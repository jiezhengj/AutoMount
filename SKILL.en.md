---
name: macos-silent-smb-mount
version: 2.0.0
description: "Standards and best practices for silent SMB mounting and multi-network policy routing on macOS: NetFSMountURLSync Keychain authentication, kernel MNT_NOWAIT non-blocking mount inspection, 3-second timeout circuit breaker, Spotlight indexing protection, and launchd automation."
metadata:
  requires:
    bins:
      - swift
      - launchctl
      - ipconfig
      - arp
      - smbutil
      - diskutil
    frameworks:
      - NetFS
      - SystemConfiguration
      - CoreFoundation
---

# Core Architecture and Decision Model

When mounting network storage volumes in macOS automation workflows, high-level blocking APIs and permission barriers must be avoided by following a deterministic technical path:

```mermaid
flowchart TD
    Start["Trigger Network Mount Evaluation"] --> CheckGW["Physical Layer 2 Gateway Probing\n(ipconfig + ARP)"]
    CheckGW --> HotspotFilter{"Is Excluded Gateway\n(e.g., 172.20.10.1 Hotspot)?"}
    HotspotFilter -- Yes --> ExitSilence["Silent Exit (Preserve Cellular Data)"]
    HotspotFilter -- No --> RouteMatch{"Evaluate Network Profiles"}
    
    RouteMatch -- "LAN Gateway MAC Matched" --> CheckMount["MNT_NOWAIT Kernel Mount Table Scan"]
    RouteMatch -- "Remote Node Reachable" --> ProbeRetry["Tailscale Handshake Retry Window"]
    ProbeRetry --> CheckMount
    RouteMatch -- "No Rule Matched" --> ExitSilence
    
    CheckMount --> SourceAudit{"Already Mounted & Source Matches?"}
    SourceAudit -- Yes --> Done["Keep Mount & Exit"]
    SourceAudit -- "Source Mismatch / Stale" --> ForceUnmount["3-Second Timeout Circuit Breaker"]
    ForceUnmount --> NetFSMount["NetFSMountURLSync Silent Mount"]
    SourceAudit -- Not Mounted --> NetFSMount
    
    NetFSMount --> IndexProtect["Inject .metadata_never_index\nRun mdutil -i off"]
    IndexProtect --> Done
```

## Mount API Selection

* **Avoid `mount_smbfs`**: This command cannot directly read credentials from the macOS Keychain. It mandates plaintext passwords in configuration files or interactive terminal input, and triggers permission alerts on newer macOS versions.
* **Mandate `NetFSMountURLSync`**: A system-level C interface from the NetFS framework. Passing `nil` for username and password automatically invokes Keychain authentication silently without Finder window popups or interactive prompts.

## Network Topology Probing Selection

* **Limitations of High-Level Wi-Fi APIs**: Starting with macOS 14, CoreWLAN access to SSID strings is strictly permission-gated. Furthermore, when global VPNs (e.g., TUN virtual interfaces) are active, default routes are redirected, causing high-level network state checks to report false connection states.
* **Physical Layer 2 ARP Gateway Fingerprinting**: By querying physical interfaces (`en0`, etc.) for their DHCP router IP and reading the Layer 2 ARP table, the physical router's hardware MAC address can be determined. This mechanism bypasses TUN tunnels, accurately reflects the physical environment, and requires no root (`sudo`) privileges.


# Production-Grade Core Code Patterns (Swift)

## Keychain-Integrated Silent Mount Pattern

Mount remote SMB shares cleanly without prompting user dialogs or opening Finder windows:

```swift
import Foundation
import NetFS

func mountSMBVolumeSilently(urlString: String) -> Bool {
    guard let url = CFURLCreateWithString(kCFAllocatorDefault, urlString as CFString, nil) else {
        return false
    }
    
    var mountPoints: Unmanaged<CFArray>?
    // Passing nil for user and password triggers system Keychain authentication
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

## Non-Blocking Kernel Mount Table Inspection

Never use `FileManager.default.fileExists` or POSIX `stat()` on network volume paths that might be unreachable; doing so blocks the calling thread in kernel sleep and causes system spinning beachball hangs. Use `getfsstat` with the `MNT_NOWAIT` flag instead:

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

## Timeout Circuit Breaker and Forced Cleanup

When a network change leaves existing mounts unresponsive, enforce a strict 3-second timeout circuit breaker using a two-stage unmount strategy:

```swift
import Foundation
import Darwin

func forceUnmountStaleVolume(at mountPath: String, timeout: Double = 3.0) -> Bool {
    let group = DispatchGroup()
    var success = false
    
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        // Stage 1: Graceful forced unmount via diskutil
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        task.arguments = ["unmount", "force", mountPath]
        try? task.run()
        task.waitUntilExit()
        
        if task.terminationStatus == 0 {
            success = true
        } else {
            // Stage 2: Low-level POSIX MNT_FORCE unmount
            success = (unmount(mountPath, MNT_FORCE) == 0)
        }
        group.leave()
    }
    
    let result = group.wait(timeout: .now() + timeout)
    return result == .success && success
}
```

## Spotlight Search and Cellular Hotspot Protection

Immediately disable metadata indexing upon mounting to prevent background indexing from saturating remote storage connections and consuming excessive CPU:

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

## Physical Network Topology and ARP Hardware Extraction

Bypass virtual TUN interfaces and extract physical router identifiers directly from Layer 2:

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


# System-Level Automation Standards (LaunchAgent)

Unlike polling-based scripts, macOS-native automation subscribes to network preference changes via launchd `WatchPaths`, achieving zero background memory overhead and sub-second event-driven triggers.

## Service Definition Standard (`~/Library/LaunchAgents/com.user.auto-mount.plist`)

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

## Modern Registration and Lifecycle Management

On macOS 13+, macOS 26+, and macOS 27+, use modern `bootstrap` and `bootout` commands rather than legacy `launchctl load` / `unload`:

```bash
# Obtain current GUI user UID
UID=$(id -u)

# Unload previous service instance if present
launchctl bootout "gui/${UID}/com.user.auto-mount" 2>/dev/null || true

# Register and load service
launchctl bootstrap "gui/${UID}" ~/Library/LaunchAgents/com.user.auto-mount.plist

# Verify current service status
launchctl list | grep com.user.auto-mount
```


# Troubleshooting and Edge Case Runbook

## Remote WireGuard / Tailscale Handshake Latency

* **Symptom**: Immediately after connecting to an external network with Tailscale active, the initial mount attempt occasionally times out.
* **Root Cause**: WireGuard tunnel establishment requires a brief negotiation window (tens to hundreds of milliseconds).
* **Mitigation**: Introduce a retry window during host probing (e.g., 3 retries at 1.0-second intervals) to verify tunnel readiness before initiating NetFS calls.

## Local Area Network mDNS Resolution Instability

* **Symptom**: `smb://server.local/share` occasionally fails to resolve, even though the server is online.
* **Diagnostic Procedure**:
  ```bash
  # 1. Verify service advertisement
  dns-sd -B _smb._tcp local.

  # 2. Bypass mDNS and query direct IP address
  smbutil lookup server
  ```
* **Mitigation**: Configure static hostnames or IP addresses instead of relying solely on mDNS broadcasts, or maintain fallback IP mappings in configuration profiles.
