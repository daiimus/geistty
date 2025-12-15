# Agent Development Guide for Geistty

A guide for [coding agents](https://agents.md/) working on the Geistty iOS SSH terminal app.

## Project Overview

Geistty is an iOS SSH terminal app built on top of Ghostty's terminal emulator. It uses a custom fork of Ghostty with an External termio backend that enables terminal emulation without a local PTY (which iOS doesn't support).

## Development Philosophy

We're open to bleeding-edge solutions, but **favor approaches that align with the coding style and architectural patterns established by Ghostty's creator (Mitchell Hashimoto) and contributors**, as well as those of the libraries we modify (libxev, libssh2). When in doubt, look at how similar problems are solved in the upstream codebases.

## Repository Structure

- **Main App**: `Geistty/` - Xcode project and Swift sources
- **Ghostty Fork**: `../ghostty/` - Custom ghostty with iOS support (branch: `ios-external-backend`)
- **libxev Fork**: `../libxev-ios/` - Custom libxev with iOS kqueue support

## Commands

### Building Geistty
```bash
# Build for device
xcodebuild -project Geistty/Geistty.xcodeproj -scheme Geistty -destination "id=DEVICE_ID" -allowProvisioningUpdates

# Build for simulator
xcodebuild -project Geistty/Geistty.xcodeproj -scheme Geistty -destination "platform=iOS Simulator,name=iPhone 15"
```

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
- `Sources/Terminal/TerminalContainerView.swift` - Terminal session UI
- `Sources/SSH/SSHConnection.swift` - Low-level SSH connection using libssh2
- `Sources/SSH/SSHSession.swift` - SSH session wrapper, tmux integration, data flow
- `Sources/SSH/TmuxControlClient.swift` - tmux Control Mode (-CC) protocol client
- `Sources/Auth/ConnectionProfile.swift` - Saved connection profiles
- `Sources/UI/SettingsView.swift` - App settings UI

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
- **libssh2** - SSH protocol (via Libssh2Prebuild Swift Package)

## tmux Integration

Geistty has special tmux support with two modes:

### Control Mode (Recommended)

Uses tmux's native Control Mode protocol (`tmux -CC`) for proper integration:

```swift
// TmuxControlClient.swift handles:
// - %output %pane-id <octal-escaped-data> → pane output to Ghostty
// - %begin/%end/%error blocks → command responses
// - capture-pane via proper protocol commands
```

Benefits:
- Geistty owns the scrollback buffer (receives all `%output`)
- Search works on buffered content without visible commands
- No marker pollution in terminal output
- Proper handling of escape sequences

### Legacy Mode (Fallback)

Uses marker-based `capture-pane` approach:

```swift
// tmux capture-pane flow (in SSHSession.swift)
// 1. Send capture-pane command with unique markers
// 2. Buffer SSH data until end marker received
// 3. Extract captured content, search within it
// 4. Resume normal terminal data flow
```

### Enabling Control Mode

Control mode is currently opt-in during development:

```swift
// In SSHSession connect methods:
try await session.connect(
    host: "...",
    useTmux: true,
    useControlMode: true  // Enable control mode (default: false)
)
```

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
4. **Module Map Naming** - GhosttyKit uses `GhosttyKit.modulemap` to avoid conflicts with CSSH's `module.modulemap`

## Do NOT

- Never use `Exec` backend on iOS (no PTY support)
- Don't modify `GhosttyKit.xcframework` directly - rebuild from ghostty repo
- Don't use `print()` for logging - use `Logger` pattern
- Don't assume `log stream --device` exists - use `xcrun devicectl ... --console`

## Architecture Decisions

| Decision | Why |
|----------|-----|
| External Backend | iOS sandboxing prevents fork/exec/PTY |
| tmux Control Mode | Proper protocol integration; Geistty owns scrollback buffer |
| capture-pane for search | Alternate screen mode (tmux, vim) has 0 scrollback by design in terminal emulators |
| libxev fork | iOS uses `kevent`, not `kevent64` |
| Custom module.modulemap name | Avoids conflicts with CSSH's module.modulemap |

## Data Flow

### Regular Mode
```
SSH Server → SSHConnection (libssh2) → SSHSession → Ghostty.Surface.writeOutput()
                                                  ↓
                                           Terminal UI (Metal)
                                                  ↓
User Input → Ghostty write callback → SSHSession → SSHConnection.write()
```

### Control Mode (tmux -CC)
```
SSH Server → SSHConnection → SSHSession → TmuxControlClient.parse()
                                                  ↓
                                         Parse %output messages
                                                  ↓
                               Decode octal escapes → Ghostty.Surface.writeOutput()
                                                  ↓
                                           Terminal UI (Metal)
                                                  ↓
User Input → Ghostty write callback → SSHSession → SSHConnection.write()
```

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

Existing categories: `Ghostty`, `Terminal`, `SSHConnection`, `SSHSession`, `SFTP`, `SFTPBrowser`, `SSHKey`, `Credentials`, `Keychain`, `libssh2`

### libssh2 Protocol Tracing

For low-level SSH debugging, enable libssh2's built-in tracing:

```swift
// Before connecting, enable tracing
connection.enableTracing = true
connection.traceCategories = LIBSSH2_TRACE_AUTH | LIBSSH2_TRACE_KEX | LIBSSH2_TRACE_ERROR

// Or enable all categories
connection.traceCategories = ~0

await connection.connect()
```

Trace output goes to os.Logger category `libssh2`. Available categories:
- `LIBSSH2_TRACE_TRANS` (1<<1) - Transport layer (noisy)
- `LIBSSH2_TRACE_KEX` (1<<2) - Key exchange ✅ default
- `LIBSSH2_TRACE_AUTH` (1<<3) - Authentication ✅ default
- `LIBSSH2_TRACE_CONN` (1<<4) - Connection layer (very noisy)
- `LIBSSH2_TRACE_SCP` (1<<5) - SCP operations
- `LIBSSH2_TRACE_SFTP` (1<<6) - SFTP operations ✅ default
- `LIBSSH2_TRACE_ERROR` (1<<7) - Errors ✅ default
- `LIBSSH2_TRACE_PUBLICKEY` (1<<8) - Public key auth ✅ default
- `LIBSSH2_TRACE_SOCKET` (1<<9) - Socket layer (noisy)

**Note:** This requires the debug-enabled libssh2 build from `daiimus/Libssh2Prebuild`.

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

- `Libssh2Prebuild` (daiimus/Libssh2Prebuild)
  - Fork with debug tracing enabled (`--enable-debug`)
  - Enables `libssh2_trace()` API for protocol-level debugging
