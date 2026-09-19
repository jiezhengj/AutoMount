#!/usr/bin/env swift
// auto_mount.swift
// 自动挂载 NAS 工具 (macOS 27 多网络策略路由与现代化交互版 - 2.0)
//
// 核心架构与特性：
// 1. 多策略优先级路由 (Profiles)：家庭局域网 (home_lan) 优先直连；离开家庭网自动降级至 Tailscale 异地互联 (tailscale_remote)。
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

// MARK: - 基础辅助函数

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

// MARK: - 2.0 数据结构定义

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
    var profiles: [NetworkProfile]
}

// 加载 2.0 配置
func loadConfig() -> AutoMountConfig? {
    let configURL = getConfigURL()
    guard let data = try? Data(contentsOf: configURL) else { return nil }
    let decoder = PropertyListDecoder()
    return try? decoder.decode(AutoMountConfig.self, from: data)
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
            print("✓ Synchronized updated configuration to LaunchAgent runtime: \(dstURL.path)")
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
        print("✓ Config saved to: \(configURL.path)")
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
        print("请输入要选择的序号 (例如 1,2 或 all，按回车全不选): ", terminator: "")
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
    print("\u{1b}[90m(↑/↓ 移动光标，Space 切换勾选，a 全选，Enter 确认提交)\u{1b}[0m")
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
            print("\n操作已取消。")
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
        print("请选择序号 [默认 \(defaultIndex + 1)]: ", terminator: "")
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
    print("\u{1b}[90m(↑/↓ 移动光标，Enter 选定确认)\u{1b}[0m")
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
            print("\n操作已取消。")
            exit(0)
        default:
            break
        }
    }
}

// MARK: - 初始化向导 (--init)

func runInitWizard() {
    print("""
    Auto Mount Tool - 初始化配置向导 (v2.0)
    ======================================
    """)

    // 1. 物理网关 MAC 探测
    print("[1/3] 局域网物理网关指纹检测")
    var homeMAC = ""
    if let detectedMAC = getCurrentNetworkFingerprint() {
        print("  ✓ 自动探测到物理网关 MAC: \(detectedMAC)")
        while homeMAC.isEmpty {
            print("  按回车直接使用此指纹，或输入自定义 MAC 覆盖 [默认: \(detectedMAC)]: ", terminator: "")
            let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            homeMAC = input.isEmpty ? detectedMAC : input
            if homeMAC.isEmpty {
                print("  ✗ 网关 MAC 不能为空，请重新输入。")
            }
        }
    } else {
        while homeMAC.isEmpty {
            print("  未能自动获取物理网关 MAC，请输入网关 MAC 地址: ", terminator: "")
            homeMAC = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if homeMAC.isEmpty {
                print("  ✗ 网关 MAC 不能为空，请重新输入。")
            }
        }
    }

    // 2. 挂载目标选择 (自动嗅探 + 复选框多选)
    print("\n[2/3] 选择家庭局域网挂载目标")
    var homeTargets: [MountTarget] = []
    let activeMounts = discoverActiveSMBMounts()

    if !activeMounts.isEmpty {
        let options = activeMounts.map { SelectionOption(title: URL(fileURLWithPath: $0.path).lastPathComponent, subtitle: $0.url) }
        let selectedIndices = promptInteractiveCheckbox(
            title: "发现当前系统中已挂载的 SMB 卷宗，请选择需要纳入自动挂载的目标 (直接按回车跳过)：",
            options: options
        )
        for idx in selectedIndices {
            let item = activeMounts[idx]
            homeTargets.append(MountTarget(url: item.url, mountPath: item.path))
            print("  ✓ 已添加: \(item.path) (\(item.url))")
        }
    }

    // 若未勾选任何已挂载项，引导手动录入或直接跳过
    if homeTargets.isEmpty {
        print("  当前未选择已挂载卷宗，可手动录入 (直接按回车可跳过此步骤)：")
        while true {
            print("  请输入 SMB 地址 (例如 smb://server.local/share，按回车跳过): ", terminator: "")
            guard let urlStr = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !urlStr.isEmpty else {
                break
            }
            let defaultPath = deriveDefaultMountPath(from: urlStr)
            print("  请输入本地挂载路径 [默认: \(defaultPath)]: ", terminator: "")
            let pathInput = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let pathStr = pathInput.isEmpty ? defaultPath : pathInput
            homeTargets.append(MountTarget(url: urlStr, mountPath: pathStr))
            print("  ✓ 已添加: \(pathStr) (\(urlStr))")
            print("  继续添加另一个挂载目标？(y/n) [默认 n]: ", terminator: "")
            let cont = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "n"
            if cont != "y" && cont != "yes" {
                break
            }
        }
    }

    if homeTargets.isEmpty {
        print("  ✓ 局域网内不挂载任何共享，该网络仅作为外出判定排他基准。")
    }

    let homeProfile = NetworkProfile(
        id: "home_lan",
        description: "家庭局域网直连 (千兆/2.5G 高速)",
        match: MatchRule(type: "gateway_mac", value: homeMAC, retryCount: nil, retryInterval: nil),
        excludeGatewayIPs: nil,
        preventSpotlightIndex: true,
        targets: homeTargets
    )

    // 3. Tailscale 远程降级策略配置
    print("\n[3/3] 配置 Tailscale 远程互联降级策略")
    var profiles: [NetworkProfile] = [homeProfile]
    let discoveredPeers = discoverTailscalePeers()

    if discoveredPeers.isEmpty {
        print("  未检测到 Tailscale 正在运行或在线节点，已跳过远程策略配置。")
        print("  （提示：后续连接 Tailscale 后，可运行 './auto_mount --config' 随时补齐远程策略）")
    } else {
        var peerOptions = discoveredPeers.map {
            SelectionOption(title: $0.name, subtitle: "MagicDNS: \($0.magicDNS ?? "无"), IP: \($0.ip), OS: \($0.os)")
        }
        peerOptions.append(SelectionOption(title: "跳过配置远程策略", subtitle: nil))

        let selected = promptInteractiveRadio(
            title: "检测到 Tailscale 正在运行，请选择对端访问设备：",
            options: peerOptions,
            defaultIndex: 0
        )

        if selected < discoveredPeers.count {
            let peer = discoveredPeers[selected]
            let selectedPeerName = peer.name
            var selectedHost = ""

            // 选择连接地址格式：MagicDNS 域名 或 虚拟 IP
            var addrOptions: [SelectionOption] = []
            if let dns = peer.magicDNS {
                addrOptions.append(SelectionOption(title: "MagicDNS 域名: \(dns)", subtitle: "推荐：IP 变动不失效，钥匙串凭据稳定"))
            }
            if !peer.ip.isEmpty {
                addrOptions.append(SelectionOption(title: "Tailscale IP: \(peer.ip)", subtitle: "直连无 DNS 解析依赖"))
            }

            if !addrOptions.isEmpty {
                let chosenAddr = promptInteractiveRadio(title: "请选择连接方式：", options: addrOptions, defaultIndex: 0)
                if addrOptions[chosenAddr].title.starts(with: "MagicDNS") {
                    selectedHost = peer.magicDNS ?? peer.ip
                } else {
                    selectedHost = peer.ip
                }
            } else {
                selectedHost = peer.ip
            }

            var remoteTargets: [MountTarget] = []

            // 路径 1：若已配置家庭局域网目标，询问是否自动映射
            var didAutoMap = false
            if !homeTargets.isEmpty {
                print("\n  是否自动将已选的家庭局域网共享目录映射为该远程主机目标？(Y/n) [默认 Y]: ", terminator: "")
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
                        print("  ✓ 自动映射: \(remoteURL) -> \(target.mountPath)")
                    }
                }
            }

            // 路径 2：若未自动映射，检查当前系统是否有挂载属于该主机的 SMB 卷
            if !didAutoMap {
                let curActive = discoverActiveSMBMounts()
                let matchingMounts = curActive.filter { mount in
                    if !selectedHost.isEmpty && mount.url.contains(selectedHost) { return true }
                    if let dns = peer.magicDNS, mount.url.contains(dns) { return true }
                    if !peer.ip.isEmpty && mount.url.contains(peer.ip) { return true }
                    return false
                }

                if !matchingMounts.isEmpty {
                    let mOptions = matchingMounts.map { SelectionOption(title: URL(fileURLWithPath: $0.path).lastPathComponent, subtitle: $0.url) }
                    let picked = promptInteractiveCheckbox(title: "检测到当前已挂载该设备的共享卷宗，请勾选需要自动挂载的项 (直接回车跳过)：", options: mOptions)
                    for pIdx in picked {
                        let item = matchingMounts[pIdx]
                        remoteTargets.append(MountTarget(url: item.url, mountPath: item.path))
                        print("  ✓ 已添加: \(item.path) (\(item.url))")
                    }
                }

                // 路径 3：若仍未选定，半自动录入共享名（或直接跳过）
                if remoteTargets.isEmpty {
                    print("  请输入远程主机上的共享文件夹名称 (直接按回车可跳过)：")
                    while true {
                        print("  请输入共享文件夹名称 (例如 data，按回车跳过): ", terminator: "")
                        guard let shareName = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !shareName.isEmpty else {
                            break
                        }
                        var cleanShare = shareName
                        while cleanShare.hasPrefix("/") { cleanShare.removeFirst() }
                        while cleanShare.hasSuffix("/") { cleanShare.removeLast() }
                        let remoteURL = "smb://\(selectedHost)/\(cleanShare)"
                        let defaultPath = "/Volumes/\(cleanShare)"
                        print("  请输入本地挂载路径 [默认: \(defaultPath)]: ", terminator: "")
                        let pathInput = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let pathStr = pathInput.isEmpty ? defaultPath : pathInput
                        remoteTargets.append(MountTarget(url: remoteURL, mountPath: pathStr))
                        print("  ✓ 已添加: \(pathStr) (\(remoteURL))")
                        print("  继续添加另一个远程挂载目标？(y/n) [默认 n]: ", terminator: "")
                        let cont = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "n"
                        if cont != "y" && cont != "yes" {
                            break
                        }
                    }
                }
            }

            if !remoteTargets.isEmpty {
                let desc = selectedPeerName.isEmpty ? "Tailscale 异地互联 (外出降级通道)" : "Tailscale 异地互联 (\(selectedPeerName))"
                let remoteProfile = NetworkProfile(
                    id: "tailscale_remote",
                    description: desc,
                    match: MatchRule(type: "probe_host", value: selectedHost, retryCount: 3, retryInterval: 1.0),
                    excludeGatewayIPs: ["172.20.10.1"],
                    preventSpotlightIndex: true,
                    targets: remoteTargets
                )
                profiles.append(remoteProfile)
            } else {
                print("  ✓ 未配置远程挂载目标，跳过远程策略。")
            }
        } else {
            print("  ✓ 已跳过配置远程策略。")
        }
    }

    // 4. 保存配置
    let config = AutoMountConfig(version: "2.0", profiles: profiles)
    saveConfig(config)
    print("\n[DONE] 初始化完成！配置已写入 \(getConfigURL().path)")
}

// MARK: - 日常配置维护菜单 (--config)

func manageConfiguration() {
    print("""
    Auto Mount Tool - 日常配置管理 (v2.0)
    ====================================
    """)

    guard var config = loadConfig() else {
        fputs("✗ 未找到配置文件，请先运行 './auto_mount --init' 初始化。\n", stderr)
        exit(1)
    }

    while true {
        print("\n当前已配置策略：")
        for (i, p) in config.profiles.enumerated() {
            if p.targets.isEmpty {
                print("  [\(i + 1)] \(p.id) (\(p.description ?? "无描述")) - 0 个挂载目标 (网络排他门牌，不执行本地挂载)")
            } else {
                print("  [\(i + 1)] \(p.id) (\(p.description ?? "无描述")) - \(p.targets.count) 个挂载目标")
                for t in p.targets {
                    print("      • \(t.mountPath) <- \(t.url)")
                }
            }
        }

        let hasTailscale = config.profiles.contains(where: { $0.id == "tailscale_remote" })
        let tailscaleActionTitle = hasTailscale ? "重新检测/更新远程 Tailscale 目标" : "配置并添加远程 Tailscale 策略"

        print("""

        请选择操作：
          [1] 添加挂载目标 (支持从当前已挂载项中导入或手动输入)
          [2] 删除已有挂载目标
          [3] 重新检测/更新家庭网关 MAC
          [4] \(tailscaleActionTitle)
          [0] 保存配置并退出
        """)
        print("请输入选项 [0-4]: ", terminator: "")
        let choice = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"

        switch choice {
        case "1":
            // 添加挂载目标
            print("\n选择要添加到的策略：")
            for (i, p) in config.profiles.enumerated() {
                print("  [\(i + 1)] \(p.id)")
            }
            print("请选择策略序号: ", terminator: "")
            guard let pStr = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let pIdx = Int(pStr), pIdx >= 1 && pIdx <= config.profiles.count else {
                print("✗ 无效选择。")
                continue
            }

            let activeMounts = discoverActiveSMBMounts()
            var added = false
            if !activeMounts.isEmpty {
                let options = activeMounts.map { SelectionOption(title: URL(fileURLWithPath: $0.path).lastPathComponent, subtitle: $0.url) }
                let selected = promptInteractiveCheckbox(title: "发现当前系统中已挂载的 SMB 卷宗，请选择添加项 (直接回车跳过)：", options: options)
                for idx in selected {
                    let item = activeMounts[idx]
                    config.profiles[pIdx - 1].targets.append(MountTarget(url: item.url, mountPath: item.path))
                    print("  ✓ 已添加: \(item.path) (\(item.url))")
                    added = true
                }
            }
            if !added {
                print("请输入 SMB 地址 (例如 smb://server.local/share): ", terminator: "")
                let urlStr = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !urlStr.isEmpty {
                    let defaultPath = deriveDefaultMountPath(from: urlStr)
                    print("请输入本地挂载路径 [默认: \(defaultPath)]: ", terminator: "")
                    let pathInput = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let pathStr = pathInput.isEmpty ? defaultPath : pathInput
                    config.profiles[pIdx - 1].targets.append(MountTarget(url: urlStr, mountPath: pathStr))
                    print("  ✓ 已添加: \(pathStr) (\(urlStr))")
                }
            }

        case "2":
            // 删除已有挂载目标
            var flatTargets: [(profileIndex: Int, targetIndex: Int, display: String)] = []
            for (pi, p) in config.profiles.enumerated() {
                for (ti, t) in p.targets.enumerated() {
                    flatTargets.append((pi, ti, "[\(p.id)] \(t.mountPath) (\(t.url))"))
                }
            }
            if flatTargets.isEmpty {
                print("当前无挂载目标可删除。")
                continue
            }
            print("\n现有挂载目标列表：")
            for (idx, item) in flatTargets.enumerated() {
                print("  [\(idx + 1)] \(item.display)")
            }
            print("请输入要删除的项目序号: ", terminator: "")
            if let delStr = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
               let delIdx = Int(delStr), delIdx >= 1 && delIdx <= flatTargets.count {
                let item = flatTargets[delIdx - 1]
                config.profiles[item.profileIndex].targets.remove(at: item.targetIndex)
                print("✓ 已删除目标。")
            }

        case "3":
            // 更新家庭网关 MAC
            if let homeIdx = config.profiles.firstIndex(where: { $0.id == "home_lan" }) {
                print("\n当前家庭网关 MAC: \(config.profiles[homeIdx].match.value)")
                if let curMAC = getCurrentNetworkFingerprint() {
                    print("自动探测到当前网络物理网关 MAC: \(curMAC)")
                    print("按回车采纳，或输入自定义 MAC 覆盖 [默认: \(curMAC)]: ", terminator: "")
                    let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    config.profiles[homeIdx].match.value = input.isEmpty ? curMAC : input
                    print("✓ 家庭网关 MAC 已更新为: \(config.profiles[homeIdx].match.value)")
                } else {
                    print("未能自动获取当前物理网关 MAC，请输入自定义 MAC: ", terminator: "")
                    let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !input.isEmpty {
                        config.profiles[homeIdx].match.value = input
                        print("✓ 家庭网关 MAC 已更新为: \(config.profiles[homeIdx].match.value)")
                    }
                }
            } else {
                print("未找到 home_lan 策略。")
            }

        case "4":
            // 更新或新建远程 Tailscale 目标
            let peers = discoverTailscalePeers()
            if peers.isEmpty {
                print("未检测到 Tailscale 在线设备。请确认 Tailscale 已启动并登录。")
                continue
            }
            var peerOptions = peers.map {
                SelectionOption(title: $0.name, subtitle: "MagicDNS: \($0.magicDNS ?? "无"), IP: \($0.ip), OS: \($0.os)")
            }
            peerOptions.append(SelectionOption(title: "取消", subtitle: nil))
            let sel = promptInteractiveRadio(title: "发现可用 Tailscale 设备，请选择：", options: peerOptions, defaultIndex: 0)
            guard sel < peers.count else {
                print("已取消操作。")
                continue
            }

            let peer = peers[sel]
            let selectedPeerName = peer.name
            var newHost = ""

            var addrOptions: [SelectionOption] = []
            if let dns = peer.magicDNS {
                addrOptions.append(SelectionOption(title: "MagicDNS 域名: \(dns)", subtitle: "推荐：IP 变动不失效，钥匙串凭据稳定"))
            }
            if !peer.ip.isEmpty {
                addrOptions.append(SelectionOption(title: "Tailscale IP: \(peer.ip)", subtitle: "直连无 DNS 解析依赖"))
            }
            if !addrOptions.isEmpty {
                let chosen = promptInteractiveRadio(title: "请选择连接方式：", options: addrOptions, defaultIndex: 0)
                newHost = addrOptions[chosen].title.starts(with: "MagicDNS") ? (peer.magicDNS ?? peer.ip) : peer.ip
            } else {
                newHost = peer.ip
            }

            if let rIdx = config.profiles.firstIndex(where: { $0.id == "tailscale_remote" }) {
                config.profiles[rIdx].match.value = newHost
                print("✓ 远程探测目标已更新为: \(newHost)")
            } else {
                // 动态新建 tailscale_remote 策略
                print("\n正在为新策略配置挂载目标：")
                var newTargets: [MountTarget] = []
                while true {
                    print("请输入该主机上的共享文件夹名称 (例如 data，按回车结束): ", terminator: "")
                    guard let sName = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !sName.isEmpty else {
                        break
                    }
                    var clean = sName
                    while clean.hasPrefix("/") { clean.removeFirst() }
                    while clean.hasSuffix("/") { clean.removeLast() }
                    let rURL = "smb://\(newHost)/\(clean)"
                    let dPath = "/Volumes/\(clean)"
                    print("请输入本地挂载路径 [默认: \(dPath)]: ", terminator: "")
                    let pIn = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let pStr = pIn.isEmpty ? dPath : pIn
                    newTargets.append(MountTarget(url: rURL, mountPath: pStr))
                    print("  ✓ 已添加: \(pStr) (\(rURL))")
                    print("继续添加另一个目标？(y/n) [默认 n]: ", terminator: "")
                    let c = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "n"
                    if c != "y" && c != "yes" { break }
                }

                let desc = selectedPeerName.isEmpty ? "Tailscale 异地互联 (外出降级通道)" : "Tailscale 异地互联 (\(selectedPeerName))"
                let newProfile = NetworkProfile(
                    id: "tailscale_remote",
                    description: desc,
                    match: MatchRule(type: "probe_host", value: newHost, retryCount: 3, retryInterval: 1.0),
                    excludeGatewayIPs: ["172.20.10.1"],
                    preventSpotlightIndex: true,
                    targets: newTargets
                )
                config.profiles.append(newProfile)
                print("✓ 远程 Tailscale 策略已成功创建并加入配置。")
            }

        case "0":
            saveConfig(config)
            print("✓ 配置管理已完成，修改已保存并生效。")
            return

        default:
            print("未知选项，请重新输入。")
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
    print("""
    Auto Mount Tool - 安装并启用自启动守护服务
    ===========================================
    """)

    guard let config = loadConfig(), !config.profiles.isEmpty else {
        fputs("✗ 未找到有效配置，请先运行 './auto_mount --init' 初始化配置。\n", stderr)
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
        fputs("✗ 创建目录失败: \(error.localizedDescription)\n", stderr)
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
                fputs("✗ 拷贝 \(fileName) 失败: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
    }

    let installedWrapper = installDir.appendingPathComponent("auto_mount").path
    let installedSwift = installDir.appendingPathComponent("auto_mount.swift").path
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedWrapper)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedSwift)

    let executablePath = FileManager.default.fileExists(atPath: installedWrapper) ? installedWrapper : installedSwift
    print("✓ 已将运行程序与配置同步部署至:\n  \(installDir.path)")

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
        print("✓ 已生成服务描述文件:\n  \(plistURL.path)")
    } catch {
        fputs("✗ 写入描述文件失败: \(error.localizedDescription)\n", stderr)
        exit(1)
    }

    let uid = getuid()
    let serviceTarget = "gui/\(uid)/\(launchAgentLabel)"
    _ = runCommand(executable: "/bin/launchctl", arguments: ["bootout", serviceTarget])

    let domainTarget = "gui/\(uid)"
    let bootResult = runCommand(executable: "/bin/launchctl", arguments: ["bootstrap", domainTarget, plistURL.path])

    if bootResult.status == 0 {
        print("✓ 成功注册并加载至系统 launchd 守护进程 (gui/\(uid))")
        print("\n服务详情:")
        print("  • 标识 (Label): \(launchAgentLabel)")
        print("  • 执行路径: \(executablePath)")
        print("  • 触发时机: 开机登录 (RunAtLoad) & 网络状态切换 (WatchPaths)")
        print("  • 日志路径: /tmp/\(launchAgentLabel).stdout.log")
        print("\n自启动与网络监听服务已生效。")
        writeLog("LaunchAgent installed and loaded successfully to \(installDir.path)")
    } else {
        fputs("✗ 加载服务失败 (代码 \(bootResult.status)): \(bootResult.stderr)\n", stderr)
        writeLog("Failed to bootstrap LaunchAgent: \(bootResult.stderr)")
        exit(1)
    }
}

func uninstallLaunchAgent() {
    print("""
    Auto Mount Tool - 卸载自启动服务
    =================================
    """)

    let uid = getuid()
    let serviceTarget = "gui/\(uid)/\(launchAgentLabel)"
    let plistURL = getLaunchAgentPlistURL()
    let installDir = getInstalledDir()

    var unloaded = false
    let bootResult = runCommand(executable: "/bin/launchctl", arguments: ["bootout", serviceTarget])
    if bootResult.status == 0 {
        print("✓ 成功从系统 launchd 中卸载服务 (\(serviceTarget))")
        unloaded = true
    } else {
        print("• 服务当前未在运行或已被卸载。")
    }

    var removedPlist = false
    if FileManager.default.fileExists(atPath: plistURL.path) {
        do {
            try FileManager.default.removeItem(at: plistURL)
            print("✓ 已删除服务描述文件: \(plistURL.path)")
            removedPlist = true
        } catch {
            fputs("✗ 删除描述文件失败: \(error.localizedDescription)\n", stderr)
        }
    } else {
        print("• 描述文件不存在: \(plistURL.path)")
    }

    var removedDir = false
    if FileManager.default.fileExists(atPath: installDir.path) {
        do {
            try FileManager.default.removeItem(at: installDir)
            print("✓ 已清理部署运行目录: \(installDir.path)")
            removedDir = true
        } catch {
            fputs("✗ 清理目录失败: \(error.localizedDescription)\n", stderr)
        }
    }

    if unloaded || removedPlist || removedDir {
        print("\n自启动服务与部署文件已彻底移除。")
        writeLog("LaunchAgent uninstalled")
    } else {
        print("\n无需清理。")
    }
}

func checkServiceStatus() {
    print("""
    Auto Mount Tool - 运行状态总览 (v2.0)
    ====================================
    """)

    let plistURL = getLaunchAgentPlistURL()
    let installDir = getInstalledDir()
    let uid = getuid()
    let serviceTarget = "gui/\(uid)/\(launchAgentLabel)"

    let plistExists = FileManager.default.fileExists(atPath: plistURL.path)
    print("  • LaunchAgent 服务配置: \(plistExists ? "已安装 (\(plistURL.path))" : "未安装")")

    let installedExists = FileManager.default.fileExists(atPath: installDir.path)
    if installedExists {
        print("  • 部署运行目录: \(installDir.path)")
    }

    let res = runCommand(executable: "/bin/launchctl", arguments: ["print", serviceTarget])
    if res.status == 0 {
        print("  • launchd 运行状态: 已加载并处于激活监听中 (gui/\(uid))")
        for line in res.stdout.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.starts(with: "state = ") || trimmed.starts(with: "last exit code = ") || trimmed.starts(with: "pid = ") {
                print("    \(trimmed)")
            }
        }
    } else {
        print("  • launchd 运行状态: 未加载 / 处于休眠状态")
    }

    print("\n  • 当前物理网络状态:")
    if let gw = getPhysicalGatewayInfo() {
        print("    物理网卡: \(gw.interface)")
        print("    物理网关 IP: \(gw.ip)")
        if let mac = getMACAddress(for: gw.ip, interface: gw.interface) {
            print("    物理网关 MAC: \(mac)")
        } else {
            print("    物理网关 MAC: (ARP 缓存中未找到)")
        }
    } else {
        print("    未检测到活跃的底层物理网络。")
    }

    print("\n  • 已配置策略列表:")
    if let config = loadConfig() {
        print("    配置版本: \(config.version)")
        let kernelEntries = getKernelMountEntries()

        for (idx, profile) in config.profiles.enumerated() {
            print("\n    [\(idx + 1)] 策略: \(profile.id) (\(profile.description ?? "无描述"))")
            print("        匹配条件: \(profile.match.type) = \(profile.match.value)")
            if let excludes = profile.excludeGatewayIPs, !excludes.isEmpty {
                print("        排除网关: \(excludes.joined(separator: ", "))")
            }
            print("        挂载目标 (\(profile.targets.count)):")
            for t in profile.targets {
                let stdPath = URL(fileURLWithPath: t.mountPath).standardizedFileURL.path
                if let entry = kernelEntries.first(where: { URL(fileURLWithPath: $0.mountPath).standardizedFileURL.path == stdPath }) {
                    print("          - \(t.mountPath) -> 已挂载 (来源: \(entry.source))")
                } else {
                    print("          - \(t.mountPath) -> 未挂载 (目标: \(t.url))")
                }
            }
        }
    } else {
        print("    未找到配置文件 (可运行: ./auto_mount --init 初始化)")
    }
}

func printUsage() {
    let configPath = getConfigURL().path
    print("""
    Auto Mount Tool (v2.0)
    ======================

    Usage:
      ./auto_mount                正常执行 (评估网络策略并挂载匹配目标)
      ./auto_mount --init         初始化配置向导 (支持自动嗅探与复选框交互)
      ./auto_mount --config       日常配置管理 (增删目标、修改网关或远程节点)
      ./auto_mount --install      配置并启用自启动后台守护服务 (LaunchAgent)
      ./auto_mount --uninstall    移除自启动配置与部署文件
      ./auto_mount --status       查看服务运行状态与挂载详情
      ./auto_mount --help         显示帮助说明

    配置文件: \(configPath)
    """)
}

// MARK: - 主流程执行逻辑

func main() {
    let args = CommandLine.arguments

    for arg in args.dropFirst() {
        if arg == "--init" {
            runInitWizard()
            exit(0)
        } else if arg == "--config" {
            manageConfiguration()
            exit(0)
        } else if arg == "--install" {
            installLaunchAgent()
            exit(0)
        } else if arg == "--uninstall" {
            uninstallLaunchAgent()
            exit(0)
        } else if arg == "--status" {
            checkServiceStatus()
            exit(0)
        } else if arg == "--help" || arg == "-h" {
            printUsage()
            exit(0)
        }
    }

    print("""
    Auto Mount Tool (v2.0)
    ======================
    """)

    guard let config = loadConfig(), !config.profiles.isEmpty else {
        fputs("✗ 未找到有效配置，请先运行 './auto_mount --init' 初始化。\n", stderr)
        writeLog("Config not found or empty, exiting")
        exit(1)
    }

    // 1. 采集物理网络信息
    print("[1] Evaluating network environment...")
    let currentGateway = getPhysicalGatewayInfo()
    let currentMAC = getCurrentNetworkFingerprint()

    if let gw = currentGateway {
        print("  Physical Gateway: \(gw.ip) on \(gw.interface)")
    } else {
        print("  Physical Gateway: None (offline)")
    }
    if let mac = currentMAC {
        print("  Physical Gateway MAC: \(mac)")
    }

    // 2. 顺序评估策略路由
    print("\n[2] Evaluating policy profiles...")
    var matchedProfile: NetworkProfile?

    for (idx, profile) in config.profiles.enumerated() {
        print("  Checking [\(idx + 1)] '\(profile.id)' (\(profile.description ?? "")):")

        if let excludes = profile.excludeGatewayIPs, let gwIP = currentGateway?.ip, excludes.contains(gwIP) {
            print("    ✗ Skipped: Gateway IP \(gwIP) is excluded (Hotspot bypass).")
            writeLog("Profile \(profile.id) skipped: Gateway IP \(gwIP) is in exclude_gateway_ips")
            continue
        }

        switch profile.match.type {
        case "gateway_mac":
            guard let curMAC = currentMAC else {
                print("    ✗ No gateway MAC detected.")
                continue
            }
            if curMAC.caseInsensitiveCompare(profile.match.value) == .orderedSame {
                print("    ✓ Matched! (Gateway MAC matches \(profile.match.value))")
                matchedProfile = profile
            } else {
                print("    ✗ Mismatch (Current MAC: \(curMAC) != \(profile.match.value))")
            }

        case "probe_host":
            let retries = profile.match.retryCount ?? 3
            let interval = profile.match.retryInterval ?? 1.0
            print("    Probing \(profile.match.value) (Retry window: \(retries) attempts, interval: \(interval)s)...")
            if probeHostWithRetries(host: profile.match.value, retries: retries, interval: interval) {
                print("    ✓ Matched! (Host \(profile.match.value) is reachable)")
                matchedProfile = profile
            } else {
                print("    ✗ Host \(profile.match.value) unreachable after \(retries) attempts.")
            }

        default:
            print("    ✗ Unknown match type: \(profile.match.type)")
        }

        if matchedProfile != nil {
            break
        }
    }

    guard let profile = matchedProfile else {
        print("\n[DONE] No matching profile for current network state. Exiting cleanly.")
        writeLog("No matching profile for current network, exiting")
        exit(0)
    }

    print("\n[3] Executing active profile: '\(profile.id)'")
    writeLog("Executing profile: \(profile.id)")

    var mountedCount = 0
    for target in profile.targets {
        print("  Target: \(target.mountPath) (\(target.url))")

        let status = ensureMountPointReady(target: target)
        switch status {
        case .alreadyMountedHealthy:
            print("    ✓ Already mounted and responsive, skipping.")
            mountedCount += 1
            continue

        case .readyToMount:
            print("    Mounting volume via NetFS...")
            if silentMount(urlString: target.url) {
                mountedCount += 1
                if profile.preventSpotlightIndex ?? true {
                    disableSpotlightIndex(at: target.mountPath)
                }
            }

        case .unmountFailed:
            print("    ✗ Mount point busy or cannot be cleared, skipping.")
        }
    }

    print("\n[DONE] \(mountedCount)/\(profile.targets.count) volumes mounted under '\(profile.id)'.")
    writeLog("Finished execution of '\(profile.id)': \(mountedCount)/\(profile.targets.count) mounted.")
}

main()
