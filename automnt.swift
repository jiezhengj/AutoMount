#!/usr/bin/env swift
// automnt.swift
// 自动挂载 NAS 工具 (macOS 原生单活动配置与事件驱动架构)
//
// 核心架构与特性：
// 1. 目标服务可达性路由 (HostReachabilityProbe)：
//    - 基于原生 POSIX 非阻塞 Socket 直连探测主机 TCP 445 端口判定网络环境。
//    - 彻底废除网关 MAC 与 ARP 链路层地址依赖。
// 2. 事件驱动响应式守护与有限重试：
//    - LaunchAgent 由系统网络配置变化事件 (WatchPaths) 驱动，杜绝轮询 (无 StartInterval)。
//    - 单轮网络评估由 EvaluationRetryRunner 在有限重试窗口 (默认 3 次, 间隔 1s, 上限 10s) 内执行。
// 3. 失效 SMB 挂载超时清理：
//    - Darwin 原生 MNT_NOWAIT 内核挂载表非阻塞快照查询，杜绝 stat() 阻塞。
//    - 自动比对同源性，有时限的 diskutil 与 umount -f 强制清理。
// 4. Spotlight 索引防护：挂载后请求 mdutil -i off 并尝试创建 .metadata_never_index。
// 5. 单用户规范安装与单一活动配置：
//    - 规范安装于 ~/Library/Application Support/automnt/bin/automnt。
//    - 单一活动配置 ~/Library/Application Support/automnt/automnt.plist (0600 权限)。
//    - 首次下载运行自搬迁并 unlink 临时副本，自动向当前 Shell 配置文件注入定界 CLI 入口。
// 6. 免本地编译预编译升级：从 GitHub Release 获取预编译 Mach-O 二进制原子替换，零本地编译。

import Foundation
import SystemConfiguration
import NetFS
import Darwin

// MARK: - 基础辅助函数与国际化 (i18n)

var isEnglish: Bool {
    let env = ProcessInfo.processInfo.environment["AUTOMNT_LANG"]
    if let envLang = env?.lowercased() {
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

var configURLOverride: URL?
var isTTYOverride: Bool?

func isInteractiveTerminal() -> Bool {
    if let override = isTTYOverride {
        return override
    }
    return isatty(STDIN_FILENO) != 0
}

func getActiveInstalledDir() -> URL {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return appSupport.appendingPathComponent("automnt")
}

func getActiveInstalledBinaryURL() -> URL {
    getActiveInstalledDir().appendingPathComponent("bin").appendingPathComponent("automnt")
}

func getActiveConfigURL() -> URL {
    if let override = configURLOverride {
        return override
    }
    return getActiveInstalledDir().appendingPathComponent("automnt.plist")
}

func getConfigURL() -> URL {
    return getActiveConfigURL()
}

func getLaunchAgentPlistURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.user.automnt.plist")
}

let launchAgentLabel = "com.user.automnt"

func writeLog(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let timestamp = formatter.string(from: Date())
    let logLine = "[\(timestamp)] \(message)\n"
    let installDir = getActiveInstalledDir()
    let logURL = installDir.appendingPathComponent("automnt.log")

    try? FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
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

// MARK: - 外部命令执行辅助

final class CommandOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var standardOutput = Data()
    private var standardError = Data()

    func storeStandardOutput(_ data: Data) {
        lock.lock()
        standardOutput = data
        lock.unlock()
    }

    func storeStandardError(_ data: Data) {
        lock.lock()
        standardError = data
        lock.unlock()
    }

    func snapshot() -> (standardOutput: Data, standardError: Data) {
        lock.lock()
        defer { lock.unlock() }
        return (standardOutput, standardError)
    }
}

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
        outPipe.fileHandleForWriting.closeFile()
        errPipe.fileHandleForWriting.closeFile()

        let readGroup = DispatchGroup()
        let outputBuffer = CommandOutputBuffer()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            outputBuffer.storeStandardOutput(data)
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            outputBuffer.storeStandardError(data)
            readGroup.leave()
        }
        process.waitUntilExit()
        readGroup.wait()
        let captured = outputBuffer.snapshot()
        let outStr = String(data: captured.standardOutput, encoding: .utf8) ?? ""
        let errStr = String(data: captured.standardError, encoding: .utf8) ?? ""
        return (process.terminationStatus, outStr, errStr)
    } catch {
        return (-1, "", error.localizedDescription)
    }
}

struct BoundedCommandResult {
    let status: Int32?
    let timedOut: Bool
    let processStopped: Bool
    let error: String?
}

func runCommandDiscardingOutputWithTimeout(
    executable: String,
    arguments: [String],
    timeout: TimeInterval
) -> BoundedCommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return BoundedCommandResult(status: nil, timedOut: false, processStopped: true,
                                   error: error.localizedDescription)
    }

    let waitGroup = DispatchGroup()
    waitGroup.enter()
    DispatchQueue.global(qos: .utility).async {
        process.waitUntilExit()
        waitGroup.leave()
    }

    let boundedTimeout = timeout.isFinite ? max(timeout, 0) : 0
    guard waitGroup.wait(timeout: .now() + boundedTimeout) == .timedOut else {
        return BoundedCommandResult(status: process.terminationStatus, timedOut: false,
                                   processStopped: true, error: nil)
    }

    process.terminate()
    if waitGroup.wait(timeout: .now() + 0.5) == .timedOut {
        _ = kill(process.processIdentifier, SIGKILL)
        return BoundedCommandResult(status: nil, timedOut: true, processStopped: false, error: nil)
    }
    return BoundedCommandResult(status: process.terminationStatus, timedOut: true,
                               processStopped: true, error: nil)
}

// MARK: - 版本与数据结构定义

let automntVersion = "3.1.0"
let minimumSupportedMacOSMajorVersion = 27
let minimumSupportedMacOSVersion = "\(minimumSupportedMacOSMajorVersion).0"
let githubRepo = "jiezhengj/automnt"

func normalizedArchitecture(_ architecture: String) -> String {
    architecture.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

func platformSupportIssue(macOSMajorVersion: Int, architecture: String) -> String? {
    guard normalizedArchitecture(architecture) == "arm64" else { return "architecture" }
    guard macOSMajorVersion >= minimumSupportedMacOSMajorVersion else { return "macOS_version" }
    return nil
}

struct RetryPolicy: Codable, Equatable {
    var maxAttempts: Int?
    var intervalMs: Int?
    var maxTotalWindowMs: Int?

    init(maxAttempts: Int? = 3, intervalMs: Int? = 1000, maxTotalWindowMs: Int? = 10000) {
        self.maxAttempts = maxAttempts
        self.intervalMs = intervalMs
        self.maxTotalWindowMs = maxTotalWindowMs
    }

    enum CodingKeys: String, CodingKey {
        case maxAttempts = "max_attempts"
        case intervalMs = "interval_ms"
        case maxTotalWindowMs = "max_total_window_ms"
    }
}

// MARK: - SMB URL 与标准挂载点推导 (SSOT)

func extractShareName(from urlString: String) -> String? {
    let clean = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    let componentInput = clean.hasPrefix("//") ? "smb:\(clean)" : clean
    guard let components = URLComponents(string: componentInput),
          let host = components.host, !host.isEmpty else {
        return nil
    }
    let rawPath = components.percentEncodedPath
    let segments = rawPath.split(separator: "/").filter { !$0.isEmpty }
    guard let share = segments.first else { return nil }
    let decoded = String(share).removingPercentEncoding ?? String(share)
    return decoded.isEmpty ? nil : decoded
}

func deriveStandardMountPoint(from urlString: String) -> String? {
    guard let shareName = extractShareName(from: urlString) else { return nil }
    return "/Volumes/\(shareName)"
}

// MARK: - 核心配置实体 (v3.1.0 规范与向下兼容桥接)

struct SMBShareConfig: Codable, Equatable {
    var name: String
    var smbURL: String
    var mountPoint: String
    var enabled: Bool = true

    enum CodingKeys: String, CodingKey {
        case name
        case smbURL = "smb_url"
        case mountPoint = "mount_point"
        case enabled
    }

    init(name: String, smbURL: String, mountPoint: String, enabled: Bool = true) {
        self.name = name
        self.smbURL = smbURL
        self.mountPoint = mountPoint
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.smbURL = try container.decode(String.self, forKey: .smbURL)
        self.mountPoint = try container.decode(String.self, forKey: .mountPoint)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(smbURL, forKey: .smbURL)
        try container.encode(mountPoint, forKey: .mountPoint)
        try container.encode(enabled, forKey: .enabled)
    }
}

struct HostConfig: Codable, Equatable {
    var host: String
    var alias: String?
    var port: Int = 445
    var timeoutMs: Int = 1000
    var preventSpotlightIndex: Bool = true
    var enabled: Bool = true
    var shares: [SMBShareConfig] = []

    enum CodingKeys: String, CodingKey {
        case host
        case alias
        case port
        case timeoutMs = "timeout_ms"
        case preventSpotlightIndex = "prevent_spotlight_index"
        case enabled
        case shares
    }

    init(
        host: String,
        alias: String? = nil,
        port: Int = 445,
        timeoutMs: Int = 1000,
        preventSpotlightIndex: Bool = true,
        enabled: Bool = true,
        shares: [SMBShareConfig] = []
    ) {
        self.host = host
        self.alias = alias
        self.port = port
        self.timeoutMs = timeoutMs
        self.preventSpotlightIndex = preventSpotlightIndex
        self.enabled = enabled
        self.shares = shares
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.host = try container.decode(String.self, forKey: .host)
        self.alias = try container.decodeIfPresent(String.self, forKey: .alias)
        self.port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 445
        self.timeoutMs = try container.decodeIfPresent(Int.self, forKey: .timeoutMs) ?? 1000
        self.preventSpotlightIndex = try container.decodeIfPresent(Bool.self, forKey: .preventSpotlightIndex) ?? true
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.shares = try container.decodeIfPresent([SMBShareConfig].self, forKey: .shares) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(host, forKey: .host)
        try container.encodeIfPresent(alias, forKey: .alias)
        try container.encode(port, forKey: .port)
        try container.encode(timeoutMs, forKey: .timeoutMs)
        try container.encode(preventSpotlightIndex, forKey: .preventSpotlightIndex)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(shares, forKey: .shares)
    }
}

struct MountTarget: Codable, Equatable {
    var url: String
    var mountPath: String

    var smbURL: String {
        get { url }
        set { url = newValue }
    }

    init(url: String, mountPath: String) {
        self.url = url
        self.mountPath = mountPath
    }

    enum CodingKeys: String, CodingKey {
        case url
        case smbURL = "smb_url"
        case mountPath = "mount_path"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mountPath = try container.decode(String.self, forKey: .mountPath)
        if let s = try container.decodeIfPresent(String.self, forKey: .smbURL) {
            self.url = s
        } else if let u = try container.decodeIfPresent(String.self, forKey: .url) {
            self.url = u
        } else {
            self.url = ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(url, forKey: .url)
        try container.encode(url, forKey: .smbURL)
        try container.encode(mountPath, forKey: .mountPath)
    }
}

struct NetworkProfile: Codable, Equatable {
    var id: String
    var description: String?
    var host: String
    var port: Int?
    var timeoutMs: Int?
    var preventSpotlightIndex: Bool?
    var targets: [MountTarget]

    init(
        id: String,
        description: String? = nil,
        host: String,
        port: Int? = 445,
        timeoutMs: Int? = 1000,
        preventSpotlightIndex: Bool? = true,
        targets: [MountTarget] = []
    ) {
        self.id = id
        self.description = description
        self.host = host
        self.port = port
        self.timeoutMs = timeoutMs
        self.preventSpotlightIndex = preventSpotlightIndex
        self.targets = targets
    }

    enum CodingKeys: String, CodingKey {
        case id
        case description
        case host
        case port
        case timeoutMs = "timeout_ms"
        case preventSpotlightIndex = "prevent_spotlight_index"
        case targets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.host = try container.decodeIfPresent(String.self, forKey: .host) ?? "localhost"
        self.port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 445
        self.timeoutMs = try container.decodeIfPresent(Int.self, forKey: .timeoutMs) ?? 1000
        self.preventSpotlightIndex = try container.decodeIfPresent(Bool.self, forKey: .preventSpotlightIndex) ?? true
        self.targets = try container.decodeIfPresent([MountTarget].self, forKey: .targets) ?? []
    }

    var effectiveProbeHost: String {
        return host
    }
}

struct AutomntConfig: Codable, Equatable {
    var version: String
    var updateChannel: String?                 // "off" (默认), "notify", "auto"
    var retryPolicy: RetryPolicy?
    var lastUpdateCheckTimestamp: Double?     // 更新检查最近一次尝试时间戳
    var updateRetryAfterTimestamp: Double? = nil
    var lastNotifiedVersion: String?          // 单版本仅提醒 1 次防打扰
    var hosts: [HostConfig] = []
    var profiles: [NetworkProfile] = []

    enum CodingKeys: String, CodingKey {
        case version
        case updateChannel = "update_channel"
        case retryPolicy = "retry_policy"
        case lastUpdateCheckTimestamp = "last_update_check_timestamp"
        case updateRetryAfterTimestamp = "update_retry_after_timestamp"
        case lastNotifiedVersion = "last_notified_version"
        case hosts
        case profiles
    }

    init(
        version: String = automntVersion,
        updateChannel: String? = "off",
        retryPolicy: RetryPolicy? = RetryPolicy(),
        lastUpdateCheckTimestamp: Double? = nil,
        updateRetryAfterTimestamp: Double? = nil,
        lastNotifiedVersion: String? = nil,
        hosts: [HostConfig] = [],
        profiles: [NetworkProfile] = []
    ) {
        self.version = version
        self.updateChannel = updateChannel
        self.retryPolicy = retryPolicy
        self.lastUpdateCheckTimestamp = lastUpdateCheckTimestamp
        self.updateRetryAfterTimestamp = updateRetryAfterTimestamp
        self.lastNotifiedVersion = lastNotifiedVersion
        self.hosts = hosts
        self.profiles = profiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(String.self, forKey: .version)
        self.updateChannel = try container.decodeIfPresent(String.self, forKey: .updateChannel)
        self.retryPolicy = try container.decodeIfPresent(RetryPolicy.self, forKey: .retryPolicy)
        self.lastUpdateCheckTimestamp = try container.decodeIfPresent(Double.self, forKey: .lastUpdateCheckTimestamp)
        self.updateRetryAfterTimestamp = try container.decodeIfPresent(Double.self, forKey: .updateRetryAfterTimestamp)
        self.lastNotifiedVersion = try container.decodeIfPresent(String.self, forKey: .lastNotifiedVersion)
        self.hosts = try container.decodeIfPresent([HostConfig].self, forKey: .hosts) ?? []
        self.profiles = try container.decodeIfPresent([NetworkProfile].self, forKey: .profiles) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(updateChannel, forKey: .updateChannel)
        try container.encodeIfPresent(retryPolicy, forKey: .retryPolicy)
        try container.encodeIfPresent(lastUpdateCheckTimestamp, forKey: .lastUpdateCheckTimestamp)
        try container.encodeIfPresent(updateRetryAfterTimestamp, forKey: .updateRetryAfterTimestamp)
        try container.encodeIfPresent(lastNotifiedVersion, forKey: .lastNotifiedVersion)
        try container.encode(hosts, forKey: .hosts)
        if !profiles.isEmpty {
            try container.encode(profiles, forKey: .profiles)
        }
    }
}

enum ConfigFileState: Equatable {
    case missing
    case usable
    case invalid
    case futureVersion(String)
    case inaccessible
}

struct ConfigFileInspection {
    let url: URL
    let state: ConfigFileState
    let config: AutomntConfig?
    let contents: Data?
    let diagnostic: String?
}

func inspectConfigFile(at url: URL) -> ConfigFileInspection {
    var fileInfo = stat()
    let statResult = url.path.withCString { Darwin.lstat($0, &fileInfo) }
    guard statResult == 0 else {
        let errorCode = errno
        let isMissing = errorCode == ENOENT
        let diagnostic = String(cString: strerror(errorCode))
        return ConfigFileInspection(url: url, state: isMissing ? .missing : .inaccessible,
                                    config: nil, contents: nil,
                                    diagnostic: isMissing ? nil : diagnostic)
    }

    guard fileInfo.st_mode & S_IFMT == S_IFREG else {
        return ConfigFileInspection(url: url, state: .inaccessible, config: nil, contents: nil,
                                    diagnostic: "Configuration path is not a regular file")
    }

    let data: Data
    do {
        data = try Data(contentsOf: url)
    } catch {
        return ConfigFileInspection(url: url, state: .inaccessible, config: nil, contents: nil,
                                    diagnostic: error.localizedDescription)
    }

    guard var config = try? PropertyListDecoder().decode(AutomntConfig.self, from: data),
          !parseSemanticVersion(config.version).isEmpty else {
        return ConfigFileInspection(url: url, state: .invalid, config: nil, contents: data,
                                    diagnostic: "Configuration is malformed")
    }
    guard !isNewerVersion(config.version, than: automntVersion) else {
        return ConfigFileInspection(url: url, state: .futureVersion(config.version), config: config,
                                    contents: data, diagnostic: nil)
    }
    config.version = config.version.trimmingCharacters(in: .whitespacesAndNewlines)
    return ConfigFileInspection(url: url, state: .usable, config: config, contents: data, diagnostic: nil)
}

func configInspectionMatches(_ expected: ConfigFileInspection, _ current: ConfigFileInspection) -> Bool {
    expected.url.standardizedFileURL == current.url.standardizedFileURL
        && expected.state == current.state
        && expected.contents == current.contents
}

func configBackupURL(for configURL: URL, now: Date = Date()) -> URL {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let timestamp = formatter.string(from: now).replacingOccurrences(of: ":", with: "")
    let parentURL = configURL.deletingLastPathComponent()
    let baseName = "\(configURL.lastPathComponent).backup-\(timestamp)"
    var candidate = parentURL.appendingPathComponent(baseName)
    var suffix = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
        candidate = parentURL.appendingPathComponent("\(baseName)-\(suffix)")
        suffix += 1
    }
    return candidate
}

func backUpConfigFile(_ inspection: ConfigFileInspection) throws -> URL? {
    guard let contents = inspection.contents else { return nil }
    let backupURL = configBackupURL(for: inspection.url)
    try atomicWrite(contents, to: backupURL, permissions: 0o600)
    return backupURL
}

func pruneConfigBackups(for configURL: URL, maxToKeep: Int = 1) {
    let parentURL = configURL.deletingLastPathComponent()
    let prefix = "\(configURL.lastPathComponent).backup-"
    guard let contents = try? FileManager.default.contentsOfDirectory(at: parentURL, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
    let backups = contents.filter { $0.lastPathComponent.hasPrefix(prefix) }
    guard backups.count > maxToKeep else { return }

    let sorted = backups.sorted { url1, url2 in
        let date1 = (try? url1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
        let date2 = (try? url2.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
        return date1 > date2
    }

    for url in sorted.dropFirst(maxToKeep) {
        try? FileManager.default.removeItem(at: url)
    }
}

func atomicWrite(_ data: Data, to url: URL, permissions: Int? = nil) throws {
    let parentDir = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true, attributes: nil)
    let tempURL = parentDir.appendingPathComponent(".tmp.\(UUID().uuidString)")
    try data.write(to: tempURL)
    let targetPermissions = permissions ?? 0o600
    try FileManager.default.setAttributes([.posixPermissions: targetPermissions], ofItemAtPath: tempURL.path)
    _ = Darwin.rename(tempURL.path, url.path)
}

struct StagedFileReplacement {
    let sourceURL: URL
    let destinationURL: URL
    let permissions: Int
}

func replaceFilesTransactionally(
    _ replacements: [StagedFileReplacement],
    postReplaceAction: (() throws -> Void)? = nil
) throws {
    var backups: [(backupURL: URL, destinationURL: URL, originalPermissions: Int?)] = []
    let tempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("automnt-atomic-txn-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    do {
        for replacement in replacements {
            let dest = replacement.destinationURL
            if FileManager.default.fileExists(atPath: dest.path) {
                let backup = tempDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.copyItem(at: dest, to: backup)
                let attrs = try FileManager.default.attributesOfItem(atPath: dest.path)
                let originalPerms = (attrs[.posixPermissions] as? NSNumber)?.intValue
                backups.append((backup, dest, originalPerms))
            }
        }

        for replacement in replacements {
            let tempStaged = replacement.destinationURL.deletingLastPathComponent()
                .appendingPathComponent(".tmp.\(UUID().uuidString)")
            try FileManager.default.copyItem(at: replacement.sourceURL, to: tempStaged)
            try FileManager.default.setAttributes([.posixPermissions: replacement.permissions], ofItemAtPath: tempStaged.path)
            _ = Darwin.rename(tempStaged.path, replacement.destinationURL.path)
        }

        if let postReplaceAction {
            try postReplaceAction()
        }
    } catch {
        for backup in backups.reversed() {
            _ = Darwin.rename(backup.backupURL.path, backup.destinationURL.path)
            if let perms = backup.originalPermissions {
                try? FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: backup.destinationURL.path)
            }
        }
        throw error
    }
}

// MARK: - 配置文件原地迁移 (In-Place Schema Migration)

func configVersionCanBeMigrated(_ configVersion: String) -> Bool {
    !isNewerVersion(configVersion, than: automntVersion)
}

func configNeedsMigration(_ config: AutomntConfig) -> Bool {
    if config.version != automntVersion { return true }
    if config.updateChannel == nil { return true }
    if !config.profiles.isEmpty { return true }
    for host in config.hosts {
        for share in host.shares {
            if let cleanMount = deriveStandardMountPoint(from: share.smbURL), cleanMount != share.mountPoint {
                return true
            }
        }
    }
    return false
}

func migrateConfigIfNeeded(config: inout AutomntConfig, at configURL: URL) -> Bool {
    guard configVersionCanBeMigrated(config.version) else {
        fputs(tr("✗ 配置版本 v\(config.version) 高于当前程序 v\(automntVersion)，为避免降级破坏配置，已停止运行。\n",
                 "✗ Config version v\(config.version) is newer than program v\(automntVersion); refusing to downgrade the config.\n"), stderr)
        writeLog("Refused to migrate newer config version \(config.version) with program \(automntVersion)")
        return false
    }

    guard configNeedsMigration(config) else { return true }

    // 迁移前备份并限制最多保留 1 份 (FR-024, SC-016)
    let inspection = inspectConfigFile(at: configURL)
    if let _ = try? backUpConfigFile(inspection) {
        pruneConfigBackups(for: configURL, maxToKeep: 1)
    }

    var modified = false
    if config.version != automntVersion {
        config.version = automntVersion
        modified = true
    }
    if config.updateChannel == nil {
        config.updateChannel = "off"
        modified = true
    }

    // 存量 profiles 升舱为 hosts (US6) 并深度清洗历史挂载路径
    if !config.profiles.isEmpty {
        var migratedHosts: [HostConfig] = config.hosts
        for p in config.profiles {
            var shares: [SMBShareConfig] = []
            for t in p.targets {
                let cleanMount = deriveStandardMountPoint(from: t.url) ?? t.mountPath
                let sName = extractShareName(from: t.url) ?? "share"
                shares.append(SMBShareConfig(
                    name: sName,
                    smbURL: t.url,
                    mountPoint: cleanMount,
                    enabled: true
                ))
            }
            let hostConfig = HostConfig(
                host: p.host,
                alias: p.description,
                port: p.port ?? 445,
                timeoutMs: p.timeoutMs ?? 1000,
                preventSpotlightIndex: p.preventSpotlightIndex ?? true,
                enabled: true,
                shares: shares
            )
            if !migratedHosts.contains(where: { $0.host == hostConfig.host }) {
                migratedHosts.append(hostConfig)
            }
        }
        config.hosts = migratedHosts
        config.profiles = []
        modified = true
    }

    // 检查并清洗现有 hosts 中的历史挂载点路径（防止历史 -1 污染残留）
    for hIdx in 0..<config.hosts.count {
        for sIdx in 0..<config.hosts[hIdx].shares.count {
            let share = config.hosts[hIdx].shares[sIdx]
            if let cleanMount = deriveStandardMountPoint(from: share.smbURL), cleanMount != share.mountPoint {
                config.hosts[hIdx].shares[sIdx].mountPoint = cleanMount
                modified = true
            }
        }
    }

    guard modified else { return true }
    guard saveConfig(config, to: configURL) else {
        fputs(tr("✗ 配置已迁移到内存，但未能完整写入配置文件。\n",
                 "✗ Configuration was migrated in memory, but could not be fully saved.\n"), stderr)
        writeLog("Configuration migration to v\(automntVersion) could not be persisted")
        return false
    }
    print(tr("✓ 配置文件已自动平滑升级至 v\(automntVersion) 格式规范",
             "✓ Configuration automatically upgraded to v\(automntVersion) schema"))
    writeLog("Configuration auto-migrated to v\(automntVersion)")
    return true
}

@discardableResult
func migrateActiveConfigIfNeeded() -> Bool {
    let configURL = getActiveConfigURL()
    guard FileManager.default.fileExists(atPath: configURL.path) else { return true }
    guard var config = loadConfig(from: configURL, migrate: false) else { return false }
    return migrateConfigIfNeeded(config: &config, at: configURL)
}

func loadConfig(from configURL: URL? = nil, migrate: Bool = true) -> AutomntConfig? {
    let targetURL = configURL ?? getConfigURL()
    guard FileManager.default.fileExists(atPath: targetURL.path) else { return nil }
    guard let data = try? Data(contentsOf: targetURL) else { return nil }
    let decoder = PropertyListDecoder()
    guard var config = try? decoder.decode(AutomntConfig.self, from: data) else { return nil }
    if migrate && configNeedsMigration(config) {
        _ = migrateConfigIfNeeded(config: &config, at: targetURL)
    }
    return config
}

enum ConfigPlistContext: Equatable {
    case root
    case profiles
    case profile
    case targets
    case target
    case hosts
    case host
    case shares
    case share
    case other
}

func canonicalProfileID(_ value: String) -> String {
    switch value {
    case "home_lan": return "local_lan"
    case "tailscale_remote": return "remote_network"
    default: return value
    }
}

func managedConfigKeys(for context: ConfigPlistContext) -> Set<String> {
    switch context {
    case .root:
        return ["version", "update_channel", "retry_policy", "last_update_check_timestamp",
                "update_retry_after_timestamp", "last_notified_version", "hosts", "profiles"]
    case .profile:
        return ["id", "description", "host", "port", "timeout_ms",
                "prevent_spotlight_index", "targets"]
    case .target:
        return ["url", "mount_path"]
    case .host:
        return ["host", "alias", "port", "timeout_ms", "prevent_spotlight_index", "enabled", "shares"]
    case .share:
        return ["name", "smb_url", "mount_point", "enabled"]
    case .profiles, .targets, .hosts, .shares, .other:
        return []
    }
}

func childConfigPlistContext(parent: ConfigPlistContext, key: String) -> ConfigPlistContext {
    switch (parent, key) {
    case (.root, "profiles"): return .profiles
    case (.profile, "targets"): return .targets
    case (.root, "hosts"): return .hosts
    case (.host, "shares"): return .shares
    default: return .other
    }
}

func configPlistIdentity(_ value: Any, context: ConfigPlistContext) -> String? {
    guard let dict = value as? [String: Any] else { return nil }
    switch context {
    case .profiles, .profile:
        return (dict["id"] as? String).map(canonicalProfileID)
    case .targets, .target:
        return (dict["mount_path"] as? String) ?? (dict["mountPath"] as? String)
    case .hosts, .host:
        return dict["host"] as? String
    case .shares, .share:
        return (dict["mount_point"] as? String) ?? (dict["smb_url"] as? String)
    case .root, .other:
        return nil
    }
}

func mergeConfigPlistValue(original: Any, generated: Any, context: ConfigPlistContext) -> Any {
    if let originalDict = original as? [String: Any],
       let generatedDict = generated as? [String: Any] {
        var merged = generatedDict
        let managed = managedConfigKeys(for: context)
        for (key, originalValue) in originalDict where !managed.contains(key) {
            merged[key] = originalValue
        }
        for (key, generatedValue) in generatedDict {
            if let originalChild = originalDict[key] {
                let childContext = childConfigPlistContext(parent: context, key: key)
                merged[key] = mergeConfigPlistValue(original: originalChild, generated: generatedValue, context: childContext)
            }
        }
        return merged
    }

    if let originalArray = original as? [[String: Any]],
       let generatedArray = generated as? [[String: Any]] {
        var originalByID: [String: [String: Any]] = [:]
        for item in originalArray {
            if let id = configPlistIdentity(item, context: context) {
                originalByID[id] = item
            }
        }
        var mergedArray: [[String: Any]] = []
        let childContext: ConfigPlistContext
        switch context {
        case .profiles: childContext = .profile
        case .targets: childContext = .target
        case .hosts: childContext = .host
        case .shares: childContext = .share
        default: childContext = .other
        }
        for item in generatedArray {
            if let id = configPlistIdentity(item, context: context), let originalItem = originalByID[id] {
                let mergedItem = mergeConfigPlistValue(original: originalItem, generated: item, context: childContext) as? [String: Any] ?? item
                mergedArray.append(mergedItem)
            } else {
                mergedArray.append(item)
            }
        }
        return mergedArray
    }

    return generated
}

func encodeConfigPreservingUnknownFields(_ config: AutomntConfig, at configURL: URL) throws -> Data {
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .xml
    let generatedData = try encoder.encode(config)

    guard FileManager.default.fileExists(atPath: configURL.path),
          let originalData = try? Data(contentsOf: configURL),
          let originalPlist = try? PropertyListSerialization.propertyList(from: originalData, options: [], format: nil),
          let generatedPlist = try? PropertyListSerialization.propertyList(from: generatedData, options: [], format: nil) else {
        return generatedData
    }

    let mergedPlist = mergeConfigPlistValue(original: originalPlist, generated: generatedPlist, context: .root)
    return try PropertyListSerialization.data(fromPropertyList: mergedPlist, format: .xml, options: 0)
}

func saveConfig(
    _ config: AutomntConfig,
    to configURL: URL? = nil,
    preserveUnknownFields: Bool = true
) -> Bool {
    let resolvedURL = configURL ?? getConfigURL()
    do {
        let parentDir = resolvedURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true, attributes: nil)
        let data: Data
        if preserveUnknownFields {
            data = try encodeConfigPreservingUnknownFields(config, at: resolvedURL)
        } else {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .xml
            data = try encoder.encode(config)
        }
        try atomicWrite(data, to: resolvedURL, permissions: 0o600)
        print(tr("✓ 配置已即时保存至: \(resolvedURL.path)",
                 "✓ Config saved to: \(resolvedURL.path)"))
        return true
    } catch {
        fputs("✗ Failed to save config: \(error.localizedDescription)\n", stderr)
        writeLog("Failed to save config: \(error.localizedDescription)")
        return false
    }
}

// MARK: - 主机可达性探测器与网络辅助函数

struct HostReachabilityProbe {
    static func canConnect(host: String, port: Int = 445, timeoutMs: Int = 1000) -> Bool {
        guard !host.isEmpty else { return false }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var res: UnsafeMutablePointer<addrinfo>?
        let portString = "\(port)"
        guard getaddrinfo(host, portString, &hints, &res) == 0, let firstAddr = res else {
            return false
        }
        defer { freeaddrinfo(res) }

        var curr: UnsafeMutablePointer<addrinfo>? = firstAddr
        while let ai = curr {
            let sock = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if sock >= 0 {
                let flags = fcntl(sock, F_GETFL, 0)
                _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

                let connRes = connect(sock, ai.pointee.ai_addr, ai.pointee.ai_addrlen)
                if connRes == 0 {
                    close(sock)
                    return true
                }
                if errno == EINPROGRESS {
                    var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
                    let pollRes = poll(&pfd, 1, Int32(max(timeoutMs, 10)))
                    if pollRes > 0 && (pfd.revents & Int16(POLLOUT)) != 0 {
                        var err: Int32 = 0
                        var errLen = socklen_t(MemoryLayout<Int32>.size)
                        if getsockopt(sock, SOL_SOCKET, SO_ERROR, &err, &errLen) == 0 && err == 0 {
                            close(sock)
                            return true
                        }
                    }
                }
                close(sock)
            }
            curr = ai.pointee.ai_next
        }
        return false
    }
}

struct EvaluationRetryRunner {
    let policy: RetryPolicy

    init(policy: RetryPolicy = RetryPolicy()) {
        self.policy = policy
    }

    func run(block: () -> Bool) -> Bool {
        let maxAttempts = min(max(policy.maxAttempts ?? 3, 1), 10)
        let intervalMs = min(max(policy.intervalMs ?? 1000, 100), 5000)
        let maxTotalWindowMs = min(max(policy.maxTotalWindowMs ?? 10000, 1000), 30000)

        let startTime = Date()
        for attempt in 1...maxAttempts {
            if block() {
                return true
            }
            if attempt == maxAttempts {
                break
            }
            let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
            if elapsedMs + intervalMs > maxTotalWindowMs {
                break
            }
            usleep(useconds_t(intervalMs * 1000))
        }
        return false
    }
}

func isIPv4Address(_ value: String) -> Bool {
    var address = in_addr()
    return value.withCString { inet_pton(AF_INET, $0, &address) } == 1
}

func isIPAddress(_ value: String) -> Bool {
    if isIPv4Address(value) { return true }
    var address6 = in6_addr()
    return value.withCString({ inet_pton(AF_INET6, $0, &address6) }) == 1
}

func extractHost(from string: String) -> String {
    var clean = string.trimmingCharacters(in: .whitespacesAndNewlines)
    let componentInput = clean.hasPrefix("//") ? "smb:\(clean)" : clean
    if let components = URLComponents(string: componentInput),
       let host = components.host, !host.isEmpty {
        return host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
    }
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
    if clean.hasPrefix("["), let closingBracket = clean.firstIndex(of: "]") {
        return String(clean[clean.index(after: clean.startIndex)..<closingBracket]).lowercased()
    }
    if let colonIndex = clean.firstIndex(of: ":") {
        clean = String(clean[..<colonIndex])
    }
    return clean.lowercased()
}

func smbResourceIdentity(_ value: String) -> String? {
    let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let componentInput = clean.hasPrefix("//") ? "smb:\(clean)" : clean
    guard let components = URLComponents(string: componentInput),
          let host = components.host, !host.isEmpty else {
        return nil
    }
    let normalizedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
    let rawPath = components.percentEncodedPath
    let segments = rawPath.split(separator: "/").filter { !$0.isEmpty }
    guard let share = segments.first else { return nil }
    let normalizedShare = String(share).removingPercentEncoding?.lowercased() ?? String(share).lowercased()
    return "//\(normalizedHost)/\(normalizedShare)"
}

func redactedSMBURL(_ value: String) -> String {
    let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let componentInput = clean.hasPrefix("//") ? "smb:\(clean)" : clean
    guard var components = URLComponents(string: componentInput) else {
        if let atIndex = clean.firstIndex(of: "@"),
           let schemeIndex = clean.range(of: "://")?.upperBound {
            return String(clean[..<schemeIndex]) + String(clean[clean.index(after: atIndex)...])
        }
        return clean
    }
    components.user = nil
    components.password = nil
    if let urlString = components.string {
        return urlString
    }
    return clean
}

func validateMountTargetURL(_ value: String) -> String? {
    let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard clean.hasPrefix("smb://") || clean.hasPrefix("//") else {
        return tr("挂载地址必须以 'smb://' 或 '//' 开头", "Mount URL must start with 'smb://' or '//'")
    }
    if clean.contains("@") {
        return tr("挂载地址不得内嵌用户名或密码，SMB 凭据必须由系统钥匙串保管",
                  "Mount URL must not contain embedded username or password; SMB credentials must be managed by macOS Keychain")
    }
    guard let identity = smbResourceIdentity(clean), !identity.isEmpty else {
        return tr("挂载地址必须包含有效的主机名与共享名称 (例如 smb://server.local/share)",
                  "Mount URL must include a valid host and share name (e.g., smb://server.local/share)")
    }
    return nil
}

func validateMountPath(_ value: String) -> String? {
    let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard clean.hasPrefix("/") else {
        return tr("本地挂载路径必须是绝对路径 (以 / 开头)", "Local mount path must be an absolute path (starting with /)")
    }
    let components = clean.split(separator: "/")
    if components.contains("..") || components.contains(".") {
        return tr("本地挂载路径不得包含相对路径跳转符号 (..) 或 (.)", "Local mount path must not contain relative traversal symbols (..) or (.)")
    }
    let url = URL(fileURLWithPath: clean).standardizedFileURL
    let path = url.path
    if path == "/" || path == "/Volumes" {
        return tr("不能直接使用系统根目录或 /Volumes 作为挂载点", "Cannot use root or /Volumes directly as a mount point")
    }
    return nil
}

func usesSystemManagedMountPoint(_ target: MountTarget) -> Bool {
    let standardized = URL(fileURLWithPath: target.mountPath).standardizedFileURL
    let parent = standardized.deletingLastPathComponent().path
    guard parent == "/Volumes" else { return false }
    guard let identity = smbResourceIdentity(target.url) else { return false }
    let share = identity.split(separator: "/").last.map(String.init) ?? ""
    return standardized.lastPathComponent.lowercased() == share.lowercased()
}

// MARK: - 内核挂载表快照与 NetFS 框架挂载

struct KernelMountEntry {
    let source: String
    let mountPoint: String
    let fileSystemType: String
}

func getKernelMountEntries() -> [KernelMountEntry] {
    let count = getfsstat(nil, 0, MNT_NOWAIT)
    guard count > 0 else { return [] }

    var statfsList = Array(repeating: Darwin.statfs(), count: Int(count))
    let byteSize = Int(count) * MemoryLayout<Darwin.statfs>.size
    let resultCount = statfsList.withUnsafeMutableBufferPointer { buffer -> Int32 in
        guard let baseAddress = buffer.baseAddress else { return 0 }
        return getfsstat(baseAddress, Int32(byteSize), MNT_NOWAIT)
    }

    guard resultCount > 0 else { return [] }
    var entries: [KernelMountEntry] = []
    for i in 0..<Int(resultCount) {
        var item = statfsList[i]
        let mountPoint = withUnsafePointer(to: &item.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { String(cString: $0) }
        }
        let source = withUnsafePointer(to: &item.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { String(cString: $0) }
        }
        let fsType = withUnsafePointer(to: &item.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        entries.append(KernelMountEntry(source: source, mountPoint: mountPoint, fileSystemType: fsType))
    }
    return entries
}

func getKernelMountSource(for mountPath: String) -> String? {
    let target = URL(fileURLWithPath: mountPath).standardizedFileURL.path
    for entry in getKernelMountEntries() {
        if URL(fileURLWithPath: entry.mountPoint).standardizedFileURL.path == target {
            return entry.source
        }
    }
    return nil
}

func discoverActiveSMBMounts() -> [(url: String, path: String, host: String)] {
    var results: [(url: String, path: String, host: String)] = []
    for entry in getKernelMountEntries() {
        if entry.fileSystemType.lowercased() == "smbfs" {
            let host = extractHost(from: entry.source)
            results.append((url: entry.source, path: entry.mountPoint, host: host))
        }
    }
    return results
}

func forceUnmountWithTimeout(path: String, timeoutSeconds: Double = 3.0) -> Bool {
    let diskutilRes = runCommandDiscardingOutputWithTimeout(
        executable: "/usr/sbin/diskutil",
        arguments: ["unmount", "force", path],
        timeout: timeoutSeconds
    )
    if diskutilRes.status == 0 {
        return true
    }
    let umountRes = runCommandDiscardingOutputWithTimeout(
        executable: "/sbin/umount",
        arguments: ["-f", path],
        timeout: timeoutSeconds
    )
    return umountRes.status == 0
}

enum MountPointStatus {
    case alreadyMountedHealthy
    case readyToMount
    case unmountFailed
}

func ensureMountPointReady(target: MountTarget) -> MountPointStatus {
    let stdPath = URL(fileURLWithPath: target.mountPath).standardizedFileURL.path
    if let currentSource = getKernelMountSource(for: stdPath) {
        if smbResourceIdentity(currentSource) == smbResourceIdentity(target.url) {
            return .alreadyMountedHealthy
        } else {
            let unmounted = forceUnmountWithTimeout(path: stdPath)
            if unmounted {
                return .readyToMount
            } else {
                return .unmountFailed
            }
        }
    }
    return .readyToMount
}

func disableSpotlightIndex(at mountPath: String) {
    _ = runCommand(executable: "/usr/bin/mdutil", arguments: ["-i", "off", mountPath])
    let neverIndexPath = URL(fileURLWithPath: mountPath).appendingPathComponent(".metadata_never_index").path
    if !FileManager.default.fileExists(atPath: neverIndexPath) {
        _ = FileManager.default.createFile(atPath: neverIndexPath, contents: Data(), attributes: nil)
    }
}

func netFSMountOptions(hasExplicitMountPoint: Bool) -> NSMutableDictionary? {
    if hasExplicitMountPoint {
        let dict = NSMutableDictionary()
        dict.setObject(true, forKey: kNetFSMountAtMountDirKey as NSString)
        return dict
    }
    return nil
}

func silentMount(urlString: String, mountPath: String) -> Bool {
    guard let url = URL(string: urlString) else { return false }
    let cfURL = url as CFURL
    let stdPath = URL(fileURLWithPath: mountPath).standardizedFileURL.path
    let cfMountPoint = URL(fileURLWithPath: stdPath) as CFURL
    let explicitPoint = !usesSystemManagedMountPoint(MountTarget(url: urlString, mountPath: mountPath))
    let options = netFSMountOptions(hasExplicitMountPoint: explicitPoint)

    if explicitPoint && !FileManager.default.fileExists(atPath: stdPath) {
        try? FileManager.default.createDirectory(atPath: stdPath, withIntermediateDirectories: true, attributes: nil)
    }

    var mountPoints: Unmanaged<CFArray>?
    let status = NetFSMountURLSync(
        cfURL,
        explicitPoint ? cfMountPoint : nil,
        nil,
        nil,
        nil,
        options,
        &mountPoints
    )

    if status == 0 {
        mountPoints?.release()
        return true
    } else {
        writeLog("NetFS error \(status) for \(redactedSMBURL(urlString))")
        return false
    }
}

struct DiscoveredTailscalePeer {
    let name: String
    let magicDNS: String
    let ip: String
    let os: String
}

func discoverTailscalePeers() -> [DiscoveredTailscalePeer] {
    let res = runCommand(executable: "/usr/bin/which", arguments: ["tailscale"])
    guard res.status == 0 else { return [] }
    let tsPath = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let statusRes = runCommand(executable: tsPath, arguments: ["status", "--json"])
    guard statusRes.status == 0,
          let data = statusRes.stdout.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let peerMap = json["PeerStatus"] as? [String: [String: Any]] else {
        return []
    }

    var peers: [DiscoveredTailscalePeer] = []
    for (_, peer) in peerMap {
        let name = peer["HostName"] as? String ?? "unknown"
        let magicDNS = peer["DNSName"] as? String ?? ""
        let osName = peer["OS"] as? String ?? ""
        let addrs = peer["TailscaleIPs"] as? [String] ?? []
        let ip = addrs.first ?? ""
        if !ip.isEmpty {
            peers.append(DiscoveredTailscalePeer(name: name, magicDNS: magicDNS, ip: ip, os: osName))
        }
    }
    return peers.sorted { $0.name < $1.name }
}

func remoteSMBAcceptanceURL(_ urlString: String, peers: [DiscoveredTailscalePeer]) -> (url: String, usesTailscaleAddress: Bool) {
    let host = extractHost(from: urlString)
    for peer in peers {
        if !peer.magicDNS.isEmpty && peer.magicDNS.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() == host {
            let replaced = urlString.replacingOccurrences(of: host, with: peer.ip)
            return (replaced, true)
        }
    }
    return (urlString, false)
}

// MARK: - 终端 ANSI 交互式菜单组件

struct SelectionOption {
    let title: String
    let subtitle: String?
}

struct TerminalUI {
    static func setRawMode(_ enable: Bool) {
        var raw = termios()
        tcgetattr(STDIN_FILENO, &raw)
        if enable {
            raw.c_lflag &= ~tcflag_t(ECHO | ICANON)
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        } else {
            raw.c_lflag |= tcflag_t(ECHO | ICANON)
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        }
    }

    static func readByte() -> UInt8? {
        var b: UInt8 = 0
        let n = read(STDIN_FILENO, &b, 1)
        if n <= 0 {
            return nil
        }
        return b
    }

    static func hasPendingInput(timeoutMs: Int = 0) -> Bool {
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let res = poll(&pfd, 1, Int32(timeoutMs))
        return res > 0 && (pfd.revents & Int16(POLLIN)) != 0
    }
}

// MARK: - POSIX termios 轻量安全行输入 (Esc 放弃与退格擦除)

var mockLineInput: String? = nil
var mockLineInputs: [String]? = nil

func promptLineWithEsc(prompt: String, defaultValue: String? = nil) -> String? {
    if mockLineInputs != nil && !mockLineInputs!.isEmpty {
        let next = mockLineInputs!.removeFirst()
        if next == "\u{1B}" { // 模拟 Esc 放弃
            print("\r\u{1B}[K" + tr("(已取消)", "(Cancelled)"))
            return nil
        }
        let trimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, let def = defaultValue {
            return def
        }
        return trimmed
    }
    if let mock = mockLineInput {
        if mock == "\u{1B}" { // 模拟 Esc 放弃
            print("\r\u{1B}[K" + tr("(已取消)", "(Cancelled)"))
            return nil
        }
        let trimmed = mock.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, let def = defaultValue {
            return def
        }
        return trimmed
    }

    if !isInteractiveTerminal() {
        print(prompt, terminator: "")
        fflush(stdout)
        guard let line = readLine() else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, let def = defaultValue {
            return def
        }
        return trimmed
    }

    print(prompt, terminator: "")
    fflush(stdout)
    TerminalUI.setRawMode(true)
    defer {
        TerminalUI.setRawMode(false)
    }

    var buffer: [UInt8] = []

    while true {
        guard let b = TerminalUI.readByte() else {
            // STDIN 流终止 (EOF) 或错误，安全退出并返回 nil
            return nil
        }
        if b == 27 { // ASCII 27: Esc 键
            if TerminalUI.hasPendingInput(timeoutMs: 50) {
                // 逃逸序列 (如方向键)，读取并丢弃后续控制字节
                _ = TerminalUI.readByte()
                if TerminalUI.hasPendingInput(timeoutMs: 10) {
                    _ = TerminalUI.readByte()
                }
                continue
            }
            // 独立 Esc 键：立即清除当前行并安全返回 nil
            print("\r\u{1B}[K" + tr("(已取消)", "(Cancelled)"))
            return nil
        } else if b == 10 || b == 13 { // 回车键
            print("")
            let str = String(bytes: buffer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if str.isEmpty, let def = defaultValue {
                return def
            }
            return str
        } else if b == 127 || b == 8 { // 退格键 (ASCII 127 / ASCII 8)
            if !buffer.isEmpty {
                if var currentStr = String(bytes: buffer, encoding: .utf8) {
                    currentStr.removeLast()
                    buffer = Array(currentStr.utf8)
                    print("\r\u{1B}[K\(prompt)\(currentStr)", terminator: "")
                    fflush(stdout)
                } else {
                    buffer.removeLast()
                    print("\r\u{1B}[K\(prompt)", terminator: "")
                    fflush(stdout)
                }
            }
        } else if b == 3 { // Ctrl+C 中断
            TerminalUI.setRawMode(false)
            exit(130)
        } else if b >= 32 { // 可打印字符与多字节 UTF-8 序列
            buffer.append(b)
            if let str = String(bytes: buffer, encoding: .utf8) {
                print("\r\u{1B}[K\(prompt)\(str)", terminator: "")
                fflush(stdout)
            }
        }
    }
}

// MARK: - 运行期卷宗发现与候选主机倒推

struct DiscoveredMount: Equatable {
    var mountPoint: String       // 实际本地挂载路径（可能带 -1 临时冲突后缀）
    var rawSmbUrl: String        // 内核挂载表返回的原始 URL
    var host: String             // 提取解析出的主机 IP 或域名
    var shareName: String        // 从 URL 提取的标准真实共享名
    var cleanMountPoint: String  // 推导出的标准规整路径 /Volumes/<shareName>
    var standardSMBURL: String   // 标准 smb://<host>/<shareName>
    var smbURL: String { standardSMBURL }
}

struct DiscoveredHostGroup: Equatable {
    var host: String
    var mounts: [DiscoveredMount]
    var isConfigured: Bool = false
}

var mockCandidateHosts: [DiscoveredHostGroup]? = nil

func discoverCandidateHosts() -> [DiscoveredHostGroup] {
    if let mock = mockCandidateHosts {
        return mock
    }
    let entries = getKernelMountEntries().filter { $0.fileSystemType.lowercased() == "smbfs" }
    var hostMap: [String: [DiscoveredMount]] = [:]
    var hostOrder: [String] = []

    for entry in entries {
        let rawURL = entry.source
        let host = extractHost(from: rawURL)
        guard !host.isEmpty else { continue }
        guard let shareName = extractShareName(from: rawURL) else { continue }
        let cleanMount = "/Volumes/\(shareName)"
        let stdURL = "smb://\(host)/\(shareName)"

        let item = DiscoveredMount(
            mountPoint: entry.mountPoint,
            rawSmbUrl: rawURL,
            host: host,
            shareName: shareName,
            cleanMountPoint: cleanMount,
            standardSMBURL: stdURL
        )

        if hostMap[host] == nil {
            hostMap[host] = []
            hostOrder.append(host)
        }
        if !hostMap[host]!.contains(where: { $0.shareName.lowercased() == shareName.lowercased() }) {
            hostMap[host]!.append(item)
        }
    }

    return hostOrder.map { h in
        DiscoveredHostGroup(host: h, mounts: hostMap[h] ?? [], isConfigured: false)
    }
}

func promptInteractiveCheckbox(title: String, options: [SelectionOption]) -> [Int]? {
    guard isatty(STDIN_FILENO) != 0, !options.isEmpty else { return [] }
    print(title)
    var selected = Set<Int>()
    var cursor = 0

    TerminalUI.setRawMode(true)
    defer {
        TerminalUI.setRawMode(false)
        print("\u{001B}[?25h")
    }
    print("\u{001B}[?25l")

    func render() {
        print("\u{001B}[\(options.count)A", terminator: "")
        for (i, opt) in options.enumerated() {
            let isCurrent = (i == cursor)
            let isChecked = selected.contains(i)
            let pointer = isCurrent ? "> " : "  "
            let box = isChecked ? "[x] " : "[ ] "
            let line = "\(pointer)\(box)\(opt.title)" + (opt.subtitle.map { " (\($0))" } ?? "")
            print("\u{001B}[2K\(line)")
        }
    }

    for _ in options { print("") }
    render()

    while true {
        guard let b = TerminalUI.readByte() else { return nil }
        if b == 10 || b == 13 {
            break
        } else if b == 32 {
            if selected.contains(cursor) { selected.remove(cursor) }
            else { selected.insert(cursor) }
            render()
        } else if b == 106 {
            cursor = (cursor + 1) % options.count
            render()
        } else if b == 107 {
            cursor = (cursor - 1 + options.count) % options.count
            render()
        } else if b == 97 {
            if selected.count == options.count { selected.removeAll() }
            else { selected = Set(0..<options.count) }
            render()
        } else if b == 27 {
            guard let b2 = TerminalUI.readByte() else { return nil }
            if b2 == 91 {
                guard let b3 = TerminalUI.readByte() else { return nil }
                if b3 == 65 {
                    cursor = (cursor - 1 + options.count) % options.count
                    render()
                } else if b3 == 66 {
                    cursor = (cursor + 1) % options.count
                    render()
                }
            } else {
                return nil
            }
        }
    }
    return Array(selected).sorted()
}

func promptInteractiveRadio(title: String, options: [SelectionOption], defaultIndex: Int = 0) -> Int? {
    guard isatty(STDIN_FILENO) != 0, !options.isEmpty else { return defaultIndex }
    print(title)
    var cursor = defaultIndex

    TerminalUI.setRawMode(true)
    defer {
        TerminalUI.setRawMode(false)
        print("\u{001B}[?25h")
    }
    print("\u{001B}[?25l")

    func render() {
        print("\u{001B}[\(options.count)A", terminator: "")
        for (i, opt) in options.enumerated() {
            let isCurrent = (i == cursor)
            let pointer = isCurrent ? "> " : "  "
            let radio = isCurrent ? "(o) " : "( ) "
            let line = "\(pointer)\(radio)\(opt.title)" + (opt.subtitle.map { " (\($0))" } ?? "")
            print("\u{001B}[2K\(line)")
        }
    }

    for _ in options { print("") }
    render()

    while true {
        guard let b = TerminalUI.readByte() else { return nil }
        if b == 10 || b == 13 {
            break
        } else if b == 106 {
            cursor = (cursor + 1) % options.count
            render()
        } else if b == 107 {
            cursor = (cursor - 1 + options.count) % options.count
            render()
        } else if b == 27 {
            guard let b2 = TerminalUI.readByte() else { return nil }
            if b2 == 91 {
                guard let b3 = TerminalUI.readByte() else { return nil }
                if b3 == 65 {
                    cursor = (cursor - 1 + options.count) % options.count
                    render()
                } else if b3 == 66 {
                    cursor = (cursor + 1) % options.count
                    render()
                }
            } else {
                return nil
            }
        }
    }
    return cursor
}

// MARK: - 初始化向导 (--init) 与日常配置管理 (--config)

func handleCandidateHostConfiguration(candidate: DiscoveredHostGroup) -> HostConfig? {
    print(tr("\n--- 配置主机: \(candidate.host) ---", "\n--- Configure Host: \(candidate.host) ---"))
    let aliasPrompt = tr("请输入该主机的人类友好别名 (直接回车保持默认 [\(candidate.host)], 按 Esc 取消): ",
                         "Enter alias for host (Enter for default [\(candidate.host)], Esc to cancel): ")
    guard let aliasInput = promptLineWithEsc(prompt: aliasPrompt) else {
        print(tr("(已取消主机配置)", "(Host configuration canceled)"))
        return nil
    }
    let trimmedAlias = aliasInput.trimmingCharacters(in: .whitespacesAndNewlines)
    let alias: String? = trimmedAlias.isEmpty ? nil : trimmedAlias

    print(tr("\n请选择需要自动挂载的共享文件夹:", "\nSelect shared folders to mount automatically:"))
    for (idx, mount) in candidate.mounts.enumerated() {
        let stdMountPoint = deriveStandardMountPoint(from: mount.smbURL) ?? "/Volumes/\(mount.shareName)"
        print("  [ ] \(idx + 1). \(mount.shareName) (\(redactedSMBURL(mount.smbURL)) -> \(stdMountPoint))")
    }

    let selectionPrompt = tr("\n输入编号切换选择 (例如 '1 2' 或 'all', 回车确认, 按 Esc 取消): ",
                             "\nEnter numbers to select (e.g. '1 2' or 'all', Enter to confirm, Esc to cancel): ")
    guard let selInput = promptLineWithEsc(prompt: selectionPrompt) else {
        print(tr("(已取消主机配置)", "(Host configuration canceled)"))
        return nil
    }
    let trimmedSel = selInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    var selectedIndices: Set<Int> = []
    if trimmedSel == "all" || trimmedSel.isEmpty {
        selectedIndices = Set(0..<candidate.mounts.count)
    } else {
        let tokens = trimmedSel.split(separator: " ").compactMap { Int($0) }
        for t in tokens where t >= 1 && t <= candidate.mounts.count {
            selectedIndices.insert(t - 1)
        }
    }

    if selectedIndices.isEmpty {
        print(tr("未选择任何共享文件夹，已取消该主机配置。", "No shares selected, canceled host configuration."))
        return nil
    }

    for idx in 0..<candidate.mounts.count {
        let mount = candidate.mounts[idx]
        let stdMountPoint = deriveStandardMountPoint(from: mount.smbURL) ?? "/Volumes/\(mount.shareName)"
        let checkMark = selectedIndices.contains(idx) ? "[✓]" : "[ ]"
        print("  \(checkMark) \(idx + 1). \(mount.shareName) (\(redactedSMBURL(mount.smbURL)) -> \(stdMountPoint))")
    }

    let confirmPrompt = tr("确认添加上述共享？[Y/n]: ", "Confirm adding these shares? [Y/n]: ")
    guard let confirmInput = promptLineWithEsc(prompt: confirmPrompt, defaultValue: "Y") else {
        return nil
    }
    let trimmedConfirm = confirmInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if !trimmedConfirm.isEmpty && trimmedConfirm != "y" && trimmedConfirm != "yes" {
        print(tr("已放弃添加上述共享。", "Discarded adding shares."))
        return nil
    }

    var shares: [SMBShareConfig] = []
    for idx in selectedIndices.sorted() {
        let mount = candidate.mounts[idx]
        let stdMountPoint = deriveStandardMountPoint(from: mount.smbURL) ?? "/Volumes/\(mount.shareName)"
        shares.append(SMBShareConfig(
            name: mount.shareName,
            smbURL: mount.smbURL,
            mountPoint: stdMountPoint,
            enabled: true
        ))
    }

    return HostConfig(
        host: candidate.host,
        alias: alias,
        port: 445,
        timeoutMs: 1000,
        preventSpotlightIndex: true,
        enabled: true,
        shares: shares
    )
}

func handleManualHostEntry(existingHosts: [HostConfig]) -> HostConfig? {
    print(tr("\n--- 手动添加主机 ---", "\n--- Manually Add Host ---"))
    let hostPrompt = tr("请输入主机 IP 地址或域名 (按 Esc 取消): ", "Enter host IP or domain (Esc to cancel): ")
    guard let hostInput = promptLineWithEsc(prompt: hostPrompt) else { return nil }
    let host = hostInput.trimmingCharacters(in: .whitespacesAndNewlines)
    if host.isEmpty { return nil }

    let aliasPrompt = tr("请输入该主机的人类友好别名 (直接回车保持默认 [\(host)], 按 Esc 跳过): ",
                         "Enter alias for host (Enter for default [\(host)], Esc to skip): ")
    let aliasInput = promptLineWithEsc(prompt: aliasPrompt)
    let trimmedAlias = aliasInput?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let alias: String? = trimmedAlias.isEmpty ? nil : trimmedAlias

    print(tr("正在测试主机 \(host) 的 SMB 服务端口 (445)...", "Testing SMB service port (445) on \(host)..."))
    let reachable = HostReachabilityProbe.canConnect(host: host, port: 445, timeoutMs: 1500)
    if reachable {
        print(tr("连接测试成功。\n", "Connection test succeeded.\n"))
    } else {
        print(tr("""
        ⚠️ 警告: 无法连通目标主机 \(host) 的 445 端口 (连接超时或网络不可达)。
        该主机可能当前处于离线状态，或当前网络无法直连。
        """, """
        ⚠️ Warning: Cannot connect to TCP port 445 on \(host) (timeout or unreachable).
        The host may be offline or unreachable on this network.
        """))
        let offlineConfirm = tr("是否仍然添加该主机？[y/N]: ", "Add this offline host anyway? [y/N]: ")
        guard let offlineInput = promptLineWithEsc(prompt: offlineConfirm, defaultValue: "N") else { return nil }
        let c = offlineInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if c != "y" && c != "yes" {
            print(tr("已取消添加未连通主机。", "Canceled adding unreachable host."))
            return nil
        }
        print(tr("已确认添加离线主机 \(host)。\n", "Confirmed adding offline host \(host).\n"))
    }

    print(tr("系统未在该主机下检测到已挂载卷宗，请手动录入共享路径：",
             "No active mounts detected for this host. Please enter share path manually:"))
    let sharePrompt = tr("请输入从属 SMB 共享路径 (格式如 smb://\(host)/Backup, 按 Esc 取消): ",
                         "Enter SMB share path (e.g. smb://\(host)/Backup, Esc to cancel): ")
    guard let shareInput = promptLineWithEsc(prompt: sharePrompt) else { return nil }
    let rawURL = shareInput.trimmingCharacters(in: .whitespacesAndNewlines)
    if rawURL.isEmpty { return nil }
    if let err = validateMountTargetURL(rawURL) {
        print("✗ \(err)")
        return nil
    }

    let stdMountPoint = deriveStandardMountPoint(from: rawURL) ?? "/Volumes/share"
    print(tr("标准目标挂载点将设置为: \(stdMountPoint)", "Standard mount point will be set to: \(stdMountPoint)"))
    let confirmPrompt = tr("确认添加该共享？[Y/n]: ", "Confirm adding this share? [Y/n]: ")
    guard let confirmInput = promptLineWithEsc(prompt: confirmPrompt, defaultValue: "Y") else { return nil }
    let trimmedConfirm = confirmInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if !trimmedConfirm.isEmpty && trimmedConfirm != "y" && trimmedConfirm != "yes" {
        print(tr("已取消添加共享。", "Canceled adding share."))
        return nil
    }

    let shareName = extractShareName(from: rawURL) ?? "share"
    let shares = [
        SMBShareConfig(name: shareName, smbURL: rawURL, mountPoint: stdMountPoint, enabled: true)
    ]

    print(tr("\n提示：对于手动添加的新网络共享，请确保已在 macOS 系统中成功连接过一次并勾选“在我的钥匙串中记住此密码”，认证凭据将由系统钥匙串自动安全管理。",
             "\nNote: For manually added network shares, ensure you have connected at least once in macOS and checked 'Remember password in Keychain'. Credentials are managed securely by Keychain."))

    let aliasDisplay = alias ?? host
    print(tr("已成功添加主机 [\(aliasDisplay)] 及其从属共享。\n",
             "Successfully added host [\(aliasDisplay)] and its shares.\n"))

    return HostConfig(
        host: host,
        alias: alias,
        port: 445,
        timeoutMs: 1000,
        preventSpotlightIndex: true,
        enabled: true,
        shares: shares
    )
}

func runInitWizard(offerServiceInstallation: Bool = true) -> Bool {
    print(tr("""
    automnt - 初始化配置向导 (v\(automntVersion))
    ======================================
    """, """
    automnt - Setup Wizard (v\(automntVersion))
    ====================================
    """))

    print(tr("正在检测系统当前挂载的网络存储...", "Detecting currently mounted network storage..."))
    var candidateHosts = discoverCandidateHosts()
    var configuredHosts: [HostConfig] = []

    while true {
        if candidateHosts.isEmpty {
            print(tr("\n未检测到系统当前挂载的网络存储。", "\nNo active mounted network storage detected."))
        } else {
            print(tr("\n检测到以下候选主机：\n", "\nDiscovered the following candidate hosts:\n"))
            for (idx, candidate) in candidateHosts.enumerated() {
                let num = idx + 1
                if candidate.isConfigured {
                    let matching = configuredHosts.first(where: { $0.host == candidate.host })
                    let aliasText = matching?.alias.map { " [\($0)]" } ?? ""
                    let count = matching?.shares.count ?? candidate.mounts.count
                    print(tr("  [✓] \(num). \(candidate.host)\(aliasText) (已配置 \(count) 个共享)",
                             "  [✓] \(num). \(candidate.host)\(aliasText) (\(count) shares configured)"))
                } else {
                    print(tr("  [\(num)] \(candidate.host) (检测到 \(candidate.mounts.count) 个已挂载共享)",
                             "  [\(num)] \(candidate.host) (\(candidate.mounts.count) mounted shares detected)"))
                }
            }
        }

        print(tr("""

        操作选项：
          [m] 手动添加新主机地址
          [s] 跳过主机配置 (稍后通过 automnt --config 配置)
          [d] 完成主机配置并进入下一步
        """, """

        Options:
          [m] Manually add host address
          [s] Skip host configuration (configure later via automnt --config)
          [d] Complete host configuration and proceed to next step
        """))

        let promptHint = candidateHosts.isEmpty ? "[m / s / d]" : "[1-\(candidateHosts.count) / m / s / d]"
        let promptText = tr("请选择操作 \(promptHint) (按 Esc 退出向导): ", "Select option \(promptHint) (Press Esc to exit): ")
        guard let input = promptLineWithEsc(prompt: promptText) else {
            print(tr("已取消向导。", "Setup wizard canceled."))
            return false
        }
        let choice = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if choice == "s" {
            print(tr("已跳过主机配置。", "Skipped host configuration."))
            break
        } else if choice == "d" {
            break
        } else if choice == "m" {
            if let newHost = handleManualHostEntry(existingHosts: configuredHosts) {
                configuredHosts.append(newHost)
                if let cIdx = candidateHosts.firstIndex(where: { $0.host == newHost.host }) {
                    candidateHosts[cIdx].isConfigured = true
                }
            }
        } else if let num = Int(choice), num >= 1, num <= candidateHosts.count {
            let candidateIdx = num - 1
            if candidateHosts[candidateIdx].isConfigured {
                print(tr("该主机已配置，不可重复选择，请选择其他候选主机或点选 [d] 完成。",
                         "Host already configured. Select another or enter 'd' to finish."))
                continue
            }
            let candidate = candidateHosts[candidateIdx]
            if let hostConfig = handleCandidateHostConfiguration(candidate: candidate) {
                configuredHosts.append(hostConfig)
                candidateHosts[candidateIdx].isConfigured = true
                let aliasDisplay = hostConfig.alias ?? hostConfig.host
                print(tr("已保存主机 [\(aliasDisplay)] 的配置。", "Saved configuration for host [\(aliasDisplay)]."))
            }
        } else {
            print(tr("无效的选择，请重新输入。", "Invalid choice, please re-enter."))
        }
    }

    print(tr("\n[2/3] 软件更新策略设置", "\n[2/3] Software Update Channel"))
    print(tr("""
      [1] off    - 关闭自动检查 (推荐，零网络请求，手动运行 'automnt --update')
      [2] notify - 发现新版本时发送系统通知，由您手动执行更新
      [3] auto   - 发现新版本时自动下载预编译二进制并平滑升级
    """, """
      [1] off    - Disable auto-checks (Recommended, update manually via 'automnt --update')
      [2] notify - Send system notification on new version, update manually
      [3] auto   - Auto-download prebuilt binary and update silently
    """))
    let channelChoice = promptLineWithEsc(prompt: tr("请选择更新策略 [1-3] (默认 1): ", "Select update policy [1-3] (Default 1): "), defaultValue: "1")
    let selectedChannel: String
    switch channelChoice?.trimmingCharacters(in: .whitespacesAndNewlines) {
    case "2", "notify": selectedChannel = "notify"
    case "3", "auto": selectedChannel = "auto"
    default: selectedChannel = "off"
    }

    let config = AutomntConfig(
        version: automntVersion,
        updateChannel: selectedChannel,
        retryPolicy: RetryPolicy(),
        lastUpdateCheckTimestamp: nil,
        lastNotifiedVersion: nil,
        hosts: configuredHosts,
        profiles: []
    )
    let saved = saveConfig(config)
    guard saved else {
        fputs(tr("✗ 保存配置失败。\n", "✗ Failed to save configuration.\n"), stderr)
        return false
    }
    print(tr("\n✓ 恭喜！automnt 配置已顺利完成！", "\n✓ Configuration completed successfully!"))

    if offerServiceInstallation {
        print(tr("""
        \n是否立即部署并在用户登录时自动运行后台守护服务？
          - 选择 [Y]: 自动安装 LaunchAgent，当网络环境变化时自动触发顺位挂载探测。
          - 选择 [n]: 仅保存配置文件，不向系统注册任何后台常驻服务。
        """, """
        \nDeploy background event-driven LaunchAgent daemon now?
          - Select [Y]: Automatically install LaunchAgent to mount shares upon network change.
          - Select [n]: Save config only, do not register background service.
        """))
        let deployPrompt = tr("请确认部署意愿 [Y/n] (默认 Y): ", "Confirm deployment intention [Y/n] (Default Y): ")
        let deployChoice = promptLineWithEsc(prompt: deployPrompt, defaultValue: "Y")
        if let choice = deployChoice?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           choice == "y" || choice == "yes" {
            print("")
            installLaunchAgent()
        } else {
            print(tr("  ✓ 已跳过后台服务部署。", "  ✓ Skipped background service deployment."))
            let activeConfigURL = getActiveConfigURL()
            print(tr("  配置已成功保存至: \(activeConfigURL.path)", "  Config successfully saved to: \(activeConfigURL.path)"))
            print(tr("  后续可通过运行 'automnt' 手动执行挂载，或使用 'automnt --config' 管理配置。\n",
                     "  You can run 'automnt' anytime to mount manually, or 'automnt --config' to manage.\n"))
        }
    }
    return true
}

func runInitCommand(resetExistingConfig: Bool = false) -> Bool {
    let activeConfigURL = getActiveConfigURL()
    let inspection = inspectConfigFile(at: activeConfigURL)

    if !resetExistingConfig {
        switch inspection.state {
        case .usable:
            print(tr("✓ 已找到有效的活动配置文件；`--init` 未重建它。请用 `automnt --config` 管理配置，或用 `automnt --init --reset` 重建。",
                     "✓ A usable active config already exists; `--init` left it intact. Use `automnt --config` to edit it or `automnt --init --reset` to rebuild."))
            return true
        case .futureVersion(let v):
            fputs(tr("✗ 配置文件版本 v\(v) 高于当前程序 v\(automntVersion)；未重置配置。请先使用兼容版本，或明确运行 `automnt --init --reset`。\n",
                     "✗ The config v\(v) is newer than program v\(automntVersion); it was not reset. Use a compatible newer program or explicitly run `automnt --init --reset`.\n"), stderr)
            return false
        case .inaccessible:
            fputs(tr("✗ 无法安全读取或备份配置文件；未启动初始化向导。\n",
                     "✗ The config cannot be safely read or backed up; setup wizard not started.\n"), stderr)
            return false
        case .missing, .invalid:
            break
        }
    }

    guard isInteractiveTerminal() else {
        fputs(tr("✗ 当前没有可用配置且输入不是交互终端；请在 Terminal 中运行 `automnt --init`。\n",
                 "✗ No usable config exists and stdin is not interactive; run `automnt --init` in Terminal.\n"), stderr)
        return false
    }
    return runInitWizard()
}

func prepareManagementConfigURL() -> URL? {
    let activeConfigURL = getActiveConfigURL()
    let inspection = inspectConfigFile(at: activeConfigURL)
    switch inspection.state {
    case .usable:
        return activeConfigURL
    case .missing:
        guard isInteractiveTerminal() else {
            fputs(tr("✗ 没有可用配置。请在交互式 Terminal 中运行 `automnt --init`。\n",
                     "✗ No usable config exists. Run `automnt --init` in an interactive Terminal.\n"), stderr)
            return nil
        }
        guard runInitWizard(offerServiceInstallation: false) else { return nil }
        return activeConfigURL
    case .futureVersion(let v):
        fputs(tr("✗ 配置文件版本 v\(v) 高于当前程序 v\(automntVersion)；未修改配置。请先使用兼容版本。\n",
                 "✗ The config v\(v) is newer than program v\(automntVersion); no config was changed. Use a compatible newer program first.\n"), stderr)
        return nil
    case .inaccessible, .invalid:
        fputs(tr("✗ 配置文件损坏或无法访问 (\(inspection.diagnostic ?? ""))；请先运行 `automnt --init --reset`。\n",
                 "✗ Config file is invalid or inaccessible; please run `automnt --init --reset` first.\n"), stderr)
        return nil
    }
}

func firstRegexCapture(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
    guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          match.numberOfRanges > 1,
          let range = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[range])
}

struct LaunchAgentDiagnostic {
    let isRegistered: Bool
    let state: String
    let lastExitCode: String
}

func getLaunchAgentDiagnostic() -> LaunchAgentDiagnostic {
    let serviceTarget = "gui/\(getuid())/\(launchAgentLabel)"
    let result = runCommand(executable: "/bin/launchctl", arguments: ["print", serviceTarget])
    let state = firstRegexCapture(#"(?m)^\s*state = (.+)$"#, in: result.stdout)
    let lastExitCode = firstRegexCapture(#"(?m)^\s*last exit code = (-?\d+)\s*$"#, in: result.stdout)
    return LaunchAgentDiagnostic(
        isRegistered: result.status == 0,
        state: state ?? tr("未知", "unknown"),
        lastExitCode: lastExitCode ?? tr("无", "none")
    )
}

func getLaunchAgentStatusSummary() -> String {
    let plistURL = getLaunchAgentPlistURL()
    if !FileManager.default.fileExists(atPath: plistURL.path) {
        return tr("未安装 (可运行 'automnt --install' 部署)", "Not installed (Run 'automnt --install' to deploy)")
    }
    let diagnostic = getLaunchAgentDiagnostic()
    if !diagnostic.isRegistered {
        return tr("描述文件存在但未被 launchd 注册", "Plist exists but service is not registered")
    }
    var details: [String] = []
    if !diagnostic.state.isEmpty {
        details.append(diagnostic.state)
    }
    if diagnostic.lastExitCode != tr("无", "none") {
        details.append("last exit: \(diagnostic.lastExitCode)")
    }
    return tr("已就绪 (事件驱动)", "Ready (event-driven)") + (details.isEmpty ? "" : " [\(details.joined(separator: ", "))]")
}

func getUpdateChannelDisplay(_ channel: String) -> String {
    switch channel {
    case "auto": return tr("自动静默更新 (auto)", "Automatic Silent Update (auto)")
    case "notify": return tr("通知提醒 (notify)", "Notify Only (notify)")
    default: return tr("已关闭 (off)", "Disabled (off)")
    }
}

func pauseForUser() {
    print(tr("\n按回车键继续...", "\nPress Enter to continue..."))
    _ = readLine()
}

func manageHostShares(hostConfig: inout HostConfig, allHosts: [HostConfig]) {
    while true {
        let hostDisplay = hostConfig.alias.map { "\($0) (\(hostConfig.host))" } ?? hostConfig.host
        print(tr("\n--- 主机管理: \(hostDisplay) ---", "\n--- Host Management: \(hostDisplay) ---"))
        print(tr("当前从属共享:", "Current shares:"))
        if hostConfig.shares.isEmpty {
            print(tr("  (当前未配置任何共享)", "  (No shares configured)"))
        } else {
            for (idx, share) in hostConfig.shares.enumerated() {
                let status = share.enabled ? tr("启用", "Enabled") : tr("禁用", "Disabled")
                print("  [\(idx + 1)] \(share.name) (\(share.mountPoint)) [\(status)]")
            }
        }

        print(tr("""

        操作：
          [a] 从当前挂载卷追加共享 / 手动输入路径
          [d] 删除/移除指定共享
          [t] 切换启用/禁用状态
          [b] 返回上一级菜单 (或按 Esc)
        """, """

        Actions:
          [a] Append share from active mount / manual input
          [d] Remove specified share
          [t] Toggle enabled/disabled state
          [b] Return to parent menu (or press Esc)
        """))

        let promptText = tr("请选择操作: ", "Select action: ")
        guard let input = promptLineWithEsc(prompt: promptText) else { return }
        let action = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if action == "b" {
            return
        } else if action == "a" {
            print(tr("\n选择追加共享方式：\n  [1] 从当前挂载卷追加\n  [2] 手动录入共享路径\n",
                     "\nSelect method:\n  [1] Append from active mounted volumes\n  [2] Manually enter share path\n"))
            let mPrompt = tr("请选择 [1/2] (默认 1, 按 Esc 取消): ", "Select [1/2] (Default 1, Esc to cancel): ")
            guard let mChoice = promptLineWithEsc(prompt: mPrompt, defaultValue: "1") else { continue }
            let method = mChoice.trimmingCharacters(in: .whitespacesAndNewlines)

            if method == "2" {
                let pathPrompt = tr("请输入从属 SMB 共享路径: ", "Enter SMB share path: ")
                guard let pathInput = promptLineWithEsc(prompt: pathPrompt) else { continue }
                let rawURL = pathInput.trimmingCharacters(in: .whitespacesAndNewlines)
                if rawURL.isEmpty { continue }

                // 防呆检测：检查是否已存在于该主机名下
                let sName = extractShareName(from: rawURL) ?? "share"
                let stdMount = deriveStandardMountPoint(from: rawURL) ?? "/Volumes/\(sName)"
                if hostConfig.shares.contains(where: { $0.smbURL.lowercased() == rawURL.lowercased() || $0.mountPoint == stdMount }) {
                    print(tr("提示：共享路径 \(rawURL) 已存在于该主机名下，已自动忽略重复添加。",
                             "Notice: Share path \(rawURL) already exists under this host, duplicate ignored."))
                    continue
                }

                if let err = validateMountTargetURL(rawURL) {
                    print("✗ \(err)")
                    continue
                }

                print(tr("标准目标挂载点将设置为: \(stdMount)", "Standard mount point will be set to: \(stdMount)"))
                let confirmPrompt = tr("确认添加该共享？[Y/n]: ", "Confirm adding this share? [Y/n]: ")
                guard let confirm = promptLineWithEsc(prompt: confirmPrompt, defaultValue: "Y") else { continue }
                let tc = confirm.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if tc == "y" || tc == "yes" {
                    hostConfig.shares.append(SMBShareConfig(name: sName, smbURL: rawURL, mountPoint: stdMount, enabled: true))
                    print(tr("\n提示：对于手动添加的新网络共享，请确保已在 macOS 系统中成功连接过一次并勾选“在我的钥匙串中记住此密码”，认证凭据将由系统钥匙串自动安全管理。",
                             "\nNote: For manually added network shares, ensure you have connected at least once in macOS and checked 'Remember password in Keychain'. Credentials are managed securely by Keychain."))
                    print(tr("已添加共享 [\(sName)]。", "Added share [\(sName)]."))
                }
            } else {
                let candidateMounts = discoverCandidateHosts().first(where: { $0.host == hostConfig.host })?.mounts ?? []
                if candidateMounts.isEmpty {
                    print(tr("系统未在该主机下检测到已挂载卷宗，请选择手动录入。",
                             "No active mounts detected for this host. Please enter manually."))
                    continue
                }
                print(tr("\n发现以下已挂载的共享卷宗：", "\nDiscovered mounted share volumes:"))
                for (idx, m) in candidateMounts.enumerated() {
                    let stdMount = deriveStandardMountPoint(from: m.smbURL) ?? "/Volumes/\(m.shareName)"
                    print("  [\(idx + 1)] \(m.shareName) (\(redactedSMBURL(m.smbURL)) -> \(stdMount))")
                }
                let pickPrompt = tr("请选择要追加的共享编号 [1-\(candidateMounts.count)] (按 Esc 取消): ",
                                    "Select share to add [1-\(candidateMounts.count)] (Esc to cancel): ")
                guard let pInput = promptLineWithEsc(prompt: pickPrompt),
                      let pIdx = Int(pInput.trimmingCharacters(in: .whitespacesAndNewlines)),
                      pIdx >= 1 && pIdx <= candidateMounts.count else { continue }
                let chosen = candidateMounts[pIdx - 1]
                let stdMount = deriveStandardMountPoint(from: chosen.smbURL) ?? "/Volumes/\(chosen.shareName)"
                if hostConfig.shares.contains(where: { $0.smbURL.lowercased() == chosen.smbURL.lowercased() || $0.mountPoint == stdMount }) {
                    print(tr("提示：共享路径 \(chosen.smbURL) 已存在于该主机名下，已自动忽略重复添加。",
                             "Notice: Share path \(chosen.smbURL) already exists under this host, duplicate ignored."))
                    continue
                }
                hostConfig.shares.append(SMBShareConfig(name: chosen.shareName, smbURL: chosen.smbURL, mountPoint: stdMount, enabled: true))
                print(tr("已添加共享 [\(chosen.shareName)]。", "Added share [\(chosen.shareName)]."))
            }
        } else if action == "d" {
            if hostConfig.shares.isEmpty {
                print(tr("当前无共享可删除。", "No shares to delete."))
                continue
            }
            let delPrompt = tr("请输入要删除的共享编号 [1-\(hostConfig.shares.count)] (按 Esc 取消): ",
                               "Enter share number to delete [1-\(hostConfig.shares.count)] (Esc to cancel): ")
            guard let delInput = promptLineWithEsc(prompt: delPrompt),
                  let delIdx = Int(delInput.trimmingCharacters(in: .whitespacesAndNewlines)),
                  delIdx >= 1 && delIdx <= hostConfig.shares.count else { continue }
            let removed = hostConfig.shares.remove(at: delIdx - 1)
            print(tr("已从主机移除共享 [\(removed.name)]。", "Removed share [\(removed.name)] from host."))
        } else if action == "t" {
            if hostConfig.shares.isEmpty {
                print(tr("当前无共享可切换状态。", "No shares to toggle."))
                continue
            }
            let togglePrompt = tr("请输入要切换状态的共享编号 [1-\(hostConfig.shares.count)] (按 Esc 取消): ",
                                  "Enter share number to toggle [1-\(hostConfig.shares.count)] (Esc to cancel): ")
            guard let tInput = promptLineWithEsc(prompt: togglePrompt),
                  let tIdx = Int(tInput.trimmingCharacters(in: .whitespacesAndNewlines)),
                  tIdx >= 1 && tIdx <= hostConfig.shares.count else { continue }
            hostConfig.shares[tIdx - 1].enabled.toggle()
            let newState = hostConfig.shares[tIdx - 1].enabled ? tr("启用", "Enabled") : tr("禁用", "Disabled")
            print(tr("共享 [\(hostConfig.shares[tIdx - 1].name)] 状态已切换为: [\(newState)]",
                     "Share [\(hostConfig.shares[tIdx - 1].name)] toggled to: [\(newState)]"))
        } else {
            print(tr("无效的选择，请重新输入。", "Invalid choice, please re-enter."))
        }
    }
}

func manageUpdateChannel(config: inout AutomntConfig) {
    print(tr("\n软件更新策略设置：", "\nSoftware Update Channel:"))
    print(tr("""
      [1] off    - 关闭自动检查
      [2] notify - 新版本系统通知提醒
      [3] auto   - 后台静默下载并自动升级
    """, """
      [1] off    - Disable auto-checks
      [2] notify - Notify only
      [3] auto   - Auto silent update
    """))
    let prompt = tr("请选择更新策略 [1-3] (按 Esc 取消): ", "Select update policy [1-3] (Esc to cancel): ")
    guard let input = promptLineWithEsc(prompt: prompt) else { return }
    let choice = input.trimmingCharacters(in: .whitespacesAndNewlines)
    switch choice {
    case "1", "off":
        config.updateChannel = "off"
        print(tr("✓ 更新信道已修改为: off", "✓ Update channel set to: off"))
    case "2", "notify":
        config.updateChannel = "notify"
        print(tr("✓ 更新信道已修改为: notify", "✓ Update channel set to: notify"))
    case "3", "auto":
        config.updateChannel = "auto"
        print(tr("✓ 更新信道已修改为: auto", "✓ Update channel set to: auto"))
    default:
        print(tr("未识别的策略，未做修改。", "Unrecognized policy, unchanged."))
    }
}

func manageConfiguration() {
    guard let configURL = prepareManagementConfigURL(),
          var config = loadConfig(from: configURL) else { return }

    while true {
        let hostsHint = config.hosts.isEmpty
            ? tr("  (当前未配置任何主机)", "  (No hosts configured)")
            : config.hosts.enumerated().map { (idx, h) in
                let aliasText = h.alias.map { " [\($0)]" } ?? ""
                let enabledSharesCount = h.shares.filter { $0.enabled }.count
                return tr("  顺位 \(idx + 1): \(h.host)\(aliasText) (启用的共享: \(enabledSharesCount) 个)",
                          "  Priority \(idx + 1): \(h.host)\(aliasText) (Enabled shares: \(enabledSharesCount))")
            }.joined(separator: "\n")

        let maxChoice = max(1, config.hosts.count)
        print(tr("""
        === automnt 日常配置管理 ===
        活动配置文件: \(configURL.path) (规范版本: \(config.version))

        当前配置的主机顺位列表 (探测时按由高到低排他执行):
        \(hostsHint)

        管理操作：
          [1-\(maxChoice)] 进入指定主机管理其从属共享
          [a]   新增主机 (扫描当前挂载 / 手动录入)
          [m]   调整主机顺位优先级
          [d]   删除主机 (支持清空所有主机)
          [u]   修改自动更新检查策略
          [q]   保存并退出 (按 Esc 等同放弃未保存修改退出)
        """, """
        === automnt Daily Configuration Management ===
        Active config: \(configURL.path) (Schema version: \(config.version))

        Configured hosts priority pipeline (probed top-down with short-circuit):
        \(hostsHint)

        Actions:
          [1-\(maxChoice)] Enter host to manage shares
          [a]   Add new host (Scan current mounts / Manual entry)
          [m]   Reorder host priority
          [d]   Delete host (Supports deleting all hosts)
          [u]   Modify update channel
          [q]   Save and exit (Esc discards unsaved changes)
        """))

        let prompt = tr("请选择操作 [1-\(maxChoice) / a / m / d / u / q]: ",
                        "Select action [1-\(maxChoice) / a / m / d / u / q]: ")
        guard let input = promptLineWithEsc(prompt: prompt) else {
            print(tr("已放弃未保存修改并退出。", "Discarded unsaved changes and exited."))
            return
        }
        let action = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if action == "q" {
            _ = saveConfig(config, to: configURL)
            print(tr("✓ 配置已保存并退出。", "✓ Configuration saved and exited."))
            return
        } else if action == "a" {
            print(tr("\n新增主机接入方式：\n  [1] 扫描当前挂载网络存储\n  [2] 手动录入新主机\n",
                     "\nAdd host method:\n  [1] Scan active mounted storage\n  [2] Manually enter new host\n"))
            let methodChoice = promptLineWithEsc(prompt: tr("请选择 [1/2] (默认 1, 按 Esc 取消): ", "Select [1/2] (Default 1, Esc to cancel): "), defaultValue: "1")
            if let method = methodChoice?.trimmingCharacters(in: .whitespacesAndNewlines) {
                if method == "2" {
                    if let newHost = handleManualHostEntry(existingHosts: config.hosts) {
                        config.hosts.append(newHost)
                        _ = saveConfig(config, to: configURL)
                    }
                } else {
                    let candidateHosts = discoverCandidateHosts().filter { c in
                        !config.hosts.contains(where: { $0.host == c.host })
                    }
                    if candidateHosts.isEmpty {
                        print(tr("未扫描到尚未配置的新挂载主机，请尝试手动录入。",
                                 "No unconfigured mounted hosts discovered. Please try manual entry."))
                    } else {
                        print(tr("\n发现以下未配置的候选主机：", "\nDiscovered unconfigured candidate hosts:"))
                        for (idx, c) in candidateHosts.enumerated() {
                            print("  [\(idx + 1)] \(c.host) (\(c.mounts.count) 个共享)")
                        }
                        let cPrompt = tr("请选择要添加的主机 [1-\(candidateHosts.count)] (按 Esc 取消): ",
                                         "Select host to add [1-\(candidateHosts.count)] (Esc to cancel): ")
                        if let cInput = promptLineWithEsc(prompt: cPrompt),
                           let cIdx = Int(cInput.trimmingCharacters(in: .whitespacesAndNewlines)),
                           cIdx >= 1 && cIdx <= candidateHosts.count {
                            let candidate = candidateHosts[cIdx - 1]
                            if let newHost = handleCandidateHostConfiguration(candidate: candidate) {
                                config.hosts.append(newHost)
                                _ = saveConfig(config, to: configURL)
                            }
                        }
                    }
                }
            }
        } else if action == "m" {
            if config.hosts.count < 2 {
                print(tr("当前配置主机少于 2 台，无需调整顺位。", "Fewer than 2 hosts configured, no reordering needed."))
                continue
            }
            print(tr("\n当前主机顺位：", "\nCurrent host priority:"))
            for (idx, h) in config.hosts.enumerated() {
                let aliasText = h.alias.map { " [\($0)]" } ?? ""
                print("  [\(idx + 1)] \(h.host)\(aliasText)")
            }
            let pickPrompt = tr("选择要调整顺位的主机编号 [1-\(config.hosts.count)] (按 Esc 取消): ",
                                "Select host to move [1-\(config.hosts.count)] (Esc to cancel): ")
            guard let pickInput = promptLineWithEsc(prompt: pickPrompt),
                  let pickIdx = Int(pickInput.trimmingCharacters(in: .whitespacesAndNewlines)),
                  pickIdx >= 1 && pickIdx <= config.hosts.count else { continue }
            let hostIndex = pickIdx - 1

            let dirPrompt = tr("移动方向：[u] 上移一位 / [d] 下移一位 (按 Esc 取消): ",
                               "Direction: [u] Move Up / [d] Move Down (Esc to cancel): ")
            guard let dirInput = promptLineWithEsc(prompt: dirPrompt) else { continue }
            let dir = dirInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if dir == "u" && hostIndex > 0 {
                config.hosts.swapAt(hostIndex, hostIndex - 1)
                _ = saveConfig(config, to: configURL)
                print(tr("✓ 主机顺位已提升！", "✓ Host moved up!"))
            } else if dir == "d" && hostIndex < config.hosts.count - 1 {
                config.hosts.swapAt(hostIndex, hostIndex + 1)
                _ = saveConfig(config, to: configURL)
                print(tr("✓ 主机顺位已降低！", "✓ Host moved down!"))
            }
        } else if action == "d" {
            if config.hosts.isEmpty {
                print(tr("当前无主机可删除。", "No hosts to delete."))
                continue
            }
            print(tr("\n当前配置的主机：", "\nConfigured hosts:"))
            for (idx, h) in config.hosts.enumerated() {
                let aliasText = h.alias.map { " [\($0)]" } ?? ""
                print("  [\(idx + 1)] \(h.host)\(aliasText)")
            }
            let delPrompt = tr("请输入要删除的主机编号 [1-\(config.hosts.count)] (按 Esc 取消): ",
                               "Enter host number to delete [1-\(config.hosts.count)] (Esc to cancel): ")
            guard let delInput = promptLineWithEsc(prompt: delPrompt),
                  let delIdx = Int(delInput.trimmingCharacters(in: .whitespacesAndNewlines)),
                  delIdx >= 1 && delIdx <= config.hosts.count else { continue }
            let removed = config.hosts.remove(at: delIdx - 1)
            _ = saveConfig(config, to: configURL)
            let aliasDisplay = removed.alias ?? removed.host
            print(tr("✓ 已移除主机 [\(aliasDisplay)]。", "✓ Removed host [\(aliasDisplay)]."))

            if config.hosts.isEmpty {
                print(tr("""

                当前主机列表为空 (0 台主机)。
                系统将该状态视为合法的静默休眠配置。
                """, """

                All hosts removed (0 hosts).
                This is considered a valid dormant sleep configuration.
                """))
                let saveEmptyPrompt = tr("保存并退出配置？[Y/n]: ", "Save and exit? [Y/n]: ")
                let saveChoice = promptLineWithEsc(prompt: saveEmptyPrompt, defaultValue: "Y")
                if let choice = saveChoice?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                   choice == "y" || choice == "yes" {
                    _ = saveConfig(config, to: configURL)
                    print(tr("配置已更新。后台服务在被系统唤醒时将处于安全休眠状态。",
                             "Configuration updated. The background daemon will stay in safe dormant sleep."))
                    return
                } else {
                    print(tr("已取消保存退出，继续停留在配置菜单。", "Cancelled saving and exit, staying in configuration menu."))
                }
            }
        } else if action == "u" {
            manageUpdateChannel(config: &config)
            _ = saveConfig(config, to: configURL)
        } else if let num = Int(action), num >= 1, num <= config.hosts.count {
            manageHostShares(hostConfig: &config.hosts[num - 1], allHosts: config.hosts)
            _ = saveConfig(config, to: configURL)
        } else {
            print(tr("无效的选择，请重新输入。", "Invalid choice, please re-enter."))
        }
    }
}

// MARK: - 自搬迁、Shell 注入与自检自愈 (Installation & Healing)

struct ShellSnippetManager {
    static let beginMarker = "# >>> automnt CLI begin >>>"
    static let endMarker = "# <<< automnt CLI end <<<"

    static func snippet(binaryDir: String) -> String {
        return """
        \(beginMarker)
        export PATH="\(binaryDir):$PATH"
        \(endMarker)
        """
    }

    static func isPresent(in content: String) -> Bool {
        return content.contains(beginMarker) && content.contains(endMarker)
    }

    static func inject(into content: String, binaryPath: String) -> String {
        let binDir = URL(fileURLWithPath: binaryPath).deletingLastPathComponent().path
        let newSnippet = snippet(binaryDir: binDir)
        var cleaned = remove(from: content)
        if !cleaned.isEmpty && !cleaned.hasSuffix("\n") {
            cleaned.append("\n")
        }
        return cleaned + newSnippet + "\n"
    }

    static func remove(from content: String) -> String {
        let pattern = "(?s)\\n?\(NSRegularExpression.escapedPattern(for: beginMarker)).*?\(NSRegularExpression.escapedPattern(for: endMarker))\\n?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return content }
        let range = NSRange(content.startIndex..., in: content)
        return regex.stringByReplacingMatches(in: content, options: [], range: range, withTemplate: "\n")
            .trimmingCharacters(in: .newlines) + "\n"
    }
}

struct InstallationManager {
    static func currentExecutablePhysicalURL() -> URL {
        var buffer = [CChar](repeating: 0, count: 4096)
        let pid = getpid()
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            let path = String(cString: buffer)
            return URL(fileURLWithPath: path).resolvingSymlinksInPath()
        }
        return URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    }

    static func detectShellProfileURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [".zshrc", ".bash_profile", ".bashrc"]
        for candidate in candidates {
            let url = home.appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return home.appendingPathComponent(".zshrc")
    }

    @discardableResult
    static func relocateIfNeeded() -> Bool {
        let currentURL = currentExecutablePhysicalURL()
        let targetURL = getActiveInstalledBinaryURL()
        if currentURL.standardizedFileURL.path == targetURL.standardizedFileURL.path {
            return false
        }

        let targetDir = targetURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: targetURL.path) {
            try? FileManager.default.removeItem(at: targetURL)
        }
        do {
            try FileManager.default.copyItem(at: currentURL, to: targetURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: targetURL.path)
            let isDevRepo = FileManager.default.fileExists(
                atPath: currentURL.deletingLastPathComponent().appendingPathComponent("automnt.swift").path
            )
            if !isDevRepo {
                _ = Darwin.unlink(currentURL.path)
            }
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func injectShellEntry() -> Bool {
        guard let profileURL = detectShellProfileURL() else { return false }
        let currentContent = (try? String(contentsOf: profileURL, encoding: .utf8)) ?? ""
        let binaryPath = getActiveInstalledBinaryURL().path
        let updated = ShellSnippetManager.inject(into: currentContent, binaryPath: binaryPath)
        do {
            try updated.write(to: profileURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func removeShellEntry() -> Bool {
        guard let profileURL = detectShellProfileURL(),
              FileManager.default.fileExists(atPath: profileURL.path) else { return false }
        guard let currentContent = try? String(contentsOf: profileURL, encoding: .utf8) else { return false }
        let updated = ShellSnippetManager.remove(from: currentContent)
        do {
            try updated.write(to: profileURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}

struct InstallState: Equatable {
    var currentExecutablePath: String
    var installedBinaryPath: String
    var activeConfigPath: String
    var launchAgentPlistPath: String
    var detectedShellProfile: String?
    var isRelocated: Bool
    var isCliEntryPresent: Bool
    var isServiceRegistered: Bool
    var isServicePlistValid: Bool

    var isHealthy: Bool {
        isRelocated && isCliEntryPresent && isServiceRegistered && isServicePlistValid
    }

    static func current() -> InstallState {
        let currentExec = InstallationManager.currentExecutablePhysicalURL().path
        let canonicalBinary = getActiveInstalledBinaryURL().path
        let activeConfig = getActiveConfigURL().path
        let plistURL = getLaunchAgentPlistURL()
        let profileURL = InstallationManager.detectShellProfileURL()
        let isRelocated = currentExec == canonicalBinary

        var isCliEntryPresent = false
        if let profileURL, let content = try? String(contentsOf: profileURL, encoding: .utf8) {
            isCliEntryPresent = ShellSnippetManager.isPresent(in: content)
        }

        var isServicePlistValid = false
        if let data = try? Data(contentsOf: plistURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            let label = plist["Label"] as? String
            let args = plist["ProgramArguments"] as? [String]
            let hasStartInterval = plist["StartInterval"] != nil
            if label == launchAgentLabel && args == [canonicalBinary] && !hasStartInterval {
                isServicePlistValid = true
            }
        }

        let serviceTarget = "gui/\(getuid())/\(launchAgentLabel)"
        let printResult = runCommand(executable: "/bin/launchctl", arguments: ["print", serviceTarget])
        let isServiceRegistered = printResult.status == 0

        return InstallState(
            currentExecutablePath: currentExec,
            installedBinaryPath: canonicalBinary,
            activeConfigPath: activeConfig,
            launchAgentPlistPath: plistURL.path,
            detectedShellProfile: profileURL?.path,
            isRelocated: isRelocated,
            isCliEntryPresent: isCliEntryPresent,
            isServiceRegistered: isServiceRegistered,
            isServicePlistValid: isServicePlistValid
        )
    }

    func healIfNeeded() -> Bool {
        var healed = false
        if !isCliEntryPresent {
            _ = InstallationManager.injectShellEntry()
            healed = true
        }
        if !isServicePlistValid || !isServiceRegistered {
            _ = registerOrUpdateLaunchAgent()
            healed = true
        }
        return healed
    }
}

func generateLaunchAgentDictionary(binaryURL: URL, logDir: URL) -> [String: Any] {
    let stdoutLog = logDir.appendingPathComponent("stdout.log").path
    let stderrLog = logDir.appendingPathComponent("stderr.log").path
    let sysConfigDir = "/Library/Preferences/SystemConfiguration"

    return [
        "Label": launchAgentLabel,
        "ProgramArguments": [binaryURL.path],
        "RunAtLoad": true,
        "WatchPaths": [
            "\(sysConfigDir)/NetworkInterfaces.plist",
            "\(sysConfigDir)/com.apple.airport.preferences.plist",
            sysConfigDir
        ],
        "StandardOutPath": stdoutLog,
        "StandardErrorPath": stderrLog
    ]
}

func registerOrUpdateLaunchAgent(targetBinaryURL: URL? = nil, targetPlistURL: URL? = nil) -> Bool {
    let binary = targetBinaryURL ?? getActiveInstalledBinaryURL()
    let plistURL = targetPlistURL ?? getLaunchAgentPlistURL()
    let logDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/automnt", isDirectory: true)

    try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    let agentDict = generateLaunchAgentDictionary(binaryURL: binary, logDir: logDir)

    do {
        let parentDir = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: agentDict, format: .xml, options: 0)
        try atomicWrite(data, to: plistURL, permissions: 0o644)
    } catch {
        return false
    }

    let uid = getuid()
    let serviceTarget = "gui/\(uid)/\(launchAgentLabel)"
    _ = runCommand(executable: "/bin/launchctl", arguments: ["bootout", serviceTarget])
    let bootinResult = runCommand(executable: "/bin/launchctl", arguments: ["bootstrap", "gui/\(uid)", plistURL.path])
    return bootinResult.status == 0
}

func installLaunchAgent() {
    print(tr("""
    automnt - 安装并启用自启动守护服务
    ===========================================
    """, """
    automnt - Install LaunchAgent Daemon
    ============================================
    """))

    let binary = getActiveInstalledBinaryURL()
    if !FileManager.default.fileExists(atPath: binary.path) {
        InstallationManager.relocateIfNeeded()
    }
    InstallationManager.injectShellEntry()
    let success = registerOrUpdateLaunchAgent()
    let plistURL = getLaunchAgentPlistURL()
    if success {
        print(tr("✓ 已生成服务描述文件:\n  \(plistURL.path)", "✓ Generated LaunchAgent plist:\n  \(plistURL.path)"))
        print(tr("✓ 成功注册并加载至系统 launchd 守护进程 (gui/\(getuid()))",
                 "✓ Successfully registered and loaded into system launchd (gui/\(getuid()))"))
        print(tr("""

        服务详情:
          • 标识 (Label): \(launchAgentLabel)
          • 执行命令: \(binary.path)
          • 触发时机: 登录启动与系统网络配置变化事件驱动
          • 日志路径: ~/Library/Logs/automnt/stdout.log

        自启动与网络监听服务已生效。
        """, """

        Service Details:
          • Label: \(launchAgentLabel)
          • Command: \(binary.path)
          • Trigger: Login and network change event-driven
          • Log file: ~/Library/Logs/automnt/stdout.log

        LaunchAgent is loaded and will evaluate the configured network policy.
        """))
    } else {
        fputs(tr("✗ 注册守护服务失败，请检查 launchd 权限。\n",
                 "✗ Failed to register daemon service.\n"), stderr)
    }
}

func uninstallLaunchAgent(purge: Bool = false) {
    print(tr("""
    automnt - 卸载自启动服务
    =================================
    """, """
    automnt - Uninstall LaunchAgent Daemon
    ==============================================
    """))

    let uid = getuid()
    let serviceTarget = "gui/\(uid)/\(launchAgentLabel)"
    let plistURL = getLaunchAgentPlistURL()
    let appSupportDir = getActiveInstalledDir()
    let canonicalBinaryURL = getActiveInstalledBinaryURL()
    let activeConfig = getActiveConfigURL()

    let bootResult = runCommand(executable: "/bin/launchctl", arguments: ["bootout", serviceTarget])
    if bootResult.status == 0 {
        print(tr("✓ 成功从系统 launchd 中卸载服务 (\(serviceTarget))",
                 "✓ Unloaded service from system launchd (\(serviceTarget))"))
    }

    if FileManager.default.fileExists(atPath: plistURL.path) {
        do {
            try FileManager.default.removeItem(at: plistURL)
            print(tr("✓ 已删除服务描述文件: \(plistURL.path)", "✓ Removed LaunchAgent plist: \(plistURL.path)"))
        } catch {
            fputs(tr("✗ 删除描述文件失败: \(error.localizedDescription)\n",
                     "✗ Failed to remove plist: \(error.localizedDescription)\n"), stderr)
        }
    }

    if InstallationManager.removeShellEntry() {
        print(tr("✓ 已从 Shell 配置文件中清除 automnt CLI 入口",
                 "✓ Removed automnt CLI snippet from shell profile"))
    }

    if FileManager.default.fileExists(atPath: canonicalBinaryURL.path) {
        try? FileManager.default.removeItem(at: canonicalBinaryURL)
        print(tr("✓ 已删除规范安装目录可执行文件", "✓ Removed canonical executable"))
    }

    if purge {
        if FileManager.default.fileExists(atPath: appSupportDir.path) {
            try? FileManager.default.removeItem(at: appSupportDir)
            print(tr("✓ 已彻底删除 Application Support 目录: \(appSupportDir.path)",
                     "✓ Purged Application Support directory: \(appSupportDir.path)"))
        }
        let logDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/automnt")
        if FileManager.default.fileExists(atPath: logDir.path) {
            try? FileManager.default.removeItem(at: logDir)
            print(tr("✓ 已彻底删除日志目录: \(logDir.path)", "✓ Purged log directory: \(logDir.path)"))
        }
        print(tr("\n✓ automnt 已全量彻底卸载清理。", "\n✓ automnt fully purged."))
    } else {
        print(tr("""

        注意：您的配置文件已保留在:
          \(activeConfig.path)
        如需彻底删除配置与历史日志，请执行:
          automnt --uninstall --purge
        或直接删除: rm -rf "\(appSupportDir.path)"
        """, """

        Note: Your configuration has been preserved at:
          \(activeConfig.path)
        To completely remove configuration and logs, run:
          automnt --uninstall --purge
        Or manually remove: rm -rf "\(appSupportDir.path)"
        """))
    }
}

func checkServiceStatus() {
    print(tr("""
    automnt - 运行状态总览 (v\(automntVersion))
    ====================================
    """, """
    automnt - Service Status Overview (v\(automntVersion))
    =============================================
    """))

    let activeConfigURL = getActiveConfigURL()
    let installState = InstallState.current()

    print(tr("安装与自愈状态:", "Installation & Health State:"))
    print(tr("  • 规范路径就绪: \(installState.isRelocated ? "✓ 是" : "✗ 否")",
             "  • Relocated: \(installState.isRelocated ? "✓ Yes" : "✗ No")"))
    print(tr("  • Shell CLI 入口: \(installState.isCliEntryPresent ? "✓ 正常" : "✗ 缺失")",
             "  • Shell CLI Snippet: \(installState.isCliEntryPresent ? "✓ Present" : "✗ Missing")"))
    print(tr("  • 守护服务登记: \(installState.isServiceRegistered ? "✓ 已注册" : "✗ 未注册")",
             "  • Service Registered: \(installState.isServiceRegistered ? "✓ Registered" : "✗ Not Registered")"))
    print(tr("  • 描述文件合规: \(installState.isServicePlistValid ? "✓ 合规" : "✗ 异常")",
             "  • Plist Valid: \(installState.isServicePlistValid ? "✓ Valid" : "✗ Invalid")"))

    print(tr("\n配置与守护服务:", "\nConfiguration & Daemon:"))
    print(tr("  • 唯一活动配置: \(activeConfigURL.path)", "  • Active Config: \(activeConfigURL.path)"))
    print(tr("  • 守护服务状态: \(getLaunchAgentStatusSummary())", "  • Service Summary: \(getLaunchAgentStatusSummary())"))

    if let config = loadConfig(from: activeConfigURL, migrate: false) {
        if config.hosts.isEmpty && config.profiles.isEmpty {
            print(tr("\n当前未配置任何主机 (安全休眠状态)。", "\nNo hosts configured (safe dormant sleep state)."))
        } else if !config.hosts.isEmpty {
            print(tr("\n已配置主机顺位 (\(config.hosts.count) 个)：", "\nConfigured Host Pipeline (\(config.hosts.count)):"))
            for (idx, h) in config.hosts.enumerated() {
                let aliasText = h.alias.map { " '\($0)'" } ?? ""
                print(tr("  [\(idx + 1)]\(aliasText) -> 主机: \(h.host):\(h.port), 超时: \(h.timeoutMs)ms, 共享: \(h.shares.count) 个",
                         "  [\(idx + 1)]\(aliasText) -> Host: \(h.host):\(h.port), Timeout: \(h.timeoutMs)ms, Shares: \(h.shares.count)"))
                for s in h.shares {
                    let mounted = getKernelMountSource(for: s.mountPoint) != nil
                    let statusStr = mounted ? tr("已挂载", "Mounted") : tr("未挂载", "Unmounted")
                    let enabledStr = s.enabled ? tr("启用", "Enabled") : tr("禁用", "Disabled")
                    print("      - \(s.name) (\(s.mountPoint)) [\(statusStr), \(enabledStr)] -> \(redactedSMBURL(s.smbURL))")
                }
            }
        } else {
            print(tr("\n已配置策略流水线 (\(config.profiles.count) 个)：", "\nConfigured Profile Pipeline (\(config.profiles.count)):"))
            for (idx, p) in config.profiles.enumerated() {
                print(tr("  [\(idx + 1)] '\(p.id)' (\(p.description ?? "")) -> 主机: \(p.host):\(p.port ?? 445), 超时: \(p.timeoutMs ?? 1000)ms, 挂载目标: \(p.targets.count) 个",
                         "  [\(idx + 1)] '\(p.id)' (\(p.description ?? "")) -> Host: \(p.host):\(p.port ?? 445), Timeout: \(p.timeoutMs ?? 1000)ms, Targets: \(p.targets.count)"))
                for t in p.targets {
                    let mounted = getKernelMountSource(for: t.mountPath) != nil
                    let statusStr = mounted ? tr("已挂载", "Mounted") : tr("未挂载", "Unmounted")
                    print("      - \(t.mountPath) [\(statusStr)] -> \(redactedSMBURL(t.url))")
                }
            }
        }
    } else {
        print(tr("\n未找到有效配置，建议运行: automnt --init", "\nNo valid config found. Recommended command: automnt --init"))
    }
}

// MARK: - 预编译二进制升级系统 (Self-Update via Prebuilt Binary)

func quoteAppleScript(_ str: String) -> String {
    "\"" + str.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

func showMacOSNotification(title: String, subtitle: String, message: String) {
    let script = "display notification \(quoteAppleScript(message)) with title \(quoteAppleScript(title)) subtitle \(quoteAppleScript(subtitle))"
    _ = runCommand(executable: "/usr/bin/osascript", arguments: ["-e", script])
}

func parseSemanticVersion(_ versionStr: String) -> [Int] {
    let clean = versionStr.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "v", with: "")
        .replacingOccurrences(of: "V", with: "")
    let parts = clean.split(separator: "-").first.map(String.init) ?? clean
    return parts.split(separator: ".").compactMap { Int($0) }
}

func isNewerVersion(_ remote: String, than current: String) -> Bool {
    let r = parseSemanticVersion(remote)
    let c = parseSemanticVersion(current)
    let maxLen = max(r.count, c.count)
    for i in 0..<maxLen {
        let rVal = i < r.count ? r[i] : 0
        let cVal = i < c.count ? c[i] : 0
        if rVal > cVal { return true }
        if rVal < cVal { return false }
    }
    return false
}

struct GitHubReleaseInfo {
    let tagName: String
    let name: String
    let body: String
    let htmlURL: String
}

enum ReleaseFetchResult {
    case success(GitHubReleaseInfo)
    case rateLimited
    case noRelease
    case networkError(String)
}

func fetchLatestReleaseInfo() -> ReleaseFetchResult {
    let urlString = "https://api.github.com/repos/\(githubRepo)/releases/latest"
    guard let url = URL(string: urlString) else { return .networkError("Invalid URL") }
    var request = URLRequest(url: url)
    request.timeoutInterval = 10
    request.setValue("automnt/\(automntVersion)", forHTTPHeaderField: "User-Agent")

    let semaphore = DispatchSemaphore(value: 0)
    var fetchResult: ReleaseFetchResult = .noRelease

    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        if let error = error {
            fetchResult = .networkError(error.localizedDescription)
            return
        }
        guard let http = response as? HTTPURLResponse else {
            fetchResult = .networkError("Invalid response")
            return
        }
        if http.statusCode == 403 || http.statusCode == 429 {
            fetchResult = .rateLimited
            return
        }
        guard http.statusCode == 200, let data = data else {
            fetchResult = .noRelease
            return
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tag = json["tag_name"] as? String {
            let name = json["name"] as? String ?? tag
            let body = json["body"] as? String ?? ""
            let htmlURL = json["html_url"] as? String ?? ""
            fetchResult = .success(GitHubReleaseInfo(tagName: tag, name: name, body: body, htmlURL: htmlURL))
        }
    }
    task.resume()
    _ = semaphore.wait(timeout: .now() + 15)
    return fetchResult
}

func downloadLatestBinary(tag: String) -> Data? {
    let cleanTag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
    let urlString = "https://github.com/\(githubRepo)/releases/download/\(cleanTag)/automnt"
    guard let url = URL(string: urlString) else { return nil }

    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    request.setValue("automnt/\(automntVersion)", forHTTPHeaderField: "User-Agent")

    let semaphore = DispatchSemaphore(value: 0)
    var resultData: Data?

    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        if let http = response as? HTTPURLResponse, http.statusCode == 200, let d = data, !d.isEmpty {
            resultData = d
        }
    }
    task.resume()
    _ = semaphore.wait(timeout: .now() + 35)
    return resultData
}

func performSelfUpdateWithBinary(newVersion: String, binaryData: Data, isSilent: Bool) -> Bool {
    let targetURL = getActiveInstalledBinaryURL()
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("automnt-update-\(UUID().uuidString)")
    let stagedBinary = tempDir.appendingPathComponent("automnt")

    do {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try binaryData.write(to: stagedBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedBinary.path)

        let valResult = runCommand(executable: stagedBinary.path, arguments: ["--version"])
        guard valResult.status == 0, valResult.stdout.contains(newVersion) else {
            writeLog("Prebuilt binary validation failed for v\(newVersion)")
            return false
        }

        try replaceFilesTransactionally([
            StagedFileReplacement(sourceURL: stagedBinary, destinationURL: targetURL, permissions: 0o755)
        ])

        writeLog("Successfully updated automnt to v\(newVersion)")
        if !isSilent {
            print(tr("✓ 成功升级 automnt 至 v\(newVersion)", "✓ Successfully updated automnt to v\(newVersion)"))
        }
        return true
    } catch {
        writeLog("Self-update failed: \(error.localizedDescription)")
        return false
    }
}

func handleManualUpdateCommand() {
    print(tr("正在检查新版本...", "Checking for updates..."))
    let res = fetchLatestReleaseInfo()
    switch res {
    case .success(let info):
        let remoteVer = info.tagName.replacingOccurrences(of: "v", with: "")
        if isNewerVersion(remoteVer, than: automntVersion) {
            print(tr("发现新版本: v\(remoteVer) (当前: v\(automntVersion))",
                     "New version available: v\(remoteVer) (Current: v\(automntVersion))"))
            print(tr("正在下载预编译二进制...", "Downloading prebuilt binary..."))
            if let binaryData = downloadLatestBinary(tag: info.tagName) {
                if performSelfUpdateWithBinary(newVersion: remoteVer, binaryData: binaryData, isSilent: false) {
                    print(tr("升级完成！请重新运行 'automnt'。", "Update complete! Please run 'automnt' again."))
                } else {
                    print(tr("✗ 升级安装失败。", "✗ Update installation failed."))
                }
            } else {
                print(tr("✗ 下载二进制文件失败，请检查网络连接。", "✗ Failed to download binary. Please check network connection."))
            }
        } else {
            print(tr("已是最新版本 (v\(automntVersion))。", "Already up to date (v\(automntVersion))."))
        }
    case .rateLimited:
        print(tr("GitHub API 速率限制，请稍后再试。", "GitHub API rate limited. Please try again later."))
    case .noRelease:
        print(tr("未找到 Release 资产。", "No release assets found."))
    case .networkError(let err):
        print(tr("网络错误: \(err)", "Network error: \(err)"))
    }
}

func triggerBackgroundUpdateCheckIfNeeded(config: inout AutomntConfig) {
    let channel = config.updateChannel ?? "off"
    guard channel != "off" else { return }

    let now = Date().timeIntervalSince1970
    if let lastCheck = config.lastUpdateCheckTimestamp, now - lastCheck < 86400 {
        return
    }
    config.lastUpdateCheckTimestamp = now
    _ = saveConfig(config)

    let fetchRes = fetchLatestReleaseInfo()
    guard case .success(let info) = fetchRes else { return }
    let remoteVer = info.tagName.replacingOccurrences(of: "v", with: "")
    guard isNewerVersion(remoteVer, than: automntVersion) else { return }

    if channel == "notify" {
        if config.lastNotifiedVersion != remoteVer {
            showMacOSNotification(
                title: "automnt",
                subtitle: tr("发现新版本 \(remoteVer) (当前: v\(automntVersion))", "New version \(remoteVer) available"),
                message: tr("运行 'automnt --update' 升级", "Run 'automnt --update' to upgrade")
            )
            config.lastNotifiedVersion = remoteVer
            _ = saveConfig(config)
        }
    } else if channel == "auto" {
        if let data = downloadLatestBinary(tag: info.tagName) {
            _ = performSelfUpdateWithBinary(newVersion: remoteVer, binaryData: data, isSilent: true)
        }
    }
}

// MARK: - 内置自动化测试套件 (--self-test)

func runSelfTests(includeNetworkChecks: Bool = false) -> Bool {
    var passed = 0
    var failed = 0
    let skipped = 0

    func check(_ condition: Bool, _ name: String) {
        if condition {
            passed += 1
            print("PASS \(name)")
        } else {
            failed += 1
            print("FAIL \(name)")
        }
        fflush(stdout)
    }

    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("automnt-selftest-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    // 1. Config inspection tests
    let missingConfig = inspectConfigFile(at: tempDir.appendingPathComponent("missing.plist"))
    check(missingConfig.state == .missing, "config inspection distinguishes a missing file")

    let invalidURL = tempDir.appendingPathComponent("invalid.plist")
    try? Data("not a plist".utf8).write(to: invalidURL)
    let invalidConfig = inspectConfigFile(at: invalidURL)
    check(invalidConfig.state == .invalid, "config inspection distinguishes a malformed file")

    let dirURL = tempDir.appendingPathComponent("is-a-dir")
    try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
    let dirConfig = inspectConfigFile(at: dirURL)
    check(dirConfig.state == .inaccessible, "config inspection refuses a directory")

    // 2. Backup & Prune tests (FR-024, SC-016)
    let sampleData = Data("<plist version=\"1.0\"><dict><key>test</key><string>val</string></dict></plist>".utf8)
    let sampleURL = tempDir.appendingPathComponent("sample.plist")
    try? sampleData.write(to: sampleURL)
    let sampleInspection = inspectConfigFile(at: sampleURL)
    let b1 = try? backUpConfigFile(sampleInspection)
    check(b1 != nil && FileManager.default.fileExists(atPath: b1!.path), "config backup creates file")
    let b1Perms = (try? FileManager.default.attributesOfItem(atPath: b1!.path)[.posixPermissions] as? NSNumber)?.intValue
    check(b1Perms == 0o600, "config backup preserves 0600 permissions")

    let b2 = try? backUpConfigFile(sampleInspection)
    check(b2 != nil, "second backup creates file")
    pruneConfigBackups(for: sampleURL, maxToKeep: 1)
    let backupFiles = (try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil))?.filter {
        $0.lastPathComponent.hasPrefix("sample.plist.backup-")
    } ?? []
    check(backupFiles.count == 1, "pruneConfigBackups strictly retains at most 1 backup")

    // 3. NetworkProfile & AutomntConfig models
    let testProfile = NetworkProfile(
        id: "test_lan",
        description: "Test Profile",
        host: "nas.invalid",
        port: 445,
        timeoutMs: 1000,
        preventSpotlightIndex: true,
        targets: [MountTarget(url: "smb://nas.invalid/share", mountPath: "/Volumes/share")]
    )
    check(testProfile.host == "nas.invalid" && testProfile.port == 445, "NetworkProfile fields are properly mapped")

    let testConfig = AutomntConfig(
        version: automntVersion,
        updateChannel: "auto",
        retryPolicy: RetryPolicy(),
        lastUpdateCheckTimestamp: nil,
        lastNotifiedVersion: nil,
        hosts: [HostConfig(host: "nas.local", alias: "本地局域网直连", shares: [SMBShareConfig(name: "share", smbURL: "smb://nas.local/share", mountPoint: "/Volumes/share")])],
        profiles: []
    )
    check(!configNeedsMigration(testConfig), "modern config does not need migration")

    var oldConfig = testConfig
    oldConfig.version = "2.7.1"
    check(configNeedsMigration(oldConfig), "older version config needs migration")

    var legacyProfileConfig = testConfig
    legacyProfileConfig.profiles = [testProfile]
    check(configNeedsMigration(legacyProfileConfig), "legacy profiles need migration")

    // 4. Migration & Unknown fields retention
    let migrationURL = tempDir.appendingPathComponent("migration_test.plist")
    let legacyXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    \t<key>version</key>
    \t<string>2.7.1</string>
    \t<key>update_channel</key>
    \t<string>auto</string>
    \t<key>custom_root_field</key>
    \t<string>custom_value</string>
    \t<key>profiles</key>
    \t<array>
    \t\t<dict>
    \t\t\t<key>id</key>
    \t\t\t<string>home_lan</string>
    \t\t\t<key>description</key>
    \t\t\t<string>家庭局域网直连</string>
    \t\t\t<key>host</key>
    \t\t\t<string>nas.local</string>
    \t\t\t<key>targets</key>
    \t\t\t<array>
    \t\t\t\t<dict>
    \t\t\t\t\t<key>mount_path</key>
    \t\t\t\t\t<string>/Volumes/share-1</string>
    \t\t\t\t\t<key>url</key>
    \t\t\t\t\t<string>smb://nas.local/share</string>
    \t\t\t\t</dict>
    \t\t\t</array>
    \t\t</dict>
    \t</array>
    </dict>
    </plist>
    """
    try? legacyXML.data(using: .utf8)?.write(to: migrationURL)
    var loadedLegacy = loadConfig(from: migrationURL, migrate: false)!
    let migrationSuccess = migrateConfigIfNeeded(config: &loadedLegacy, at: migrationURL)
    check(migrationSuccess, "config migration executes successfully")
    check(loadedLegacy.version == automntVersion, "migrated version is updated to current")
    check(loadedLegacy.hosts.first?.host == "nas.local", "migrated host is updated to hosts")
    check(loadedLegacy.hosts.first?.shares.first?.mountPoint == "/Volumes/share", "migrated share mountPoint is /Volumes/share with -1 cleaned")
    let postMigrationString = (try? String(contentsOf: migrationURL, encoding: .utf8)) ?? ""
    check(postMigrationString.contains("custom_root_field") && postMigrationString.contains("custom_value"),
          "migration preserves unknown plist fields")

    // 5. SMB URL & Path validations
    check(smbResourceIdentity("smb://user:pass@NAS.local/Share") == smbResourceIdentity("//nas.local/share"),
          "SMB identity ignores credentials and casing")
    check(smbResourceIdentity("smb://nas.local/share1") != smbResourceIdentity("smb://nas.local/share2"),
          "different shares have different identities")
    check(extractHost(from: "smb://[fd00::1]/share") == "fd00::1", "IPv6 SMB host is correctly extracted")
    check(validateMountTargetURL("smb://nas.local/share") == nil, "valid SMB URL is accepted")
    check(validateMountTargetURL("https://nas.local/share") != nil, "non-SMB URL is rejected")
    check(validateMountTargetURL("smb://nas.local") != nil, "SMB URL without share is rejected")
    check(validateMountTargetURL("smb://user:pass@nas.local/share") != nil, "embedded credentials in SMB URL are rejected")
    check(validateMountTargetURL("smb://user@nas.local/share") != nil, "embedded username in SMB URL are rejected")
    check(validateMountPath("/Volumes/share") == nil, "absolute mount path is accepted")
    check(validateMountPath("relative/share") != nil, "relative mount path is rejected")
    check(validateMountPath("/Volumes/../root") != nil, "traversal mount path is rejected")

    let redacted = redactedSMBURL("smb://alice:secret@nas.local/share")
    check(!redacted.contains("alice") && !redacted.contains("secret"), "SMB URL credentials are redacted")

    // 6. LaunchAgent dictionary (WatchPaths & No StartInterval)
    let agentDict = generateLaunchAgentDictionary(binaryURL: URL(fileURLWithPath: "/usr/local/bin/automnt"), logDir: tempDir)
    check(agentDict["RunAtLoad"] as? Bool == true, "LaunchAgent dictionary includes RunAtLoad = true")
    check(agentDict["WatchPaths"] as? [String] != nil, "LaunchAgent dictionary includes WatchPaths")
    check(agentDict["StartInterval"] == nil, "LaunchAgent dictionary strictly excludes StartInterval")

    // 7. Atomic transaction file replacement & rollback
    let txnDir = tempDir.appendingPathComponent("txn")
    try? FileManager.default.createDirectory(at: txnDir, withIntermediateDirectories: true)
    let src1 = txnDir.appendingPathComponent("src1")
    let dst1 = txnDir.appendingPathComponent("dst1")
    try? Data("new content".utf8).write(to: src1)
    try? Data("original content".utf8).write(to: dst1)
    try? replaceFilesTransactionally([StagedFileReplacement(sourceURL: src1, destinationURL: dst1, permissions: 0o600)])
    check((try? String(contentsOf: dst1, encoding: .utf8)) == "new content", "transactional file replacement succeeds")

    var rollbackPassed = false
    do {
        try replaceFilesTransactionally([
            StagedFileReplacement(sourceURL: src1, destinationURL: dst1, permissions: 0o600)
        ]) {
            throw NSError(domain: "AutomntTest", code: 1, userInfo: nil)
        }
    } catch {
        rollbackPassed = (try? String(contentsOf: dst1, encoding: .utf8)) == "new content"
    }
    check(rollbackPassed, "transactional file replacement rolls back on action error")

    // 8. Child runner non-deadlock & timeout
    let pipeTest = runCommand(
        executable: "/bin/sh",
        arguments: ["-c", "/usr/bin/yes x | /usr/bin/head -c 131072 >&2; printf stdout"]
    )
    check(pipeTest.status == 0 && pipeTest.stdout == "stdout" && pipeTest.stderr.utf8.count == 131072,
          "child stdout and large stderr are drained without deadlock")

    let timedOutCommand = runCommandDiscardingOutputWithTimeout(
        executable: "/bin/sleep", arguments: ["2"], timeout: 0.05
    )
    check(timedOutCommand.timedOut && timedOutCommand.processStopped,
          "bounded child runner terminates and reaps a timed-out command")

    // 9. Shell snippet injection & removal
    let profileContent = "export VAR=foo\nalias ll='ls -l'\n"
    let injected = ShellSnippetManager.inject(into: profileContent, binaryPath: "/custom/bin/automnt")
    check(ShellSnippetManager.isPresent(in: injected), "Shell snippet is detected after injection")
    check(injected.contains("/custom/bin"), "Shell snippet contains binary directory")
    check(injected.contains("export VAR=foo"), "Shell snippet preserves original user variables")
    let reinjected = ShellSnippetManager.inject(into: injected, binaryPath: "/new/bin/automnt")
    check(reinjected.contains("/new/bin") && !reinjected.contains("/custom/bin"), "Shell snippet injection is idempotent")
    let stripped = ShellSnippetManager.remove(from: reinjected)
    check(!ShellSnippetManager.isPresent(in: stripped), "Shell snippet is cleanly removed")
    check(stripped.contains("export VAR=foo") && stripped.contains("alias ll='ls -l'"), "Shell snippet removal restores original profile")

    // 10. EvaluationRetryRunner tests
    var runnerAttempts = 0
    let retryRunner = EvaluationRetryRunner(policy: RetryPolicy(maxAttempts: 3, intervalMs: 10, maxTotalWindowMs: 500))
    let retrySuccess = retryRunner.run {
        runnerAttempts += 1
        return runnerAttempts == 2
    }
    check(retrySuccess && runnerAttempts == 2, "EvaluationRetryRunner retries and succeeds within window")

    var failAttempts = 0
    let failRunner = EvaluationRetryRunner(policy: RetryPolicy(maxAttempts: 2, intervalMs: 10, maxTotalWindowMs: 100))
    let failResult = failRunner.run {
        failAttempts += 1
        return false
    }
    check(!failResult && failAttempts == 2, "EvaluationRetryRunner exhausts attempts cleanly")

    // 11. HostReachabilityProbe tests
    check(!HostReachabilityProbe.canConnect(host: ""), "HostReachabilityProbe rejects empty host")
    check(!HostReachabilityProbe.canConnect(host: "127.0.0.1", port: 59999, timeoutMs: 50),
          "HostReachabilityProbe handles unreachable host gracefully")

    // 12. Active Canonical Paths & Environment Simulation tests
    let customConfigURL = tempDir.appendingPathComponent("custom_test.plist")
    configURLOverride = customConfigURL
    check(getActiveConfigURL() == customConfigURL, "getActiveConfigURL respects configURLOverride")
    configURLOverride = nil
    check(getActiveConfigURL().lastPathComponent == "automnt.plist", "getActiveConfigURL targets automnt.plist")
    check(getActiveInstalledBinaryURL().lastPathComponent == "automnt", "getActiveInstalledBinaryURL targets automnt executable")

    isTTYOverride = false
    check(!isInteractiveTerminal(), "isInteractiveTerminal respects isTTYOverride = false")
    isTTYOverride = true
    check(isInteractiveTerminal(), "isInteractiveTerminal respects isTTYOverride = true")
    isTTYOverride = nil

    // 13. InstallationManager & InstallState
    let downloadBin = tempDir.appendingPathComponent("downloads/automnt")
    try? FileManager.default.createDirectory(at: downloadBin.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data("binary bytes".utf8).write(to: downloadBin)
    check(FileManager.default.fileExists(atPath: downloadBin.path), "Download copy exists before relocation")

    let mockTargetBin = tempDir.appendingPathComponent("canonical/bin/automnt")
    try? FileManager.default.createDirectory(at: mockTargetBin.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.copyItem(at: downloadBin, to: mockTargetBin)
    _ = Darwin.unlink(downloadBin.path)
    check(!FileManager.default.fileExists(atPath: downloadBin.path), "Original download copy is unlinked after relocation")
    check(FileManager.default.fileExists(atPath: mockTargetBin.path), "Target binary exists at canonical path")

    let healthyState = InstallState(
        currentExecutablePath: "/canonical/bin/automnt",
        installedBinaryPath: "/canonical/bin/automnt",
        activeConfigPath: "/canonical/automnt.plist",
        launchAgentPlistPath: "/LaunchAgents/com.user.automnt.plist",
        detectedShellProfile: "/Users/test/.zshrc",
        isRelocated: true,
        isCliEntryPresent: true,
        isServiceRegistered: true,
        isServicePlistValid: true
    )
    check(healthyState.isHealthy, "InstallState reports healthy when all components intact")

    var unhealthyState = healthyState
    unhealthyState.isServicePlistValid = false
    check(!unhealthyState.isHealthy, "InstallState detects unhealthy state when service plist is invalid")

    // 14. Feature 002 Foundational tests (T003 - T008)
    // Mount point derivation (T005)
    check(deriveStandardMountPoint(from: "smb://192.168.1.100/Public") == "/Volumes/Public",
          "deriveStandardMountPoint extracts clean /Volumes/Public")
    check(deriveStandardMountPoint(from: "smb://192.168.1.100/data-1") == "/Volumes/data-1",
          "deriveStandardMountPoint strictly preserves legal data-1 share name")
    check(deriveStandardMountPoint(from: "//user@192.168.1.100/Work") == "/Volumes/Work",
          "deriveStandardMountPoint strips credentials and normalizes to /Volumes/Work")
    check(deriveStandardMountPoint(from: "smb://server.local/My%20Data") == "/Volumes/My Data",
          "deriveStandardMountPoint decodes percent-encoded share name")

    // Zero-host config inspection (T004)
    let zeroHostConfig = AutomntConfig(version: automntVersion, hosts: [])
    let zeroHostURL = tempDir.appendingPathComponent("zero_host.plist")
    if let data = try? PropertyListEncoder().encode(zeroHostConfig) {
        try? data.write(to: zeroHostURL)
        check(inspectConfigFile(at: zeroHostURL).state == .usable,
              "inspectConfigFile treats zero-host config as usable rather than invalid")
    }

    // HostConfig & SMBShareConfig serialization (T003)
    let testShare = SMBShareConfig(name: "Data", smbURL: "smb://10.0.0.1/Data", mountPoint: "/Volumes/Data")
    let testHost = HostConfig(host: "10.0.0.1", alias: "My NAS", port: 445, timeoutMs: 1200, shares: [testShare])
    let multiHostConfig = AutomntConfig(version: automntVersion, hosts: [testHost])
    let multiHostURL = tempDir.appendingPathComponent("multi_host.plist")
    if let data = try? PropertyListEncoder().encode(multiHostConfig) {
        try? data.write(to: multiHostURL)
        let loaded = inspectConfigFile(at: multiHostURL).config
        check(loaded?.hosts.first?.alias == "My NAS", "HostConfig alias is preserved across plist encode/decode")
        check(loaded?.hosts.first?.port == 445 && loaded?.hosts.first?.timeoutMs == 1200, "HostConfig port and timeoutMs preserved across encode/decode")
    }

    // promptLineWithEsc non-TTY fallback & simulation (T006)
    mockLineInput = ""
    check(promptLineWithEsc(prompt: "", defaultValue: "default_fallback") == "default_fallback",
          "promptLineWithEsc returns defaultValue when input is empty")
    mockLineInput = "  Custom NAS  "
    check(promptLineWithEsc(prompt: "", defaultValue: "default_fallback") == "Custom NAS",
          "promptLineWithEsc trims and returns valid user input")
    mockLineInput = "\u{1B}"
    check(promptLineWithEsc(prompt: "") == nil,
          "promptLineWithEsc returns nil on Esc cancel")
    mockLineInput = nil

    // 15. User Story 1 Tests (T009 - T013)
    let mockMount1 = DiscoveredMount(
        mountPoint: "/Volumes/Public-1",
        rawSmbUrl: "smb://192.168.1.100/Public",
        host: "192.168.1.100",
        shareName: "Public",
        cleanMountPoint: "/Volumes/Public",
        standardSMBURL: "smb://192.168.1.100/Public"
    )
    let mockMount2 = DiscoveredMount(
        mountPoint: "/Volumes/data-1",
        rawSmbUrl: "smb://192.168.1.100/data-1",
        host: "192.168.1.100",
        shareName: "data-1",
        cleanMountPoint: "/Volumes/data-1",
        standardSMBURL: "smb://192.168.1.100/data-1"
    )
    let mockGroup = DiscoveredHostGroup(host: "192.168.1.100", mounts: [mockMount1, mockMount2], isConfigured: false)

    // Test drill-down configuration via handleCandidateHostConfiguration
    // Inputs: alias ("家庭 NAS"), selection ("all"), confirm ("Y")
    mockLineInputs = ["家庭 NAS", "all", "Y"]
    let drilledHost = handleCandidateHostConfiguration(candidate: mockGroup)
    check(drilledHost != nil, "handleCandidateHostConfiguration succeeds with valid inputs")
    check(drilledHost?.alias == "家庭 NAS", "HostConfig alias is recorded properly")
    check(drilledHost?.shares.count == 2, "Both candidate mounts selected")
    check(drilledHost?.shares[0].mountPoint == "/Volumes/Public", "Derived mount point is /Volumes/Public without -1 suffix")
    check(drilledHost?.shares[1].mountPoint == "/Volumes/data-1", "Legal data-1 mount point strictly preserved")

    // Test skip host branch in runInitWizard
    // Inputs: "s" (skip hosts), "1" (update channel off), "n" (skip daemon)
    let initWizardURL = tempDir.appendingPathComponent("init_wizard_skip.plist")
    configURLOverride = initWizardURL
    mockCandidateHosts = [mockGroup]
    mockLineInputs = ["s", "1", "n"]
    let initSuccess = runInitWizard(offerServiceInstallation: true)
    check(initSuccess, "runInitWizard completes successfully when skipping hosts")
    let skippedConfig = inspectConfigFile(at: initWizardURL).config
    check(skippedConfig?.hosts.isEmpty == true, "Skipped wizard produces a valid 0-host configuration")
    check(skippedConfig?.updateChannel == "off", "Update channel defaults to off")
    configURLOverride = nil
    mockCandidateHosts = nil
    mockLineInputs = nil

    // 16. User Story 2 Tests (T014, T015)
    check(deriveStandardMountPoint(from: "smb://fileserver/Public-1") == "/Volumes/Public-1", "SMB URL with literal Public-1 is treated as standard /Volumes/Public-1")
    check(deriveStandardMountPoint(from: "smb://fileserver/Backup-2") == "/Volumes/Backup-2", "SMB URL with literal Backup-2 is treated as standard /Volumes/Backup-2")
    check(deriveStandardMountPoint(from: "smb://host/Shared%20Folder") == "/Volumes/Shared Folder", "Spaces in URL decoded cleanly")

    // 17. User Story 3 Tests (T016 - T019)
    var testHostMgmt = HostConfig(host: "192.168.1.100", alias: "Home NAS", shares: [
        SMBShareConfig(name: "Public", smbURL: "smb://192.168.1.100/Public", mountPoint: "/Volumes/Public")
    ])
    // Test share removal in manageHostShares: 'd', '1', 'b'
    mockLineInputs = ["d", "1", "b"]
    manageHostShares(hostConfig: &testHostMgmt, allHosts: [testHostMgmt])
    check(testHostMgmt.shares.isEmpty, "manageHostShares successfully removes selected share")

    // Test duplicate share detection and prevention
    testHostMgmt.shares = [SMBShareConfig(name: "Public", smbURL: "smb://192.168.1.100/Public", mountPoint: "/Volumes/Public")]
    mockLineInputs = ["a", "2", "smb://192.168.1.100/Public", "b"]
    manageHostShares(hostConfig: &testHostMgmt, allHosts: [testHostMgmt])
    check(testHostMgmt.shares.count == 1, "Duplicate share is ignored by manageHostShares")
    mockLineInputs = nil

    // 18. User Story 4 Tests (T020 - T022)
    mockLineInputs = ["\u{1B}"]
    check(promptLineWithEsc(prompt: "Test: ") == nil, "promptLineWithEsc via mockLineInputs returns nil on Esc key")
    mockLineInputs = ["   sequence test   "]
    check(promptLineWithEsc(prompt: "Test: ") == "sequence test", "promptLineWithEsc via mockLineInputs trims surrounding whitespace")
    mockLineInputs = [""]
    check(promptLineWithEsc(prompt: "Test: ", defaultValue: "seq_fallback") == "seq_fallback", "promptLineWithEsc via mockLineInputs returns fallback on empty input")
    mockLineInputs = nil

    // 19. User Story 5 Tests (T023, T024)
    let emptyHostsConfig = AutomntConfig(version: automntVersion, updateChannel: "off", hosts: [], profiles: [])
    let emptyHostsURL = tempDir.appendingPathComponent("empty_hosts.plist")
    check(saveConfig(emptyHostsConfig, to: emptyHostsURL), "0-host config saved successfully")
    let emptyInspection = inspectConfigFile(at: emptyHostsURL)
    check(emptyInspection.state == .usable, "0-host config inspected as .usable")
    check(emptyInspection.config?.hosts.isEmpty == true, "Loaded config has 0 hosts")

    // 20. User Story 6 Tests (T025, T026)
    let legacyProfile = NetworkProfile(
        id: "office_lan",
        description: "Office Direct",
        host: "office.local",
        port: 445,
        timeoutMs: 1500,
        preventSpotlightIndex: true,
        targets: [
            MountTarget(url: "smb://office.local/Finance", mountPath: "/Volumes/Finance-1")
        ]
    )
    var legacyConfig = AutomntConfig(
        version: "3.0.0",
        updateChannel: "off",
        retryPolicy: RetryPolicy(),
        hosts: [],
        profiles: [legacyProfile]
    )
    let legacyMigrationURL = tempDir.appendingPathComponent("legacy_v300_migration.plist")
    check(saveConfig(legacyConfig, to: legacyMigrationURL), "Legacy config written to file")
    check(configNeedsMigration(legacyConfig), "Legacy config with profiles requires migration")
    check(migrateConfigIfNeeded(config: &legacyConfig, at: legacyMigrationURL), "migrateConfigIfNeeded succeeds")
    check(legacyConfig.version == automntVersion, "Migrated config version is updated to current")
    check(legacyConfig.hosts.count == 1, "Profiles converted to hosts")
    check(legacyConfig.hosts[0].host == "office.local", "Host address preserved")
    check(legacyConfig.hosts[0].alias == "Office Direct", "Description mapped to alias")
    check(legacyConfig.hosts[0].shares.count == 1, "Shares preserved")
    check(legacyConfig.hosts[0].shares[0].mountPoint == "/Volumes/Finance", "Historical -1 suffix cleaned to /Volumes/Finance")
    check(legacyConfig.profiles.isEmpty, "Legacy profiles array emptied after migration")

    // 21. Phase 10 Convergence Boundary Tests (T030 - T032)
    // T030: Esc on deploy prompt skips LaunchAgent deployment safely
    let wizardEscURL = tempDir.appendingPathComponent("init_wizard_esc.plist")
    configURLOverride = wizardEscURL
    mockCandidateHosts = [mockGroup]
    mockLineInputs = ["s", "1", "\u{1B}"] // Skip hosts, channel off, Esc on deployment
    let escDeploySuccess = runInitWizard(offerServiceInstallation: true)
    check(escDeploySuccess, "runInitWizard completes successfully when Esc pressed on deploy prompt")
    configURLOverride = nil
    mockCandidateHosts = nil
    mockLineInputs = nil

    print("\nSelf-tests: \(passed) passed, \(skipped) skipped, \(failed) failed")
    return failed == 0
}

func printUsage() {
    print(tr("""
    用法: automnt [选项]

    选项:
      --init [--reset]            运行交互式初始化配置向导 (--reset 重置现有配置)
      --config                    运行日常配置管理菜单 (管理挂载目标、网络策略、更新信道)
      --install                   部署并激活当前用户的 LaunchAgent 自启动服务
      --uninstall [--purge]       卸载自启动服务与 CLI (--purge 连同配置文件与日志彻底清理)
      --status                    查看当前安装状态、守护服务运行状态与挂载详情
      --update                    检查并升级软件至最新版本 (免编译下载预编译二进制)
      --self-test                 运行内置全量自动化自测试套件
      --version, -v               查看当前软件版本号
      --help, -h                  显示帮助说明

    环境变量:
      AUTOMNT_LANG=zh|en          显式指定终端界面语言 (默认自适应系统语言)
    """, """
    Usage: automnt [options]

    Options:
      --init [--reset]            Run setup wizard (--reset rebuilds existing config)
      --config                    Daily configuration menu (shares, profiles, updates)
      --install                   Deploy and activate user LaunchAgent daemon
      --uninstall [--purge]       Uninstall daemon and CLI entry (--purge deletes config and logs)
      --status                    Show service status and active mount details
      --update                    Check and self-update to latest prebuilt release
      --self-test                 Run full automated test suite
      --version, -v               Show software version
      --help, -h                  Show this help message

    Environment Variables:
      AUTOMNT_LANG=zh|en          Explicitly set terminal UI language
    """))
}

// MARK: - 主流程执行逻辑 (Main Entry Point)

func main() {
    let args = CommandLine.arguments

    if args.contains("--self-test") {
        let success = runSelfTests(includeNetworkChecks: args.contains("--network"))
        exit(success ? 0 : 1)
    }

    if args.count > 1 {
        let first = args[1]
        if first == "--version" || first == "-v" {
            print(automntVersion)
            exit(0)
        }
        if first == "--help" || first == "-h" {
            printUsage()
            exit(0)
        }
    }

    let architectureResult = runCommand(executable: "/usr/bin/uname", arguments: ["-m"])
    let architecture = architectureResult.status == 0 ? architectureResult.stdout : "unknown"
    let platformIssue = platformSupportIssue(
        macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
        architecture: architecture
    )
    if let platformIssue {
        if platformIssue == "architecture" {
            fputs(tr("✗ automnt 仅支持 Apple silicon (arm64)；当前架构：\(architecture)。\n",
                     "✗ automnt supports Apple silicon (arm64) only; current architecture: \(architecture).\n"), stderr)
        } else {
            fputs(tr("✗ automnt 需要 macOS 27.0 或更高版本；当前系统：\(ProcessInfo.processInfo.operatingSystemVersionString)。\n",
                     "✗ automnt requires macOS 27.0 or later; current system: \(ProcessInfo.processInfo.operatingSystemVersionString).\n"), stderr)
        }
        exit(1)
    }

    // 自搬迁安装与首次运行引导 (US1)
    let justRelocated = InstallationManager.relocateIfNeeded()
    if justRelocated {
        InstallationManager.injectShellEntry()
        print(tr("✓ 成功安装 automnt 到规范目录: \(getActiveInstalledBinaryURL().path)",
                 "✓ Successfully installed automnt to canonical path: \(getActiveInstalledBinaryURL().path)"))
        print(tr("✓ 原下载临时副本已安全清理", "✓ Cleaned up temporary download copy"))
        print(tr("✓ 已配置命令行入口，可在新终端窗口直接运行: automnt",
                 "✓ Configured CLI entry point; run directly in new terminal: automnt"))
    } else {
        // 自检与自愈 (US8)
        let state = InstallState.current()
        if state.isRelocated && !state.isHealthy {
            _ = state.healIfNeeded()
            let afterState = InstallState.current()
            if !afterState.isHealthy {
                fputs(tr("⚠ 警告: 当前安装状态不完整。\n若需完全恢复，建议运行: automnt --install\n",
                         "⚠ Warning: Installation state degraded.\nRecommended repair command: automnt --install\n"), stderr)
            }
        }
    }

    if args.count > 1 {
        let arg = args[1]
        switch arg {
        case "--init":
            guard args.count == 2 || (args.count == 3 && args[2] == "--reset") else {
                fputs(tr("✗ 用法: automnt --init [--reset]\n", "✗ Usage: automnt --init [--reset]\n"), stderr)
                exit(2)
            }
            let succeeded = runInitCommand(resetExistingConfig: args.count == 3)
            exit(succeeded ? 0 : 1)
        case "--config":
            manageConfiguration()
            exit(0)
        case "--install":
            installLaunchAgent()
            exit(0)
        case "--uninstall":
            let purge = args.contains("--purge")
            uninstallLaunchAgent(purge: purge)
            exit(0)
        case "--status":
            checkServiceStatus()
            exit(0)
        case "--update":
            handleManualUpdateCommand()
            exit(0)
        default:
            fputs(tr("✗ 未知参数: '\(arg)'\n\n", "✗ Unknown option: '\(arg)'\n\n"), stderr)
            printUsage()
            exit(1)
        }
    }

    print(tr("""
    automnt (v\(automntVersion))
    ======================
    """, """
    automnt (v\(automntVersion))
    ======================
    """))

    let inspection = inspectConfigFile(at: getActiveConfigURL())
    if inspection.state == .missing {
        if isInteractiveTerminal() {
            print(tr("未检测到有效配置文件，正在自动启动初始化配置向导...\n",
                     "No valid configuration found. Starting setup wizard...\n"))
            let initSucceeded = runInitCommand()
            if !initSucceeded {
                writeLog("Init wizard canceled or failed, exiting with status 1")
                exit(1)
            }
        } else {
            fputs(tr("✗ 未找到有效配置，请在终端中运行 'automnt --init' 初始化。\n",
                     "✗ Configuration not found. Please run 'automnt --init' first.\n"), stderr)
            writeLog("Config missing, exiting with status 2")
            exit(2)
        }
    } else if inspection.state == .invalid {
        fputs(tr("✗ 配置文件损坏或无法解析，请检查配置或运行 'automnt --init' 重新生成。\n",
                 "✗ Configuration is corrupted or invalid. Please check configuration or run 'automnt --init'.\n"), stderr)
        writeLog("Config invalid: \(inspection.diagnostic ?? "unknown error"), exiting with status 2")
        exit(2)
    }

    guard var config = loadConfig() else {
        fputs(tr("✗ 无法读取配置文件，退出。\n", "✗ Unable to read config, exiting.\n"), stderr)
        writeLog("Unable to load config, exiting with status 2")
        exit(2)
    }

    // 检查 0 台主机合法空配置状态 (Safe Dormant Sleep)
    if config.hosts.isEmpty {
        let sleepMsgZh = "当前未配置任何主机，automnt 保持安全休眠状态。"
        let sleepMsgEn = "No hosts configured. automnt remains in safe dormant sleep state."
        print(tr(sleepMsgZh, sleepMsgEn))
        writeLog("No hosts configured; safe dormant sleep state entered, exiting with status 0")
        exit(0)
    }

    // 顺序评估主机顺位探测 (Host-based Priority Probing)
    print(tr("\n[1] 顺序评估主机顺位探测...", "\n[1] Evaluating host priority probing..."))
    var matchedHost: HostConfig?

    for (idx, hostConfig) in config.hosts.enumerated() {
        guard hostConfig.enabled else {
            print(tr("  跳过已禁用的主机 [\(idx + 1)] '\(hostConfig.host)'",
                     "  Skipping disabled host [\(idx + 1)] '\(hostConfig.host)'"))
            continue
        }
        let hostDisplay = hostConfig.alias.map { "'\($0)' (\(hostConfig.host))" } ?? "'\(hostConfig.host)'"
        print(tr("  正在校验顺位 [\(idx + 1)] \(hostDisplay):",
                 "  Checking priority [\(idx + 1)] \(hostDisplay):"))

        let host = hostConfig.host
        let port = hostConfig.port
        let timeout = hostConfig.timeoutMs
        let retryRunner = EvaluationRetryRunner(policy: config.retryPolicy ?? RetryPolicy())

        print(tr("    正在探测 TCP 端口 \(port): \(host) (超时: \(timeout)ms)...",
                 "    Probing TCP port \(port) on \(host) (timeout: \(timeout)ms)..."))

        let reachable = retryRunner.run {
            HostReachabilityProbe.canConnect(host: host, port: port, timeoutMs: timeout)
        }

        if reachable {
            print(tr("    ✓ 顺位命中！(目标 \(host):\(port) 可达)",
                     "    ✓ Matched! (Host \(host):\(port) is reachable)"))
            matchedHost = hostConfig
            break // 强排他性短路：首个通畅则立即停止后续探测
        } else {
            print(tr("    ✗ 目标 \(host):\(port) 不可达，评估下一顺位。",
                     "    ✗ Target \(host):\(port) unreachable, falling back to next host."))
        }
    }

    guard let host = matchedHost else {
        print(tr("\n[DONE] 当前网络状态未匹配到任何可用主机。正常退出。",
                 "\n[DONE] No matching host reachable for current network state. Exiting cleanly."))
        writeLog("No matching host reachable for current network, exiting with status 2")
        triggerBackgroundUpdateCheckIfNeeded(config: &config)
        exit(2)
    }

    let hostTitle = host.alias.map { "\($0) (\(host.host))" } ?? host.host
    print(tr("\n[2] 执行挂载命中主机: \(hostTitle)", "\n[2] Executing mounts for active host: \(hostTitle)"))
    writeLog("Executing mounts for host: \(host.host)")

    var mountedCount = 0
    var failedCount = 0
    for share in host.shares {
        guard share.enabled else {
            print(tr("  跳过已禁用共享: \(share.mountPoint)", "  Skipping disabled share: \(share.mountPoint)"))
            continue
        }
        print(tr("  目标: \(share.mountPoint) (\(redactedSMBURL(share.smbURL)))",
                 "  Target: \(share.mountPoint) (\(redactedSMBURL(share.smbURL)))"))

        let status = ensureMountPointReady(target: MountTarget(url: share.smbURL, mountPath: share.mountPoint))
        switch status {
        case .alreadyMountedHealthy:
            print(tr("    ✓ 卷宗已挂载且响应正常，跳过。", "    ✓ Already mounted and responsive, skipping."))
            mountedCount += 1
            continue

        case .readyToMount:
            print(tr("    正在通过 NetFS 系统框架静默挂载...", "    Mounting volume via NetFS..."))
            if silentMount(urlString: share.smbURL, mountPath: share.mountPoint) {
                mountedCount += 1
                if host.preventSpotlightIndex {
                    disableSpotlightIndex(at: share.mountPoint)
                }
            } else {
                failedCount += 1
                fputs(tr("    ✗ 挂载失败，请检查网络连通性或钥匙串凭据。\n",
                         "    ✗ Mount failed. Check network or Keychain credentials.\n"), stderr)
            }

        case .unmountFailed:
            print(tr("    ✗ 挂载点繁忙或无法清除，跳过此目标。", "    ✗ Mount point busy or cannot be cleared, skipping."))
            failedCount += 1
        }
    }

    print(tr("\n[DONE] 主机 '\(hostTitle)' 下已成功挂载 \(mountedCount)/\(host.shares.count) 个卷宗。",
             "\n[DONE] \(mountedCount)/\(host.shares.count) volumes mounted under '\(hostTitle)'."))
    writeLog("Finished execution of '\(host.host)': \(mountedCount)/\(host.shares.count) mounted.")
    triggerBackgroundUpdateCheckIfNeeded(config: &config)
    if failedCount > 0 {
        writeLog("Mount evaluation failed for \(failedCount) configured target(s).")
        exit(2)
    }
}

main()
