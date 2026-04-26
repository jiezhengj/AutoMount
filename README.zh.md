# Auto Mount Tool

macOS 自动挂载 NAS 工具。当连接到指定 WiFi 时，静默挂载指定的网络卷宗。

## 特性

- ✅ **静默挂载** — 不弹出 Finder 窗口
- ✅ **无需密码** — 首次初始化后，日常使用无需 sudo
- ✅ **智能检测** — 自动检查服务器可达性，已挂载的卷宗自动跳过
- ✅ **开机自启** — 支持 LaunchAgent 配置，开机或网络变化时自动运行
- ✅ **零依赖** — 编译后为独立可执行文件，无需安装任何依赖

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

首次运行需要使用 sudo 获取当前 WiFi SSID 并保存配置：

```bash
sudo ./auto_mount --init
```

输出示例：

```
Auto Mount Tool - Init Mode
===========================

[1] Getting current WiFi SSID...
  Current SSID: YourWiFi

[2] Configuring mount targets...
  Enter SMB URL (or press Enter to finish): smb://server.local/share
  Enter mount path: /Volumes/share
  ✓ Added: smb://server.local/share -> /Volumes/share
  Add another? (y/n): n
✓ Config saved to: ./auto_mount.plist
  Target SSID: YourWiFi
  Mount targets: 1

[DONE] Init complete! You can now run './auto_mount' without sudo.
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
  Target SSID: YourWiFi

[2] Checking network...
  ✓ Server reachable!

[3] Checking mount points...
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
sudo ./auto_mount --init
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
    <key>target_ssid</key>
    <string>YourWiFiName</string>
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

### Q: 为什么首次运行需要 sudo？

A: macOS 14+ 出于隐私保护，获取 WiFi SSID 需要 root 权限。首次初始化后，SSID 会保存到配置文件，后续运行无需 sudo。

### Q: 如何更换目标 WiFi？

A: 在新的 WiFi 网络下重新运行初始化：

```bash
sudo ./auto_mount --init
```

### Q: 挂载失败怎么办？

A: 检查以下几点：

1. 确认已保存过 WiFi 凭据到 Keychain（首次手动挂载时会提示保存）
2. 确认 NAS 服务器在线
3. 确认当前连接的是目标 WiFi

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

### v1.1.0 (2026-04-20)

- 🐛 **修复**：将 SMB URL 从 `hostname._smb._tcp.local` 改为 `hostname.local` 格式，解决部分网络环境下 mDNS SRV 记录解析失败的问题
- 📝 更新文档，添加 mDNS 解析问题的排查指南

### v1.0.0 (2026-04-20)

- ✅ 初始版本
- ✅ 支持静默挂载多个 SMB 卷宗
- ✅ 支持配置文件持久化
- ✅ 支持 LaunchAgent 开机自启
- ✅ 智能检测服务器可达性

