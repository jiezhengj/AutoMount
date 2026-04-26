# Auto Mount Tool

Silent auto-mount SMB shares on macOS when connected to designated WiFi. Zero dependencies, no Finder popups, LaunchAgent ready.

## Features

- ✅ **Silent Mounting** — No Finder window popups
- ✅ **No Password Needed** — After initial setup,日常运行无需 sudo
- ✅ **Smart Detection** — Auto-checks server reachability, skips already mounted volumes
- ✅ **Auto-Start** — LaunchAgent support, runs on boot or network change
- ✅ **Zero Dependencies** — Standalone executable, no extra packages required

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

Initial run requires sudo to get current WiFi SSID and save config:

```bash
sudo ./auto_mount --init
```

Example output:
```
Auto Mount Tool - Init Mode
===========================

[1] Getting current WiFi SSID...
  Current SSID: YourWiFi

[2] Configuring mount targets...
  Enter SMB URL (or press Enter to finish): smb://server.local/share
  Enter mount path: /Volumes/share
  ✓ Added: smb://server.local/share -> /Volumes/share
  Add another? (y/n): n
✓ Config saved to: ./auto_mount.plist
  Target SSID: YourWiFi
  Mount targets: 1

[DONE] Init complete! You can now run './auto_mount' without sudo.
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
  Target SSID: YourWiFi

[2] Checking network...
  ✓ Server reachable!

[3] Checking mount points...
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
sudo ./auto_mount --init
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
    <key>target_ssid</key>
    <string>YourWiFiName</string>
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
sudo ./auto_mount --init
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

### macOS Privacy Restrictions

macOS 14+ has strict restrictions on WiFi SSID access. This tool uses the following approach:

1. **First-time initialization**: Uses `sudo wdutil info` to get SSID (requires root)
2. **Save config**: Stores SSID to `./auto_mount.plist`
3. **Daily operation**: Checks server reachability via ping to indirectly determine if on target network

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

### Q: Why does the first run require sudo?

A: macOS 14+ restricts WiFi SSID access for privacy. After first initialization, the SSID is saved to config file, so subsequent runs don't need sudo.

### Q: How to change target WiFi?

A: Re-initialize under the new WiFi network:

```bash
sudo ./auto_mount --init
```

### Q: Mount failed?

A: Check the following:
1. Ensure WiFi credentials are saved to Keychain (first manual mount will prompt to save)
2. Ensure NAS server is online
3. Ensure you're connected to the target WiFi

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
