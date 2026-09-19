# Product Overview

AutoMount is a native, lightweight network storage (SMB) automation tool designed specifically for macOS. Engineered for multi-network roaming scenarios (seamless transitions between home local networks and remote mobile work environments), it pierces through VPN and proxy interference, leveraging physical gateway MAC fingerprinting alongside Tailscale remote interconnection. It delivers a completely silent, password-free, and timeout-fused network volume mounting experience.

# Key Features

- **Silent Background Mounting**: Powered by macOS native `NetFS.framework` deep system calls, operating entirely in the background without spawning Finder windows or interrupting active desktop workflows.
- **Multi-Policy Priority Routing (Profiles)**: Supports priority-ordered network profiles. Prioritizes gigabit/2.5G high-speed local home connections, gracefully falling back to Tailscale virtual overlay networking when away from home.
- **Physical Gateway MAC Fingerprinting**: Bypasses VPN TUN virtual network interfaces, directly querying the underlying ARP cache on physical interfaces (such as `en0`) for the router's physical hardware MAC address (BSSID). Fully exempt from macOS 14+ CoreLocation privacy restrictions and immune to proxy TUN hijacking or Fake-IP conflicts.
- **Timeout-Fused Forced Cleanup for Dead Mounts**: Utilizes Darwin kernel `MNT_NOWAIT` non-blocking mount table snapshots. Upon network switching or remote server unavailability, triggers an asynchronous unmount with a strict 3-second timeout fuse (`diskutil unmount force` with POSIX `unmount(MNT_FORCE)` kernel fallback), preventing filesystem I/O locks and system beachball freezes.
- **Tailscale Handshake Readiness Retry Window**: Provides a lightweight retry window (default 3 attempts with 1.0s intervals) to accommodate the delay required for WireGuard tunnels to establish handshakes upon lid open or network handoff.
- **Cellular Hotspot & Spotlight Protection**: Automatically executes `mdutil -i off` and writes `.metadata_never_index` upon mounting to suppress remote metadata indexing, conserving mobile data and avoiding unnecessary NAS disk spin-ups; supports `exclude_gateway_ips` to filter metered gateways like iPhone personal hotspots (`172.20.10.1`).
- **Modern Terminal Interactive UI**: Built with native ANSI Raw Mode terminal controls supporting arrow keys, Space to toggle, Enter to submit, and `a` for select all; dynamic discovery scans currently mounted SMB shares and active Tailscale peers with MagicDNS auto-mapping during `--init`.
- **Daily Configuration Management (`--config`)**: Provides an interactive maintenance menu to add/remove mount targets, update gateway MACs, or refresh remote nodes without re-initializing, automatically syncing updates to the active LaunchAgent runtime.
- **Zero Sudo & Zero External Dependencies**: Implemented purely in native Swift, executed directly via macOS built-in Swift runtime without compilation, requiring no root/sudo privileges during daily operations.

# Quick Start

## Running Options

The project includes the native Swift implementation [auto_mount.swift](file:///Users/jiezhengj/Documents/Project/AutoMount/auto_mount.swift) and a wrapper script [auto_mount](file:///Users/jiezhengj/Documents/Project/AutoMount/auto_mount). Run directly via the built-in Swift interpreter:

```bash
cd /path/to/AutoMount
chmod +x auto_mount
./auto_mount
```

Or execute directly via the system Swift runner:

```bash
swift auto_mount.swift
```

## First-Time Initialization (`--init`)

Before initializing, ensure you have connected to your NAS share at least once in Finder via "Connect to Server (`Cmd + K`)" and checked "Remember this password in my keychain".

Connect to your home network and run the initialization wizard:

```bash
./auto_mount --init
```

The wizard guides you through:

1. **Automatic Gateway MAC Capture**: Detects and displays the physical router hardware fingerprint, with support for custom MAC overrides (cannot be empty, serving as the network exclusion baseline).
2. **Active SMB Mount Discovery**: Scans currently mounted SMB volumes in the kernel and presents an ANSI checkbox menu for multi-selection via Space and arrow keys; **supports pressing Enter directly to skip** (mounting zero volumes in this LAN, using it solely as an exclusion condition for remote access); for manual entry, local mount points auto-derive from share names and accept default on Enter (e.g., `/Volumes/<share>`).
3. **Tailscale Peer Discovery**: Queries `tailscale status --json` to list active nodes; gracefully skips if no active peers are found; upon device selection, supports auto-mapping from local shares, checkbox selection of active mounts, or entering a share folder name with auto-constructed URL and mount path.
4. **Configuration Generation**: Writes the structured `auto_mount.plist` with zero manual syntax required.

Terminal Checkbox Controls:
- `↑` / `k`: Move cursor up
- `↓` / `j`: Move cursor down
- `Space`: Toggle item selection (`[●]` / `[ ]`)
- `a`: Toggle select all / unselect all
- `Enter`: Confirm selection (or press Enter to skip)
- `Ctrl + C`: Safe exit restoring terminal mode

## Daily Configuration Management (`--config`)

To add new shares, remove obsolete mount points, or update router hardware MACs without starting from scratch:

```bash
./auto_mount --config
```

The interactive management menu displays:

```
Auto Mount Tool - Daily Configuration Management (v2.0)
======================================================

Currently configured profiles:
  [1] home_lan (Home LAN Direct High-Speed) - 0 mount targets (Exclusion Gatekeeper, no local mounts)
  [2] tailscale_remote (Tailscale Remote Peer) - 1 mount target
      • /Volumes/personal_folder <- smb://dx4600.xxx.ts.net/personal_folder

Please select an action:
  [1] Add mount target (Dynamic kernel scan or manual entry with auto-derived path)
  [2] Remove mount target
  [3] Re-detect/Update home gateway MAC
  [4] Re-detect/Update remote Tailscale target (or Configure and Add if not present)
  [0] Save configuration and exit
```

Upon saving, changes are committed to the local `auto_mount.plist` and automatically synced to the LaunchAgent deployment directory for immediate effect.

## Background Daemon Deployment (`--install`)

Register AutoMount with the system service manager:

```bash
# Install and activate LaunchAgent daemon (no sudo needed)
./auto_mount --install

# Check service status and active mount points
./auto_mount --status

# Uninstall service and clean deployment files
./auto_mount --uninstall
```

`--install` deploys the script and configuration into `~/Library/Application Support/AutoMount`, bypassing macOS TCC sandbox restrictions on user folders (Documents/Downloads), and registers `com.user.auto-mount.plist` inside `~/Library/LaunchAgents`. The daemon triggers automatically upon system network events or waking from sleep.

# Configuration Reference

The configuration file is located at `auto_mount.plist` using Apple Property List (XML) format. Example multi-policy configuration:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>version</key>
    <string>2.0</string>
    <key>profiles</key>
    <array>
        <!-- Policy 1: Home LAN Direct Connection (High Priority) -->
        <dict>
            <key>id</key>
            <string>home_lan</string>
            <key>description</key>
            <string>Home LAN High-Speed Direct Connection</string>
            <key>match</key>
            <dict>
                <key>type</key>
                <string>gateway_mac</string>
                <key>value</key>
                <string>00:11:22:33:44:55</string>
            </dict>
            <key>prevent_spotlight_index</key>
            <true/>
            <key>targets</key>
            <array>
                <dict>
                    <key>mount_path</key>
                    <string>/Volumes/documents</string>
                    <key>url</key>
                    <string>smb://nas.local/documents</string>
                </dict>
                <dict>
                    <key>mount_path</key>
                    <string>/Volumes/media</string>
                    <key>url</key>
                    <string>smb://nas.local/media</string>
                </dict>
            </array>
        </dict>

        <!-- Policy 2: Tailscale Remote Connection (Fallback Policy) -->
        <dict>
            <key>id</key>
            <string>tailscale_remote</string>
            <key>description</key>
            <string>Tailscale Remote Interconnection</string>
            <key>match</key>
            <dict>
                <key>type</key>
                <string>probe_host</string>
                <key>value</key>
                <string>nas.example.ts.net</string>
                <key>retry_count</key>
                <integer>3</integer>
                <key>retry_interval</key>
                <real>1.0</real>
            </dict>
            <!-- Exclude metered gateways (e.g. iPhone Personal Hotspot) -->
            <key>exclude_gateway_ips</key>
            <array>
                <string>172.20.10.1</string>
            </array>
            <key>prevent_spotlight_index</key>
            <true/>
            <key>targets</key>
            <array>
                <dict>
                    <key>mount_path</key>
                    <string>/Volumes/documents</string>
                    <key>url</key>
                    <string>smb://nas.example.ts.net/documents</string>
                </dict>
                <dict>
                    <key>mount_path</key>
                    <string>/Volumes/media</string>
                    <key>url</key>
                    <string>smb://nas.example.ts.net/media</string>
                </dict>
            </array>
        </dict>
    </array>
</dict>
</plist>
```

### Schema Reference

| Key | Type | Description |
| :--- | :--- | :--- |
| `version` | String | Configuration schema version (`2.0`). |
| `profiles` | Array | Ordered policy list. Evaluated sequentially; the first matching profile executes and terminates subsequent evaluations. |
| `id` | String | Unique profile identifier (e.g., `home_lan`, `tailscale_remote`). |
| `description` | String | Human-readable profile description. |
| `match.type` | String | Match strategy: `gateway_mac` (hardware ARP BSSID matching) or `probe_host` (host reachability probe). |
| `match.value` | String | Target match value: MAC address (case-insensitive) or target hostname/MagicDNS domain/IP. |
| `match.retry_count` | Integer | Probe retry attempts for `probe_host` (defaults to 3). |
| `match.retry_interval` | Real | Probe retry interval in seconds (defaults to 1.0). |
| `exclude_gateway_ips` | Array | Physical gateway IPs to bypass (e.g., `172.20.10.1` for iPhone tethering). |
| `prevent_spotlight_index` | Boolean | Whether to disable Spotlight indexing on mounted volumes (defaults to `true`). |
| `targets` | Array | List of SMB mount targets under this profile. |
| `targets[].url` | String | Full SMB connection URL (e.g., `smb://nas.local/share`). |
| `targets[].mount_path` | String | Expected local mount directory path (e.g., `/Volumes/share`). |

# Daily Maintenance

## Status & Health Inspection

Inspect active network identification, gateway hardware details, and volume mount states:

```bash
./auto_mount --status
```

The command reports:
- Current physical interface and detected gateway MAC
- Active LaunchAgent daemon state
- Evaluated profile statuses and corresponding kernel mount points

## Operation Logs

Logs are written to `auto_mount.log` alongside the executable, recording network state transitions, mount actions, and errors:

```bash
tail -f ~/Library/Application\ Support/AutoMount/auto_mount.log
```

## LaunchAgent Service Control

Manage the background daemon directly via `launchctl`:

```bash
# Check if service is registered
launchctl list | grep auto-mount

# Trigger an immediate evaluation
launchctl start com.user.auto-mount

# Stop running instance
launchctl stop com.user.auto-mount
```

# Technical Architecture

## 1. Physical Layer Network Fingerprinting

In environments running VPN or proxy software (e.g., Clash Verge in TUN mode), default system routes are captured by virtual TUN interfaces, causing high-level network queries to misreport network interfaces. Furthermore, macOS 14+ imposes strict CoreLocation privacy requirements on Wi-Fi SSID access.

AutoMount navigates beneath virtual interfaces by inspecting the system's IPv4 default physical route interface (e.g., `en0`) and querying the operating system's ARP routing table for the next-hop router hardware MAC address (BSSID). This approach requires zero location permissions, operates without root/sudo privileges, and remains completely immune to proxy virtual routing.

## 2. Kernel Non-Blocking Mount Queries & Timeout Forced Unmount

When roaming outside the home network or waking from sleep, previously mounted SMB shares often become dead or unresponsive. Standard filesystem calls like POSIX `stat()` will block the thread in kernel wait states, leading to application hangs and system beachballs.

AutoMount employs a two-tier protection mechanism:
1. **Zero-Blocking Kernel Snapshot**: Invokes Darwin's native `getmntinfo(..., MNT_NOWAIT)` system call. With `MNT_NOWAIT`, the kernel returns cached mount table entries without issuing remote filesystem network requests, completing in under 1 millisecond.
2. **Timeout-Fused Forced Unmount**: If a mount point is occupied by an unreachable server or source URL mismatch (e.g. switching from local `nas.local` to remote `nas.example.ts.net`), an asynchronous subprocess runs `diskutil unmount force <mountPath>`. If the process fails to exit within 3 seconds, the parent sends `SIGKILL` and immediately executes POSIX `unmount(mountPath, MNT_FORCE)` to release the mount point before attempting new mounts.

## 3. NetFS Silent Mounting Core

The tool interfaces directly with macOS internal `NetFS.framework`:

```swift
var mountPoints: Unmanaged<CFArray>?
let status = NetFSMountURLSync(
    url as CFURL,
    nil,
    nil,
    nil,
    nil,
    nil,
    &mountPoints
)
```

By passing `nil` for username and password credentials, macOS automatically retrieves stored credentials from the user's Keychain. Mounting proceeds silently without spawning Finder windows or interactive authentication prompts.

# Frequently Asked Questions (FAQ)

### Q: Why do connection errors occur when Clash TUN mode is active?

AutoMount's ARP MAC detection is fully immune to TUN routing. If reachability checks fail, the cause is typically **Fake-IP DNS hijacking** intercepting internal domains.

**Solution**: Add a direct bypass rule in your proxy configuration for internal NAS domains (e.g., `DOMAIN-SUFFIX,local,DIRECT`).

### Q: Why is Tailscale MagicDNS preferred over virtual IP addresses?

Tailscale MagicDNS domains (e.g., `nas.example.ts.net`) offer key advantages:
1. **Keychain Credential Continuity**: macOS Keychain binds credentials strictly to hostnames. MagicDNS domains ensure that saved SMB credentials remain valid even across node reconfigurations.
2. **System-Level DNS Resolution**: macOS native DNS resolver handles MagicDNS seamlessly during network transitions.

### Q: What should I check if mounting fails with permission errors?

1. Open Finder, press `Cmd + K`, enter your SMB URL (e.g., `smb://nas.local/share`), provide credentials, and ensure **"Remember this password in my keychain"** is checked.
2. Once verified accessible in Finder, AutoMount can mount the share silently in the background.

### Q: How do I update configuration after replacing my home router?

Since the physical router MAC address has changed, run:

```bash
./auto_mount --config
```

Select `[4] Update home gateway MAC`. The program detects the new hardware fingerprint and updates configuration automatically.

# License

MIT License
