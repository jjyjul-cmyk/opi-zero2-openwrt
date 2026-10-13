# Orange Pi Zero 2 → OpenWrt 24.10：WiFi + 蓝牙 + Docker

把 Xunlong Orange Pi Zero 2（Allwinner H616 + AW859A）编成一份**板载无线能用、蓝牙能用、带 Docker** 的 OpenWrt 固件。
在 GitHub Actions 上跑，点一次出 `img.gz`。

---

## 一、为什么必须整棵树编，不能偷懒

零 2 的板载无线 **AW859A 就是紫光展锐 UWE5622 的封装版**。它的两个驱动：

| 部件 | 驱动模块 | 在 Linux 主线里吗 |
|---|---|---|
| WiFi | `sprdwl_ng` + `uwe5622_bsp_sdio` | ❌ 不在 |
| 蓝牙 | `sprdbt_tty`（走 tty-sdio，非 USB/UART HCI） | ❌ 不在 |

所以：

- **官方 release 镜像 / ImageBuilder / firmware-selector** → 编出来一个无线接口都没有，直接排除。
- **openwrt.ai 那类在线定制站** → 同样拿不到这块驱动，排除。
- **SDK 单编 kmod 塞进官方镜像** → 我们为了 Docker 改了内核配置（cgroup/namespace），vermagic 必然和官方 rootfs 不匹配，模块加载不进去，也不行。

结论：只有整棵树编这一条路。本次用的是社区移植 [`DeepAQ/openwrt-uwe5622-sunxi`](https://github.com/DeepAQ/openwrt-uwe5622-sunxi)，
作者在 README 里写明了 **"Tested on Orange Pi Zero 2 with OpenWrt 24.10 source code"**，所以版本锁在 `openwrt-24.10`。

---

## 二、这个工程踩掉的四个坑

### 坑 1：移植仓库自带的 `mac80211/Makefile` 会毁掉整次编译

那个仓库里有一份 `package/kernel/mac80211/Makefile`。它的 README 说"把文件 merge 进去"，
但这份 Makefile 把 backports 固定在 **6.12.6**，而 openwrt-24.10 分支现在是 **6.12.96**：

```
 官方:   PKG_VERSION:=6.12.96  PKG_RELEASE:=4   .../backports/releases/.../backports-v6.12.96.tar.zst
 移植:   PKG_VERSION:=6.12.6   PKG_RELEASE:=2   http://mirror2.openwrt.org/sources/backports-6.12.6.tar.xz
```

直接覆盖 = backports 降级 + 官方几十个按 6.12.96 写的补丁集体失配 = 必挂。

`scripts/diy.sh` 改成**最小侵入**：只取它的 `unisoc.mk` 和 `patches/unisoc/`，再往官方 Makefile 里补 3 行
（`include unisoc.mk` + `PatchDir` + `Quilt/RefreshDir`）。官方那份 Makefile 的锚点不存在时会直接报错退出，
不会静默编出一个没无线的固件。

### 坑 2：蓝牙固件所在的 `armbian/firmware` 是个巨型 git 仓库

上游 `armbian-firmware` 包用 `PKG_SOURCE_PROTO:=git` 拉整个 `armbian/firmware`。
CI 里 clone 几百 MB～GB，又慢又容易爆盘。

本工程改为**按固定 commit 直取 5 个文件**（全部实测可达，见下），秒级完成：

| 文件 | 用途 | 大小 |
|---|---|---|
| `uwe5622/wcnmodem.bin` | WiFi 固件 | 947 KB |
| `uwe5622/wcnmodem-38222.bin` | WiFi 固件（备用） | 1.75 MB |
| `uwe5622/wifi_2355b001_1ant.ini` | 单天线射频参数 | 6.7 KB |
| `bt_configure_pskey.ini` / `bt_configure_rf.ini` | 蓝牙参数 | 5.3 / 3.1 KB |

固件 commit：`fc3059b081043ea9e121841af12d976984b2d5bf`（与上游包固定的是同一个）。

### 坑 3：Docker 起不来，问题在内核不在软件包

openwrt-24.10 的 `target/linux/generic/config-6.6` 里这四项**全是关的**：

```
第 849 行   # CONFIG_CGROUPS is not set
第 3835 行  # CONFIG_NAMESPACES is not set
第 4681 行  # CONFIG_POSIX_MQUEUE is not set
第 5310 行  # CONFIG_SECCOMP is not set
```

`configs/zero2.config` 已补齐 cgroup / namespace 全家桶 + `POSIX_MQUEUE` + `SECCOMP`。
生效机制是 `include/kernel-defaults.mk:117` —— 它把 `.config` 里所有 `CONFIG_KERNEL_*` 去掉前缀后
**追加**到内核 `.config.target` 末尾，所以能覆盖上面的基线。

**这里有个很坑的写法错误**：`veth` 在 OpenWrt 里**不是** `CONFIG_KERNEL_` 符号。
它由 `kmod-veth` 这个内核模块包用 `KCONFIG:=CONFIG_VETH` 驱动（`package/kernel/linux/modules/netsupport.mk:522`），
所以正确写法是 `CONFIG_PACKAGE_kmod-veth=y`。写 `CONFIG_KERNEL_VETH=y` 会被 `make defconfig`
**静默丢弃**——不报错、不警告，你以为开了其实没开。

> 排查这类问题要注意：`config/Config-kernel.in` 里 cgroup / namespace 的子项是**带 Tab 缩进**
> 写在 `if KERNEL_CGROUPS` / `if KERNEL_NAMESPACES` 块里的。用 `grep '^config KERNEL_'` 会
> **把 `KERNEL_CGROUP_DEVICE`、`KERNEL_MEMCG`、`KERNEL_NET_NS` 等全部漏掉**，误判成"符号不存在"。
> 正确写法是 `grep -E '^[[:space:]]*config KERNEL_'`。

顺带：`CONFIG_OVERLAY_FS` 基线里本来就是 `y`（第 4395 行），Docker 的 overlay2 存储驱动不用管。

**还有一个隐藏的坑**：sunxi 的 sdcard 镜像是**编译期定死大小**的（`gen_sunxi_sdcard_img.sh` 吃
`CONFIG_TARGET_ROOTFS_PARTSIZE`），刷完**不会自动扩容**。官方默认只有 **104 MiB**，`docker pull` 第一个镜像就爆盘。
本工程设成 **2048 MiB**。

### 坑 4：内核 `syncconfig` 会因为一个上游新符号直接把编译打断

这个坑是**实际编译到 29 分钟时才炸**的，报错长这样：

```
  Realtek PHYs (REALTEK_PHY) [Y/n/m/?] y
    HWMON support for Realtek PHYs (REALTEK_PHY_HWMON) [N/y/?] (NEW)
make[8]: *** [scripts/kconfig/Makefile:77: syncconfig] Error 1
make[7]: *** [Makefile:697: syncconfig] Error 2
ERROR: target/linux failed to build.
```

**不是我们的驱动、也不是 Docker 配置的问题**，是上游 24.10 分支的一个回归：

| | 原始（24.10 早期） | 现在（backport `781-27`） |
|---|---|---|
| Kconfig | `def_bool REALTEK_PHY && HWMON` | `bool "HWMON support for Realtek PHYs"` |
| 有无默认值 | **有** → 内核从不追问 | **没有** → 内核必须追问 |
| 可见性 | 内部符号 | 用户可见 |

而 `target/linux/sunxi/config-6.6` 里 `CONFIG_REALTEK_PHY=y`、`CONFIG_HWMON=y`：
两个依赖都满足，符号就**可见**了；但整个 `config-6.6` 里**没有它的条目**，于是它**没有值**。
内核的 `syncconfig` 在非交互环境下会对「没有值」的符号发问，读到 EOF 就 `exit 1`。

> 判定依据在内核源码里写得很明确：`scripts/kconfig/conf.c` 的 `check_conf()` 条件是
> `if (sym && !sym_has_value(sym) && (sym_is_changeable(sym) || ...))`，
> 走 `default:` 分支 → `printf("*\n* Restart config...\n*\n")` → `conf(rootEntry)` 打印整段菜单并提问。
> 这个 `default:` 分支对**所有输入模式**生效（只有 `listnewconfig` / `helpnewconfig` 除外），
> 所以 `--syncconfig` 也会问。

**官方 release 为什么没踩到？** 因为官方那套 `.config` 带 `CONFIG_ALL_KMODS=y`
（见 `targets/sunxi/cortexa53/config.buildinfo`），必然会选中 `kmod-hwmon-core`；而它的定义是
`KCONFIG:=CONFIG_HWMON`（`package/kernel/linux/modules/hwmon.mk:14`），于是 `.config.override`
把 `CONFIG_HWMON` 压成 `=m`。此时依赖 `!(REALTEK_PHY=y && HWMON=m)` 为**假**，符号直接隐藏，根本不会被问。
我们是精简包集（不编译全部 kmod），`HWMON` 保持 `config-6.6` 里的 `=y` —— 于是中招。

**两道保险**（都在 `scripts/diy.sh` 里，且都是幂等的）：

1. 给该符号显式赋值：往 `target/linux/sunxi/config-6.6` 追加
   `# CONFIG_REALTEK_PHY_HWMON is not set`。
2. **通用兜底**：在 `include/kernel-defaults.mk` 的 `Kernel/Configure/Default` 里、
   写完内核 `.config` 之后插入一行 `yes '' | $(KERNEL_MAKE) oldconfig`。
   这样任何「可见但无默认值」的新符号都会自动取默认值，不再有非交互 EOF 问题。
   插入前会断言锚点唯一、插入后会在自检里 `grep` 标记，防止静默失效。

> 为什么不是简单地把 `CONFIG_ALL_KMODS=y` 打开？那会把所有内核模块都编进去，
> 编译时间从 40 分钟涨到数小时，镜像也大得多。上面两条只改配置，不增加产物。

---

## 三、怎么出固件

仓库推上去后，`push` 本身就会触发编译；也可以在
**Actions → Build OpenWrt for Orange Pi Zero 2 → Run workflow** 手动再跑一次。

用 `tools/publish.sh` 的话，建仓库 → 推代码 → 触发 → 轮询 → 下载固件是一条命令走完的。

**这次只把必要的坑填了，没有改 rootfs 形态**：`CONFIG_TARGET_ROOTFS_SQUASHFS` 和
`CONFIG_TARGET_ROOTFS_EXT4FS` 都保持为开，与上游 sunxi 的 `FEATURES`（含 `ext4` 与 `squashfs`）一致，
出镜像的形态因此和官方发布版完全相同。

流程里有一步叫 **"预检 · 只打补丁不编译"**，这是刻意加的：

> AW859A 的驱动是靠补丁注入 backports 的。如果哪天 backports 版本再漂移、或 DTS 上下文变了，
> 这一步会在 **5～10 分钟**内失败并直接给出 `tail -150` 的日志。
> 不然你要等一小时才知道补丁没打上。
>
> 它还会断言 `build_dir` 里真的出现了 `uwe5622` 目录——防止"补丁命令没报错但其实没生效"。

- 首次全量：约 40～90 分钟（含工具链）
- 有 ccache 命中后：约 15～25 分钟

> ccache 目录要注意：`rules.mk:346` 定义的默认值是 `$(TOPDIR)/.ccache`，
> 也就是 `openwrt/.ccache`，**不是 `~/.ccache`**。缓存错路径等于没有缓存，每次都要全量重编。

产物在 **Artifacts → `openwrt-24.10-orangepi-zero2`**（文件名已对照官方 24.10.8 下载目录确认）：

```
openwrt-24.10.8-sunxi-cortexa53-xunlong_orangepi-zero2-ext4-sdcard.img.gz      ← 跑 Docker 用这个
openwrt-24.10.8-sunxi-cortexa53-xunlong_orangepi-zero2-squashfs-sdcard.img.gz
sha256sums
profiles.json
zero2.build.config
```

> sunxi 目标**不产出 `.bin`**，可启动镜像就是 `sdcard.img.gz`（gzip 过的 raw 镜像）。
> balenaEtcher 能直接吃 `.gz`；要用 `dd` 就先 `gzip -d`。

**两种镜像怎么选**

| | ext4 | squashfs |
|---|---|---|
| 根分区 | 编译期就做成 2 G，直接可用 | 2 G 分区，但 squashfs 只占几十 M，剩下靠 overlay |
| 重置 | 手动重刷 | 可以恢复出厂 |
| 跑 Docker | **推荐** | 也能跑，但数据写在 overlay 里 |

---

## 四、刷完先做这几步

```sh
# 1. 找到设备（默认 DHCP，网口在 lan 里）
#    浏览器开 http://192.168.1.1   —— LuCI，无密码，先设密码

# 2. 看无线有没有起来
ubus call network.wireless status | grep -i up
iwinfo                        # 应该能看到 phy0 / wlan0
ls /lib/firmware/ | grep -E 'wcnmodem|2355b'    # 固件三件套

# 3. 看蓝牙
/etc/init.d/aw859a-bt status  # 一条命令看模块/串口/hci0/wlan
/etc/init.d/aw859a-bt wifi    # 单独重载无线并检查接口
logread -e aw859a-bt
cat /tmp/aw859a-bt.log

# 4. Docker
/etc/init.d/dockerd status
docker info | grep -E 'Storage Driver|Cgroup|Server Version'
docker run --rm hello-world
```

如果要拿 USB 盘当 Docker 数据目录：

```sh
opkg update && opkg install kmod-usb-storage-uas block-mount
# 插盘后
lsblk
uci set dockerd.globals.data_root='/mnt/sda1/docker/'
uci commit dockerd && /etc/init.d/dockerd restart
```

国内拉镜像慢的话，在 `/etc/config/dockerd` 里加镜像源（**镜像站经常失效，自己挑可用的**）：

```sh
uci add_list dockerd.globals.registry_mirrors='https://你的镜像站'
uci commit dockerd && /etc/init.d/dockerd restart
```

---

## 五、已知问题与排查

**先说清楚哪些是验证过的、哪些是待上机确认的。**

- ✅ **WiFi 有社区实证**（移植作者在 Zero 2 + 24.10 上测过）。但 **LuCI 无线页不显示关联信息是已知缺陷**
  （作者在 README 里明确列为 Known issues），**不影响实际上网**。
- ⚠️ **蓝牙属于"内核模块已编出 + 用户态拼装"，上机前未经实测。** `sprdbt_tty.ko` 随驱动包一起编译，
  但 `hciattach_opi` 和射频参数是从 Armbian 取来塞进 rootfs 的。上电脚本按 Armbian 实测参数
  （`hciattach_opi -s 1500000 /dev/ttyBT0 sprd`）写的，并且**两个 hciattach 版本都会依次尝试**，
  日志里能直接看出哪个管用。

### 蓝牙起不来的排查顺序

```sh
# ① 字符设备在不在？不在说明 sprdbt_tty 没起来
ls -l /dev/ttyBT0

# ② driver 起来了但没挂 HCI
dmesg | grep -iE 'uwe5622|sprd|tty-sdio|bluetooth'

# ③ 手工重试，把报错看全
/usr/bin/hciattach_opi -s 1500000 /dev/ttyBT0 sprd
/usr/bin/hciattach_opi_upstream -s 1500000 /dev/ttyBT0 sprd

# ④ MAC 地址来源：sunxi_addr 提供芯片 cid，sprd 驱动据此生成稳定 MAC
lsmod | grep sunxi_addr
cat /sys/class/misc/sunxi-addr/* 2>/dev/null
```

有串口调试线会轻松很多（H616 的 debug UART 是 115200）。

### WiFi 连不上的排查顺序

```sh
dmesg | grep -iE 'sprdwl|uwe5622'
lsmod | grep -E 'sprdwl_ng|uwe5622_bsp_sdio'
ls /lib/firmware/ | grep -E 'wcnmodem|2355b'
cat /etc/config/wireless
```

这块模组对 **802.11r（快速漫游）和频段引导不稳**，家用路由先关掉再连。

### 其它

- **已核实（对着本地解压的完整 24.10 源码树逐条比对）**：
  - 移植仓库的 12 个 sunxi 补丁与上游 `target/linux/sunxi/patches-6.6` 里的 27 个补丁**零重名**，
    可以整批放入；`cp -an` 已保证万一上游将来收录同名补丁也不会覆盖。
  - `configs/zero2.config` 里 16 个 `CONFIG_KERNEL_*` 符号、以及设备/镜像/软件包符号，
    全部在源码树里真实存在。唯一的例外 `CONFIG_KERNEL_VETH` 已删除（原因见第二节）。
  - 工作流里加了一道配置校验，任何 `MISS` 都会在编译前直接终止，不会白等一小时。
- **backports 版本失配风险 —— 已实测排除**：移植仓库最后更新在 2025-08，当时对齐 backports 6.12.6，
  而 24.10 分支现在是 6.12.96。实际跑过之后，**15 个 unisoc 补丁全部干净应用**
  （`104`~`114` 逐个 `Applying ... using plaintext`，无一处 hunk 失败），
  `make package/kernel/mac80211/prepare` 正常退出。所以**不需要** pin 老 commit。
- **仍需观察**：预检第二段 `make target/linux/prepare`（sunxi 的 12 个 DTS/内核补丁）。
  DTS 补丁可能因 24.10 的 DTS 演进失配（`Device/Default` 的 DTS 会被上游 `016`/`023` 等补丁改过，
  而移植仓库的 DTS 补丁按文件名排序排在它们**之后**应用）。由预检这一步兜住。
  真失配了，方案是**把 OpenWrt 树 pin 到 2025 年年中的 commit**，让上下文回到作者测过的状态。
- **写断言不要制造假阴性**（踩过的坑）：预检里查驱动是否注入，第一版写
  `find build_dir -maxdepth 6 -type d -name uwe5622` —— 而驱动实际落在 `build_dir` 下**第 8 层**
  （`target-<arch>_musl/linux-sunxi_cortexa53/mac80211-regular/backports-<ver>/drivers/net/wireless/uwe5622`），
  于是一次完全正常的编译被误判成"补丁没生效"直接红掉。现在改成**两条独立证据、任一成立即通过**
  （补丁日志里的 `patching file .../uwe5622/` 计数 + `maxdepth 12` 的目录查找），并额外抽查三个关键源文件。
  校验逻辑本身也会出错，别让它比它要防的问题更脆弱。
- **不要**把 `files/` 里的 `etc/init.d/*` 改成非可执行——git 在 Windows 上不记可执行位，
  `scripts/diy.sh` 结尾会统一 `chmod 0755` 补回来。

---

## 六、目录说明

```
.github/workflows/build.yml   云编译流水线（含"只打补丁"预检）
configs/zero2.config          配置种子，cp 成 .config 后 make defconfig
scripts/diy.sh                源码树改造：驱动注入 / DTS / 固件 / overlay
overlay/                      直接进 rootfs 的文件
  etc/init.d/aw859a-bt        蓝牙上电脚本（带 status / wifi 子命令）
  etc/uci-defaults/99-aw859a-bt      首次启动 enable 蓝牙服务
  etc/uci-defaults/99-docker-setup   首次启动配置并 enable Docker
tools/publish.sh              建仓库 + 推代码 + 触发编译（可选）
```

### 上游来源

| 内容 | 来源 |
|---|---|
| UWE5622 驱动（`unisoc.mk` + `patches/unisoc/`） | `DeepAQ/openwrt-uwe5622-sunxi` |
| H616 / Zero2 DTS 与 `sunxi_addr` 内核补丁 | 同上（内核补丁与固件源自 Armbian） |
| WiFi 固件、蓝牙射频参数 | `armbian/firmware` @ `fc3059b` |
| `hciattach_opi` | `armbian/build` → `packages/blobs/bt/hciattach/` |
