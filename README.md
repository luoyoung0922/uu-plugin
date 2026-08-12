# luci-app-uu-official

这是一个面向 OpenWrt/iStoreOS 24.10+ 的网易 UU 路由器管理插件。项目只提供 LuCI 管理层、服务管理脚本和一键安装器；UU 官方监控脚本及 `uuplugin` 核心仍从网易官方接口下载。

> 本项目不是网易官方项目，与网易没有隶属或合作关系。UU、网易及相关商标归其权利人所有。

## 已完成的功能

- LuCI 页面：服务启停、重启、启用状态和运行状态。
- 状态页：显示运行中的 PID、CPU 架构、监控脚本状态。
- 加速设备页：只展示 UU 官方 `/tmp/uu/activate_status` 确认的设备，不把普通 ARP 邻居误报为加速设备。
- 延迟检测：对 UU 已确认的设备 IP 执行 ping，并显示最近一次延迟。
- 自动识别 `x86_64`、`aarch64`、ARM、MIPS 等架构，并从官方接口下载匹配文件。
- 下载后按官方接口返回的 MD5 校验完整性。
- 保留网易官方 `S99uuplugin` 启动和守护方式，LuCI 只负责管理及展示，不替换官方进程生命周期。
- 自动停用旧的 `uugamebooster` 软件包启动方式，避免两套 UU 同时修改 nftables。
- 不把网易闭源二进制重新打包进仓库或 IPK/APK。

## 一键安装

在路由器上执行：

```sh
scp uu-official-installer.run root@192.168.10.33:/tmp/
ssh root@192.168.10.33
chmod +x /tmp/uu-official-installer.run
/tmp/uu-official-installer.run
```

安装器会检查并安装 `kmod-tun`、`curl`、`ca-bundle`，注册 LuCI 文件，启用并启动 `uu-official` 服务。安装完成后打开：

`服务 → 网易 UU`

也可以只安装不启动：

```sh
/tmp/uu-official-installer.run --no-start
```

卸载本项目管理层（保留 `/usr/sbin/uu` 和 `/tmp/uu` 中的官方运行文件）：

```sh
/tmp/uu-official-installer.run --uninstall
```

## LuCI 使用说明

进入“服务 → 网易 UU”后：

1. 在“设置”页确认“启用服务”并保存。
2. 在“状态”页查看服务是否已启用、是否运行、PID、架构和监控脚本状态。
3. “加速设备”只在 UU 官方写入激活状态后显示；没有设备时页面会明确显示“暂无 UU 已确认的加速设备”。
4. 延迟是路由器对设备 IP 的 ICMP 测量值，不代表 UU 服务器或游戏延迟。

## 命令行排障

```sh
/usr/libexec/uu-official/manager.sh status
/usr/libexec/uu-official/manager.sh devices
/usr/libexec/uu-official/manager.sh start
/usr/libexec/uu-official/manager.sh stop
/usr/libexec/uu-official/manager.sh restart
/usr/libexec/uu-official/manager.sh update-monitor
```

监控日志通常位于 `/tmp/monitor.log`，也可使用 `logread -e uu-official` 查看管理器日志。运行文件位于 `/usr/sbin/uu`，临时核心位于 `/tmp/uu`。停止服务不会删除下载缓存；执行 `update-monitor` 时会备份旧脚本后重新从网易官方接口下载。

若页面安装后没有出现，先清理 LuCI 缓存并重载服务：

```sh
rm -f /tmp/luci-indexcache.*.json /tmp/luci-modulecache/*
/etc/init.d/rpcd restart
/etc/init.d/uhttpd reload
```

安装器会保留并重建网易官方 `/etc/rc.d/S99uuplugin` 启动链接。不要在监控进程仍运行时手工删除监控脚本。

## 从源码编译

将 `luci-app-uu-official` 复制到 OpenWrt 源码树的 `package/` 目录，然后执行：

```sh
make menuconfig
# LuCI → Applications → luci-app-uu-official
make package/luci-app-uu-official/compile V=s
```

生成的包位于 `bin/packages/.../luci/`。重新生成一键安装器（Windows PowerShell）：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\build-installer.ps1
```

## 官方分发接口

- 监控脚本：`http://router.uu.163.com/api/script/monitor?type=openwrt`
- 核心程序：`http://router.uu.163.com/api/plugin?type=openwrt-<arch>`
- 卸载脚本：`http://router.uu.163.com/api/script/uninstall?type=openwrt`

官方接口可能变化；如下载失败，请先运行 `update-monitor` 并查看日志。

## 安全与隐私

- MD5 仅用于发现传输损坏，不能替代数字签名或现代密码学完整性验证。
- 执行和运行的是网易提供的闭源脚本/二进制，请自行评估供应链和隐私风险。
- 本项目不会额外收集、代理或上传数据；UU 核心自身的网络行为由网易决定。
- 请勿在公开渠道泄露路由器 root 密码，并在安装后修改默认密码。

## 许可证

本仓库自有代码使用 MIT License。网易下载的脚本和闭源二进制不适用本仓库许可证。
