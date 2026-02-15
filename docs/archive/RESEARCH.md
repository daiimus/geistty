# Research Findings

> **📚 HISTORICAL DOCUMENT (Early 2024)**
> 
> This document captures initial research conducted when starting the project. 
> The findings informed design decisions but many implementation details have evolved.
> Kept for reference and future research.

This document captures research conducted on reference implementations and relevant technologies.

## Table of Contents

1. [Ghostty iOS Analysis](#ghostty-ios-analysis)
2. [SwiftTerm Analysis](#swiftterm-analysis)
3. [SwiftTermApp Analysis](#swifttermapp-analysis)
4. [SSH Libraries Comparison](#ssh-libraries-comparison)
5. [Key Insights](#key-insights)

---

## Ghostty iOS Analysis

### Repository: [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty)

### iOS Code Status

Ghostty contains **scaffolding** for iOS support, but it is NOT a shipping app. The iOS code exists primarily to support xcframework builds.

### Key Files Found

#### `macos/Sources/Ghostty/SurfaceView_UIKit.swift` (~120 lines)
- UIView subclass wrapping a `ghostty_surface_t`
- Sets up Metal layer for rendering
- Handles `layoutSubviews` and size changes
- Very minimal—mostly a container for the Metal surface

#### `macos/Sources/App/iOS/iOSApp.swift`
- SwiftUI `@main` App entry point
- ContentView just shows "Hello, world!"
- Pure scaffolding, no functional terminal

#### `src/pty.zig` - NullPty
```zig
pub const NullPty = struct {
    pub fn read(_: *NullPty, _: []u8) !usize { return 0; }
    pub fn write(_: *NullPty, _: []const u8) !usize { return 0; }
};
```
The iOS PTY implementation does nothing—this is where SSH integration would plug in.

#### `src/apprt/embedded.zig`
- Platform union includes iOS
- Defines `Surface` struct with iOS-specific code paths
- Uses `GHOSTTY_PLATFORM_IOS` preprocessor flag

#### `include/ghostty.h`
- Complete C API for embedding libghostty
- Key functions:
  - `ghostty_surface_new()` / `ghostty_surface_free()`
  - `ghostty_surface_key()` for keyboard input
  - `ghostty_surface_mouse()` for pointer events
  - Various configuration options

### xcframework Build

The build system produces an xcframework with:
- macOS (arm64)
- iOS (arm64)
- iOS Simulator (arm64, x86_64)

This is the artifact we'll use.

---

## SwiftTerm Analysis

### Repository: [migueldeicaza/SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)

### Overview

SwiftTerm is a **pure Swift** terminal emulator used in production apps:
- **Secure Shellfish** (Panic)
- **La Terminal** (Miguel de Icaza)
- **CodeEdit**

### Architecture

```
SwiftTerm/
├── Sources/SwiftTerm/
│   ├── Terminal.swift          # Core terminal state machine
│   ├── Buffer.swift            # Screen buffer
│   ├── Parser.swift            # ANSI/VT escape sequence parser
│   ├── iOS/
│   │   ├── iOSTerminalView.swift    # UIKit view
│   │   └── iOSAccessoryView.swift   # Keyboard accessory bar
│   └── Mac/
│       └── MacTerminalView.swift    # AppKit view
└── TerminalApp/                # Sample iOS app
    └── iOSTerminal/
        └── UIKitSshTerminalView.swift  # SSH integration example!
```

### Key Pattern: TerminalViewDelegate

SwiftTerm uses a delegate pattern for I/O abstraction:

```swift
public protocol TerminalViewDelegate: AnyObject {
    /// Called when the terminal has data to send to the backend
    func send(source: TerminalView, data: ArraySlice<UInt8>)
    
    /// Terminal size changed
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int)
    
    /// Terminal title changed  
    func setTerminalTitle(source: TerminalView, title: String)
    
    /// Bell received
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?)
}
```

This is how you connect any backend (local PTY, SSH, etc.) to the terminal.

### iOS Platform Support

- Minimum: `.iOS(.v13)`
- Also supports visionOS
- Uses CoreText for text rendering
- Supports input methods for international keyboards
- Built-in `TerminalAccessory` for special keys (Esc, Ctrl, Tab, arrows, F-keys)

### SSH Sample Code

The `UIKitSshTerminalView.swift` shows SSH integration using **SwiftSH**:

```swift
// Simplified from sample code
class UIKitSshTerminalView: TerminalView, TerminalViewDelegate {
    var shell: SSHShell?
    
    func connect() {
        let session = SSHSession(host: "192.168.86.28", port: 22)
        session.authenticate(.byPassword(username: "miguel", password: "..."))
        
        shell = session.shell
        shell?.withCallback { [weak self] data, error in
            // Data from SSH → Terminal
            self?.feed(byteArray: data)
        }
        .connect()
        .open()
    }
    
    // TerminalViewDelegate: Terminal → SSH
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        shell?.write(Data(data))
    }
}
```

---

## SwiftTermApp Analysis

### Repository: [migueldeicaza/SwiftTermApp](https://github.com/migueldeicaza/SwiftTermApp)

### Overview

SwiftTermApp is a **complete iOS SSH client** and the open-source core of "La Terminal" (App Store). MIT licensed.

### Key Features

- Full SSH client with connection management
- Secure Enclave key storage (hardware-backed keys!)
- Multiple authentication methods
- SFTP support
- tmux integration
- Metal shader backgrounds (animated!)
- Theme support (colors)
- Font selection

### SSH Implementation (libssh2 direct)

SwiftTermApp wraps libssh2 directly (no SwiftSH dependency for production):

#### SessionActor (Swift Actor pattern)
```swift
actor SessionActor {
    var sessionHandle: OpaquePointer  // LIBSSH2_SESSION*
    
    // All libssh2 calls go through this for thread safety
    func callSsh<T>(_ block: @escaping () -> T) async -> T {
        // Handles EAGAIN retry loop
        while true {
            let result = block()
            if result != LIBSSH2_ERROR_EAGAIN {
                return result
            }
            // Yield and retry
        }
    }
}
```

#### Authentication Methods

1. **Password**:
   ```swift
   libssh2_userauth_password_ex(sessionHandle, username, ..., password, ...)
   ```

2. **Public Key from Memory**:
   ```swift
   libssh2_userauth_publickey_frommemory(sessionHandle, username, ..., 
       pubPtr, strlen(pubPtr), privPtr, strlen(privPtr), passPhrase)
   ```

3. **Keyboard Interactive**:
   ```swift
   libssh2_userauth_keyboard_interactive_ex(sessionHandle, username, ...) {
       // Callback for challenge-response
   }
   ```

4. **Secure Enclave Callback**:
   Uses `libssh2_userauth_publickey()` with a signing callback that calls into iOS Secure Enclave.

#### Network Layer

Uses Apple's `Network.framework` (`NWConnection`) instead of raw sockets:

```swift
class SocketSession: Session {
    var connection: NWConnection
    
    init(host: Host, delegate: SessionDelegate) {
        connection = NWConnection(
            host: NWEndpoint.Host(host.hostname), 
            port: NWEndpoint.Port(integerLiteral: UInt16(host.port)), 
            using: .tcp
        )
        // Setup send/recv callbacks for libssh2
    }
}
```

### Terminal Integration

#### SshTerminalView
```swift
public class SshTerminalView: AppTerminalView, TerminalViewDelegate, SessionDelegate {
    var session: SocketSession?
    var sessionChannel: Channel?
    
    // Login flow
    func loggedIn(session: Session) async {
        await setupTerminalChannel(session: session)
    }
    
    func setupTerminalChannel(session: Session) async {
        // Open channel
        channel = await session.openChannel()
        
        // Request PTY
        await channel.requestPseudoTerminal(
            name: "xterm-256color",
            cols: terminal.cols,
            rows: terminal.rows
        )
        
        // Start shell
        await channel.exec(command: nil)  // nil = default shell
    }
}
```

### Fonts

SwiftTermApp includes:

```swift
var fontNames: [String] = [
    "Courier", 
    "Courier New", 
    "Menlo", 
    "SF Mono",              // System monospace
    "SourceCodePro-Medium"  // Bundled
]
```

And bundles **Source Code Pro** with SIL Open Font License.

### Themes

Uses iTerm2 color scheme format (XRDB):
- Adventure Time
- Dark (builtin)
- Django
- Light (builtin)
- Material
- Ocean
- Pro (default)
- Solarized Dark
- Solarized Light
- Tango Dark
- Tango Light

---

## SSH Libraries Comparison

| Library | Language | License | Notes |
|---------|----------|---------|-------|
| **libssh2** | C | BSD | Mature, production-proven, used by curl. SwiftTermApp's choice. |
| SwiftSH | Swift | MIT | Wrapper around libssh2, convenient API |
| SwiftNIO SSH | Swift | Apache 2.0 | Pure Swift, modern async/await, Apple-backed |
| NMSSH | Obj-C | MIT | libssh2 wrapper, CocoaPods friendly |

### Recommendation: **libssh2 (direct)**

Reasons:
1. SwiftTermApp proves it works well on iOS
2. Full control over authentication flows
3. Secure Enclave integration requires callback-level access
4. Production-tested in La Terminal

---

## Key Insights

### 1. The NullPty Problem is Solvable
Ghostty's iOS code doesn't work because `NullPty` does nothing. But the architecture supports plugging in a different backend. We have two options:
- **Swift-side bridge**: Feed data to libghostty from Swift after SSH read
- **Custom Zig backend**: Create `SshTermio` in Zig that accepts callbacks

### 2. SwiftTermApp is the Blueprint
The complete SSH implementation in SwiftTermApp can be largely reused. Key pieces:
- `SessionActor` pattern for thread-safe libssh2
- `Channel` abstraction for PTY
- Authentication flow with Secure Enclave support
- `NWConnection`-based networking

### 3. Font Strategy
Two approaches:
- Bundle **Nerd Fonts** variants (JetBrainsMono, FiraCode, etc.)
- Use system fonts (SF Mono, Menlo) with fallback

Nerd Fonts give us Powerline symbols and dev icons out of the box.

### 4. Metal Rendering is Key
libghostty uses Metal for GPU-accelerated rendering. This should give us:
- Smooth scrolling
- Ligature support
- High refresh rate on ProMotion displays
- Low power consumption

### 5. Secure Enclave is Differentiating
SwiftTermApp's Secure Enclave integration means private keys:
- Are generated on-device in hardware
- Never exist in extractable form
- Can't be stolen even if device is compromised

This is a significant security feature we should preserve.

### 6. iOS Platform Considerations

| Consideration | Solution |
|--------------|----------|
| No background processes | SSH connections suspend; consider Mosh for reliability |
| Split View / Stage Manager | SwiftUI adaptive layouts |
| Hardware keyboards | Full key event handling with modifiers |
| Trackpad/mouse | UIKit pointer interaction APIs |
| External displays | UIScene / UIWindowScene |
