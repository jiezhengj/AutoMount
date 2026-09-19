#!/usr/bin/env swift
// auto_mount.swift
// 自动挂载 NAS 工具 (macOS 27 多网络策略路由与现代化交互版 - 2.0)
//
// 核心架构与特性：
// 1. 多策略优先级路由 (Profiles)：本地局域网 (local_lan) 优先直连；离开局域网自动降级至远程互联 (remote_network / Tailscale / WireGuard / 域名 / IP)。
// 2. 失效挂载与源切换的超时强制清理 (Strategy B)：
//    - Darwin 原生 MNT_NOWAIT 内核挂载表非阻塞查询，杜绝 stat() 阻塞与系统彩虹球假死。
//    - 自动比对挂载源同源性，带 3 秒严格超时熔断机制 (diskutil unmount force + POSIX MNT_FORCE)。
// 3. Tailscale 握手就绪延迟应对机制 (Retry Window)：
//    - 探测阶段提供轻量重试窗口（默认 3 次，间隔 1.0 秒），捕获 WireGuard 握手就绪时刻。
// 4. 蜂窝热点流量与 Spotlight 索引防护：
//    - 挂载后自动执行 mdutil -i off 并写入 .metadata_never_index，彻底屏蔽 Spotlight 对该远程卷宗的元数据检索。
//    - 策略支持 exclude_gateway_ips，默认过滤 iPhone 个人热点网关 (172.20.10.1)。
// 5. 现代化交互与全自动动态嗅探：
//    - 纯 Swift 原生 ANSI Raw 模式交互式复选框 (Space 勾选、Enter 提交、a 全选、k/j 上下移动)；
//    - 动态扫描内核已挂载的 SMB 共享卷宗供勾选；
//    - 动态读取 Tailscale 节点列表供单选，并自动批量映射远程 MagicDNS / IP 挂载目标；
//    - 提供 --config 日常配置管理功能，日常增删共享点无需推倒重来。

import Foundation
import SystemConfiguration
import NetFS
import Darwin

// MARK: - 基础辅助函数与国际化 (i18n)

var isEnglish: Bool {
    if let envLang = ProcessInfo.processInfo.environment["AUTO_MOUNT_LANG"]?.lowercased() {
        if envLang.starts(with: "en") { return true }
        if envLang.starts(with: "zh") { return false }
    }
    if let preferred = Locale.preferredLanguages.first?.lowercased() {
        if preferred.starts(with: "zh") { return false }
        return true
    }
    if let lang = ProcessInfo.processInfo.environment["LANG"]?.lowercased() {
        if lang.starts(with: "zh") { return false }
    }
    return true
}

func tr(_ zh: String, _ en: String) -> String {
    return isEnglish ? en : zh
}

// 获取可执行文件所在目录
func getAppDir() -> URL {
    let exeURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    return exeURL.deletingLastPathComponent()
}

// 写入日志（带时间戳）
func writeLog(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let timestamp = formatter.string(from: Date())
    let logLine = "[\(timestamp)] \(message)\n"
    let logURL = getAppDir().appendingPathComponent("auto_mount.log")

    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        if let data = logLine.data(using: .utf8) {
            handle.write(data)
        }
        try? handle.close()
    } else {
        try? logLine.write(to: logURL, atomically: true, encoding: .utf8)
    }
}

// 配置文件路径
func getConfigURL() -> URL {
    return getAppDir().appendingPathComponent("auto_mount.plist")
}

// 执行外部命令辅助函数
@discardableResult
func runCommand(executable: String, arguments: [String]) -> (status: Int32, stdout: String, stderr: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    do {
        try process.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let outStr = String(data: outData, encoding: .utf8) ?? ""
        let errStr = String(data: errData, encoding: .utf8) ?? ""
        return (process.terminationStatus, outStr, errStr)
    } catch {
        return (-1, "", error.localizedDescription)
    }
}

// MARK: - 版本与数据结构定义

let autoMountVersion = "2.4.1"
let githubRepo = "jiezhengj/AutoMount"

struct MatchRule: Codable {
    var type: String             // "gateway_mac" 或 "probe_host"
    var value: String            // 网关 MAC 地址 或 探测主机 IP/域名
    var retryCount: Int?         // 探测重试次数 (默认 3)
    var retryInterval: Double?   // 探测重试间隔秒数 (默认 1.0)

    enum CodingKeys: String, CodingKey {
        case type
        case value
        case retryCount = "retry_count"
        case retryInterval = "retry_interval"
    }
}

struct MountTarget: Codable {
    var url: String
    var mountPath: String

    enum CodingKeys: String, CodingKey {
        case url
        case mountPath = "mount_path"
    }
}

struct NetworkProfile: Codable {
    var id: String
    var description: String?
    var match: MatchRule
    var excludeGatewayIPs: [String]?
    var preventSpotlightIndex: Bool?
    var targets: [MountTarget]

    enum CodingKeys: String, CodingKey {
        case id
        case description
        case match
        case excludeGatewayIPs = "exclude_gateway_ips"
        case preventSpotlightIndex = "prevent_spotlight_index"
        case targets
    }
}

struct AutoMountConfig: Codable {
    var version: String
    var updateChannel: String?                 // "off" (默认), "notify", "auto"
    var lastUpdateCheckTimestamp: Double?     // 24小时冷却时间戳
    var lastNotifiedVersion: String?          // 单版本仅提醒 1 次防打扰
    var profiles: [NetworkProfile]

    enum CodingKeys: String, CodingKey {
        case version
        case updateChannel = "update_channel"
        case lastUpdateCheckTimestamp = "last_update_check_timestamp"
        case lastNotifiedVersion = "last_notified_version"
        case profiles
    }
}

// MARK: - 配置文件原地无损自动升舱 (In-Place Schema Auto-Migration)

func migrateConfigIfNeeded(config: inout AutoMountConfig) -> Bool {
    var modified = false
    if config.version != autoMountVersion {
        config.version = autoMountVersion
        modified = true
    }
    if config.updateChannel == nil {
        config.updateChannel = "off"
        modified = true
    }
    if modified {
        saveConfig(config)
        print(tr("✓ 配置文件已自动平滑升级至 v\(autoMountVersion) 格式规范",
                 "✓ Configuration automatically upgraded to v\(autoMountVersion) schema"))
        writeLog("Configuration auto-migrated to v\(autoMountVersion)")
    }
    return modified
}

// 加载配置并按需执行原地无损升舱
func loadConfig() -> AutoMountConfig? {
    let configURL = getConfigURL()
    guard let data = try? Data(contentsOf: configURL) else { return nil }
    let decoder = PropertyListDecoder()
    guard var config = try? decoder.decode(AutoMountConfig.self, from: data) else { return nil }
    _ = migrateConfigIfNeeded(config: &config)
    return config
}

// 自动同步配置到 LaunchAgent 运行时目录（若已安装）
func syncConfigToInstalledDirIfNeeded() {
    let installDir = getInstalledDir()
    let dstURL = installDir.appendingPathComponent("auto_mount.plist")
    if FileManager.default.fileExists(atPath: dstURL.path) {
        let srcURL = getConfigURL()
        if FileManager.default.fileExists(atPath: srcURL.path) {
            try? FileManager.default.removeItem(at: dstURL)
            try? FileManager.default.copyItem(at: srcURL, to: dstURL)
            print(tr("✓ 已同步最新配置至后台守护服务: \(dstURL.path)",
                     "✓ Synchronized updated configuration to LaunchAgent runtime: \(dstURL.path)"))
            writeLog("Synchronized configuration to \(dstURL.path)")
        }
    }
}

// 保存 2.0 配置
func saveConfig(_ config: AutoMountConfig) {
    let configURL = getConfigURL()
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .xml
    do {
        let data = try encoder.encode(config)
        try data.write(to: configURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: configURL.path)
        print(tr("✓ 配置已即时保存至: \(configURL.path)",
                 "✓ Config saved to: \(configURL.path)"))
        syncConfigToInstalledDirIfNeeded()
    } catch {
        fputs("✗ Failed to save config: \(error.localizedDescription)\n", stderr)
        writeLog("Failed to save config: \(error.localizedDescription)")
    }
}

// MARK: - 网络硬件探测 (穿透 TUN 隧道与 ARP 解析)

func getPhysicalBSDInterfaces() -> [String] {
    let cfInterfaces = SCNetworkInterfaceCopyAll()
    let list = cfInterfaces as [AnyObject]
    var names: [String] = []
    for item in list {
        let iface = item as! SCNetworkInterface
        if let bsd = SCNetworkInterfaceGetBSDName(iface) {
            let name = bsd as String
            if name.starts(with: "en") {
                names.append(name)
            }
        }
    }
    return names.isEmpty ? ["en0", "en1", "en2", "en3", "en4", "en5"] : names
}

struct GatewayInfo {
    let ip: String
    let interface: String
}

func getPhysicalGatewayInfo() -> GatewayInfo? {
    let interfaces = getPhysicalBSDInterfaces()
    for iface in interfaces {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
        task.arguments = ["getoption", iface, "router"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                if let output = String(data: data, encoding: .utf8) {
                    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return GatewayInfo(ip: trimmed, interface: iface)
                    }
                }
            }
        } catch {
            continue
        }
    }
    return nil
}

func queryARPCache(for ip: String) -> String? {
    let arp = Process()
    arp.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
    arp.arguments = ["-n", "-a"]
    let pipe = Pipe()
    arp.standardOutput = pipe
    arp.standardError = Pipe()
    do {
        try arp.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        arp.waitUntilExit()
        guard arp.terminationStatus == 0 else { return nil }
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        let pattern = "\\(\\Q" + ip + "\\E\\)\\s+at\\s+([0-9a-fA-F:]+)\\s+on"
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
           let macRange = Range(match.range(at: 1), in: output) {
            let mac = String(output[macRange]).lowercased()
            if !mac.contains("incomplete") {
                return mac
            }
        }
    } catch {
        return nil
    }
    return nil
}

func getMACAddress(for ip: String, interface: String? = nil) -> String? {
    guard !ip.isEmpty else { return nil }
    if let cachedMAC = queryARPCache(for: ip) {
        return cachedMAC
    }
    let ping = Process()
    ping.executableURL = URL(fileURLWithPath: "/sbin/ping")
    var args = ["-c", "1", "-t", "1"]
    if let iface = interface {
        args.append(contentsOf: ["-b", iface])
    }
    args.append(ip)
    ping.arguments = args
    ping.standardOutput = Pipe()
    ping.standardError = Pipe()
    try? ping.run()
    ping.waitUntilExit()

    Thread.sleep(forTimeInterval: 0.1)
    return queryARPCache(for: ip)
}

func getCurrentNetworkFingerprint() -> String? {
    guard let gatewayInfo = getPhysicalGatewayInfo() else { return nil }
    return getMACAddress(for: gatewayInfo.ip, interface: gatewayInfo.interface)
}

func extractHost(from string: String) -> String {
    var clean = string.trimmingCharacters(in: .whitespacesAndNewlines)
    if clean.hasPrefix("smb://") {
        clean = String(clean.dropFirst(6))
    } else if clean.hasPrefix("//") {
        clean = String(clean.dropFirst(2))
    }
    if let atIndex = clean.firstIndex(of: "@") {
        clean = String(clean[clean.index(after: atIndex)...])
    }
    if let slashIndex = clean.firstIndex(of: "/") {
        clean = String(clean[..<slashIndex])
    }
    if let colonIndex = clean.firstIndex(of: ":") {
        clean = String(clean[..<colonIndex])
    }
    return clean.lowercased()
}

func probeHostWithRetries(host: String, retries: Int = 3, interval: Double = 1.0) -> Bool {
    let cleanHost = extractHost(from: host)
    for attempt in 1...retries {
        let ping = Process()
        ping.executableURL = URL(fileURLWithPath: "/sbin/ping")
        ping.arguments = ["-c", "1", "-t", "1", cleanHost]
        ping.standardOutput = Pipe()
        ping.standardError = Pipe()
        do {
            try ping.run()
            ping.waitUntilExit()
            if ping.terminationStatus == 0 {
                return true
            }
        } catch {
            // ignore
        }
        if attempt < retries {
            Thread.sleep(forTimeInterval: interval)
        }
    }
    return false
}

// MARK: - 内核非阻塞挂载表快照与断网失效挂载清理 (Strategy B)

struct KernelMountEntry {
    let mountPath: String
    let source: String
}

func getKernelMountEntries() -> [KernelMountEntry] {
    var mntbuf: UnsafeMutablePointer<statfs>?
    let count = getmntinfo(&mntbuf, MNT_NOWAIT)
    guard count > 0, let mnt = mntbuf else { return [] }
    var entries: [KernelMountEntry] = []
    for i in 0..<Int(count) {
        let entry = mnt[i]
        var from = entry.f_mntfromname
        var to = entry.f_mntonname
        let fromStr = withUnsafePointer(to: &from) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
        let toStr = withUnsafePointer(to: &to) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
        entries.append(KernelMountEntry(mountPath: toStr, source: fromStr))
    }
    return entries
}

func getKernelMountSource(for mountPath: String) -> String? {
    let stdPath = URL(fileURLWithPath: mountPath).standardizedFileURL.path
    let entries = getKernelMountEntries()
    for entry in entries {
        if URL(fileURLWithPath: entry.mountPath).standardizedFileURL.path == stdPath {
            return entry.source
        }
    }
    return nil
}

// 动态扫描当前系统已挂载的所有 SMB 共享卷宗
func discoverActiveSMBMounts() -> [(url: String, path: String, host: String)] {
    let entries = getKernelMountEntries()
    var results: [(url: String, path: String, host: String)] = []
    for entry in entries {
        // SMB 挂载源通常形如 //user@host/share 或 //host/share
        if entry.source.hasPrefix("//") {
            let host = extractHost(from: entry.source)
            // 提取共享名：从最后一个斜杠截取
            var clean = entry.source.dropFirst(2)
            if let atIdx = clean.firstIndex(of: "@") {
                clean = clean[clean.index(after: atIdx)...]
            }
            let reconstructedURL = "smb://" + clean
            results.append((url: reconstructedURL, path: entry.mountPath, host: host))
        }
    }
    return results
}

// 动态根据 SMB URL 推导默认本地挂载路径
func deriveDefaultMountPath(from string: String) -> String {
    var clean = string.trimmingCharacters(in: .whitespacesAndNewlines)
    while clean.hasSuffix("/") { clean.removeLast() }
    if let lastSlash = clean.lastIndex(of: "/") {
        let name = String(clean[clean.index(after: lastSlash)...])
        if !name.isEmpty {
            return "/Volumes/\(name)"
        }
    }
    return "/Volumes/share"
}

// 动态发现在线的 Tailscale 节点信息
struct DiscoveredTailscalePeer {
    let name: String
    let magicDNS: String?
    let ip: String
    let os: String
}

func findTailscaleBinary() -> String? {
    let candidatePaths = [
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    ]
    for path in candidatePaths {
        if FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
    }
    return nil
}

func discoverTailscalePeers() -> [DiscoveredTailscalePeer] {
    guard let binPath = findTailscaleBinary() else { return [] }

    let task = Process()
    task.executableURL = URL(fileURLWithPath: binPath)
    task.arguments = ["status", "--json"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do {
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return [] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let peers = json["Peer"] as? [String: [String: Any]] else { return [] }

        var list: [DiscoveredTailscalePeer] = []
        for (_, peer) in peers {
            let name = peer["HostName"] as? String ?? "unknown"
            var dns = peer["DNSName"] as? String
            if let d = dns, d.hasSuffix(".") {
                dns = String(d.dropLast())
            }
            let ips = peer["TailscaleIPs"] as? [String] ?? []
            let ip = ips.first ?? ""
            let os = peer["OS"] as? String ?? ""
            list.append(DiscoveredTailscalePeer(name: name, magicDNS: dns, ip: ip, os: os))
        }
        return list.sorted { $0.name < $1.name }
    } catch {
        return []
    }
}

// 严格带超时限制的强制卸载函数 (3 秒超时)
@discardableResult
func forceUnmountWithTimeout(path: String, timeoutSeconds: Double = 3.0) -> Bool {
    print("    [Unmount] Force unmounting stale/conflicting volume at \(path)...")
    writeLog("Attempting force unmount on \(path) (timeout \(timeoutSeconds)s)")

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    task.arguments = ["unmount", "force", path]
    task.standardOutput = Pipe()
    task.standardError = Pipe()

    let group = DispatchGroup()
    group.enter()
    do {
        try task.run()
        DispatchQueue.global().async {
            task.waitUntilExit()
            group.leave()
        }
        let result = group.wait(timeout: .now() + timeoutSeconds)
        if result == .timedOut {
            task.terminate()
            writeLog("diskutil unmount timed out, falling back to Darwin unmount(MNT_FORCE)")
            _ = Darwin.unmount(path, MNT_FORCE)
        }
    } catch {
        _ = Darwin.unmount(path, MNT_FORCE)
        group.leave()
    }

    Thread.sleep(forTimeInterval: 0.5)
    let stillMounted = getKernelMountSource(for: path) != nil
    if !stillMounted {
        print("    ✓ Successfully unmounted \(path)")
        writeLog("Successfully unmounted \(path)")
        return true
    } else {
        print("    ✗ Failed to unmount \(path)")
        writeLog("Failed to unmount \(path)")
        return false
    }
}

enum MountPointStatus {
    case alreadyMountedHealthy   // 同源且正常在线 -> 跳过
    case readyToMount            // 未挂载 或 已成功完成清理 -> 可以挂载
    case unmountFailed           // 冲突挂载点无法卸载 -> 跳过
}

func ensureMountPointReady(target: MountTarget) -> MountPointStatus {
    guard let currentSource = getKernelMountSource(for: target.mountPath) else {
        return .readyToMount
    }

    let currentHost = extractHost(from: currentSource)
    let targetHost = extractHost(from: target.url)

    if currentHost == targetHost {
        if probeHostWithRetries(host: targetHost, retries: 1, interval: 0.5) {
            return .alreadyMountedHealthy
        } else {
            print("    [Health Check] Stale mount detected (host \(targetHost) unreachable).")
            writeLog("Stale mount detected on \(target.mountPath), unmounting...")
            return forceUnmountWithTimeout(path: target.mountPath) ? .readyToMount : .unmountFailed
        }
    } else {
        print("    [Health Check] Mount source switch detected (\(currentHost) -> \(targetHost)).")
        writeLog("Source switch on \(target.mountPath) (\(currentHost) -> \(targetHost)), unmounting old session...")
        return forceUnmountWithTimeout(path: target.mountPath) ? .readyToMount : .unmountFailed
    }
}

// MARK: - 流量保护与 Spotlight 索引阻断

func disableSpotlightIndex(at mountPath: String) {
    let mdutil = Process()
    mdutil.executableURL = URL(fileURLWithPath: "/usr/bin/mdutil")
    mdutil.arguments = ["-i", "off", mountPath]
    mdutil.standardOutput = Pipe()
    mdutil.standardError = Pipe()
    try? mdutil.run()
    mdutil.waitUntilExit()

    let flagURL = URL(fileURLWithPath: mountPath).appendingPathComponent(".metadata_never_index")
    if !FileManager.default.fileExists(atPath: flagURL.path) {
        try? "".write(to: flagURL, atomically: true, encoding: .utf8)
    }
    writeLog("Spotlight indexing disabled for \(mountPath)")
}

// 静默挂载网络卷宗（NetFS 核心 API）
func silentMount(urlString: String) -> Bool {
    guard let url = CFURLCreateWithString(kCFAllocatorDefault, urlString as CFString, nil) else {
        fputs("    ✗ Invalid URL: \(urlString)\n", stderr)
        return false
    }
    var mountPoints: Unmanaged<CFArray>?
    let status = NetFSMountURLSync(
        url,
        nil,
        nil,
        nil,
        nil,
        nil,
        &mountPoints
    )
    if let mp = mountPoints {
        mp.release()
    }
    if status == noErr {
        print("    ✓ Mounted: \(urlString)")
        writeLog("Mounted: \(urlString)")
        return true
    } else {
        fputs("    ✗ Failed to mount: \(urlString) (error: \(status))\n", stderr)
        writeLog("Failed to mount: \(urlString) (error: \(status))")
        return false
    }
}

// MARK: - 终端 ANSI Raw Mode 交互式复选框与单选组件

struct TerminalUI {
    static var isInteractive: Bool {
        return isatty(STDIN_FILENO) != 0
    }

    static func enableRawMode() -> termios? {
        var orig = termios()
        if tcgetattr(STDIN_FILENO, &orig) != 0 { return nil }
        var raw = orig
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        raw.c_cc.16 = 1 // VMIN = 1
        raw.c_cc.17 = 0 // VTIME = 0
        if tcsetattr(STDIN_FILENO, TCSANOW, &raw) != 0 { return nil }
        print("\u{1b}[?25l", terminator: "")
        fflush(stdout)
        return orig
    }

    static func disableRawMode(orig: termios?) {
        print("\u{1b}[?25h", terminator: "")
        fflush(stdout)
        if var orig = orig {
            tcsetattr(STDIN_FILENO, TCSANOW, &orig)
        }
    }

    enum Key {
        case up
        case down
        case space
        case enter
        case selectAll
        case cancel
        case other
    }

    static func readKey() -> Key {
        var buf = [UInt8](repeating: 0, count: 3)
        let n = read(STDIN_FILENO, &buf, 3)
        guard n > 0 else { return .other }

        if n == 1 {
            let byte = buf[0]
            if byte == 3 { return .cancel } // Ctrl+C
            if byte == 10 || byte == 13 { return .enter } // Enter
            if byte == 32 { return .space } // Space
            if byte == 97 || byte == 65 { return .selectAll } // a / A
            if byte == 107 || byte == 75 { return .up } // k
            if byte == 106 || byte == 74 { return .down } // j
            return .other
        }

        if n == 3 && buf[0] == 27 && buf[1] == 91 {
            if buf[2] == 65 { return .up }
            if buf[2] == 66 { return .down }
        }

        return .other
    }
}

struct SelectionOption {
    let title: String
    let subtitle: String?
}

// 终端交互式复选框多选
func promptInteractiveCheckbox(title: String, options: [SelectionOption]) -> [Int] {
    guard !options.isEmpty else { return [] }

    if !TerminalUI.isInteractive {
        print(title)
        for (i, opt) in options.enumerated() {
            let sub = opt.subtitle != nil ? " (\(opt.subtitle!))" : ""
            print("  [\(i + 1)] \(opt.title)\(sub)")
        }
        print(tr("请输入要选择的序号 (例如 1,2 或 all，按回车全不选): ", "Enter options to select (e.g. 1,2 or all, Enter to skip): "), terminator: "")
        guard let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else {
            return []
        }
        if line.lowercased() == "all" { return Array(0..<options.count) }
        return line.components(separatedBy: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.map { $0 - 1 }.filter { $0 >= 0 && $0 < options.count }
    }

    var selected = [Bool](repeating: false, count: options.count)
    var cursorIndex = 0
    let origTerm = TerminalUI.enableRawMode()
    defer {
        TerminalUI.disableRawMode(orig: origTerm)
    }

    func render(isFirst: Bool = false) {
        if !isFirst {
            print("\u{1b}[\(options.count)A\u{1b}[J", terminator: "")
        }
        for (i, opt) in options.enumerated() {
            let isCurrent = (i == cursorIndex)
            let isChecked = selected[i]
            let cursor = isCurrent ? "❯" : " "
            let box = isChecked ? "[\u{1b}[32m●\u{1b}[0m]" : "[ ]"
            let titleStr = isCurrent ? "\u{1b}[1m\(opt.title)\u{1b}[0m" : opt.title
            let sub = opt.subtitle != nil ? " \u{1b}[90m(\(opt.subtitle!))\u{1b}[0m" : ""
            print("\(cursor) \(box) \(titleStr)\(sub)\u{1b}[K")
        }
        fflush(stdout)
    }

    print("\(title)")
    print(tr("\u{1b}[90m(↑/↓ 移动光标，Space 切换勾选，a 全选，Enter 确认提交)\u{1b}[0m",
             "\u{1b}[90m(↑/↓ Move cursor, Space toggle, a select all, Enter confirm)\u{1b}[0m"))
    render(isFirst: true)

    while true {
        let key = TerminalUI.readKey()
        switch key {
        case .up:
            cursorIndex = (cursorIndex - 1 + options.count) % options.count
            render()
        case .down:
            cursorIndex = (cursorIndex + 1) % options.count
            render()
        case .space:
            selected[cursorIndex].toggle()
            render()
        case .selectAll:
            let all = selected.allSatisfy { $0 }
            selected = [Bool](repeating: !all, count: options.count)
            render()
        case .enter:
            TerminalUI.disableRawMode(orig: origTerm)
            print("")
            var res: [Int] = []
            for (i, s) in selected.enumerated() where s {
                res.append(i)
            }
            return res
        case .cancel:
            TerminalUI.disableRawMode(orig: origTerm)
            print(tr("\n操作已取消。", "\nOperation cancelled."))
            exit(0)
        default:
            break
        }
    }
}

// 终端交互式单选
func promptInteractiveRadio(title: String, options: [SelectionOption], defaultIndex: Int = 0) -> Int {
    guard !options.isEmpty else { return 0 }

    if !TerminalUI.isInteractive {
        print(title)
        for (i, opt) in options.enumerated() {
            let sub = opt.subtitle != nil ? " (\(opt.subtitle!))" : ""
            print("  [\(i + 1)] \(opt.title)\(sub)")
        }
        print(tr("请选择序号 [默认 \(defaultIndex + 1)]: ", "Select index [Default \(defaultIndex + 1)]: "), terminator: "")
        guard let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else {
            return defaultIndex
        }
        if let val = Int(line), val >= 1 && val <= options.count {
            return val - 1
        }
        return defaultIndex
    }

    var cursorIndex = defaultIndex
    let origTerm = TerminalUI.enableRawMode()
    defer {
        TerminalUI.disableRawMode(orig: origTerm)
    }

    func render(isFirst: Bool = false) {
        if !isFirst {
            print("\u{1b}[\(options.count)A\u{1b}[J", terminator: "")
        }
        for (i, opt) in options.enumerated() {
            let isCurrent = (i == cursorIndex)
            let cursor = isCurrent ? "❯" : " "
            let radio = isCurrent ? "(\u{1b}[36m●\u{1b}[0m)" : "( )"
            let titleStr = isCurrent ? "\u{1b}[1m\(opt.title)\u{1b}[0m" : opt.title
            let sub = opt.subtitle != nil ? " \u{1b}[90m(\(opt.subtitle!))\u{1b}[0m" : ""
            print("\(cursor) \(radio) \(titleStr)\(sub)\u{1b}[K")
        }
        fflush(stdout)
    }

    print("\(title)")
    print(tr("\u{1b}[90m(↑/↓ 移动光标，Enter 选定确认)\u{1b}[0m",
             "\u{1b}[90m(↑/↓ Move cursor, Enter confirm selection)\u{1b}[0m"))
    render(isFirst: true)

    while true {
        let key = TerminalUI.readKey()
        switch key {
        case .up:
            cursorIndex = (cursorIndex - 1 + options.count) % options.count
            render()
        case .down:
            cursorIndex = (cursorIndex + 1) % options.count
            render()
        case .enter:
            TerminalUI.disableRawMode(orig: origTerm)
            print("")
            return cursorIndex
        case .cancel:
            TerminalUI.disableRawMode(orig: origTerm)
            print(tr("\n操作已取消。", "\nOperation cancelled."))
            exit(0)
        default:
            break
        }
    }
}

// MARK: - 初始化向导 (--init)

func runInitWizard() {
    print(tr("""
    Auto Mount Tool - 初始化配置向导 (v\(autoMountVersion))
    ======================================
    """, """
    Auto Mount Tool - Setup Wizard (v\(autoMountVersion))
    ====================================
    """))

    if loadConfig() != nil {
        print(tr("  [提示] 检测到已存在配置文件，继续向导将全量重写配置；如需增删目标请使用 './auto_mount --config'。\n",
                 "  [Note] Existing configuration detected. Continuing will overwrite it; use './auto_mount --config' for incremental edits.\n"))
    }

    // 1. 物理网关 MAC 探测
    print(tr("[1/5] 局域网物理网关指纹检测", "[1/5] LAN Gateway Hardware Fingerprint Detection"))
    var homeMAC = ""
    if let detectedMAC = getCurrentNetworkFingerprint() {
        print(tr("  ✓ 自动探测到物理网关 MAC: \(detectedMAC)", "  ✓ Detected physical gateway MAC: \(detectedMAC)"))
        while homeMAC.isEmpty {
            print(tr("  按回车直接使用此指纹，或输入自定义 MAC 覆盖 [默认: \(detectedMAC)]: ",
                     "  Press Enter to use this fingerprint, or enter custom MAC [Default: \(detectedMAC)]: "), terminator: "")
            let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            homeMAC = input.isEmpty ? detectedMAC : input
            if homeMAC.isEmpty {
                print(tr("  ✗ 网关 MAC 不能为空，请重新输入。", "  ✗ Gateway MAC cannot be empty, please re-enter."))
            }
        }
    } else {
        while homeMAC.isEmpty {
            print(tr("  未能自动获取物理网关 MAC，请输入网关 MAC 地址: ",
                     "  Failed to detect gateway MAC. Please enter gateway MAC: "), terminator: "")
            homeMAC = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if homeMAC.isEmpty {
                print(tr("  ✗ 网关 MAC 不能为空，请重新输入。", "  ✗ Gateway MAC cannot be empty, please re-enter."))
            }
        }
    }

    // 2. 挂载目标选择 (自动嗅探 + 复选框多选)
    print(tr("\n[2/5] 选择家庭局域网挂载目标", "\n[2/5] Select Home LAN Mount Targets"))
    var homeTargets: [MountTarget] = []
    let activeMounts = discoverActiveSMBMounts()

    if !activeMounts.isEmpty {
        let options = activeMounts.map { SelectionOption(title: URL(fileURLWithPath: $0.path).lastPathComponent, subtitle: $0.url) }
        let selectedIndices = promptInteractiveCheckbox(
            title: tr("发现当前系统中已挂载的 SMB 卷宗，请选择需要纳入自动挂载的目标 (直接按回车跳过)：",
                      "Discovered currently mounted SMB volumes. Select targets to auto-mount (Enter to skip):"),
            options: options
        )
        for idx in selectedIndices {
            let item = activeMounts[idx]
            homeTargets.append(MountTarget(url: item.url, mountPath: item.path))
            print(tr("  ✓ 已添加: \(item.path) (\(item.url))", "  ✓ Added: \(item.path) (\(item.url))"))
        }
    }

    // 若未勾选任何已挂载项，引导手动录入或直接跳过
    if homeTargets.isEmpty {
        print(tr("  当前未选择已挂载卷宗，可手动录入 (直接按回车可跳过此步骤)：",
                 "  No active mounts selected. You can enter manually (Enter to skip this step):"))
        while true {
            print(tr("  请输入 SMB 地址 (例如 smb://server.local/share，按回车跳过): ",
                     "  Enter SMB URL (e.g. smb://server.local/share, Enter to skip): "), terminator: "")
            guard let urlStr = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !urlStr.isEmpty else {
                break
            }
            let defaultPath = deriveDefaultMountPath(from: urlStr)
            print(tr("  请输入本地挂载路径 [默认: \(defaultPath)]: ",
                     "  Enter local mount path [Default: \(defaultPath)]: "), terminator: "")
            let pathInput = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let pathStr = pathInput.isEmpty ? defaultPath : pathInput
            homeTargets.append(MountTarget(url: urlStr, mountPath: pathStr))
            print(tr("  ✓ 已添加: \(pathStr) (\(urlStr))", "  ✓ Added: \(pathStr) (\(urlStr))"))
            print(tr("  继续添加另一个挂载目标？(y/n) [默认 n]: ",
                     "  Add another mount target? (y/n) [Default n]: "), terminator: "")
            let cont = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "n"
            if cont != "y" && cont != "yes" {
                break
            }
        }
    }

    if homeTargets.isEmpty {
        print(tr("  ✓ 局域网内不挂载任何共享，该网络仅作为外出判定排他基准。",
                 "  ✓ No shares configured for LAN. This network acts solely as an exclusion gatekeeper."))
    }

    let homeProfileDesc = tr("本地局域网高速直连", "Local LAN Direct")
    let homeProfile = NetworkProfile(
        id: "local_lan",
        description: homeProfileDesc,
        match: MatchRule(type: "gateway_mac", value: homeMAC, retryCount: nil, retryInterval: nil),
        excludeGatewayIPs: nil,
        preventSpotlightIndex: true,
        targets: homeTargets
    )

    // 3. 远程互联降级策略配置 (Tailscale / WireGuard / 域名 / IP)
    print(tr("\n[3/5] 配置远程互联降级策略 (Tailscale / WireGuard / 域名 / IP)",
             "\n[3/5] Configure Remote Fallback Profile (Tailscale / WireGuard / Domain / IP)"))
    var profiles: [NetworkProfile] = [homeProfile]
    let discoveredPeers = discoverTailscalePeers()

    var remoteOptions: [SelectionOption] = []
    if !discoveredPeers.isEmpty {
        for peer in discoveredPeers {
            remoteOptions.append(SelectionOption(
                title: tr("Tailscale 设备: \(peer.name)", "Tailscale Device: \(peer.name)"),
                subtitle: tr("MagicDNS: \(peer.magicDNS ?? "无"), IP: \(peer.ip), OS: \(peer.os)",
                             "MagicDNS: \(peer.magicDNS ?? "None"), IP: \(peer.ip), OS: \(peer.os)")
            ))
        }
    }
    remoteOptions.append(SelectionOption(
        title: tr("手动输入远程主机名 / DDNS 域名 / IP", "Manual Hostname / DDNS Domain / IP"),
        subtitle: tr("适用于 WireGuard、ZeroTier、公网 DDNS 动态域名或固定公网 IP",
                     "For WireGuard, ZeroTier, DDNS dynamic domain, or public IP")
    ))
    remoteOptions.append(SelectionOption(
        title: tr("跳过配置远程策略", "Skip remote profile setup"),
        subtitle: nil
    ))

    let selected = promptInteractiveRadio(
        title: tr("请选择远程对端接入方式：", "Select remote peer connection mode:"),
        options: remoteOptions,
        defaultIndex: 0
    )

    let skipIndex = remoteOptions.count - 1
    let manualIndex = remoteOptions.count - 2

    if selected == skipIndex {
        print(tr("  ✓ 已跳过配置远程策略。", "  ✓ Skipped remote profile configuration."))
    } else {
        var selectedPeerName = ""
        var selectedHost = ""

        if selected == manualIndex {
            // 手动输入模式
            print(tr("\n  请输入远程目标主机名、DDNS 动态域名或 IP (例如 nas.example.com): ",
                     "\n  Enter remote target hostname, DDNS domain, or IP (e.g. nas.example.com): "), terminator: "")
            let manualInput = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if manualInput.isEmpty {
                print(tr("  ✓ 未输入有效主机，已跳过远程策略。", "  ✓ No valid host entered. Skipped remote profile."))
            } else {
                selectedHost = manualInput
                selectedPeerName = manualInput
            }
        } else if selected < discoveredPeers.count {
            // Tailscale 快捷选择
            let peer = discoveredPeers[selected]
            selectedPeerName = peer.name

            var addrOptions: [SelectionOption] = []
            if let dns = peer.magicDNS {
                addrOptions.append(SelectionOption(
                    title: tr("MagicDNS 域名: \(dns)", "MagicDNS Domain: \(dns)"),
                    subtitle: tr("推荐：IP 变动不失效，钥匙串凭据稳定", "Recommended: stable credentials across IP changes")
                ))
            }
            if !peer.ip.isEmpty {
                addrOptions.append(SelectionOption(
                    title: tr("Tailscale IP: \(peer.ip)", "Tailscale IP: \(peer.ip)"),
                    subtitle: tr("直连无 DNS 解析依赖", "Direct connection without DNS dependency")
                ))
            }

            if !addrOptions.isEmpty {
                let chosenAddr = promptInteractiveRadio(
                    title: tr("请选择连接方式：", "Select connection address:"),
                    options: addrOptions,
                    defaultIndex: 0
                )
                selectedHost = addrOptions[chosenAddr].title.contains("MagicDNS") ? (peer.magicDNS ?? peer.ip) : peer.ip
            } else {
                selectedHost = peer.ip
            }
        }

        if !selectedHost.isEmpty {
            var remoteTargets: [MountTarget] = []

            // 路径 1：若已配置局域网目标，询问是否自动映射
            var didAutoMap = false
            if !homeTargets.isEmpty {
                print(tr("\n  是否自动将已选的本地局域网共享目录映射为该远程主机目标？(Y/n) [默认 Y]: ",
                         "\n  Auto-map selected LAN shares to this remote host? (Y/n) [Default Y]: "), terminator: "")
                let autoMap = (readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "y") != "n"
                if autoMap {
                    didAutoMap = true
                    for target in homeTargets {
                        var pathPart = target.url
                        if pathPart.hasPrefix("smb://") { pathPart = String(pathPart.dropFirst(6)) }
                        if let slashIdx = pathPart.firstIndex(of: "/") {
                            pathPart = String(pathPart[slashIdx...])
                        } else {
                            pathPart = "/" + pathPart
                        }
                        let remoteURL = "smb://\(selectedHost)\(pathPart)"
                        remoteTargets.append(MountTarget(url: remoteURL, mountPath: target.mountPath))
                        print(tr("  ✓ 自动映射: \(remoteURL) -> \(target.mountPath)",
                                 "  ✓ Auto-mapped: \(remoteURL) -> \(target.mountPath)"))
                    }
                }
            }

            // 路径 2：若未自动映射，检查当前系统是否有挂载属于该主机的 SMB 卷
            if !didAutoMap {
                let curActive = discoverActiveSMBMounts()
                let matchingMounts = curActive.filter { mount in
                    mount.url.contains(selectedHost)
                }

                if !matchingMounts.isEmpty {
                    let mOptions = matchingMounts.map { SelectionOption(title: URL(fileURLWithPath: $0.path).lastPathComponent, subtitle: $0.url) }
                    let picked = promptInteractiveCheckbox(
                        title: tr("检测到当前已挂载该设备的共享卷宗，请勾选需要自动挂载的项 (直接回车跳过)：",
                                  "Discovered active mounts for this device. Select items to include (Enter to skip):"),
                        options: mOptions
                    )
                    for pIdx in picked {
                        let item = matchingMounts[pIdx]
                        remoteTargets.append(MountTarget(url: item.url, mountPath: item.path))
                        print(tr("  ✓ 已添加: \(item.path) (\(item.url))", "  ✓ Added: \(item.path) (\(item.url))"))
                    }
                }

                // 路径 3：录入共享名
                if remoteTargets.isEmpty {
                    print(tr("  请输入远程主机上的共享文件夹名称 (直接按回车可跳过)：",
                             "  Enter share folder name on remote host (Enter to skip):"))
                    while true {
                        print(tr("  请输入共享文件夹名称 (例如 data，按回车跳过): ",
                                 "  Enter share folder name (e.g. data, Enter to skip): "), terminator: "")
                        guard let shareName = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !shareName.isEmpty else {
                            break
                        }
                        var cleanShare = shareName
                        while cleanShare.hasPrefix("/") { cleanShare.removeFirst() }
                        while cleanShare.hasSuffix("/") { cleanShare.removeLast() }
                        let remoteURL = "smb://\(selectedHost)/\(cleanShare)"
                        let defaultPath = "/Volumes/\(cleanShare)"
                        print(tr("  请输入本地挂载路径 [默认: \(defaultPath)]: ",
                                 "  Enter local mount path [Default: \(defaultPath)]: "), terminator: "")
                        let pathInput = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let pathStr = pathInput.isEmpty ? defaultPath : pathInput
                        remoteTargets.append(MountTarget(url: remoteURL, mountPath: pathStr))
                        print(tr("  ✓ 已添加: \(pathStr) (\(remoteURL))", "  ✓ Added: \(pathStr) (\(remoteURL))"))
                        print(tr("  继续添加另一个远程挂载目标？(y/n) [默认 n]: ",
                                 "  Add another remote target? (y/n) [Default n]: "), terminator: "")
                        let cont = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "n"
                        if cont != "y" && cont != "yes" {
                            break
                        }
                    }
                }
            }

            if !remoteTargets.isEmpty {
                let desc = tr("远程互联 (\(selectedPeerName))", "Remote Network (\(selectedPeerName))")
                let remoteProfile = NetworkProfile(
                    id: "remote_network",
                    description: desc,
                    match: MatchRule(type: "probe_host", value: selectedHost, retryCount: 3, retryInterval: 1.0),
                    excludeGatewayIPs: ["172.20.10.1"],
                    preventSpotlightIndex: true,
                    targets: remoteTargets
                )
                profiles.append(remoteProfile)
            } else {
                print(tr("  ✓ 未配置远程挂载目标，跳过远程策略。", "  ✓ No remote targets configured. Skipped remote profile."))
            }
        }
    }

    // 4. 软件更新策略配置
    print(tr("\n[4/5] 软件更新策略配置", "\n[4/5] Configure Software Update Policy"))
    print(tr("""
      请选择软件自动更新检查策略：
        [1] off    - 关闭自动检查 (默认，零网络请求，可纯手动运行 './auto_mount --update')
        [2] notify - 发现新版本时发送系统通知，由您手动执行更新
        [3] auto   - 发现新版本时自动静默预检并平滑无缝热升级
    """, """
      Select software update policy:
        [1] off    - Disable auto-checks (Default, zero network requests, manual update via './auto_mount --update')
        [2] notify - Send system notification on new version, update manually
        [3] auto   - Automatically download, pre-check, and upgrade in background
    """))
    print(tr("  请选择更新策略 [1-3] (直接按回车选择默认 1): ",
             "  Select update policy [1-3] (Press Enter for default 1): "), terminator: "")
    let updateChoiceInput = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    var selectedChannel = "off"
    if updateChoiceInput == "2" {
        selectedChannel = "notify"
    } else if updateChoiceInput == "3" {
        selectedChannel = "auto"
    } else {
        selectedChannel = "off"
    }
    print(tr("  ✓ 软件更新策略已设置为: \(selectedChannel)", "  ✓ Software update policy set to: \(selectedChannel)"))

    // 保存配置
    let config = AutoMountConfig(version: autoMountVersion, updateChannel: selectedChannel, lastUpdateCheckTimestamp: nil, lastNotifiedVersion: nil, profiles: profiles)
    saveConfig(config)
    print(tr("\n[DONE] 初始化完成！配置已写入 \(getConfigURL().path)",
             "\n[DONE] Setup complete! Configuration written to \(getConfigURL().path)"))

    // 5. 部署后台自启动守护服务
    print(tr("\n[5/5] 部署自启动后台守护服务", "\n[5/5] Deploy Background Auto-Mount Daemon"))
    print(tr("  是否立即将 AutoMount 注册为系统的后台自动挂载守护服务？(Y/n) [默认 Y]: ",
             "  Register AutoMount as system LaunchAgent daemon for auto-mounting on login & network change? (Y/n) [Default Y]: "), terminator: "")
    let installChoice = (readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "y")
    if installChoice != "n" && installChoice != "no" {
        print("")
        installLaunchAgent()
    } else {
        print(tr("  ✓ 已跳过后台服务安装。后续可随时运行 './auto_mount --install' 进行部署。\n",
                 "  ✓ Daemon deployment skipped. You can run './auto_mount --install' anytime later.\n"))
    }
}

// MARK: - 日常配置维护菜单 (--config)

func getLaunchAgentStatusSummary() -> String {
    let plistURL = getLaunchAgentPlistURL()
    if !FileManager.default.fileExists(atPath: plistURL.path) {
        return tr("未安装 (可选择 [5] 部署守护)", "Not installed (Select [5] to deploy)")
    }
    let uid = getuid()
    let serviceTarget = "gui/\(uid)/\(launchAgentLabel)"
    let check = runCommand(executable: "/bin/launchctl", arguments: ["print", serviceTarget])
    if check.status == 0 {
        return tr("已注册运行 (\(serviceTarget))", "Active & running (\(serviceTarget))")
    } else {
        return tr("已部署描述文件但未处于激活状态", "Deployed but inactive in launchd")
    }
}

func getUpdateChannelDisplay(_ channel: String) -> String {
    switch channel {
    case "notify":
        return tr("notify (新版本通知提醒)", "notify (Notification only)")
    case "auto":
        return tr("auto (后台静默自动升级)", "auto (Silent background auto-update)")
    default:
        return tr("off (关闭自动检查，纯手动)", "off (Disabled, manual update)")
    }
}

func manageConfiguration() {
    print(tr("""
    Auto Mount Tool - 日常配置管理 (v\(autoMountVersion))
    ====================================
    """, """
    Auto Mount Tool - Daily Configuration Management (v\(autoMountVersion))
    ======================================================
    """))

    guard var config = loadConfig() else {
        fputs(tr("✗ 未找到配置文件，请先运行 './auto_mount --init' 初始化。\n",
                 "✗ Configuration not found. Please run './auto_mount --init' first.\n"), stderr)
        exit(1)
    }

    while true {
        print(tr("\n当前已配置策略：", "\nCurrently configured profiles:"))
        for (i, p) in config.profiles.enumerated() {
            if p.targets.isEmpty {
                print(tr("  [\(i + 1)] \(p.id) (\(p.description ?? "无描述")) - 0 个挂载目标 (网络排他门牌，不执行本地挂载)",
                         "  [\(i + 1)] \(p.id) (\(p.description ?? "No description")) - 0 mount targets (Exclusion Gatekeeper, no local mounts)"))
            } else {
                print(tr("  [\(i + 1)] \(p.id) (\(p.description ?? "无描述")) - \(p.targets.count) 个挂载目标",
                         "  [\(i + 1)] \(p.id) (\(p.description ?? "No description")) - \(p.targets.count) mount targets"))
                for t in p.targets {
                    print("      • \(t.mountPath) <- \(t.url)")
                }
            }
        }

        let daemonSummary = getLaunchAgentStatusSummary()
        let curChannel = config.updateChannel ?? "off"
        let channelDisplay = getUpdateChannelDisplay(curChannel)
        let hasRemote = config.profiles.contains(where: { $0.match.type == "probe_host" || $0.id == "remote_network" || $0.id == "tailscale_remote" })
        let remoteActionTitle = hasRemote ?
            tr("重新配置/更新远程互联主机 (Tailscale / 域名 / IP)", "Re-detect / update remote host (Tailscale / Domain / IP)") :
            tr("配置并添加远程互联策略", "Configure & add remote profile")

        print(tr("""

        软件版本: v\(autoMountVersion) | 自动更新信道: \(channelDisplay)
        后台守护服务状态: \(daemonSummary)

        请选择操作：
          [1] 添加挂载目标 (支持从当前已挂载项中导入或手动输入)
          [2] 删除已有挂载目标
          [3] 重新检测/更新本地网关 MAC
          [4] \(remoteActionTitle)
          [5] 守护服务管理 (部署/重载、查看详情、卸载服务)
          [6] 自动更新信道与版本维护 (设置更新策略、立即检查并升级)
          [0] 退出配置管理
        """, """

        Software Version: v\(autoMountVersion) | Auto-Update Channel: \(channelDisplay)
        Background Daemon Status: \(daemonSummary)

        Select an action:
          [1] Add mount target (import from active mounts or manual entry)
          [2] Remove existing mount target
          [3] Re-detect / update local gateway MAC
          [4] \(remoteActionTitle)
          [5] Daemon management (deploy/reload, view details, uninstall)
          [6] Auto-update channel & version maintenance
          [0] Exit configuration management
        """))

        print(tr("请输入选项 [0-6]: ", "Enter choice [0-6]: "), terminator: "")
        guard let choice = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            break
        }

        switch choice {
        case "1":
            // 添加挂载目标
            print(tr("\n请选择要添加目标的策略：", "\nSelect profile to add target to:"))
            for (i, p) in config.profiles.enumerated() {
                print("  [\(i + 1)] \(p.id) (\(p.description ?? "无描述"))")
            }
            print(tr("请输入策略编号 (按回车取消): ", "Enter profile number (Enter to cancel): "), terminator: "")
            guard let pStr = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let pIdx = Int(pStr), pIdx >= 1 && pIdx <= config.profiles.count else {
                continue
            }

            let profileIndex = pIdx - 1
            var defaultHost = ""
            if config.profiles[profileIndex].match.type == "probe_host" {
                defaultHost = config.profiles[profileIndex].match.value
            }

            // 导入活动挂载或手动输入
            let activeMounts = discoverActiveSMBMounts()
            var options: [SelectionOption] = []
            for m in activeMounts {
                let name = URL(fileURLWithPath: m.path).lastPathComponent
                options.append(SelectionOption(title: name, subtitle: "\(m.path) <- \(m.url)"))
            }
            options.append(SelectionOption(title: tr("手动输入挂载目标 URL 和挂载点", "Manual entry of URL and mount path"), subtitle: nil))

            let sel = promptInteractiveRadio(
                title: tr("请选择添加方式：", "Select addition method:"),
                options: options,
                defaultIndex: options.count - 1
            )

            if sel < activeMounts.count {
                let m = activeMounts[sel]
                config.profiles[profileIndex].targets.append(MountTarget(url: m.url, mountPath: m.path))
                saveConfig(config)
                print(tr("✓ 已添加: \(m.path) <- \(m.url)", "✓ Added: \(m.path) <- \(m.url)"))
            } else {
                // 手动输入
                let sampleURL = defaultHost.isEmpty ? "smb://server.local/share" : "smb://\(defaultHost)/share"
                print(tr("请输入完整 SMB 地址 (例如 \(sampleURL)): ",
                         "Enter full SMB URL (e.g. \(sampleURL)): "), terminator: "")
                guard let url = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else {
                    continue
                }
                var defaultPath = "/Volumes/share"
                if let lastPart = url.split(separator: "/").last {
                    defaultPath = "/Volumes/\(lastPart)"
                }
                print(tr("请输入本地挂载点绝对路径 [默认: \(defaultPath)]: ",
                         "Enter local mount point path [Default: \(defaultPath)]: "), terminator: "")
                let pathInput = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let path = pathInput.isEmpty ? defaultPath : pathInput
                config.profiles[profileIndex].targets.append(MountTarget(url: url, mountPath: path))
                saveConfig(config)
                print(tr("✓ 已添加: \(path) <- \(url)", "✓ Added: \(path) <- \(url)"))
            }

        case "2":
            // 删除挂载目标
            var flatTargets: [(profileIndex: Int, targetIndex: Int, display: String)] = []
            for (pI, p) in config.profiles.enumerated() {
                for (tI, t) in p.targets.enumerated() {
                    flatTargets.append((pI, tI, "[\(p.id)] \(t.mountPath) <- \(t.url)"))
                }
            }

            if flatTargets.isEmpty {
                print(tr("当前没有任何已配置的挂载目标。", "No mount targets configured."))
                continue
            }

            print(tr("\n当前所有挂载目标列表：", "\nCurrent mount targets:"))
            for (idx, item) in flatTargets.enumerated() {
                print("  [\(idx + 1)] \(item.display)")
            }
            print(tr("请输入要删除的编号 (按回车取消): ", "Enter target number to delete (Enter to cancel): "), terminator: "")
            if let delStr = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
               let delIdx = Int(delStr), delIdx >= 1 && delIdx <= flatTargets.count {
                let item = flatTargets[delIdx - 1]
                config.profiles[item.profileIndex].targets.remove(at: item.targetIndex)
                saveConfig(config)
                print(tr("✓ 已删除目标。", "✓ Target removed."))
            }

        case "3":
            // 更新本地网关 MAC
            let localIdx = config.profiles.firstIndex(where: { $0.match.type == "gateway_mac" }) ??
                           config.profiles.firstIndex(where: { $0.id == "local_lan" || $0.id == "home_lan" })
            if let idx = localIdx {
                print(tr("\n当前本地网关 MAC: \(config.profiles[idx].match.value)",
                         "\nCurrent local gateway MAC: \(config.profiles[idx].match.value)"))
                if let curMAC = getCurrentNetworkFingerprint() {
                    print(tr("自动探测到当前网络物理网关 MAC: \(curMAC)",
                             "Detected current physical gateway MAC: \(curMAC)"))
                    print(tr("按回车采纳，或输入自定义 MAC 覆盖 [默认: \(curMAC)]: ",
                             "Press Enter to accept, or enter custom MAC [Default: \(curMAC)]: "), terminator: "")
                    let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    config.profiles[idx].match.value = input.isEmpty ? curMAC : input
                    saveConfig(config)
                    print(tr("✓ 本地网关 MAC 已更新为: \(config.profiles[idx].match.value)",
                             "✓ Local gateway MAC updated to: \(config.profiles[idx].match.value)"))
                } else {
                    print(tr("未能自动获取当前物理网关 MAC，请输入自定义 MAC: ",
                             "Failed to auto-detect gateway MAC. Enter custom MAC: "), terminator: "")
                    let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !input.isEmpty {
                        config.profiles[idx].match.value = input
                        saveConfig(config)
                        print(tr("✓ 本地网关 MAC 已更新为: \(config.profiles[idx].match.value)",
                                 "✓ Local gateway MAC updated to: \(config.profiles[idx].match.value)"))
                    }
                }
            } else {
                print(tr("未找到基于网关 MAC 的本地网络策略。", "No gateway MAC local profile found."))
            }

        case "4":
            // 更新或新建远程互联主机 (Tailscale / 域名 / IP)
            let peers = discoverTailscalePeers()
            var modeOptions: [SelectionOption] = []
            if !peers.isEmpty {
                for p in peers {
                    modeOptions.append(SelectionOption(
                        title: tr("Tailscale 设备: \(p.name)", "Tailscale Device: \(p.name)"),
                        subtitle: tr("MagicDNS: \(p.magicDNS ?? "无"), IP: \(p.ip)", "MagicDNS: \(p.magicDNS ?? "None"), IP: \(p.ip)")
                    ))
                }
            }
            modeOptions.append(SelectionOption(
                title: tr("手动输入远程主机名 / DDNS 域名 / IP", "Manual Hostname / DDNS Domain / IP"),
                subtitle: tr("支持 WireGuard、ZeroTier、公网动态域名或固定 IP", "Supports WireGuard, ZeroTier, DDNS, or public IP")
            ))
            modeOptions.append(SelectionOption(title: tr("取消", "Cancel"), subtitle: nil))

            let sel = promptInteractiveRadio(
                title: tr("请选择远程主机接入方式：", "Select remote host connection mode:"),
                options: modeOptions,
                defaultIndex: 0
            )

            let cancelIdx = modeOptions.count - 1
            let manualModeIdx = modeOptions.count - 2

            guard sel != cancelIdx else {
                print(tr("已取消操作。", "Operation cancelled."))
                continue
            }

            var newHost = ""
            var selectedDisplayName = ""

            if sel == manualModeIdx {
                print(tr("\n请输入远程主机名、DDNS 动态域名或 IP (例如 nas.example.com): ",
                         "\nEnter remote hostname, DDNS domain, or IP (e.g. nas.example.com): "), terminator: "")
                let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if input.isEmpty {
                    print(tr("未输入有效地址，已取消。", "No valid address entered. Cancelled."))
                    continue
                }
                newHost = input
                selectedDisplayName = input
            } else if sel < peers.count {
                let peer = peers[sel]
                selectedDisplayName = peer.name
                var addrOptions: [SelectionOption] = []
                if let dns = peer.magicDNS {
                    addrOptions.append(SelectionOption(
                        title: tr("MagicDNS 域名: \(dns)", "MagicDNS Domain: \(dns)"),
                        subtitle: tr("推荐：IP 变动不失效，钥匙串凭据稳定", "Recommended: stable credentials across IP changes")
                    ))
                }
                if !peer.ip.isEmpty {
                    addrOptions.append(SelectionOption(
                        title: tr("Tailscale IP: \(peer.ip)", "Tailscale IP: \(peer.ip)"),
                        subtitle: tr("直连无 DNS 解析依赖", "Direct connection without DNS dependency")
                    ))
                }
                if !addrOptions.isEmpty {
                    let chosen = promptInteractiveRadio(
                        title: tr("请选择连接方式：", "Select connection address:"),
                        options: addrOptions,
                        defaultIndex: 0
                    )
                    newHost = addrOptions[chosen].title.contains("MagicDNS") ? (peer.magicDNS ?? peer.ip) : peer.ip
                } else {
                    newHost = peer.ip
                }
            }

            guard !newHost.isEmpty else { continue }

            let existingRemoteIdx = config.profiles.firstIndex(where: { $0.match.type == "probe_host" }) ??
                                   config.profiles.firstIndex(where: { $0.id == "remote_network" || $0.id == "tailscale_remote" })

            if let rIdx = existingRemoteIdx {
                config.profiles[rIdx].match.value = newHost
                config.profiles[rIdx].description = tr("远程互联 (\(selectedDisplayName))", "Remote Network (\(selectedDisplayName))")
                saveConfig(config)
                print(tr("✓ 远程探测目标已更新为: \(newHost) (\(selectedDisplayName))",
                         "✓ Remote probe target updated to: \(newHost) (\(selectedDisplayName))"))
            } else {
                print(tr("\n正在为新远程策略配置挂载目标：", "\nConfiguring mount targets for new remote profile:"))
                var newTargets: [MountTarget] = []
                while true {
                    print(tr("请输入该主机上的共享文件夹名称 (例如 data，按回车结束): ",
                             "Enter share folder name on remote host (e.g. data, Enter to finish): "), terminator: "")
                    guard let sName = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !sName.isEmpty else {
                        break
                    }
                    var clean = sName
                    while clean.hasPrefix("/") { clean.removeFirst() }
                    while clean.hasSuffix("/") { clean.removeLast() }
                    let rURL = "smb://\(newHost)/\(clean)"
                    let dPath = "/Volumes/\(clean)"
                    print(tr("请输入本地挂载路径 [默认: \(dPath)]: ",
                             "Enter local mount path [Default: \(dPath)]: "), terminator: "")
                    let pIn = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let pStr = pIn.isEmpty ? dPath : pIn
                    newTargets.append(MountTarget(url: rURL, mountPath: pStr))
                    print(tr("  ✓ 已添加: \(pStr) (\(rURL))", "  ✓ Added: \(pStr) (\(rURL))"))
                    print(tr("继续添加另一个目标？(y/n) [默认 n]: ",
                             "Add another target? (y/n) [Default n]: "), terminator: "")
                    let c = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "n"
                    if c != "y" && c != "yes" { break }
                }

                let newProfile = NetworkProfile(
                    id: "remote_network",
                    description: tr("远程互联 (\(selectedDisplayName))", "Remote Network (\(selectedDisplayName))"),
                    match: MatchRule(type: "probe_host", value: newHost, retryCount: 3, retryInterval: 1.0),
                    excludeGatewayIPs: ["172.20.10.1"],
                    preventSpotlightIndex: true,
                    targets: newTargets
                )
                config.profiles.append(newProfile)
                saveConfig(config)
                print(tr("✓ 远程策略已成功创建并加入配置。", "✓ Remote profile created and added to configuration."))
            }

        case "5":
            // 守护服务管理
            print(tr("""

            守护服务管理：
              [1] 部署 / 重新加载自启动守护服务 (LaunchAgent)
              [2] 查看守护服务运行状态与挂载详情
              [3] 卸载并移除自启动守护服务
              [0] 返回上级菜单
            """, """

            Daemon Management:
              [1] Deploy / reload LaunchAgent daemon
              [2] View service status and active mount details
              [3] Uninstall and remove LaunchAgent daemon
              [0] Back to main menu
            """))
            print(tr("请输入选项 [0-3]: ", "Enter choice [0-3]: "), terminator: "")
            let subChoice = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
            switch subChoice {
            case "1":
                installLaunchAgent()
            case "2":
                checkServiceStatus()
            case "3":
                uninstallLaunchAgent()
            default:
                break
            }

        case "6":
            // 自动更新信道与版本管理
            let curChan = config.updateChannel ?? "off"
            print(tr("""

            自动更新信道与版本维护：
              当前策略: \(getUpdateChannelDisplay(curChan))

              [1] 设置为 off (关闭自动更新检查，纯手动更新)
              [2] 设置为 notify (发现新版本时发送系统通知)
              [3] 设置为 auto (发现新版本时自动静默升级)
              [4] 立即检查远端最新版本并升级 (执行 --update)
              [0] 返回上级菜单
            """, """

            Auto-Update Channel & Maintenance:
              Current Policy: \(getUpdateChannelDisplay(curChan))

              [1] Set to 'off' (disable auto checks, manual update only)
              [2] Set to 'notify' (notify via system notification on new version)
              [3] Set to 'auto' (automatically download and upgrade in background)
              [4] Check for updates and upgrade now (execute --update)
              [0] Back to main menu
            """))
            print(tr("请输入选项 [0-4]: ", "Enter choice [0-4]: "), terminator: "")
            let uChoice = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
            switch uChoice {
            case "1":
                config.updateChannel = "off"
                saveConfig(config)
                print(tr("✓ 自动更新策略已设置为: off", "✓ Auto-update policy set to: off"))
            case "2":
                config.updateChannel = "notify"
                saveConfig(config)
                print(tr("✓ 自动更新策略已设置为: notify", "✓ Auto-update policy set to: notify"))
            case "3":
                config.updateChannel = "auto"
                saveConfig(config)
                print(tr("✓ 自动更新策略已设置为: auto", "✓ Auto-update policy set to: auto"))
            case "4":
                handleManualUpdateCommand()
            default:
                break
            }

        case "0":
            print(tr("✓ 已退出配置管理。", "✓ Exited configuration management."))
            return

        default:
            print(tr("未知选项，请重新输入。", "Unknown option, please try again."))
        }
    }
}

// MARK: - LaunchAgent 自启动服务管理

let launchAgentLabel = "com.user.auto-mount"

func getLaunchAgentPlistURL() -> URL {
    let homeURL = FileManager.default.homeDirectoryForCurrentUser
    return homeURL.appendingPathComponent("Library/LaunchAgents").appendingPathComponent("\(launchAgentLabel).plist")
}

func getInstalledDir() -> URL {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return appSupport.appendingPathComponent("AutoMount")
}

func installLaunchAgent() {
    print(tr("""
    Auto Mount Tool - 安装并启用自启动守护服务
    ===========================================
    """, """
    Auto Mount Tool - Install LaunchAgent Daemon
    ============================================
    """))

    guard let config = loadConfig(), !config.profiles.isEmpty else {
        fputs(tr("✗ 未找到有效配置，请先运行 './auto_mount --init' 初始化配置。\n",
                 "✗ Configuration not found. Please run './auto_mount --init' first.\n"), stderr)
        writeLog("Install aborted: config missing or invalid")
        exit(1)
    }

    let currentAppDir = getAppDir()
    let installDir = getInstalledDir()
    let plistURL = getLaunchAgentPlistURL()
    let launchAgentsDir = plistURL.deletingLastPathComponent()

    do {
        try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true, attributes: nil)
        try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true, attributes: nil)
    } catch {
        fputs(tr("✗ 创建目录失败: \(error.localizedDescription)\n", "✗ Failed to create directory: \(error.localizedDescription)\n"), stderr)
        exit(1)
    }

    let filesToDeploy = ["auto_mount", "auto_mount.swift", "auto_mount.plist"]
    for fileName in filesToDeploy {
        let srcURL = currentAppDir.appendingPathComponent(fileName)
        let dstURL = installDir.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: srcURL.path) {
            if FileManager.default.fileExists(atPath: dstURL.path) {
                try? FileManager.default.removeItem(at: dstURL)
            }
            do {
                try FileManager.default.copyItem(at: srcURL, to: dstURL)
            } catch {
                fputs(tr("✗ 拷贝 \(fileName) 失败: \(error.localizedDescription)\n",
                         "✗ Failed to copy \(fileName): \(error.localizedDescription)\n"), stderr)
                exit(1)
            }
        }
    }

    let installedWrapper = installDir.appendingPathComponent("auto_mount").path
    let installedSwift = installDir.appendingPathComponent("auto_mount.swift").path
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedWrapper)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedSwift)

    let executablePath = FileManager.default.fileExists(atPath: installedWrapper) ? installedWrapper : installedSwift
    print(tr("✓ 已将运行程序与配置同步部署至:\n  \(installDir.path)",
             "✓ Deployed executable and configuration to:\n  \(installDir.path)"))

    let plistData: [String: Any] = [
        "Label": launchAgentLabel,
        "ProgramArguments": [executablePath],
        "RunAtLoad": true,
        "WatchPaths": ["/Library/Preferences/SystemConfiguration"],
        "StandardOutPath": "/tmp/\(launchAgentLabel).stdout.log",
        "StandardErrorPath": "/tmp/\(launchAgentLabel).stderr.log"
    ]

    do {
        let data = try PropertyListSerialization.data(fromPropertyList: plistData, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plistURL.path)
        print(tr("✓ 已生成服务描述文件:\n  \(plistURL.path)", "✓ Generated LaunchAgent plist:\n  \(plistURL.path)"))
    } catch {
        fputs(tr("✗ 写入描述文件失败: \(error.localizedDescription)\n",
                 "✗ Failed to write plist file: \(error.localizedDescription)\n"), stderr)
        exit(1)
    }

    let uid = getuid()
    let serviceTarget = "gui/\(uid)/\(launchAgentLabel)"
    _ = runCommand(executable: "/bin/launchctl", arguments: ["bootout", serviceTarget])

    let domainTarget = "gui/\(uid)"
    let bootResult = runCommand(executable: "/bin/launchctl", arguments: ["bootstrap", domainTarget, plistURL.path])

    if bootResult.status == 0 {
        print(tr("✓ 成功注册并加载至系统 launchd 守护进程 (gui/\(uid))",
                 "✓ Successfully registered and loaded into system launchd (gui/\(uid))"))
        print(tr("""

        服务详情:
          • 标识 (Label): \(launchAgentLabel)
          • 执行路径: \(executablePath)
          • 触发时机: 开机登录 (RunAtLoad) & 网络状态切换 (WatchPaths)
          • 日志路径: /tmp/\(launchAgentLabel).stdout.log

        自启动与网络监听服务已生效。
        """, """

        Service Details:
          • Label: \(launchAgentLabel)
          • Program: \(executablePath)
          • Trigger: Login (RunAtLoad) & Network Configuration Changes (WatchPaths)
          • Log file: /tmp/\(launchAgentLabel).stdout.log

        Auto-mount daemon is active and running.
        """))
        writeLog("LaunchAgent installed and loaded successfully to \(installDir.path)")
    } else {
        fputs(tr("✗ 加载服务失败 (代码 \(bootResult.status)): \(bootResult.stderr)\n",
                 "✗ Failed to bootstrap service (Code \(bootResult.status)): \(bootResult.stderr)\n"), stderr)
        writeLog("Failed to bootstrap LaunchAgent: \(bootResult.stderr)")
        exit(1)
    }
}

func uninstallLaunchAgent() {
    print(tr("""
    Auto Mount Tool - 卸载自启动服务
    =================================
    """, """
    Auto Mount Tool - Uninstall LaunchAgent Daemon
    ==============================================
    """))

    let uid = getuid()
    let serviceTarget = "gui/\(uid)/\(launchAgentLabel)"
    let plistURL = getLaunchAgentPlistURL()
    let installDir = getInstalledDir()

    var unloaded = false
    let bootResult = runCommand(executable: "/bin/launchctl", arguments: ["bootout", serviceTarget])
    if bootResult.status == 0 {
        print(tr("✓ 成功从系统 launchd 中卸载服务 (\(serviceTarget))",
                 "✓ Unloaded service from system launchd (\(serviceTarget))"))
        unloaded = true
    } else {
        print(tr("• 服务当前未在运行或已被卸载。", "• Service is not currently running or already unloaded."))
    }

    var removedPlist = false
    if FileManager.default.fileExists(atPath: plistURL.path) {
        do {
            try FileManager.default.removeItem(at: plistURL)
            print(tr("✓ 已删除服务描述文件: \(plistURL.path)", "✓ Removed LaunchAgent plist: \(plistURL.path)"))
            removedPlist = true
        } catch {
            fputs(tr("✗ 删除描述文件失败: \(error.localizedDescription)\n",
                     "✗ Failed to remove plist: \(error.localizedDescription)\n"), stderr)
        }
    } else {
        print(tr("• 描述文件不存在: \(plistURL.path)", "• Plist file does not exist: \(plistURL.path)"))
    }

    var removedDir = false
    if FileManager.default.fileExists(atPath: installDir.path) {
        do {
            try FileManager.default.removeItem(at: installDir)
            print(tr("✓ 已清理部署运行目录: \(installDir.path)", "✓ Removed runtime directory: \(installDir.path)"))
            removedDir = true
        } catch {
            fputs(tr("✗ 清理目录失败: \(error.localizedDescription)\n",
                     "✗ Failed to clean directory: \(error.localizedDescription)\n"), stderr)
        }
    }

    if unloaded || removedPlist || removedDir {
        print(tr("\n自启动服务与部署文件已彻底移除。", "\nLaunchAgent service and deployed files completely removed."))
        writeLog("LaunchAgent uninstalled")
    } else {
        print(tr("\n无需清理。", "\nNothing to clean."))
    }
}

func checkServiceStatus() {
    print(tr("""
    Auto Mount Tool - 运行状态总览 (v\(autoMountVersion))
    ====================================
    """, """
    Auto Mount Tool - Service Status Overview (v\(autoMountVersion))
    ================================================
    """))

    let plistURL = getLaunchAgentPlistURL()
    let installDir = getInstalledDir()
    let uid = getuid()
    let serviceTarget = "gui/\(uid)/\(launchAgentLabel)"

    let plistExists = FileManager.default.fileExists(atPath: plistURL.path)
    print(tr("  • LaunchAgent 服务配置: \(plistExists ? "已安装 (\(plistURL.path))" : "未安装")",
             "  • LaunchAgent Configuration: \(plistExists ? "Installed (\(plistURL.path))" : "Not Installed")"))

    let installedExists = FileManager.default.fileExists(atPath: installDir.path)
    if installedExists {
        print(tr("  • 部署运行目录: \(installDir.path)", "  • Runtime Directory: \(installDir.path)"))
    }

    let res = runCommand(executable: "/bin/launchctl", arguments: ["print", serviceTarget])
    if res.status == 0 {
        print(tr("  • launchd 运行状态: 已加载并处于激活监听中 (gui/\(uid))",
                 "  • launchd Status: Active & listening (gui/\(uid))"))
        for line in res.stdout.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.starts(with: "state = ") || trimmed.starts(with: "last exit code = ") || trimmed.starts(with: "pid = ") {
                print("    \(trimmed)")
            }
        }
    } else {
        print(tr("  • launchd 运行状态: 未加载 / 处于休眠状态", "  • launchd Status: Inactive / Not loaded"))
    }

    print(tr("\n  • 当前物理网络状态:", "\n  • Physical Network Status:"))
    if let gw = getPhysicalGatewayInfo() {
        print(tr("    物理网卡: \(gw.interface)", "    Physical Interface: \(gw.interface)"))
        print(tr("    物理网关 IP: \(gw.ip)", "    Physical Gateway IP: \(gw.ip)"))
        if let mac = getMACAddress(for: gw.ip, interface: gw.interface) {
            print(tr("    物理网关 MAC: \(mac)", "    Physical Gateway MAC: \(mac)"))
        } else {
            print(tr("    物理网关 MAC: (ARP 缓存中未找到)", "    Physical Gateway MAC: (Not found in ARP cache)"))
        }
    } else {
        print(tr("    未检测到活跃的底层物理网络。", "    No active physical network detected."))
    }

    print(tr("\n  • 已配置策略列表:", "\n  • Configured Policy Profiles:"))
    if let config = loadConfig() {
        print(tr("    配置版本: \(config.version)", "    Config Version: \(config.version)"))
        let kernelEntries = getKernelMountEntries()

        for (idx, profile) in config.profiles.enumerated() {
            print(tr("\n    [\(idx + 1)] 策略: \(profile.id) (\(profile.description ?? "无描述"))",
                     "\n    [\(idx + 1)] Profile: \(profile.id) (\(profile.description ?? "No description"))"))
            print(tr("        匹配条件: \(profile.match.type) = \(profile.match.value)",
                     "        Match Rule: \(profile.match.type) = \(profile.match.value)"))
            if let excludes = profile.excludeGatewayIPs, !excludes.isEmpty {
                print(tr("        排除网关: \(excludes.joined(separator: ", "))",
                         "        Exclude Gateways: \(excludes.joined(separator: ", "))"))
            }
            print(tr("        挂载目标 (\(profile.targets.count)):", "        Mount Targets (\(profile.targets.count)):"))
            for t in profile.targets {
                let stdPath = URL(fileURLWithPath: t.mountPath).standardizedFileURL.path
                if let entry = kernelEntries.first(where: { URL(fileURLWithPath: $0.mountPath).standardizedFileURL.path == stdPath }) {
                    print(tr("          - \(t.mountPath) -> 已挂载 (来源: \(entry.source))",
                             "          - \(t.mountPath) -> Mounted (Source: \(entry.source))"))
                } else {
                    print(tr("          - \(t.mountPath) -> 未挂载 (目标: \(t.url))",
                             "          - \(t.mountPath) -> Not Mounted (Target: \(t.url))"))
                }
            }
        }
    } else {
        print(tr("    未找到配置文件 (可运行: ./auto_mount --init 初始化)",
                 "    Configuration file not found (Run: ./auto_mount --init to initialize)"))
    }

    if let config = loadConfig() {
        let channel = config.updateChannel ?? "off"
        print(tr("\n  • 软件版本: v\(autoMountVersion) (自动更新信道: \(channel))",
                 "\n  • Software Version: v\(autoMountVersion) (Update Channel: \(channel))"))
    } else {
        print(tr("\n  • 软件版本: v\(autoMountVersion)", "\n  • Software Version: v\(autoMountVersion)"))
    }
}

// MARK: - 软件生命周期与自升级系统 (Self-Update & Release Probing)

func quoteAppleScript(_ str: String) -> String {
    let escaped = str.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}

func showMacOSNotification(title: String, subtitle: String, message: String) {
    let script = "display notification \(quoteAppleScript(message)) with title \(quoteAppleScript(title)) subtitle \(quoteAppleScript(subtitle))"
    _ = runCommand(executable: "/usr/bin/osascript", arguments: ["-e", script])
}

func parseSemanticVersion(_ versionStr: String) -> [Int] {
    var clean = versionStr.trimmingCharacters(in: .whitespacesAndNewlines)
    if clean.hasPrefix("v") || clean.hasPrefix("V") {
        clean.removeFirst()
    }
    return clean.split(separator: ".").compactMap { Int($0) }
}

func isNewerVersion(_ remote: String, than current: String) -> Bool {
    let rParts = parseSemanticVersion(remote)
    let cParts = parseSemanticVersion(current)
    let maxLen = max(rParts.count, cParts.count)
    for i in 0..<maxLen {
        let r = i < rParts.count ? rParts[i] : 0
        let c = i < cParts.count ? cParts[i] : 0
        if r > c { return true }
        if r < c { return false }
    }
    return false
}

struct GitHubReleaseInfo {
    let tagName: String
    let name: String
    let body: String
    let publishedAt: String?
}

enum ReleaseFetchResult {
    case success(GitHubReleaseInfo)
    case noReleasesFound
    case networkError
}

func fetchLatestReleaseInfo() -> ReleaseFetchResult {
    let apiURLString = "https://api.github.com/repos/\(githubRepo)/releases/latest"
    guard let url = URL(string: apiURLString) else { return .networkError }

    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5.0)
    request.setValue("AutoMount/\(autoMountVersion)", forHTTPHeaderField: "User-Agent")
    request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

    let semaphore = DispatchSemaphore(value: 0)
    var result: ReleaseFetchResult = .networkError

    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        if error != nil {
            result = .networkError
            return
        }
        guard let httpRes = response as? HTTPURLResponse else {
            result = .networkError
            return
        }
        if httpRes.statusCode == 404 {
            result = .noReleasesFound
            return
        }
        guard httpRes.statusCode == 200, let data = data else {
            result = .networkError
            return
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tagName = json["tag_name"] as? String else {
            result = .networkError
            return
        }
        let name = (json["name"] as? String) ?? tagName
        let body = (json["body"] as? String) ?? ""
        let publishedAt = json["published_at"] as? String
        result = .success(GitHubReleaseInfo(tagName: tagName, name: name, body: body, publishedAt: publishedAt))
    }
    task.resume()
    _ = semaphore.wait(timeout: .now() + 6.0)
    return result
}

func downloadLatestSource(tag: String) -> String? {
    let rawURLString = "https://raw.githubusercontent.com/\(githubRepo)/\(tag)/auto_mount.swift"
    guard let url = URL(string: rawURLString) else { return nil }

    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10.0)
    request.setValue("AutoMount/\(autoMountVersion)", forHTTPHeaderField: "User-Agent")

    let semaphore = DispatchSemaphore(value: 0)
    var downloadedContent: String?

    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        guard error == nil, let data = data,
              let httpRes = response as? HTTPURLResponse, httpRes.statusCode == 200,
              let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return
        }
        downloadedContent = text
    }
    task.resume()
    _ = semaphore.wait(timeout: .now() + 11.0)
    return downloadedContent
}

func verifySwiftSyntax(sourceCode: String) -> Bool {
    let tempDir = FileManager.default.temporaryDirectory
    let tempFile = tempDir.appendingPathComponent("automount_check_\(UUID().uuidString).swift")
    do {
        try sourceCode.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        process.arguments = ["-parse", tempFile.path]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

func performSelfUpdate(newVersion: String, newContent: String, isSilent: Bool) -> Bool {
    // 1. 本地语法分析预检
    if !verifySwiftSyntax(sourceCode: newContent) {
        let err = tr("✗ 新版本代码本地 Swift 语法预检失败，已自动终止更新，保护当前运行环境安全。",
                     "✗ Swift syntax check failed for the new version. Aborted update to protect daemon.")
        fputs("\(err)\n", stderr)
        writeLog("Self-update aborted: syntax check failed for version \(newVersion)")
        if !isSilent {
            showMacOSNotification(
                title: tr("AutoMount 升级未完成", "AutoMount Update Incomplete"),
                subtitle: tr("语法校验未通过", "Syntax Validation Failed"),
                message: tr("下载的代码预检未通过，当前运行未受影响。", "Downloaded code failed syntax check. Current runtime unchanged.")
            )
        }
        return false
    }

    let installDir = getInstalledDir()
    let currentAppDir = getAppDir()
    var updatedPaths: [String] = []

    // 2. 更新运行目录 ~/Library/Application Support/AutoMount/auto_mount.swift
    let targetInstalledSwift = installDir.appendingPathComponent("auto_mount.swift")
    if FileManager.default.fileExists(atPath: installDir.path) {
        do {
            try newContent.write(to: targetInstalledSwift, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: targetInstalledSwift.path)
            updatedPaths.append(targetInstalledSwift.path)
        } catch {
            fputs("✗ \(error.localizedDescription)\n", stderr)
        }
    }

    // 3. 若当前处于工程工作区且存在 auto_mount.swift，一并同步工作区
    let localSwift = currentAppDir.appendingPathComponent("auto_mount.swift")
    if FileManager.default.fileExists(atPath: localSwift.path) && localSwift.path != targetInstalledSwift.path {
        do {
            try newContent.write(to: localSwift, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: localSwift.path)
            updatedPaths.append(localSwift.path)
        } catch {
            // 忽略非工作区权限写入限制
        }
    }

    // 4. 重载 LaunchAgent 守护服务
    let uid = getuid()
    let serviceTarget = "gui/\(uid)/\(launchAgentLabel)"
    let plistURL = getLaunchAgentPlistURL()
    if FileManager.default.fileExists(atPath: plistURL.path) {
        _ = runCommand(executable: "/bin/launchctl", arguments: ["bootout", serviceTarget])
        _ = runCommand(executable: "/bin/launchctl", arguments: ["bootstrap", "gui/\(uid)", plistURL.path])
    }

    writeLog("Self-update succeeded to \(newVersion). Updated files: \(updatedPaths.joined(separator: ", "))")

    if isSilent {
        showMacOSNotification(
            title: tr("AutoMount 自动升级成功", "AutoMount Updated Successfully"),
            subtitle: tr("已自动平滑热升级至 \(newVersion)", "Updated seamlessly to \(newVersion)"),
            message: tr("网络挂载与守护服务已恢复最新就绪状态。", "Mount engine and daemon are updated and running.")
        )
    } else {
        print(tr("✓ 软件已成功升级至 \(newVersion)！", "✓ Successfully updated to \(newVersion)!"))
        if !updatedPaths.isEmpty {
            print(tr("  已同步更新组件:\n    \(updatedPaths.joined(separator: "\n    "))",
                     "  Synchronized components:\n    \(updatedPaths.joined(separator: "\n    "))"))
        }
        print(tr("✓ 后台守护服务已自动完成热重载并就绪。", "✓ Background daemon reloaded and active."))
    }
    return true
}

func triggerBackgroundUpdateCheckIfNeeded(config: inout AutoMountConfig) {
    let channel = config.updateChannel ?? "off"
    guard channel == "notify" || channel == "auto" else { return }

    let now = Date().timeIntervalSince1970
    let cooldown: Double = 86400 // 24 小时冷却窗口

    if let last = config.lastUpdateCheckTimestamp, (now - last) < cooldown {
        return // 冷却中，跳过
    }

    // 记录本次检查时间并写回
    config.lastUpdateCheckTimestamp = now
    saveConfig(config)

    writeLog("Starting background update check (channel: \(channel))...")
    guard case .success(let release) = fetchLatestReleaseInfo() else { return }
    let remoteVersion = release.tagName
    guard isNewerVersion(remoteVersion, than: autoMountVersion) else { return }

    writeLog("New version discovered: \(remoteVersion) (current: \(autoMountVersion)), channel: \(channel)")

    if channel == "notify" {
        // 单版本仅提醒 1 次防打扰机制
        if config.lastNotifiedVersion == remoteVersion {
            writeLog("Update notification for \(remoteVersion) already presented once. Skipping.")
            return
        }

        showMacOSNotification(
            title: tr("AutoMount 新版本提醒", "AutoMount Update Available"),
            subtitle: tr("发现新版本 \(remoteVersion) (当前: v\(autoMountVersion))",
                         "New version \(remoteVersion) available (Current: v\(autoMountVersion))"),
            message: tr("可运行 './auto_mount --update' 完成升级。",
                         "Run './auto_mount --update' to upgrade.")
        )

        config.lastNotifiedVersion = remoteVersion
        saveConfig(config)
    } else if channel == "auto" {
        if let sourceCode = downloadLatestSource(tag: remoteVersion) {
            _ = performSelfUpdate(newVersion: remoteVersion, newContent: sourceCode, isSilent: true)
        }
    }
}

func getInstalledAppVersion() -> String? {
    let installDir = getInstalledDir()
    let installedBinary = installDir.appendingPathComponent("auto_mount").path
    let installedSwift = installDir.appendingPathComponent("auto_mount.swift").path

    let targetPath = FileManager.default.fileExists(atPath: installedBinary) ? installedBinary : (FileManager.default.fileExists(atPath: installedSwift) ? installedSwift : nil)
    guard let exePath = targetPath else { return nil }

    let result = runCommand(executable: exePath, arguments: ["--version"])
    if result.status == 0 {
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil {
            return trimmed
        }
    }

    let swiftPath = FileManager.default.fileExists(atPath: installedSwift) ? installedSwift : (FileManager.default.fileExists(atPath: installedBinary) ? installedBinary : nil)
    if let path = swiftPath, let content = try? String(contentsOfFile: path, encoding: .utf8) {
        let pattern = #"let\s+autoMountVersion\s*=\s*"([^"]+)""#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
           let range = Range(match.range(at: 1), in: content) {
            return String(content[range])
        }
    }
    return nil
}

func syncCurrentToInstalledDaemon() -> Bool {
    let currentAppDir = getAppDir()
    let installDir = getInstalledDir()
    guard FileManager.default.fileExists(atPath: installDir.path) else { return false }

    let filesToSync = ["auto_mount", "auto_mount.swift", "auto_mount.plist"]
    for fileName in filesToSync {
        let srcURL = currentAppDir.appendingPathComponent(fileName)
        let dstURL = installDir.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: srcURL.path) {
            try? FileManager.default.removeItem(at: dstURL)
            try? FileManager.default.copyItem(at: srcURL, to: dstURL)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dstURL.path)
        }
    }

    let uid = getuid()
    let serviceTarget = "gui/\(uid)/\(launchAgentLabel)"
    let plistURL = getLaunchAgentPlistURL()
    if FileManager.default.fileExists(atPath: plistURL.path) {
        _ = runCommand(executable: "/bin/launchctl", arguments: ["bootout", serviceTarget])
        _ = runCommand(executable: "/bin/launchctl", arguments: ["bootstrap", "gui/\(uid)", plistURL.path])
    }
    writeLog("Synchronized current workspace build to LaunchAgent runtime and reloaded daemon.")
    return true
}

func checkAndSyncInstalledIfOutdated(currentVersion: String, installedVersion: String?) {
    guard let instVer = installedVersion else { return }
    guard isNewerVersion(currentVersion, than: instVer) else {
        if instVer == currentVersion {
            print(tr("✓ 后台守护服务版本一致 (v\(instVer))，无需同步。",
                     "✓ Daemon service is in sync (v\(instVer))."))
        }
        return
    }

    print(tr("\n💡 检测到后台守护服务版本 (v\(instVer)) 落后于当前工作区 (v\(currentVersion))！",
             "\n💡 Daemon service version (v\(instVer)) is older than current workspace (v\(currentVersion))!"))
    print(tr("是否立即将当前工作区最新程序同步至后台守护服务？(Y/n) [默认 Y]: ",
             "Synchronize current workspace build to daemon service now? (Y/n) [Default Y]: "), terminator: "")
    let confirm = (readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "y")
    if confirm == "y" || confirm == "yes" || confirm.isEmpty {
        if syncCurrentToInstalledDaemon() {
            print(tr("✓ 已成功将后台守护服务同步升级至 v\(currentVersion)，并已热重载生效！",
                     "✓ Successfully updated and reloaded daemon service to v\(currentVersion)!"))
        } else {
            print(tr("✗ 同步至后台守护服务失败，请尝试运行 './auto_mount --install'。",
                     "✗ Failed to sync daemon service. Try running './auto_mount --install' manually."))
        }
    } else {
        print(tr("已跳过后台守护服务同步。", "Skipped daemon service sync."))
    }
}

func handleManualUpdateCommand() {
    print(tr("""
    Auto Mount Tool - 软件版本检测与自升级
    ======================================
    """, """
    Auto Mount Tool - Software Update
    =================================
    """))

    let currentVersion = autoMountVersion
    let installedVersion = getInstalledAppVersion()
    let currentDir = getAppDir()
    let installDir = getInstalledDir()
    let isRunningFromWorkspace = currentDir.path != installDir.path

    if isRunningFromWorkspace {
        print(tr("  • 当前运行程序: \(currentDir.appendingPathComponent("auto_mount").path) (v\(currentVersion))",
                 "  • Current Executable: \(currentDir.appendingPathComponent("auto_mount").path) (v\(currentVersion))"))
        if let instVer = installedVersion {
            let status = (instVer == currentVersion) ? tr("版本一致", "In sync") : tr("待更新", "Out of sync")
            print(tr("  • 后台守护服务: \(installDir.appendingPathComponent("auto_mount").path) (v\(instVer), \(status))",
                     "  • Daemon Service: \(installDir.appendingPathComponent("auto_mount").path) (v\(instVer), \(status))"))
        } else {
            print(tr("  • 后台守护服务: 未安装", "  • Daemon Service: Not installed"))
        }
    } else {
        print(tr("  • 当前运行程序: \(installDir.appendingPathComponent("auto_mount").path) (v\(currentVersion), 守护服务运行目录)",
                 "  • Current Executable: \(installDir.appendingPathComponent("auto_mount").path) (v\(currentVersion), Daemon Runtime)"))
    }

    print(tr("\n正在检索 GitHub 官方最新发布版本 (https://github.com/\(githubRepo))...",
             "\nChecking latest release from GitHub (https://github.com/\(githubRepo))..."))

    let fetchResult = fetchLatestReleaseInfo()
    let release: GitHubReleaseInfo
    switch fetchResult {
    case .success(let info):
        release = info
    case .noReleasesFound:
        print(tr("✓ 官方仓库目前尚未发布正式 Release 版本，本地 (v\(currentVersion)) 为最新状态。",
                 "✓ No official release published yet on remote. Current local (v\(currentVersion)) is up to date."))
        checkAndSyncInstalledIfOutdated(currentVersion: currentVersion, installedVersion: installedVersion)
        return
    case .networkError:
        print(tr("✗ 无法连接到 GitHub 检查更新，请检查网络连接或稍后重试。",
                 "✗ Failed to check for updates. Please check network connection."))
        checkAndSyncInstalledIfOutdated(currentVersion: currentVersion, installedVersion: installedVersion)
        return
    }

    let remoteVersion = release.tagName
    print(tr("远端最新版本: \(remoteVersion)", "Latest remote release: \(remoteVersion)"))

    if !isNewerVersion(remoteVersion, than: currentVersion) {
        print(tr("✓ 当前运行程序已经是最新版本 (v\(currentVersion))。",
                 "✓ Current executable is already up to date (v\(currentVersion))."))
        checkAndSyncInstalledIfOutdated(currentVersion: currentVersion, installedVersion: installedVersion)
        return
    }

    print(tr("\n💡 发现新版本: \(remoteVersion)！", "\n💡 New version available: \(remoteVersion)!"))
    let releaseBody = release.body.trimmingCharacters(in: .whitespacesAndNewlines)
    if !releaseBody.isEmpty {
        print(tr("\n更新说明：\n\(releaseBody)\n", "\nRelease Notes:\n\(releaseBody)\n"))
    }

    print(tr("是否立即下载并升级至 \(remoteVersion)？(Y/n) [默认 Y]: ",
             "Do you want to download and upgrade to \(remoteVersion) now? (Y/n) [Default Y]: "), terminator: "")
    let confirm = (readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "y")
    if confirm != "y" && confirm != "yes" {
        print(tr("已取消升级。", "Update cancelled."))
        return
    }

    print(tr("\n正在下载最新源码...", "\nDownloading latest source code..."))
    guard let source = downloadLatestSource(tag: remoteVersion) else {
        print(tr("✗ 下载最新代码失败，请稍后重试。", "✗ Failed to download latest source code."))
        return
    }

    print(tr("正在进行本地 Swift 语法预检...", "Performing local Swift syntax validation..."))
    _ = performSelfUpdate(newVersion: remoteVersion, newContent: source, isSilent: false)
}

func printUsage() {
    let configPath = getConfigURL().path
    print(tr("""
    Auto Mount Tool (v\(autoMountVersion))
    ========================

    使用方法:
      ./auto_mount                正常执行 (评估网络策略并挂载匹配目标)
      ./auto_mount --init         初始化配置向导 (支持自动嗅探与复选框交互)
      ./auto_mount --config       日常配置管理 (增删目标、修改网关或远程节点、服务管理)
      ./auto_mount --install      配置并启用自启动后台守护服务 (LaunchAgent)
      ./auto_mount --uninstall    移除自启动配置与部署文件
      ./auto_mount --status       查看服务运行状态与挂载详情
      ./auto_mount --update       检查并升级软件至最新版本 (支持本地语法校验)
      ./auto_mount --version, -v  查看当前软件版本号
      ./auto_mount --help, -h     显示帮助说明

    环境变量:
      AUTO_MOUNT_LANG=zh|en       强制指定终端界面语言

    配置文件: \(configPath)
    """, """
    Auto Mount Tool (v\(autoMountVersion))
    ========================

    Usage:
      ./auto_mount                Run normal evaluation and mount targets
      ./auto_mount --init         Interactive setup wizard (with device discovery)
      ./auto_mount --config       Daily configuration & daemon management menu
      ./auto_mount --install      Deploy and enable background LaunchAgent daemon
      ./auto_mount --uninstall    Remove LaunchAgent daemon and deployed files
      ./auto_mount --status       Show service status and active mount details
      ./auto_mount --update       Check and self-update to latest release
      ./auto_mount --version, -v  Show software version
      ./auto_mount --help, -h     Show this help message

    Environment Variables:
      AUTO_MOUNT_LANG=zh|en       Explicitly specify terminal UI language

    Configuration: \(configPath)
    """))
}

// MARK: - 主流程执行逻辑

func main() {
    let args = CommandLine.arguments

    if args.count > 1 {
        let arg = args[1]
        switch arg {
        case "--init":
            runInitWizard()
            exit(0)
        case "--config":
            manageConfiguration()
            exit(0)
        case "--install":
            installLaunchAgent()
            exit(0)
        case "--uninstall":
            uninstallLaunchAgent()
            exit(0)
        case "--status":
            checkServiceStatus()
            exit(0)
        case "--update":
            handleManualUpdateCommand()
            exit(0)
        case "--version", "-v":
            print(autoMountVersion)
            exit(0)
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            fputs(tr("✗ 未知参数: '\(arg)'\n\n", "✗ Unknown option: '\(arg)'\n\n"), stderr)
            printUsage()
            exit(1)
        }
    }

    print(tr("""
    Auto Mount Tool (v\(autoMountVersion))
    ======================
    """, """
    Auto Mount Tool (v\(autoMountVersion))
    ======================
    """))

    guard var config = loadConfig(), !config.profiles.isEmpty else {
        fputs(tr("✗ 未找到有效配置，请先运行 './auto_mount --init' 初始化。\n",
                 "✗ Configuration not found or empty. Please run './auto_mount --init' first.\n"), stderr)
        writeLog("Config not found or empty, exiting")
        exit(1)
    }

    // 1. 采集物理网络信息
    print(tr("[1] 评估当前底层物理网络环境...", "[1] Evaluating network environment..."))
    let currentGateway = getPhysicalGatewayInfo()
    let currentMAC = getCurrentNetworkFingerprint()

    if let gw = currentGateway {
        print(tr("  物理网关: \(gw.ip) (网卡: \(gw.interface))", "  Physical Gateway: \(gw.ip) on \(gw.interface)"))
    } else {
        print(tr("  物理网关: 无 (处于离线状态)", "  Physical Gateway: None (offline)"))
    }
    if let mac = currentMAC {
        print(tr("  物理网关 MAC: \(mac)", "  Physical Gateway MAC: \(mac)"))
    }

    // 2. 顺序评估策略路由
    print(tr("\n[2] 顺序评估网络策略路由...", "\n[2] Evaluating policy profiles..."))
    var matchedProfile: NetworkProfile?

    for (idx, profile) in config.profiles.enumerated() {
        print(tr("  正在校验 [\(idx + 1)] '\(profile.id)' (\(profile.description ?? "")):",
                 "  Checking [\(idx + 1)] '\(profile.id)' (\(profile.description ?? "")):"))

        if let excludes = profile.excludeGatewayIPs, let gwIP = currentGateway?.ip, excludes.contains(gwIP) {
            print(tr("    ✗ 已跳过: 网关 IP \(gwIP) 处于排除名单中 (蜂窝热点流量保护)。",
                     "    ✗ Skipped: Gateway IP \(gwIP) is excluded (Hotspot bypass)."))
            writeLog("Profile \(profile.id) skipped: Gateway IP \(gwIP) is in exclude_gateway_ips")
            continue
        }

        switch profile.match.type {
        case "gateway_mac":
            guard let curMAC = currentMAC else {
                print(tr("    ✗ 未探测到物理网关 MAC 指纹。", "    ✗ No gateway MAC detected."))
                continue
            }
            if curMAC.caseInsensitiveCompare(profile.match.value) == .orderedSame {
                print(tr("    ✓ 策略命中！(网关 MAC 吻合 \(profile.match.value))",
                         "    ✓ Matched! (Gateway MAC matches \(profile.match.value))"))
                matchedProfile = profile
            } else {
                print(tr("    ✗ 不匹配 (当前 MAC: \(curMAC) != 期望: \(profile.match.value))",
                         "    ✗ Mismatch (Current MAC: \(curMAC) != \(profile.match.value))"))
            }

        case "probe_host":
            let retries = profile.match.retryCount ?? 3
            let interval = profile.match.retryInterval ?? 1.0
            print(tr("    正在探测主机 \(profile.match.value) (重试窗口: \(retries) 次, 间隔: \(interval) 秒)...",
                     "    Probing \(profile.match.value) (Retry window: \(retries) attempts, interval: \(interval)s)..."))
            if probeHostWithRetries(host: profile.match.value, retries: retries, interval: interval) {
                print(tr("    ✓ 策略命中！(主机 \(profile.match.value) 可达)",
                         "    ✓ Matched! (Host \(profile.match.value) is reachable)"))
                matchedProfile = profile
            } else {
                print(tr("    ✗ 在 \(retries) 次尝试后主机 \(profile.match.value) 依然不可达。",
                         "    ✗ Host \(profile.match.value) unreachable after \(retries) attempts."))
            }

        default:
            print(tr("    ✗ 未知匹配规则类型: \(profile.match.type)",
                     "    ✗ Unknown match type: \(profile.match.type)"))
        }

        if matchedProfile != nil {
            break
        }
    }

    guard let profile = matchedProfile else {
        print(tr("\n[DONE] 当前网络状态未匹配到任何策略。正常退出。",
                 "\n[DONE] No matching profile for current network state. Exiting cleanly."))
        writeLog("No matching profile for current network, exiting")
        triggerBackgroundUpdateCheckIfNeeded(config: &config)
        exit(0)
    }

    print(tr("\n[3] 执行匹配策略: '\(profile.id)'", "\n[3] Executing active profile: '\(profile.id)'"))
    writeLog("Executing profile: \(profile.id)")

    var mountedCount = 0
    for target in profile.targets {
        print(tr("  目标: \(target.mountPath) (\(target.url))", "  Target: \(target.mountPath) (\(target.url))"))

        let status = ensureMountPointReady(target: target)
        switch status {
        case .alreadyMountedHealthy:
            print(tr("    ✓ 卷宗已挂载且响应正常，跳过。", "    ✓ Already mounted and responsive, skipping."))
            mountedCount += 1
            continue

        case .readyToMount:
            print(tr("    正在通过 NetFS 系统框架静默挂载...", "    Mounting volume via NetFS..."))
            if silentMount(urlString: target.url) {
                mountedCount += 1
                if profile.preventSpotlightIndex ?? true {
                    disableSpotlightIndex(at: target.mountPath)
                }
            }

        case .unmountFailed:
            print(tr("    ✗ 挂载点繁忙或无法清除，跳过此目标。", "    ✗ Mount point busy or cannot be cleared, skipping."))
        }
    }

    print(tr("\n[DONE] 策略 '\(profile.id)' 下已成功挂载 \(mountedCount)/\(profile.targets.count) 个卷宗。",
             "\n[DONE] \(mountedCount)/\(profile.targets.count) volumes mounted under '\(profile.id)'."))
    writeLog("Finished execution of '\(profile.id)': \(mountedCount)/\(profile.targets.count) mounted.")
    triggerBackgroundUpdateCheckIfNeeded(config: &config)
}

main()
