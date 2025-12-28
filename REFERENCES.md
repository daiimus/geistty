# References & Resources

## Source Repositories

### Primary Projects

| Project | URL | Purpose |
|---------|-----|---------|
| **Ghostty** | https://github.com/ghostty-org/ghostty | Source for libghostty terminal emulation library |
| **SwiftTerm** | https://github.com/migueldeicaza/SwiftTerm | Reference Swift terminal emulator |
| **SwiftTermApp** | https://github.com/migueldeicaza/SwiftTermApp | Complete iOS SSH client (blueprint for our SSH layer) |

### Supporting Projects

| Project | URL | Purpose |
|---------|-----|---------|
| **Nerd Fonts** | https://github.com/ryanoasis/nerd-fonts | Patched fonts with icons |
| **SwiftNIO-SSH** | https://github.com/apple/swift-nio-ssh | Pure Swift SSH implementation |
| **SwiftNIO-SSH (fork)** | https://github.com/daiimus/swift-nio-ssh | Fork with RSA key support |
| **libxev** | https://github.com/Cloudef/libxev | Event loop (iOS fork required) |

> **Note:** libssh2 was replaced with SwiftNIO-SSH in Dec 2024 for pure Swift async/await support.

---

## Documentation

### Ghostty

- **Main Site**: https://ghostty.org/ (if available)
- **GitHub Wiki**: https://github.com/ghostty-org/ghostty/wiki
- **C API Header**: `include/ghostty.h` in repo

### SSH

- **SwiftNIO-SSH**: https://github.com/apple/swift-nio-ssh
- **RFC 4253 (SSH Transport)**: https://datatracker.ietf.org/doc/html/rfc4253
- **RFC 4254 (SSH Connection)**: https://datatracker.ietf.org/doc/html/rfc4254

### Terminal Emulation

- **XTerm Control Sequences**: https://invisible-island.net/xterm/ctlseqs/ctlseqs.html
- **ECMA-48 (ANSI Standard)**: https://www.ecma-international.org/publications-and-standards/standards/ecma-48/
- **VT100 User Guide**: https://vt100.net/docs/vt100-ug/

### iOS Development

- **UIKit**: https://developer.apple.com/documentation/uikit
- **SwiftUI**: https://developer.apple.com/documentation/swiftui
- **Metal**: https://developer.apple.com/documentation/metal
- **Network Framework**: https://developer.apple.com/documentation/network
- **Security (Keychain/SecureEnclave)**: https://developer.apple.com/documentation/security

---

## Key Files in Reference Repos

### Ghostty

```
ghostty-org/ghostty/
├── include/ghostty.h                    # C API - READ THIS FIRST
├── src/
│   ├── apprt/embedded.zig               # Embedded app runtime
│   ├── termio/Termio.zig                # Terminal I/O abstraction
│   └── pty.zig                          # PTY (NullPty for iOS)
└── macos/Sources/
    ├── Ghostty/
    │   └── SurfaceView_UIKit.swift      # UIKit surface view
    └── App/iOS/
        └── iOSApp.swift                 # iOS app entry
```

### SwiftTermApp

```
migueldeicaza/SwiftTermApp/
├── SwiftTermApp/
│   ├── Ssh/
│   │   ├── Session.swift                # Main SSH session
│   │   ├── SessionActor.swift           # Thread-safe libssh2 wrapper
│   │   ├── Channel.swift                # SSH channel
│   │   ├── Errors.swift                 # Error handling
│   │   └── LibsshKnownHost.swift        # Known hosts verification
│   ├── Terminal/
│   │   ├── SshTerminalView.swift        # SSH + Terminal integration
│   │   └── AppTerminalView.swift        # Base terminal view
│   ├── Keys/
│   │   └── SshUtil.swift                # Key handling utilities
│   └── Settings/
│       └── SettingsView.swift           # Font/theme settings
└── LICENSE                              # MIT
```

### SwiftTerm

```
migueldeicaza/SwiftTerm/
├── Sources/SwiftTerm/
│   ├── Terminal.swift                   # Core emulator
│   ├── iOS/
│   │   ├── iOSTerminalView.swift        # UIKit view
│   │   └── iOSAccessoryView.swift       # Keyboard accessory
│   └── Mac/
│       └── MacTerminalView.swift        # AppKit view
└── TerminalApp/iOSTerminal/
    └── UIKitSshTerminalView.swift       # SSH example!
```

---

## Fonts

### Downloads

| Font | Download |
|------|----------|
| JetBrains Mono | https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.tar.xz |
| Fira Code | https://github.com/ryanoasis/nerd-fonts/releases/latest/download/FiraCode.tar.xz |
| Hack | https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Hack.tar.xz |
| Source Code Pro | https://github.com/ryanoasis/nerd-fonts/releases/latest/download/SourceCodePro.tar.xz |
| All Fonts | https://www.nerdfonts.com/font-downloads |

### Resources

- **Nerd Fonts Cheat Sheet**: https://www.nerdfonts.com/cheat-sheet
- **Font Patcher**: https://github.com/ryanoasis/nerd-fonts#font-patcher
- **Powerline Symbols**: https://github.com/ryanoasis/powerline-extra-symbols

---

## iOS SSH Apps (Competition/Inspiration)

| App | Developer | Notes |
|-----|-----------|-------|
| **La Terminal** | Miguel de Icaza | SwiftTermApp is open core |
| **Secure ShellFish** | Panic | Uses SwiftTerm |
| **Termius** | Termius Corp | Feature-rich, commercial |
| **Prompt 3** | Panic | macOS/iOS, Mosh support |
| **Blink Shell** | Blink Shell | Mosh, open source |
| **SSH Files** | Panic | SFTP focus |

---

## Build Tools

### Required

- **Xcode 15+**: https://developer.apple.com/xcode/
- **Zig**: https://ziglang.org/download/ (for building libghostty)
- **Homebrew**: https://brew.sh/ (for dependencies)

### Optional

- **SwiftLint**: https://github.com/realm/SwiftLint
- **SwiftFormat**: https://github.com/nicklockwood/SwiftFormat

---

## Community

### Discord/Forums

- **Ghostty Discord**: (check repo for invite)
- **SwiftTerm GitHub Discussions**: https://github.com/migueldeicaza/SwiftTerm/discussions
- **r/iOSProgramming**: https://reddit.com/r/iOSProgramming

### People to Follow

| Name | Role | Links |
|------|------|-------|
| Mitchell Hashimoto | Ghostty creator | [@mitchellh](https://twitter.com/mitchellh) |
| Miguel de Icaza | SwiftTerm/La Terminal | [@migueldeicaza](https://twitter.com/migueldeicaza) |

---

## Quick Commands

### Clone Repositories

```bash
# Create workspace
mkdir -p ~/Projects/Repositories
cd ~/Projects/Repositories

# Clone Ghostty (large repo - use shallow clone)
git clone --depth 1 https://github.com/ghostty-org/ghostty.git

# Clone SwiftTermApp (reference)
git clone https://github.com/migueldeicaza/SwiftTermApp.git

# Clone SwiftTerm (reference)
git clone https://github.com/migueldeicaza/SwiftTerm.git
```

### Install Fonts (macOS)

```bash
# Via Homebrew
brew tap homebrew/cask-fonts
brew install font-jetbrains-mono-nerd-font
brew install font-fira-code-nerd-font
brew install font-hack-nerd-font
```

### Install Xcode CLI Tools

```bash
xcode-select --install
```

---

## License Information

| Project | License | Commercial Use |
|---------|---------|----------------|
| Ghostty (libghostty) | MIT | ✅ Yes |
| SwiftTerm | MIT | ✅ Yes |
| SwiftTermApp | MIT | ✅ Yes |
| SwiftNIO-SSH | Apache 2.0 | ✅ Yes |
| Nerd Fonts | Various (mostly OFL) | ✅ Yes (with attribution) |

All dependencies are compatible with commercial use, requiring only attribution.
