# Agent Development Guide for Geistty

A guide for [coding agents](https://agents.md/) working on the Geistty iOS SSH terminal app.

## Project Overview

Geistty is an iOS SSH terminal app built on top of Ghostty's terminal emulator. It uses a custom fork of Ghostty with an External termio backend that enables terminal emulation without a local PTY (which iOS doesn't support).

## Development Philosophy

We're open to bleeding-edge solutions, but **favor approaches that align with the coding style and architectural patterns established by Ghostty's creator (Mitchell Hashimoto) and contributors**, as well as those of the libraries we modify (libxev, SwiftNIO-SSH). When in doubt, look at how similar problems are solved in the upstream codebases.

## Repository Structure

- **Main App**: `Geistty/` - Xcode project and Swift sources
- **Ghostty Fork**: `../ghostty/` - Custom ghostty with iOS support (branch: `ios-external-backend`)
- **libxev Fork**: `../libxev-ios/` - Custom libxev with iOS kqueue support

## Commands

### Building Geistty
```bash
# Quick CI build (simulator, no signing)
cd Geistty && ./ci.sh build

# Build for device
xcodebuild -project Geistty/Geistty.xcodeproj -scheme Geistty -destination "id=DEVICE_ID" -allowProvisioningUpdates

# Build for simulator
xcodebuild -project Geistty/Geistty.xcodeproj -scheme Geistty -destination "platform=iOS Simulator,name=iPhone 17 Pro"
```

### Testing
```bash
# Run all CI checks (build + lint)
cd Geistty && ./ci.sh all

# Run unit tests
cd Geistty && ./ci.sh test

# Run UI tests
cd Geistty && ./ci.sh ui-test
```

See [TESTING.md](TESTING.md) for detailed testing documentation.

### Rebuilding GhosttyKit (when Ghostty changes)
```bash
cd ../ghostty
zig build -Demit-xcframework=true -Dxcframework-target=universal

# Copy to Geistty
cp -R macos/GhosttyKit.xcframework ../geistty/Geistty/Frameworks/

# IMPORTANT: Rename module.modulemap to avoid conflicts with CSSH
for dir in ../geistty/Geistty/Frameworks/GhosttyKit.xcframework/*/Headers/; do
    [ -f "${dir}module.modulemap" ] && mv "${dir}module.modulemap" "${dir}GhosttyKit.modulemap"
done
```

## Directory Structure

```
Geistty/
├── Sources/
│   ├── App/              # App entry point, main views
│   ├── Auth/             # SSH authentication, credentials, keychain
│   ├── Ghostty/          # Ghostty integration, terminal surface
│   ├── SFTP/             # SFTP file browser
│   ├── SSH/              # SSH connection management, tmux control mode
│   ├── Terminal/         # Terminal session, view models
│   └── UI/               # Settings, reusable UI components
├── Frameworks/
│   └── GhosttyKit.xcframework/  # Ghostty static library
├── Resources/
│   └── Fonts/            # Custom fonts (Departure Mono)
└── Assets.xcassets/      # App icons, colors
```

## Key Files

- `Sources/Ghostty/Ghostty.swift` - Main Ghostty integration, Config, App, Surface
- `Sources/Ghostty/FontMapping.swift` - Centralized font name mapping (GUI ↔ Ghostty/CoreText)
- `Sources/Terminal/TerminalContainerView.swift` - Terminal session UI
- `Sources/Terminal/KeyTableIndicatorView.swift` - Vim-style key table indicator
- `Sources/SSH/NIOSSHConnection.swift` - SwiftNIO-SSH connection with Network.framework
- `Sources/SSH/SSHSession.swift` - SSH session wrapper, tmux integration, data flow
- `Sources/SSH/TmuxGateway.swift` - **Actor-based tmux Control Mode gateway (replaces TmuxControlClient)**
- `Sources/SSH/TmuxProtocolParser.swift` - Pure synchronous tmux protocol parser
- `Sources/SSH/KittyKeyboardTranslator.swift` - Kitty → legacy keyboard translation
- `Sources/SSH/TmuxSessionManager.swift` - Multi-pane state management, surface ownership
- `Sources/Auth/ConnectionProfile.swift` - Saved connection profiles
- `Sources/UI/SettingsView.swift` - App settings UI
- `Sources/SFTP/SFTPChannel.swift` - Low-level SFTP protocol implementation
- `Sources/SFTP/SFTPClient.swift` - High-level async SFTP API (for future File Provider)

## Ghostty C API Usage

Geistty uses the Ghostty C API for terminal emulation:

```swift
// Create config with settings
let cfg = ghostty_config_new()
ghostty_config_load_string(cfg, configString, configString.utf8.count)
ghostty_config_finalize(cfg)

// Create app and surface
let app = ghostty_app_new(&runtimeConfig, cfg)
let surface = ghostty_surface_new(app, &surfaceConfig)

// External backend: write data to terminal
ghostty_surface_write_output(surface, data, length)

// Live config update
ghostty_surface_update_config(surface, newConfig)
```

## Custom Ghostty APIs

The `ios-external-backend` branch adds:

1. **External Backend** (`src/termio/External.zig`)
   - Terminal emulation without PTY
   - Write callback for bidirectional I/O

2. **Config APIs** (`src/config/CApi.zig`)
   - `ghostty_config_load_file(config, path, len)` - Load config from file
   - `ghostty_config_load_string(config, str, len)` - Load config from string

## Font Configuration

Fonts are configured via the `font-family` config option:

```swift
// Available fonts
["Departure Mono", "SF Mono", "Menlo", "Courier New"]

// Ghostty mapping
"Departure Mono" -> "DepartureMono-Regular"
"SF Mono" -> "SF Mono"
```

Live font updates use `ghostty_surface_update_config()` with a new config.

## Dependencies

- **Ghostty** - Terminal emulator (custom fork with External backend)
- **libxev** - Event loop (custom fork with iOS kqueue support)
- **SwiftNIO-SSH** - SSH protocol (via daiimus/swift-nio-ssh fork with RSA support)

## tmux Integration

Geistty uses tmux Control Mode (`tmux -CC`) with an actor-based architecture:

### Architecture (Dec 2025)

```
SSH Server → NIOSSHConnection → SSHSession → TmuxGateway.receive()
                                                   ↓
                                        TmuxProtocolParser.parse()
                                                   ↓
                                        AsyncStream<TmuxGatewayEvent>
                                                   ↓
                              SSHSession.handleGatewayEvent() → TmuxSessionManager
                                                   ↓
                                        Ghostty.SurfaceView
```

### Key Components

| Component | Purpose |
|-----------|----------|
| `TmuxGateway` | Swift actor with command queue, health observation, async/await API |
| `TmuxProtocolParser` | Pure synchronous parser: `parse(data, buffer, state) → (messages, buffer, state)` |
| `KittyKeyboardTranslator` | Converts Kitty keyboard protocol to legacy terminal codes for tmux |
| `TmuxSessionManager` | Multi-pane state, surface ownership, layout parsing |

### Control Mode Protocol
### Control Mode Protocol Reference

From tmux wiki: https://github.com/tmux/tmux/wiki/Control-Mode

| Message | Format | Description |
|---------|--------|-------------|
| `%output` | `%output %pane-id data` | Pane output (octal escaped) |
| `%begin` | `%begin timestamp flags` | Command response start |
| `%end` | `%end timestamp flags` | Command response end |
| `%error` | `%error timestamp flags` | Command error |
| `%exit` | `%exit [reason]` | Control client exited |

Octal escapes: Characters <32 and `\` are encoded as `\NNN` (e.g., `\033` for ESC, `\134` for `\`)

## Development Notes

1. **No PTY on iOS** - Use External backend, not Exec backend
2. **Metal Renderer** - iOS uses Metal, not OpenGL
3. **CoreText Fonts** - Font discovery via CoreText on iOS
4. **Module Map Naming** - GhosttyKit uses `GhosttyKit.modulemap` (renamed from `module.modulemap`)

## Do NOT

- Never use `Exec` backend on iOS (no PTY support)
- Don't modify `GhosttyKit.xcframework` directly - rebuild from ghostty repo
- Don't use `print()` for logging - use `Logger` pattern
- Don't assume `log stream --device` exists - use `xcrun devicectl ... --console`

---

## ⚠️ File Provider Development

**STOP. Before touching ANY File Provider code:**

1. Read `FILE_PROVIDER_IMPLEMENTATION.md` completely
2. Check which enumerator is active in `FileProviderExtension.swift` (`enumerator(for:)` method)
3. State your understanding before making changes

### DO NOT (File Provider specific)

- **Do NOT add debug logging as a first step** - the code is already instrumented
- **Do NOT test on device before understanding the problem** - write unit tests first
- **Do NOT repeat failed approaches** - check the "Failed Approaches" section below

### Current State (Jan 3, 2026)

| Question | Answer |
|----------|--------|
| **Active enumerator** | `MetadataStoreEnumerator` (for working set) |
| **Symptom** | "Syncing with Geistty Paused" - testing after dual-cache fix |
| **Alert gone?** | ✅ Yes - error alert no longer appears |
| **Changes reflect?** | 🔄 Testing after dual-cache fix |
| **Last fix applied** | Dual cache consolidation (Jan 3, 2026) |
| **Code removed** | ~500 lines (MetadataCache.swift, CachedItem.swift deleted) |

### Bug Fix History (Jan 3, 2026)

**Fix #2: Dual Cache Consolidation** - 🔄 Testing
- **Root cause discovered:** TWO PARALLEL CACHE SYSTEMS existed:
  - `MetadataCache` + `CachedItem` (~500 lines) - used by RemoteEnumerator for browsing
  - `MetadataStore` + `CachedFileMetadata` - used by MetadataStoreEnumerator
- Directory browsing used `MetadataCache` which held stale data
- **Fix:**
  - Updated `item(for:)` to use `MetadataStore.shared.item(id:)`
  - Updated `enumerateItems` fallback to use `MetadataStore.shared.items(inFolder:)`
  - Rewrote `refreshFromServer()` to only update `MetadataStore`
  - Added full write capabilities to `CachedMetadataItem`
  - **DELETED** `MetadataCache.swift` (359 lines)
  - **DELETED** `CachedItem.swift` (137 lines)
  - **DELETED** `CachedRemoteItem` class

**Fix #1: MetadataStore Commits (Jan 2, 2026)** - ✅ Partial success
- Added `upsert()` calls in `createItem()` and `modifyItem()`
- Added `markDeleted()` call in `deleteItem()`
- Added `signalEnumerator(for: .workingSet)` after all operations
- **Result:** Error alert gone, but stale data issue led to discovery of dual caches

**Earlier Fix: Item Filtering Bug** - ✅ Fixed
- Removed filter that dropped subfolder items
- Test: `testSubfolderFileChangesAreReported()`

### Failed Approaches

1. **Adding more logging** - Created diagnostic bloat, didn't identify root cause
2. **Signaling errors resolved** - `signalErrorResolved()` after SFTP connect - no effect
3. **Async Task{} in callbacks** - Apple docs say async is allowed, Cryptomator does it, didn't help
4. **Parent-in-modified-set filter** - **REMOVED** - caused subfolder items to be dropped

### Key Files

| File | Purpose |
|------|---------|
| `FileProviderExtension.swift` | Main extension, `enumerator(for:)` returns which enumerator |
| `MetadataStoreEnumerator.swift` | Working set enumerator (current) |
| `MetadataStoreEnumeratorTests.swift` | Unit tests for enumerator behavior |
| `MetadataStore.swift` | SwiftData actor, anchor cache - **ONLY source of truth** |
| `CachedFileMetadata.swift` | SwiftData @Model for file metadata |
| `FILE_PROVIDER_IMPLEMENTATION.md` | Full context, history, architecture |

---

## Architecture Decisions

| Decision | Why |
|----------|-----|
| External Backend | iOS sandboxing prevents fork/exec/PTY |
| SwiftNIO-SSH | Pure Swift, Network.framework integration, native async/await |
| tmux Control Mode | Proper protocol integration; Geistty owns scrollback buffer |
| TmuxGateway Actor | Proper concurrency isolation; async/await API; follows SFTPClient pattern |
| TmuxProtocolParser | Pure synchronous parsing; state passed in/out explicitly; actor-friendly |
| DCS 1000p Filter | Prevents dual-parser conflict between Ghostty and TmuxGateway |
| capture-pane for search | Alternate screen mode (tmux, vim) has 0 scrollback by design in terminal emulators |
| libxev fork | iOS uses `kevent`, not `kevent64` |
| Custom module.modulemap name | Renamed to avoid Xcode module conflicts |

## Data Flow

### Regular Mode (No tmux)
```
SSH Server → NIOSSHConnection (SwiftNIO-SSH) → SSHSession → Ghostty.Surface.writeOutput()
                                                         ↓
                                                  Terminal UI (Metal)
                                                         ↓
User Input → Ghostty write callback → SSHSession → NIOSSHConnection.write()
```

### Control Mode (tmux -CC) - Current Architecture
```
SSH Server → NIOSSHConnection → SSHSession.handleReceivedData()
                                        ↓
                              [DCS 1000p filter - prevents Ghostty internal tmux parser conflict]
                                        ↓
                              TmuxGateway.receive(data)
                                        ↓
                              TmuxProtocolParser.parse()
                                        ↓
                              AsyncStream<TmuxGatewayEvent>
                                        ↓
                              SSHSession.handleGatewayEvent()
                                        ↓
                              TmuxSessionManager.routeOutput()
                                        ↓
                              Ghostty.Surface.writeOutput()
                                        ↓
                              Terminal UI (Metal)
                                        ↓
User Input → Ghostty write callback → SSHSession.write()
                                        ↓
                              TmuxGateway.sendKeys(data)
                                        ↓
                              KittyKeyboardTranslator.translate()
                                        ↓
                              "send-keys -H -t %pane hex..." → NIOSSHConnection.write()
```

### Critical: DCS 1000p Filter

The `SSHSession.handleReceivedData()` method filters out `\x1bP1000p` (DCS 1000p) sequences
before forwarding to Ghostty. This is critical because:

1. tmux sends DCS 1000p to signal control mode entry
2. Ghostty has an internal tmux control mode parser that activates on this sequence
3. If both Ghostty's parser AND our TmuxGateway parse the same data, it causes conflicts
4. The filter ensures only TmuxGateway handles the control mode protocol

## Common Pitfalls

- `log stream --device` doesn't exist - use `xcrun devicectl device process launch --console`
- Ghostty alternate screen has 0 scrollback (`Terminal.zig:2631`) - this is correct behavior, not a bug
- Module map conflicts: GhosttyKit must use `GhosttyKit.modulemap` not `module.modulemap`
- Device IDs change between CoreDevice UUID and UDID formats - use `xcrun devicectl list devices`

## Roadmap & Tasks

See `TODO.md` for current tasks, known issues, and planned features.

## Debugging

### Logging Pattern
Use Swift's unified `Logger` with subsystem `com.geistty`:

```swift
import os
private let logger = Logger(subsystem: "com.geistty", category: "YourCategory")

// Usage
logger.info("Info message")
logger.error("Error: \(error.localizedDescription)")
logger.debug("Debug details: \(someValue)")
```

Existing categories: `Ghostty`, `Terminal`, `NIOSSHConnection`, `SSHSession`, `SFTP`, `SSHKey`, `Credentials`, `Keychain`

### SwiftNIO-SSH Debugging

SwiftNIO-SSH provides structured logging via SwiftLog. For protocol-level debugging:

```swift
// Enable verbose logging in NIOSSHConnection
// Logs go to os.Logger category "NIOSSHConnection"
```

Network.framework path monitoring logs use the 📡 emoji prefix for easy filtering.

### Viewing Device Logs
Stream logs from a connected device in real-time using `--console`:

```bash
# Find device ID
xcrun devicectl list devices

# Launch app with console output (streams os_log in real-time)
xcrun devicectl device process launch --device <device-id> --console com.geistty.app

# With grep filter for specific logs
xcrun devicectl device process launch --device <device-id> --console com.geistty.app 2>&1 | grep -E "(SSH|Terminal|capture)" --line-buffered

# Terminate existing, then relaunch with console
xcrun devicectl device process terminate --device <device-id> com.geistty.app 2>&1; \
  xcrun devicectl device process launch --device <device-id> --console com.geistty.app
```

Or use Console.app:
1. Connect device via USB
2. Open Console.app, select device in sidebar  
3. Filter: `subsystem:com.geistty`

### Build & Deploy Workflow
```bash
# Build for device
xcodebuild -project Geistty/Geistty.xcodeproj -scheme Geistty -destination "id=<device-id>" -allowProvisioningUpdates

# Install on device
xcrun devicectl device install app --device <device-id> /path/to/Geistty.app

# Launch app (no console)
xcrun devicectl device process launch --device <device-id> com.geistty.app

# Launch with console output (preferred for debugging)
xcrun devicectl device process launch --device <device-id> --console com.geistty.app
```

### Other Debug Tools
- Check Ghostty logs for terminal errors
- Metal frame capture in Xcode for rendering issues
- Xcode Instruments for performance profiling

## Related Repositories

- `ghostty` (daiimus/ghostty, branch: ios-external-backend)
  - External termio backend for SSH/iOS
  - C API extensions for config loading
  
- `libxev-ios` (daiimus/libxev-ios)
  - iOS kqueue support (uses kevent instead of kevent64)

- `swift-nio-ssh` (daiimus/swift-nio-ssh, branch: add-rsa-support)
  - Fork with RSA key support added
  - Pure Swift SSH implementation with Network.framework integration
