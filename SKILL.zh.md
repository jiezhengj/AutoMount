---
name: macos-silent-smb-mount
version: 1.1.0
description: "macOS 静默挂载 SMB 共享的最佳实践：mount_smbfs 的局限性、NetFSMountURLSync 解决方案、macOS 26 隐私限制处理"
metadata:
  requires:
    bins:
      - clang
  prerequisite_skills: []
---

# macOS 静默挂载 SMB 共享

## 问题背景

macOS（特别是 26+）不会在开机后自动挂载局域网 SMB 卷宗，即使 NAS 在线且已保存凭据。需要在脚本或自动化流程中实现静默挂载（不弹出 Finder 窗口）。

## mount_smbfs 的局限性（实测发现）

**❌ mount_smbfs 不能直接从 Keychain 读取密码**

```bash
# 这会失败！
mount_smbfs -N //user@server/share /Volumes/xxx
# 输出：Authentication error
```

**原因：**
- mount_smbfs 需要从 `~/Library/Preferences/nsmb.conf` 读取密码
- 或者交互式输入密码
- **它不能直接从 macOS Keychain 读取凭据**

**mount_smbfs 的 `-o nobrowse` 选项：**
```bash
# 可以隐藏挂载点（不显示在桌面/Finder 侧边栏）
mount_smbfs -o nobrowse //user@server/share /Volumes/xxx
```

**结论：mount_smbfs 不适合自动化场景**，因为需要明文密码配置文件或交互式输入。

## 正确方案：NetFSMountURLSync API

**✅ 使用 NetFS 框架的 NetFSMountURLSync 函数**

```c
#include <CoreFoundation/CoreFoundation.h>
#include <NetFS/NetFS.h>

int main() {
    CFURLRef url = CFURLCreateWithBytes(NULL,
        (UInt8*)"smb://server.local/share",
        30, kCFStringEncodingUTF8, 0);
    
    CFArrayRef mountPoints = NULL;
    OSStatus status = NetFSMountURLSync(
        url,
        NULL,  // MountPath（自动选择）
        NULL,  // User（nil = 自动从 Keychain 读取）
        NULL,  // Pass（nil = 自动从 Keychain 读取）
        NULL,  // OpenOptions
        NULL,  // MountOptions
        &mountPoints
    );
    
    if (mountPoints) CFRelease(mountPoints);
    CFRelease(url);
    
    return (status == noErr) ? 0 : 1;
}
```

**优势：**
- ✅ 直接从 Keychain 读取凭据（nil 参数触发）
- ✅ 完全静默，不弹出 Finder 窗口
- ✅ 不需要密码配置文件
- ✅ 适合自动化场景

**编译：**
```bash
clang mount_nas.c -framework CoreFoundation -framework NetFS -o mount_nas
```

## 自动化挂载需求清单

实现以下功能的完整方案：

1. **开机自动检测** — launchd 开机启动
2. **WiFi SSID 过滤** — 只在指定 WiFi 下挂载
3. **连入指定 WiFi 自动挂载** — 事件触发
4. **已挂载不再尝试** — 状态检测

### 推荐架构：launchd + Shell 脚本

```
launchd (开机自启 + 事件触发)
    └── check_and_mount.sh
        ├── mount | grep 检测是否已挂载
        ├── airport -I 获取当前 WiFi SSID
        ├── 判断是否是指定 SSID
        └── 调用 mount_nas（NetFSMountURLSync 静默挂载）
```

### 识别当前局域网环境 (物理探测)

**⚠️ 痛点：macOS 隐私限制与 VPN 路由劫持（实测发现）**

1. **SSID 隐私限制**：macOS 14+ 严格限制 SSID 获取，非系统应用获取到的通常是 `<redacted>`。以往使用 `wdutil info` 强行获取需要 `sudo` 权限，严重影响静默自动化的体验。
2. **TUN 模式误导**：当使用 Clash TUN 模式等全局 VPN 时，系统默认路由被劫持到虚拟网卡（`utun`），导致 macOS 高层网络 API 误认为当前在使用“有线网络”，从而使得基于“Wi-Fi 状态检测”的逻辑直接崩盘。

**推荐终极方案：物理层网关 MAC 指纹（免 Sudo）**

既然高层网络 API 受到隐私和 VPN 的双重干扰，我们选择“降维探测”：直接下探到数据链路层（二层网络），询问物理网卡（如 `en0`）：“你直接连接的那个物理路由器的 MAC 地址是多少？”

```bash
# 首次运行（记录当前物理路由器的 MAC 地址作为家庭指纹）
./auto_mount --init

# 后续运行（比对当前路由器的 MAC，吻合则挂载）
./auto_mount
```

**获取 MAC 指纹的核心逻辑（全程无需 root）：**
```objc
// 1. 获取物理网关IP (使用系统底层 DHCP 状态，不受 TUN 默认路由影响)
NSString* getPhysicalGatewayIP() {
    // 轮询物理网卡 en0, en1 等
    // 对应命令：/usr/sbin/ipconfig getoption en0 router
    // 返回真实的网关局域网 IP，如 192.168.1.1
}

// 2. 根据 IP 获取网关 MAC 地址 (二层 ARP 协议)
NSString* getMACAddressForIP(NSString *ip) {
    // 对应命令：/usr/sbin/arp -n 192.168.1.1
    // 解析输出获取 MAC 地址，例如 00:11:22:33:44:55
}
```
**优势：**
- ✅ **完全免 `sudo`**：这些基础诊断命令对所有用户开放。
- ✅ **100% 免疫 VPN 劫持**：ARP 和物理 DHCP 状态处于网络栈底层，Clash 的三层 TUN 隧道无法伪装或篡改物理路由器的 MAC。

### 检测是否已挂载

```bash
if mount | grep -q "/Volumes/nas_share"; then
    echo "已挂载"
fi
```

### launchd 事件触发配置

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.mount-nas</string>
    <key>ProgramArguments</key>
    <array>
        <string>/path/to/check_and_mount.sh</string>
    </array>
    <key>WatchPaths</key>
    <array>
        <string>/Library/Preferences/SystemConfiguration</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
```

## 方案选择指南

| 场景 | 推荐方案 |
|------|----------|
| 静默挂载单个 SMB 共享 | C 命令行工具 + NetFSMountURLSync |
| 开机自动检测 | launchd RunAtLoad |
| WiFi 变化触发 | launchd WatchPaths 或守护进程 |
| 需要 GUI 配置管理 | 完整的 Swift macOS 应用（如 AutoMount 项目） |

## 架构选择：系统级 vs Agent Cron

**关键发现：系统级任务应使用 launchd，而非 Agent Cron**

| 方案 | 依赖 Agent | 响应速度 | 适用场景 |
|------|-----------|----------|----------|
| Agent Cron | ✅ 依赖 | 分钟级 | 需要 AI 判断、消息通知 |
| launchd | ❌ 不依赖 | 秒级 | 系统级任务、实时响应 |
| 守护进程 | ❌ 不依赖 | 毫秒级 | 高性能实时监控 |

**NAS 自动挂载适合系统级方案的原因：**
- ✅ 需要开机自启
- ✅ 需要实时响应 WiFi 变化
- ✅ 不需要 AI 逻辑
- ✅ 不依赖外部服务

**Agent Cron 更适合：**
- 需要复杂判断逻辑
- 需要调用 AI 能力
- 需要发送消息通知
- 任务频率不需要太高

## mDNS 解析失败排查（2026-04-20 实测）

**问题现象：** `NAS_HOSTNAME._smb._tcp.local` 无法解析，`ping` 和 `nslookup` 都失败，但 NAS 实际在线。

**排查步骤：**
```bash
# 1. 确认 mDNS 能发现服务（Browse 成功不代表 Resolve 成功）
dns-sd -B _smb._tcp local.

# 2. 用 smbutil 直接查询 IP（绕过 mDNS DNS 解析）
smbutil lookup NAS_HOSTNAME
# 输出：IP address of NAS_HOSTNAME: 192.168.1.100

# 3. 用 IP 地址验证连通性
ping 192.168.1.100
```

**根因分析：**
- mDNS 有两个阶段：Browse（发现服务）和 Resolve（解析为 IP）
- Browse 可以成功，但 Resolve 可能失败
- 常见原因：有线网络多播路由问题、防火墙阻止 UDP 5353、DNS 配置优先级问题

**解决方案 — smbutil lookup：**
```bash
# 获取 SMB 服务器 IP
SERVER_IP=$(smbutil lookup NAS_HOSTNAME 2>/dev/null | grep "IP address" | awk '{print $NF}')
if [ -n "$SERVER_IP" ]; then
    ping -c 1 -t 2 "$SERVER_IP"
fi
```

**在 auto_mount.m 中的改进方案：**
```objc
// 原始：直接 ping 主机名（mDNS 失败则整体失败）
ping -c 1 -t 2 NAS_HOSTNAME._smb._tcp.local

// 改进：先尝试主机名，失败后用 smbutil lookup 获取 IP
NSString* resolveServerIP(NSString *hostname) {
    // 先尝试 ping 主机名
    // 如果失败，用 smbutil lookup 获取 IP
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/smbutil"];
    [task setArguments:@[@"lookup", hostname]];
    // ... 解析输出获取 IP
}
```

**注意：** NetFSMountURLSync 传入 SMB URL 时，系统内部也会做解析。如果 mDNS 不通，建议把 URL 里的主机名也换成 IP：
```objc
// 原始
smb://NAS_HOSTNAME._smb._tcp.local/nas_share
// 备用
smb://192.168.1.100/nas_share
```
但需注意 Keychain 凭据是按服务器名存储的，用 IP 可能需要重新保存凭据。

## 关键发现

1. **NetFSMountURLSync 是唯一可靠的静默挂载方案** — 直接从 Keychain 读取凭据，不弹窗
2. **mount_smbfs 不能从 Keychain 读取** — 必须提供明文密码或配置文件
3. **物理层 MAC 探测优于高层网络 API** — 完美绕过 macOS 14+ SSID 限制和 VPN TUN 模式导致的系统级网络类型误判，且无需 `sudo`
4. **系统级任务（launchd）优于 Agent Cron** — 不依赖外部服务，开机自启，实时响应，不一致则秒级退出（0 开销）
5. **C/ObjC 语言实现最轻量** — ~20KB 二进制，无依赖，启动最快
6. **Config 文件方案** — 首次初始化保存物理网关 MAC 指纹，全程免密
7. **mDNS Browse ≠ Resolve** — dns-sd -B 成功不代表主机名能解析为 IP，smbutil lookup 是可靠备用方案

## 配置文件位置建议

**推荐使用公共位置：`./auto_mount.plist`**

原因：
- sudo 运行时保存到 `/var/root/.auto_mount_config.plist`，普通用户无法读取
- 公共位置 + `0644` 权限，所有用户可读
- 只有首次 init 需要 sudo 写入

```objc
#define CONFIG_FILE @"./auto_mount.plist"

void saveConfig(NSString *fingerprint) {
    NSDictionary *config = @{@"target_gateway_mac": fingerprint};
    [config writeToFile:CONFIG_FILE atomically:YES];
    // 设置权限为所有人可读
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0644} 
                                 ofItemAtPath:CONFIG_FILE error:nil];
}
```

## 完整 Objective-C 实现

见 AutoMount 项目：`~/Documents/Project/projects/AutoMount/`

核心功能：
- `--init` 模式：获取物理网关 MAC 地址作为指纹保存到配置文件（免 sudo）
- 正常模式：加载配置 → 比对指纹 → 不一致立刻退出 → 一致则 ping 检查服务器 → 静默挂载未挂载的卷宗
- 支持多个挂载目标
- LaunchAgent 开机自启 + 网络变化触发

## 编译

重新 clone 后需要重新编译：

```bash
cd ~/Documents/Project/projects/AutoMount
clang auto_mount.m -framework SystemConfiguration -framework Foundation -framework NetFS -fobjc-arc -o auto_mount
```
