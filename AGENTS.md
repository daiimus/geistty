# Agent Development Guide for Bodak

A guide for [coding agents](https://agents.md/) working on the Bodak iOS SSH terminal app.

## Project Overview

Bodak is an iOS SSH terminal app built on top of Ghostty's terminal emulator. It uses a custom fork of Ghostty with an External termio backend that enables terminal emulation without a local PTY (which iOS doesn't support).

## Repository Structure

- **Main App**: `Bodak/` - Xcode project and Swift sources
- **Ghostty Fork**: `../ghostty/` - Custom ghostty with iOS support (branch: `ios-external-backend`)
- **libxev Fork**: `../libxev-ios/` - Custom libxev with iOS kqueue support

## Commands

### Building Bodak
```bash
# Build for device
xcodebuild -project Bodak/Bodak.xcodeproj -scheme Bodak -destination "id=DEVICE_ID" -allowProvisioningUpdates

# Build for simulator
xcodebuild -project Bodak/Bodak.xcodeproj -scheme Bodak -destination "platform=iOS Simulator,name=iPhone 15"
```

### Rebuilding GhosttyKit (when Ghostty changes)
```bash
cd ../ghostty
zig build -Demit-xcframework=true -Dxcframework-target=universal

# Copy to Bodak
cp -R macos/GhosttyKit.xcframework ../bodak/Bodak/Frameworks/

# IMPORTANT: Rename module.modulemap to avoid conflicts with CSSH
for dir in ../bodak/Bodak/Frameworks/GhosttyKit.xcframework/*/Headers/; do
    [ -f "${dir}module.modulemap" ] && mv "${dir}module.modulemap" "${dir}GhosttyKit.modulemap"
done
```

## Directory Structure

```
Bodak/
├── Sources/
│   ├── App/              # App entry point, main views
│   ├── Auth/             # SSH authentication, credentials, keychain
│   ├── Ghostty/          # Ghostty integration, terminal surface
│   ├── SFTP/             # SFTP file browser
│   ├── SSH/              # SSH connection management
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
- `Sources/SSH/SSHConnection.swift` - SSH connection using NMSSH
- `Sources/Auth/ConnectionProfile.swift` - Saved connection profiles
- `Sources/UI/SettingsView.swift` - App settings UI

## Ghostty C API Usage

Bodak uses the Ghostty C API for terminal emulation:

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

## Development Notes

1. **No PTY on iOS** - Use External backend, not Exec backend
2. **Metal Renderer** - iOS uses Metal, not OpenGL
3. **CoreText Fonts** - Font discovery via CoreText on iOS
4. **Module Map Naming** - GhosttyKit uses `GhosttyKit.modulemap` to avoid conflicts with CSSH's `module.modulemap`

## Debugging

- Check Ghostty logs for terminal errors
- Use `os_log` for Swift-side logging (category: "Ghostty")
- Metal frame capture in Xcode for rendering issues

## Related Repositories

- `ghostty` (daiimus/ghostty, branch: ios-external-backend)
  - External termio backend for SSH/iOS
  - C API extensions for config loading
  
- `libxev-ios` (daiimus/libxev-ios)
  - iOS kqueue support (uses kevent instead of kevent64)
