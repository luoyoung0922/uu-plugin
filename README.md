# luci-app-uu-official

一个面向 OpenWrt 24.10+ 的网易 UU 路由器插件管理界面。

本仓库只包含开源的 LuCI 管理层和服务脚本，不包含网易 UU 的闭源核心。
安装并启用服务后，程序会从网易官方分发接口下载对应架构的监控脚本和
`uuplugin` 核心。

> 本项目不是网易官方项目，与网易公司无隶属或合作关系。“网易”“UU”及
> 相关商标归其权利人所有。

## 功能

- LuCI 中启停、重启和查看运行状态
- 自动识别 `x86_64`、`aarch64`、ARM、MIPS 架构
- 使用网易官方 API 获取下载地址
- 按官方接口返回的 MD5 校验下载文件
- 使用 `procd` 管理监控进程并支持异常拉起
- 查看监控日志、刷新官方脚本、重新安装运行时
- 不把闭源二进制打包进 IPK/APK

## 支持范围

- OpenWrt/iStoreOS 24.10 或相近版本
- LuCI JavaScript 前端
- `firewall4` / nftables
- 已安装并可用的 TUN 内核模块

推荐依赖会由包管理器自动安装：`kmod-tun`、`curl`、`ca-bundle`、
BusyBox 自带的 `md5sum` 用于完整性检查。

## 编译

如果只想一键安装，不需要 OpenWrt SDK：直接把仓库里的
`uu-official-installer.run` 上传到路由器执行即可：

```sh
chmod +x /tmp/uu-official-installer.run
/tmp/uu-official-installer.run
```

安装器会检查并安装 `kmod-tun`、`curl`、`ca-bundle`，停用旧的 UU 启动方式，
写入 LuCI 管理页面并启动服务。使用 `--no-start` 可只安装不启动，使用
`--uninstall` 可移除本项目的管理层（不会删除 `/usr/sbin/uu` 中的官方运行时）。

把本仓库放入 OpenWrt 源码树：

```sh
cp -a luci-app-uu-official /path/to/openwrt/package/
cd /path/to/openwrt
make menuconfig
```

在 `LuCI -> Applications` 中选择 `luci-app-uu-official`，然后编译：

```sh
make package/luci-app-uu-official/compile V=s
```

生成的包位于 `bin/packages/.../luci/`。

## 安装后使用

LuCI 路径：`服务 -> 网易 UU`。

包安装时会注册开机启动，但 UCI 中的“启用服务”默认关闭；请在 LuCI 设置页
开启并保存，然后从状态页启动服务。

命令行：

```sh
/etc/init.d/uu-official start
/etc/init.d/uu-official stop
/etc/init.d/uu-official restart
/usr/libexec/uu-official/manager.sh status
/usr/libexec/uu-official/manager.sh update-monitor
```

运行文件保存在 `/usr/sbin/uu`，临时核心保存在 `/tmp/uu`。服务停止时不会
删除下载缓存；“重新安装运行时”会清理后重新从网易下载。

## 从网易原始脚本迁移

若设备已经通过网易原始安装脚本创建 `/etc/rc.d/S99uuplugin`，请先停止旧
监控进程并删除该启动链接，避免两套启动机制重复拉起：

```sh
for pid in $(ps w | awk '/[u]uplugin_monitor\.sh/ { print $1 }'); do kill "$pid"; done
rm -f /etc/rc.d/S99uuplugin
/etc/init.d/uu-official enable
/etc/init.d/uu-official start
```

管理器在启动时也会检测重复运行的监控进程，并拒绝启动以避免冲突。

若还安装了 `uugamebooster`/`luci-app-uugamebooster` 软件包，请先卸载它们，
不要让两个 UU 实现同时修改 nftables 规则。

## 安全说明

- 网易接口当前返回 MD5。MD5 可用于发现传输损坏，但不能替代数字签名或
  现代密码学完整性验证。
- 下载并执行的是网易提供的闭源二进制；请自行评估供应链和隐私风险。
- 本项目不会收集、代理或上传额外数据；UU 核心本身的网络行为由网易决定。
- 官方接口可能随时变更，届时需要更新管理脚本。

## 官方分发接口

- 监控脚本：`http://router.uu.163.com/api/script/monitor?type=openwrt`
- 核心程序：`http://router.uu.163.com/api/plugin?type=openwrt-<arch>`
- 卸载脚本：`http://router.uu.163.com/api/script/uninstall?type=openwrt`

## 许可证

本仓库代码使用 MIT License。下载的网易脚本和二进制不适用本仓库许可证。
