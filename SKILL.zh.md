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

### 检测当前 WiFi SSID

**⚠️ macOS 26+ 隐私限制（实测发现）**

macOS 26 对 WiFi SSID 获取施加了严格限制：

| 方法 | 需要 sudo | macOS 26 可用性 | 备注 |
|------|-----------|-----------------|------|
| `airport -I` | ❌ | ❌ 路径可能不存在 | 旧方法 |
| `ipconfig getsummary en0` | ❌ | ❌ 返回 `<redacted>` | 隐私保护 |
| `CoreWLAN` 框架 | ❌ | ⚠️ 需要位置权限 | 需要用户授权 |
| `SCDynamicStore` | ❌ | ❌ 返回空 SSID | macOS 26 限制 |
| `wdutil info` | ✅ | ✅ 可用 | 需要 sudo |
| `networksetup` | ❌ | ⚠️ 不稳定 | 环境依赖 |

**推荐方案：Config 文件 + 首次初始化**

由于获取 WiFi SSID 需要权限，推荐使用配置文件方案：

```bash
# 首次运行（保存当前 WiFi SSID 到配置文件）
sudo ./auto_mount --init

# 后续运行（从配置文件读取 SSID，无需 sudo）
./auto_mount
```

**获取 SSID 的代码（需要 root 权限）：**
```objc
// 使用 wdutil 命令
NSString* getSSIDWithWdutil() {
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/wdutil"];
    [task setArguments:@[@"info"]];
    
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task launch];
    [task waitUntilExit];
    
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    
    // 解析 "SSID : xxx" 格式
    NSArray *lines = [output componentsSeparatedByString:@"\n"];
    for (NSString *line in lines) {
        if ([line containsString:@"SSID"]) {
            NSArray *parts = [line componentsSeparatedByString:@":"];
            if ([parts count] >= 2) {
                NSString *value = [[parts objectAtIndex:1] 
                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if ([value length] > 0 && ![value isEqualToString:@"<redacted>"]) {
                    return value;
                }
            }
        }
    }
    return nil;
}
```

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
3. **macOS 26 WiFi SSID 获取受限** — 多种方法返回 `<redacted>`，需要 sudo 或位置权限
4. **系统级任务（launchd）优于 Agent Cron** — 不依赖外部服务，开机自启，实时响应
5. **C/ObjC 语言实现最轻量** — ~20KB 二进制，无依赖，启动最快
6. **Config 文件方案** — 首次 sudo 初始化保存 SSID，后续无需密码
7. **mDNS Browse ≠ Resolve** — dns-sd -B 成功不代表主机名能解析为 IP，smbutil lookup 是可靠备用方案

## 配置文件位置建议

**推荐使用公共位置：`./auto_mount.plist`**

原因：
- sudo 运行时保存到 `/var/root/.auto_mount_config.plist`，普通用户无法读取
- 公共位置 + `0644` 权限，所有用户可读
- 只有首次 init 需要 sudo 写入

```objc
#define CONFIG_FILE @"./auto_mount.plist"

void saveConfig(NSString *ssid) {
    NSDictionary *config = @{@"target_ssid": ssid};
    [config writeToFile:CONFIG_FILE atomically:YES];
    // 设置权限为所有人可读
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0644} 
                                 ofItemAtPath:CONFIG_FILE error:nil];
}
```

## 完整 Objective-C 实现

见 AutoMount 项目：`~/Documents/Project/projects/AutoMount/`

核心功能：
- `--init` 模式：sudo 获取 SSID 保存到配置文件
- 正常模式：加载配置 → ping 检查服务器 → 静默挂载未挂载的卷宗
- 支持多个挂载目标
- LaunchAgent 开机自启 + 网络变化触发

## 编译

重新 clone 后需要重新编译：

```bash
cd ~/Documents/Project/projects/AutoMount
clang auto_mount.m -framework SystemConfiguration -framework Foundation -framework NetFS -fobjc-arc -o auto_mount
```
