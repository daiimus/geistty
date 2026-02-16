# Geistty

> A native iOS/iPadOS SSH terminal powered by [Ghostty](https://ghostty.org)'s terminal engine

<p align="center">
  <img src="https://img.shields.io/badge/v0.1--stable-February_2026-green.svg" alt="v0.1-stable"/>
  <img src="https://img.shields.io/badge/iOS-17+-blue.svg" alt="iOS 17+"/>
  <img src="https://img.shields.io/badge/Swift-5.9+-orange.svg" alt="Swift 5.9+"/>
  <img src="https://img.shields.io/badge/Zig-0.14+-yellow.svg" alt="Zig 0.14+"/>
</p>

## What is this?

iOS can't spawn local shells -- no `fork`, no `exec`, no PTY. Geistty works around this by using Ghostty's **External termio backend**, which accepts terminal data from an external source (SSH) instead of a local process. The result: real Ghostty terminal emulation -- Metal GPU rendering, full VT parsing, proper Unicode -- running on iPad and iPhone, connected over SSH.

tmux control mode (`tmux -CC`) is handled natively by Ghostty's Zig code. Multi-pane layouts, session persistence across app suspensions, and transparent reconnection all work.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the deep dive on how everything fits together.

## Current State

**Tag: `v0.1-stable`** -- deployed and confirmed working on iPad Pro (Icarus).

Everything below is implemented and functional:

### Terminal
- Full Ghostty terminal rendering (Metal GPU-accelerated, 120fps)
- Complete xterm-256color/truecolor support
- Text selection via long-press + drag
- Copy/paste with system clipboard
- Scrollback buffer with search (Cmd+F)
- Mouse tracking for terminal apps (vim, htop, etc.)
- Two-finger scroll and trackpad support

### tmux Integration
- Native tmux Control Mode (`tmux -CC`) via Ghostty's viewer.zig
- Multi-pane layouts with per-pane output routing
- Multi-window support with window tab bar
- Per-window focused pane tracking via C API
- Window tabs with switching (Cmd+1-9)
- Ghostty-style keyboard shortcuts:
  - Split: Cmd+D (right), Cmd+Shift+D (down)
  - Navigate: Cmd+[ / ], Cmd+Option+Arrows
  - Zoom: Cmd+Shift+Enter
  - Equalize: Cmd+Ctrl+=
- Window rename (Cmd+Shift+R, double-tap, context menu)
- Session persistence across app suspensions
- Touch-optimized divider dragging (30pt hit areas), double-tap zoom

### Keyboard
- Full hardware keyboard support (Magic Keyboard, external keyboards)
- Arrow keys, function keys (F1-F12), Home/End/PageUp/PageDown
- Modifier keys (Ctrl+C, Ctrl+D, Ctrl+Z, etc.)
- On-screen keyboard with accessory bar (Esc, Ctrl toggle, arrows, Tab)
- Keyboard resize with animated terminal reflow

### Connections
- SSH password and key authentication (Ed25519, RSA)
- In-app SSH key generation
- Saved connection profiles with favorites
- Quick Connect
- Secure credential storage (iOS Keychain)
- Auto-reconnect on app resume (up to 3 retries, 2s delay)
- Disconnect detection with reconnect overlay (Cmd+R)

### Settings
- Font size adjustment (Cmd+0/+/-)
- Theme selection (18 bundled themes)
- Font family (Departure Mono, JetBrains Mono, Fira Code, Hack, Source Code Pro, IBM Plex Mono, Inconsolata, Menlo, Courier New)
- Config file (`ghostty.conf`) is source of truth
- Auto-hiding chrome (header/toolbar)
- Haptic feedback toggle

## Architecture

```
SwiftUI (navigation, connection profiles, settings)
    |
UIKit Bridge (SurfaceView: Metal rendering + keyboard input)
    |
State & Transport (SSHSession, TerminalViewModel, TmuxSessionManager)
    |
GhosttyKit (Zig: VT parser, terminal grid, Metal renderer, External backend, tmux viewer)
    |
SwiftNIO-SSH (Network.framework transport)
    |
SSH Server (tmux -CC control mode)
```

Data flow is simple:
1. **Output**: SSH bytes -> `ghostty_surface_write_output()` -> VT parse -> Metal render
2. **Input**: Keyboard -> `ghostty_surface_key()` -> `queueWrite()` -> write callback -> SSH send
3. **tmux**: Same paths, but Ghostty's viewer.zig intercepts -- wraps input in `send-keys -H`, parses `%output` for display

Full architecture documentation with Mermaid diagrams: **[ARCHITECTURE.md](ARCHITECTURE.md)**

## Repositories

| Repo | Branch | Purpose |
|------|--------|---------|
| [daiimus/geistty](https://github.com/daiimus/geistty) | `main` | iOS app (Swift, SwiftUI, UIKit) |
| [daiimus/ghostty](https://github.com/daiimus/ghostty) | `ios-external-backend` | Ghostty fork (External backend, tmux viewer, iOS C API) |
| [daiimus/swift-nio-ssh](https://github.com/daiimus/swift-nio-ssh) | `add-rsa-support` | SwiftNIO-SSH fork (RSA key support) |

## Building

### Prerequisites

- macOS with Xcode 15+
- Zig 0.14+ (for building GhosttyKit)
- iOS 17+ device or simulator
- SSH key for git operations (via ssh-agent or similar)

### Build GhosttyKit from Ghostty fork

```bash
cd path/to/ghostty
zig build -Demit-xcframework=true -Dxcframework-target=universal

# Copy framework to Geistty
rm -rf path/to/geistty/Geistty/Frameworks/GhosttyKit.xcframework
cp -R macos/GhosttyKit.xcframework path/to/geistty/Geistty/Frameworks/

# Rename module maps to avoid conflicts with CSSH
for dir in path/to/geistty/Geistty/Frameworks/GhosttyKit.xcframework/*/Headers/; do
    [ -f "${dir}module.modulemap" ] && mv "${dir}module.modulemap" "${dir}GhosttyKit.modulemap"
done
```

### Build and deploy to device

```bash
cd path/to/geistty/Geistty

# CI build + tests (simulator, no signing)
./ci.sh all

# Build for device
xcodebuild -project Geistty.xcodeproj -scheme Geistty \
  -destination "platform=iOS,name=YourDevice" \
  -allowProvisioningUpdates build

# Install
xcrun devicectl device install app --device <device-uuid> path/to/Geistty.app

# Launch with console logging
xcrun devicectl device process launch --device <device-uuid> \
  --terminate-existing --console com.geistty.app
```

### Run tests

```bash
# Swift tests (550 tests)
cd path/to/geistty/Geistty && ./ci.sh test

# Zig tests (External backend + tmux viewer)
cd path/to/ghostty && zig build test
cd path/to/ghostty && zig build test -Dtest-filter="tmux"
```

## Project Structure

```
geistty/
├── ARCHITECTURE.md          # Deep architecture docs
├── AGENTS.md                # Agent development guide
├── Geistty/
│   ├── Geistty.xcodeproj
│   ├── Frameworks/
│   │   └── GhosttyKit.xcframework/
│   ├── Resources/
│   │   └── Fonts/           # 7 bundled font families
│   └── Sources/
│       ├── App/             # GeisttyApp, ContentView
│       ├── Auth/            # ConnectionProfile, Keychain, SSH keys
│       ├── Ghostty/         # C API bridge, SurfaceView, config, search, tmux protocol
│       ├── SSH/             # NIOSSHConnection, SSHSession, TmuxSessionManager
│       ├── Terminal/        # TerminalContainerView, VC extensions, multi-pane views, themes
│       └── UI/              # Connection list, editor, settings
├── GeisttyTests/            # 550 unit tests (20 files + 2 mocks)
└── GeisttyUITests/          # 4 UI test files + 2 config files
```

## Dependencies

| Dependency | License | Purpose |
|------------|---------|---------|
| [Ghostty](https://github.com/ghostty-org/ghostty) | MIT | Terminal emulation engine (Zig, our fork) |
| [SwiftNIO-SSH](https://github.com/daiimus/swift-nio-ssh) | Apache 2.0 | SSH transport (our fork with RSA support) |
| [libxev](https://github.com/mitchellh/libxev) | MIT | Event loop (used by Ghostty internally) |
| [Departure Mono](https://departuremono.com/) | OFL | Default terminal font |

## Acknowledgments

- [Ghostty](https://ghostty.org) by Mitchell Hashimoto -- the terminal engine that makes this possible
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) by Miguel de Icaza -- referenced for iOS terminal patterns
- [SwiftNIO-SSH](https://github.com/apple/swift-nio-ssh) by Apple -- the SSH foundation we forked

## License

Geistty is a hobby.

Third-party dependencies are used under their respective licenses -- see [LICENSES.md](LICENSES.md).
