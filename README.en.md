# Auto Mount Tool

Silent auto-mount SMB shares on macOS when connected to designated WiFi. Zero dependencies, no Finder popups, LaunchAgent ready.

## Features

- ✅ **Silent Mounting** — No Finder window popups
- ✅ **No Password Needed** — After initial setup,日常运行无需 sudo
- ✅ **Smart Detection** — Auto-checks server reachability, skips already mounted volumes
- ✅ **Auto-Start** — LaunchAgent support, runs on boot or network change
- ✅ **Zero Dependencies** — Standalone executable, no extra packages required

## Product Requirements Document (PRD)

### Scenarios
- **LAN Roaming**: Users frequently switch between external networks (e.g., company, cafe) and their home network, expecting automatic NAS mounting upon returning home.
- **Complex Proxy Environments**: Users often have proxy software enabled (e.g., Clash Verge TUN mode + Fake-IP). This hijacks the system's default route, causing high-level network APIs to misidentify the network as "wired" and hijacking internal domains (e.g., `nas.local`) with fake IPs.
- **Completely Silent**: The mounting process should happen entirely in the background without any Finder window popups or `sudo` password prompts during network switches.

### Core Features & Mechanisms
1. **Physical Layer Network Fingerprint (Core Breakthrough)**: The program bypasses the VPN TUN virtual interface, using the underlying ARP protocol to detect the **real router MAC address (BSSID)** connected to the physical network card (e.g., `en0`) as the home network fingerprint. It no longer relies on the WiFi SSID, completely avoiding macOS 14+ strict location privacy restrictions and achieving **true zero-permission (sudo-free) operation**.
2. **Event-Driven Silent Monitoring**: The program does not run continuously in the background. It utilizes macOS native `launchd` to monitor system network state changes. Upon a network switch, `launchd` instantly wakes the program. It compares the current router MAC fingerprint; if mismatched, it safely exits immediately (zero resource overhead); if matched, it initiates the mount.
3. **Domain Name Bypass Compatibility**: Fully supports `.local` domain mounts. For Clash Fake-IP users, simply add `.local` to the direct (Bypass) list in Clash rules to achieve highly stable and fast LAN mounting.

## Requirements

- macOS 10.15+
- Xcode Command Line Tools (for compilation)

## Quick Start

### 1. Compile

```bash
cd /path/to/AutoMount
clang auto_mount.m -framework SystemConfiguration -framework Foundation -framework NetFS -fobjc-arc -o auto_mount
```

> ⚠️ The compiled binary (`auto_mount`) is not tracked by git. Recompile after re-cloning.

### 2. First-Time Initialization

Connect to your home network and run the initialization (gets current router MAC address as the home fingerprint, **no sudo required**):

```bash
./auto_mount --init
```

Example output:
```
Auto Mount Tool - Init Mode
===========================

[1] Getting current network fingerprint (Gateway MAC)...
  Current Gateway MAC: 00:11:22:33:44:55

[2] Configuring mount targets...
  Enter SMB URL (or press Enter to finish): smb://server.local/share
  Enter mount path: /Volumes/share
  ✓ Added: smb://server.local/share -> /Volumes/share
  Add another? (y/n): n
✓ Config saved to: ./auto_mount.plist
  Target Gateway MAC: 00:11:22:33:44:55
  Mount targets: 1

[DONE] Init complete! You can now run './auto_mount' seamlessly.
```

### 3. Test Run

```bash
./auto_mount
```

Example output:
```
Auto Mount Tool
===============

[1] Loading config...
  Target Gateway MAC: 00:11:22:33:44:55

[2] Checking network fingerprint...
  Current Gateway MAC: 00:11:22:33:44:55
  ✓ Network fingerprint matched!

[3] Checking network...
  NAS hostname: your-server.local
  ✓ Server reachable!

[4] Checking mount points...
  /Volumes/your-share-1: not mounted, mounting...
  ✓ Mounted: smb://your-server.local/your-share-1
  /Volumes/your-share-2: already mounted, skipping.

[DONE] 2/2 volumes mounted.
```

## Auto-Start on Boot

### Method: LaunchAgent (Recommended)

```bash
# Create config file
cat << 'EOF' > ~/Library/LaunchAgents/com.user.auto-mount.plist
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.auto-mount</string>
    <key>ProgramArguments</key>
    <array>
        <string>/path/to/auto_mount</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>WatchPaths</key>
    <array>
        <string>/Library/Preferences/SystemConfiguration</string>
    </array>
</dict>
</plist>
EOF

# Load service
launchctl load ~/Library/LaunchAgents/com.user.auto-mount.plist
```

### Triggers

- **RunAtLoad**: Runs automatically on boot
- **WatchPaths**: Runs on network configuration change (WiFi switch, reconnect, etc.)

## Custom Configuration

### Modify Mount Targets

Config file: `./auto_mount.plist`

Re-initialize with `--init`:

```bash
./auto_mount --init
```

Or edit the plist directly:

```bash
nano ./auto_mount.plist
```

Config format:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>target_gateway_mac</key>
    <string>00:11:22:33:44:55</string>
    <key>mount_targets</key>
    <array>
        <dict>
            <key>url</key>
            <string>smb://your-nas.local/your-share</string>
            <key>path</key>
            <string>/Volumes/your-mount-point</string>
        </dict>
    </array>
</dict>
</plist>
```

> ⚠️ Use `hostname.local` format (e.g., `your-nas.local`) instead of `Hostname._smb._tcp.local` service discovery names, which may fail to resolve in some network environments.

### Re-Initialize

If you change WiFi networks, re-initialize:

```bash
./auto_mount --init
```

## How It Works

### Detection Flow

```
1. Load config file (./auto_mount.plist)
   ↓
2. Ping to check if NAS server is reachable
   ↓
3. Iterate through mount target list
   ↓
4. Check if each mount point is already mounted
   ↓
5. Unmounted volumes → Call NetFSMountURLSync for silent mounting
   ↓
6. Mounted volumes → Skip
```

### Silent Mounting Implementation

Uses macOS native `NetFS` framework's `NetFSMountURLSync` function:

```objc
OSStatus status = NetFSMountURLSync(
    cfURL,       // SMB URL
    NULL,        // MountPath (system decides)
    NULL,        // User (reads from Keychain)
    NULL,        // Pass (reads from Keychain)
    NULL,        // OpenOptions
    NULL,        // MountOptions
    &mountPoints // Output mount points
);
```

- Passing `NULL` for username and password makes the system automatically read saved credentials from Keychain
- No Finder windows will appear

### macOS Privacy & VPN Restrictions

macOS 14+ restricts WiFi SSID access, and VPNs (like Clash TUN) obscure network types. This tool uses a robust Layer-2 approach:

1. **Initialization**: Uses `ipconfig` and `arp` to get the physical router's MAC address (BSSID) directly from the network interface, requiring **no root/sudo privileges**.
2. **Save config**: Stores the MAC address to `./auto_mount.plist`.
3. **Daily operation**: Compares the current router's MAC address with the saved one, bypassing any VPN routing layer.

## Management Commands

```bash
# Check service status
launchctl list | grep auto-mount

# Manually start service
launchctl start com.user.auto-mount

# Stop service
launchctl stop com.user.auto-mount

# Uninstall service (no auto-start on boot)
launchctl unload ~/Library/LaunchAgents/com.user.auto-mount.plist

# Reload service
launchctl unload ~/Library/LaunchAgents/com.user.auto-mount.plist
launchctl load ~/Library/LaunchAgents/com.user.auto-mount.plist
```

## File Structure

```
AutoMount/
├── auto_mount.m            # Source code
├── auto_mount              # Compiled executable
├── README.md               # Chinese documentation
├── README_en.md            # English documentation (this file)
└── SKILL.md                # Hermes Agent skill (Chinese)
```

### Config File Locations

```
./auto_mount.plist                          # Runtime config (stores target WiFi SSID)
~/Library/LaunchAgents/com.user.auto-mount.plist         # LaunchAgent config
```

## Command-Line Options

```bash
./auto_mount [options]

Options:
  --init      Initialization mode (requires sudo, saves current WiFi SSID)
  --help      Show help information
```

## FAQ

### Q: Mount fails when Clash TUN mode is active?

A: This tool's physical network detection bypasses TUN's "wired network" misidentification. However, Clash's **Fake-IP mechanism might hijack your NAS domain**.
**Solution**: Add a bypass rule for your `.local` domain (or your specific NAS domain) in your Clash configuration. For example: `DOMAIN-SUFFIX,local,DIRECT`.

### Q: How to change target home network/router?

A: Connect to the new network and run the initialization command again:

```bash
./auto_mount --init
```

### Q: Standard checks for mount failure?

A: Check the following:
1. Ensure NAS credentials are saved to Keychain (check "Remember password" on first manual Finder connection).
2. Ensure NAS server is online.
3. Ensure your router hasn't changed (if you replaced your main router, re-run `--init`).

### Q: "Server not reachable" but NAS is actually online?

A: This might be caused by mDNS service discovery name (`MyNAS._smb._tcp.local`) resolution failure. This format relies on SRV record queries, which can be unstable in some network environments.

**Solution**: Use hostname format `hostname.local` (e.g., `your-nas.local`) instead of service discovery names.

Verification:
```bash
# Test hostname resolution
ping -c 1 your-nas.local

# Compare with service discovery name (may fail)
ping -c 1 YourNAS._smb._tcp.local
```

If hostname works, modify the URL and ping target in `auto_mount.m`, then recompile.

### Q: How to add multiple mount targets?

A: Edit the `getMountTargets()` function in source code, add more SMB URLs and mount points, then recompile.

### Q: How to completely uninstall?

A:

```bash
# 1. Uninstall LaunchAgent
launchctl unload ~/Library/LaunchAgents/com.user.auto-mount.plist
rm ~/Library/LaunchAgents/com.user.auto-mount.plist

# 2. Delete config file
rm ./auto_mount.plist

# 3. Delete executable
rm /path/to/auto_mount
```

## Technical Details

### System Frameworks Used

- **SystemConfiguration** — Network configuration detection
- **NetFS** — Network file system mounting (core of silent mounting)
- **Foundation** — Basic functionality

### Key API

```objc
// Silent mount network volume
OSStatus NetFSMountURLSync(
    CFURLRef url,
    CFURLRef mountpath,
    CFStringRef user,
    CFStringRef password,
    CFDictionaryRef open_options,
    CFDictionaryRef mount_options,
    CFArrayRef *mountpoints
);
```

## License

MIT License

## Author

郑杰 (Jie Zheng)

## Changelog

### v1.1.0 (2026-04-20)

- 🐛 **Fix**: Changed SMB URL from `hostname._smb._tcp.local` to `hostname.local` format to resolve mDNS SRV record parsing failures in some network environments
- 📝 Updated documentation with mDNS troubleshooting guide

### v1.0.0 (2026-04-20)

- ✅ Initial release
- ✅ Silent mounting for multiple SMB volumes
- ✅ Persistent config file support
- ✅ LaunchAgent auto-start support
- ✅ Smart server reachability detection
