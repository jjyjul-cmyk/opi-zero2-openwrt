#!/usr/bin/env bash
#
# 亚瑟（JDCloud RE-SS-01）专用改造脚本
#
# 运行时机：./scripts/feeds update/install 之后、生成 .config 之前（由 workflow 调用）
# 干五件事：
#   1) 改默认 LAN IP 与主机名
#   2) 从 target 默认包 / 设备默认包里去掉 WiFi（ath11k 固件与 ipq-wifi 校准数据）
#   3) 从 kenzok8/small-package 稀疏克隆 luci-app-ssr-plus 与它缺的依赖（shadowsocksr-libev）
#   4) 把 overlay-arthur/ 注入 rootfs（Open-Box 首启安装器 + 说明）
#   5) 自检 NSS 包集合是否就位（缺了就别浪费时间编了）
#
# 环境变量：OPENWRT_DIR / DEFAULT_LAN_IP / DEFAULT_HOSTNAME / THIRD_PARTY_FILE
#
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENWRT_DIR="${OPENWRT_DIR:-$REPO_ROOT/openwrt}"
DEFAULT_LAN_IP="${DEFAULT_LAN_IP:-192.168.2.1}"
DEFAULT_HOSTNAME="${DEFAULT_HOSTNAME:-JDCloud-Arthur}"
THIRD_PARTY_FILE="${THIRD_PARTY_FILE:-$REPO_ROOT/third-party-sources.txt}"

# SSR-Plus 及依赖的来源仓库（稀疏克隆，只取需要的目录）
SMALL_REPO_URL="${SMALL_REPO_URL:-https://github.com/kenzok8/small-package.git}"
SMALL_REPO_BRANCH="${SMALL_REPO_BRANCH:-main}"
# luci-app-ssr-plus : 主体
# shadowsocksr-libev: SSR 协议的 local/redir 内核。ImmortalWrt 的 feeds 里没有，
#                     而 luci-app-ssr-plus 默认 INCLUDE_ShadowsocksR_Libev_Client=y，
#                     不补上就是硬依赖缺失、编译直接红。
SMALL_REPO_PATHS=(luci-app-ssr-plus shadowsocksr-libev)

cd "$OPENWRT_DIR"
[ -f Makefile ] || { echo "!! $OPENWRT_DIR 不是 OpenWrt 源码树" >&2; exit 1; }

echo "===== 1/5 默认 LAN IP 与主机名 ====="
grep -q "192\.168\.1\.1" package/base-files/files/bin/config_generate || {
  echo "!! config_generate 里找不到 192.168.1.1，上游可能改过默认值，检查后再改" >&2; exit 1
}
sed -i "s/192\.168\.1\.1/$DEFAULT_LAN_IP/g" package/base-files/files/bin/config_generate
sed -i "s/hostname='OpenWrt'/hostname='$DEFAULT_HOSTNAME'/g" package/base-files/files/bin/config_generate
echo "  LAN  : $DEFAULT_LAN_IP"
echo "  主机名: $DEFAULT_HOSTNAME"
if grep -n "192\.168\.1\.1" package/base-files/files/bin/config_generate; then
  echo "  [warn] 仍有 192.168.1.1 残留（可能是注释或别的用途），确认后自行决定" >&2
fi

echo "===== 2/5 去掉 WiFi：从默认包里删掉 ath11k 与 ipq-wifi ====="
# 关键：ath11k-firmware-ipq6018 写在 target.mk 的 DEFAULT_PACKAGES 里，属于"目标默认包"。
# Kconfig 里这类符号因为 DEFAULT_*=y 而没有 prompt，所以在 .config 里写
# CONFIG_PACKAGE_kmod-ath11k=n 是关不掉的（make defconfig 会把它覆盖回 y）。
# 同理 ipq-wifi-jdcloud_re-ss-01 写在设备定义的 DEVICE_PACKAGES 里，
# CONFIG_TARGET_DEVICE_PACKAGES_...="" 也压不住。
# 唯一可靠的办法：在源码层把这两个名字从默认包列表里删掉。
TT=target/linux/qualcommax/ipq60xx/target.mk
[ -f "$TT" ] || { echo "!! 找不到 $TT" >&2; exit 1; }
sed -i 's/ath11k-firmware-ipq6018[[:space:]]*//; s/[[:space:]]*ath11k-firmware-ipq6018//' "$TT"
if grep -q 'ath11k-firmware-ipq6018' "$TT"; then
  echo "!! $TT 里仍残留 ath11k-firmware-ipq6018" >&2; exit 1
fi
echo "  $TT"
grep '^DEFAULT_PACKAGES' "$TT" | sed 's/^/    /'

IM=target/linux/qualcommax/image/ipq60xx.mk
[ -f "$IM" ] || { echo "!! 找不到 $IM" >&2; exit 1; }
sed -i '/^define Device\/jdcloud_re-ss-01$/,/^endef$/ s/ipq-wifi-jdcloud_re-ss-01[[:space:]]*//' "$IM"
if sed -n '/^define Device\/jdcloud_re-ss-01$/,/^endef$/p' "$IM" | grep -q 'ipq-wifi'; then
  echo "!! $IM 的亚瑟设备定义里仍残留 ipq-wifi" >&2; exit 1
fi
echo "  $IM 亚瑟段："
sed -n '/^define Device\/jdcloud_re-ss-01$/,/^endef$/p' "$IM" | sed 's/^/    /'

echo "===== 3/5 拉取 ShadowSocksR Plus 及缺失依赖 ====="
SMALL_DIR="$(mktemp -d /tmp/kenzok8-small-package.XXXXXX)"
trap 'rm -rf "$SMALL_DIR"' EXIT
git clone --depth=1 --no-tags --filter=blob:none --sparse \
  --branch "$SMALL_REPO_BRANCH" --single-branch "$SMALL_REPO_URL" "$SMALL_DIR"
git -C "$SMALL_DIR" sparse-checkout set "${SMALL_REPO_PATHS[@]}"
SMALL_COMMIT="$(git -C "$SMALL_DIR" rev-parse HEAD)"
echo "  $SMALL_REPO_URL@$SMALL_REPO_BRANCH = $SMALL_COMMIT"

# 记录第三方源码版本，便于以后核对（不写进固件）
{
  printf 'Repository\tBranch\tCommit\n'
  printf '%s\t%s\t%s\n' "$SMALL_REPO_URL" "$SMALL_REPO_BRANCH" "$SMALL_COMMIT"
} > "$THIRD_PARTY_FILE"

for d in "${SMALL_REPO_PATHS[@]}"; do
  rm -rf "package/$d"
  cp -a "$SMALL_DIR/$d" "package/$d"
  echo "  + package/$d"
done

# 放在 package/ 根下会被自动扫描，不需要 feeds install；校验一下 Makefile 真在
[ -f package/luci-app-ssr-plus/Makefile ] || { echo "!! luci-app-ssr-plus 没拉下来" >&2; exit 1; }
[ -f package/shadowsocksr-libev/Makefile ] || { echo "!! shadowsocksr-libev 没拉下来" >&2; exit 1; }
echo "  ssr-plus 版本: $(sed -n 's/^PKG_VERSION:=[[:space:]]*//p' package/luci-app-ssr-plus/Makefile | head -1)"

echo "===== 4/5 注入 overlay（Open-Box 首启安装器）====="
mkdir -p files
cp -a "$REPO_ROOT/overlay-arthur/." files/
chmod 0755 files/etc/uci-defaults/99-open-box
find files -type f -printf '  %M %p\n' | sort

echo "===== 5/5 自检 NSS 包集合 ====="
if [ ! -d feeds/nss_packages ]; then
  echo "!! feeds/nss_packages 不存在 —— NSS 硬件加速会整体缺失。" >&2
  echo "   检查 feeds.conf.default 是否有 nss_packages 这一行（上游 laipeng668/immortalwrt 才有）。" >&2
  exit 1
fi
# NSS 的包分散在两处，别只盯着 feed 目录：
#   feeds/nss_packages/...  → 驱动主体（qca-nss-drv / qca-nss-ecm）、固件、nss-ifb
#   package/kernel/...      → datapath（qca-nss-dp）与 switch SDK（qca-ssdk），源码树自带，
#                             这两个包名分别对应 kmod-qca-nss-dp / kmod-qca-ssdk
NSS_CHECK="
feeds/nss_packages/qca-nss-drv
feeds/nss_packages/qca-nss-ecm
feeds/nss_packages/nss-ifb
feeds/nss_packages/firmware/nss-firmware
package/kernel/qca-nss-dp
package/kernel/qca-ssdk
"
for p in $NSS_CHECK; do
  if [ -e "$p" ]; then
    echo "  OK   $p"
  else
    echo "!! $p 缺失" >&2
    echo "   当前实际存在的相关目录：" >&2
    ls -d feeds/nss_packages/*/ 2>/dev/null >&2 || true
    ls -d package/kernel/qca-*/ 2>/dev/null >&2 || true
    exit 1
  fi
done

echo "改造完成。"
