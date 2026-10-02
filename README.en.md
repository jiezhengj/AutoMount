# Product Overview

automnt is a native, lightweight SMB auto-mounting tool for macOS that matches network policies based on target host TCP 445 reachability and mounts shares through macOS NetFS. If usable credentials exist in Keychain, mounting proceeds silently without interactive password prompts; mount failures return clear status codes and diagnostic logs.

# Key Features

- **Silent Background Mounting**: Operates entirely in the background using macOS native `NetFS.framework`, mounting volumes without opening Finder windows or interrupting desktop workflows.
- **Service Reachability Routing**: Network profiles match based on target host TCP 445 reachability checks (`HostReachabilityProbe`), eliminating dependencies on fragile link-layer MAC addresses or ARP caches.
- **User-Scoped Canonical Install & Shell Integration**: Installs canonically to `~/Library/Application Support/automnt/bin/automnt` and automatically injects its directory into user shell profiles (`.zshrc`, `.bash_profile`, etc.) for global terminal access.
- **Event-Driven Reactive Daemon**: The LaunchAgent daemon triggers strictly on macOS system network configuration changes (`WatchPaths`), completely eliminating periodic polling (`StartInterval`) to ensure zero idle battery and CPU consumption. An internal retry runner (`EvaluationRetryRunner`) accommodates network handshake delays.
- **Bounded Cleanup for Dead Mounts**: Employs Darwin kernel `MNT_NOWAIT` non-blocking mount table snapshots to eliminate `stat()` blocking and spinning beachballs. Only matching SMB mount points undergo bounded cleanup using `diskutil` and fallback `umount -f`.
- **Single Active Configuration Contract**: Uses a single source of truth at `~/Library/Application Support/automnt/automnt.plist`, written atomically with strict `0600` permissions.
- **Spotlight Indexing Protection**: Automatically executes `mdutil -i off` and attempts to write `.metadata_never_index` to protect network volumes from indexing degradation.
- **Compiler-Free Binary Self-Updates**: Directly downloads precompiled binaries from GitHub Releases, validates them in a sandbox, and transactionally updates in place without requiring local Xcode or Swift developer tools.
- **Self-Health Check and Healing**: The executable inspects its binary path, shell profile entry, and LaunchAgent status on launch, automatically healing broken components.
- **Zero External Dependencies**: Implemented purely in native Swift, compiled to a standalone executable optimized for Apple silicon.

# Quick Start

## System Requirements

- Architecture: Apple silicon (arm64)
- Operating System: macOS 27.0 or later

## Installation & First Run

Download the prebuilt `automnt` binary from GitHub Releases:

```bash
chmod +x automnt
./automnt
```

Running `automnt` from a temporary or Downloads folder initiates automated relocation:
1. Installs canonically to `~/Library/Application Support/automnt/bin/automnt`;
2. Removes the temporary download artifact;
3. Injects the CLI PATH entry into the current user's shell configuration;
4. Informs you that `automnt` is now available directly in any new terminal window.

## Upgrading from Legacy Versions (2.7.4)

3.0.0 introduces a unified single-config model and event-driven architecture, and does not provide an in-place migration path for 2.7.4 installations. Legacy users should migrate via the following steps:

1. Perform a complete uninstall using the command from your 2.7.4 installation:
   ```bash
   ./<legacy-binary> --uninstall
   ```
2. Download the 3.0.0 prebuilt binary and run it once:
   ```bash
   chmod +x automnt
   ./automnt
   ```
3. Run the initial configuration wizard to create a canonical configuration:
   ```bash
   automnt --init
   ```

> [!NOTE]
> Under the clean single-model design, legacy configurations are not reused. Please select or enter your target shares in the setup wizard.

## Initial Setup Wizard (`automnt --init`)

Ensure you have connected to your target SMB share at least once via Finder ("Connect to Server", `Cmd + K`) and saved credentials in your Keychain.

Launch the setup wizard:

```bash
automnt --init
```

The wizard guides you through:
1. **[1/4] Active SMB Mount Discovery**: Detects currently mounted SMB shares, allowing multi-selection with Space; hostnames are extracted automatically for reachability probes.
2. **[2/4] Tailscale Peer Discovery**: Automatically enumerates online Tailscale peers if running, simplifying remote network profile configuration.
3. **[3/4] Software Update Policy**: Configures the update channel (`off`, `notify`, or `auto`). Default is `off`.
4. **[4/4] Save & LaunchAgent Deployment**: Writes `automnt.plist` and registers the event-driven background service.

> [!IMPORTANT]
> **Existing Configuration Protection**
> - `automnt --init` preserves existing usable configs without overwriting.
> - To rebuild configuration from scratch, run `automnt --init --reset`. A timestamped backup is created prior to writing.

## Daily Configuration (`automnt --config`)

Manage mount targets, probe hosts, and update preferences using the interactive menu:

```bash
automnt --config
```

The control center supports:
- 📁 **Mount Targets**: Batch-import active mounts, manually enter custom SMB targets, remove targets;
- 🚦 **Network Profiles**: Reorder evaluation priority, edit target host/port, configure retry parameters;
- ⚙️ **Daemon Management**: Inspect LaunchAgent status, view logs, reload or repair the background service;
- 🔄 **Update Settings**: Toggle update channels, check for new releases immediately.

# CLI Interface Reference

```text
Usage:
  automnt                     Evaluate network profiles and mount matching targets
  automnt --init              Safe setup; preserves any existing usable config
  automnt --init --reset      Back up existing configuration and rebuild from scratch
  automnt --config            Daily configuration and daemon management menu
  automnt --install           Deploy or repair LaunchAgent daemon and CLI entry
  automnt --uninstall         Remove LaunchAgent daemon and CLI entry (preserves config)
  automnt --uninstall --purge Full purge (removes daemon, CLI entry, config, and logs)
  automnt --status            Show service status and active mount details
  automnt --update            Check and self-update to latest prebuilt release
  automnt --self-test         Run full automated test suite
  automnt --version, -v       Show software version
  automnt --help, -h          Show this help message

Environment Variables:
  AUTOMNT_LANG=zh|en          Explicitly set terminal UI language
```

# Technical Architecture

## Host Reachability Probing (HostReachabilityProbe)

Network environments are identified by verifying TCP port 445 connectivity against configured server endpoints:
- Sends bounded non-blocking socket requests (default 1000 ms timeout);
- A reachable port confirms network presence;
- Connection refused, host unreachable, or timeout transitions evaluation to the next profile.

## Reactive Event-Driven Daemon

- **Network Change Detection**: Registered LaunchAgent specifies `WatchPaths` for `/Library/Preferences/SystemConfiguration`, triggered by macOS whenever network state alters.
- **Bounded Retry Execution**: `EvaluationRetryRunner` performs limited retries within a configurable window, gracefully handling network handshake delays. If no profile matches, it exits silently with code `2`.
- **Integrity Self-Healing**: Validates `InstallState` on execution and repairs missing plist registrations or stripped shell paths.

## Non-Blocking Mount Snapshots

To prevent thread hangs on broken networks, `automnt` invokes Darwin kernel `getfsstat`:

```swift
let count = getfsstat(nil, 0, MNT_NOWAIT)
```

With `MNT_NOWAIT`, mount status returns instantly from kernel cache without waiting for remote I/O responses.

## Uninstallation Options

- Regular Uninstallation:
  ```bash
  automnt --uninstall
  ```
  Unloads LaunchAgent, cleans up shell profile PATH entries, and preserves configuration and logs.

- Full Purge:
  ```bash
  automnt --uninstall --purge
  ```
  Removes the service, cleans shell profiles, and deletes `~/Library/Application Support/automnt` and `~/Library/Logs/automnt`.
