# Auto Mount Tool

macOS 自动挂载 NAS 工具。当连接到指定 WiFi 时，静默挂载指定的网络卷宗。

## 特性

- ✅ **静默挂载** — 不弹出 Finder 窗口
- ✅ **无需密码** — 首次初始化后，日常使用无需 sudo
- ✅ **智能检测** — 自动检查服务器可达性，已挂载的卷宗自动跳过
- ✅ **开机自启** — 支持 LaunchAgent 配置，开机或网络变化时自动运行
- ✅ **零依赖** — 编译后为独立可执行文件，无需安装任何依赖

## 产品需求说明 (PRD)

### 场景描述
- **局域网漫游**：用户经常带着 Mac 在外网（如公司、咖啡厅）和家庭内网之间切换，期望回到家时自动挂载 NAS。
- **复杂代理环境**：用户常驻开启代理软件（如 Clash Verge 的 TUN 模式 + Fake-IP）。这会导致系统的默认路由被接管，常规的网络高层 API 会将网络误判为“有线网络”，且内部域名（如 `nas.local`）可能被假 IP 劫持。
- **完全静默免扰**：希望挂载过程完全在后台进行，不要弹出任何 Finder 窗口，也不要在每次网络切换或开机时弹窗请求 `sudo` 密码。

### 核心功能与机制
1. **物理层网络指纹（核心突破）**：程序完全穿透 VPN TUN 虚拟网卡，直接通过底层 ARP 协议探测物理网卡（如 `en0`）连接的**真实路由器 MAC 地址（BSSID）**作为家庭网络指纹。不再依赖 Wi-Fi SSID 名称，从而完美避开了 macOS 14+ 严格的定位隐私限制，实现了**真正的零权限（免 Sudo）运行**。
2. **事件驱动无感监听**：程序自身不驻留后台。利用 macOS 原生 `launchd` 监听系统网络状态变化。当网络发生切换时，`launchd` 会极速唤醒程序。程序比对当前路由器 MAC 指纹，若不一致则立刻安全退出（零资源占用）；若一致则发起挂载。
3. **域名直连兼容**：全面兼容 `.local` 等内网域名挂载。针对 Clash Fake-IP 用户，只需在 Clash 规则中将 `.local` 加入直连（Bypass）名单，即可实现极其稳定、极速的内网挂载。

## 系统要求

- macOS 10.15+
- Xcode Command Line Tools（用于编译）

## 快速开始

### 1. 编译

```bash
cd /path/to/AutoMount
clang auto_mount.m -framework SystemConfiguration -framework Foundation -framework NetFS -fobjc-arc -o auto_mount
```

> ⚠️ 编译产物（`auto_mount`）不被 git 跟踪。重新 clone 后需要重新编译。

### 2. 首次初始化

连上家里的网络，执行初始化（获取当前路由器 MAC 地址作为家庭指纹，**不需要 sudo**）：

```bash
./auto_mount --init
```

输出示例：

```
Auto Mount Tool - Init Mode
===========================

[1] Getting current network fingerprint (Gateway MAC)...
  Current Gateway MAC: 00:11:22:33:44:55

[2] Configuring mount targets...
  Enter SMB URL (or press Enter to finish): smb://server.local/share
  Enter mount path: /Volumes/share
  ✓ Added: smb://server.local/share -> /Volumes/share
  Add another? (y/n): n
✓ Config saved to: ./auto_mount.plist
  Target Gateway MAC: 00:11:22:33:44:55
  Mount targets: 1

[DONE] Init complete! You can now run './auto_mount' seamlessly.
```

### 3. 测试运行

```bash
./auto_mount
```

输出示例：

```
Auto Mount Tool
===============

[1] Loading config...
  Target Gateway MAC: 00:11:22:33:44:55

[2] Checking network fingerprint...
  Current Gateway MAC: 00:11:22:33:44:55
  ✓ Network fingerprint matched!

[3] Checking network...
  NAS hostname: your-server.local
  ✓ Server reachable!

[4] Checking mount points...
  /Volumes/your-share-1: not mounted, mounting...
  ✓ Mounted: smb://your-server.local/your-share-1
  /Volumes/your-share-2: already mounted, skipping.

[DONE] 2/2 volumes mounted.
```

## 配置开机自动运行

### 方法一：使用 LaunchAgent（推荐）

```bash
# 创建配置文件
cat << 'EOF' > ~/Library/LaunchAgents/com.user.auto-mount.plist
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.auto-mount</string>
    <key>ProgramArguments</key>
    <array>
        <string>/path/to/auto_mount</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>WatchPaths</key>
    <array>
        <string>/Library/Preferences/SystemConfiguration</string>
    </array>
</dict>
</plist>
EOF

# 加载服务
launchctl load ~/Library/LaunchAgents/com.user.auto-mount.plist
```

### 触发条件

- **RunAtLoad**: 开机时自动运行
- **WatchPaths**: 网络配置变化时自动运行（WiFi 切换、网络重连等）

## 自定义配置

### 修改挂载目标

配置文件：`./auto_mount.plist`

使用 `--init` 重新初始化配置：

```bash
./auto_mount --init
```

或直接编辑 plist 文件：

```bash
nano ./auto_mount.plist
```

配置格式：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1-0.dtd">
<plist version="1.0">
<dict>
    <key>target_gateway_mac</key>
    <string>00:11:22:33:44:55</string>
    <key>mount_targets</key>
    <array>
        <dict>
            <key>url</key>
            <string>smb://your-nas.local/your-share</string>
            <key>path</key>
            <string>/Volumes/your-mount-point</string>
        </dict>
    </array>
</dict>
</plist>
```

> ⚠️ 建议使用 `hostname.local` 格式（如 `your-nas.local`），而非 `Hostname._smb._tcp.local` 服务发现名称，后者在部分网络环境下可能解析失败。

### 重新初始化

如果更换了 WiFi 网络，需要重新初始化：

```bash
sudo ./auto_mount --init
```

## 工作原理

### 检测流程

```
1. 加载配置文件 (./auto_mount.plist)
   ↓
2. Ping 检查 NAS 服务器是否可达
   ↓
3. 遍历挂载目标列表
   ↓
4. 检查每个挂载点是否已挂载
   ↓
5. 未挂载的卷宗 → 调用 NetFSMountURLSync 静默挂载
   ↓
6. 已挂载的卷宗 → 跳过
```

### 静默挂载实现

使用 macOS 原生的 `NetFS` 框架的 `NetFSMountURLSync` 函数：

```objc
OSStatus status = NetFSMountURLSync(
    cfURL,       // SMB URL
    NULL,        // MountPath (系统决定)
    NULL,        // User (从 Keychain 读取)
    NULL,        // Pass (从 Keychain 读取)
    NULL,        // OpenOptions
    NULL,        // MountOptions
    &mountPoints // 输出挂载点
);
```

- 传入 `NULL` 作为用户名和密码，系统会自动从 Keychain 读取已保存的凭据
- 不会弹出任何 Finder 窗口

### macOS 隐私限制处理

macOS 14+ 对 WiFi SSID 获取有严格限制。本工具采用以下方案：

1. **首次初始化**：使用 `sudo wdutil info` 获取 SSID（需要 root 权限）
2. **保存配置**：将 SSID 保存到 `./auto_mount.plist`
3. **日常运行**：通过 ping 检查服务器可达性，间接判断是否在目标网络

## 管理命令

```bash
# 查看服务状态
launchctl list | grep auto-mount

# 手动启动服务
launchctl start com.user.auto-mount

# 停止服务
launchctl stop com.user.auto-mount

# 卸载服务（开机不再自动运行）
launchctl unload ~/Library/LaunchAgents/com.user.auto-mount.plist

# 重新加载服务
launchctl unload ~/Library/LaunchAgents/com.user.auto-mount.plist
launchctl load ~/Library/LaunchAgents/com.user.auto-mount.plist
```

## 文件说明

```
AutoMount/
├── auto_mount.m            # 源代码
├── auto_mount              # 编译后的可执行文件
├── README.md               # 本文件
└── AutoMount.xcodeproj/    # Xcode 项目文件（可选）
```

### 配置文件位置

```
./auto_mount.plist    # 运行时配置（保存目标 WiFi SSID）
~/Library/LaunchAgents/com.user.auto-mount.plist  # LaunchAgent 配置
```

## 命令行参数

```bash
./auto_mount [选项]

选项：
  --init      初始化模式（需要 sudo，用于保存当前 WiFi SSID）
  --help      显示帮助信息
```

## 常见问题

### Q: 开启了 Clash TUN 模式导致挂载失败怎么办？

A: 本工具已经彻底重构了底层网络识别逻辑（MAC 地址物理探针），完全免疫 TUN 模式带来的“误判为有线网络”问题。如果您仍然挂载失败，通常是因为 Clash 的 **Fake-IP 机制劫持了内网域名**。
**解决办法**：请在 Clash 的配置文件（规则）中，加入对 `.local` 域名（或您 NAS 的具体域名）的直连（Bypass）规则。例如：`DOMAIN-SUFFIX,local,DIRECT`。

### Q: 如何更换家庭网络/目标路由器？

A: 连接到新网络后，重新运行一次免密的初始化命令即可：

```bash
./auto_mount --init
```

### Q: 挂载失败的常规检查点？

A: 检查以下几点：

1. 确认已将 NAS 访问凭据保存到 Keychain（首次在 Finder 手动连接时勾选“记住密码”）
2. 确认 NAS 服务器在线
3. 确认当前所处网络的路由器没有更换（若更换了光猫或主路由，请重新 `--init`）

### Q: 提示 "Server not reachable" 但 NAS 确实在线？

A: 可能是 mDNS 服务发现名称（如 `MyNAS._smb._tcp.local`）解析失败。这种格式依赖 SRV 记录查询，在某些网络环境下不稳定。

**解决方法**：使用主机名格式 `hostname.local`（如 `your-nas.local`）替代服务发现名称。

验证方法：

```bash
# 测试主机名是否能解析
ping -c 1 your-nas.local

# 对比测试服务发现名（可能失败）
ping -c 1 YourNAS._smb._tcp.local
```

如果主机名能通，修改 `auto_mount.m` 中的 URL 和 ping 目标，重新编译即可。

### Q: 如何添加多个挂载目标？

A: 编辑源代码中的 `getMountTargets()` 函数，添加更多 SMB URL 和挂载点，然后重新编译。

### Q: 如何完全卸载？

A:

```bash
# 1. 卸载 LaunchAgent
launchctl unload ~/Library/LaunchAgents/com.user.auto-mount.plist
rm ~/Library/LaunchAgents/com.user.auto-mount.plist

# 2. 删除配置文件
rm ./auto_mount.plist

# 3. 删除可执行文件
rm /path/to/auto_mount
```

## 技术细节

### 使用的系统框架

- **SystemConfiguration** — 网络配置检测
- **NetFS** — 网络文件系统挂载（静默挂载核心）
- **Foundation** — 基础功能

### 关键 API

```objc
// 静默挂载网络卷宗
OSStatus NetFSMountURLSync(
    CFURLRef url,
    CFURLRef mountpath,
    CFStringRef user,
    CFStringRef password,
    CFDictionaryRef open_options,
    CFDictionaryRef mount_options,
    CFArrayRef *mountpoints
);
```

## 许可证

MIT License

## 作者

郑杰

## 更新日志

### v1.2.0 (2026-04-30)

- 🔧 **优化**：优化日志行为 - 仅在异常/错误情况下记录日志，减少日志文件膨胀
- 📝 更新文档

### v1.1.0 (2026-04-20)

- 🐛 **修复**：将 SMB URL 从 `hostname._smb._tcp.local` 改为 `hostname.local` 格式，解决部分网络环境下 mDNS SRV 记录解析失败的问题
- 📝 更新文档，添加 mDNS 解析问题的排查指南

### v1.0.0 (2026-04-20)

- ✅ 初始版本
- ✅ 支持静默挂载多个 SMB 卷宗
- ✅ 支持配置文件持久化
- ✅ 支持 LaunchAgent 开机自启
- ✅ 智能检测服务器可达性

