#!/usr/bin/env swift
// auto_mount.swift
// 自动挂载 NAS 工具 (macOS 多网络策略路由与交互版)
//
// 核心架构与特性：
// 1. 多策略优先级路由 (Profiles)：本地局域网 (local_lan) 优先直连；离开局域网自动降级至远程互联 (remote_network / Tailscale / WireGuard / 域名 / IP)。
// 2. 失效 SMB 挂载与源切换的超时清理：
//    - Darwin 原生 MNT_NOWAIT 内核挂载表非阻塞查询，杜绝 stat() 阻塞与系统彩虹球假死。
//    - 自动比对挂载源同源性，使用有界时限的 diskutil 与 umount -f 子进程清理。
// 3. 远程 SMB 服务就绪重试：
//    - 通过 TCP 445 探测 SMB 服务，并提供轻量重试窗口（默认 3 次，间隔 1.0 秒）。
// 4. Spotlight 索引防护与网关排除：
//    - 挂载后请求关闭 mdutil 索引并尝试写入 .metadata_never_index，同时记录操作结果。
//    - 策略可显式排除用户提供的物理网关地址。
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

var configURLOverride: URL?

func getWorkspaceConfigURL() -> URL {
    return getAppDir().appendingPathComponent("auto_mount.plist")
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
    return configURLOverride ?? getWorkspaceConfigURL()
}

// 执行外部命令辅助函数
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

        // Drain both pipes concurrently. Reading one to EOF before the other can
        // deadlock when a child fills the unread pipe (for example, swiftc errors).
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

let autoMountVersion = "2.7.3"
let minimumSupportedMacOSMajorVersion = 27
let minimumSupportedMacOSVersion = "\(minimumSupportedMacOSMajorVersion).0"
let githubRepo = "jiezhengj/AutoMount"

func normalizedArchitecture(_ architecture: String) -> String {
    architecture.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

func swiftCompilerTargetTriple(architecture: String) -> String? {
    guard normalizedArchitecture(architecture) == "arm64" else { return nil }
    return "arm64-apple-macosx\(minimumSupportedMacOSVersion)"
}

func platformSupportIssue(macOSMajorVersion: Int, architecture: String) -> String? {
    guard normalizedArchitecture(architecture) == "arm64" else { return "architecture" }
    guard macOSMajorVersion >= minimumSupportedMacOSMajorVersion else { return "macOS_version" }
    return nil
}

func macOSSDKMajorVersion(_ version: String) -> Int? {
    Int(version.split(separator: ".").first ?? "")
}

func currentMacOSSDKPath() -> String? {
    let sdk = runCommand(executable: "/usr/bin/xcrun", arguments: ["--sdk", "macosx", "--show-sdk-path"])
    let version = runCommand(executable: "/usr/bin/xcrun", arguments: ["--sdk", "macosx", "--show-sdk-version"])
    guard sdk.status == 0,
          version.status == 0,
          let majorVersion = macOSSDKMajorVersion(version.stdout.trimmingCharacters(in: .whitespacesAndNewlines)),
          majorVersion >= minimumSupportedMacOSMajorVersion else { return nil }
    let path = sdk.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    return FileManager.default.fileExists(atPath: path) ? path : nil
}

func compileOptimizedSwiftSource(sourceURL: URL, outputURL: URL) -> (status: Int32, stdout: String, stderr: String) {
    let architectureResult = runCommand(executable: "/usr/bin/uname", arguments: ["-m"])
    guard architectureResult.status == 0,
          let target = swiftCompilerTargetTriple(architecture: architectureResult.stdout) else {
        return (-1, "", "Could not determine a supported macOS CPU architecture.")
    }
    guard let sdkPath = currentMacOSSDKPath() else {
        return (-1, "", "AutoMount requires the macOS 27 SDK or later from Xcode or Command Line Tools.")
    }
    return runCommand(
        executable: "/usr/bin/swiftc",
        arguments: ["-O", "-sdk", sdkPath, "-target", target, sourceURL.path, "-o", outputURL.path]
    )
}

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
    var lastUpdateCheckTimestamp: Double?     // 更新检查最近一次尝试时间戳
    var updateRetryAfterTimestamp: Double? = nil
    var lastNotifiedVersion: String?          // 单版本仅提醒 1 次防打扰
    var profiles: [NetworkProfile]

    enum CodingKeys: String, CodingKey {
        case version
        case updateChannel = "update_channel"
        case lastUpdateCheckTimestamp = "last_update_check_timestamp"
        case updateRetryAfterTimestamp = "update_retry_after_timestamp"
        case lastNotifiedVersion = "last_notified_version"
        case profiles
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
    let config: AutoMountConfig?
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

    guard var config = try? PropertyListDecoder().decode(AutoMountConfig.self, from: data),
          !config.profiles.isEmpty,
          !parseSemanticVersion(config.version).isEmpty else {
        return ConfigFileInspection(url: url, state: .invalid, config: nil, contents: data,
                                    diagnostic: "Configuration is malformed or has no profiles")
    }
    guard !isNewerVersion(config.version, than: autoMountVersion) else {
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

func replaceConfigFile(
    with source: ConfigFileInspection,
    at destinationURL: URL,
    destination: ConfigFileInspection
) throws -> URL? {
    guard source.state == .usable, let sourceContents = source.contents else {
        throw NSError(domain: "AutoMountConfig", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "The selected source config is not usable"])
    }
    guard destination.state != .inaccessible else {
        throw NSError(domain: "AutoMountConfig", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: destination.diagnostic ?? "The destination config cannot be safely backed up"])
    }

    let latestSource = inspectConfigFile(at: source.url)
    guard latestSource.state == .usable,
          let latestSourceContents = latestSource.contents,
          latestSourceContents == sourceContents,
          configInspectionMatches(source, latestSource) else {
        throw NSError(domain: "AutoMountConfig", code: 5,
                      userInfo: [NSLocalizedDescriptionKey: "The selected source config changed during recovery; review the latest config and retry"])
    }
    let latestDestination = inspectConfigFile(at: destinationURL)
    guard configInspectionMatches(destination, latestDestination) else {
        throw NSError(domain: "AutoMountConfig", code: 6,
                      userInfo: [NSLocalizedDescriptionKey: "The destination config changed during recovery; review the latest config and retry"])
    }

    let backupURL = try backUpConfigFile(latestDestination)
    do {
        try atomicWrite(latestSourceContents, to: destinationURL, permissions: 0o600)
        let replaced = inspectConfigFile(at: destinationURL)
        guard replaced.state == .usable, replaced.contents == latestSourceContents else {
            throw NSError(domain: "AutoMountConfig", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "The replacement config did not pass read-back validation"])
        }
        return backupURL
    } catch {
        do {
            if let originalContents = latestDestination.contents {
                try atomicWrite(originalContents, to: destinationURL, permissions: 0o600)
            } else if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
        } catch {
            throw NSError(domain: "AutoMountConfig", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Config replacement failed: \(error.localizedDescription). Restoring the previous destination also failed."])
        }
        throw error
    }
}

// MARK: - 配置文件原地迁移 (In-Place Schema Migration)

func configVersionCanBeMigrated(_ configVersion: String) -> Bool {
    !isNewerVersion(configVersion, than: autoMountVersion)
}

func configNeedsMigration(_ config: AutoMountConfig) -> Bool {
    if config.version != autoMountVersion { return true }
    if config.updateChannel == nil { return true }
    for profile in config.profiles {
        if profile.id == "home_lan" || profile.id == "tailscale_remote" {
            return true
        }
        if let desc = profile.description {
            if desc.contains("家庭局域网") || desc.contains("Home LAN") ||
               desc.contains("Tailscale 异地互联") || desc.contains("Tailscale Remote") {
                return true
            }
        }
    }
    return false
}

func migrateConfigIfNeeded(config: inout AutoMountConfig, at configURL: URL) -> Bool {
    guard configVersionCanBeMigrated(config.version) else {
        fputs(tr("✗ 配置版本 v\(config.version) 高于当前程序 v\(autoMountVersion)，为避免降级破坏配置，已停止运行。\n",
                 "✗ Config version v\(config.version) is newer than program v\(autoMountVersion); refusing to downgrade the config.\n"), stderr)
        writeLog("Refused to migrate newer config version \(config.version) with program \(autoMountVersion)")
        return false
    }

    guard configNeedsMigration(config) else { return true }

    var modified = false
    if config.version != autoMountVersion {
        config.version = autoMountVersion
        modified = true
    }
    if config.updateChannel == nil {
        config.updateChannel = "off"
        modified = true
    }
    for i in 0..<config.profiles.count {
        if config.profiles[i].id == "home_lan" {
            config.profiles[i].id = "local_lan"
            modified = true
        }
        if let desc = config.profiles[i].description, (desc.contains("家庭局域网") || desc.contains("Home LAN")) {
            config.profiles[i].description = tr("本地局域网高速直连", "Local LAN High-Speed Direct Connection")
            modified = true
        }
        if config.profiles[i].id == "tailscale_remote" {
            config.profiles[i].id = "remote_network"
            modified = true
        }
        if let desc = config.profiles[i].description, (desc.contains("Tailscale 异地互联") || desc.contains("Tailscale Remote")) {
            let updated = desc.replacingOccurrences(of: "Tailscale 异地互联", with: "远程互联")
                              .replacingOccurrences(of: "Tailscale Remote", with: "Remote Network")
            config.profiles[i].description = updated
            modified = true
        }
    }
    guard modified else { return true }
    guard saveConfig(config, to: configURL, syncInstalled: false) else {
        fputs(tr("✗ 配置已迁移到内存，但未能完整写入配置文件。\n",
                 "✗ Configuration was migrated in memory, but could not be fully saved.\n"), stderr)
        writeLog("Configuration migration to v\(autoMountVersion) could not be persisted")
        return false
    }
    print(tr("✓ 配置文件已自动平滑升级至 v\(autoMountVersion) 格式规范",
             "✓ Configuration automatically upgraded to v\(autoMountVersion) schema"))
    writeLog("Configuration auto-migrated to v\(autoMountVersion)")
    return true
}

enum ConfigMigrationStartupResult: Equatable {
    case migrated
    case unchanged
    case skippedMissing
    case skippedInaccessible(String?)
    case skippedMalformed(String?)
    case skippedFutureVersion(String)
    case migrationFailed
}

func discoverVisibleConfigURLs(
    appDirectory: URL = getAppDir(),
    installedDirectory: URL = getInstalledDir(),
    overrideURL: URL? = configURLOverride
) -> [URL] {
    var candidateURLs: [URL] = []
    if let overrideURL {
        candidateURLs.append(overrideURL)
    }

    let standardizedAppDir = appDirectory.standardizedFileURL.path
    let standardizedInstalledDir = installedDirectory.standardizedFileURL.path

    if standardizedAppDir == standardizedInstalledDir {
        candidateURLs.append(installedDirectory.appendingPathComponent("auto_mount.plist"))
    } else {
        candidateURLs.append(appDirectory.appendingPathComponent("auto_mount.plist"))
        candidateURLs.append(installedDirectory.appendingPathComponent("auto_mount.plist"))
    }

    var seenPaths = Set<String>()
    var uniqueURLs: [URL] = []
    for url in candidateURLs {
        let path = url.standardizedFileURL.path
        if !seenPaths.contains(path) {
            seenPaths.insert(path)
            uniqueURLs.append(url)
        }
    }
    return uniqueURLs
}

@discardableResult
func eagerMigrateVisibleConfigs(
    candidateURLs: [URL] = discoverVisibleConfigURLs()
) -> [URL: ConfigMigrationStartupResult] {
    var results: [URL: ConfigMigrationStartupResult] = [:]

    for url in candidateURLs {
        let inspection = inspectConfigFile(at: url)
        switch inspection.state {
        case .missing:
            results[url] = .skippedMissing

        case .inaccessible:
            let reason = inspection.diagnostic ?? "access denied"
            writeLog("Startup config migration skipped inaccessible file at \(url.path): \(reason)")
            results[url] = .skippedInaccessible(inspection.diagnostic)

        case .invalid:
            let reason = inspection.diagnostic ?? "malformed content"
            writeLog("Startup config migration skipped malformed file at \(url.path): \(reason)")
            results[url] = .skippedMalformed(inspection.diagnostic)

        case .futureVersion(let version):
            writeLog("Startup config migration skipped future version v\(version) at \(url.path)")
            results[url] = .skippedFutureVersion(version)

        case .usable:
            guard var config = inspection.config else {
                results[url] = .skippedMalformed("Missing config object")
                continue
            }
            guard configNeedsMigration(config) else {
                results[url] = .unchanged
                continue
            }
            let success = migrateConfigIfNeeded(config: &config, at: url)
            if success {
                results[url] = .migrated
            } else {
                writeLog("Startup config migration failed for \(url.path)")
                results[url] = .migrationFailed
            }
        }
    }

    return results
}

// 加载配置并执行已定义的迁移
func loadConfig(from configURL: URL? = nil, migrate: Bool = true) -> AutoMountConfig? {
    let resolvedURL = configURL ?? getConfigURL()
    guard let data = try? Data(contentsOf: resolvedURL) else { return nil }
    let decoder = PropertyListDecoder()
    guard var config = try? decoder.decode(AutoMountConfig.self, from: data) else { return nil }
    if migrate {
        guard migrateConfigIfNeeded(config: &config, at: resolvedURL) else { return nil }
    }
    return config
}

func atomicWrite(_ data: Data, to url: URL, permissions: Int? = nil) throws {
    let parentURL = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
    let temporaryURL = parentURL.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    let requestedPermissions = permissions ?? 0o600

    guard FileManager.default.createFile(
        atPath: temporaryURL.path,
        contents: nil,
        attributes: [.posixPermissions: requestedPermissions]
    ) else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Could not create temporary file for \(url.lastPathComponent)"])
    }
    defer { try? FileManager.default.removeItem(at: temporaryURL) }

    try FileManager.default.setAttributes([.posixPermissions: requestedPermissions], ofItemAtPath: temporaryURL.path)
    let handle = try FileHandle(forWritingTo: temporaryURL)
    try handle.write(contentsOf: data)
    try handle.synchronize()
    try handle.close()

    let renameResult = temporaryURL.path.withCString { sourcePath in
        url.path.withCString { destinationPath in
            Darwin.rename(sourcePath, destinationPath)
        }
    }
    guard renameResult == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Could not atomically replace \(url.lastPathComponent)"])
    }
}

// 自动同步配置到已部署的 LaunchAgent 运行目录。
@discardableResult
func syncConfigToInstalledDirIfNeeded(from sourceURL: URL) -> Bool {
    let plistURL = getLaunchAgentPlistURL()
    guard FileManager.default.fileExists(atPath: plistURL.path) else { return true }

    let destinationURL = getInstalledDir().appendingPathComponent("auto_mount.plist")
    guard sourceURL.standardizedFileURL.path != destinationURL.standardizedFileURL.path else { return true }
    do {
        let data = try Data(contentsOf: sourceURL)
        try atomicWrite(data, to: destinationURL, permissions: 0o600)
        print(tr("✓ 已同步最新配置至后台守护服务: \(destinationURL.path)",
                 "✓ Synchronized configuration to LaunchAgent runtime: \(destinationURL.path)"))
        writeLog("Synchronized configuration to \(destinationURL.path)")
        return true
    } catch {
        fputs(tr("✗ 配置已保存，但同步到后台守护服务失败: \(error.localizedDescription)\n",
                 "✗ Config saved, but synchronization to LaunchAgent runtime failed: \(error.localizedDescription)\n"), stderr)
        writeLog("Failed to synchronize configuration to \(destinationURL.path): \(error.localizedDescription)")
        return false
    }
}

func mergeDaemonOwnedMetadata(into config: inout AutoMountConfig, from runtimeConfig: AutoMountConfig) {
    let timestamps = [config.lastUpdateCheckTimestamp, runtimeConfig.lastUpdateCheckTimestamp]
        .compactMap { $0 }
        .filter { $0.isFinite }
    config.lastUpdateCheckTimestamp = timestamps.max()

    let retryTimestamps = [config.updateRetryAfterTimestamp, runtimeConfig.updateRetryAfterTimestamp]
        .compactMap { $0 }
        .filter { $0.isFinite }
    config.updateRetryAfterTimestamp = retryTimestamps.max()

    if let runtimeVersion = runtimeConfig.lastNotifiedVersion,
       config.lastNotifiedVersion == nil || isNewerVersion(runtimeVersion, than: config.lastNotifiedVersion ?? "") {
        config.lastNotifiedVersion = runtimeVersion
    }
}

enum ConfigPlistContext: Equatable {
    case root
    case profiles
    case profile
    case match
    case targets
    case target
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
        return ["version", "update_channel", "last_update_check_timestamp",
                "update_retry_after_timestamp", "last_notified_version", "profiles"]
    case .profile:
        return ["id", "description", "match", "exclude_gateway_ips",
                "prevent_spotlight_index", "targets"]
    case .match:
        return ["type", "value", "retry_count", "retry_interval"]
    case .target:
        return ["url", "mount_path"]
    case .profiles, .targets, .other:
        return []
    }
}

func childConfigPlistContext(parent: ConfigPlistContext, key: String) -> ConfigPlistContext {
    switch (parent, key) {
    case (.root, "profiles"): return .profiles
    case (.profile, "match"): return .match
    case (.profile, "targets"): return .targets
    default: return .other
    }
}

func configPlistIdentity(_ value: Any, context: ConfigPlistContext) -> String? {
    guard let dictionary = value as? [String: Any] else { return nil }
    switch context {
    case .profiles:
        guard let identifier = dictionary["id"] as? String else { return nil }
        return canonicalProfileID(identifier)
    case .targets:
        return dictionary["mount_path"] as? String
    default:
        return nil
    }
}

func mergeConfigPlistValue(
    original: Any,
    generated: Any,
    context: ConfigPlistContext
) -> Any {
    if let originalDictionary = original as? [String: Any],
       let generatedDictionary = generated as? [String: Any] {
        var merged = originalDictionary
        for key in managedConfigKeys(for: context) where generatedDictionary[key] == nil {
            merged.removeValue(forKey: key)
        }
        for (key, newValue) in generatedDictionary {
            let childContext = childConfigPlistContext(parent: context, key: key)
            if let oldValue = originalDictionary[key] {
                merged[key] = mergeConfigPlistValue(original: oldValue, generated: newValue, context: childContext)
            } else {
                merged[key] = newValue
            }
        }
        return merged
    }

    if let originalArray = original as? [Any], let generatedArray = generated as? [Any] {
        guard context == .profiles || context == .targets else { return generatedArray }
        var unusedOriginalIndices = Set(originalArray.indices)
        return generatedArray.map { newValue in
            let identity = configPlistIdentity(newValue, context: context)
            let matchedIndex = identity.flatMap { newIdentity in
                unusedOriginalIndices.first { configPlistIdentity(originalArray[$0], context: context) == newIdentity }
            }
            guard let matchedIndex else { return newValue }
            unusedOriginalIndices.remove(matchedIndex)
            let childContext: ConfigPlistContext = context == .profiles ? .profile : .target
            return mergeConfigPlistValue(original: originalArray[matchedIndex], generated: newValue, context: childContext)
        }
    }

    return generated
}

func encodeConfigPreservingUnknownFields(_ config: AutoMountConfig, at configURL: URL) throws -> Data {
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .xml
    let encodedData = try encoder.encode(config)
    guard FileManager.default.fileExists(atPath: configURL.path),
          let originalData = try? Data(contentsOf: configURL),
          let original = (try? PropertyListSerialization.propertyList(from: originalData, options: [], format: nil)) as? [String: Any],
          let generated = (try? PropertyListSerialization.propertyList(from: encodedData, options: [], format: nil)) as? [String: Any],
          let merged = mergeConfigPlistValue(original: original, generated: generated, context: .root) as? [String: Any] else {
        return encodedData
    }
    return try PropertyListSerialization.data(fromPropertyList: merged, format: .xml, options: 0)
}

// 保存配置并限制读取权限，避免 SMB URL 中可能含有的凭据被其他本机用户读取。
@discardableResult
func saveConfig(
    _ config: AutoMountConfig,
    to configURL: URL? = nil,
    syncInstalled: Bool = true,
    preserveUnknownFields: Bool = true,
    mergeRuntimeMetadata: Bool = true
) -> Bool {
    let resolvedURL = configURL ?? getConfigURL()
    var configToSave = config
    let runtimeConfigURL = getInstalledDir().appendingPathComponent("auto_mount.plist")
    if mergeRuntimeMetadata,
       resolvedURL.standardizedFileURL.path != runtimeConfigURL.standardizedFileURL.path,
       let runtimeConfig = loadConfig(from: runtimeConfigURL, migrate: false) {
        mergeDaemonOwnedMetadata(into: &configToSave, from: runtimeConfig)
    }
    do {
        let data: Data
        if preserveUnknownFields {
            data = try encodeConfigPreservingUnknownFields(configToSave, at: resolvedURL)
        } else {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .xml
            data = try encoder.encode(configToSave)
        }
        try atomicWrite(data, to: resolvedURL, permissions: 0o600)
        print(tr("✓ 配置已即时保存至: \(resolvedURL.path)",
                 "✓ Config saved to: \(resolvedURL.path)"))
        return syncInstalled ? syncConfigToInstalledDirIfNeeded(from: resolvedURL) : true
    } catch {
        fputs("✗ Failed to save config: \(error.localizedDescription)\n", stderr)
        writeLog("Failed to save config: \(error.localizedDescription)")
        return false
    }
}

// MARK: - 物理网关与接口作用域 ARP 探测

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

func isIPv4Address(_ value: String) -> Bool {
    var address = in_addr()
    return value.withCString { inet_pton(AF_INET, $0, &address) } == 1
}

struct GatewayInfo {
    let ip: String
    let interface: String
}

func getPhysicalGatewayInfo() -> GatewayInfo? {
    let interfaces = getPhysicalBSDInterfaces()

    // Prefer the active default route when macOS reports an Ethernet interface.
    // VPN routes can replace the default route, so retain DHCP-router lookup as a fallback.
    let route = runCommand(executable: "/sbin/route", arguments: ["-n", "get", "default"])
    if route.status == 0 {
        let gateway = route.stdout.components(separatedBy: .newlines).first {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("gateway:")
        }?.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
        let interface = route.stdout.components(separatedBy: .newlines).first {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("interface:")
        }?.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
        if let gateway, let interface, isIPv4Address(gateway), interface.hasPrefix("en") {
            return GatewayInfo(ip: gateway, interface: interface)
        }
    }

    for iface in interfaces {
        let result = runCommand(executable: "/usr/sbin/ipconfig", arguments: ["getoption", iface, "router"])
        guard result.status == 0 else { continue }
        let router = result.stdout.split(whereSeparator: \.isWhitespace).map(String.init).first(where: isIPv4Address)
        if let router {
            return GatewayInfo(ip: router, interface: iface)
        }
    }
    return nil
}

func parseARPCacheOutput(_ output: String, for ip: String, interface: String? = nil) -> String? {
    let escapedIP = NSRegularExpression.escapedPattern(for: ip)
    let pattern = #"\("# + escapedIP + #"\)\s+at\s+((?:[0-9a-fA-F]{1,2}:){5}[0-9a-fA-F]{1,2})\s+on\b"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    for line in output.components(separatedBy: .newlines) where line.contains("(\(ip))") {
        if let interface {
            let escapedInterface = NSRegularExpression.escapedPattern(for: interface)
            guard let interfaceRegex = try? NSRegularExpression(pattern: #"\bon\s+"# + escapedInterface + #"(?:\s|$)"#),
                  interfaceRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else {
                continue
            }
        }
        guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { continue }
        return String(line[range]).lowercased()
    }
    return nil
}

func queryARPCache(for ip: String, interface: String) -> String? {
    // macOS can report a miss for a destination-specific lookup even when the
    // same interface-scoped neighbor is present in its full ARP table.
    let exact = runCommand(executable: "/usr/sbin/arp", arguments: ["-n", "-i", interface, ip])
    if exact.status == 0, let mac = parseARPCacheOutput(exact.stdout, for: ip, interface: interface) {
        return mac
    }

    let interfaceTable = runCommand(executable: "/usr/sbin/arp", arguments: ["-n", "-i", interface, "-a"])
    if interfaceTable.status == 0,
       let mac = parseARPCacheOutput(interfaceTable.stdout, for: ip, interface: interface) {
        return mac
    }

    // The system may not return an entry for an interface-scoped query even
    // when its normal route lookup can see that same physical neighbor.
    let routedLookup = runCommand(executable: "/usr/sbin/arp", arguments: ["-n", ip])
    guard routedLookup.status == 0 else { return nil }
    return parseARPCacheOutput(routedLookup.stdout, for: ip, interface: interface)
}

func getMACAddress(for ip: String, interface: String? = nil) -> String? {
    guard !ip.isEmpty else { return nil }
    for attempt in 0..<4 {
        if let iface = interface, let cachedMAC = queryARPCache(for: ip, interface: iface) {
            return cachedMAC
        }
        var args = ["-c", "1", "-t", "1"]
        if let iface = interface {
            args.append(contentsOf: ["-b", iface])
        }
        args.append(ip)
        let ping = runCommand(executable: "/sbin/ping", arguments: args)
        if ping.status != 0 {
            writeLog("Gateway neighbor probe failed for \(ip) on \(interface ?? "default route") (status \(ping.status)): \(ping.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if attempt < 3 {
            Thread.sleep(forTimeInterval: 0.35)
        }
    }
    guard let interface else { return nil }
    return queryARPCache(for: ip, interface: interface)
}

func getCurrentNetworkFingerprint() -> String? {
    guard let gatewayInfo = getPhysicalGatewayInfo() else { return nil }
    return getMACAddress(for: gatewayInfo.ip, interface: gatewayInfo.interface)
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
    if clean.hasPrefix("["), let end = clean.firstIndex(of: "]") {
        clean = String(clean[clean.index(after: clean.startIndex)..<end])
    } else if clean.filter({ $0 == ":" }).count == 1, let colonIndex = clean.firstIndex(of: ":") {
        clean = String(clean[..<colonIndex])
    }
    return clean.lowercased()
}

func smbResourceIdentity(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let input = trimmed.hasPrefix("//") ? "smb:\(trimmed)" : trimmed
    guard let components = URLComponents(string: input),
          components.scheme?.lowercased() == "smb",
          let host = components.host, !host.isEmpty else { return nil }
    let sharePath = components.path
        .split(separator: "/")
        .map(String.init)
        .joined(separator: "/")
        .lowercased()
    guard !sharePath.isEmpty else { return nil }
    let normalizedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
    return "\(normalizedHost)/\(sharePath)"
}

func redactedSMBURL(_ value: String) -> String {
    if var components = URLComponents(string: value),
       components.user != nil || components.password != nil {
        components.user = nil
        components.password = nil
        if let sanitized = components.string { return sanitized }
    }

    // Invalid URLs still reach validation diagnostics. Redact authority userinfo
    // there too, and apply the same rule to non-SMB schemes.
    guard let regex = try? NSRegularExpression(
        pattern: #"^((?:[A-Za-z][A-Za-z0-9+.-]*:)?//)[^/?#@]*@"#
    ) else { return value }
    let range = NSRange(value.startIndex..., in: value)
    return regex.stringByReplacingMatches(in: value, range: range, withTemplate: "$1<redacted>@")
}

func validateMountTargetURL(_ value: String) -> String? {
    guard let components = URLComponents(string: value),
          components.scheme?.lowercased() == "smb",
          let host = components.host, !host.isEmpty,
          !components.path.split(separator: "/").isEmpty else {
        return tr("SMB 地址必须包含 smb://、服务器和共享名。", "SMB URL must include smb://, a server, and a share name.")
    }
    guard components.query == nil, components.fragment == nil else {
        return tr("SMB 地址不能包含查询参数或片段。", "SMB URL cannot contain a query or fragment.")
    }
    return nil
}

func validateMountPath(_ value: String) -> String? {
    guard value.hasPrefix("/"), value != "/" else {
        return tr("挂载路径必须是非根目录的绝对路径。", "Mount path must be an absolute path other than '/'.")
    }
    if URL(fileURLWithPath: value).standardizedFileURL.path == "/Volumes" {
        return tr("不能将 /Volumes 本身用作挂载点。", "'/Volumes' itself cannot be used as a mount point.")
    }
    let components = value.split(separator: "/")
    guard !components.contains("."), !components.contains("..") else {
        return tr("挂载路径不能包含 . 或 .. 路径段。", "Mount path cannot contain '.' or '..' path components.")
    }
    return nil
}

func usesSystemManagedMountPoint(_ target: MountTarget) -> Bool {
    let mountURL = URL(fileURLWithPath: target.mountPath, isDirectory: true).standardizedFileURL
    guard mountURL.deletingLastPathComponent().path == "/Volumes",
          let components = URLComponents(string: target.url),
          let shareName = components.path.split(separator: "/").last else { return false }
    return String(shareName).caseInsensitiveCompare(mountURL.lastPathComponent) == .orderedSame
}

func isIPAddress(_ value: String) -> Bool {
    if isIPv4Address(value) { return true }
    var address6 = in6_addr()
    return value.withCString({ inet_pton(AF_INET6, $0, &address6) }) == 1
}

func promptExcludedGateways() -> [String]? {
    while true {
        print(tr("  可选：输入要排除的物理网关 IP，多个地址用逗号分隔；直接回车表示不排除：",
                 "  Optional: enter physical gateway IPs to exclude, separated by commas; Enter means none: "), terminator: "")
        let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if input.isEmpty { return nil }
        let addresses = input.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !addresses.isEmpty, addresses.allSatisfy(isIPAddress) else {
            print(tr("  ✗ 列表中存在无效 IP 地址，请重新输入。", "  ✗ The list contains an invalid IP address. Please try again."))
            continue
        }
        return Array(Set(addresses)).sorted()
    }
}

func probeHostWithRetries(host: String, retries: Int = 3, interval: Double = 1.0) -> Bool {
    let cleanHost = extractHost(from: host)
    guard !cleanHost.isEmpty, retries > 0 else { return false }
    let attempts = min(retries, 10)
    let retryInterval = interval.isFinite ? min(max(interval, 0), 10) : 1.0
    for attempt in 1...attempts {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        probe.arguments = ["-z", "-G", "2", cleanHost, "445"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        do {
            try probe.run()
            probe.waitUntilExit()
            if probe.terminationStatus == 0 {
                return true
            }
        } catch {
            writeLog("SMB TCP probe failed to start for \(cleanHost): \(error.localizedDescription)")
        }
        if attempt < attempts, retryInterval > 0 {
            Thread.sleep(forTimeInterval: retryInterval)
        }
    }
    return false
}

// MARK: - 内核非阻塞挂载表快照与失效 SMB 挂载清理

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
    let result = runCommand(executable: binPath, arguments: ["status", "--json"])
    guard result.status == 0,
          let data = result.stdout.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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
}

func remoteSMBAcceptanceURL(_ urlString: String, peers: [DiscoveredTailscalePeer]) -> (url: String, usesTailscaleAddress: Bool) {
    let configuredHost = extractHost(from: urlString).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    guard let peer = peers.first(where: {
        $0.magicDNS?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == configuredHost
    }),
          let address = URLComponents(string: urlString).flatMap({ components -> String? in
              var routedComponents = components
              routedComponents.host = peer.ip
              return routedComponents.url?.absoluteString
          }) else {
        return (urlString, false)
    }
    return (address, true)
}

// 通过共享时限内的子进程尝试强制卸载。
@discardableResult
func forceUnmountWithTimeout(path: String, timeoutSeconds: Double = 3.0) -> Bool {
    print("    [Unmount] Force unmounting stale/conflicting volume at \(path)...")
    writeLog("Attempting force unmount on \(path) (timeout \(timeoutSeconds)s)")

    let requestedTimeout = timeoutSeconds.isFinite ? max(timeoutSeconds, 0) : 3.0
    let startedAt = Date()
    let diskutil = runCommandDiscardingOutputWithTimeout(
        executable: "/usr/sbin/diskutil",
        arguments: ["unmount", "force", path],
        timeout: requestedTimeout * 0.6
    )

    if diskutil.status != 0 || diskutil.timedOut {
        guard diskutil.processStopped else {
            writeLog("diskutil unmount did not stop after SIGKILL; skipped concurrent fallback")
            return false
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        let remaining = max(requestedTimeout - elapsed, 0)
        writeLog("diskutil unmount failed or timed out; trying bounded umount -f fallback")
        if remaining > 0 {
            let fallback = runCommandDiscardingOutputWithTimeout(
                executable: "/sbin/umount",
                arguments: ["-f", path],
                timeout: remaining
            )
            guard fallback.processStopped else {
                writeLog("umount -f fallback did not stop after SIGKILL")
                return false
            }
            if fallback.status != 0 {
                writeLog("umount -f fallback failed with status \(fallback.status.map(String.init) ?? "unknown")")
            }
        } else {
            writeLog("No timeout budget remained for umount -f fallback")
        }
    }

    let remaining = max(requestedTimeout - Date().timeIntervalSince(startedAt), 0)
    if remaining > 0 {
        Thread.sleep(forTimeInterval: min(0.5, remaining))
    }
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
    if let error = validateMountTargetURL(target.url) {
        print("    [Validation] \(error)")
        writeLog("Rejected invalid SMB URL for \(target.mountPath): \(redactedSMBURL(target.url))")
        return .unmountFailed
    }
    if let error = validateMountPath(target.mountPath) {
        print("    [Validation] \(error)")
        writeLog("Rejected invalid mount path: \(target.mountPath)")
        return .unmountFailed
    }

    guard let currentSource = getKernelMountSource(for: target.mountPath) else {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: target.mountPath, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                print("    [Mount Point] The configured path exists and is not a directory.")
                writeLog("Mount point is not a directory: \(target.mountPath)")
                return .unmountFailed
            }
        } else if !usesSystemManagedMountPoint(target) {
            do {
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: target.mountPath),
                    withIntermediateDirectories: true
                )
            } catch {
                print("    [Mount Point] Could not create directory: \(error.localizedDescription)")
                writeLog("Could not create mount point \(target.mountPath): \(error.localizedDescription)")
                return .unmountFailed
            }
        }
        return .readyToMount
    }

    guard let currentResource = smbResourceIdentity(currentSource) else {
        print("    [Mount Point] An unrelated filesystem is mounted at this path; it will be left untouched.")
        writeLog("Refusing to unmount non-SMB filesystem at configured mount path \(target.mountPath): \(currentSource)")
        return .unmountFailed
    }

    let targetResource = smbResourceIdentity(target.url)!
    let currentHost = extractHost(from: currentSource)
    let targetHost = extractHost(from: target.url)

    if currentResource == targetResource {
        if probeHostWithRetries(host: targetHost, retries: 1, interval: 0.5) {
            return .alreadyMountedHealthy
        } else {
            print("    [Health Check] SMB endpoint \(targetHost):445 is unreachable.")
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
    let mdutil = runCommand(executable: "/usr/bin/mdutil", arguments: ["-i", "off", mountPath])
    var markerCreated = false
    if mdutil.status != 0 {
        writeLog("mdutil could not disable indexing for \(mountPath): \(mdutil.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        fputs("    ⚠ Could not confirm Spotlight indexing is disabled for \(mountPath).\n", stderr)
    }

    let flagURL = URL(fileURLWithPath: mountPath).appendingPathComponent(".metadata_never_index")
    if !FileManager.default.fileExists(atPath: flagURL.path) {
        do {
            try "".write(to: flagURL, atomically: true, encoding: .utf8)
            markerCreated = true
        } catch {
            writeLog("Could not create Spotlight marker at \(mountPath): \(error.localizedDescription)")
        }
    } else {
        markerCreated = true
    }
    if mdutil.status == 0 || markerCreated {
        writeLog("Spotlight indexing prevention requested for \(mountPath) (mdutil status: \(mdutil.status), marker present: \(markerCreated))")
    } else {
        writeLog("Spotlight indexing prevention could not be confirmed for \(mountPath)")
    }
}

// 静默挂载网络卷宗。/Volumes 下的标准共享名由 NetFS 创建挂载目录，避免普通 LaunchAgent 写系统目录。
func netFSMountOptions(hasExplicitMountPoint: Bool) -> NSMutableDictionary? {
    guard hasExplicitMountPoint else { return nil }
    let options = NSMutableDictionary()
    options[kNetFSMountAtMountDirKey as String] = true
    return options
}

func silentMount(urlString: String, mountPath: String) -> Bool {
    if let error = validateMountTargetURL(urlString) {
        fputs("    ✗ \(error)\n", stderr)
        return false
    }
    if let error = validateMountPath(mountPath) {
        fputs("    ✗ \(error)\n", stderr)
        return false
    }
    guard let url = CFURLCreateWithString(kCFAllocatorDefault, urlString as CFString, nil) else {
        fputs("    ✗ Invalid SMB URL: \(redactedSMBURL(urlString))\n", stderr)
        return false
    }
    let standardizedMountPath = URL(fileURLWithPath: mountPath, isDirectory: true).standardizedFileURL.path
    let mountpointURL: CFURL?
    if FileManager.default.fileExists(atPath: standardizedMountPath) {
        mountpointURL = URL(fileURLWithPath: standardizedMountPath, isDirectory: true).standardizedFileURL as CFURL
    } else if usesSystemManagedMountPoint(MountTarget(url: urlString, mountPath: standardizedMountPath)) {
        mountpointURL = nil
    } else {
        fputs("    ✗ Mount point does not exist and cannot be delegated to NetFS: \(standardizedMountPath)\n", stderr)
        writeLog("Mount point is missing and is not a NetFS-managed /Volumes share path: \(standardizedMountPath)")
        return false
    }
    let openOptions = NSMutableDictionary()
    openOptions[kNAUIOptionKey as String] = kNAUIOptionNoUI as String
    let mountOptions = netFSMountOptions(hasExplicitMountPoint: mountpointURL != nil)
    var mountPoints: Unmanaged<CFArray>?
    let status = NetFSMountURLSync(
        url,
        mountpointURL,
        nil,
        nil,
        openOptions as CFMutableDictionary,
        mountOptions as CFMutableDictionary?,
        &mountPoints
    )
    let returnedMountPaths = mountPoints?.takeRetainedValue() as? [String] ?? []
    if status == noErr {
        let candidatePaths = ([standardizedMountPath] + returnedMountPaths).reduce(into: [String]()) { paths, path in
            let normalizedPath = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
            if !paths.contains(normalizedPath) { paths.append(normalizedPath) }
        }
        for candidatePath in candidatePaths {
            for _ in 0..<20 {
                if let mountedSource = getKernelMountSource(for: candidatePath) {
                    if smbResourceIdentity(mountedSource) == smbResourceIdentity(urlString) {
                        if candidatePath == standardizedMountPath {
                            print("    ✓ Mounted at \(candidatePath): \(redactedSMBURL(urlString))")
                            writeLog("Mounted \(redactedSMBURL(urlString)) at \(candidatePath)")
                            return true
                        }
                        fputs("    ✗ NetFS mounted this share at \(candidatePath), not the configured path \(standardizedMountPath).\n", stderr)
                        writeLog("NetFS mounted \(redactedSMBURL(urlString)) at \(candidatePath), not configured path \(standardizedMountPath); cleaning up the new mount")
                        _ = forceUnmountWithTimeout(path: candidatePath)
                        return false
                    }
                    break
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        fputs("    ✗ NetFS returned success, but no matching mount appeared at \(standardizedMountPath).\n", stderr)
        writeLog("NetFS returned success for \(redactedSMBURL(urlString)), but no matching mount appeared at \(standardizedMountPath)")
        return false
    } else {
        fputs("    ✗ Failed to mount \(redactedSMBURL(urlString)) at \(standardizedMountPath) (error: \(status))\n", stderr)
        writeLog("Failed to mount \(redactedSMBURL(urlString)) at \(standardizedMountPath) (error: \(status))")
        return false
    }
}

func runRemoteSMBAcceptanceChecks() -> Bool {
    guard let config = loadConfig(from: getConfigURL(), migrate: false),
          let profile = config.profiles.first(where: { $0.match.type == "probe_host" && !$0.targets.isEmpty }) else {
        fputs("FAIL remote SMB acceptance: no valid remote profile is configured.\n", stderr)
        return false
    }

    print("Remote SMB acceptance: profile \(profile.id), \(profile.targets.count) target(s)")
    var passed = 0
    var failed = 0
    let tailscalePeers = discoverTailscalePeers()
    guard let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
        fputs("FAIL remote SMB acceptance: no user cache directory is available.\n", stderr)
        return false
    }
    let testRoot = cacheDirectory
        .appendingPathComponent("AutoMountRemoteAcceptance-\(UUID().uuidString)", isDirectory: true)

    for (index, target) in profile.targets.enumerated() {
        let mountPath = testRoot.appendingPathComponent("target-\(index + 1)", isDirectory: true).path
        guard validateMountTargetURL(target.url) == nil,
              validateMountPath(mountPath) == nil else {
            fputs("FAIL remote SMB target \(index + 1): invalid configured target.\n", stderr)
            failed += 1
            continue
        }
        do {
            try FileManager.default.createDirectory(atPath: mountPath, withIntermediateDirectories: true)
        } catch {
            fputs("FAIL remote SMB target \(index + 1): could not create a temporary mount point (\(error.localizedDescription)).\n", stderr)
            failed += 1
            continue
        }

        let endpoint = remoteSMBAcceptanceURL(target.url, peers: tailscalePeers)
        if endpoint.usesTailscaleAddress {
            print("  Target \(index + 1): using the configured peer's Tailscale address for this test")
        }
        let testHost = extractHost(from: endpoint.url)
        let reachable = probeHostWithRetries(
            host: testHost,
            retries: profile.match.retryCount ?? 3,
            interval: profile.match.retryInterval ?? 1.0
        )
        var mountVerified = false
        if reachable {
            _ = silentMount(urlString: endpoint.url, mountPath: mountPath)
            if let source = getKernelMountSource(for: mountPath) {
                mountVerified = smbResourceIdentity(source) == smbResourceIdentity(endpoint.url)
            }
        }

        var cleanupSucceeded = true
        if getKernelMountSource(for: mountPath) != nil {
            cleanupSucceeded = forceUnmountWithTimeout(path: mountPath)
        }
        if cleanupSucceeded {
            try? FileManager.default.removeItem(at: testRoot)
        } else {
            fputs("FAIL remote SMB target \(index + 1): unmount failed; temporary mount remains at \(mountPath).\n", stderr)
        }

        if mountVerified && cleanupSucceeded {
            passed += 1
            print("PASS remote SMB target \(index + 1): mounted the configured share through the remote endpoint and unmounted it")
        } else {
            failed += 1
            let reason = reachable ? "remote mount or source verification failed" : "remote SMB TCP port 445 is unreachable"
            fputs("FAIL remote SMB target \(index + 1): \(reason).\n", stderr)
        }
    }

    print("Remote SMB acceptance: \(passed) passed, \(failed) failed")
    return failed == 0 && passed == profile.targets.count
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
            if byte == 3 || byte == 27 { return .cancel } // Ctrl+C or Esc
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

// 终端交互式复选框多选 (返回 nil 表示用户主动取消/按 Esc)
func promptInteractiveCheckbox(title: String, options: [SelectionOption]) -> [Int]? {
    guard !options.isEmpty else { return [] }

    if !TerminalUI.isInteractive {
        print(title)
        for (i, opt) in options.enumerated() {
            let sub = opt.subtitle != nil ? " (\(opt.subtitle!))" : ""
            print("  [\(i + 1)] \(opt.title)\(sub)")
        }
        print(tr("请输入要选择的序号 (例如 1,2 或 all，按回车全不选，输入 q 取消): ",
                 "Enter options to select (e.g. 1,2 or all, Enter to skip, q to cancel): "), terminator: "")
        guard let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else {
            return []
        }
        if line.lowercased() == "q" || line.lowercased() == "cancel" { return nil }
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
    print(tr("\u{1b}[90m(↑/↓ 移动光标，Space 切换勾选，a 全选，Enter 确认提交，Esc 取消)\u{1b}[0m",
             "\u{1b}[90m(↑/↓ Move cursor, Space toggle, a select all, Enter confirm, Esc cancel)\u{1b}[0m"))
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
            print("")
            return nil
        default:
            break
        }
    }
}

// 终端交互式单选 (返回 nil 表示用户主动取消/按 Esc)
func promptInteractiveRadio(title: String, options: [SelectionOption], defaultIndex: Int = 0) -> Int? {
    guard !options.isEmpty else { return nil }

    if !TerminalUI.isInteractive {
        print(title)
        for (i, opt) in options.enumerated() {
            let sub = opt.subtitle != nil ? " (\(opt.subtitle!))" : ""
            print("  [\(i + 1)] \(opt.title)\(sub)")
        }
        print(tr("请选择序号 [默认 \(defaultIndex + 1)，输入 q 取消]: ",
                 "Select index [Default \(defaultIndex + 1), q to cancel]: "), terminator: "")
        guard let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else {
            return defaultIndex
        }
        if line.lowercased() == "q" || line.lowercased() == "cancel" { return nil }
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
    print(tr("\u{1b}[90m(↑/↓ 移动光标，Enter 选定确认，Esc 取消)\u{1b}[0m",
             "\u{1b}[90m(↑/↓ Move cursor, Enter confirm selection, Esc cancel)\u{1b}[0m"))
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
            print("")
            return nil
        default:
            break
        }
    }
}

// MARK: - 初始化向导 (--init)

func runInitWizard(offerServiceInstallation: Bool = true) -> Bool {
    print(tr("""
    Auto Mount Tool - 初始化配置向导 (v\(autoMountVersion))
    ======================================
    """, """
    Auto Mount Tool - Setup Wizard (v\(autoMountVersion))
    ====================================
    """))

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
        let options = activeMounts.map { SelectionOption(title: URL(fileURLWithPath: $0.path).lastPathComponent, subtitle: redactedSMBURL($0.url)) }
        let selectedIndices = promptInteractiveCheckbox(
            title: tr("发现当前系统中已挂载的 SMB 卷宗，请选择需要纳入自动挂载的目标 (直接按回车跳过)：",
                      "Discovered currently mounted SMB volumes. Select targets to auto-mount (Enter to skip):"),
            options: options
        ) ?? []
        for idx in selectedIndices {
            let item = activeMounts[idx]
            homeTargets.append(MountTarget(url: item.url, mountPath: item.path))
            print(tr("  ✓ 已添加: \(item.path) (\(redactedSMBURL(item.url)))", "  ✓ Added: \(item.path) (\(redactedSMBURL(item.url)))"))
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
                        print(tr("  ✓ 已添加: \(pathStr) (\(redactedSMBURL(urlStr)))", "  ✓ Added: \(pathStr) (\(redactedSMBURL(urlStr)))"))
            print(tr("  继续添加另一个挂载目标？(y/n) [默认 n]: ",
                     "  Add another mount target? (y/n) [Default n]: "), terminator: "")
            let cont = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "n"
            if cont != "y" && cont != "yes" {
                break
            }
        }
    }

    if homeTargets.isEmpty {
        print(tr("  ✓ 未为此局域网配置挂载目标；策略命中后会结束本轮评估。",
                 "  ✓ No local shares are configured. A match ends profile evaluation on this network."))
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

    guard let selected = promptInteractiveRadio(
        title: tr("请选择远程对端接入方式：", "Select remote peer connection mode:"),
        options: remoteOptions,
        defaultIndex: 0
    ) else {
        print(tr("\n向导已取消。", "\nWizard cancelled."))
        exit(0)
    }

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
                ) ?? 0
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
                        print(tr("  ✓ 自动映射: \(redactedSMBURL(remoteURL)) -> \(target.mountPath)",
                                 "  ✓ Auto-mapped: \(redactedSMBURL(remoteURL)) -> \(target.mountPath)"))
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
                    let mOptions = matchingMounts.map { SelectionOption(title: URL(fileURLWithPath: $0.path).lastPathComponent, subtitle: redactedSMBURL($0.url)) }
                    let picked = promptInteractiveCheckbox(
                        title: tr("检测到当前已挂载该设备的共享卷宗，请勾选需要自动挂载的项 (直接回车跳过)：",
                                  "Discovered active mounts for this device. Select items to include (Enter to skip):"),
                        options: mOptions
                    ) ?? []
                    for pIdx in picked {
                        let item = matchingMounts[pIdx]
                        remoteTargets.append(MountTarget(url: item.url, mountPath: item.path))
                        print(tr("  ✓ 已添加: \(item.path) (\(redactedSMBURL(item.url)))", "  ✓ Added: \(item.path) (\(redactedSMBURL(item.url)))"))
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
                print(tr("  ✓ 已添加: \(pathStr) (\(redactedSMBURL(remoteURL)))", "  ✓ Added: \(pathStr) (\(redactedSMBURL(remoteURL)))"))
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
                    excludeGatewayIPs: promptExcludedGateways(),
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
    let channelOptions = [
        SelectionOption(title: "off", subtitle: tr("关闭自动检查 (默认，零网络请求，可纯手动运行 './auto_mount --update')",
                                                  "Disable auto-checks (Default, manual update via './auto_mount --update')")),
        SelectionOption(title: "notify", subtitle: tr("发现新版本时发送系统通知，由您手动执行更新",
                                                     "Send system notification on new version, update manually")),
        SelectionOption(title: "auto", subtitle: tr("发现新版本时自动静默预检并平滑无缝热升级",
                                                   "Automatically download, pre-check, and upgrade in background"))
    ]
    let selChannel = promptInteractiveRadio(
        title: tr("\n[4/5] 请选择软件自动更新检查策略：", "\n[4/5] Select software update policy:"),
        options: channelOptions,
        defaultIndex: 0
    ) ?? 0
    let selectedChannel = channelOptions[selChannel].title
    print(tr("  ✓ 软件更新策略已设置为: \(selectedChannel)", "  ✓ Software update policy set to: \(selectedChannel)"))

    // 保存配置
    let config = AutoMountConfig(version: autoMountVersion, updateChannel: selectedChannel, lastUpdateCheckTimestamp: nil, lastNotifiedVersion: nil, profiles: profiles)
    let workspaceConfigURL = getWorkspaceConfigURL()
    let previousWorkspaceConfig = inspectConfigFile(at: workspaceConfigURL)
    guard previousWorkspaceConfig.state != .inaccessible else {
        fputs(tr("✗ 无法安全读取或备份工作区配置；未写入新配置。\n",
                 "✗ The workspace config cannot be safely read or backed up; no new config was written.\n"), stderr)
        return false
    }
    if let backupURL = try? backUpConfigFile(previousWorkspaceConfig) {
        print(tr("✓ 已备份原工作区配置: \(backupURL.path)", "✓ Backed up the previous workspace config: \(backupURL.path)"))
    } else if previousWorkspaceConfig.contents != nil {
        fputs(tr("✗ 无法备份现有工作区配置；未覆盖原文件。\n",
                 "✗ Could not back up the existing workspace config; the original file was not replaced.\n"), stderr)
        return false
    }
    guard saveConfig(config, to: workspaceConfigURL, syncInstalled: false,
                     preserveUnknownFields: false, mergeRuntimeMetadata: false) else {
        fputs(tr("✗ 新配置未能保存；未继续部署守护服务。\n",
                 "✗ The new config could not be saved; daemon deployment was not continued.\n"), stderr)
        return false
    }
    print(tr("\n[DONE] 初始化完成！配置已写入 \(getConfigURL().path)",
             "\n[DONE] Setup complete! Configuration written to \(getConfigURL().path)"))

    guard offerServiceInstallation else {
        print(tr("✓ 配置已保存；正在继续当前命令。\n", "✓ Config saved; continuing the current command.\n"))
        return true
    }

    // 5. 部署后台自启动守护服务
    let daemonOptions = [
        SelectionOption(title: tr("立即部署自启动后台守护服务 (推荐)", "Deploy LaunchAgent daemon now (Recommended)"),
                        subtitle: tr("登录、网络或配置变化时运行，并每 60 秒重试", "Run on login, network/config changes, and retry every 60 seconds")),
        SelectionOption(title: tr("暂不部署", "Skip for now"),
                        subtitle: tr("后续可随时运行 './auto_mount --install' 进行部署", "Run './auto_mount --install' anytime later"))
    ]
    let selDaemon = promptInteractiveRadio(
        title: tr("\n[5/5] 部署自启动后台守护服务：", "\n[5/5] Deploy Background Auto-Mount Daemon:"),
        options: daemonOptions,
        defaultIndex: 0
    ) ?? 0
    if selDaemon == 0 {
        print("")
        installLaunchAgent()
    } else {
        print(tr("  ✓ 已跳过后台服务安装。后续可随时运行 './auto_mount --install' 进行部署。\n",
                 "  ✓ Daemon deployment skipped. You can run './auto_mount --install' anytime later.\n"))
    }
    return true
}

func runInitCommand(resetExistingConfig: Bool = false) -> Bool {
    let workspaceURL = getWorkspaceConfigURL()
    let runtimeURL = getInstalledDir().appendingPathComponent("auto_mount.plist")
    let workspace = inspectConfigFile(at: workspaceURL)
    let runtime = inspectConfigFile(at: runtimeURL)

    let equivalent = workspace.state == .usable && runtime.state == .usable
        && workspace.config.map { workspaceConfig in
            runtime.config.map { installConfigModelsAreEquivalent(workspaceConfig, $0) } ?? false
        } == true
    switch resolveInitConfigState(
        resetExistingConfig: resetExistingConfig,
        workspaceState: workspace.state,
        runtimeState: runtime.state,
        documentsEquivalent: equivalent
    ) {
    case .preserve(.runtime):
        if workspace.state == .invalid {
            print(tr("✓ 已保留有效的守护配置；工作区文件无效。请运行 `--config` 恢复工作区，或运行 `--install` 部署服务。",
                     "✓ Preserved the usable daemon config; the workspace file is invalid. Run `--config` to restore the workspace or `--install` to deploy the service."))
        } else {
            print(tr("✓ 已找到有效的守护配置；`--init` 未重建它。请用 `--config` 管理配置，或用 `--install` 部署守护程序。",
                     "✓ A usable daemon config already exists; `--init` left it intact. Use `--config` to manage it or `--install` to deploy the daemon."))
        }
        return true
    case .preserve(.workspace):
        if runtime.state == .invalid, FileManager.default.fileExists(atPath: getLaunchAgentPlistURL().path) {
            print(tr("✓ 已保留有效的工作区配置；守护配置无效。请运行 `--install`，程序会先备份并恢复守护配置。",
                     "✓ Preserved the usable workspace config; the daemon config is invalid. Run `--install` to back it up and restore it."))
        } else {
            print(tr("✓ 已找到有效的工作区配置；`--init` 未重建它。请用 `--config` 修改配置，或用 `--install` 部署守护程序。",
                     "✓ A usable workspace config already exists; `--init` left it intact. Use `--config` to edit it or `--install` to deploy the daemon."))
        }
        return true
    case .diverged:
        print(tr("⚠ 工作区与守护配置都有效但内容不同；`--init` 未覆盖任何一份。请用 `--config` 管理活动守护配置，或用 `--install --config-source workspace` 明确选择工作区配置。",
                 "⚠ Both workspace and daemon configs are valid but differ; `--init` did not replace either one. Use `--config` to manage the active daemon config, or `--install --config-source workspace` to explicitly select the workspace config."))
        return true
    case let .futureVersion(location, version):
        let name = location == .runtime ? tr("守护", "daemon") : tr("工作区", "workspace")
        fputs(tr("✗ \(name)配置版本 v\(version) 高于当前程序 v\(autoMountVersion)；未重置配置。请先使用兼容版本，或明确运行 `--init --reset`。\n",
                 "✗ The \(name) config v\(version) is newer than program v\(autoMountVersion); it was not reset. Use a compatible newer program or explicitly run `--init --reset`.\n"), stderr)
        return false
    case let .inaccessible(location):
        let name = location == .runtime ? tr("守护", "daemon") : tr("工作区", "workspace")
        fputs(tr("✗ 无法安全读取或备份\(name)配置；未启动初始化向导。\n",
                 "✗ The \(name) config cannot be safely read or backed up; the setup wizard was not started.\n"), stderr)
        return false
    case .initialize:
        break
    }

    guard isatty(STDIN_FILENO) == 1 else {
        fputs(tr("✗ 当前没有可用配置且输入不是交互终端；请在 Terminal 中运行 `./auto_mount --init`。\n",
                 "✗ No usable config exists and stdin is not interactive; run `./auto_mount --init` in Terminal.\n"), stderr)
        return false
    }
    return runInitWizard()
}

func configURL(for location: InstallConfigLocation) -> URL {
    switch location {
    case .workspace:
        return getWorkspaceConfigURL()
    case .runtime:
        return getInstalledDir().appendingPathComponent("auto_mount.plist")
    }
}

func prepareManagementConfigURL() -> URL? {
    let workspaceURL = getWorkspaceConfigURL()
    let runtimeURL = getInstalledDir().appendingPathComponent("auto_mount.plist")
    let launchAgentInstalled = FileManager.default.fileExists(atPath: getLaunchAgentPlistURL().path)
    var didRunSetup = false

    for _ in 0..<2 {
        let workspace = inspectConfigFile(at: workspaceURL)
        let runtime = inspectConfigFile(at: runtimeURL)
        let resolution = resolveManagementConfigLocation(
            launchAgentInstalled: launchAgentInstalled,
            workspaceState: workspace.state,
            runtimeState: runtime.state
        )

        switch resolution {
        case let .selected(location):
            if workspace.state == .usable, runtime.state == .usable,
               let workspaceConfig = workspace.config, let runtimeConfig = runtime.config,
               !installConfigModelsAreEquivalent(workspaceConfig, runtimeConfig) {
                let active = launchAgentInstalled ? runtimeURL.path : workspaceURL.path
                print(tr("⚠ 工作区与守护配置内容不同；本次管理活动配置：\(active)",
                         "⚠ Workspace and daemon configs differ; managing the active config: \(active)"))
            }
            return configURL(for: location)
        case let .recover(target, source):
            let sourceInspection = source == .workspace ? workspace : runtime
            let destinationInspection = target == .workspace ? workspace : runtime
            do {
                let backupURL = try replaceConfigFile(
                    with: sourceInspection,
                    at: configURL(for: target),
                    destination: destinationInspection
                )
                if let backupURL {
                    print(tr("✓ 已备份不可用配置: \(backupURL.path)", "✓ Backed up the unusable config: \(backupURL.path)"))
                }
                print(tr("✓ 已从\(source == .workspace ? "工作区" : "守护")配置恢复\(target == .workspace ? "工作区" : "守护")配置。",
                         "✓ Restored the \(target == .workspace ? "workspace" : "daemon") config from the \(source == .workspace ? "workspace" : "daemon") config."))
                writeLog("Configuration management restored \(target) config from \(source)")
                return configURL(for: target)
            } catch {
                fputs(tr("✗ 配置恢复失败，未进入管理菜单: \(error.localizedDescription)\n",
                         "✗ Config recovery failed; the management menu was not opened: \(error.localizedDescription)\n"), stderr)
                return nil
            }
        case .initialize:
            guard !didRunSetup, isatty(STDIN_FILENO) == 1 else {
                fputs(tr("✗ 没有可用配置。请在交互式 Terminal 中运行 `./auto_mount --init`。\n",
                         "✗ No usable config exists. Run `./auto_mount --init` in an interactive Terminal.\n"), stderr)
                return nil
            }
            didRunSetup = true
            guard runInitWizard(offerServiceInstallation: false) else { return nil }
        case let .futureVersion(location, version):
            let name = location == .runtime ? tr("守护", "daemon") : tr("工作区", "workspace")
            fputs(tr("✗ \(name)配置版本 v\(version) 高于当前程序 v\(autoMountVersion)；未修改配置。请先使用兼容版本。\n",
                     "✗ The \(name) config v\(version) is newer than program v\(autoMountVersion); no config was changed. Use a compatible newer program first.\n"), stderr)
            return nil
        case let .inaccessible(location):
            let name = location == .runtime ? tr("守护", "daemon") : tr("工作区", "workspace")
            fputs(tr("✗ 无法安全读取或备份\(name)配置；未修改任何文件。\n",
                     "✗ The \(name) config cannot be safely read or backed up; no files were changed.\n"), stderr)
            return nil
        }
    }
    return nil
}

// MARK: - 日常配置维护菜单 (--config)

struct LaunchAgentDiagnostic {
    let loaded: Bool
    let output: String
    let state: String?
    let lastExitCode: Int?
    let pid: Int?
}

func firstRegexCapture(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          match.numberOfRanges > 1,
          let range = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[range])
}

func getLaunchAgentDiagnostic() -> LaunchAgentDiagnostic {
    let serviceTarget = "gui/\(getuid())/\(launchAgentLabel)"
    let result = runCommand(executable: "/bin/launchctl", arguments: ["print", serviceTarget])
    let state = firstRegexCapture(#"(?m)^\s*state = (.+)$"#, in: result.stdout)
    let exitCode = firstRegexCapture(#"(?m)^\s*last exit code = (-?\d+)\s*$"#, in: result.stdout).flatMap(Int.init)
    let pid = firstRegexCapture(#"(?m)^\s*pid = (\d+)\s*$"#, in: result.stdout).flatMap(Int.init)
    return LaunchAgentDiagnostic(loaded: result.status == 0, output: result.stdout, state: state, lastExitCode: exitCode, pid: pid)
}

func getLaunchAgentStatusSummary() -> String {
    let plistURL = getLaunchAgentPlistURL()
    if !FileManager.default.fileExists(atPath: plistURL.path) {
        return tr("未安装 (可选择 [5] 部署守护)", "Not installed (Select [5] to deploy)")
    }
    let runtimeConfigURL = getInstalledDir().appendingPathComponent("auto_mount.plist")
    let configState = FileManager.default.fileExists(atPath: runtimeConfigURL.path)
        ? tr("守护配置存在", "runtime config present")
        : tr("守护配置缺失", "runtime config missing")
    let diagnostic = getLaunchAgentDiagnostic()
    if diagnostic.loaded {
        if let exitCode = diagnostic.lastExitCode, exitCode != 0 {
            return tr("已加载；最近一次运行失败 (退出码 \(exitCode))；\(configState)",
                      "Loaded; last run failed (exit \(exitCode)); \(configState)")
        }
        if diagnostic.pid != nil {
            return tr("已加载且当前正在执行；\(configState)", "Loaded and currently running; \(configState)")
        }
        return tr("已加载，当前空闲等待触发；\(configState)", "Loaded and idle, waiting for a trigger; \(configState)")
    } else {
        return tr("描述文件已安装但未加载；\(configState)", "Plist installed but not loaded; \(configState)")
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

func pauseForUser() {
    print(tr("\n按回车键继续...", "\nPress Enter to continue..."), terminator: "")
    _ = readLine()
}

func validateMountTarget(profile: NetworkProfile, newURL: String, newPath: String) -> String? {
    if let error = validateMountTargetURL(newURL) { return error }
    if let error = validateMountPath(newPath) { return error }
    if profile.targets.contains(where: { $0.url.caseInsensitiveCompare(newURL) == .orderedSame }) {
        return tr("策略 '\(profile.id)' 下已存在相同的 SMB 地址: \(redactedSMBURL(newURL))",
                  "Profile '\(profile.id)' already contains SMB URL: \(redactedSMBURL(newURL))")
    }
    if profile.targets.contains(where: { $0.mountPath.caseInsensitiveCompare(newPath) == .orderedSame }) {
        return tr("策略 '\(profile.id)' 下本地挂载路径已被占用: \(newPath)",
                  "Profile '\(profile.id)' already uses mount path: \(newPath)")
    }
    return nil
}

// MARK: - 挂载目标管理模块 (Task 2)

func manageMountTargets(config: inout AutoMountConfig) {
    while true {
        let options = [
            SelectionOption(title: tr("➕ 添加挂载目标", "➕ Add Mount Target"),
                            subtitle: tr("从系统活动挂载项复选批量导入，或手动循环录入", "Batch import active mounts, or manual entry")),
            SelectionOption(title: tr("🗑️ 批量删除挂载目标", "🗑️ Batch Remove Mount Targets"),
                            subtitle: tr("复选框勾选多个目标，一次性批量移除", "Check multiple targets to delete in batch")),
            SelectionOption(title: tr("↩ 返回上级菜单", "↩ Back to Main Menu"), subtitle: nil)
        ]

        guard let sel = promptInteractiveRadio(
            title: tr("\n📁 挂载目标管理：", "\n📁 Mount Target Management:"),
            options: options,
            defaultIndex: 0
        ), sel < 2 else {
            break
        }

        if sel == 0 {
            // 添加挂载目标
            var profileOptions: [SelectionOption] = []
            for p in config.profiles {
                let typeLabel = p.match.type == "gateway_mac" ? tr("局域网", "LAN") : tr("远程", "Remote")
                let noDesc = tr("无描述", "No description")
                let countStr = tr("当前 \(p.targets.count) 个挂载目标", "Current \(p.targets.count) targets")
                profileOptions.append(SelectionOption(
                    title: "[\(typeLabel)] \(p.id)",
                    subtitle: "\(p.description ?? noDesc) (\(countStr))"
                ))
            }
            profileOptions.append(SelectionOption(title: tr("↩ 取消并返回", "↩ Cancel and return"), subtitle: nil))

            guard let pSel = promptInteractiveRadio(
                title: tr("\n请选择要添加目标的策略：", "\nSelect target profile:"),
                options: profileOptions,
                defaultIndex: 0
            ), pSel < config.profiles.count else {
                continue
            }
            let profileIndex = pSel

            // 1. 嗅探活动 SMB 挂载，支持复选框多选导入
            let activeMounts = discoverActiveSMBMounts()
            if !activeMounts.isEmpty {
                let mOptions = activeMounts.map { SelectionOption(title: URL(fileURLWithPath: $0.path).lastPathComponent, subtitle: "\($0.path) <- \(redactedSMBURL($0.url))") }
                if let picked = promptInteractiveCheckbox(
                    title: tr("发现当前系统中已挂载的 SMB 卷宗，请勾选需要导入的目标 (Space 勾选，a 全选，Enter 确认，Esc 跳过)：",
                              "Discovered active SMB mounts. Check items to import (Space toggle, a all, Enter confirm, Esc skip):"),
                    options: mOptions
                ), !picked.isEmpty {
                    var addedCount = 0
                    for idx in picked {
                        let m = activeMounts[idx]
                        if let err = validateMountTarget(profile: config.profiles[profileIndex], newURL: m.url, newPath: m.path) {
                            print(tr("  ✗ 跳过重复项: \(err)", "  ✗ Skipped duplicate: \(err)"))
                        } else {
                            config.profiles[profileIndex].targets.append(MountTarget(url: m.url, mountPath: m.path))
                            print(tr("  ✓ 已添加: \(m.path) <- \(redactedSMBURL(m.url))", "  ✓ Added: \(m.path) <- \(redactedSMBURL(m.url))"))
                            addedCount += 1
                        }
                    }
                    if addedCount > 0 {
                        saveConfig(config)
                        print(tr("✓ 已批量保存 \(addedCount) 个挂载目标至策略 '\(config.profiles[profileIndex].id)'。",
                                 "✓ Batch saved \(addedCount) targets to profile '\(config.profiles[profileIndex].id)'."))
                    }
                }
            }

            // 2. 引导手动录入
            let manualPromptOptions = [
                SelectionOption(title: tr("手动录入自定义挂载目标", "Manually enter custom target"),
                                subtitle: tr("输入 SMB URL 与本地挂载路径", "Enter SMB URL and local mount path")),
                SelectionOption(title: tr("完成添加，返回上级", "Finished, return"), subtitle: nil)
            ]
            let manualChoice = promptInteractiveRadio(
                title: tr("是否需要手动录入其他 SMB 挂载目标？", "Do you want to manually enter additional SMB targets?"),
                options: manualPromptOptions,
                defaultIndex: 1
            ) ?? 1

            if manualChoice == 0 {
                var defaultHost = ""
                if config.profiles[profileIndex].match.type == "probe_host" {
                    defaultHost = config.profiles[profileIndex].match.value
                }
                var addedManual = 0
                while true {
                    let sampleURL = defaultHost.isEmpty ? "smb://server.local/share" : "smb://\(defaultHost)/share"
                    print(tr("\n请输入完整 SMB 地址 (例如 \(sampleURL)，直接按回车结束): ",
                             "\nEnter full SMB URL (e.g. \(sampleURL), Enter to finish): "), terminator: "")
                    guard let url = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else {
                        break
                    }
                    var defaultPath = "/Volumes/share"
                    if let lastPart = url.split(separator: "/").last {
                        defaultPath = "/Volumes/\(lastPart)"
                    }
                    print(tr("请输入本地挂载点绝对路径 [默认: \(defaultPath)]: ",
                             "Enter local mount path [Default: \(defaultPath)]: "), terminator: "")
                    let pathInput = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let path = pathInput.isEmpty ? defaultPath : pathInput

                    if let err = validateMountTarget(profile: config.profiles[profileIndex], newURL: url, newPath: path) {
                        print(tr("  ✗ \(err)", "  ✗ \(err)"))
                    } else {
                        config.profiles[profileIndex].targets.append(MountTarget(url: url, mountPath: path))
                        addedManual += 1
                        print(tr("  ✓ 已添加: \(path) <- \(redactedSMBURL(url))", "  ✓ Added: \(path) <- \(redactedSMBURL(url))"))
                    }

                    print(tr("继续添加另一个目标？(y/n) [默认 n]: ",
                             "Add another target? (y/n) [Default n]: "), terminator: "")
                    let cont = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "n"
                    if cont != "y" && cont != "yes" {
                        break
                    }
                }
                if addedManual > 0 {
                    saveConfig(config)
                    print(tr("✓ 配置已保存更新。", "✓ Configuration saved."))
                }
            }

        } else if sel == 1 {
            // 批量删除挂载目标
            struct FlatTargetItem {
                let profileIndex: Int
                let targetIndex: Int
                let profileId: String
                let target: MountTarget
            }
            var flatItems: [FlatTargetItem] = []
            for (pI, p) in config.profiles.enumerated() {
                for (tI, t) in p.targets.enumerated() {
                    flatItems.append(FlatTargetItem(profileIndex: pI, targetIndex: tI, profileId: p.id, target: t))
                }
            }
            if flatItems.isEmpty {
                print(tr("\n当前没有任何已配置的挂载目标。", "\nNo configured mount targets found."))
                pauseForUser()
                continue
            }

            let deleteOptions = flatItems.map {
            SelectionOption(title: "\($0.target.mountPath) <- \(redactedSMBURL($0.target.url))",
                                subtitle: tr("归属策略: \($0.profileId)", "Profile: \($0.profileId)"))
            }
            guard let toDelete = promptInteractiveCheckbox(
                title: tr("\n请勾选要删除的挂载目标 (Space 勾选，a 全选，Enter 确认删除，Esc 取消)：",
                          "\nSelect targets to remove (Space toggle, a all, Enter confirm, Esc cancel):"),
                options: deleteOptions
            ), !toDelete.isEmpty else {
                print(tr("已取消删除操作。", "Deletion cancelled."))
                continue
            }

            // 按倒序删除，防止索引漂移
            let sortedIndices = toDelete.sorted(by: >)
            for idx in sortedIndices {
                let item = flatItems[idx]
                config.profiles[item.profileIndex].targets.remove(at: item.targetIndex)
            }
            saveConfig(config)
            print(tr("✓ 已成功批量删除 \(toDelete.count) 个挂载目标并保存。",
                     "✓ Successfully removed and saved \(toDelete.count) target(s)."))
            pauseForUser()
        }
    }
}

// MARK: - 网络策略流水线管理模块 (Task 3 & Task 4)

func manageNetworkProfiles(config: inout AutoMountConfig) {
    while true {
        print(tr("\n当前网络策略流水线 (自顶向下顺序评估，首次命中即执行)：",
                 "\nCurrent network profile pipeline (Evaluated top-to-bottom, first match wins):"))
        for (i, p) in config.profiles.enumerated() {
            let typeDesc = p.match.type == "gateway_mac" ? tr("局域网指纹", "Gateway MAC") : tr("远程主机探测", "Host Probe")
            print(tr("  [\(i + 1)] \(p.id) (\(p.description ?? "无描述"))",
                     "  [\(i + 1)] \(p.id) (\(p.description ?? "No description"))"))
            print("      • \(typeDesc): \(p.match.value)")
            if let excludes = p.excludeGatewayIPs, !excludes.isEmpty {
                print(tr("      • 排除网关 IP: \(excludes.joined(separator: ", "))",
                         "      • Excluded IPs: \(excludes.joined(separator: ", "))"))
            }
            print(tr("      • 挂载目标数: \(p.targets.count)", "      • Targets count: \(p.targets.count)"))
        }

        let profileMenuOptions = [
            SelectionOption(title: tr("↕️ 调整策略评估优先级 (上移/下移)", "↕️ Adjust Policy Priority (Move Up / Down)"),
                            subtitle: tr("调整在列表中的先后顺序，改变命中抢占关系", "Reorder pipeline to change evaluation precedence")),
            SelectionOption(title: tr("➕ 新建网络策略", "➕ Create New Network Profile"),
                            subtitle: tr("添加新的本地局域网指纹或异地远程互联策略", "Add new LAN gateway MAC or remote probe profile")),
            SelectionOption(title: tr("✏️ 编辑策略触发条件与属性", "✏️ Edit Profile Rules & Properties"),
                            subtitle: tr("更新网关指纹、更换远程主机(自动迁移)、描述与热点排除", "Update MAC, change remote host (auto-migrated), excludes")),
            SelectionOption(title: tr("🗑️ 删除网络策略", "🗑️ Delete Network Profile"),
                            subtitle: tr("移除不需要的策略及其包含的挂载目标", "Remove unneeded profile and its targets")),
            SelectionOption(title: tr("↩ 返回上级菜单", "↩ Back to Main Menu"), subtitle: nil)
        ]

        guard let sel = promptInteractiveRadio(
            title: tr("\n请选择策略管理操作：", "\nSelect profile management action:"),
            options: profileMenuOptions,
            defaultIndex: 0
        ) else {
            break
        }

        switch sel {
        case 0:
            // 调整策略优先级
            if config.profiles.count <= 1 {
                print(tr("\n当前仅有 1 个策略，无需调整顺序。", "\nOnly 1 profile configured. No reordering needed."))
                pauseForUser()
                continue
            }
            let pOptions = config.profiles.enumerated().map {
                SelectionOption(title: "[\($0 + 1)] \($1.id)", subtitle: "\($1.description ?? tr("无描述", "No description"))")
            }
            guard let chosen = promptInteractiveRadio(
                title: tr("\n请选择要调整优先级的策略：", "\nSelect profile to reorder:"),
                options: pOptions,
                defaultIndex: 0
            ) else {
                continue
            }
            let curIdx = chosen
            let actionOptions = [
                SelectionOption(title: tr("🔼 上移一位 (提升优先级)", "🔼 Move Up (Higher Priority)"),
                                subtitle: curIdx == 0 ? tr("(当前已是最高优先级)", "(Already at highest priority)") : nil),
                SelectionOption(title: tr("🔽 下移一位 (降低优先级)", "🔽 Move Down (Lower Priority)"),
                                subtitle: curIdx == config.profiles.count - 1 ? tr("(当前已是最低优先级)", "(Already at lowest priority)") : nil),
                SelectionOption(title: tr("↩ 取消", "↩ Cancel"), subtitle: nil)
            ]
            guard let act = promptInteractiveRadio(
                title: tr("请选择移动方向：", "Select move direction:"),
                options: actionOptions,
                defaultIndex: 0
            ) else {
                continue
            }
            if act == 0 {
                if curIdx > 0 {
                    config.profiles.swapAt(curIdx, curIdx - 1)
                    saveConfig(config)
                    print(tr("✓ 策略 '\(config.profiles[curIdx - 1].id)' 优先级已上移。", "✓ Profile priority moved up."))
                    pauseForUser()
                } else {
                    print(tr("该策略已经是最高优先级，无法上移。", "Already at highest priority."))
                    pauseForUser()
                }
            } else if act == 1 {
                if curIdx < config.profiles.count - 1 {
                    config.profiles.swapAt(curIdx, curIdx + 1)
                    saveConfig(config)
                    print(tr("✓ 策略 '\(config.profiles[curIdx + 1].id)' 优先级已下移。", "✓ Profile priority moved down."))
                    pauseForUser()
                } else {
                    print(tr("该策略已经是最低优先级，无法下移。", "Already at lowest priority."))
                    pauseForUser()
                }
            }

        case 1:
            // 新建网络策略向导
            let typeOptions = [
                SelectionOption(title: tr("🏠 本地物理局域网 (基于物理网关 MAC 指纹)", "🏠 Local LAN (Based on Gateway MAC)"),
                                subtitle: tr("高带宽直连，适用于家庭、办公室、工作室有线或 Wi-Fi", "High-speed direct LAN for home, office, etc.")),
                SelectionOption(title: tr("🌐 远程互联/异地专网 (基于主机连通探测)", "🌐 Remote Network (Based on Host Reachability)"),
                                subtitle: tr("适用于 Tailscale、WireGuard、公网 DDNS 动态域名等", "For Tailscale, WireGuard, DDNS, public IP, etc.")),
                SelectionOption(title: tr("↩ 取消", "↩ Cancel"), subtitle: nil)
            ]
            guard let typeSel = promptInteractiveRadio(
                title: tr("\n请选择要创建的策略类型：", "\nSelect profile type to create:"),
                options: typeOptions,
                defaultIndex: 0
            ), typeSel < 2 else {
                continue
            }

            if typeSel == 0 {
                // 创建局域网策略
                print(tr("\n请输入新策略的标识 ID (英文唯一代号，例如 office_lan): ",
                         "\nEnter unique profile ID (e.g. office_lan): "), terminator: "")
                guard let pId = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !pId.isEmpty else { continue }
                if config.profiles.contains(where: { $0.id == pId }) {
                    print(tr("✗ 策略 ID '\(pId)' 已存在，请使用其他名称。", "✗ Profile ID '\(pId)' already exists."))
                    pauseForUser()
                    continue
                }
                print(tr("请输入策略描述信息 (例如 办公室局域网高速直连): ",
                         "Enter profile description (e.g. Office LAN High-Speed): "), terminator: "")
                let pDesc = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)

                var macVal = ""
                if let detected = getCurrentNetworkFingerprint() {
                    print(tr("自动探测到当前网关 MAC: \(detected)", "Detected current gateway MAC: \(detected)"))
                    print(tr("按回车直接使用，或输入自定义 MAC 覆盖 [默认: \(detected)]: ",
                             "Press Enter to use, or enter custom MAC [Default: \(detected)]: "), terminator: "")
                    let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    macVal = input.isEmpty ? detected : input
                } else {
                    print(tr("未能自动获取当前网关 MAC，请输入: ", "Failed to detect gateway MAC. Please enter: "), terminator: "")
                    macVal = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                }
                guard !macVal.isEmpty else { continue }

                let newProfile = NetworkProfile(
                    id: pId,
                    description: pDesc?.isEmpty ?? true ? tr("本地局域网", "Local LAN") : pDesc,
                    match: MatchRule(type: "gateway_mac", value: macVal, retryCount: nil, retryInterval: nil),
                    excludeGatewayIPs: nil,
                    preventSpotlightIndex: true,
                    targets: []
                )
                // 物理局域网策略默认建议插在所有远程探测策略之前，确保物理高速直连优先
                let firstRemoteIdx = config.profiles.firstIndex(where: { $0.match.type == "probe_host" }) ?? config.profiles.count
                config.profiles.insert(newProfile, at: firstRemoteIdx)
                saveConfig(config)
                print(tr("✓ 策略 '\(pId)' 已创建并插入至第 \(firstRemoteIdx + 1) 优先级 (优先于远程策略)。",
                         "✓ Profile '\(pId)' created at priority \(firstRemoteIdx + 1)."))
                pauseForUser()

            } else {
                // 创建远程策略
                print(tr("\n请输入新策略的标识 ID (例如 remote_nas2): ",
                         "\nEnter unique profile ID (e.g. remote_nas2): "), terminator: "")
                guard let pId = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !pId.isEmpty else { continue }
                if config.profiles.contains(where: { $0.id == pId }) {
                    print(tr("✗ 策略 ID '\(pId)' 已存在，请使用其他名称。", "✗ Profile ID '\(pId)' already exists."))
                    pauseForUser()
                    continue
                }
                print(tr("请输入策略描述信息 (例如 异地 NAS 备份): ",
                         "Enter profile description (e.g. Remote Backup NAS): "), terminator: "")
                let pDesc = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)

                let peers = discoverTailscalePeers()
                var hostOptions: [SelectionOption] = []
                for p in peers {
                    hostOptions.append(SelectionOption(
                        title: tr("Tailscale 设备: \(p.name)", "Tailscale Device: \(p.name)"),
                        subtitle: tr("MagicDNS: \(p.magicDNS ?? "无"), IP: \(p.ip)", "MagicDNS: \(p.magicDNS ?? "None"), IP: \(p.ip)")
                    ))
                }
                hostOptions.append(SelectionOption(title: tr("手动输入远程主机名 / DDNS 域名 / IP", "Manual Hostname / DDNS / IP"), subtitle: nil))
                hostOptions.append(SelectionOption(title: tr("↩ 取消", "↩ Cancel"), subtitle: nil))

                guard let hSel = promptInteractiveRadio(
                    title: tr("请选择远程主机接入方式：", "Select remote host connection:"),
                    options: hostOptions,
                    defaultIndex: 0
                ), hSel < hostOptions.count - 1 else {
                    continue
                }

                var chosenHost = ""
                if hSel < peers.count {
                    let p = peers[hSel]
                    chosenHost = p.magicDNS ?? p.ip
                } else {
                    print(tr("请输入远程主机名、DDNS 动态域名或 IP: ", "Enter remote hostname, DDNS, or IP: "), terminator: "")
                    chosenHost = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                }
                guard !chosenHost.isEmpty else { continue }

                let newProfile = NetworkProfile(
                    id: pId,
                    description: pDesc?.isEmpty ?? true ? tr("远程互联", "Remote Network") : pDesc,
                    match: MatchRule(type: "probe_host", value: chosenHost, retryCount: 3, retryInterval: 1.0),
                    excludeGatewayIPs: promptExcludedGateways(),
                    preventSpotlightIndex: true,
                    targets: []
                )
                config.profiles.append(newProfile)
                saveConfig(config)
                print(tr("✓ 远程策略 '\(pId)' 已成功创建并追加至策略流水线末尾。",
                         "✓ Remote profile '\(pId)' created and appended to pipeline."))
                pauseForUser()
            }

        case 2:
            // 编辑策略触发条件与属性 (Task 3: 连带迁移 targets)
            let editProfiles = config.profiles.enumerated().map {
                SelectionOption(title: "[\($0 + 1)] \($1.id) (\($1.description ?? tr("无描述", "No description")))",
                                subtitle: "\($1.match.type) = \($1.match.value)")
            }
            guard let eIdx = promptInteractiveRadio(
                title: tr("\n请选择要编辑的策略：", "\nSelect profile to edit:"),
                options: editProfiles,
                defaultIndex: 0
            ) else {
                continue
            }

            let curP = config.profiles[eIdx]
            let curPrevent = curP.preventSpotlightIndex ?? true
            let preventSub = curPrevent ? tr("当前: 开启防索引", "Current: Indexing Prevented") : tr("当前: 允许索引", "Current: Indexing Allowed")
            let currentExclusions = curP.excludeGatewayIPs?.joined(separator: ", ") ?? tr("无", "None")
            let attrOptions = [
                SelectionOption(title: tr("修改策略描述名称", "Edit Profile Description"), subtitle: curP.description ?? tr("无描述", "No description")),
                SelectionOption(title: tr("更新匹配规则值 (网关 MAC / 探测主机)", "Update Match Value (Gateway MAC / Probe Host)"), subtitle: "\(curP.match.type) = \(curP.match.value)"),
                SelectionOption(title: tr("切换 Spotlight 防索引开关", "Toggle Prevent Spotlight Index"), subtitle: preventSub),
                SelectionOption(title: tr("编辑排除网关 IP 列表", "Edit Excluded Gateway IPs"), subtitle: currentExclusions),
                SelectionOption(title: tr("↩ 返回", "↩ Back"), subtitle: nil)
            ]
            guard let aSel = promptInteractiveRadio(
                title: tr("请选择要修改的属性：", "Select property to edit:"),
                options: attrOptions,
                defaultIndex: 0
            ) else {
                continue
            }

            if aSel == 0 {
                print(tr("请输入新的描述名称 [原值: \(curP.description ?? "")]: ",
                         "Enter new description [Current: \(curP.description ?? "")]: "), terminator: "")
                let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !input.isEmpty {
                    config.profiles[eIdx].description = input
                    saveConfig(config)
                    print(tr("✓ 描述已更新。", "✓ Description updated."))
                    pauseForUser()
                }
            } else if aSel == 1 {
                if curP.match.type == "gateway_mac" {
                    if let curMAC = getCurrentNetworkFingerprint() {
                        print(tr("自动探测到当前网关 MAC: \(curMAC)", "Detected current gateway MAC: \(curMAC)"))
                        print(tr("按回车采纳，或输入自定义 MAC 覆盖 [默认: \(curMAC)]: ",
                                 "Press Enter to accept, or enter custom MAC [Default: \(curMAC)]: "), terminator: "")
                        let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        config.profiles[eIdx].match.value = input.isEmpty ? curMAC : input
                    } else {
                        print(tr("请输入网关 MAC [当前: \(curP.match.value)]: ",
                                 "Enter gateway MAC [Current: \(curP.match.value)]: "), terminator: "")
                        let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if !input.isEmpty { config.profiles[eIdx].match.value = input }
                    }
                    saveConfig(config)
                    print(tr("✓ 网关 MAC 已更新为: \(config.profiles[eIdx].match.value)",
                             "✓ Gateway MAC updated to: \(config.profiles[eIdx].match.value)"))
                    pauseForUser()
                } else if curP.match.type == "probe_host" {
                    let oldHost = curP.match.value
                    print(tr("请输入新的远程主机名、DDNS 域名或 IP [当前: \(oldHost)]: ",
                             "Enter new remote host, DDNS, or IP [Current: \(oldHost)]: "), terminator: "")
                    let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !input.isEmpty && input != oldHost {
                        let newHost = input
                        config.profiles[eIdx].match.value = newHost

                        // Task 3 核心修复：检查已有 targets 是否包含 oldHost 并提供平滑迁移
                        let affectedTargets = curP.targets.filter { $0.url.contains(oldHost) }
                        if !affectedTargets.isEmpty {
                            let migrateOptions = [
                                SelectionOption(title: tr("自动将已有的 \(affectedTargets.count) 个挂载目标地址更新为新主机 (推荐)",
                                                          "Automatically update \(affectedTargets.count) targets to new host (Recommended)"),
                                                subtitle: tr("平滑替换 SMB URL 中的旧主机名，防止断连失效", "Replace old host in URLs smoothly to avoid broken mounts")),
                                SelectionOption(title: tr("保持已有目标地址不变", "Keep existing target URLs unchanged"), subtitle: nil),
                                SelectionOption(title: tr("清空该策略下的已有挂载目标", "Clear all existing targets in this profile"), subtitle: nil)
                            ]
                            let mSel = promptInteractiveRadio(
                                title: tr("检测到该策略下有挂载目标指向旧主机 (\(oldHost))，请选择处理方式：",
                                          "Discovered targets pointing to old host (\(oldHost)). Select action:"),
                                options: migrateOptions,
                                defaultIndex: 0
                            ) ?? 0

                            if mSel == 0 {
                                for tI in 0..<config.profiles[eIdx].targets.count {
                                    if config.profiles[eIdx].targets[tI].url.contains(oldHost) {
                                        config.profiles[eIdx].targets[tI].url = config.profiles[eIdx].targets[tI].url.replacingOccurrences(of: oldHost, with: newHost)
                                    }
                                }
                                print(tr("✓ 已将 \(affectedTargets.count) 个挂载目标地址平滑迁移至新主机 \(newHost)。",
                                         "✓ Successfully migrated \(affectedTargets.count) targets to \(newHost)."))
                            } else if mSel == 2 {
                                config.profiles[eIdx].targets.removeAll()
                                print(tr("✓ 已清空该策略下的所有挂载目标。", "✓ Cleared all targets in this profile."))
                            }
                        }
                        saveConfig(config)
                        print(tr("✓ 远程探测目标已更新为: \(newHost)", "✓ Remote probe host updated to: \(newHost)"))
                        pauseForUser()
                    }
                }
            } else if aSel == 2 {
                let cur = config.profiles[eIdx].preventSpotlightIndex ?? true
                config.profiles[eIdx].preventSpotlightIndex = !cur
                saveConfig(config)
                let stateStr = (!cur) ? tr("开启防索引", "Prevent Indexing Enabled") : tr("允许索引", "Indexing Allowed")
                print(tr("✓ Spotlight 防索引已更新为: \(stateStr)", "✓ Prevent Spotlight Index updated to: \(stateStr)"))
                pauseForUser()
            } else if aSel == 3 {
                config.profiles[eIdx].excludeGatewayIPs = promptExcludedGateways()
                saveConfig(config)
                print(tr("✓ 排除网关 IP 列表已更新。", "✓ Excluded gateway IP list updated."))
                pauseForUser()
            }

        case 3:
            // 删除网络策略
            if config.profiles.count <= 1 {
                print(tr("\n当前仅剩 1 个策略，系统至少需要保留 1 个策略，不可全部删除。",
                         "\nOnly 1 profile left. At least 1 profile must be retained."))
                pauseForUser()
                continue
            }
            let delOptions = config.profiles.enumerated().map {
                SelectionOption(title: "[\($0 + 1)] \($1.id) (\($1.description ?? tr("无描述", "No description")))",
                                subtitle: tr("含 \($1.targets.count) 个挂载目标", "Contains \($1.targets.count) targets"))
            }
            guard let picked = promptInteractiveCheckbox(
                title: tr("\n请勾选要删除的网络策略 (Space 勾选，Enter 确认，Esc 取消)：",
                          "\nSelect profiles to delete (Space toggle, Enter confirm, Esc cancel):"),
                options: delOptions
            ), !picked.isEmpty else {
                print(tr("已取消删除操作。", "Deletion cancelled."))
                continue
            }

            if picked.count >= config.profiles.count {
                print(tr("✗ 不可全选删除所有策略！系统至少需保留 1 个策略。",
                         "✗ Cannot delete all profiles! At least 1 profile must be retained."))
                pauseForUser()
                continue
            }

            // 二次确认
            let confirmOptions = [
                SelectionOption(title: tr("确认删除选中的 \(picked.count) 个策略 (所含目标将一并移除)",
                                          "Confirm deletion of \(picked.count) profile(s) (Targets will be removed)"), subtitle: nil),
                SelectionOption(title: tr("取消并返回", "Cancel and return"), subtitle: nil)
            ]
            guard let cSel = promptInteractiveRadio(
                title: tr("⚠️ 警告：删除策略将同时清除其名下的所有挂载目标配置，确认继续吗？",
                          "⚠️ Warning: Deleting profiles will also remove their targets. Proceed?"),
                options: confirmOptions,
                defaultIndex: 1
            ), cSel == 0 else {
                print(tr("已取消操作。", "Operation cancelled."))
                continue
            }

            let sorted = picked.sorted(by: >)
            for idx in sorted {
                let removed = config.profiles.remove(at: idx)
                print(tr("  ✓ 已删除策略: '\(removed.id)'", "  ✓ Removed profile: '\(removed.id)'"))
            }
            saveConfig(config)
            print(tr("✓ 配置已保存。", "✓ Configuration saved."))
            pauseForUser()

        default:
            return
        }
    }
}

// MARK: - 守护服务管理模块

func manageDaemonService() {
    while true {
        let status = getLaunchAgentStatusSummary()
        let options = [
            SelectionOption(title: tr("部署 / 重新加载自启动守护服务 (LaunchAgent)", "Deploy / reload LaunchAgent daemon"),
                            subtitle: tr("登录、网络或守护配置变化时运行，并每 60 秒重试", "Run on login, network/config changes, and retry every 60 seconds")),
            SelectionOption(title: tr("查看守护服务运行状态与挂载详情", "View service runtime status and active mount details"),
                            subtitle: tr("打印 launchd 诊断与当前物理网络/挂载点状态", "Print launchd diagnostic, network & mount status")),
            SelectionOption(title: tr("卸载并移除自启动守护服务", "Uninstall and remove LaunchAgent daemon"),
                            subtitle: tr("注销 launchd 服务并清理 plist 描述文件", "Unload service and clean plist description file")),
            SelectionOption(title: tr("↩ 返回上级菜单", "↩ Back to Main Menu"), subtitle: nil)
        ]
        print(tr("\n当前守护服务状态: \(status)", "\nCurrent daemon status: \(status)"))
        guard let sel = promptInteractiveRadio(
            title: tr("请选择守护服务管理操作：", "Select daemon management action:"),
            options: options,
            defaultIndex: 0
        ), sel < 3 else {
            break
        }
        switch sel {
        case 0:
            installLaunchAgent()
            pauseForUser()
        case 1:
            checkServiceStatus()
            pauseForUser()
        case 2:
            uninstallLaunchAgent()
            pauseForUser()
        default:
            break
        }
    }
}

// MARK: - 自动更新设置模块

func manageUpdateChannel(config: inout AutoMountConfig) {
    while true {
        let cur = config.updateChannel ?? "off"
        let options = [
            SelectionOption(title: "off", subtitle: tr("关闭自动更新检查 (纯手动运行 './auto_mount --update')", "Disable auto-checks (Manual update only)")),
            SelectionOption(title: "notify", subtitle: tr("发现新版本时发送系统通知", "Send system notification on new version")),
            SelectionOption(title: "auto", subtitle: tr("发现新版本时在后台自动静默平滑热升级", "Automatically download & upgrade in background")),
            SelectionOption(title: tr("立即检查远端最新版本并升级 (执行 --update)", "Check for updates and upgrade now (execute --update)"), subtitle: nil),
            SelectionOption(title: tr("↩ 返回上级菜单", "↩ Back to Main Menu"), subtitle: nil)
        ]
        var defIdx = 0
        if cur == "notify" { defIdx = 1 } else if cur == "auto" { defIdx = 2 }

        print(tr("\n当前自动更新信道: \(getUpdateChannelDisplay(cur))",
                 "\nCurrent auto-update channel: \(getUpdateChannelDisplay(cur))"))
        guard let sel = promptInteractiveRadio(
            title: tr("请选择更新策略操作：", "Select update policy action:"),
            options: options,
            defaultIndex: defIdx
        ), sel < 4 else {
            break
        }
        if sel == 0 {
            config.updateChannel = "off"
            saveConfig(config)
            print(tr("✓ 自动更新策略已设置为: off", "✓ Auto-update policy set to: off"))
        } else if sel == 1 {
            config.updateChannel = "notify"
            saveConfig(config)
            print(tr("✓ 自动更新策略已设置为: notify", "✓ Auto-update policy set to: notify"))
        } else if sel == 2 {
            config.updateChannel = "auto"
            saveConfig(config)
            print(tr("✓ 自动更新策略已设置为: auto", "✓ Auto-update policy set to: auto"))
        } else if sel == 3 {
            handleManualUpdateCommand()
            pauseForUser()
        }
    }
}

// MARK: - 日常配置维护菜单入口 (--config)

func manageConfiguration() {
    guard let managementConfigURL = prepareManagementConfigURL() else { exit(1) }
    configURLOverride = managementConfigURL
    defer { configURLOverride = nil }

    print(tr("""
    Auto Mount Tool - 日常配置管理 (v\(autoMountVersion))
    ====================================
    """, """
    Auto Mount Tool - Daily Configuration Management (v\(autoMountVersion))
    ======================================================
    """))

    guard var config = loadConfig() else {
        fputs(tr("✗ 配置恢复或迁移失败；未打开管理菜单。\n",
                 "✗ Config recovery or migration failed; the management menu was not opened.\n"), stderr)
        exit(1)
    }
    print(tr("当前配置编辑路径: \(getConfigURL().path)", "Current configuration edit path: \(getConfigURL().path)"))

    while true {
        print(tr("\n当前已配置策略流水线 (自顶向下顺序评估，首次命中即执行)：",
                 "\nCurrently configured profile pipeline (Evaluated top-to-bottom, first match wins):"))
        for (i, p) in config.profiles.enumerated() {
            let typeLabel = p.match.type == "gateway_mac" ? tr("局域网", "LAN") : tr("远程", "Remote")
            let descStr = p.description ?? tr("无描述", "No description")
            if p.targets.isEmpty {
                print(tr("  [\(i + 1)] [\(typeLabel)] \(p.id) (\(descStr)) - 0 个挂载目标 (命中后结束策略评估)",
                         "  [\(i + 1)] [\(typeLabel)] \(p.id) (\(descStr)) - 0 targets (a match ends profile evaluation)"))
            } else {
                print(tr("  [\(i + 1)] [\(typeLabel)] \(p.id) (\(descStr)) - \(p.targets.count) 个挂载目标",
                         "  [\(i + 1)] [\(typeLabel)] \(p.id) (\(descStr)) - \(p.targets.count) mount targets"))
                for t in p.targets {
                    print("      • \(t.mountPath) <- \(redactedSMBURL(t.url))")
                }
            }
        }

        let daemonSummary = getLaunchAgentStatusSummary()
        let curChannel = config.updateChannel ?? "off"
        let channelDisplay = getUpdateChannelDisplay(curChannel)

        print(tr("""

        软件版本: v\(autoMountVersion) | 自动更新信道: \(channelDisplay)
        后台守护服务状态: \(daemonSummary)
        """, """

        Software Version: v\(autoMountVersion) | Auto-Update Channel: \(channelDisplay)
        Background Daemon Status: \(daemonSummary)
        """))

        let mainOptions: [SelectionOption] = [
            SelectionOption(title: tr("📁 挂载目标管理", "📁 Mount Target Management"),
                            subtitle: tr("批量导入活动挂载、手动添加目标、批量勾选删除", "Batch import active mounts, manual add, batch delete")),
            SelectionOption(title: tr("🚦 网络策略管理", "🚦 Network Profile Pipeline"),
                            subtitle: tr("调整优先级顺序、新建策略、修改触发规则、删除策略", "Adjust priority pipeline, create profile, edit rules, delete")),
            SelectionOption(title: tr("⚙️ 守护服务管理", "⚙️ Background Daemon Management"),
                            subtitle: tr("部署自启动守护、查看详细运行状态、卸载服务", "Deploy LaunchAgent, view runtime status, uninstall")),
            SelectionOption(title: tr("🔄 自动更新设置", "🔄 Auto-Update Settings"),
                            subtitle: tr("切换自动更新策略、立即检查并升级", "Switch update channel, check & upgrade now")),
            SelectionOption(title: tr("🚪 退出配置管理", "🚪 Exit Configuration Management"), subtitle: nil)
        ]

        guard let sel = promptInteractiveRadio(
            title: tr("请选择操作模块：", "Select module:"),
            options: mainOptions,
            defaultIndex: 0
        ) else {
            // 按 Esc 或 Ctrl+C
            print(tr("✓ 已退出配置管理。", "✓ Exited configuration management."))
            break
        }

        switch sel {
        case 0:
            manageMountTargets(config: &config)
        case 1:
            manageNetworkProfiles(config: &config)
        case 2:
            manageDaemonService()
        case 3:
            manageUpdateChannel(config: &config)
        default:
            print(tr("✓ 已退出配置管理。", "✓ Exited configuration management."))
            return
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

func atomicCopyFile(from sourceURL: URL, to destinationURL: URL, permissions: Int) throws {
    let data = try Data(contentsOf: sourceURL)
    try atomicWrite(data, to: destinationURL, permissions: permissions)
}

struct StagedFileReplacement {
    let sourceURL: URL
    let destinationURL: URL
    let permissions: Int
}

func replaceFilesTransactionally(
    _ replacements: [StagedFileReplacement],
    afterReplacement: (() throws -> Void)? = nil
) throws {
    struct Snapshot {
        let url: URL
        let contents: Data?
        let permissions: Int
    }

    var seenPaths = Set<String>()
    var snapshots: [Snapshot] = []
    for replacement in replacements {
        let path = replacement.destinationURL.standardizedFileURL.path
        guard seenPaths.insert(path).inserted else {
            throw NSError(domain: "AutoMountUpdate", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "A destination was listed more than once: \(path)"])
        }
        if FileManager.default.fileExists(atPath: path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? replacement.permissions
            snapshots.append(Snapshot(url: replacement.destinationURL,
                                      contents: try Data(contentsOf: replacement.destinationURL),
                                      permissions: permissions))
        } else {
            snapshots.append(Snapshot(url: replacement.destinationURL, contents: nil,
                                      permissions: replacement.permissions))
        }
    }

    var appliedCount = 0
    func rollbackAppliedFiles() -> [String] {
        var rollbackFailures: [String] = []
        for snapshot in snapshots.prefix(appliedCount).reversed() {
            do {
                if let contents = snapshot.contents {
                    try atomicWrite(contents, to: snapshot.url, permissions: snapshot.permissions)
                } else {
                    try FileManager.default.removeItem(at: snapshot.url)
                }
            } catch {
                rollbackFailures.append("\(snapshot.url.path): \(error.localizedDescription)")
            }
        }
        return rollbackFailures
    }

    do {
        for replacement in replacements {
            try atomicCopyFile(from: replacement.sourceURL,
                               to: replacement.destinationURL,
                               permissions: replacement.permissions)
            appliedCount += 1
        }
        try afterReplacement?()
    } catch {
        let rollbackFailures = rollbackAppliedFiles()
        let rollbackMessage = rollbackFailures.isEmpty
            ? ""
            : " Rollback also failed for: \(rollbackFailures.joined(separator: "; "))"
        throw NSError(domain: "AutoMountUpdate", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "\(error.localizedDescription).\(rollbackMessage)"])
    }
}

func launchAgentProgramArguments(binaryURL: URL, sourceURL: URL, preferSource: Bool = true) -> [String] {
    if preferSource, FileManager.default.isExecutableFile(atPath: "/usr/bin/swift") {
        return ["/usr/bin/swift", sourceURL.path]
    }
    return [binaryURL.path]
}

enum InstallConfigLocation: Equatable {
    case workspace
    case runtime
}

enum InstallConfigResolution: Equatable {
    case selected(InstallConfigLocation)
    case diverged
    case repairRuntimeFromWorkspace
    case initialize
    case unavailable(InstallConfigLocation)
    case futureVersion(InstallConfigLocation, String)
    case inaccessible(InstallConfigLocation)
}

enum ManagementConfigResolution: Equatable {
    case selected(InstallConfigLocation)
    case recover(target: InstallConfigLocation, source: InstallConfigLocation)
    case initialize
    case futureVersion(InstallConfigLocation, String)
    case inaccessible(InstallConfigLocation)
}

enum InitConfigResolution: Equatable {
    case preserve(InstallConfigLocation)
    case diverged
    case initialize
    case futureVersion(InstallConfigLocation, String)
    case inaccessible(InstallConfigLocation)
}

func resolveInitConfigState(
    resetExistingConfig: Bool,
    workspaceState: ConfigFileState,
    runtimeState: ConfigFileState,
    documentsEquivalent: Bool
) -> InitConfigResolution {
    if resetExistingConfig {
        if workspaceState == .inaccessible { return .inaccessible(.workspace) }
        if runtimeState == .inaccessible { return .inaccessible(.runtime) }
        return .initialize
    }
    if !resetExistingConfig, case let .futureVersion(version) = runtimeState {
        return .futureVersion(.runtime, version)
    }
    if !resetExistingConfig, case let .futureVersion(version) = workspaceState {
        return .futureVersion(.workspace, version)
    }
    if workspaceState == .inaccessible { return .inaccessible(.workspace) }
    if runtimeState == .inaccessible { return .inaccessible(.runtime) }
    if workspaceState == .usable, runtimeState == .usable,
       !documentsEquivalent {
        return .diverged
    }
    if workspaceState == .usable { return .preserve(.workspace) }
    if runtimeState == .usable { return .preserve(.runtime) }
    return .initialize
}

func installConfigIsUsable(at url: URL) -> Bool {
    inspectConfigFile(at: url).state == .usable
}

func installConfigModelsAreEquivalent(_ lhsConfig: AutoMountConfig, _ rhsConfig: AutoMountConfig) -> Bool {
    var lhs = lhsConfig
    var rhs = rhsConfig
    lhs.version = ""
    rhs.version = ""
    lhs.lastUpdateCheckTimestamp = nil
    rhs.lastUpdateCheckTimestamp = nil
    lhs.updateRetryAfterTimestamp = nil
    rhs.updateRetryAfterTimestamp = nil
    lhs.lastNotifiedVersion = nil
    rhs.lastNotifiedVersion = nil
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let lhsData = try? encoder.encode(lhs), let rhsData = try? encoder.encode(rhs) else { return false }
    return lhsData == rhsData
}

func installConfigDocumentsAreEquivalent(_ lhsURL: URL, _ rhsURL: URL) -> Bool {
    guard let lhs = loadConfig(from: lhsURL, migrate: false),
          let rhs = loadConfig(from: rhsURL, migrate: false) else { return false }
    return installConfigModelsAreEquivalent(lhs, rhs)
}

func resolveManagementConfigLocation(
    launchAgentInstalled: Bool,
    workspaceState: ConfigFileState,
    runtimeState: ConfigFileState
) -> ManagementConfigResolution {
    let activeLocation: InstallConfigLocation = launchAgentInstalled ? .runtime : .workspace
    let fallbackLocation: InstallConfigLocation = launchAgentInstalled ? .workspace : .runtime
    let activeState = launchAgentInstalled ? runtimeState : workspaceState
    let fallbackState = launchAgentInstalled ? workspaceState : runtimeState

    switch activeState {
    case .usable:
        return .selected(activeLocation)
    case let .futureVersion(version):
        return .futureVersion(activeLocation, version)
    case .inaccessible:
        return .inaccessible(activeLocation)
    case .missing, .invalid:
        switch fallbackState {
        case .usable:
            return .recover(target: activeLocation, source: fallbackLocation)
        case let .futureVersion(version):
            return .futureVersion(fallbackLocation, version)
        case .inaccessible:
            return .inaccessible(fallbackLocation)
        case .missing, .invalid:
            return .initialize
        }
    }
}

func resolveInstallConfigLocation(
    requested: InstallConfigLocation?,
    workspaceState: ConfigFileState,
    runtimeState: ConfigFileState,
    documentsEquivalent: Bool
) -> InstallConfigResolution {
    if let requested {
        let requestedState = requested == .workspace ? workspaceState : runtimeState
        if requested == .workspace, runtimeState == .inaccessible {
            return .inaccessible(.runtime)
        }
        switch requestedState {
        case .usable:
            return .selected(requested)
        case let .futureVersion(version):
            return .futureVersion(requested, version)
        case .inaccessible:
            return .inaccessible(requested)
        case .missing, .invalid:
            return .unavailable(requested)
        }
    }

    switch runtimeState {
    case let .futureVersion(version):
        return .futureVersion(.runtime, version)
    case .inaccessible:
        return .inaccessible(.runtime)
    case .usable:
        if workspaceState == .usable {
            return documentsEquivalent ? .selected(.runtime) : .diverged
        }
        return .selected(.runtime)
    case .missing, .invalid:
        switch workspaceState {
        case .usable:
            return runtimeState == .invalid ? .repairRuntimeFromWorkspace : .selected(.workspace)
        case let .futureVersion(version):
            return .futureVersion(.workspace, version)
        case .inaccessible:
            return .inaccessible(.workspace)
        case .missing, .invalid:
            return .initialize
        }
    }
}

func printConfigRecoveryFailure(_ resolution: InstallConfigResolution) {
    let message: String
    switch resolution {
    case .futureVersion(let location, let version):
        let source = location == .runtime ? tr("守护", "daemon") : tr("工作区", "workspace")
        message = tr("✗ \(source)配置版本 v\(version) 高于当前程序 v\(autoMountVersion)；为避免降级破坏配置，未覆盖任何文件。请先升级工作区程序，或显式选择一个当前程序可读取的配置来源。\n",
                     "✗ The \(source) config v\(version) is newer than program v\(autoMountVersion); no files were replaced. Update the workspace program or explicitly select a config source supported by this program.\n")
    case .inaccessible(let location):
        let source = location == .runtime ? tr("守护", "daemon") : tr("工作区", "workspace")
        message = tr("✗ \(source)配置无法安全读取或备份；未修改文件，也未注册服务。\n",
                     "✗ The \(source) config cannot be safely read or backed up; no files were changed and no service was registered.\n")
    case .unavailable(.runtime):
        message = tr("✗ 请求使用的守护配置不存在或无效。\n", "✗ The requested daemon config is missing or invalid.\n")
    case .unavailable(.workspace):
        message = tr("✗ 请求使用的工作区配置不存在或无效。\n", "✗ The requested workspace config is missing or invalid.\n")
    default:
        message = tr("✗ 没有可迁移的有效配置。\n", "✗ No usable, migratable config is available.\n")
    }
    fputs(message, stderr)
}

func promptForInstallConfigLocation() -> InstallConfigLocation? {
    print(tr("工作区配置与已安装的守护配置内容不同。默认保留守护配置。",
             "Workspace and installed daemon configs differ. Keeping the daemon config is the default."))
    print(tr("  1) 保留守护配置（推荐）\n  2) 用工作区配置覆盖守护配置\n  3) 取消安装",
             "  1) Keep daemon config (recommended)\n  2) Replace it with workspace config\n  3) Cancel installation"))
    while true {
        print(tr("请选择 [1]: ", "Choose [1]: "), terminator: "")
        guard let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) else { return .runtime }
        switch input {
        case "", "1": return .runtime
        case "2": return .workspace
        case "3": return nil
        default: print(tr("请输入 1、2 或 3。", "Enter 1, 2, or 3."))
        }
    }
}

func installLaunchAgent(requestedConfigLocation: InstallConfigLocation? = nil) {
    print(tr("""
    Auto Mount Tool - 安装并启用自启动守护服务
    ===========================================
    """, """
    Auto Mount Tool - Install LaunchAgent Daemon
    ============================================
    """))

    let currentAppDir = getAppDir()
    let installDir = getInstalledDir()
    let plistURL = getLaunchAgentPlistURL()
    let launchAgentsDir = plistURL.deletingLastPathComponent()

    let sourceURL = currentAppDir.appendingPathComponent("auto_mount.swift")
    let sourceConfigURL = getWorkspaceConfigURL()
    let installedBinaryURL = installDir.appendingPathComponent("auto_mount")
    let installedSourceURL = installDir.appendingPathComponent("auto_mount.swift")
    let installedConfigURL = installDir.appendingPathComponent("auto_mount.plist")
    var workspace = inspectConfigFile(at: sourceConfigURL)
    var runtime = inspectConfigFile(at: installedConfigURL)
    var configsEquivalent = workspace.state == .usable && runtime.state == .usable
        && workspace.config.map { workspaceConfig in
            runtime.config.map { installConfigModelsAreEquivalent(workspaceConfig, $0) } ?? false
        } == true
    var resolution = resolveInstallConfigLocation(
        requested: requestedConfigLocation,
        workspaceState: workspace.state,
        runtimeState: runtime.state,
        documentsEquivalent: configsEquivalent
    )

    if resolution == .initialize {
        guard isatty(STDIN_FILENO) == 1 else {
            fputs(tr("✗ 工作区和守护目录都没有可用配置；请在交互式 Terminal 中运行 `./auto_mount --install` 并完成配置向导。未注册服务。\n",
                     "✗ Neither workspace nor daemon directory has a usable config. Run `./auto_mount --install` in an interactive Terminal to complete setup. No service was registered.\n"), stderr)
            writeLog("Install stopped before service registration because setup requires an interactive terminal")
            exit(1)
        }
        guard runInitWizard(offerServiceInstallation: false) else {
            fputs(tr("✗ 配置向导未能保存有效配置；未注册服务。\n",
                     "✗ The setup wizard did not save a usable config; no service was registered.\n"), stderr)
            exit(1)
        }
        workspace = inspectConfigFile(at: sourceConfigURL)
        runtime = inspectConfigFile(at: installedConfigURL)
        configsEquivalent = workspace.state == .usable && runtime.state == .usable
            && workspace.config.map { workspaceConfig in
                runtime.config.map { installConfigModelsAreEquivalent(workspaceConfig, $0) } ?? false
            } == true
        resolution = resolveInstallConfigLocation(
            requested: requestedConfigLocation,
            workspaceState: workspace.state,
            runtimeState: runtime.state,
            documentsEquivalent: configsEquivalent
        )
    }

    if resolution == .repairRuntimeFromWorkspace {
        print(tr("⚠ 守护配置内容无效；将先备份它，再从有效工作区配置恢复。",
                 "⚠ The daemon config is invalid; it will be backed up and restored from the usable workspace config."))
        writeLog("Install will recover the invalid runtime config from the usable workspace config")
        resolution = .selected(.workspace)
    }
    if resolution == .diverged {
        if isatty(STDIN_FILENO) == 1 {
            guard let choice = promptForInstallConfigLocation() else {
                print(tr("安装已取消；现有文件和守护服务均未更改。", "Installation cancelled; existing files and daemon were not changed."))
                exit(0)
            }
            resolution = .selected(choice)
        } else {
            print(tr("⚠ 工作区与守护配置不同；本次非交互安装保留守护配置。若要用工作区覆盖，请运行 './auto_mount --install --config-source workspace'。",
                     "⚠ Workspace and daemon configs differ; this non-interactive install keeps the daemon config. To replace it, run './auto_mount --install --config-source workspace'."))
            resolution = .selected(.runtime)
        }
    }
    guard case let .selected(configLocation) = resolution else {
        printConfigRecoveryFailure(resolution)
        writeLog("Install aborted because no usable requested config source was available: \(resolution)")
        exit(1)
    }
    let configSourceURL = configLocation == .workspace ? sourceConfigURL : installedConfigURL
    let configSourceInspection = configLocation == .workspace ? workspace : runtime
    guard configSourceInspection.state == .usable, let configSourceContents = configSourceInspection.contents else {
        fputs(tr("✗ 选中的配置来源在安装前已不可用；未注册或重载服务。\n",
                 "✗ The selected config source is no longer usable; the service was not registered or reloaded.\n"), stderr)
        exit(1)
    }
    let runtimeConfigExists = runtime.state != .missing
    let workspaceConfigExists = workspace.state != .missing
    let workspaceConfigUsable = workspace.state == .usable
    let shouldSeedRuntimeConfig = runtime.state == .missing
    let runtimeConfigWillBeReplaced = configLocation == .workspace
        && runtime.contents != workspace.contents
    if configLocation == .workspace && runtimeConfigExists && runtimeConfigWillBeReplaced {
        print(tr("⚠ 本次将用工作区配置更新守护配置，并先备份现有守护配置。",
                 "⚠ This install will replace the daemon config from the workspace after backing up the existing daemon config."))
        writeLog("Install explicitly selected workspace config to replace the runtime daemon config")
    } else if configLocation == .runtime && workspaceConfigExists && !workspaceConfigUsable {
        print(tr("⚠ 工作区配置无效或版本较新；本次保留有效的守护配置。", "⚠ Workspace config is invalid or newer; preserving the usable daemon config."))
    }

    do {
        try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true, attributes: nil)
        try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true, attributes: nil)
    } catch {
        fputs(tr("✗ 创建目录失败: \(error.localizedDescription)\n", "✗ Failed to create directory: \(error.localizedDescription)\n"), stderr)
        exit(1)
    }

    let stagedBinaryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("automount-install-\(UUID().uuidString)")
    let stagedConfigURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("automount-install-config-\(UUID().uuidString).plist")
    let stagedPlistURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("automount-install-launchagent-\(UUID().uuidString).plist")
    defer { try? FileManager.default.removeItem(at: stagedBinaryURL) }
    defer { try? FileManager.default.removeItem(at: stagedConfigURL) }
    defer { try? FileManager.default.removeItem(at: stagedPlistURL) }

    let sourceExists = FileManager.default.fileExists(atPath: sourceURL.path)
    let currentBinaryURL = currentAppDir.appendingPathComponent("auto_mount")
    if sourceExists {
        let compile = compileOptimizedSwiftSource(sourceURL: sourceURL, outputURL: stagedBinaryURL)
        guard compile.status == 0 else {
            fputs(tr("✗ 当前 Swift 源码编译失败，旧运行程序未覆盖。\n", "✗ Swift source compilation failed; the old executable was not replaced.\n"), stderr)
            fputs(compile.stderr, stderr)
            writeLog("Install aborted because source compilation failed: \(compile.stderr)")
            exit(1)
        }
    } else if !FileManager.default.isExecutableFile(atPath: currentBinaryURL.path) {
        fputs(tr("✗ 找不到 Swift 源码或可执行程序，无法安装守护服务。\n",
                 "✗ No Swift source or executable is available to install the daemon.\n"), stderr)
        writeLog("Install aborted because neither Swift source nor executable was available")
        exit(1)
    }

    do {
        try atomicWrite(configSourceContents, to: stagedConfigURL, permissions: 0o600)
    } catch {
        fputs(tr("✗ 无法暂存守护配置，现有文件未更改: \(error.localizedDescription)\n",
                 "✗ Could not stage daemon config; existing files were not changed: \(error.localizedDescription)\n"), stderr)
        writeLog("Install aborted while staging config: \(error.localizedDescription)")
        exit(1)
    }

    let migrationExecutable = sourceExists ? stagedBinaryURL : currentBinaryURL
    let migration = runCommand(
        executable: migrationExecutable.path,
        arguments: ["--migrate-only", stagedConfigURL.path]
    )
    guard migration.status == 0 else {
        fputs(tr("✗ 配置迁移失败，已安装文件和现有配置未更改: \(migration.stderr)",
                 "✗ Config migration failed; installed files and existing config were not changed: \(migration.stderr)"), stderr)
        writeLog("Install aborted because staged config migration failed: \(migration.stderr)")
        exit(1)
    }

    let stagedConfigInspection = inspectConfigFile(at: stagedConfigURL)
    guard stagedConfigInspection.state == .usable, let stagedConfigContents = stagedConfigInspection.contents else {
        fputs(tr("✗ 暂存配置未通过回读验证；已安装文件和守护服务均未更改。\n",
                 "✗ Staged config failed read-back validation; installed files and the daemon were not changed.\n"), stderr)
        writeLog("Install aborted because staged config failed read-back validation")
        exit(1)
    }
    let programArguments = launchAgentProgramArguments(binaryURL: installedBinaryURL,
                                                       sourceURL: installedSourceURL,
                                                       preferSource: sourceExists)
    let plistData: Data
    do {
        let plist: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": programArguments,
            "RunAtLoad": true,
            "StartInterval": 60,
            "WatchPaths": ["/Library/Preferences/SystemConfiguration", installedConfigURL.path],
            "StandardOutPath": "/tmp/\(launchAgentLabel).stdout.log",
            "StandardErrorPath": "/tmp/\(launchAgentLabel).stderr.log"
        ]
        plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try atomicWrite(plistData, to: stagedPlistURL, permissions: 0o644)
    } catch {
        fputs(tr("✗ 无法生成服务描述文件，现有服务未更改: \(error.localizedDescription)\n",
                 "✗ Could not stage LaunchAgent plist; the existing service was not changed: \(error.localizedDescription)\n"), stderr)
        writeLog("Install aborted while staging LaunchAgent plist: \(error.localizedDescription)")
        exit(1)
    }

    var replacements: [StagedFileReplacement] = []
    if sourceExists {
        replacements.append(StagedFileReplacement(sourceURL: sourceURL, destinationURL: installedSourceURL, permissions: 0o755))
        replacements.append(StagedFileReplacement(sourceURL: stagedBinaryURL, destinationURL: installedBinaryURL, permissions: 0o755))
    } else {
        replacements.append(StagedFileReplacement(sourceURL: currentBinaryURL, destinationURL: installedBinaryURL, permissions: 0o755))
    }
    replacements.append(StagedFileReplacement(sourceURL: stagedPlistURL, destinationURL: plistURL, permissions: 0o644))

    let serviceTarget = "gui/\(getuid())/\(launchAgentLabel)"
    let serviceWasLoaded = getLaunchAgentDiagnostic().loaded
    if serviceWasLoaded {
        let stopResult = runCommand(executable: "/bin/launchctl", arguments: ["bootout", serviceTarget])
        if stopResult.status != 0 && getLaunchAgentDiagnostic().loaded {
            fputs(tr("✗ 无法先停止旧服务，已取消覆盖运行文件。\n", "✗ Could not unload the existing service; runtime files were not replaced.\n"), stderr)
            writeLog("Install aborted because existing LaunchAgent could not be unloaded: \(stopResult.stderr)")
            exit(1)
        }
    }

    do {
        let latestSource = inspectConfigFile(at: configSourceURL)
        guard latestSource.state == .usable, latestSource.contents == configSourceContents else {
            throw NSError(domain: "AutoMountInstall", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "The selected config source changed during installation; rerun the command to review the latest config"])
        }
        let latestRuntime = inspectConfigFile(at: installedConfigURL)
        guard latestRuntime.state != .inaccessible else {
            throw NSError(domain: "AutoMountInstall", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "The runtime config cannot be read or backed up safely"])
        }
        let runtimeConfigNeedsReplacement = latestRuntime.contents != stagedConfigContents
        if runtimeConfigNeedsReplacement, latestRuntime.contents != nil {
            guard let backupURL = try backUpConfigFile(latestRuntime) else {
                throw NSError(domain: "AutoMountInstall", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "No readable bytes were available for the runtime config backup"])
            }
            print(tr("✓ 已备份原守护配置: \(backupURL.path)", "✓ Backed up the previous daemon config: \(backupURL.path)"))
            writeLog("Backed up daemon config before replacement to \(backupURL.path)")
        }
        var finalReplacements = replacements
        if runtimeConfigNeedsReplacement {
            finalReplacements.append(StagedFileReplacement(sourceURL: stagedConfigURL,
                                                           destinationURL: installedConfigURL,
                                                           permissions: 0o600))
        }
        try replaceFilesTransactionally(finalReplacements) {
            let uid = getuid()
            let bootResult = runCommand(executable: "/bin/launchctl",
                                        arguments: ["bootstrap", "gui/\(uid)", plistURL.path])
            let loaded = bootResult.status == 0 && getLaunchAgentDiagnostic().loaded
            guard loaded else {
                _ = runCommand(executable: "/bin/launchctl", arguments: ["bootout", serviceTarget])
                let detail = bootResult.stderr.isEmpty
                    ? "launchctl bootstrap did not load the service"
                    : bootResult.stderr
                throw NSError(domain: "AutoMountInstall", code: Int(bootResult.status),
                              userInfo: [NSLocalizedDescriptionKey: detail])
            }
        }
    } catch {
        var restoreMessage = ""
        if serviceWasLoaded {
            let restore = runCommand(executable: "/bin/launchctl",
                                     arguments: ["bootstrap", "gui/\(getuid())", plistURL.path])
            if restore.status != 0 || !getLaunchAgentDiagnostic().loaded {
                restoreMessage = tr("；恢复旧服务也失败: \(restore.stderr)", "; restoring the previous service also failed: \(restore.stderr)")
            }
        }
        fputs(tr("✗ 部署或启动失败，已回滚文件替换尝试: \(error.localizedDescription)\(restoreMessage)\n",
                 "✗ Deployment or launch failed; file rollback was attempted: \(error.localizedDescription)\(restoreMessage)\n"), stderr)
        writeLog("Install failed and file rollback was attempted: \(error.localizedDescription)\(restoreMessage)")
        exit(1)
    }

    if shouldSeedRuntimeConfig {
        print(tr("✓ 已部署编译后的程序，并从工作区初始化守护配置:\n  \(installDir.path)",
                 "✓ Deployed the compiled program and initialized daemon config from the workspace:\n  \(installDir.path)"))
    } else if configLocation == .workspace {
        print(tr("✓ 已部署编译后的程序，并将工作区配置同步到守护目录:\n  \(installedConfigURL.path)",
                 "✓ Deployed the compiled program and synchronized the workspace config to the daemon directory:\n  \(installedConfigURL.path)"))
    } else {
        print(tr("✓ 已部署编译后的程序，并保留现有守护配置内容:\n  \(installedConfigURL.path)",
                 "✓ Deployed the compiled program and preserved existing daemon config settings:\n  \(installedConfigURL.path)"))
        writeLog("Install preserved the existing runtime config at \(installedConfigURL.path)")
    }

    let uid = getuid()
    print(tr("✓ 已生成服务描述文件:\n  \(plistURL.path)", "✓ Generated LaunchAgent plist:\n  \(plistURL.path)"))
    print(tr("✓ 成功注册并加载至系统 launchd 守护进程 (gui/\(uid))",
             "✓ Successfully registered and loaded into system launchd (gui/\(uid))"))
    print(tr("""

        服务详情:
          • 标识 (Label): \(launchAgentLabel)
          • 执行命令: \(programArguments.joined(separator: " "))
          • 触发时机: 登录、网络或守护配置变化及每 60 秒重试
          • 日志路径: /tmp/\(launchAgentLabel).stdout.log

        自启动与网络监听服务已生效。
        """, """

        Service Details:
          • Label: \(launchAgentLabel)
          • Command: \(programArguments.joined(separator: " "))
          • Trigger: Login, network/config changes, and every 60 seconds
          • Log file: /tmp/\(launchAgentLabel).stdout.log

        LaunchAgent is loaded and will evaluate the configured network policy.
        """))
    writeLog("LaunchAgent installed and loaded successfully to \(installDir.path); runtime config: \(installedConfigURL.path)")
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

    let bootResult = runCommand(executable: "/bin/launchctl", arguments: ["bootout", serviceTarget])
    if bootResult.status == 0 {
        print(tr("✓ 成功从系统 launchd 中卸载服务 (\(serviceTarget))",
                 "✓ Unloaded service from system launchd (\(serviceTarget))"))
    }
    if getLaunchAgentDiagnostic().loaded {
        fputs(tr("✗ launchd 仍报告服务已加载；为避免留下失效服务，未删除描述文件或运行目录。\n",
                 "✗ launchd still reports the service as loaded; its plist and runtime directory were preserved.\n"), stderr)
        writeLog("Uninstall aborted because LaunchAgent remains loaded after bootout: \(bootResult.stderr)")
        return
    }
    if bootResult.status != 0 {
        print(tr("• 服务当前已卸载。", "• Service is already unloaded."))
    }

    if FileManager.default.fileExists(atPath: plistURL.path) {
        do {
            try FileManager.default.removeItem(at: plistURL)
            print(tr("✓ 已删除服务描述文件: \(plistURL.path)", "✓ Removed LaunchAgent plist: \(plistURL.path)"))
        } catch {
            fputs(tr("✗ 删除描述文件失败: \(error.localizedDescription)\n",
                     "✗ Failed to remove plist: \(error.localizedDescription)\n"), stderr)
            writeLog("Uninstall stopped because the LaunchAgent plist could not be removed: \(error.localizedDescription)")
            return
        }
    } else {
        print(tr("• 描述文件不存在: \(plistURL.path)", "• Plist file does not exist: \(plistURL.path)"))
    }

    if FileManager.default.fileExists(atPath: installDir.path) {
        do {
            try FileManager.default.removeItem(at: installDir)
            print(tr("✓ 已清理部署运行目录: \(installDir.path)", "✓ Removed runtime directory: \(installDir.path)"))
        } catch {
            fputs(tr("✗ 清理目录失败: \(error.localizedDescription)\n",
                     "✗ Failed to clean directory: \(error.localizedDescription)\n"), stderr)
            writeLog("LaunchAgent plist was removed, but runtime files remain: \(error.localizedDescription)")
            return
        }
    }

    print(tr("\n已确认服务未加载，LaunchAgent 描述文件与运行目录已移除。",
             "\nConfirmed service is unloaded; LaunchAgent plist and runtime directory were removed."))
    writeLog("LaunchAgent uninstalled")
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
    let runtimeConfigURL = installDir.appendingPathComponent("auto_mount.plist")
    let plistExists = FileManager.default.fileExists(atPath: plistURL.path)
    print(tr("  • LaunchAgent 服务配置: \(plistExists ? "已安装 (\(plistURL.path))" : "未安装")",
             "  • LaunchAgent Configuration: \(plistExists ? "Installed (\(plistURL.path))" : "Not Installed")"))
    print(tr("  • 守护运行目录: \(installDir.path)", "  • Runtime Directory: \(installDir.path)"))
    let runtimeConfigExists = FileManager.default.fileExists(atPath: runtimeConfigURL.path)
    print(tr("  • 守护配置来源: \(runtimeConfigExists ? "已安装 (\(runtimeConfigURL.path))" : "缺失 (\(runtimeConfigURL.path))")",
             "  • Runtime Config Source: \(runtimeConfigExists ? "Installed (\(runtimeConfigURL.path))" : "Missing (\(runtimeConfigURL.path))")"))

    let diagnostic = getLaunchAgentDiagnostic()
    if diagnostic.loaded {
        print(tr("  • launchd 注册状态: 已加载 (gui/\(getuid()))",
                 "  • launchd Registration: Loaded (gui/\(getuid()))"))
        print(tr("  • 当前执行状态: \(diagnostic.pid == nil ? "空闲，等待触发" : "正在运行 (pid \(diagnostic.pid!))")",
                 "  • Current Process: \(diagnostic.pid == nil ? "Idle, waiting for a trigger" : "Running (pid \(diagnostic.pid!))")"))
        if let state = diagnostic.state {
            print(tr("  • launchd 状态字段: \(state)", "  • launchd State: \(state)"))
        }
        if let exitCode = diagnostic.lastExitCode {
            print(tr("  • 最近一次运行退出码: \(exitCode)\(exitCode == 0 ? " (成功)" : " (失败)")",
                     "  • Last Run Exit Code: \(exitCode)\(exitCode == 0 ? " (success)" : " (failure)")"))
        }
    } else {
        print(tr("  • launchd 注册状态: 未加载", "  • launchd Registration: Not loaded"))
    }
    if let installedVersion = getInstalledAppVersion() {
        print(tr("  • 守护程序版本: v\(installedVersion)", "  • Runtime Program Version: v\(installedVersion)"))
    } else {
        print(tr("  • 守护程序版本: 无法读取", "  • Runtime Program Version: unavailable"))
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

    print(tr("\n  • 守护服务使用的策略列表:", "\n  • Profiles Used by the LaunchAgent:"))
    if let config = loadConfig(from: runtimeConfigURL, migrate: false) {
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
                    let sourceURL = entry.source.hasPrefix("//") ? "smb:\(entry.source)" : entry.source
                    if smbResourceIdentity(entry.source) == smbResourceIdentity(t.url) {
                        print(tr("          - \(t.mountPath) -> 已挂载且来源匹配 (\(redactedSMBURL(sourceURL)))",
                                 "          - \(t.mountPath) -> Mounted, source matches (\(redactedSMBURL(sourceURL)))"))
                    } else {
                        print(tr("          - \(t.mountPath) -> 已挂载但来源不匹配 (实际: \(redactedSMBURL(sourceURL)))",
                                 "          - \(t.mountPath) -> Mounted from a different source (actual: \(redactedSMBURL(sourceURL)))"))
                    }
                } else {
                    print(tr("          - \(t.mountPath) -> 未挂载 (目标: \(redactedSMBURL(t.url)))",
                             "          - \(t.mountPath) -> Not Mounted (Target: \(redactedSMBURL(t.url)))"))
                }
            }
        }
    } else {
        print(tr("    守护服务配置缺失或无法解析。配置路径: \(runtimeConfigURL.path)",
                 "    Runtime config is missing or invalid. Config path: \(runtimeConfigURL.path)"))
    }

    if let config = loadConfig(from: runtimeConfigURL, migrate: false) {
        let channel = config.updateChannel ?? "off"
        print(tr("\n  • 当前命令程序版本: v\(autoMountVersion) (守护配置更新信道: \(channel))",
                 "\n  • Invoked Program Version: v\(autoMountVersion) (Runtime Config Update Channel: \(channel))"))
    } else {
        print(tr("\n  • 当前命令程序版本: v\(autoMountVersion)", "\n  • Invoked Program Version: v\(autoMountVersion)"))
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
    let clean = versionStr.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let regex = try? NSRegularExpression(pattern: #"^[vV]?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$"#),
          let match = regex.firstMatch(in: clean, range: NSRange(clean.startIndex..., in: clean)),
          match.numberOfRanges == 4 else { return [] }
    var parts: [Int] = []
    for index in 1...3 {
        guard let range = Range(match.range(at: index), in: clean),
              let component = Int(clean[range]) else { return [] }
        parts.append(component)
    }
    return parts
}

func isNewerVersion(_ remote: String, than current: String) -> Bool {
    let rParts = parseSemanticVersion(remote)
    let cParts = parseSemanticVersion(current)
    guard rParts.count == 3, cParts.count == 3 else { return false }
    for i in 0..<3 {
        let r = rParts[i]
        let c = cParts[i]
        if r > c { return true }
        if r < c { return false }
    }
    return false
}

let backgroundUpdateCheckCooldown: TimeInterval = 24 * 60 * 60
let backgroundUpdateRetryDelay: TimeInterval = 15 * 60

func shouldCheckForBackgroundUpdate(config: AutoMountConfig, now: TimeInterval) -> Bool {
    if let retryAfter = config.updateRetryAfterTimestamp, retryAfter.isFinite {
        return now >= retryAfter
    }
    guard let lastCheck = config.lastUpdateCheckTimestamp, lastCheck.isFinite else { return true }
    return now - lastCheck >= backgroundUpdateCheckCooldown
}

func recordBackgroundUpdateFailure(config: inout AutoMountConfig, now: TimeInterval) {
    config.lastUpdateCheckTimestamp = now
    config.updateRetryAfterTimestamp = now + backgroundUpdateRetryDelay
}

func runSelfTests(includeNetworkChecks: Bool = false) -> Bool {
    var passed = 0
    var skipped = 0
    var failed = 0
    func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        if condition() {
            passed += 1
            print("PASS \(name)")
        } else {
            failed += 1
            fputs("FAIL \(name)\n", stderr)
        }
    }
    func skip(_ name: String, reason: String) {
        skipped += 1
        print("SKIP \(name): \(reason)")
    }

    check(parseSemanticVersion("v2.7.2") == [2, 7, 2], "semantic version parses v-prefixed release")
    check(parseSemanticVersion("2.6.x").isEmpty, "malformed semantic version is rejected")
    check(parseSemanticVersion("2.06.1").isEmpty, "leading-zero semantic component is rejected")
    check(isNewerVersion("v2.7.2", than: "2.7.1"), "newer patch version is ordered")
    check(!isNewerVersion("2.6.99", than: "2.7.0"), "older version is not ordered as newer")
    check(!isNewerVersion("2.x.99", than: "2.7.0"), "malformed release cannot trigger update")
    check(swiftCompilerTargetTriple(architecture: "arm64") == "arm64-apple-macosx27.0",
          "Apple silicon builds target macOS 27.0")
    check(swiftCompilerTargetTriple(architecture: " x86_64\n") == nil,
          "Intel architecture is rejected before compilation")
    check(swiftCompilerTargetTriple(architecture: "unsupported") == nil,
          "unsupported CPU architectures are rejected before compilation")
    check(platformSupportIssue(macOSMajorVersion: 27, architecture: "arm64") == nil,
          "macOS 27 on Apple silicon is supported")
    check(platformSupportIssue(macOSMajorVersion: 28, architecture: "arm64") == nil,
          "future macOS releases on Apple silicon remain supported")
    check(platformSupportIssue(macOSMajorVersion: 26, architecture: "arm64") == "macOS_version",
          "macOS releases before 27 are rejected")
    check(platformSupportIssue(macOSMajorVersion: 27, architecture: "x86_64") == "architecture",
          "Intel Macs are rejected")
    check(macOSSDKMajorVersion("27.0") == 27 && macOSSDKMajorVersion("28.1") == 28,
          "macOS 27 and later SDK versions are recognized")
    check(macOSSDKMajorVersion("26.4") ?? 0 < minimumSupportedMacOSMajorVersion,
          "older macOS SDK versions are below the supported target")
    check(macOSSDKMajorVersion("unknown") == nil,
          "unrecognized SDK versions are rejected")
    check(!configVersionCanBeMigrated("2.7.4"), "newer config versions are not downgraded")
    check(configVersionCanBeMigrated("2.7.2"), "older config versions remain eligible for migration")

    let updateNow: TimeInterval = 10_000
    var updateState = AutoMountConfig(version: "2.7.0", updateChannel: "auto", lastUpdateCheckTimestamp: nil, lastNotifiedVersion: nil, profiles: [])
    check(shouldCheckForBackgroundUpdate(config: updateState, now: updateNow),
          "background updater checks when no successful check is recorded")
    updateState.lastUpdateCheckTimestamp = updateNow - 60
    check(!shouldCheckForBackgroundUpdate(config: updateState, now: updateNow),
          "background updater observes the normal 24-hour cooldown")
    updateState.updateRetryAfterTimestamp = updateNow + backgroundUpdateRetryDelay
    check(!shouldCheckForBackgroundUpdate(config: updateState, now: updateNow + 1),
          "background updater waits during a persisted failure retry delay")
    check(shouldCheckForBackgroundUpdate(config: updateState, now: updateNow + backgroundUpdateRetryDelay),
          "failed update retries when its shorter retry delay expires")
    recordBackgroundUpdateFailure(config: &updateState, now: updateNow)
    check(updateState.updateRetryAfterTimestamp == updateNow + backgroundUpdateRetryDelay,
          "update failure persists an explicit retry deadline")

    var workspaceMetadata = AutoMountConfig(version: "2.7.0", updateChannel: "auto", lastUpdateCheckTimestamp: 100, lastNotifiedVersion: "2.6.1", profiles: [])
    var daemonMetadata = AutoMountConfig(version: "2.7.0", updateChannel: "auto", lastUpdateCheckTimestamp: 200, lastNotifiedVersion: "2.6.1", profiles: [])
    daemonMetadata.updateRetryAfterTimestamp = updateNow + backgroundUpdateRetryDelay
    mergeDaemonOwnedMetadata(into: &workspaceMetadata, from: daemonMetadata)
    check(workspaceMetadata.lastUpdateCheckTimestamp == 200 && workspaceMetadata.lastNotifiedVersion == "2.6.1",
          "workspace config saves preserve newer daemon update state")
    check(workspaceMetadata.updateRetryAfterTimestamp == updateState.updateRetryAfterTimestamp,
          "workspace config saves preserve the daemon update retry deadline")

    let originalConfigPlist: [String: Any] = [
        "version": "2.6.1",
        "custom_root": "keep",
        "profiles": [[
            "id": "home_lan",
            "custom_profile": "keep",
            "match": ["type": "probe_host", "value": "example.invalid", "custom_match": true],
            "targets": [[
                "url": "smb://server.invalid/share",
                "mount_path": "/Volumes/share",
                "custom_target": 7
            ]]
        ]]
    ]
    let migratedConfigPlist: [String: Any] = [
        "version": "2.7.0",
        "profiles": [[
            "id": "local_lan",
            "match": ["type": "probe_host", "value": "example.invalid"],
            "targets": [[
                "url": "smb://server.invalid/share",
                "mount_path": "/Volumes/share"
            ]]
        ]]
    ]
    let mergedConfigPlist = mergeConfigPlistValue(
        original: originalConfigPlist,
        generated: migratedConfigPlist,
        context: .root
    ) as? [String: Any]
    let mergedProfiles = mergedConfigPlist?["profiles"] as? [[String: Any]]
    let mergedMatch = mergedProfiles?.first?["match"] as? [String: Any]
    let mergedTarget = (mergedProfiles?.first?["targets"] as? [[String: Any]])?.first
    check(mergedConfigPlist?["custom_root"] as? String == "keep"
          && mergedProfiles?.first?["custom_profile"] as? String == "keep"
          && mergedMatch?["custom_match"] as? Bool == true
          && mergedTarget?["custom_target"] as? Int == 7,
          "config migration preserves unknown root, profile, match, and target fields")

    let insertedConfig = mergeConfigPlistValue(
        original: ["profiles": [[
            "id": "existing",
            "custom_profile": "belongs to existing",
            "targets": [["url": "smb://server.invalid/share", "mount_path": "/Volumes/existing", "custom_target": "belongs to existing"]]
        ]]],
        generated: ["profiles": [
            ["id": "new", "match": ["type": "probe_host", "value": "new.invalid"],
             "targets": [["url": "smb://new.invalid/share", "mount_path": "/Volumes/new"]]],
            ["id": "existing", "match": ["type": "probe_host", "value": "existing.invalid"],
             "targets": [["url": "smb://server.invalid/share", "mount_path": "/Volumes/existing"]]]
        ]],
        context: .root
    ) as? [String: Any]
    let insertedProfiles = insertedConfig?["profiles"] as? [[String: Any]]
    let insertedTargets = insertedProfiles?.first?["targets"] as? [[String: Any]]
    let retainedExistingProfile = insertedProfiles?.last
    let retainedExistingTarget = (retainedExistingProfile?["targets"] as? [[String: Any]])?.first
    check(insertedProfiles?.first?["custom_profile"] == nil
          && insertedTargets?.first?["custom_target"] == nil
          && retainedExistingProfile?["custom_profile"] as? String == "belongs to existing"
          && retainedExistingTarget?["custom_target"] as? String == "belongs to existing",
          "config merge does not transfer unknown fields to inserted or reordered items")

    let missingConfigState = ConfigFileState.missing
    let usableConfigState = ConfigFileState.usable
    let invalidConfigState = ConfigFileState.invalid
    let futureConfigState = ConfigFileState.futureVersion("2.7.4")
    let inaccessibleConfigState = ConfigFileState.inaccessible
    check(resolveInstallConfigLocation(
        requested: nil, workspaceState: usableConfigState, runtimeState: missingConfigState,
        documentsEquivalent: false
    ) == .selected(.workspace), "first daemon install seeds a valid workspace config")
    check(resolveInstallConfigLocation(
        requested: nil, workspaceState: missingConfigState, runtimeState: usableConfigState,
        documentsEquivalent: false
    ) == .selected(.runtime), "runtime config is preserved when workspace config is missing")
    check(resolveInstallConfigLocation(
        requested: nil, workspaceState: usableConfigState, runtimeState: usableConfigState,
        documentsEquivalent: true
    ) == .selected(.runtime), "matching configs preserve daemon-owned runtime state")
    check(resolveInstallConfigLocation(
        requested: nil, workspaceState: usableConfigState, runtimeState: usableConfigState,
        documentsEquivalent: false
    ) == .diverged, "diverged configs require an explicit interactive choice")
    check(resolveInstallConfigLocation(
        requested: nil, workspaceState: usableConfigState, runtimeState: invalidConfigState,
        documentsEquivalent: false
    ) == .repairRuntimeFromWorkspace, "invalid runtime config is recovered from a valid workspace config")
    check(resolveInstallConfigLocation(
        requested: nil, workspaceState: invalidConfigState, runtimeState: usableConfigState,
        documentsEquivalent: false
    ) == .selected(.runtime), "valid runtime config wins over an invalid workspace config")
    check(resolveInstallConfigLocation(
        requested: nil, workspaceState: invalidConfigState, runtimeState: missingConfigState,
        documentsEquivalent: false
    ) == .initialize, "installation requests setup when neither config is usable")
    check(resolveInstallConfigLocation(
        requested: nil, workspaceState: futureConfigState, runtimeState: usableConfigState,
        documentsEquivalent: false
    ) == .selected(.runtime), "valid runtime config is retained when workspace config is from a newer version")
    check(resolveInstallConfigLocation(
        requested: nil, workspaceState: usableConfigState, runtimeState: futureConfigState,
        documentsEquivalent: false
    ) == .futureVersion(.runtime, "2.7.4"), "newer runtime config prevents an implicit downgrade")
    check(resolveInstallConfigLocation(
        requested: nil, workspaceState: usableConfigState, runtimeState: inaccessibleConfigState,
        documentsEquivalent: false
    ) == .inaccessible(.runtime), "runtime access failures stop installation before replacement")
    check(resolveInstallConfigLocation(
        requested: .workspace, workspaceState: usableConfigState, runtimeState: invalidConfigState,
        documentsEquivalent: false
    ) == .selected(.workspace), "explicit workspace selection can repair an invalid runtime config")
    check(resolveInstallConfigLocation(
        requested: .workspace, workspaceState: usableConfigState, runtimeState: futureConfigState,
        documentsEquivalent: false
    ) == .selected(.workspace), "explicit workspace selection can replace a newer runtime after backup")
    check(resolveInstallConfigLocation(
        requested: .runtime, workspaceState: usableConfigState, runtimeState: missingConfigState,
        documentsEquivalent: false
    ) == .unavailable(.runtime), "explicit runtime selection fails when runtime config is absent")
    check(resolveInstallConfigLocation(
        requested: .runtime, workspaceState: usableConfigState, runtimeState: futureConfigState,
        documentsEquivalent: false
    ) == .futureVersion(.runtime, "2.7.4"), "explicit runtime selection still rejects a config the current program cannot migrate")

    let installStateMatrix: [(ConfigFileState, ConfigFileState, Bool, InstallConfigResolution)] = [
        (.missing, .missing, false, .initialize),
        (.missing, .usable, false, .selected(.runtime)),
        (.missing, .invalid, false, .initialize),
        (.missing, .futureVersion("2.7.4"), false, .futureVersion(.runtime, "2.7.4")),
        (.missing, .inaccessible, false, .inaccessible(.runtime)),
        (.usable, .missing, false, .selected(.workspace)),
        (.usable, .usable, true, .selected(.runtime)),
        (.usable, .usable, false, .diverged),
        (.usable, .invalid, false, .repairRuntimeFromWorkspace),
        (.usable, .futureVersion("2.7.4"), false, .futureVersion(.runtime, "2.7.4")),
        (.usable, .inaccessible, false, .inaccessible(.runtime)),
        (.invalid, .missing, false, .initialize),
        (.invalid, .usable, false, .selected(.runtime)),
        (.invalid, .invalid, false, .initialize),
        (.invalid, .futureVersion("2.7.4"), false, .futureVersion(.runtime, "2.7.4")),
        (.invalid, .inaccessible, false, .inaccessible(.runtime)),
        (.futureVersion("2.7.4"), .missing, false, .futureVersion(.workspace, "2.7.4")),
        (.futureVersion("2.7.4"), .usable, false, .selected(.runtime)),
        (.futureVersion("2.7.4"), .invalid, false, .futureVersion(.workspace, "2.7.4")),
        (.futureVersion("2.7.4"), .futureVersion("2.7.4"), false, .futureVersion(.runtime, "2.7.4")),
        (.futureVersion("2.7.4"), .inaccessible, false, .inaccessible(.runtime)),
        (.inaccessible, .missing, false, .inaccessible(.workspace)),
        (.inaccessible, .usable, false, .selected(.runtime)),
        (.inaccessible, .invalid, false, .inaccessible(.workspace)),
        (.inaccessible, .futureVersion("2.7.4"), false, .futureVersion(.runtime, "2.7.4")),
        (.inaccessible, .inaccessible, false, .inaccessible(.runtime))
    ]
    for (index, scenario) in installStateMatrix.enumerated() {
        let resolution = resolveInstallConfigLocation(
            requested: nil,
            workspaceState: scenario.0,
            runtimeState: scenario.1,
            documentsEquivalent: scenario.2
        )
        check(resolution == scenario.3, "install configuration state matrix branch \(index + 1)/\(installStateMatrix.count)")
    }

    let configStateCases: [(String, ConfigFileState)] = [
        ("missing", missingConfigState),
        ("usable", usableConfigState),
        ("invalid", invalidConfigState),
        ("future", futureConfigState),
        ("inaccessible", inaccessibleConfigState)
    ]
    func expectedExplicitInstallResolution(
        requested: InstallConfigLocation,
        workspaceState: ConfigFileState,
        runtimeState: ConfigFileState
    ) -> InstallConfigResolution {
        if requested == .workspace, runtimeState == .inaccessible {
            return .inaccessible(.runtime)
        }
        let selectedState = requested == .workspace ? workspaceState : runtimeState
        switch selectedState {
        case .usable:
            return .selected(requested)
        case let .futureVersion(version):
            return .futureVersion(requested, version)
        case .inaccessible:
            return .inaccessible(requested)
        case .missing, .invalid:
            return .unavailable(requested)
        }
    }
    for (workspaceName, workspaceState) in configStateCases {
        for (runtimeName, runtimeState) in configStateCases {
            for requested in [InstallConfigLocation.workspace, .runtime] {
                let resolution = resolveInstallConfigLocation(
                    requested: requested,
                    workspaceState: workspaceState,
                    runtimeState: runtimeState,
                    documentsEquivalent: false
                )
                let expected = expectedExplicitInstallResolution(
                    requested: requested,
                    workspaceState: workspaceState,
                    runtimeState: runtimeState
                )
                check(resolution == expected,
                      "explicit \(requested) install matrix \(workspaceName)/\(runtimeName)")
            }
        }
    }

    check(resolveManagementConfigLocation(
        launchAgentInstalled: true, workspaceState: usableConfigState, runtimeState: invalidConfigState
    ) == .recover(target: .runtime, source: .workspace), "config management repairs a damaged active runtime from workspace")
    check(resolveManagementConfigLocation(
        launchAgentInstalled: true, workspaceState: usableConfigState, runtimeState: missingConfigState
    ) == .recover(target: .runtime, source: .workspace), "config management restores a missing active runtime config")
    check(resolveManagementConfigLocation(
        launchAgentInstalled: false, workspaceState: invalidConfigState, runtimeState: usableConfigState
    ) == .recover(target: .workspace, source: .runtime), "config management restores an invalid workspace from the only usable config")
    check(resolveManagementConfigLocation(
        launchAgentInstalled: true, workspaceState: usableConfigState, runtimeState: futureConfigState
    ) == .futureVersion(.runtime, "2.7.4"), "config management does not rewrite a newer active runtime config")
    func expectedManagementResolution(
        launchAgentInstalled: Bool,
        workspaceState: ConfigFileState,
        runtimeState: ConfigFileState
    ) -> ManagementConfigResolution {
        let active: InstallConfigLocation = launchAgentInstalled ? .runtime : .workspace
        let fallback: InstallConfigLocation = launchAgentInstalled ? .workspace : .runtime
        let activeState = launchAgentInstalled ? runtimeState : workspaceState
        let fallbackState = launchAgentInstalled ? workspaceState : runtimeState
        switch activeState {
        case .usable:
            return .selected(active)
        case let .futureVersion(version):
            return .futureVersion(active, version)
        case .inaccessible:
            return .inaccessible(active)
        case .missing, .invalid:
            switch fallbackState {
            case .usable:
                return .recover(target: active, source: fallback)
            case let .futureVersion(version):
                return .futureVersion(fallback, version)
            case .inaccessible:
                return .inaccessible(fallback)
            case .missing, .invalid:
                return .initialize
            }
        }
    }
    for (workspaceName, workspaceState) in configStateCases {
        for (runtimeName, runtimeState) in configStateCases {
            for launchAgentInstalled in [false, true] {
                let resolution = resolveManagementConfigLocation(
                    launchAgentInstalled: launchAgentInstalled,
                    workspaceState: workspaceState,
                    runtimeState: runtimeState
                )
                let expected = expectedManagementResolution(
                    launchAgentInstalled: launchAgentInstalled,
                    workspaceState: workspaceState,
                    runtimeState: runtimeState
                )
                check(resolution == expected,
                      "management matrix service=\(launchAgentInstalled) \(workspaceName)/\(runtimeName)")
            }
        }
    }
    check(resolveInitConfigState(
        resetExistingConfig: false, workspaceState: usableConfigState, runtimeState: invalidConfigState,
        documentsEquivalent: false
    ) == .preserve(.workspace), "init preserves an existing usable workspace config")
    check(resolveInitConfigState(
        resetExistingConfig: false, workspaceState: usableConfigState, runtimeState: usableConfigState,
        documentsEquivalent: false
    ) == .diverged, "init refuses to overwrite two valid divergent configs")
    check(resolveInitConfigState(
        resetExistingConfig: false, workspaceState: missingConfigState, runtimeState: missingConfigState,
        documentsEquivalent: false
    ) == .initialize, "init starts the setup wizard when both configs are missing")
    check(resolveInitConfigState(
        resetExistingConfig: false, workspaceState: futureConfigState, runtimeState: missingConfigState,
        documentsEquivalent: false
    ) == .futureVersion(.workspace, "2.7.4"), "init protects a config written by a newer program")
    check(resolveInitConfigState(
        resetExistingConfig: true, workspaceState: usableConfigState, runtimeState: usableConfigState,
        documentsEquivalent: false
    ) == .initialize, "explicit init reset starts a fresh setup after backup")
    func expectedInitResolution(
        resetExistingConfig: Bool,
        workspaceState: ConfigFileState,
        runtimeState: ConfigFileState,
        documentsEquivalent: Bool
    ) -> InitConfigResolution {
        if resetExistingConfig {
            if workspaceState == .inaccessible { return .inaccessible(.workspace) }
            if runtimeState == .inaccessible { return .inaccessible(.runtime) }
            return .initialize
        }
        if case let .futureVersion(version) = runtimeState {
            return .futureVersion(.runtime, version)
        }
        if case let .futureVersion(version) = workspaceState {
            return .futureVersion(.workspace, version)
        }
        if workspaceState == .inaccessible { return .inaccessible(.workspace) }
        if runtimeState == .inaccessible { return .inaccessible(.runtime) }
        if workspaceState == .usable, runtimeState == .usable, !documentsEquivalent {
            return .diverged
        }
        if workspaceState == .usable { return .preserve(.workspace) }
        if runtimeState == .usable { return .preserve(.runtime) }
        return .initialize
    }
    for (workspaceName, workspaceState) in configStateCases {
        for (runtimeName, runtimeState) in configStateCases {
            let equivalenceCases = workspaceState == .usable && runtimeState == .usable
                ? [false, true] : [false]
            for equivalent in equivalenceCases {
                let resolution = resolveInitConfigState(
                    resetExistingConfig: false,
                    workspaceState: workspaceState,
                    runtimeState: runtimeState,
                    documentsEquivalent: equivalent
                )
                let expected = expectedInitResolution(
                    resetExistingConfig: false,
                    workspaceState: workspaceState,
                    runtimeState: runtimeState,
                    documentsEquivalent: equivalent
                )
                check(resolution == expected,
                      "init preserve matrix \(workspaceName)/\(runtimeName) equivalent=\(equivalent)")
            }
            let resetResolution = resolveInitConfigState(
                resetExistingConfig: true,
                workspaceState: workspaceState,
                runtimeState: runtimeState,
                documentsEquivalent: false
            )
            let expectedResetResolution = expectedInitResolution(
                resetExistingConfig: true,
                workspaceState: workspaceState,
                runtimeState: runtimeState,
                documentsEquivalent: false
            )
            check(resetResolution == expectedResetResolution,
                  "init reset matrix \(workspaceName)/\(runtimeName)")
        }
    }

    let configFileTestDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("automount-config-state-\(UUID().uuidString)", isDirectory: true)
    let invalidTestConfigURL = configFileTestDirectory.appendingPathComponent("config.plist")
    let corruptConfigBytes = Data("corrupt plist test bytes".utf8)
    do {
        try FileManager.default.createDirectory(at: configFileTestDirectory, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: invalidTestConfigURL.path, contents: corruptConfigBytes,
                                           attributes: [.posixPermissions: 0o644])
    } catch {
        fputs("FAIL could not create isolated config-state test files: \(error.localizedDescription)\n", stderr)
    }
    defer { try? FileManager.default.removeItem(at: configFileTestDirectory) }
    let missingTestConfig = inspectConfigFile(at: configFileTestDirectory.appendingPathComponent("missing.plist"))
    let invalidTestConfig = inspectConfigFile(at: invalidTestConfigURL)
    check(missingTestConfig.state == .missing, "config inspection distinguishes a missing file")
    check(invalidTestConfig.state == .invalid, "config inspection distinguishes a malformed file")
    let changedInvalidSnapshot = ConfigFileInspection(
        url: invalidTestConfigURL, state: .invalid, config: nil,
        contents: Data("changed corrupt plist bytes".utf8), diagnostic: "Configuration is malformed"
    )
    check(!configInspectionMatches(invalidTestConfig, changedInvalidSnapshot),
          "config snapshot validation detects concurrent content changes")
    let nonFileConfigPath = configFileTestDirectory.appendingPathComponent("not-a-file", isDirectory: true)
    try? FileManager.default.createDirectory(at: nonFileConfigPath, withIntermediateDirectories: true)
    check(inspectConfigFile(at: nonFileConfigPath).state == .inaccessible,
          "config inspection refuses a directory where a config file is expected")
    let backupURL = try? backUpConfigFile(invalidTestConfig)
    let backupBytes = backupURL.flatMap { try? Data(contentsOf: $0) }
    let backupPermissions = backupURL.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.posixPermissions] as? NSNumber }
    check(backupBytes == corruptConfigBytes && backupPermissions?.intValue == 0o600,
          "config backup preserves bytes with owner-only permissions")
    let unvalidatedReplacement = ConfigFileInspection(
        url: configFileTestDirectory.appendingPathComponent("source.plist"), state: .usable,
        config: nil, contents: Data("unvalidated replacement bytes".utf8), diagnostic: nil
    )
    var replacementWasRejected = false
    do {
        _ = try replaceConfigFile(with: unvalidatedReplacement, at: invalidTestConfigURL,
                                  destination: invalidTestConfig)
    } catch {
        replacementWasRejected = true
    }
    check(replacementWasRejected && (try? Data(contentsOf: invalidTestConfigURL)) == corruptConfigBytes,
          "stale config source is rejected without modifying the destination")

    let equivalenceProfile = NetworkProfile(
        id: "test_profile", description: "Generic test profile",
        match: MatchRule(type: "probe_host", value: "server.invalid", retryCount: nil, retryInterval: nil),
        excludeGatewayIPs: nil, preventSpotlightIndex: nil,
        targets: [MountTarget(url: "smb://server.invalid/share", mountPath: "/Volumes/share")]
    )
    let runtimeSettings = AutoMountConfig(
        version: "2.7.0", updateChannel: "auto", lastUpdateCheckTimestamp: 1,
        updateRetryAfterTimestamp: 2, lastNotifiedVersion: "2.7.0", profiles: [equivalenceProfile]
    )
    var workspaceSettings = runtimeSettings
    workspaceSettings.version = "2.7.1"
    workspaceSettings.lastUpdateCheckTimestamp = 10
    workspaceSettings.updateRetryAfterTimestamp = 20
    workspaceSettings.lastNotifiedVersion = "2.7.1"
    check(installConfigModelsAreEquivalent(workspaceSettings, runtimeSettings),
          "install config comparison ignores version and daemon update bookkeeping")
    workspaceSettings.updateChannel = "off"
    check(!installConfigModelsAreEquivalent(workspaceSettings, runtimeSettings),
          "install config comparison detects user settings changes")

    check(smbResourceIdentity("smb://user:secret@NAS.local/Media") == smbResourceIdentity("//NAS.local/media"),
          "SMB identity ignores credentials and case")
    check(smbResourceIdentity("smb://nas.local/media") != smbResourceIdentity("smb://nas.local/archive"),
          "different SMB shares have different identities")
    check(extractHost(from: "smb://[fd00::1]/share") == "fd00::1", "IPv6 SMB host is extracted")
    check(validateMountTargetURL("smb://nas.local/share") == nil, "valid SMB URL is accepted")
    check(validateMountTargetURL("https://nas.local/share") != nil, "non-SMB URL is rejected")
    check(validateMountTargetURL("smb://nas.local") != nil, "SMB URL without share is rejected")
    let routedTestURL = remoteSMBAcceptanceURL(
        "smb://nas.example.ts.net/share",
        peers: [DiscoveredTailscalePeer(name: "nas", magicDNS: "nas.example.ts.net.", ip: "peer.invalid", os: "linux")]
    )
    check(routedTestURL.url == "smb://peer.invalid/share" && routedTestURL.usesTailscaleAddress,
          "remote SMB acceptance prefers a matching Tailscale peer address over local DNS")
    check(validateMountPath("/Volumes/media") == nil, "absolute mount path is accepted")
    check(validateMountPath("relative/media") != nil, "relative mount path is rejected")
    check(validateMountPath("/Volumes/../private") != nil, "traversal mount path is rejected")
    check(usesSystemManagedMountPoint(MountTarget(url: "smb://nas.local/media", mountPath: "/Volumes/media")),
          "standard share mount path can be created by NetFS")
    let explicitNetFSMountOptions = netFSMountOptions(hasExplicitMountPoint: true)
    check(explicitNetFSMountOptions?.object(forKey: kNetFSMountAtMountDirKey as String) as? Bool == true,
          "NetFS mounts at an explicit mount point instead of beneath it")
    check(netFSMountOptions(hasExplicitMountPoint: false) == nil,
          "NetFS keeps system-managed mount behavior when no explicit mount point is provided")
    check(!usesSystemManagedMountPoint(MountTarget(url: "smb://nas.local/media", mountPath: "/Volumes/archive")),
          "custom mount path is not delegated to the system")
    check(!usesSystemManagedMountPoint(MountTarget(url: "smb://nas.local/media", mountPath: "/Volumes/nas/media")),
          "nested mount path is not delegated to the system")
    check(parseARPCacheOutput("? (192.0.2.1) at AA:BB:CC:DD:EE:FF on en0 ifscope [ethernet]", for: "192.0.2.1") == "aa:bb:cc:dd:ee:ff",
          "interface-scoped ARP entry is parsed and normalized")
    check(parseARPCacheOutput("? (192.0.2.1) at AA:BB:CC:DD:EE:FF on en1 ifscope", for: "192.0.2.1", interface: "en0") == nil,
          "ARP lookup rejects a matching address on the wrong interface")
    check(parseARPCacheOutput("? (192.0.2.10) at 00:11:22:33:44:55 on en0\n? (192.0.2.1) at (incomplete) on en0", for: "192.0.2.1") == nil,
          "incomplete ARP entry is rejected")
    check(parseARPCacheOutput("? (192.0.2.10) at 00:11:22:33:44:55 on en0", for: "192.0.2.1") == nil,
          "ARP parser does not match a different IP")
    let redacted = redactedSMBURL("smb://alice:secret@nas.local/share")
    check(!redacted.contains("alice") && !redacted.contains("secret"), "SMB URL credentials are redacted")
    let nonSMBRedacted = redactedSMBURL("https://alice:secret@host.invalid/path")
    check(!nonSMBRedacted.contains("alice") && !nonSMBRedacted.contains("secret"),
          "credentials are redacted from rejected non-SMB URLs")
    let malformedURLRedacted = redactedSMBURL("smb://alice:sec ret@host.invalid/share")
    check(!malformedURLRedacted.contains("alice") && !malformedURLRedacted.contains("sec ret"),
          "credentials are redacted from malformed URLs")
    let binaryURL = URL(fileURLWithPath: "/tmp/automount-test-binary")
    let sourceURL = URL(fileURLWithPath: "/tmp/automount-test-source.swift")
    check(launchAgentProgramArguments(binaryURL: binaryURL, sourceURL: sourceURL, preferSource: false) == [binaryURL.path],
          "LaunchAgent falls back to the compiled binary when source launch is disabled")
    check(launchAgentProgramArguments(binaryURL: binaryURL, sourceURL: sourceURL, preferSource: true) == ["/usr/bin/swift", sourceURL.path],
          "first LaunchAgent install can select its staged Swift source")

    let atomicWriteURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("automount-self-test-\(UUID().uuidString)")
    var atomicWritePassed = false
    do {
        try atomicWrite(Data("test".utf8), to: atomicWriteURL, permissions: 0o600)
        let mode = (try FileManager.default.attributesOfItem(atPath: atomicWriteURL.path)[.posixPermissions] as? NSNumber)?.intValue
        let contents = try String(contentsOf: atomicWriteURL, encoding: .utf8)
        atomicWritePassed = mode == 0o600 && contents == "test"
    } catch {
        atomicWritePassed = false
    }
    try? FileManager.default.removeItem(at: atomicWriteURL)
    check(atomicWritePassed, "atomic config writes preserve content and requested file permissions")

    let transactionDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("automount-transaction-test-\(UUID().uuidString)")
    let firstSourceURL = transactionDirectory.appendingPathComponent("first-new")
    let firstDestinationURL = transactionDirectory.appendingPathComponent("first-destination")
    let missingSourceURL = transactionDirectory.appendingPathComponent("missing-source")
    let secondDestinationURL = transactionDirectory.appendingPathComponent("second-destination")
    try? FileManager.default.createDirectory(at: transactionDirectory, withIntermediateDirectories: true)
    try? Data("new".utf8).write(to: firstSourceURL)
    try? Data("old".utf8).write(to: firstDestinationURL)
    var transactionRolledBack = false
    do {
        try replaceFilesTransactionally([
            StagedFileReplacement(sourceURL: firstSourceURL, destinationURL: firstDestinationURL, permissions: 0o600),
            StagedFileReplacement(sourceURL: missingSourceURL, destinationURL: secondDestinationURL, permissions: 0o600)
        ])
    } catch {
        transactionRolledBack = (try? String(contentsOf: firstDestinationURL, encoding: .utf8)) == "old"
            && !FileManager.default.fileExists(atPath: secondDestinationURL.path)
    }
    check(transactionRolledBack, "multi-file deployment restores prior files when a replacement fails")

    var activationRolledBack = false
    do {
        try replaceFilesTransactionally([
            StagedFileReplacement(sourceURL: firstSourceURL, destinationURL: firstDestinationURL, permissions: 0o600)
        ]) {
            throw NSError(domain: "AutoMountTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "simulated activation failure"])
        }
    } catch {
        activationRolledBack = (try? String(contentsOf: firstDestinationURL, encoding: .utf8)) == "old"
    }
    check(activationRolledBack, "failed service activation restores the prior file set")
    try? FileManager.default.removeItem(at: transactionDirectory)

    let pipeTest = runCommand(
        executable: "/bin/sh",
        arguments: ["-c", "/usr/bin/yes x | /usr/bin/head -c 131072 >&2; printf stdout"]
    )
    check(pipeTest.status == 0 && pipeTest.stdout == "stdout" && pipeTest.stderr.utf8.count == 131072,
          "child stdout and large stderr are drained without deadlock")

    let completedCommand = runCommandDiscardingOutputWithTimeout(
        executable: "/usr/bin/true", arguments: [], timeout: 1.0
    )
    check(completedCommand.status == 0 && !completedCommand.timedOut && completedCommand.processStopped,
          "bounded child runner reports a completed command")
    let timedOutCommand = runCommandDiscardingOutputWithTimeout(
        executable: "/bin/sleep", arguments: ["2"], timeout: 0.05
    )
    check(timedOutCommand.timedOut && timedOutCommand.processStopped,
          "bounded child runner terminates and reaps a timed-out command")

    let launchdSample = """
    state = not running
    last exit code = 1
    """
    check(firstRegexCapture(#"(?m)^\s*last exit code = (-?\d+)\s*$"#, in: launchdSample) == "1",
          "launchd last exit code is parsed")

    // Visible config discovery tests
    let mockAppDir = URL(fileURLWithPath: "/tmp/mock_app")
    let mockInstalledDir = URL(fileURLWithPath: "/tmp/mock_installed")
    let daemonDiscovered = discoverVisibleConfigURLs(appDirectory: mockInstalledDir, installedDirectory: mockInstalledDir)
    check(daemonDiscovered.count == 1 && daemonDiscovered.first?.path == mockInstalledDir.appendingPathComponent("auto_mount.plist").path,
          "daemon discovery only inspects its own installed directory")

    let workspaceDiscovered = discoverVisibleConfigURLs(appDirectory: mockAppDir, installedDirectory: mockInstalledDir)
    check(workspaceDiscovered.count == 2
          && workspaceDiscovered[0].path == mockAppDir.appendingPathComponent("auto_mount.plist").path
          && workspaceDiscovered[1].path == mockInstalledDir.appendingPathComponent("auto_mount.plist").path,
          "workspace discovery scans both workspace and runtime configs")

    let deduplicatedDiscovered = discoverVisibleConfigURLs(appDirectory: mockInstalledDir, installedDirectory: mockInstalledDir)
    check(deduplicatedDiscovered.count == 1,
          "coinciding workspace and runtime directories are deduplicated")

    let overrideConfigURL = URL(fileURLWithPath: "/tmp/mock_override.plist")
    let overrideDiscovered = discoverVisibleConfigURLs(appDirectory: mockAppDir, installedDirectory: mockInstalledDir, overrideURL: overrideConfigURL)
    check(overrideDiscovered.count == 3 && overrideDiscovered[0].path == overrideConfigURL.path,
          "override config URL is prioritized and included in visible configs")

    // configNeedsMigration tests
    let modernConfig = AutoMountConfig(version: autoMountVersion, updateChannel: "auto", lastUpdateCheckTimestamp: nil, lastNotifiedVersion: nil, profiles: [
        NetworkProfile(id: "local_lan", description: "Local LAN High-Speed Direct Connection", match: MatchRule(type: "gateway_mac", value: "00:11:22:33:44:55"), excludeGatewayIPs: nil, preventSpotlightIndex: true, targets: [])
    ])
    check(!configNeedsMigration(modernConfig), "modern config does not need migration")

    var olderConfig = modernConfig
    olderConfig.version = "2.7.1"
    check(configNeedsMigration(olderConfig), "older version config needs migration")

    var legacyIdConfig = modernConfig
    legacyIdConfig.profiles[0].id = "home_lan"
    check(configNeedsMigration(legacyIdConfig), "legacy profile ID needs migration")

    var nilChannelConfig = modernConfig
    nilChannelConfig.updateChannel = nil
    check(configNeedsMigration(nilChannelConfig), "missing updateChannel needs migration")

    // eagerMigrateVisibleConfigs sandbox tests
    let eagerSandbox = FileManager.default.temporaryDirectory.appendingPathComponent("eager-migration-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: eagerSandbox, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: eagerSandbox) }

    let wsConfigURL = eagerSandbox.appendingPathComponent("workspace_auto_mount.plist")
    let rtConfigURL = eagerSandbox.appendingPathComponent("runtime_auto_mount.plist")
    let malformedURL = eagerSandbox.appendingPathComponent("malformed_auto_mount.plist")
    let futureURL = eagerSandbox.appendingPathComponent("future_auto_mount.plist")
    let missingURL = eagerSandbox.appendingPathComponent("missing_auto_mount.plist")

    let wsXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    \t<key>version</key>
    \t<string>2.7.1</string>
    \t<key>update_channel</key>
    \t<string>auto</string>
    \t<key>custom_field</key>
    \t<string>preserved_value</string>
    \t<key>profiles</key>
    \t<array>
    \t\t<dict>
    \t\t\t<key>id</key>
    \t\t\t<string>home_lan</string>
    \t\t\t<key>description</key>
    \t\t\t<string>家庭局域网直连</string>
    \t\t\t<key>match</key>
    \t\t\t<dict>
    \t\t\t\t<key>type</key>
    \t\t\t\t<string>gateway_mac</string>
    \t\t\t\t<key>value</key>
    \t\t\t\t<string>aa:bb:cc:dd:ee:ff</string>
    \t\t\t</dict>
    \t\t\t<key>targets</key>
    \t\t\t<array>
    \t\t\t\t<dict>
    \t\t\t\t\t<key>mount_path</key>
    \t\t\t\t\t<string>/Volumes/ws_share</string>
    \t\t\t\t\t<key>url</key>
    \t\t\t\t\t<string>smb://nas.local/ws_share</string>
    \t\t\t\t</dict>
    \t\t\t</array>
    \t\t</dict>
    \t</array>
    </dict>
    </plist>
    """
    try? wsXML.data(using: .utf8)?.write(to: wsConfigURL)

    let rtXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    \t<key>version</key>
    \t<string>\(autoMountVersion)</string>
    \t<key>update_channel</key>
    \t<string>off</string>
    \t<key>profiles</key>
    \t<array>
    \t\t<dict>
    \t\t\t<key>id</key>
    \t\t\t<string>local_lan</string>
    \t\t\t<key>description</key>
    \t\t\t<string>本地局域网高速直连</string>
    \t\t\t<key>match</key>
    \t\t\t<dict>
    \t\t\t\t<key>type</key>
    \t\t\t\t<string>gateway_mac</string>
    \t\t\t\t<key>value</key>
    \t\t\t\t<string>11:22:33:44:55:66</string>
    \t\t\t</dict>
    \t\t\t<key>targets</key>
    \t\t\t<array>
    \t\t\t\t<dict>
    \t\t\t\t\t<key>mount_path</key>
    \t\t\t\t\t<string>/Volumes/rt_share</string>
    \t\t\t\t\t<key>url</key>
    \t\t\t\t\t<string>smb://nas.local/rt_share</string>
    \t\t\t\t</dict>
    \t\t\t</array>
    \t\t</dict>
    \t</array>
    </dict>
    </plist>
    """
    try? rtXML.data(using: .utf8)?.write(to: rtConfigURL)

    try? "this is not a valid plist xml".data(using: .utf8)?.write(to: malformedURL)

    let futureXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    \t<key>version</key>
    \t<string>99.0.0</string>
    \t<key>update_channel</key>
    \t<string>auto</string>
    \t<key>profiles</key>
    \t<array>
    \t\t<dict>
    \t\t\t<key>id</key>
    \t\t\t<string>future_profile</string>
    \t\t\t<key>match</key>
    \t\t\t<dict>
    \t\t\t\t<key>type</key>
    \t\t\t\t<string>gateway_mac</string>
    \t\t\t\t<key>value</key>
    \t\t\t\t<string>ff:ee:dd:cc:bb:aa</string>
    \t\t\t</dict>
    \t\t\t<key>targets</key>
    \t\t\t<array/>
    \t\t</dict>
    \t</array>
    </dict>
    </plist>
    """
    try? futureXML.data(using: .utf8)?.write(to: futureURL)

    let migrationRun1 = eagerMigrateVisibleConfigs(candidateURLs: [wsConfigURL, rtConfigURL, malformedURL, futureURL, missingURL])
    check(migrationRun1[wsConfigURL] == .migrated, "workspace config is migrated to current schema")
    check(migrationRun1[rtConfigURL] == .unchanged, "already-up-to-date runtime config is unchanged")
    check(migrationRun1[malformedURL] == .skippedMalformed("Configuration is malformed or has no profiles"), "malformed config is skipped without error")
    check(migrationRun1[futureURL] == .skippedFutureVersion("99.0.0"), "future version config is skipped without downgrade")
    check(migrationRun1[missingURL] == .skippedMissing, "missing config is skipped")

    let migratedWSInspection = inspectConfigFile(at: wsConfigURL)
    check(migratedWSInspection.state == .usable, "migrated workspace config is usable")
    check(migratedWSInspection.config?.version == autoMountVersion, "migrated workspace config version matches current program")
    check(migratedWSInspection.config?.profiles.first?.id == "local_lan", "migrated workspace config profile ID updated to local_lan")
    let rawWSData = try? Data(contentsOf: wsConfigURL)
    let rawWSString = rawWSData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    check(rawWSString.contains("custom_field") && rawWSString.contains("preserved_value"), "migrated workspace config preserves unknown fields")
    check(rawWSString.contains("/Volumes/ws_share"), "migrated workspace config preserves its own targets without overwrite")
    check(!rawWSString.contains("/Volumes/rt_share"), "migrated workspace config is not overwritten by runtime config")

    let wsPermissions = (try? FileManager.default.attributesOfItem(atPath: wsConfigURL.path)[.posixPermissions] as? NSNumber)?.intValue
    check(wsPermissions == 0o600, "migrated config preserves 0600 permissions")

    let malformedContent = (try? String(contentsOf: malformedURL, encoding: .utf8)) ?? ""
    check(malformedContent == "this is not a valid plist xml", "malformed file was not overwritten")
    let futureInspection = inspectConfigFile(at: futureURL)
    check(futureInspection.state == .futureVersion("99.0.0"), "future config version was not downgraded")

    let migrationRun2 = eagerMigrateVisibleConfigs(candidateURLs: [wsConfigURL, rtConfigURL])
    check(migrationRun2[wsConfigURL] == .unchanged, "repeat migration leaves up-to-date workspace config unchanged")
    check(migrationRun2[rtConfigURL] == .unchanged, "repeat migration leaves up-to-date runtime config unchanged")

    if includeNetworkChecks {
        if let gateway = getPhysicalGatewayInfo() {
            let scopedTable = runCommand(executable: "/usr/sbin/arp",
                                         arguments: ["-n", "-i", gateway.interface, "-a"])
            check(scopedTable.status == 0,
                  "interface-scoped ARP table command completes for the current gateway")
            if scopedTable.stdout.isEmpty {
                let reason = "arp returned no entries in this run, so neighbor-cache behavior is unverified"
                skip("gateway entry in the ARP table", reason: reason)
                skip("ARP entry parsing and interface scope", reason: reason)
                skip("gateway MAC cache lookup", reason: reason)
                skip("application gateway MAC probe", reason: reason)
            } else {
                check(scopedTable.stdout.contains("(\(gateway.ip))"),
                      "interface-scoped ARP table contains the current gateway address")
                check(parseARPCacheOutput(scopedTable.stdout, for: gateway.ip, interface: gateway.interface) != nil,
                      "interface-scoped ARP table includes a parseable entry for the current gateway")
                check(queryARPCache(for: gateway.ip, interface: gateway.interface) != nil,
                      "current gateway MAC is readable from the interface-scoped ARP entry")
                check(getMACAddress(for: gateway.ip, interface: gateway.interface) != nil,
                      "current gateway MAC can be resolved through the application probe")
            }
        } else {
            check(false, "current physical gateway is detected")
        }
    }

    print("Self-tests: \(passed) passed, \(skipped) skipped, \(failed) failed")
    return failed == 0
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
    let resultLock = NSLock()
    var result: ReleaseFetchResult = .networkError

    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        var fetchedResult: ReleaseFetchResult = .networkError
        if error != nil {
            fetchedResult = .networkError
        } else if let httpRes = response as? HTTPURLResponse, httpRes.statusCode == 404 {
            fetchedResult = .noReleasesFound
        } else if let httpRes = response as? HTTPURLResponse, httpRes.statusCode == 200,
                  let data,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let tagName = json["tag_name"] as? String {
            let name = (json["name"] as? String) ?? tagName
            let body = (json["body"] as? String) ?? ""
            let publishedAt = json["published_at"] as? String
            fetchedResult = .success(GitHubReleaseInfo(tagName: tagName, name: name, body: body, publishedAt: publishedAt))
        }
        resultLock.lock()
        result = fetchedResult
        resultLock.unlock()
        semaphore.signal()
    }
    task.resume()
    guard semaphore.wait(timeout: .now() + 6.0) == .success else {
        task.cancel()
        return .networkError
    }
    resultLock.lock()
    defer { resultLock.unlock() }
    return result
}

func downloadLatestSource(tag: String) -> String? {
    let rawURLString = "https://raw.githubusercontent.com/\(githubRepo)/\(tag)/auto_mount.swift"
    guard let url = URL(string: rawURLString) else { return nil }

    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10.0)
    request.setValue("AutoMount/\(autoMountVersion)", forHTTPHeaderField: "User-Agent")

    let semaphore = DispatchSemaphore(value: 0)
    let contentLock = NSLock()
    var downloadedContent: String?

    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        var fetchedContent: String?
        if error == nil, let data,
           let httpRes = response as? HTTPURLResponse, httpRes.statusCode == 200,
           let text = String(data: data, encoding: .utf8), !text.isEmpty {
            fetchedContent = text
        }
        contentLock.lock()
        downloadedContent = fetchedContent
        contentLock.unlock()
        semaphore.signal()
    }
    task.resume()
    guard semaphore.wait(timeout: .now() + 11.0) == .success else {
        task.cancel()
        return nil
    }
    contentLock.lock()
    defer { contentLock.unlock() }
    return downloadedContent
}

func performSelfUpdate(newVersion: String, newContent: String, isSilent: Bool) -> Bool {
    func fail(_ message: String) -> Bool {
        fputs("✗ \(message)\n", stderr)
        writeLog("Self-update failed for \(newVersion): \(message)")
        if !isSilent {
            showMacOSNotification(
                title: tr("AutoMount 升级未完成", "AutoMount Update Incomplete"),
                subtitle: tr("更新未完成", "Update Failed"),
                message: message
            )
        }
        return false
    }

    guard parseSemanticVersion(newVersion).count == 3 else {
        return fail(tr("发布版本号无效。", "Release version is invalid."))
    }
    let versionPattern = #"let\s+autoMountVersion\s*=\s*"([^"]+)""#
    guard let versionRegex = try? NSRegularExpression(pattern: versionPattern),
          let versionMatch = versionRegex.firstMatch(in: newContent, range: NSRange(newContent.startIndex..., in: newContent)),
          let versionRange = Range(versionMatch.range(at: 1), in: newContent),
          parseSemanticVersion(String(newContent[versionRange])) == parseSemanticVersion(newVersion) else {
        return fail(tr("下载源码中的版本号与发布版本不一致。", "Downloaded source version does not match the release tag."))
    }

    let tempDirectory = FileManager.default.temporaryDirectory
    let stagedSourceURL = tempDirectory.appendingPathComponent("automount-update-\(UUID().uuidString).swift")
    let stagedBinaryURL = tempDirectory.appendingPathComponent("automount-update-\(UUID().uuidString)")
    var stagedConfigURLs: [URL] = []
    defer {
        try? FileManager.default.removeItem(at: stagedSourceURL)
        try? FileManager.default.removeItem(at: stagedBinaryURL)
        for url in stagedConfigURLs {
            try? FileManager.default.removeItem(at: url)
        }
    }
    do {
        try newContent.write(to: stagedSourceURL, atomically: true, encoding: .utf8)
    } catch {
        return fail(tr("无法暂存升级源码: \(error.localizedDescription)", "Could not stage update source: \(error.localizedDescription)"))
    }
    let compile = compileOptimizedSwiftSource(sourceURL: stagedSourceURL, outputURL: stagedBinaryURL)
    guard compile.status == 0 else {
        let details = compile.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return fail(tr("新版本完整编译失败。\n\(details)", "The new version failed to compile.\n\(details)"))
    }

    let installDir = getInstalledDir()
    let currentAppDir = getAppDir()
    let targetInstalledSwift = installDir.appendingPathComponent("auto_mount.swift")
    let installedBinary = installDir.appendingPathComponent("auto_mount")
    let localSwift = currentAppDir.appendingPathComponent("auto_mount.swift")
    let localBinary = currentAppDir.appendingPathComponent("auto_mount")
    let installDirectoryExists = FileManager.default.fileExists(atPath: installDir.path)
    let localDirectoryIsRuntime = currentAppDir.standardizedFileURL.path == installDir.standardizedFileURL.path
    var updateWorkspace = !localDirectoryIsRuntime
        && (FileManager.default.fileExists(atPath: localSwift.path)
            || FileManager.default.fileExists(atPath: localBinary.path))
    var skippedModifiedWorkspace = false

    if updateWorkspace && FileManager.default.fileExists(atPath: localSwift.path) {
        let gitCheck = runCommand(
            executable: "/usr/bin/git",
            arguments: ["-C", currentAppDir.path, "status", "--porcelain", "--", "auto_mount.swift"]
        )
        if gitCheck.status == 0
            && !gitCheck.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updateWorkspace = false
            skippedModifiedWorkspace = true
            writeLog("Skipped updating the workspace because auto_mount.swift has local changes.")
        }
    }

    guard installDirectoryExists || updateWorkspace else {
        return fail(tr("没有找到可安全升级的程序目录。", "No safe program directory was found to update."))
    }

    var replacements: [StagedFileReplacement] = []
    var updatedPaths: [String] = []
    if installDirectoryExists {
        replacements.append(StagedFileReplacement(sourceURL: stagedBinaryURL, destinationURL: installedBinary, permissions: 0o755))
        replacements.append(StagedFileReplacement(sourceURL: stagedSourceURL, destinationURL: targetInstalledSwift, permissions: 0o755))
        updatedPaths.append(installedBinary.path)
        updatedPaths.append(targetInstalledSwift.path)
    }
    if updateWorkspace {
        if FileManager.default.fileExists(atPath: localBinary.path) {
            replacements.append(StagedFileReplacement(sourceURL: stagedBinaryURL, destinationURL: localBinary, permissions: 0o755))
            updatedPaths.append(localBinary.path)
        }
        if FileManager.default.fileExists(atPath: localSwift.path) {
            replacements.append(StagedFileReplacement(sourceURL: stagedSourceURL, destinationURL: localSwift, permissions: 0o755))
            updatedPaths.append(localSwift.path)
        }
    }

    var configDestinations = Set<String>()
    var candidateConfigs: [URL] = []
    if installDirectoryExists {
        candidateConfigs.append(installDir.appendingPathComponent("auto_mount.plist"))
    }
    if updateWorkspace {
        candidateConfigs.append(currentAppDir.appendingPathComponent("auto_mount.plist"))
    }

    for configURL in candidateConfigs
        where FileManager.default.fileExists(atPath: configURL.path)
            && configDestinations.insert(configURL.standardizedFileURL.path).inserted {
        let stagedConfigURL = tempDirectory.appendingPathComponent("automount-config-\(UUID().uuidString).plist")
        stagedConfigURLs.append(stagedConfigURL)
        do {
            try atomicCopyFile(from: configURL, to: stagedConfigURL, permissions: 0o600)
        } catch {
            return fail(tr("无法暂存配置文件: \(error.localizedDescription)", "Could not stage config file: \(error.localizedDescription)"))
        }
        let migration = runCommand(
            executable: stagedBinaryURL.path,
            arguments: ["--migrate-only", stagedConfigURL.path]
        )
        guard migration.status == 0 else {
            return fail(tr("配置迁移失败，原配置未被替换: \(migration.stderr)",
                           "Config migration failed; the original config was not replaced: \(migration.stderr)"))
        }
        replacements.append(StagedFileReplacement(sourceURL: stagedConfigURL, destinationURL: configURL, permissions: 0o600))
        updatedPaths.append(configURL.path + tr(" (已迁移)", " (migrated)"))
    }

    do {
        try replaceFilesTransactionally(replacements)
    } catch {
        return fail(tr("写入升级文件失败，已尝试恢复原文件: \(error.localizedDescription)",
                       "Could not install update files; rollback was attempted: \(error.localizedDescription)"))
    }

    let launchAgentLoaded = FileManager.default.fileExists(atPath: getLaunchAgentPlistURL().path)
        && getLaunchAgentDiagnostic().loaded
    writeLog("Self-update succeeded to \(newVersion). Updated files: \(updatedPaths.joined(separator: ", "))")
    if skippedModifiedWorkspace {
        writeLog("The updated runtime is current; the modified workspace was left untouched.")
    }

    if isSilent {
        showMacOSNotification(
            title: tr("AutoMount 自动升级成功", "AutoMount Updated Successfully"),
            subtitle: tr("已部署版本 \(newVersion)", "Version \(newVersion) deployed"),
            message: tr("守护进程会在配置变化触发或不超过 60 秒的下次启动时读取新版本。",
                        "The daemon will read the new version when the config change triggers it or on the next launch within 60 seconds.")
        )
    } else {
        print(tr("✓ 软件已成功升级至 \(newVersion)！", "✓ Successfully updated to \(newVersion)!"))
        if !updatedPaths.isEmpty {
            print(tr("  已同步更新组件:\n    \(updatedPaths.joined(separator: "\n    "))",
                     "  Synchronized components:\n    \(updatedPaths.joined(separator: "\n    "))"))
        }
        if skippedModifiedWorkspace {
            print(tr("• 工作区源码有未提交修改，已保留；后台运行目录仍已更新。",
                     "• The workspace has uncommitted source changes and was preserved; the daemon runtime was updated."))
        }
        print(tr(
            launchAgentLoaded
                ? "✓ 已部署新版本；守护进程将在配置变化触发或不超过 60 秒的下次启动时读取新文件。"
                : "✓ 已部署新版本；未强制启动或重载 LaunchAgent。",
            launchAgentLoaded
                ? "✓ New files are deployed; the daemon will load them on a config-change trigger or its next launch within 60 seconds."
                : "✓ New files are deployed; the LaunchAgent was not forcibly started or reloaded."
        ))
    }
    return true
}

func triggerBackgroundUpdateCheckIfNeeded(config: inout AutoMountConfig) {
    let channel = config.updateChannel ?? "off"
    guard channel == "notify" || channel == "auto" else { return }

    let now = Date().timeIntervalSince1970
    guard shouldCheckForBackgroundUpdate(config: config, now: now) else { return }

    writeLog("Starting background update check (channel: \(channel))...")
    let fetchResult = fetchLatestReleaseInfo()
    if case .networkError = fetchResult {
        recordBackgroundUpdateFailure(config: &config, now: now)
        _ = saveConfig(config)
        writeLog("Background update check failed; retry scheduled after \(backgroundUpdateRetryDelay) seconds.")
        return
    }

    // A successful response starts the normal cooldown. Failed downloads or
    // deployments replace it with the shorter persisted retry deadline below.
    config.lastUpdateCheckTimestamp = now
    config.updateRetryAfterTimestamp = nil
    guard case .success(let release) = fetchResult else {
        _ = saveConfig(config)
        return
    }
    let remoteVersion = release.tagName
    guard isNewerVersion(remoteVersion, than: autoMountVersion) else {
        _ = saveConfig(config)
        return
    }

    writeLog("New version discovered: \(remoteVersion) (current: \(autoMountVersion)), channel: \(channel)")

    if channel == "notify" {
        // 单版本仅提醒 1 次防打扰机制
        if config.lastNotifiedVersion == remoteVersion {
            writeLog("Update notification for \(remoteVersion) already presented once. Skipping.")
            _ = saveConfig(config)
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
        // Persist the successful release check before attempting installation.
        // If the process exits during deployment, the config still records the
        // check and a failed attempt can replace the 24-hour cooldown.
        _ = saveConfig(config)
        guard let sourceCode = downloadLatestSource(tag: remoteVersion) else {
            recordBackgroundUpdateFailure(config: &config, now: Date().timeIntervalSince1970)
            _ = saveConfig(config)
            writeLog("Update source download failed; retry scheduled after \(backgroundUpdateRetryDelay) seconds.")
            return
        }
        if !performSelfUpdate(newVersion: remoteVersion, newContent: sourceCode, isSilent: true) {
            recordBackgroundUpdateFailure(config: &config, now: Date().timeIntervalSince1970)
            _ = saveConfig(config)
            writeLog("Automatic deployment failed; retry scheduled after \(backgroundUpdateRetryDelay) seconds.")
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

    let sourceURL = currentAppDir.appendingPathComponent("auto_mount.swift")
    let sourceConfigURL = currentAppDir.appendingPathComponent("auto_mount.plist")
    let sourceExists = FileManager.default.fileExists(atPath: sourceURL.path)
    let installedSourceURL = installDir.appendingPathComponent("auto_mount.swift")
    let installedBinaryURL = installDir.appendingPathComponent("auto_mount")
    let installedConfigURL = installDir.appendingPathComponent("auto_mount.plist")
    let shouldSeedRuntimeConfig = !FileManager.default.fileExists(atPath: installedConfigURL.path)
    let stagedBinaryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("automount-sync-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: stagedBinaryURL) }

    if !shouldSeedRuntimeConfig && loadConfig(from: installedConfigURL) == nil {
        fputs("✗ Existing daemon config is invalid or could not be migrated; runtime synchronization stopped.\n", stderr)
        writeLog("Daemon synchronization aborted because the existing runtime config is invalid or could not be migrated")
        return false
    }

    var replacements: [StagedFileReplacement] = []
    if sourceExists {
        let compile = compileOptimizedSwiftSource(sourceURL: sourceURL, outputURL: stagedBinaryURL)
        guard compile.status == 0 else {
            fputs("✗ Swift source compilation failed; installed files were not replaced.\n", stderr)
            fputs(compile.stderr, stderr)
            writeLog("Daemon synchronization compilation failed: \(compile.stderr)")
            return false
        }
        replacements.append(StagedFileReplacement(sourceURL: stagedBinaryURL, destinationURL: installedBinaryURL, permissions: 0o755))
        replacements.append(StagedFileReplacement(sourceURL: sourceURL, destinationURL: installedSourceURL, permissions: 0o755))
    } else {
        let binaryURL = currentAppDir.appendingPathComponent("auto_mount")
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else { return false }
        replacements.append(StagedFileReplacement(sourceURL: binaryURL, destinationURL: installedBinaryURL, permissions: 0o755))
    }
    if shouldSeedRuntimeConfig && FileManager.default.fileExists(atPath: sourceConfigURL.path) {
        replacements.append(StagedFileReplacement(sourceURL: sourceConfigURL, destinationURL: installedConfigURL, permissions: 0o600))
    }

    do {
        try replaceFilesTransactionally(replacements)
    } catch {
        fputs("✗ Failed to synchronize daemon files; rollback was attempted: \(error.localizedDescription)\n", stderr)
        writeLog("Daemon synchronization failed and rollback was attempted: \(error.localizedDescription)")
        return false
    }

    writeLog("Synchronized current workspace build to LaunchAgent runtime; existing daemon config was preserved. The new files will be read on a config-change trigger or the next launch within 60 seconds.")
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
            print(tr("✓ 已将后台守护服务文件同步至 v\(currentVersion)；配置变化触发或不超过 60 秒的下次启动时读取新文件。",
                     "✓ Daemon files are synchronized to v\(currentVersion); the service will read them on a config-change trigger or its next launch within 60 seconds."))
        } else {
            print(tr("✗ 同步至后台守护服务失败，请尝试运行 './auto_mount --install'。",
                     "✗ Failed to sync daemon service. Try running './auto_mount --install' manually."))
        }
    } else {
        print(tr("已跳过后台守护服务同步。", "Skipped daemon service sync."))
    }
}

func restartCurrentProcess() -> Never {
    let args = CommandLine.arguments
    let exeURL = URL(fileURLWithPath: args[0]).resolvingSymlinksInPath()
    var cArgs: [UnsafeMutablePointer<CChar>?] = args.map { str in
        str.withCString { strdup($0) }
    }
    cArgs.append(nil)
    _ = exeURL.path.withCString { exePathCStr in
        execv(exePathCStr, cArgs)
    }
    exit(1)
}

func checkAndSyncWorkspaceFromInstalledDaemonIfNeeded() {
    let currentAppDir = getAppDir()
    let installDir = getInstalledDir()
    guard currentAppDir.path != installDir.path else { return }

    guard let installedVersion = getInstalledAppVersion() else { return }
    guard isNewerVersion(installedVersion, than: autoMountVersion) else { return }

    // Check git cleanliness of auto_mount.swift if inside a git repository
    let swiftPath = currentAppDir.appendingPathComponent("auto_mount.swift").path
    if FileManager.default.fileExists(atPath: swiftPath) {
        let gitCheck = runCommand(executable: "/usr/bin/git", arguments: ["-C", currentAppDir.path, "status", "--porcelain", "auto_mount.swift"])
        if gitCheck.status == 0 && !gitCheck.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Local modifications exist! Prompt user for safety
            print(tr("\n💡 检测到后台守护服务版本 (v\(installedVersion)) 高于当前工作区 (v\(autoMountVersion))，但本地 auto_mount.swift 存在未提交的代码修改。",
                     "\n💡 Daemon service version (v\(installedVersion)) is newer than workspace (v\(autoMountVersion)), but local auto_mount.swift has uncommitted modifications."))
            print(tr("是否确认放弃本地修改并同步至最新版本？(y/N) [默认 N]: ",
                     "Discard local changes and sync to latest version? (y/N) [Default N]: "), terminator: "")
            let answer = (readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "n")
            if answer != "y" && answer != "yes" {
                print(tr("已跳过工作区更新，继续使用当前版本执行。\n", "Skipped workspace update, continuing with current version.\n"))
                return
            }
        }
    }

    let installedSwiftURL = installDir.appendingPathComponent("auto_mount.swift")
    let localSwiftURL = currentAppDir.appendingPathComponent("auto_mount.swift")
    guard FileManager.default.fileExists(atPath: installedSwiftURL.path) else { return }

    let temporaryDirectory = FileManager.default.temporaryDirectory
    let stagedSourceURL = temporaryDirectory.appendingPathComponent("automount-workspace-sync-\(UUID().uuidString).swift")
    let stagedBinaryURL = temporaryDirectory.appendingPathComponent("automount-workspace-sync-\(UUID().uuidString)")
    var stagedConfigURL: URL?
    defer {
        try? FileManager.default.removeItem(at: stagedSourceURL)
        try? FileManager.default.removeItem(at: stagedBinaryURL)
        if let stagedConfigURL {
            try? FileManager.default.removeItem(at: stagedConfigURL)
        }
    }

    let localBinaryURL = currentAppDir.appendingPathComponent("auto_mount")
    let shouldCompileBinary = FileManager.default.fileExists(atPath: localBinaryURL.path)
    do {
        try atomicCopyFile(from: installedSwiftURL, to: stagedSourceURL, permissions: 0o755)
        let compileResult = compileOptimizedSwiftSource(sourceURL: stagedSourceURL, outputURL: stagedBinaryURL)
        guard compileResult.status == 0 else {
            fputs("✗ Could not compile the installed source for the workspace.\n", stderr)
            fputs(compileResult.stderr, stderr)
            writeLog("Workspace synchronization compilation failed: \(compileResult.stderr)")
            return
        }
    } catch {
        fputs("✗ Failed to sync auto_mount.swift from daemon: \(error.localizedDescription)\n", stderr)
        writeLog("Workspace source/binary synchronization failed: \(error.localizedDescription)")
        return
    }

    // Sync or migrate config for workspace
    let installedPlistURL = installDir.appendingPathComponent("auto_mount.plist")
    let localPlistURL = currentAppDir.appendingPathComponent("auto_mount.plist")
    let localConfigExists = FileManager.default.fileExists(atPath: localPlistURL.path)
    let installedConfigExists = FileManager.default.fileExists(atPath: installedPlistURL.path)
    let configSourceURL = localConfigExists ? localPlistURL : (installedConfigExists ? installedPlistURL : nil)
    if let configSourceURL {
        let stagedURL = temporaryDirectory.appendingPathComponent("automount-workspace-config-\(UUID().uuidString).plist")
        stagedConfigURL = stagedURL
        do {
            try atomicCopyFile(from: configSourceURL, to: stagedURL, permissions: 0o600)
        } catch {
            fputs("✗ Could not stage the workspace config: \(error.localizedDescription)\n", stderr)
            writeLog("Workspace config staging failed: \(error.localizedDescription)")
            return
        }
        let migration = runCommand(executable: stagedBinaryURL.path, arguments: ["--migrate-only", stagedURL.path])
        guard migration.status == 0 else {
            fputs("✗ Workspace config migration failed; workspace files were not replaced: \(migration.stderr)\n", stderr)
            writeLog("Workspace config migration failed before deployment: \(migration.stderr)")
            return
        }
    }

    var replacements = [
        StagedFileReplacement(sourceURL: stagedSourceURL, destinationURL: localSwiftURL, permissions: 0o755)
    ]
    if shouldCompileBinary {
        replacements.append(StagedFileReplacement(sourceURL: stagedBinaryURL, destinationURL: localBinaryURL, permissions: 0o755))
    }
    if let stagedConfigURL {
        replacements.append(StagedFileReplacement(sourceURL: stagedConfigURL, destinationURL: localPlistURL, permissions: 0o600))
    }
    do {
        try replaceFilesTransactionally(replacements)
    } catch {
        fputs("✗ Workspace synchronization failed; rollback was attempted: \(error.localizedDescription)\n", stderr)
        writeLog("Workspace synchronization deployment failed and rollback was attempted: \(error.localizedDescription)")
        return
    }

    print(tr("✓ 检测到后台守护服务已升级至 v\(installedVersion)，工作区程序与配置已同步，正在重启当前命令...\n",
             "✓ Daemon service is at v\(installedVersion); the workspace program and config are synchronized. Restarting the current command...\n"))

    restartCurrentProcess()
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

    print(tr("正在完整编译并预检新版本...", "Compiling and validating the complete new version..."))
    if !performSelfUpdate(newVersion: remoteVersion, newContent: source, isSilent: false) {
        exit(1)
    }
}

func printUsage() {
    let configPath = getConfigURL().path
    print(tr("""
    Auto Mount Tool (v\(autoMountVersion))
    ========================

    使用方法:
      ./auto_mount                正常执行 (评估网络策略并挂载匹配目标)
      ./auto_mount --init         安全初始化；已有有效配置时不覆盖
      ./auto_mount --init --reset 明确备份后从头重建工作区配置
      ./auto_mount --config       日常配置管理 (增删目标、修改网关或远程节点、服务管理)
      ./auto_mount --install [--config-source workspace|runtime]
                                  部署守护服务；指定工作区或守护配置来源
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
      ./auto_mount --init         Safe setup; preserves any existing usable config
      ./auto_mount --init --reset Back up and rebuild the workspace config
      ./auto_mount --config       Daily configuration & daemon management menu
      ./auto_mount --install [--config-source workspace|runtime]
                                  Deploy LaunchAgent and select config source
      ./auto_mount --uninstall    Remove LaunchAgent daemon and deployed files
      ./auto_mount --status       Show service status and active mount details
      ./auto_mount --update       Check and self-update to latest release
      ./auto_mount --self-test [--network] [--remote-smb]
                                  Run checks; optionally mount and clean up remote SMB targets
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

    if args.count > 1 && args[1] == "--self-test" {
        let passed = runSelfTests(includeNetworkChecks: args.contains("--network"))
        let remotePassed = args.contains("--remote-smb") ? runRemoteSMBAcceptanceChecks() : true
        exit(passed && remotePassed ? 0 : 1)
    }

    // Internal command: migrate the config and persist it.
    if args.count > 1 && args[1] == "--migrate-only" {
        let migrationConfigURL = args.count > 2
            ? URL(fileURLWithPath: args[2])
            : getConfigURL()
        guard loadConfig(from: migrationConfigURL) != nil else {
            writeLog("Config migration failed: no valid config at \(migrationConfigURL.path)")
            exit(1)
        }
        writeLog("Config migration executed for version \(autoMountVersion)")
        exit(0)
    }

    // 信息类指令跳过自检
    if args.count > 1 {
        let first = args[1]
        if first == "--version" || first == "-v" {
            print(autoMountVersion)
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
            fputs(tr("✗ AutoMount 仅支持 Apple silicon（arm64）；当前架构：\(architecture)。\n",
                     "✗ AutoMount supports Apple silicon (arm64) only; current architecture: \(architecture).\n"), stderr)
        } else {
            fputs(tr("✗ AutoMount 需要 macOS 27.0 或更高版本；当前系统：\(ProcessInfo.processInfo.operatingSystemVersionString)。\n",
                     "✗ AutoMount requires macOS 27.0 or later; current system: \(ProcessInfo.processInfo.operatingSystemVersionString).\n"), stderr)
        }
        exit(1)
    }

    // 工作区自愈嗅探：若发现后台守护服务先一步升级，自动反哺工作区并热重启
    checkAndSyncWorkspaceFromInstalledDaemonIfNeeded()

    // 启动阶段统一扫描并迁移所有可见配置副本
    eagerMigrateVisibleConfigs()

    if args.count > 1 {
        let arg = args[1]
        switch arg {
        case "--init":
            guard args.count == 2 || (args.count == 3 && args[2] == "--reset") else {
                fputs(tr("✗ 用法: ./auto_mount --init [--reset]\n", "✗ Usage: ./auto_mount --init [--reset]\n"), stderr)
                exit(2)
            }
            let succeeded = runInitCommand(resetExistingConfig: args.count == 3)
            exit(succeeded ? 0 : 1)
        case "--config":
            manageConfiguration()
            exit(0)
        case "--install":
            var requestedConfigLocation: InstallConfigLocation?
            if args.count == 2 {
                requestedConfigLocation = nil
            } else if args.count == 4 && args[2] == "--config-source" {
                switch args[3] {
                case "workspace": requestedConfigLocation = .workspace
                case "runtime": requestedConfigLocation = .runtime
                default:
                    fputs(tr("✗ --config-source 只接受 workspace 或 runtime。\n", "✗ --config-source accepts only workspace or runtime.\n"), stderr)
                    exit(2)
                }
            } else {
                fputs(tr("✗ --install 参数无效。用法: ./auto_mount --install [--config-source workspace|runtime]\n",
                         "✗ Invalid --install arguments. Usage: ./auto_mount --install [--config-source workspace|runtime]\n"), stderr)
                exit(2)
            }
            installLaunchAgent(requestedConfigLocation: requestedConfigLocation)
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
    let currentMAC = currentGateway.flatMap { getMACAddress(for: $0.ip, interface: $0.interface) }

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
            print(tr("    ✗ 已跳过: 网关 IP \(gwIP) 处于该策略的用户排除名单中。",
                     "    ✗ Skipped: Gateway IP \(gwIP) is excluded by this profile's user-configured list."))
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
            let retries = min(max(profile.match.retryCount ?? 3, 1), 10)
            let configuredInterval = profile.match.retryInterval ?? 1.0
            let interval = configuredInterval.isFinite ? min(max(configuredInterval, 0), 10) : 1.0
            print(tr("    正在探测 SMB 端口 445: \(profile.match.value) (重试窗口: \(retries) 次, 间隔: \(interval) 秒)...",
                     "    Probing SMB TCP port 445 on \(profile.match.value) (Retry window: \(retries) attempts, interval: \(interval)s)..."))
            if probeHostWithRetries(host: profile.match.value, retries: retries, interval: interval) {
                print(tr("    ✓ 策略命中！(SMB 端口 445 可连接)",
                         "    ✓ Matched! (SMB TCP port 445 is reachable)"))
                matchedProfile = profile
            } else {
                print(tr("    ✗ 在 \(retries) 次尝试后 SMB 端口 445 仍不可连接。",
                         "    ✗ SMB TCP port 445 remained unreachable after \(retries) attempts."))
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
    var failedCount = 0
    for target in profile.targets {
        print(tr("  目标: \(target.mountPath) (\(redactedSMBURL(target.url)))", "  Target: \(target.mountPath) (\(redactedSMBURL(target.url)))"))

        let status = ensureMountPointReady(target: target)
        switch status {
        case .alreadyMountedHealthy:
            print(tr("    ✓ 卷宗已挂载且响应正常，跳过。", "    ✓ Already mounted and responsive, skipping."))
            mountedCount += 1
            continue

        case .readyToMount:
            print(tr("    正在通过 NetFS 系统框架静默挂载...", "    Mounting volume via NetFS..."))
            if silentMount(urlString: target.url, mountPath: target.mountPath) {
                mountedCount += 1
                if profile.preventSpotlightIndex ?? true {
                    disableSpotlightIndex(at: target.mountPath)
                }
            } else {
                failedCount += 1
            }

        case .unmountFailed:
            print(tr("    ✗ 挂载点繁忙或无法清除，跳过此目标。", "    ✗ Mount point busy or cannot be cleared, skipping."))
            failedCount += 1
        }
    }

    print(tr("\n[DONE] 策略 '\(profile.id)' 下已成功挂载 \(mountedCount)/\(profile.targets.count) 个卷宗。",
             "\n[DONE] \(mountedCount)/\(profile.targets.count) volumes mounted under '\(profile.id)'."))
    writeLog("Finished execution of '\(profile.id)': \(mountedCount)/\(profile.targets.count) mounted.")
    triggerBackgroundUpdateCheckIfNeeded(config: &config)
    if failedCount > 0 {
        writeLog("Mount evaluation failed for \(failedCount) configured target(s).")
        exit(2)
    }
}

main()
