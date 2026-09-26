# Product Overview

AutoMount is a native, lightweight SMB auto-mount tool for macOS. It selects network policies using the physical gateway MAC or remote SMB service reachability, then mounts shares through macOS NetFS. If usable credentials are available in Keychain, mounting requires no interactive password entry; failures are returned and logged for diagnosis.

# Key Features

- **Silent Background Mounting**: Powered by macOS native `NetFS.framework` deep system calls, operating entirely in the background without spawning Finder windows or interrupting active desktop workflows.
- **Multi-Policy Priority Routing (Profiles)**: Checks network profiles in configured order. A matching LAN profile uses its local SMB targets; if it does not match, the program checks the configured remote SMB endpoint.
- **Physical Gateway MAC Fingerprinting**: The program identifies a gateway and interface from the physical default route or DHCP information, then queries the interface-scoped ARP neighbor entry. Detection depends on the routing and neighbor information macOS exposes at the time.
- **Bounded Cleanup for Dead Mounts**: Uses Darwin kernel `MNT_NOWAIT` mount snapshots. It only switches or unmounts SMB mounts and preserves unrelated filesystems at configured paths. Cleanup uses `diskutil` and a bounded `umount -f` subprocess fallback; it does not start a second unmount while the first child may still be running.
- **Remote SMB Readiness Retries**: Remote profiles probe SMB over TCP port 445 and support retries (3 attempts by default, 1 second apart) for brief reachability delays after wake or a network change. This checks the SMB port; it does not read Tailscale handshake state.
- **Spotlight Protection and Gateway Exclusions**: Profiles can exclude physical gateway IPs entered by the user. After mounting, the program calls `mdutil -i off` and writes `.metadata_never_index`, while recording whether macOS confirmed the indexing change.
- **Auto-Update Channel & Safe Self-Update**: Compares semantic versions against published GitHub Releases. Channels are `off` (default), `notify` (one notification per release), and `auto` (automatic download and upgrade). The updater compiles source and stages config migrations before deployment, rolls back a failed replacement, and retries failed background updates after 15 minutes.
- **Modern Terminal Interactive UI**: Built with native ANSI Raw Mode terminal controls supporting arrow keys, Space to toggle, Enter to submit, and `a` for select all; dynamic discovery scans currently mounted SMB shares and active Tailscale peers with MagicDNS auto-mapping during `--init`.
- **Daily Configuration Management (`--config`)**: Provides an interactive control center for mount targets, network profiles, update policies, and LaunchAgent services. When a daemon config is installed, the menu reads and edits it under Application Support; the status page also reports whether the LaunchAgent is loaded and the latest program run result.
- **Bilingual Terminal Localization (i18n)**: Automatically detects macOS system preferred languages to display English or Simplified Chinese, with override support via `AUTO_MOUNT_LANG=en|zh`.
- **Strict Argument Validation & POSIX Help**: Features standard `--help` / `-h` usage output, strictly validating input arguments and rejecting unknown options to prevent unintended mount triggers.
- **Zero Sudo & Zero External Dependencies**: Implemented purely in native Swift, executed directly via macOS built-in Swift runtime without compilation, requiring no root/sudo privileges during daily operations.

# Quick Start

## Running Options

The project supports macOS 27.0 or later on Apple silicon (arm64) only; Intel Macs are unsupported. It includes the Swift source [auto_mount.swift](auto_mount.swift) and an arm64 prebuilt CLI [auto_mount](auto_mount). Both source execution and daemon installation check the macOS version and CPU architecture. `--install` compiles the daemon using the macOS 27 SDK or later, so Xcode or Command Line Tools must provide that SDK:

```bash
cd /path/to/AutoMount
chmod +x auto_mount
./auto_mount
```

To run the source directly:

```bash
swift auto_mount.swift
```

## First-Time Initialization (`--init`)

Before initializing, ensure you have connected to your NAS share at least once in Finder via "Connect to Server (`Cmd + K`)" and checked "Remember this password in my keychain".

Connect to your home network and run the initialization wizard:

```bash
./auto_mount --init
```

The wizard guides you through a 5-step streamlined workflow:

1. **[1/5] Automatic Gateway MAC Capture**: Detects and displays the physical router hardware fingerprint, with support for a custom MAC override (cannot be empty, used to match the network profile).
2. **[2/5] Active SMB Mount Discovery**: Scans currently mounted SMB volumes in the kernel and presents an ANSI checkbox menu for multi-selection via Space and arrow keys; **supports pressing Enter directly to skip** (mounting zero volumes in this LAN, using it solely as an exclusion condition for remote access); for manual entry, local mount points auto-derive from share names and accept default on Enter (e.g., `/Volumes/<share>`).
3. **[3/5] Tailscale Peer Discovery**: Queries `tailscale status --json` to list active nodes; gracefully skips if no active peers are found; upon device selection, supports auto-mapping from local shares, checkbox selection of active mounts, or entering a share folder name with auto-constructed URL and mount path.
4. **[4/5] Configure Software Update Policy**: Select software update channel (`1. off` default, `2. notify`, `3. auto`), press Enter directly for default `off` with zero external requests.
5. **[5/5] Save Configuration & One-Click Daemon Deployment**: Writes the structured `auto_mount.plist`, and prompts whether to immediately register and activate the system LaunchAgent background daemon (defaults to `Y`, pressing Enter deploys and starts service immediately).

Terminal Checkbox Controls:
- `↑` / `k`: Move cursor up
- `↓` / `j`: Move cursor down
- `Space`: Toggle item selection (`[●]` / `[ ]`)
- `a`: Toggle select all / unselect all
- `Enter`: Confirm selection (or press Enter to skip)
- `Ctrl + C`: Safe exit restoring terminal mode

> [!IMPORTANT]
> **Important: `--init` performs a full overwrite initialization**
> - `--init` is designed to construct an entirely new configuration from scratch and **never reads, merges, or preserves existing historical configuration**.
> - If `auto_mount.plist` already exists on disk, completing the wizard will overwrite the entire file.
> - In the "Select home LAN mount targets" step, pressing Enter to skip **sets that profile's target list to empty; a matching profile ends evaluation without mounting, and existing targets will NOT be retained**.
> - If you already have an existing configuration and only want to add/remove mount points, update router MACs, or refresh Tailscale peers while keeping existing items intact, **do NOT use `--init`; use `./auto_mount --config` instead**.

## Daily Configuration Management (`--config`)

To add new shares, remove obsolete mount points, or update router hardware MACs without starting from scratch (and without accidentally overwriting existing configuration via `--init`), run:

```bash
./auto_mount --config
```

The interactive management menu displays:

Normal workspace commands read the config beside the executable. When an installed daemon config exists, `--config` reads and edits `~/Library/Application Support/AutoMount/auto_mount.plist`, which is also used by the daemon status page; without a runtime config it falls back to the workspace config. A first `--install` seeds the runtime config from the workspace. On reinstall, if both valid configs differ, an interactive run asks which one to use; a non-interactive run keeps the daemon config. Use `--install --config-source workspace` to explicitly replace it from the workspace, or `--config-source runtime` to explicitly keep it. An invalid or newer daemon config is never silently overwritten.

```text
Auto Mount Tool - Daily Configuration Management (v2.7.0)
======================================================

Currently configured profile pipeline (Evaluated top-to-bottom, first match wins):
  [1] [LAN] local_lan (Local LAN Direct) - 0 targets (a match ends profile evaluation)
  [2] [Remote] remote_network (Remote Network (NAS)) - 2 mount targets
      • /Volumes/documents <- smb://nas.example.ts.net/documents
      • /Volumes/media <- smb://nas.example.ts.net/media

Software Version: v2.7.0 | Auto-Update Channel: auto (Silent background auto-update)
Background Daemon Status: Loaded and idle, waiting for a trigger; runtime config present (gui/<uid>)

Select module:
  [●] 📁 Mount Target Management (Batch import active mounts, manual add, batch delete)
  [ ] 🚦 Network Profile Pipeline (Adjust priority pipeline, create profile, edit rules, delete)
  [ ] ⚙️ Background Daemon Management (Deploy LaunchAgent, view runtime status, uninstall)
  [ ] 🔄 Auto-Update Settings (Switch update channel, check & upgrade now)
  [ ] 🚪 Exit Configuration Management
(↑/↓ Move cursor, Enter confirm selection, Esc cancel)
```

Each configuration change is written atomically to the active config file. When a LaunchAgent is installed, the program attempts to sync the change to its runtime directory. If that sync fails, the interface reports the error and the daemon continues using the existing runtime config.

## Background Daemon Deployment (`--install`)

If you skipped daemon deployment during `--init` or prefer managing the service via command line (also available under `./auto_mount --config` option `[5]`):

```bash
# Install and activate LaunchAgent daemon (no sudo needed)
./auto_mount --install

# Check service status and active mount points
./auto_mount --status

# Check and self-update to latest release (with full compile check)
./auto_mount --update

# Uninstall service and clean deployment files
./auto_mount --uninstall

# Show CLI usage and environment variable options
./auto_mount --help
```

`--install` compiles the CLI and deploys the executable and source into `~/Library/Application Support/AutoMount`. On first install, it seeds the runtime config from the workspace. On reinstall, it compares user settings while ignoring the version and daemon update-check state. If configs differ, an interactive run asks which one to use; a non-interactive run keeps the daemon config. Use `--install --config-source workspace` to explicitly replace the runtime config, or `--install --config-source runtime` to keep it. An invalid or newer daemon config is never silently overwritten. The LaunchAgent runs the deployed source through the system Swift runtime so it can read interface-scoped network state in the logged-in session; the compiled executable remains available for interactive commands. Login, network configuration changes, daemon config changes, and a 60-second interval trigger policy evaluation so the service retries if the network becomes ready later.

Run network acceptance with `./auto_mount --self-test --network --remote-smb`. The `--remote-smb` check reads the configured remote profile and uses a matching peer's Tailscale address when available, avoiding a local DNS answer that could send the test over the home LAN. It temporarily mounts each SMB share under the user's cache directory, verifies its mounted source, and unmounts it. ARP checks are reported as `SKIP` when the current process cannot read ARP output; skipped checks are not counted as passed.

# Configuration Reference

The configuration file is located at `auto_mount.plist` using Apple Property List (XML) format. Example multi-policy configuration:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>version</key>
    <string>2.7.0</string>
    <key>update_channel</key>
    <string>off</string>
    <key>profiles</key>
    <array>
        <!-- Policy 1: Local LAN Direct Connection (High Priority) -->
        <dict>
            <key>id</key>
            <string>local_lan</string>
            <key>description</key>
            <string>Local LAN High-Speed Direct Connection</string>
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

        <!-- Profile 2: Remote Interconnection (Tailscale / WireGuard / DDNS / IP) -->
        <dict>
            <key>id</key>
            <string>remote_network</string>
            <key>description</key>
            <string>Remote Interconnection Fallback</string>
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
            <!-- Documentation example only; replace with a gateway IP the user wants to exclude. -->
            <key>exclude_gateway_ips</key>
            <array>
                <string>192.0.2.1</string>
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
| `version` | String | Schema version kept in sync with the software version (e.g., `2.7.0`). The program migrates existing config when loading an older schema. |
| `update_channel` | String | Software update strategy: `off` (disabled, default), `notify` (system notification banner), or `auto` (silent background upgrade). |
| `last_update_check_timestamp` | Real | Unix timestamp of the latest update-check attempt; absent a failure retry, normal checks are 24 hours apart. |
| `update_retry_after_timestamp` | Real | Retry deadline after a failed background check or automatic deployment; once it expires, it bypasses the normal 24-hour interval. |
| `last_notified_version` | String | Latest remote release tag that was notified, ensuring at most one notification per new version. |
| `profiles` | Array | Ordered policy list. Evaluated sequentially; the first matching profile executes and terminates subsequent evaluations. |
| `id` | String | Unique profile identifier (e.g., `local_lan`, `remote_network`). Legacy profile IDs (`home_lan`, `tailscale_remote`) are automatically migrated in-place to current schema upon loading. |
| `description` | String | Human-readable profile description. |
| `match.type` | String | Match strategy: `gateway_mac` (physical gateway MAC matching) or `probe_host` (SMB TCP port 445 probe). |
| `match.value` | String | Target match value: MAC address (case-insensitive) or target hostname/MagicDNS domain/IP. |
| `match.retry_count` | Integer | Probe retry attempts for `probe_host` (defaults to 3). |
| `match.retry_interval` | Real | Probe retry interval in seconds (defaults to 1.0). |
| `exclude_gateway_ips` | Array | User-supplied physical gateway IPs that should skip this profile. No gateway is excluded by default. |
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
- Software version and configured auto-update channel

## Software Updates & Self-Upgrade (`--update`)

Check for updates and self-upgrade AutoMount anytime via:

```bash
./auto_mount --update
```

The self-update process follows these checks and update steps:
1. **Release and Semantic Version Check**: A commit push alone does not trigger updates. The updater queries the latest published GitHub Release and installs it only when its semantic version is newer and its tagged source embeds the same version.
2. **Bidirectional Automatic Version Alignment & Workspace Self-Healing**:
   - **Workspace to runtime**: Running `--update` from the workspace updates existing workspace and runtime files. A loaded LaunchAgent stays running and reads the new files on a config-change trigger or its next launch within 60 seconds.
   - **Runtime to workspace**: A workspace command that detects a newer installed version can sync its source, compile the executable, and migrate config when workspace synchronization is allowed.
3. **Config Migration**: Config files are copied to temporary files and migrated by the new program. Deployment starts only after the program and target configs are ready; a migration failure leaves the originals untouched.
4. **Full Build and Rollback**: Downloaded source is compiled before deployment. Program, source, and config files are replaced as one rollback-capable operation; a replacement failure restores files already replaced.
5. **Daemon Continues Running**: The updater does not call `launchctl bootout` from the running daemon. The LaunchAgent uses stable runtime paths and reads the new files on a config-change trigger or its next launch within 60 seconds; the updater does not start a service that was previously unloaded.

## Print Version (`--version`, `-v`)

Output raw version number directly for scripting or environment inspection:

```bash
./auto_mount --version
```


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

AutoMount does not read the Wi-Fi SSID. It first checks whether the IPv4 default route uses a physical Ethernet interface. If the default route uses a virtual interface, it attempts to read the gateway from DHCP information for physical interfaces and then queries the interface-scoped ARP neighbor entry. Detection depends on the routing, DHCP, and ARP information exposed by macOS; network services and VPN configuration can affect the result.

## 2. Kernel Non-Blocking Mount Queries & Timeout Forced Unmount

After a network change or wake, an existing SMB mount may temporarily stop responding. AutoMount checks the kernel mount table with Darwin `getmntinfo(..., MNT_NOWAIT)` to avoid actively accessing the remote filesystem during this check.

AutoMount employs a two-tier protection mechanism:
1. **Non-Blocking Mount Table Check**: Uses `getmntinfo(..., MNT_NOWAIT)` to read the kernel mount snapshot without issuing a remote file operation for this check.
2. **Bounded SMB Cleanup**: If an SMB source at a configured path is unreachable or differs from the target share, the program runs `diskutil unmount force <mountPath>`, then tries `umount -f <mountPath>` within the remaining time if needed. It terminates timed-out children and does not start a second unmount while the first child may still be running. Other filesystem types are preserved and reported as conflicts.

## 3. NetFS Silent Mounting Core

The tool interfaces directly with macOS internal `NetFS.framework`:

```swift
var mountPoints: Unmanaged<CFArray>?
let openOptions = NSMutableDictionary()
openOptions[kNAUIOptionKey as String] = kNAUIOptionNoUI as String
let status = NetFSMountURLSync(
    url as CFURL,
    mountpointURL,
    nil,
    nil,
    openOptions as CFMutableDictionary,
    nil,
    &mountPoints
)
```

In this fragment, `url` and `mountpointURL` are validated inputs. For a missing standard `/Volumes/<share>` path, `mountpointURL` is `nil` so NetFS can create the mount directory; other targets pass their configured path. The program leaves username and password parameters empty and sets the non-interactive NetAuth option. macOS can use existing SMB credentials from the user's Keychain. If no usable credential is available, mounting fails with a diagnostic instead of opening a credential prompt.

# Frequently Asked Questions (FAQ)

### Q: Why do connection errors occur when Clash TUN mode is active?

With proxy TUN routing enabled, the system default route may use a virtual interface. AutoMount attempts to fall back to DHCP gateway information for physical interfaces; if that information is unavailable, the status page reports that gateway or MAC detection failed. For remote SMB failures, also check proxy rules and target hostname resolution.

**Solution**: Add a direct bypass rule in your proxy configuration for internal NAS domains (e.g., `DOMAIN-SUFFIX,local,DIRECT`).

### Q: Why is Tailscale MagicDNS preferred over virtual IP addresses?

Tailscale MagicDNS domains (e.g., `nas.example.ts.net`) provide a stable hostname that can be reused across networks with the matching SMB Keychain entry. Name resolution still depends on the current Tailscale and system DNS state.

### Q: What should I check if mounting fails with permission errors?

1. Open Finder, press `Cmd + K`, enter your SMB URL (e.g., `smb://nas.local/share`), provide credentials, and ensure **"Remember this password in my keychain"** is checked.
2. Once verified accessible in Finder, AutoMount can mount the share silently in the background.

### Q: How do I update configuration after replacing my home router?

Since the physical router MAC address has changed, run:

```bash
./auto_mount --config
```

Select `[4] Update home gateway MAC`. The program detects the new hardware fingerprint and updates configuration automatically.

### Q: What is the difference between `--init` and `--config`? What happens if I press Enter to skip mount targets in `--init`?

- **`--init` (Full Scratch Initialization)**: Intended for first-time setup or clean rebuilds. The wizard builds an entirely new configuration object from scratch and **never reads, merges, or preserves existing settings**. Pressing Enter to skip in the mount target selection step sets the target list to empty (`targets: []`). When that profile matches, evaluation ends without mounting; on completion, `--init` **overwrites the existing `auto_mount.plist` configuration file**.
- **`--config` (Incremental Daily Management)**: Intended for ongoing configuration maintenance. It loads existing configuration into memory, preserving all unedited settings, and allows adding new targets, removing specific targets, refreshing gateway MACs, or updating remote peers. Changes are safely saved back to disk and hot-synced to the LaunchAgent daemon. Always use `--config` for daily maintenance.

### Q: How do I synchronize changes to the running LaunchAgent daemon after modifying local workspace code?

When updating local repository code via Git or editing scripts in the workspace, you can apply updates to the active daemon via:
1. Run `./auto_mount --install`: deploys the latest workspace code and restarts the service. A first install seeds the daemon config from the workspace. If the two configs differ on reinstall, an interactive run asks which one to use; non-interactive runs preserve the daemon config. Use `./auto_mount --install --config-source workspace` to explicitly replace it.
2. Self-update: With the `auto` channel or `./auto_mount --update`, the updater validates the source and config before deployment. The daemon reads the new version on a config-change trigger or its next launch within 60 seconds.

### Q: Does software update generate unauthorized background network requests?

AutoMount maintains strict data privacy and zero unexpected external traffic:
- **Default policy is `off`**: By default, the program never reaches out to GitHub or external servers in the background. Update checks are strictly user-initiated via `./auto_mount --update`.
- **Check interval**: After a successful release query, normal checks wait 24 hours. Network, download, or deployment failures schedule a retry after 15 minutes, avoiding both per-minute retries and a full-day delay after a failed update.

### Q: What is the frequency and notification limit for the `notify` channel?

The `notify` channel features built-in alert throttling and anti-fatigue controls:
1. **Normal Check Interval**: Successful checks are 24 hours apart; a failed check is retried after 15 minutes.
2. **Single Notification Cap**: Tracked via `last_notified_version` in the configuration. Once a notification banner is displayed for a newly discovered release, AutoMount never presents repeated alerts for that same version, remaining completely quiet until an even newer release is published.

### Q: Do I need to manually update configuration files or re-run `--init` after updating the software?

An existing valid config does not need to be recreated after a software update. The program updates its schema version, adds defined defaults, migrates supported profile IDs and descriptions, and preserves unrecognized config fields. Workspace and runtime configs migrate independently. When a LaunchAgent is installed, `--config` reads and edits the runtime config in Application Support.

# License

MIT License
