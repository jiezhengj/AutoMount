# 核心架构与决策模型

在 macOS 自动化流程中挂载网络存储卷宗时，必须避开高层阻塞 API 与权限陷阱，遵循确定性技术路线：

```mermaid
flowchart TD
    Start["触发网络挂载评估"] --> CheckGW["物理二层网关探测\n(ipconfig + ARP)"]
    CheckGW --> HotspotFilter{"是否属于排除网关\n(如 172.20.10.1 热点)?"}
    HotspotFilter -- 是 --> ExitSilence["静默退出 (保护蜂窝流量)"]
    HotspotFilter -- 否 --> RouteMatch{"匹配网络策略 (Profiles)"}
    
    RouteMatch -- "局域网 MAC 吻合" --> HasTargets{"是否包含挂载目标?"}
    HasTargets -- "否 (排他门牌)" --> Done["阻断后续策略，静默退出"]
    HasTargets -- "是" --> CheckMount["MNT_NOWAIT 内核挂载表检查"]
    RouteMatch -- "异地节点可达" --> ProbeRetry["Tailscale 握手重试窗口"]
    ProbeRetry --> CheckMount
    RouteMatch -- "无规则匹配" --> ExitSilence
    
    CheckMount --> SourceAudit{"已挂载且同源?"}
    SourceAudit -- 是 --> Done["保持挂载，退出"]
    SourceAudit -- "源不符/失效" --> ForceUnmount["3秒超时强制解挂断路器"]
    ForceUnmount --> NetFSMount["NetFSMountURLSync 静默挂载"]
    SourceAudit -- 未挂载 --> NetFSMount
    
    NetFSMount --> IndexProtect["注入 .metadata_never_index\n执行 mdutil -i off"]
    IndexProtect --> Done
```

## 网络排他门牌机制 (Exclusion Gatekeeper)

* **空目标截断设计**：当策略路由配置中某个高优先级策略（如 `home_lan`）的 `targets` 声明为空数组 `[]` 时，该策略即作为网络排他门牌运作。
* **确定性路由截断**：一旦物理网关 MAC 命中该策略，引擎完成 0 个挂载任务后立即终止后续策略评估，从架构上彻底阻断低优先级异地策略（如 Tailscale）被误触发；当设备物理离开该网络时，网关 MAC 指纹失效，流量与挂载逻辑自然降级流转至后续异地策略。

## 挂载 API 的确定性选型

* **禁止使用 `mount_smbfs`**：该命令无法直接读取 macOS 钥匙串 (Keychain)，强制要求明文密码配置文件或交互输入，且高版本 macOS 中容易产生权限弹窗。
* **强制使用 `NetFSMountURLSync`**：系统级 C 接口，传入 `nil` 凭据参数时自动无缝唤起钥匙串静默鉴权，不产生任何访达窗口或交互请求。

## 网络拓扑探测的抗干扰选型

* **高层 Wi-Fi API 的局限**：自 macOS 14 起，CoreWLAN 读取 SSID 受到严格权限隔离；且当系统运行全局 VPN（如 TUN 虚拟网卡）时，系统网络栈默认路由被劫持，导致高层网络状态判断失效。
* **物理二层 ARP 网关指纹**：通过遍历物理接口（`en0` 等）并读取 DHCP 路由器 IP，再通过二层 ARP 表获取路由器的物理 MAC 地址。该机制完全穿透 TUN 隧道，100% 反映真实接入的物理硬件，且完全免 `sudo`。


# 生产级核心代码模式 (Swift)

## 钥匙串免密静默挂载范式

通过系统 `NetFS` 框架直接挂载，不弹出访达窗口：

```swift
import Foundation
import NetFS

func mountSMBVolumeSilently(urlString: String) -> Bool {
    guard let url = CFURLCreateWithString(kCFAllocatorDefault, urlString as CFString, nil) else {
        return false
    }
    
    var mountPoints: Unmanaged<CFArray>?
    // 关键：User、Password 均传 nil，强制底层读取系统 Keychain
    let status = NetFSMountURLSync(
        url,
        nil,
        nil,
        nil,
        nil,
        nil,
        &mountPoints
    )
    
    if let points = mountPoints {
        points.release()
    }
    
    return status == noErr
}
```

## 内核挂载表非阻塞扫描 (防假死核心)

严禁在远程网络卷宗可能断网失效时使用 `FileManager.default.fileExists` 或 POSIX `stat()`，否则会导致调用线程进入内核级等待并触发系统彩虹球假死。必须使用 `getfsstat` 配合 `MNT_NOWAIT` 标志位：

```swift
import Darwin

struct ActiveMountRecord {
    let mountPath: String
    let sourceURL: String
}

func queryActiveKernelMounts() -> [ActiveMountRecord] {
    let count = getfsstat(nil, 0, MNT_NOWAIT)
    guard count > 0 else { return [] }
    
    var buffer = [statfs](repeating: statfs(), count: Int(count))
    let actualCount = buffer.withUnsafeMutableBufferPointer { ptr in
        getfsstat(ptr.baseAddress, count * Int32(MemoryLayout<statfs>.size), MNT_NOWAIT)
    }
    
    var results: [ActiveMountRecord] = []
    for i in 0..<Int(actualCount) {
        let entry = buffer[i]
        let path = withUnsafePointer(to: entry.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let source = withUnsafePointer(to: entry.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        results.append(ActiveMountRecord(mountPath: path, sourceURL: source))
    }
    return results
}
```

## 失效挂载的超时熔断与强制清理

当网络环境改变导致已有挂载点变为“僵死”状态时，必须施加严格的 3 秒超时限制，采用两级强退机制：

```swift
import Foundation
import Darwin

func forceUnmountStaleVolume(at mountPath: String, timeout: Double = 3.0) -> Bool {
    let group = DispatchGroup()
    var success = false
    
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        // 第一阶段：优雅强制卸载
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        task.arguments = ["unmount", "force", mountPath]
        try? task.run()
        task.waitUntilExit()
        
        if task.terminationStatus == 0 {
            success = true
        } else {
            // 第二阶段：POSIX 内核层强制解挂
            success = (unmount(mountPath, MNT_FORCE) == 0)
        }
        group.leave()
    }
    
    let result = group.wait(timeout: .now() + timeout)
    return result == .success && success
}
```

## Spotlight 检索防护与移动热点保护

挂载成功后必须立即执行元数据检索屏蔽，避免远端大容量磁盘检索造成系统发热与网络卡顿：

```swift
import Foundation

func protectVolumeFromSpotlight(mountPath: String) {
    let flagFile = (mountPath as NSString).appendingPathComponent(".metadata_never_index")
    if !FileManager.default.fileExists(atPath: flagFile) {
        FileManager.default.createFile(atPath: flagFile, contents: nil)
    }
    
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/mdutil")
    task.arguments = ["-i", "off", mountPath]
    try? task.run()
    task.waitUntilExit()
}
```

## 物理网络拓扑与 ARP 硬件提取

绕过 TUN 路由劫持，直探物理链路层：

```swift
import Foundation
import SystemConfiguration

func getPhysicalGatewayIP() -> (ip: String, interface: String)? {
    guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return nil }
    for iface in interfaces {
        guard let name = SCNetworkInterfaceGetBSDName(iface) as String?, name.starts(with: "en") else { continue }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
        task.arguments = ["getoption", name, "router"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let ip = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !ip.isEmpty {
            return (ip, name)
        }
    }
    return nil
}

func getGatewayMAC(for ip: String) -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
    task.arguments = ["-n", ip]
    let pipe = Pipe()
    task.standardOutput = pipe
    try? task.run()
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else { return nil }
    
    let pattern = "([0-9a-fA-F]{1,2}(?::[0-9a-fA-F]{1,2}){5})"
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
          let range = Range(match.range(at: 1), in: output) else {
        return nil
    }
    return String(output[range]).lowercased()
}
```


# 系统级常驻自动化规范 (LaunchAgent)

不同于依赖上层轮询的 Cron 机制，macOS 原生网络监听通过 launchd 的 `WatchPaths` 订阅系统网络配置目录，实现零内存常驻、秒级事件唤醒。

## 描述文件配置标准 (`~/Library/LaunchAgents/com.user.auto-mount.plist`)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.auto-mount</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/USERNAME/Library/Application Support/AutoMount/auto_mount</string>
    </array>
    <key>WatchPaths</key>
    <array>
        <string>/Library/Preferences/SystemConfiguration</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/com.user.auto-mount.stdout.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/com.user.auto-mount.stderr.log</string>
</dict>
</plist>
```

## 现代注册与生命周期管理命令

在 macOS 13+ / 26+ / 27+ 环境中，弃用已废弃的 `launchctl load / unload`，采用现代 `bootstrap / bootout` 子命令：

```bash
# 获取当前控制台用户 UID
UID=$(id -u)

# 卸载旧服务 (若存在)
launchctl bootout "gui/${UID}/com.user.auto-mount" 2>/dev/null || true

# 注册并加载服务
launchctl bootstrap "gui/${UID}" ~/Library/LaunchAgents/com.user.auto-mount.plist

# 验证服务当前运行状态
launchctl list | grep com.user.auto-mount
```


# 故障诊断与边缘场景排障手册

## 异地 WireGuard / Tailscale 握手延迟

* **现象**：刚切换至外网时，Tailscale 节点已激活，但首次挂载偶发超时失败。
* **原因**：WireGuard 隧道建立需要数十毫秒至数百毫秒的协商握手期。
* **解决方案**：引入轻量重试窗口，在主机可达性探测阶段设置 3 次探测重试（每次间隔 1.0 秒），捕获握手就绪时刻后再发起 NetFS 调用。

## 局域网 mDNS 解析不稳定

* **现象**：`smb://server.local/share` 偶发无法解析，但主机实际在线。
* **排查手段**：
  ```bash
  # 1. 检查服务宣告状态
  dns-sd -B _smb._tcp local.

  # 2. 绕过 mDNS 查询直连 IP
  smbutil lookup server
  ```
* **容灾方案**：在配置中使用静态主机名或固定 IP 替代单点 mDNS 广播，或在策略中维护备用 IP 回退列表。

# CLI 控制层与交互架构设计

## 一站式配置中心与正交子命令协同模型

AutoMount CLI 在架构设计上融合了经典 UNIX 正交哲学与现代交互式控制台美学：

* **底层正交可脚本化**：`--install`、`--uninstall`、`--status` 作为独立顶级子命令存在，具备确定性与免交互特性，便于自动化运维脚本与 CI/CD 流程调用。
* **高层聚合控制中心**：`--config` 作为一站式交互控制面板，直接展示后台守护进程的运行时状态（`gui/<uid>`），并将服务安装、重载、查看与卸载作为子菜单纳入统一管理，降低日常维护认知成本。
* **首次配置闭环**：`--init` 将生成配置文件与注册 LaunchAgent 守护服务合为四步一体的完整闭环，消除“配置已完成但后台未部署”的体验断层。
* **防御性参数拦截**：采用严格的命令行参数解析，任何未知参数均立即终止并打印标准使用规范，杜绝参数拼写错误导致误触发网络挂载与解挂操作。

## 零依赖原生国际化 (i18n) 架构

* **系统语言自适应**：优先检测 macOS 系统的 `Locale.preferredLanguages`，在非中文系统下默认自适应为英文界面。
* **环境变量控制**：支持通过 `AUTO_MOUNT_LANG=zh|en` 环境变量对运行期界面语言进行显式覆写与测试。
* **轻量双语分发引擎**：在纯 Swift 单文件内通过内置映射函数分发，不引入外部 `.strings` 依赖，保证跨机器运行的自包含性与便携性。
