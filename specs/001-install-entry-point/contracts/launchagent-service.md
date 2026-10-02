本文档规范以当前登录用户身份运行的 LaunchAgent 描述文件 `~/Library/LaunchAgents/com.user.automnt.plist` 的属性结构与生命周期契约。

# 描述文件结构示例

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.automnt</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/USERNAME/Library/Application Support/automnt/bin/automnt</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>WatchPaths</key>
    <array>
        <string>/Library/Preferences/SystemConfiguration/NetworkInterfaces.plist</string>
        <string>/Library/Preferences/SystemConfiguration/com.apple.airport.preferences.plist</string>
    </array>
    <key>StandardOutPath</key>
    <string>/Users/USERNAME/Library/Logs/automnt/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/USERNAME/Library/Logs/automnt/stderr.log</string>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
```

# 键语义与刚性约束

### 1. 事件驱动机制

- `RunAtLoad: true`：用户登录进入桌面会话时，由 `launchd` 发起首次挂载评估。
- `WatchPaths`：注册系统网络配置核心文件。一旦发生 Wi-Fi 切换、以太网插拔、VPN/Tailscale 接口建立等网络拓扑变动，系统内核立即唤醒本进程执行一次评估。
- **刚性禁止项**：**严禁配置 `StartInterval` 键**。服务不得包含固定周期轮询，严格遵守 Constitution 原则 II 与 Feature US7。

### 2. 执行体约束

- `ProgramArguments`：仅包含规范安装路径中的二进制文件绝对路径，不经过中间 shell 包装脚本，不传递任何临时参数。
- 权限上下文：以标准 GUI 用户上下文运行（`gui/<uid>`），绝不使用 Root 权限，不需要 `sudo`。

# 生命周期管理契约

### 加载与注册 (`launchctl bootstrap`)

1. 程序生成目标 plist 文件并写入 `~/Library/LaunchAgents/com.user.automnt.plist`（权限 `0644`）；
2. 获取当前用户 GUI 域 UID；
3. 执行：
```bash
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.user.automnt.plist
```

### 注销与移除 (`launchctl bootout`)

1. 卸载或重新注册时，执行：
```bash
launchctl bootout "gui/$(id -u)/com.user.automnt" 2>/dev/null || true
```
2. 删除 plist 描述文件。
