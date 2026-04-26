---
name: macos-silent-smb-mount
version: 1.1.0
description: "Best practices for silent SMB mounting on macOS: mount_smbfs limitations, NetFSMountURLSync solution, macOS 26 privacy restrictions"
metadata:
  requires:
    bins:
      - clang
  prerequisite_skills: []
---

# Silent SMB Mounting on macOS

## Problem Background

macOS (especially 26+) does not automatically mount LAN SMB volumes on boot, even when NAS is online and credentials are saved. Silent mounting (without Finder window popups) is needed for scripts and automation workflows.

## Limitations of mount_smbfs (Discovered Through Testing)

**❌ mount_smbfs cannot read passwords directly from Keychain**

```bash
# This will fail!
mount_smbfs -N //user@server/share /Volumes/xxx
# Output: Authentication error
```

**Reason:**
- mount_smbfs reads passwords from `~/Library/Preferences/nsmb.conf`
- Or requires interactive password input
- **It cannot directly read credentials from macOS Keychain**

**mount_smbfs `-o nobrowse` option:**
```bash
# Can hide mount points (not shown on Desktop/Finder sidebar)
mount_smbfs -o nobrowse //user@server/share /Volumes/xxx
```

**Conclusion: mount_smbfs is not suitable for automation** because it requires plaintext password config files or interactive input.

## Correct Solution: NetFSMountURLSync API

**✅ Use NetFS framework's NetFSMountURLSync function**

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
        NULL,  // MountPath (auto-select)
        NULL,  // User (nil = auto-read from Keychain)
        NULL,  // Pass (nil = auto-read from Keychain)
        NULL,  // OpenOptions
        NULL,  // MountOptions
        &mountPoints
    );
    
    if (mountPoints) CFRelease(mountPoints);
    CFRelease(url);
    
    return (status == noErr) ? 0 : 1;
}
```

**Advantages:**
- ✅ Reads credentials directly from Keychain (triggered by nil parameters)
- ✅ Completely silent, no Finder window popups
- ✅ No password config file needed
- ✅ Suitable for automation scenarios

**Compilation:**
```bash
clang mount_nas.c -framework CoreFoundation -framework NetFS -o mount_nas
```

## Automation Mount Requirements Checklist

Complete solution implementing:

1. **Auto-detection on boot** — launchd startup
2. **WiFi SSID filtering** — Only mount on designated WiFi
3. **Auto-mount on WiFi connection** — Event trigger
4. **Skip already mounted** — Status detection

### Recommended Architecture: launchd + Shell Script

```
launchd (boot startup + event trigger)
    └── check_and_mount.sh
        ├── mount | grep to check if already mounted
        ├── airport -I to get current WiFi SSID
        ├── Check if it's the designated SSID
        └── Call mount_nas (NetFSMountURLSync silent mount)
```

### Identifying Local Network Environment (Physical Probing)

**⚠️ Pain Points: macOS Privacy Restrictions & VPN Routing Hijack (Discovered Through Testing)**

1. **SSID Privacy Restrictions**: macOS 14+ strictly limits SSID access. Non-system apps usually get `<redacted>`. Previously, forcing access with `wdutil info` required `sudo`, ruining the silent automation experience.
2. **TUN Mode Misdirection**: When using global VPNs like Clash TUN mode, the system's default route is hijacked to a virtual interface (`utun`). This causes high-level macOS network APIs to mistakenly believe the system is using a "wired network," causing any logic based on "Wi-Fi state detection" to fail entirely.

**Recommended Ultimate Solution: Physical Layer Gateway MAC Fingerprint (Sudo-Free)**

Since high-level network APIs are compromised by privacy limits and VPNs, we choose "low-level probing": going directly to the data link layer (Layer 2) and asking the physical network card (e.g., `en0`), "What is the MAC address of the physical router you are directly connected to?"

```bash
# First run (records the current physical router's MAC address as the home fingerprint)
./auto_mount --init

# Subsequent runs (compares current router's MAC, mounts if it matches)
./auto_mount
```

**Core Logic for Getting MAC Fingerprint (No root required):**
```objc
// 1. Get physical gateway IP (Uses system underlying DHCP state, unaffected by TUN default route)
NSString* getPhysicalGatewayIP() {
    // Poll physical interfaces en0, en1, etc.
    // Corresponding command: /usr/sbin/ipconfig getoption en0 router
    // Returns the real gateway LAN IP, e.g., 192.168.1.1
}

// 2. Get gateway MAC address from IP (Layer 2 ARP protocol)
NSString* getMACAddressForIP(NSString *ip) {
    // Corresponding command: /usr/sbin/arp -n 192.168.1.1
    // Parse output to get MAC address, e.g., 00:11:22:33:44:55
}
```
**Advantages:**
- ✅ **Completely `sudo`-free**: These basic diagnostic commands are available to all users.
- ✅ **100% Immune to VPN Hijacking**: ARP and physical DHCP states operate at the bottom of the network stack. Clash's Layer 3 TUN tunnel cannot spoof or alter the physical router's MAC address.

### Check if Already Mounted

```bash
if mount | grep -q "/Volumes/nas_share"; then
    echo "Already mounted"
fi
```

### launchd Event Trigger Configuration

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

## Solution Selection Guide

| Scenario | Recommended Solution |
|----------|---------------------|
| Silent mount single SMB share | C CLI tool + NetFSMountURLSync |
| Auto-detection on boot | launchd RunAtLoad |
| WiFi change trigger | launchd WatchPaths or daemon |
| GUI config management needed | Full Swift macOS app (e.g., AutoMount project) |

## Architecture Choice: System-Level vs Agent Cron

**Key Finding: System-level tasks should use launchd, not Agent Cron**

| Solution | Depends on Agent | Response Speed | Use Case |
|----------|-----------------|----------------|----------|
| Agent Cron | ✅ Depends | Minute-level | Needs AI judgment, message notifications |
| launchd | ❌ Independent | Second-level | System-level tasks, real-time response |
| Daemon | ❌ Independent | Millisecond-level | High-performance real-time monitoring |

**NAS auto-mount suits system-level solution because:**
- ✅ Needs boot auto-start
- ✅ Needs real-time WiFi change response
- ✅ No AI logic needed
- ✅ No external service dependency

**Agent Cron is better for:**
- Complex judgment logic
- AI capability invocation
- Message notifications
- Tasks with lower frequency requirements

## mDNS Resolution Troubleshooting (Tested 2026-04-20)

**Symptom:** `NAS_HOSTNAME._smb._tcp.local` cannot be resolved, `ping` and `nslookup` both fail, but NAS is actually online.

**Troubleshooting Steps:**
```bash
# 1. Confirm mDNS can discover service (Browse success ≠ Resolve success)
dns-sd -B _smb._tcp local.

# 2. Use smbutil to query IP directly (bypasses mDNS DNS resolution)
smbutil lookup NAS_HOSTNAME
# Output: IP address of NAS_HOSTNAME: 192.168.1.100

# 3. Verify connectivity with IP address
ping 192.168.1.100
```

**Root Cause Analysis:**
- mDNS has two stages: Browse (discover service) and Resolve (resolve to IP)
- Browse can succeed, but Resolve may fail
- Common causes: Wired network multicast routing issues, firewall blocking UDP 5353, DNS configuration priority issues

**Solution — smbutil lookup:**
```bash
# Get SMB server IP
SERVER_IP=$(smbutil lookup NAS_HOSTNAME 2>/dev/null | grep "IP address" | awk '{print $NF}')
if [ -n "$SERVER_IP" ]; then
    ping -c 1 -t 2 "$SERVER_IP"
fi
```

**Improved approach in auto_mount.m:**
```objc
// Original: Direct ping hostname (fails entirely if mDNS fails)
ping -c 1 -t 2 NAS_HOSTNAME._smb._tcp.local

// Improved: Try hostname first, fallback to smbutil lookup for IP
NSString* resolveServerIP(NSString *hostname) {
    // First try ping hostname
    // If fails, use smbutil lookup to get IP
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/smbutil"];
    [task setArguments:@[@"lookup", hostname]];
    // ... parse output to get IP
}
```

**Note:** When NetFSMountURLSync receives SMB URL, the system also does internal resolution. If mDNS fails, consider replacing hostname in URL with IP:
```objc
// Original
smb://NAS_HOSTNAME._smb._tcp.local/nas_share
// Fallback
smb://192.168.1.100/nas_share
```
But note that Keychain credentials are stored by server name; using IP may require re-saving credentials.

## Key Findings

1. **NetFSMountURLSync is the only reliable silent mounting solution** — Reads credentials directly from Keychain, no popups
2. **mount_smbfs cannot read from Keychain** — Requires plaintext password or config file
3. **Physical layer MAC probing outperforms high-level network APIs** — Perfectly bypasses macOS 14+ SSID restrictions and VPN TUN mode misidentifications, requiring no `sudo`.
4. **System-level tasks (launchd) outperform Agent Cron** — No external service dependency, boot auto-start, real-time response, exits in milliseconds if mismatched (0 overhead).
5. **C/ObjC implementation is lightest** — ~20KB binary, no dependencies, fastest startup
6. **Config file approach** — First initialization saves physical gateway MAC fingerprint, fully password-free.
7. **mDNS Browse ≠ Resolve** — dns-sd -B success doesn't mean hostname resolves to IP; smbutil lookup is reliable fallback

## Config File Location Recommendation

**Recommended: Public location `./auto_mount.plist`**

Reasons:
- sudo saves to `/var/root/.auto_mount_config.plist`, unreadable by normal users
- Public location + `0644` permissions, readable by all users
- Only first init needs sudo for writing

```objc
#define CONFIG_FILE @"./auto_mount.plist"

void saveConfig(NSString *fingerprint) {
    NSDictionary *config = @{@"target_gateway_mac": fingerprint};
    [config writeToFile:CONFIG_FILE atomically:YES];
    // Set permissions to world-readable
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0644} 
                                 ofItemAtPath:CONFIG_FILE error:nil];
}
```

## Complete Objective-C Implementation

See AutoMount project: `~/Documents/Project/projects/AutoMount/`

Core features:
- `--init` mode: Gets physical gateway MAC address as fingerprint and saves to config file (no sudo)
- Normal mode: Load config → compare fingerprint → exit immediately if mismatched → if matched, ping check server → silent mount unmounted volumes
- Supports multiple mount targets
- LaunchAgent boot auto-start + network change trigger

## Compilation

After re-cloning, recompile is required:

```bash
cd ~/Documents/Project/projects/AutoMount
clang auto_mount.m -framework SystemConfiguration -framework Foundation -framework NetFS -fobjc-arc -o auto_mount
```
