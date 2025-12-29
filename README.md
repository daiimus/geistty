# Geistty

> A native iOS/iPadOS SSH terminal powered by [Ghostty](https://github.com/ghostty-org/ghostty)'s terminal engine

<p align="center">
  <img src="https://img.shields.io/badge/iOS-17+-blue.svg" alt="iOS 17+"/>
  <img src="https://img.shields.io/badge/Swift-5.9+-orange.svg" alt="Swift 5.9+"/>
  <img src="https://img.shields.io/badge/Xcode-15+-purple.svg" alt="Xcode 15+"/>
</p>

## Overview

Geistty brings **libghostty**—the core terminal emulation library from [Ghostty](https://github.com/ghostty-org/ghostty)—to iPadOS/iOS as a fully-functional SSH terminal client. The terminal rendering, VT parsing, cursor handling, colors, and scrolling are all powered by Ghostty's real engine, compiled from the original Zig source code.

### Why Ghostty on iOS?

iOS/iPadOS doesn't support local PTY (pseudo-terminal) functionality—apps cannot spawn local shell processes. However, Ghostty's **External termio backend** was designed exactly for this use case: feeding terminal data from an external source (like SSH) into the terminal emulator.

The result is a native iOS app with:
- **Metal GPU-accelerated rendering** - Smooth 120fps terminal display
- **Full terminal emulation** - xterm-256color/truecolor via Ghostty's VT parser
- **Proper Unicode support** - Including wide characters and emoji
- **Selection and clipboard** - Native iOS text selection with Ghostty's selection engine

## Features

### Terminal
- ✅ Full Ghostty terminal rendering (Metal GPU-accelerated)
- ✅ Complete xterm-256color/truecolor support
- ✅ Text selection via long-press + drag
- ✅ Copy/paste with system clipboard integration
- ✅ Scrollback buffer with search (Cmd+F)
- ✅ Mouse tracking for terminal apps (vim, tmux, etc.)
- ✅ Two-finger scroll and trackpad support

### tmux Integration
- ✅ Native tmux Control Mode (-CC) support
- ✅ Multi-pane layouts with real-time sync
- ✅ Per-pane output routing and input
- ✅ Window tabs with switching (Cmd+1-9)
- ✅ Ghostty-style keyboard shortcuts:
  - Split: Cmd+D (right), Cmd+Shift+D (down)
  - Navigate: Cmd+[ / ], Cmd+Option+Arrows
  - Zoom: Cmd+Shift+Enter
  - Equalize: Cmd+Ctrl+=
- ✅ Window rename (Cmd+Shift+R, double-tap, context menu)

### Keyboard
- ✅ Full hardware keyboard support (iPad Magic Keyboard, external keyboards)
- ✅ Arrow keys, function keys (F1-F12), Home/End/PageUp/PageDown
- ✅ Modifier keys (Ctrl+C, Ctrl+D, Ctrl+Z, etc.)
- ✅ On-screen keyboard with accessory bar (Esc, Ctrl toggle, arrows, Tab)
- ✅ Keyboard resize handling with animated terminal resize

### Connections
- ✅ SSH password authentication
- ✅ SSH key authentication (Ed25519, RSA)
- ✅ In-app SSH key generation
- ✅ Saved connection profiles
- ✅ Quick Connect
- ✅ Favorites and recent connections
- ✅ Secure credential storage (iOS Keychain)
- ✅ Auto-reconnect on app resume (credentials stored in memory only)
- ✅ Disconnect detection with overlay and reconnect option (Cmd+R)

### Settings
- ✅ Font size adjustment (Cmd+0/+/-)
- ✅ Theme/color scheme selection (18 bundled themes)
- ✅ Font family selection (Departure Mono, SF Mono, Menlo, Courier)
- ✅ Config file support (ghostty.conf)
- ✅ Auto-hiding chrome (header/toolbar)
- ✅ Haptic feedback toggle

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     SwiftUI App Layer                           │
│  ┌──────────────────┐          ┌─────────────────────────────┐  │
│  │  Connection UI   │          │   TerminalContainerView     │  │
│  │  (profiles,      │          │   (SwiftUI ↔ UIKit bridge)  │  │
│  │   credentials)   │          └───────────┬─────────────────┘  │
│  └────────┬─────────┘                      │                    │
│           │                                ▼                    │
│  ┌──────────────────┐          ┌─────────────────────────────┐  │
│  │   SSHSession     │◄────────►│   Ghostty.SurfaceView       │  │
│  │  (SwiftNIO-SSH)  │  Data    │   (UIView + Metal + Input)  │  │
│  └──────────────────┘  Flow    └─────────────────────────────┘  │
├─────────────────────────────────────────────────────────────────┤
│                    GhosttyKit.xcframework                       │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                    libghostty (Zig)                       │   │
│  │   • VT Parser (escape sequences, xterm emulation)        │   │
│  │   • Metal Renderer (GPU-accelerated text rendering)      │   │
│  │   • Terminal Grid (scrollback, selection, cursor)        │   │
│  │   • External Termio Backend (SSH data pipe)              │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

### Data Flow

1. **SSH → Terminal**: `SSHSession` reads data from remote server → `ghostty_surface_write_output()` feeds it to Ghostty for parsing and rendering
2. **Terminal → SSH**: User types → Ghostty's write callback fires → `SSHSession.write()` sends to server

## Building

### Prerequisites

- macOS with Xcode 15+
- iOS 17+ Simulator or device
- The `GhosttyKit.xcframework` (pre-built from Ghostty's Zig source)

### Build Steps

```bash
# Clone the repository
git clone https://github.com/yourusername/geistty.git
cd geistty

# Open in Xcode
open Geistty/Geistty.xcodeproj

# Build and run on simulator (Cmd+R) or use CLI:
xcodebuild -project Geistty/Geistty.xcodeproj \
  -scheme Geistty \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,name=iPad Pro 13-inch (M5)" \
  build
```

### Building GhosttyKit.xcframework

If you need to rebuild the framework from Ghostty source:

```bash
# Clone Ghostty
git clone https://github.com/ghostty-org/ghostty.git
cd ghostty

# Build xcframework (requires Zig 0.14+)
zig build -Demit-xcframework

# Copy to Geistty project
cp -r macos/GhosttyKit.xcframework ../geistty/Geistty/Frameworks/
```

## Project Structure

```
geistty/
├── README.md
├── Geistty/
│   ├── Geistty.xcodeproj
│   ├── Info.plist
│   ├── Assets.xcassets/
│   ├── Frameworks/
│   │   └── GhosttyKit.xcframework/   # Pre-built Ghostty library
│   ├── Resources/
│   │   └── Fonts/                    # Bundled terminal fonts
│   └── Sources/
│       ├── App/
│       │   ├── GeisttyApp.swift        # @main entry point
│       │   └── ContentView.swift     # Root navigation
│       ├── Auth/
│       │   ├── ConnectionProfile.swift
│       │   ├── CredentialProvider.swift
│       │   ├── KeychainManager.swift
│       │   └── SSHKeyManager.swift
       │   ├── Ghostty/
       │   │   ├── Ghostty.swift         # Swift wrapper for libghostty
       │   ├── FontMapping.swift     # Centralized font name mapping
       │   └── GhosttyTerminalView.swift
       ├── SFTP/
       │   ├── SFTPChannel.swift     # SFTP protocol (for future File Provider)
       │   └── SFTPClient.swift
       ├── SSH/
       │   ├── NIOSSHConnection.swift # SwiftNIO-SSH wrapper
       │   └── SSHSession.swift       # High-level session manager
       ├── Terminal/
       │   ├── TerminalContainerView.swift
       │   └── KeyTableIndicatorView.swift
│       └── UI/
│           ├── ConnectionEditorView.swift
│           ├── ConnectionListView.swift
│           └── SettingsView.swift
```

## Implementation Notes

### Ghostty External Backend

The app uses Ghostty's `GHOSTTY_BACKEND_EXTERNAL` mode, designed for scenarios where terminal I/O comes from an external source rather than a local PTY:

```swift
// Configure surface for external backend
var config = Ghostty.SurfaceConfiguration()
config.backendType = .external

// Feed SSH output to Ghostty for rendering
surfaceView.feedData(sshData)

// Handle user input (sent to SSH)
surfaceView.onWrite = { data in
    sshSession.write(data)
}
```

### iOS-Specific Adaptations

1. **IOSurfaceLayer Sizing**: On iOS, Ghostty adds its Metal layer as a sublayer (vs. replacing the layer on macOS). We manually resize sublayers in `layoutSubviews()`.

2. **UIKeyInput Protocol**: Captures software keyboard input via `insertText(_:)` and `deleteBackward()`, forwarding to `ghostty_surface_text()`.

3. **Hardware Keyboard**: Uses `pressesBegan/pressesEnded` to capture UIKey events and map them to Ghostty keycodes.

4. **addSublayer Workaround**: Ghostty's Zig code calls `objc.sel("addSublayer")` (without colon). We register a runtime method to handle this ObjC convention mismatch.

## Roadmap

### Recently Completed
- ✅ tmux Control Mode with multi-pane layouts
- ✅ Ghostty-style keyboard shortcuts
- ✅ Auto-reconnect on app resume
- ✅ Disconnect detection and reconnect UI
- ✅ Window rename support
- ✅ Search in scrollback (Cmd+F)
- ✅ Theme and font customization

### Planned Features
- [ ] iPadOS Scene integration (each pane as native window)
- [ ] SFTP file browser with Files.app integration
- [ ] iCloud sync for connection profiles
- [ ] Multiple SSH connections in unified tab bar
- [ ] Mosh protocol support
- [ ] Port forwarding
- [ ] Snippet library (saved commands)
- [ ] Split View / Stage Manager optimization

### Known Issues
- Secure Enclave key storage is stubbed but not fully implemented

## Dependencies

| Dependency | License | Purpose |
|------------|---------|--------|
| [Ghostty](https://github.com/ghostty-org/ghostty) | MIT | Terminal emulation engine (Zig) |
| [SwiftNIO-SSH](https://github.com/daiimus/swift-nio-ssh) | Apache 2.0 | Pure Swift SSH (fork with RSA support) |
| [libxev](https://github.com/Cloudef/libxev) | MIT | Event loop for Ghostty (iOS fork) |
| [Departure Mono](https://departuremono.com/) | OFL | Beautiful monospace font |

### Acknowledgments

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) by Miguel de Icaza - Pure Swift terminal emulator, referenced for iOS terminal patterns
- [SwiftTermApp](https://github.com/migueldeicaza/SwiftTermApp) - Sample SSH terminal app, referenced for SSH integration approach
- [SwiftNIO-SSH](https://github.com/apple/swift-nio-ssh) by Apple - Pure Swift SSH implementation (we maintain a [fork with RSA support](https://github.com/daiimus/swift-nio-ssh))

## License

Geistty is a hobby.

Third-party dependencies are used under their respective licenses - see [LICENSES.md](LICENSES.md) for details.

---

*Built with [Ghostty](https://ghostty.org) 👻*
