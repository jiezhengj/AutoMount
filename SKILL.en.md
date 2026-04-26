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

### Detecting Current WiFi SSID

**⚠️ macOS 26+ Privacy Restrictions (Discovered Through Testing)**

macOS 26 imposes strict restrictions on WiFi SSID access:

| Method | Requires sudo | macOS 26 Availability | Notes |
|--------|---------------|----------------------|-------|
| `airport -I` | ❌ | ❌ Path may not exist | Legacy method |
| `ipconfig getsummary en0` | ❌ | ❌ Returns `<redacted>` | Privacy protection |
| `CoreWLAN` framework | ❌ | ⚠️ Requires location permission | Needs user authorization |
| `SCDynamicStore` | ❌ | ❌ Returns empty SSID | macOS 26 restriction |
| `wdutil info` | ✅ | ✅ Available | Requires sudo |
| `networksetup` | ❌ | ⚠️ Unstable | Environment dependent |

**Recommended: Config File + First-Time Initialization**

Since getting WiFi SSID requires permissions, config file approach is recommended:

```bash
# First run (save current WiFi SSID to config file)
sudo ./auto_mount --init

# Subsequent runs (read SSID from config file, no sudo needed)
./auto_mount
```

**Code for getting SSID (requires root):**
```objc
// Using wdutil command
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
    
    // Parse "SSID : xxx" format
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
3. **macOS 26 WiFi SSID access restricted** — Multiple methods return `<redacted>`, need sudo or location permission
4. **System-level tasks (launchd) outperform Agent Cron** — No external service dependency, boot auto-start, real-time response
5. **C/ObjC implementation is lightest** — ~20KB binary, no dependencies, fastest startup
6. **Config file approach** — First sudo initialization saves SSID, subsequent runs password-free
7. **mDNS Browse ≠ Resolve** — dns-sd -B success doesn't mean hostname resolves to IP; smbutil lookup is reliable fallback

## Config File Location Recommendation

**Recommended: Public location `./auto_mount.plist`**

Reasons:
- sudo saves to `/var/root/.auto_mount_config.plist`, unreadable by normal users
- Public location + `0644` permissions, readable by all users
- Only first init needs sudo for writing

```objc
#define CONFIG_FILE @"./auto_mount.plist"

void saveConfig(NSString *ssid) {
    NSDictionary *config = @{@"target_ssid": ssid};
    [config writeToFile:CONFIG_FILE atomically:YES];
    // Set permissions to world-readable
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0644} 
                                 ofItemAtPath:CONFIG_FILE error:nil];
}
```

## Complete Objective-C Implementation

See AutoMount project: `~/Documents/Project/projects/AutoMount/`

Core features:
- `--init` mode: sudo gets SSID and saves to config file
- Normal mode: Load config → ping check server → silent mount unmounted volumes
- Supports multiple mount targets
- LaunchAgent boot auto-start + network change trigger

## Compilation

After re-cloning, recompile is required:

```bash
cd ~/Documents/Project/projects/AutoMount
clang auto_mount.m -framework SystemConfiguration -framework Foundation -framework NetFS -fobjc-arc -o auto_mount
```
