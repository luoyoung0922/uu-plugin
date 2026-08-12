# luci-app-uu-official

为 OpenWrt/iStoreOS 提供网易 UU 路由器插件的 LuCI 管理界面和一键安装器。

本项目只维护开源的管理层，不分发网易 UU 的闭源核心。安装后，监控脚本和 `uuplugin` 运行时仍由网易官方接口提供，并沿用官方的启动方式。

> 本项目不是网易官方项目，与网易没有隶属或合作关系。“网易”“UU”及相关商标归其权利人所有。

## 功能

- 在 LuCI 中查看 UU 服务是否运行、进程 PID、架构和监控脚本状态
- 启动、停止、重启服务，更新官方监控脚本，重新安装运行时
- 从 UU 实际创建的 `XU_ACC_DEVICE_*` nftables 规则识别加速设备
- 显示加速设备的 IP、MAC、可达延迟和规则包计数
- 自动识别 `x86_64`、`aarch64`、ARM、MIPS 大小端架构
- 按网易接口提供的 MD5 校验下载文件
- 保留网易官方 `S99uuplugin` 启动方式
- 避免与旧版 `uugamebooster` 软件包同时运行
- 可选的 OpenClash 动态联动：仅在 UU 实际创建设备规则时绕过代理，停止加速后自动恢复

## 支持范围

当前主要面向：

- OpenWrt/iStoreOS 24.10 或相近版本
- LuCI JavaScript 前端
- `firewall4` / nftables
- 具备可用 TUN 内核模块的设备

安装器需要 `opkg`，并会检查 `kmod-tun`、`curl` 和 `ca-bundle`。其他 OpenWrt 分支、旧版 iptables 固件及厂商深度定制系统可能需要自行适配。

## 一键安装

从 [Releases](https://github.com/luoyoung0922/uu-plugin/releases) 下载 `uu-official-installer.run`，上传到路由器后执行：

```sh
chmod +x /tmp/uu-official-installer.run
/tmp/uu-official-installer.run
```

安装完成后进入：

```text
LuCI → 服务 → 网易 UU
```

只安装、不立即启动：

```sh
/tmp/uu-official-installer.run --no-start
```

移除本项目的 LuCI 管理层：

```sh
/tmp/uu-official-installer.run --uninstall
```

卸载管理层默认保留网易官方运行文件和临时状态。若需要完全移除 UU，请使用网易官方卸载脚本。

## 使用方法

1. 安装插件并确认状态页显示服务正在运行。
2. 手机与需要加速的设备连接到路由器所在局域网。
3. 在网易 UU App 中添加路由器、选择目标设备并开始加速。
4. 返回 LuCI 状态页查看 UU 实际下发的设备规则和包计数。

设备表中的含义：

- **IP/MAC**：UU 规则对应的局域网设备
- **延迟**：路由器 ping 设备的局域网可达延迟，不是游戏延迟
- **Packets**：UU nftables 规则累计命中的数据包数量；持续增长通常表示规则正在处理流量

`/tmp/uu/activate_status` 主要反映路由器注册状态，不应单独用于判断某个终端是否正在加速。本项目优先以 UU 实际创建的 `XU_ACC_DEVICE_*` 规则为准。

## 主路由与旁路由

主路由部署通常最省心。旁路由部署时需要自行保证目标设备的流量确实经过运行 UU 的 OpenWrt：

- 目标设备的默认网关或策略路由应指向旁路由
- 手机 App 的路由器发现可能依赖局域网路径和 DNS
- “App 显示正在匹配”和“目标设备规则已生效”属于不同状态，旁路由环境中可能不同步
- 请以目标设备规则是否出现、包计数是否增长以及游戏实测为准

项目不会改写 OpenClash 配置文件。内置的 `uu-openclash-sync` 服务只观察 UU 创建的 `XU_ACC_DEVICE_<IP>_*` 表，并临时向 OpenClash nftables 链加入带专用注释的绕过规则：

- UU 开始加速：检测到设备表后，该设备临时绕过 OpenClash
- UU 停止加速：设备表消失后，自动删除临时规则，该设备恢复走 OpenClash
- 不需要写死设备 IP，也不会永久添加 `SRC-IP-CIDR,DIRECT`

检查动态规则：

```sh
nft -a list chain inet fw4 openclash | grep 'uu_official_dynamic_bypass'
/etc/init.d/uu-openclash-sync status
```

如不需要联动，可停用：

```sh
/etc/init.d/uu-openclash-sync disable
/etc/init.d/uu-openclash-sync stop
```

PassWall、Tailscale、SmartDNS 等其他插件不在自动联动范围内。透明代理、DNS 劫持、策略路由和多网关环境仍可能与 UU 规则冲突，建议逐项排查。

## 命令行检查

```sh
/usr/libexec/uu-official/manager.sh status
/usr/libexec/uu-official/manager.sh devices
/usr/libexec/uu-official/manager.sh start
/usr/libexec/uu-official/manager.sh stop
/usr/libexec/uu-official/manager.sh restart
/usr/libexec/uu-official/manager.sh update-monitor
```

其他常用检查：

```sh
ps w | grep '[u]uplugin'
nft list tables | grep XU_ACC
ip rule
ip route show table all
tail -n 100 /tmp/monitor.log
```

## 常见问题

### LuCI 菜单没有出现

清理缓存并重新加载 LuCI：

```sh
rm -f /tmp/luci-indexcache.*.json /tmp/luci-modulecache/*
/etc/init.d/rpcd restart
/etc/init.d/uhttpd reload
```

### 服务运行，但没有加速设备

先在 UU App 中添加路由器并开始加速。只有 UU 创建 `XU_ACC_DEVICE_<IP>_*` 规则后，状态页才会把该设备识别为正在加速。

### App 一直显示“正在匹配”

先确认目标设备规则是否存在、包计数是否增长。如果实际规则生效但 App 状态没有更新，重点检查：

- 手机和目标设备是否处于同一局域网
- 旁路由网关、DNS和策略路由是否正确
- 手机是否启用了私人 DNS、VPN、蜂窝数据辅助或代理
- 透明代理/DNS 插件是否截获了 UU 的本地发现流量

不要仅为了修复 App 文案反复清除运行状态；这会中断已经生效的加速规则并生成新的路由器注册会话。

### 重复安装或服务冲突

不要同时运行本项目、`uugamebooster` 和另一套 UU 启动脚本。安装器会停用已知旧服务，并重建网易官方 `/etc/rc.d/S99uuplugin` 链接。

## 从源码构建

将 `luci-app-uu-official` 放入 OpenWrt 源码树的 `package/` 目录：

```sh
make menuconfig
# LuCI → Applications → luci-app-uu-official
make package/luci-app-uu-official/compile V=s
```

重新生成一键安装器（Windows PowerShell）：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\build-installer.ps1
```

## 网易官方接口

- 安装脚本：`http://router.uu.163.com/api/script/install?type=openwrt`
- 监控脚本：`http://router.uu.163.com/api/script/monitor?type=openwrt`
- 核心程序：`http://router.uu.163.com/api/plugin?type=openwrt-<arch>`
- 卸载脚本：`http://router.uu.163.com/api/script/uninstall?type=openwrt`

官方接口、下载格式和闭源核心行为可能随时变化。

## 安全与隐私

- 本项目不包含或重新分发网易闭源二进制
- 本项目不会额外收集或上传用户数据
- 网易官方核心的网络行为、隐私政策和服务条款由网易负责
- 官方接口目前提供 MD5；MD5 可以发现传输损坏，但不能替代数字签名
- 在路由器上执行第三方或官方远程脚本前，请自行评估供应链风险

## 贡献

欢迎提交 Issue 和 Pull Request。报告问题时建议提供：

- 固件名称和版本
- CPU 架构
- 主路由或旁路由拓扑
- `manager.sh status` 与 `manager.sh devices` 输出
- 已脱敏的 `/tmp/monitor.log`

请勿提交路由器密码、UU 账号、UUID、公网地址或其他敏感信息。

## 许可证

本仓库自有代码使用 [MIT License](LICENSE)。通过网易接口下载的脚本和二进制不适用本仓库许可证。
