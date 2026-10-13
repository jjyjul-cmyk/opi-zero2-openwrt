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

## 二、这个工程踩掉的三个坑

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

顺带：`CONFIG_OVERLAY_FS` 基线里本来就是 `y`（第 4395 行），Docker 的 overlay2 存储驱动不用管。

**还有一个隐藏的坑**：sunxi 的 sdcard 镜像是**编译期定死大小**的（`gen_sunxi_sdcard_img.sh` 吃
`CONFIG_TARGET_ROOTFS_PARTSIZE`），刷完**不会自动扩容**。官方默认只有 **104 MiB**，`docker pull` 第一个镜像就爆盘。
本工程设成 **2048 MiB**。

---

## 三、怎么出固件

推上 GitHub，进 **Actions → Build OpenWrt for Orange Pi Zero 2 → Run workflow**。

流程里有一步叫 **"预检 · 只打补丁不编译"**，这是刻意加的：

> AW859A 的驱动是靠补丁注入 backports 的。如果哪天 backports 版本再漂移、或 DTS 上下文变了，
> 这一步会在 **5～10 分钟**内失败并直接给出 `tail -150` 的日志。
> 不然你要等一小时才知道补丁没打上。

- 首次全量：约 40～90 分钟（含工具链）
- 有 ccache 命中后：约 15～25 分钟

出产物在 **Artifacts → `openwrt-24.10-orangepi-zero2`**，包含：

```
openwrt-24.10.8-sunxi-cortexa53-xunlong_orangepi-zero2-ext4-sdcard.img.gz      ← 推荐
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

- **剩余风险**：移植仓库最后更新在 2025-08，当时对齐的是 backports 6.12.6；现在 24.10 分支是 6.12.96。
  DTS 补丁也可能因为 24.10 的 DTS 演进失配。两者都由"预检"那一步提前暴露。
  真失配了，方案是**把 OpenWrt 树 pin 到 2025 年年中的 commit**，让上下文回到作者测过的状态。
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
