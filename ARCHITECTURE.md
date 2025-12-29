# Architecture Deep Dive

## Overview

This document details the technical architecture of the Ghostty iOS SSH Terminal—a working implementation that uses the real Ghostty terminal engine (compiled from Zig) with an SSH backend for iOS.

## System Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        SwiftUI App Layer                            │
│  ┌────────────────┐              ┌────────────────────────────────┐ │
│  │  ContentView   │              │  TerminalContainerView         │ │
│  │  (connection   │──navigate──►│  (UIViewRepresentable)         │ │
│  │   form)        │              │                                │ │
│  └────────────────┘              └───────────────┬────────────────┘ │
│                                                  │                  │
│                                    creates       │                  │
│                                                  ▼                  │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │                    TerminalViewModel                           │ │
│  │  • Manages SSHSession lifecycle                                │ │
│  │  • Holds reference to SurfaceView                              │ │
│  │  • Coordinates data flow                                       │ │
│  └───────────────┬────────────────────────────────┬───────────────┘ │
│                  │                                │                 │
│           owns   │                         owns   │                 │
│                  ▼                                ▼                 │
│  ┌────────────────────────┐      ┌─────────────────────────────────┐│
│  │     SSHSession         │      │   Ghostty.SurfaceView           ││
│  │  ┌──────────────────┐  │      │  ┌───────────────────────────┐  ││
│  │  │ NIOSSHConnection │  │      │  │  UIView + CAMetalLayer    │  ││
│  │  │ (SwiftNIO-SSH)   │  │      │  │  + UIKeyInput             │  ││
│  │  └────────┬─────────┘  │      │  └───────────────────────────┘  ││
│  └───────────┼────────────┘      │              │                  ││
│              │                   │              │                  ││
│              │ async read        │   feedData() │ onWrite callback ││
│              ▼                   │              ▼                  ││
│  ┌───────────────────────────────┴──────────────────────────────┐  ││
│  │                    Data Flow                                  │  ││
│  │   SSH Server ──read──► SSHSession ──feedData──► SurfaceView  │  ││
│  │   SSH Server ◄─write── SSHSession ◄─onWrite─── SurfaceView   │  ││
│  └───────────────────────────────────────────────────────────────┘  ││
│                                  │                                  ││
└──────────────────────────────────┼──────────────────────────────────┘│
                                   │                                   │
                                   ▼                                   │
┌──────────────────────────────────────────────────────────────────────┘
│                    GhosttyKit.xcframework (libghostty)
│  ┌────────────────────────────────────────────────────────────────┐
│  │  ghostty_surface_new()     - Create terminal surface           │
│  │  ghostty_surface_write_output() - Feed data FOR DISPLAY        │
│  │  ghostty_surface_text()    - Send user INPUT to terminal       │
│  │  ghostty_surface_set_size() - Update terminal dimensions       │
│  │  ghostty_surface_free()    - Clean up surface                  │
│  └────────────────────────────────────────────────────────────────┘
│                                   │
│                                   ▼
│  ┌────────────────────────────────────────────────────────────────┐
│  │                    Zig Core Components                         │
│  │  • VT Parser (escape sequences, CSI, OSC, DCS)                │
│  │  • Terminal Grid (cells, scrollback, dirty tracking)          │
│  │  • Metal Renderer (shaders, glyph atlas, GPU drawing)         │
│  │  • External Termio Backend (write callback for SSH)           │
│  └────────────────────────────────────────────────────────────────┘
└───────────────────────────────────────────────────────────────────────
```

## Component Details

### 1. GhosttyKit.xcframework

Pre-built from Ghostty's Zig source code. Contains:

```
GhosttyKit.xcframework/
├── Info.plist
├── ios-arm64/
│   ├── libghostty-fat.a          # ~5MB static library
│   └── Headers/
│       ├── ghostty.h             # Main C API
│       └── ghostty/
│           └── vt.h              # VT parser types
├── ios-arm64-simulator/
│   └── ...
└── macos-arm64_x86_64/
    └── ...
```

**Key Symbols** (verified via `nm`):
```
_ghostty_app_new          # Create app instance
_ghostty_surface_new      # Create terminal surface
_ghostty_surface_write_output  # Feed data to display
_ghostty_surface_text     # Send user input
_ghostty_surface_key      # Send key events
_ghostty_surface_set_size # Resize terminal
```

### 2. Ghostty Swift Wrappers

The Ghostty C API is wrapped in Swift for iOS integration:

- **`Ghostty.swift`** - Main implementation (Config, App, SurfaceView classes)
- **`FontMapping.swift`** - Centralized font name mapping (GUI ↔ CoreText)

See [GHOSTTY_API.md](Geistty/GHOSTTY_API.md) for detailed API coverage.

### 3. Ghostty.swift - Core Implementation

#### Ghostty.Config
```swift
class Config {
    private(set) var config: ghostty_config_t
    
    init?() {
        guard let cfg = ghostty_config_new() else { return nil }
        config = cfg
        ghostty_config_finalize(config)
    }
}
```

#### Ghostty.App
```swift
class App: ObservableObject {
    @Published var readiness: Readiness = .loading
    private(set) var app: ghostty_app_t?
    
    init(config: Config) {
        // Initialize runtime (once)
        ghostty_init()
        
        // Create app with callbacks
        var appConfig = ghostty_app_config_s(...)
        app = ghostty_app_new(&appConfig)
    }
}
```

#### Ghostty.SurfaceView
```swift
class SurfaceView: UIView, ObservableObject, UIKeyInput {
    private(set) var surface: ghostty_surface_t?
    var onWrite: ((Data) -> Void)?  // Called when user types
    
    // UIKeyInput - keyboard handling
    var hasText: Bool { true }
    var canBecomeFirstResponder: Bool { true }
    
    func insertText(_ text: String) {
        // Send to ghostty → triggers write callback → SSH
        ghostty_surface_text(surface, ptr, len)
    }
    
    func deleteBackward() {
        ghostty_surface_text(surface, "\u{7f}", 1)  // DEL
    }
    
    // Feed SSH output to terminal for rendering
    func feedData(_ data: Data) {
        ghostty_surface_write_output(surface, ptr, len)
    }
}
```

#### SurfaceConfiguration (External Backend)
```swift
struct SurfaceConfiguration {
    var backendType: BackendType = .external  // Key for SSH!
    
    func withCValue<T>(view: UIView, writeCallback: ghostty_write_callback_fn?, _ body: (inout ghostty_surface_config_s) -> T) -> T {
        var config = ghostty_surface_config_s()
        config.platform_tag = GHOSTTY_PLATFORM_IOS
        config.backend_tag = GHOSTTY_BACKEND_EXTERNAL  // ← This!
        config.write_callback = writeCallback
        // ...
        return body(&config)
    }
}
```

### 3. SSH Layer (NIOSSHConnection.swift)

The SSH layer uses SwiftNIO-SSH with NIOTransportServices for native Network.framework integration:

```swift
class NIOSSHConnection {
    private let eventLoop: NIOTSEventLoopGroup  // Network.framework-backed
    private var channel: Channel?               // SwiftNIO channel
    private let pathMonitor: NWPathMonitor      // Connection health
    
    func connect(host: String, port: Int, username: String, credential: SSHCredential) async throws {
        // 1. Bootstrap with NIOTransportServices (Network.framework)
        let bootstrap = NIOTSConnectionBootstrap(group: eventLoop)
            .connectTimeout(.seconds(30))
            .channelInitializer { channel in
                // Add SSH handlers
                channel.pipeline.addHandlers([...])
            }
        
        // 2. Connect and authenticate
        self.channel = try await bootstrap.connect(host: host, port: port).get()
        
        // 3. Open shell channel
        // SwiftNIO-SSH handles protocol negotiation
    }
    
    func write(_ data: Data) async throws {
        try await channel?.writeAndFlush(data)
    }
}
```

**Key Benefits of SwiftNIO-SSH:**
- Pure Swift with native async/await
- Network.framework integration for iOS power management
- NWPathMonitor for connection health
- No C memory management

### 4. Data Flow Integration

#### SSH Output → Terminal Display
```swift
// In TerminalContainerView
func sshSession(_ session: SSHSession, didReceiveData data: Data) {
    // Feed SSH output to Ghostty for rendering
    surfaceView?.feedData(data)
}
```

#### User Input → SSH
```swift
// In Ghostty.SurfaceView (via write callback)
private static let externalWriteCallback: ghostty_write_callback_fn = { surface, data, len in
    let surfaceView = Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    let swiftData = Data(bytes: data, count: Int(len))
    surfaceView.onWrite?(swiftData)  // → SSHSession.send()
}

// Connected in TerminalContainerView
surfaceView.onWrite = { [weak self] data in
    self?.sshSession?.send(data)
}
```

## iOS-Specific Implementation Details

### 1. IOSurfaceLayer Sizing

**Problem**: On iOS, Ghostty adds an `IOSurfaceLayer` as a sublayer (vs. replacing the layer on macOS). The sublayer starts with zero frame.

**Solution**: Manually resize in `sizeDidChange()`:
```swift
func sizeDidChange(_ size: CGSize) {
    ghostty_surface_set_size(surface, scaledWidth, scaledHeight)
    
    // Resize sublayers to match view bounds
    for sublayer in layer.sublayers ?? [] {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sublayer.frame = bounds
        sublayer.contentsScale = contentScaleFactor
        CATransaction.commit()
    }
}
```

### 2. addSublayer Selector Mismatch

**Problem**: Ghostty's Zig code calls `objc.sel("addSublayer")` without the ObjC colon convention for methods with arguments.

**Solution**: Register runtime method:
```swift
static func registerGhosttyMethods() {
    let selector = sel_registerName("addSublayer")  // No colon!
    let imp: @convention(c) (AnyObject, Selector, AnyObject) -> Void = { self_, sel_, sublayer in
        if let view = self_ as? UIView, let layer = sublayer as? CALayer {
            view.layer.addSublayer(layer)
        }
    }
    class_addMethod(SurfaceView.self, selector, unsafeBitCast(imp, to: IMP.self), "v@:@")
}
```

### 3. Keyboard Input via UIKeyInput

```swift
extension SurfaceView: UIKeyInput {
    var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    
    func insertText(_ text: String) {
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
        }
    }
    
    func deleteBackward() {
        ghostty_surface_text(surface, "\u{7f}", 1)
    }
}
```

### 4. Surface Lifecycle Management

**Problem**: Crashes on reconnect due to improper surface cleanup.

**Solution**: Explicit `close()` method:
```swift
func close() {
    guard let surface = surface else { return }
    onWrite = nil  // Prevent callbacks during free
    ghostty_surface_free(surface)
    self.surface = nil
}

deinit {
    close()
}
```

## What Ghostty Provides

The `libghostty-fat.a` static library (~5MB) contains:

| Component | Description |
|-----------|-------------|
| **VT Parser** | Full xterm/VT100 terminal emulation |
| **Terminal Grid** | Cell storage, scrollback buffer, dirty tracking |
| **Metal Renderer** | GPU-accelerated text rendering with shaders |
| **Font System** | Glyph atlas, font shaping, fallback fonts |
| **Color System** | 256-color and truecolor support |
| **Selection** | Text selection and clipboard integration |
| **Cursor** | Cursor rendering and blinking |

## What We Implement in Swift

| Component | Description |
|-----------|-------------|
| **SSH Transport** | SwiftNIO-SSH for network I/O |
| **UIKeyInput** | iOS keyboard event handling |
| **Layer Sizing** | IOSurfaceLayer frame management |
| **Lifecycle** | Surface create/close management |
| **SwiftUI Bridge** | UIViewRepresentable wrapper |
        ("←", [0x1b, 0x5b, 0x44]),
        ("→", [0x1b, 0x5b, 0x43]),
    ]
}
```

## Data Flow

```
┌─────────────┐    SSH Read    ┌─────────────┐    Terminal     ┌─────────────┐
│   Remote    │───────────────►│    SSH      │────Emulation───►│  libghostty │
│   Server    │                │   Channel   │                 │   Surface   │
└─────────────┘                └─────────────┘                 └──────┬──────┘
      ▲                                                               │
      │                                                               │
      │    SSH Write                              Metal Render        │
      │                                                               ▼
┌─────┴─────────────────────────────────────────────────────────────────────┐
│                              User Input                                    │
│                   (keyboard, touch, trackpad, mouse)                       │
└───────────────────────────────────────────────────────────────────────────┘
```

## Threading Model

- **Main Thread**: UI updates, Metal rendering
- **NIO Event Loop**: SwiftNIO-SSH operations (via `NIOTSEventLoopGroup`)
- **Background**: Network I/O via `NWConnection` (Network.framework)

SwiftNIO handles thread safety internally via event loops.

## Memory Management

- `ghostty_surface_t` - Created/freed from Swift, ref counted
- `Channel` - SwiftNIO channel, managed by event loop lifecycle
- `NIOSSHConnection` - Swift class, ARC-managed

## Platform Considerations

### iOS-Specific
- No background PTY execution
- Must handle app suspension gracefully
- Mosh-style reconnection for reliability
- Secure Enclave for hardware-backed keys

### iPadOS-Specific  
- Stage Manager / windowing support
- External display support
- Trackpad/mouse cursor support
- Split View multitasking

## Configuration

Terminal emulation settings:

```swift
struct TerminalConfig {
    var terminalType = "xterm-256color"
    var scrollbackLines = 10000
    var cursorStyle: CursorStyle = .block
    var cursorBlink = true
    var fontFamily = "JetBrainsMono Nerd Font"
    var fontSize: CGFloat = 14
    var theme: ThemeColor = .default
}
```

## Error Handling

Key error scenarios:

1. **Connection Failed** - Network unreachable, timeout
2. **Authentication Failed** - Wrong credentials, key rejected
3. **Channel Error** - PTY request denied, EOF
4. **Terminal Error** - Invalid escape sequences (logged, not fatal)

## Security

- TLS not used (SSH provides encryption)
- Host key verification via known_hosts
- Key material never leaves Secure Enclave (when using hardware keys)
- Passwords encrypted in Keychain
- Reconnect credentials stored in memory only (cleared on explicit disconnect)

## Auto-Reconnect System

When iOS suspends and resumes the app, SSH connections may be dropped. The system handles this transparently:

```
┌─────────────────┐
│  App Becomes    │
│    Active       │
└────────┬────────┘
         │
         ▼
┌─────────────────┐    alive     ┌─────────────────┐
│  Check if       │─────────────►│  Resume Paused  │
│  Connection     │              │  Panes (tmux)   │
│  Alive?         │              └─────────────────┘
└────────┬────────┘
         │ dead
         ▼
┌─────────────────┐    no        ┌─────────────────┐
│  Have Stored    │─────────────►│  Notify User    │
│  Credentials?   │              │  (Disconnected) │
└────────┬────────┘              └─────────────────┘
         │ yes
         ▼
┌─────────────────┐              ┌─────────────────┐
│  Reconnect      │──success────►│  Re-attach to   │
│  (up to 3x)     │              │  tmux Session   │
└────────┬────────┘              └─────────────────┘
         │ fail
         ▼
┌─────────────────┐
│  Show Error     │
│  (Can Retry)    │
└─────────────────┘
```

**Key Properties in SSHSession:**
- `storedPassword` / `storedProfile` / `storedCredential` - Credentials for reconnect
- `isReconnecting` - Prevents concurrent reconnect attempts
- `reconnectAttempts` / `maxReconnectAttempts` - Retry control (default: 3 attempts)

**Behavior:**
- Credentials stored in memory on successful connect
- Cleared on explicit disconnect (Cmd+W) to prevent unwanted reconnect
- Auto-reconnect uses 2-second delay between attempts
- Re-attaches to existing tmux session via `tmux -CC new-session -A -s <name>`

