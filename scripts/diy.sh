#!/usr/bin/env bash
#
# Xunlong Orange Pi Zero 2 (Allwinner H616 + AW859A) —— OpenWrt 源码树改造脚本
#
# 背景（这几条都是实际查证过的，不是推断）：
#   1) 板载无线 AW859A 就是紫光展锐 UWE5622 的封装版。WiFi(sprdwl_ng) 与蓝牙(sprdbt_tty)
#      两个驱动都不在 Linux 主线里，所以 OpenWrt 官方固件 / ImageBuilder /
#      firmware-selector 做出来的镜像一个无线接口都没有。
#      社区移植：https://github.com/DeepAQ/openwrt-uwe5622-sunxi
#      作者声明 "Tested on Orange Pi Zero 2 with OpenWrt 24.10 source code"。
#
#   2) 该移植仓库自带一份 package/kernel/mac80211/Makefile。如果按"文档说的直接 merge"，
#      它会**覆盖**OpenWrt 官方那份，把 backports 从 6.12.96 降级到 6.12.6 ——
#      官方那几十个 mac80211 补丁是按 6.12.96 写的，集体失配，必挂。
#      本脚本改为最小侵入：只取它的新增件，再往官方 Makefile 里补 3 行。
#
#   3) 官方 mac80211/Makefile 里 driver 的挂载方式是 include xxx.mk + PatchDir，
#      所以新增一个驱动只需要这 3 行，不碰版本。
#
#   4) 固件与蓝牙二进制不走上游那个 armbian/firmware 巨型 git 仓库（几百 MB～GB 级，
#      CI 里 clone 又慢又容易爆盘），改为按固定 commit 直取 5 个小文件。
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${SRC:-$ROOT/openwrt}"
PATCH_REPO="${PATCH_REPO:-https://github.com/DeepAQ/openwrt-uwe5622-sunxi.git}"
PATCH_REPO_REF="${PATCH_REPO_REF:-main}"

# 与上游 package/firmware/armbian-firmware 固定的是同一个 commit
ARMBIAN_FW_COMMIT="${ARMBIAN_FW_COMMIT:-fc3059b081043ea9e121841af12d976984b2d5bf}"
ARMBIAN_FW_RAW="https://raw.githubusercontent.com/armbian/firmware/${ARMBIAN_FW_COMMIT}"
ARMBIAN_BUILD_RAW="https://raw.githubusercontent.com/armbian/build/main"

log() { echo -e "\n>>> $*"; }
warn() { echo "  [!] $*" >&2; }
die() { echo "!! $*" >&2; exit 1; }

[ -d "$SRC/package" ] || die "找不到 OpenWrt 源码目录: $SRC"
MACDIR="$SRC/package/kernel/mac80211"
MACMK="$MACDIR/Makefile"

log "0/5 体检当前源码树"
[ -f "$MACMK" ] || die "缺少 $MACMK"
grep -q 'PKG_NAME:=mac80211' "$MACMK" || die "mac80211 包结构异常"
BACKPORTS="$(grep -m1 '^PKG_VERSION:=' "$MACMK" | cut -d: -f2)"
echo "  backports 版本 = $BACKPORTS （保持官方值，不动）"
for anchor in 'include realtek.mk' 'PatchDir,$(PKG_BUILD_DIR),$(PATCH_DIR)/rtl,rtl/' 'Quilt/RefreshDir,$(PKG_BUILD_DIR),$(PATCH_DIR)/rtl,rtl/'; do
  grep -qF "$anchor" "$MACMK" || die "官方 Makefile 里找不到锚点: $anchor （上游结构变了，需要改脚本）"
done
echo "  3 个注入锚点都在"

log "1/5 拉取 AW859A / UWE5622 驱动移植"
rm -rf /tmp/uwe5622
git clone --depth 1 -b "$PATCH_REPO_REF" "$PATCH_REPO" /tmp/uwe5622
UP=/tmp/uwe5622
[ -d "$UP/package/kernel/mac80211/patches/unisoc" ] || die "移植仓库结构变了：找不到 patches/unisoc"
[ -f "$UP/package/kernel/mac80211/unisoc.mk" ]        || die "移植仓库结构变了：找不到 unisoc.mk"
echo "  补丁数量: $(ls "$UP/package/kernel/mac80211/patches/unisoc" | wc -l)"

log "2/5 注入 WiFi/蓝牙驱动（保留官方 mac80211/Makefile 版本）"
cp -a "$UP/package/kernel/mac80211/unisoc.mk" "$MACDIR/"
mkdir -p "$MACDIR/patches"
cp -a "$UP/package/kernel/mac80211/patches/unisoc" "$MACDIR/patches/"

python3 - "$MACMK" <<'PY'
import sys

p = sys.argv[1]
# 用 newline='' 显式关掉换行转换：否则在 Windows 上写入会把整份文件变成 CRLF，
# 换个环境跑就得到一份全文件 diff，甚至会因为行尾多了 \r 让 make 的续行解析出错。
with open(p, encoding='utf-8', newline='') as f:
    s = f.read()
changed = []

# (a) 挂载 unisoc.mk。必须在文件末尾那句
#     $(eval $(foreach drv,$(PKG_DRIVERS),$(call KernelPackage,$(drv))))
#     之前，否则 uwe5622 不会生成 kmod-uwe5622 配置项。
if 'include unisoc.mk' not in s:
    s = s.replace('include realtek.mk\n',
                  'include realtek.mk\ninclude unisoc.mk\n', 1)
    changed.append('include unisoc.mk')

# (b) Build/Patch 段：让 make 去 patches/unisoc/ 里打补丁
if '$(PATCH_DIR)/unisoc' not in s:
    a = '\t$(call PatchDir,$(PKG_BUILD_DIR),$(PATCH_DIR)/rtl,rtl/)\n'
    s = s.replace(a, a + '\t$(call PatchDir,$(PKG_BUILD_DIR),$(PATCH_DIR)/unisoc,unisoc/)\n', 1)
    changed.append('PatchDir/unisoc')

# (c) Quilt/Refresh/Package 段同步，否则 make package/.../refresh 会漏掉这个目录
if s.count('$(PATCH_DIR)/unisoc') < 2:
    a = '\t$(call Quilt/RefreshDir,$(PKG_BUILD_DIR),$(PATCH_DIR)/rtl,rtl/)\n'
    s = s.replace(a, a + '\t$(call Quilt/RefreshDir,$(PKG_BUILD_DIR),$(PATCH_DIR)/unisoc,unisoc/)\n', 1)
    changed.append('Quilt/RefreshDir/unisoc')

if not changed:
    print('  Makefile 已打过补丁，跳过')
else:
    with open(p, 'w', encoding='utf-8', newline='') as f:
        f.write(s)
    print('  Makefile 注入: ' + ', '.join(changed))
PY

log "3/5 注入 H616 / Zero2 的 DTS 与内核补丁"
mkdir -p "$SRC/target/linux/sunxi/patches-6.6"
# 用 -n（no-clobber）：万一上游 24.10 已收录同名补丁，保留官方那份，绝不覆盖造成重复应用
cp -an "$UP/target/linux/sunxi/patches-6.6/." "$SRC/target/linux/sunxi/patches-6.6/"
echo "  已放入: $(ls "$UP/target/linux/sunxi/patches-6.6" | wc -l) 个文件"

log "4/5 落盘 rootfs overlay（蓝牙上电脚本 + 首次启动默认项）"
mkdir -p "$SRC/files"
cp -a "$ROOT/overlay/." "$SRC/files/"
# git 在 Windows 上不记录可执行位，这里显式补回来，否则 init.d 脚本不会被执行
chmod 0755 "$SRC/files/etc/init.d/"* 2>/dev/null || true
chmod 0755 "$SRC/files/etc/uci-defaults/"* 2>/dev/null || true
echo "  overlay 文件:"
find "$SRC/files" -type f | sed 's|^|    |'

log "5/5 取 WiFi 固件与蓝牙二进制（直取，不克隆 armbian/firmware）"
FW="$SRC/files/lib/firmware"
BIN="$SRC/files/usr/bin"
mkdir -p "$FW" "$BIN"

# --- WiFi：驱动会到 /lib/firmware/ 顶层找这三个文件 ---
for f in wcnmodem.bin wcnmodem-38222.bin wifi_2355b001_1ant.ini; do
  curl -fsSL --retry 3 -o "$FW/$f" "$ARMBIAN_FW_RAW/uwe5622/$f" || die "下载失败: uwe5622/$f"
  echo "  $f  $(wc -c < "$FW/$f") 字节"
done

# --- 蓝牙：UWE5622 走 tty-sdio，需要定制版 hciattach（1500000 波特率 + sprd 协议） ---
#     两个版本都带上，上电脚本会依次尝试，日志里能看出哪个管用
curl -fsSL --retry 3 -o "$BIN/hciattach_opi" \
  "$ARMBIAN_BUILD_RAW/packages/blobs/bt/hciattach/hciattach_opi_arm64" \
  || die "下载 hciattach_opi 失败"
curl -fsSL --retry 3 -o "$BIN/hciattach_opi_upstream" \
  "$ARMBIAN_BUILD_RAW/packages/blobs/bt/hciattach/hciattach_opi_arm64_upstream" \
  || warn "备用 hciattach 下载失败（不影响主流程）"
chmod 0755 "$BIN"/hciattach_opi* 2>/dev/null || true
ls -l "$BIN"

# --- 射频参数：驱动可选读取，缺了不致命，所以失败只告警 ---
for f in bt_configure_pskey.ini bt_configure_rf.ini; do
  curl -fsSL --retry 3 -o "$FW/$f" "$ARMBIAN_FW_RAW/$f" || warn "可选文件下载失败: $f"
done

log "自检"
missing=0
check() { if [ -e "$1" ]; then echo "  OK   $1"; else echo "  MISS $1"; missing=1; fi; }
check "$MACDIR/unisoc.mk"
check "$MACDIR/patches/unisoc/100-uwe5622-allwinner-v6.3.patch"
check "$SRC/target/linux/sunxi/patches-6.6/arm64-dts-h616-add-wifi-support-for-orange-pi-zero-2-and-zero3.patch"
check "$SRC/files/etc/init.d/aw859a-bt"
check "$SRC/files/lib/firmware/wcnmodem.bin"
check "$BIN/hciattach_opi"
grep -q 'include unisoc.mk' "$MACMK" || { echo "  MISS mac80211 Makefile 未挂载 unisoc"; missing=1; }
[ "$missing" = "0" ] || die "改造不完整，见上面 MISS 项"

log "源码树改造完成。"
echo "  package/kernel/mac80211/{unisoc.mk,patches/unisoc/*}"
echo "  target/linux/sunxi/patches-6.6/*  (DTS + sunxi_addr)"
echo "  files/  (firmware / hciattach / init.d / uci-defaults)"
