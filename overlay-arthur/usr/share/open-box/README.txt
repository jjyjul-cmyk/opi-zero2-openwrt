Open-Box（一体化透明代理）—— 本固件的预置说明与排错
=====================================================
适用机型：JDCloud RE-SS-01（京东云无线宝 亚瑟 AX1800 Pro / IPQ6000）
固件：ImmortalWrt 25.12 + 6.18 内核 + 全功能 NSS，无 WiFi，带 USB3.0

一、固件已经为你做了哪些准备
--------------------------------
1. Open-Box 要求的系统依赖已全部预装，不用再连软件源：
   kmod-tun、kmod-nft-core/nat/queue/socket/tproxy、kmod-veth、
   ip-full、nftables-json、iptables-nft、ca-bundle、curl
2. 首次开机联网后会自动执行官方安装脚本（后台跑，不阻塞开机）
   日志：/root/open-box-install.log
3. 安装成功后：浏览器打开 http://<路由器IP>:3036 ，首次进入时设置面板密码
   （端口可在安装时用 --port 改，或装好后在面板里改）

为什么要"自动装"而不是直接打进固件：
   Open-Box 自有程序是闭源发布包，官方安装脚本会按架构下载约 106MB 运行时
   （含 sing-box 内核、Node 运行时、GeoSite/GeoIP 数据）并注册开机自启。
   固件内预置的是依赖 + 自动安装，保持升级路径和官方一致。

二、手动安装 / 重装 / 升级 / 卸载
--------------------------------
# 手动安装（指定面板端口）
mkdir -p /opt
curl -fsSL https://raw.githubusercontent.com/liandu2024/Open-Box/main/scripts/install.sh | sh -s -- --port 3036

# raw.githubusercontent.com 不通时：先用镜像取脚本，再让脚本 --mirror 走镜像下发布包
#   sh install.sh --mirror            # 自动探测内置镜像列表
#   sh install.sh --mirror <前缀>      # 指定镜像前缀

# 升级
curl -fsSL https://raw.githubusercontent.com/liandu2024/Open-Box/main/scripts/update.sh | sh -s -- --mirror

# 卸载
curl -fsSL https://raw.githubusercontent.com/liandu2024/Open-Box/main/scripts/uninstall.sh | sh

# 服务状态
/etc/init.d/openbox status
/etc/init.d/openbox-panel status

三、内存/存储要求（亚瑟是 512MB 内存，属于最低配）
--------------------------------
Open-Box 安装时会自检：
  - MemTotal ≥ 440MB（/proc/meminfo）
  - 安装分区（/opt 所在）可用空间 ≥ 512MB

本固件带 NSS 驱动，设备树 ipq6018-512m.dtsi 给 NSS 预留了 55MB（0x3700000）。
如果 /root/open-box-install.log 里出现"内存不足"，说明留给系统的内存不够，
可以把 NSS 预留改小后重编固件（无 WiFi 用不到那么大）：

  编辑 target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi
    reg = <0x0 0x4ab00000 0x0 0x3700000>;   # 55MB（默认）
  改成
    reg = <0x0 0x4ab00000 0x0 0x2000000>;   # 32MB
  或
    reg = <0x0 0x4ab00000 0x0 0x1000000>;   # 16MB
  改完在 scripts/diy-arthur.sh 里加一行 sed 即可（脚本里留了注释位置）。

另外：/opt 在 overlay 上，所以机器必须刷的是"大分区"布局，否则 106MB 装不下。

四、和 ShadowSocksR Plus 不要同时开
--------------------------------
两者都会接管 nftables 透明代理 + DNS，同时启用会互相抢规则，表现为偶发断流/解析异常。
二选一：
  - 用 SSR-Plus：LuCI → 服务 → ShadowSocksR Plus+ 里配置好，确认 Open-Box 停止
  - 用 Open-Box：/etc/init.d/openbox stop，SSR-Plus 里把"运行状态"关掉

五、参考资料
--------------------------------
Open-Box 项目：https://github.com/liandu2024/Open-Box
（安装、升级、卸载所需脚本均来自该项目官方仓库）
