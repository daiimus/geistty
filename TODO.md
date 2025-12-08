# Development Roadmap

## Overview

This document tracks the development progress for the Ghostty iOS SSH Terminal project.

---

## ✅ Phase 0: Environment Setup — COMPLETE

- [x] Install Xcode 15+
- [x] Install Homebrew
- [x] Install Zig (for building libghostty)
- [x] Clone Ghostty repository
- [x] Set up development environment

---

## ✅ Phase 1: Build libghostty xcframework — COMPLETE

- [x] Study Ghostty build system
- [x] Build xcframework for iOS (arm64, arm64-simulator)
- [x] Extract and configure C headers
- [x] Create GhosttyKit.xcframework with proper structure

**Deliverable**: `GhosttyKit.xcframework` ready for import ✅

---

## ✅ Phase 2: Minimal iOS App Shell — COMPLETE

- [x] Create Xcode project (SwiftUI lifecycle, iOS 16+)
- [x] Import GhosttyKit.xcframework
- [x] Create Swift wrapper for ghostty C API (`Ghostty.swift`)
  - [x] `Ghostty.Config` wrapper
  - [x] `Ghostty.App` wrapper  
  - [x] `Ghostty.SurfaceView` (UIView subclass)
  - [x] `Ghostty.SurfaceConfiguration` for External backend
- [x] Create GhosttySurfaceView (UIViewRepresentable bridge)
- [x] Verify terminal rendering works

**Deliverable**: iOS app that displays ghostty-rendered terminal ✅

---

## ✅ Phase 3: SSH Connection Layer — COMPLETE

- [x] Integrate libssh2 via SPM (CSSH package)
- [x] Implement SSHConnection class
  - [x] Socket connection
  - [x] SSH handshake
  - [x] Password authentication
  - [x] Channel open / PTY request
  - [x] Non-blocking read loop
- [x] Implement SSHSession wrapper with delegate pattern

**Deliverable**: Can connect, authenticate, and open PTY channel ✅

---

## ✅ Phase 4: I/O Bridge Integration — COMPLETE

- [x] Connect SSH channel output → ghostty surface (`feedData()`)
- [x] Connect ghostty input → SSH channel (`onWrite` callback)
- [x] Implement keyboard input via UIKeyInput protocol
  - [x] `insertText(_:)` for character input
  - [x] `deleteBackward()` for backspace
  - [x] `canBecomeFirstResponder` for keyboard activation
- [x] Fix IOSurfaceLayer sizing (iOS sublayer quirk)
- [x] Fix surface lifecycle (close/free without crash)
- [x] Terminal resize handling (basic)

**Deliverable**: Functional SSH terminal session ✅

---

## 🔄 Phase 5: iOS UX Polish — IN PROGRESS

### Keyboard & Input
- [x] **Hardware keyboard support**
  - [x] Arrow keys (up/down/left/right)
  - [x] Modifier keys (Ctrl+C, Ctrl+D, etc.)
  - [x] Function keys (F1-F12)
  - [x] Home/End/PageUp/PageDown
  - [x] UIKey → macOS keycode mapping
- [x] **Keyboard accessory bar**
  - [x] Esc button
  - [x] Ctrl toggle button (sticky modifier)
  - [x] Arrow key buttons

### Terminal Features
- [x] **Copy/paste support**
  - [x] Text selection (long press + drag using Ghostty mouse API)
  - [x] Copy to clipboard (uses ghostty_surface_read_selection)
  - [x] Paste from clipboard (via toolbar menu and system paste)
  - [x] System edit menu integration (canPerformAction)
- [x] **Terminal resize on keyboard show/hide**
  - [x] Keyboard notification observers
  - [x] Animated resize with bottom padding
- [x] **Terminal environment auto-setup**
  - [x] xterm-ghostty preferred (falls back to xterm-256color)
  - [x] COLORTERM=truecolor injection for server compatibility
- [ ] **Scrollback support** (if not already working)
- [ ] **tmux support**
  - [x] Ctrl+B prefix key handling (via Ctrl toggle)
  - [ ] Verify all escape sequences work correctly
  - [ ] Window/pane navigation testing

### Connection Management
- [x] **Saved connections**
  - [x] Connection profile model (host, port, username, auth method)
  - [x] UserDefaults persistence (ConnectionProfileManager)
  - [x] Connection list UI with add/edit/delete
  - [x] Quick Connect flow
  - [x] Favorites and recents tracking
  - [ ] iCloud sync for connection profiles
- [x] **SSH Key Authentication (Infrastructure)**
  - [x] Generate Ed25519 keys in-app (SSHKeyManager)
  - [x] Generate RSA keys (2048/4096 bit options)
  - [x] Keychain storage for keys
  - [x] Key management UI (SSHKeyListView)
  - [x] View/copy public key
  - [ ] Import keys from Files app
  - [ ] Secure Enclave storage (planned, needs additional work)
- [x] **Credential Provider System (Infrastructure)**
  - [x] KeychainCredentialProvider (saved passwords)
  - [x] SSHKeyCredentialProvider (key-based auth)
  - [x] Unified CredentialManager for multiple sources
  - [ ] 1Password integration (protocol ready, needs SDK)
  - [ ] iCloud Keychain (protocol ready, needs ASAuthorizationController)
  - [ ] LastPass (protocol ready, needs SDK)
  - [ ] AutoFill support for password fields
- [ ] **Connection status indicators**
- [x] **Handle remote disconnect**
  - [x] Detect SSH channel EOF/close
  - [x] Show disconnect via navigation
  - [x] Auto-navigate back to connection screen

### iPad-Specific
- [ ] Split View support
- [ ] Stage Manager support
- [ ] External display mirroring

### Settings
- [ ] Font size adjustment
- [ ] Theme/color scheme selection
- [ ] Terminal type (xterm-256color, etc.)

---

## 📋 Phase 6: Advanced Features — PLANNED

- [ ] **Secure Enclave keys** (hardware-backed SSH keys)
- [ ] **Multiple sessions** (tabs or split view)
- [ ] **SFTP browser** (file upload/download)
- [ ] **Mosh support** (stretch goal)
- [ ] **Snippet library** (saved commands)
- [ ] **Port forwarding**

---

## 📋 Phase 7: Release Preparation — PLANNED

- [ ] Performance optimization
- [ ] Accessibility (VoiceOver, Dynamic Type)
- [ ] Localization
- [ ] App Store assets (screenshots, description)
- [ ] Privacy policy
- [ ] TestFlight beta
- [ ] App Store submission

---

## Milestones Summary

| Phase | Goal | Status |
|-------|------|--------|
| 0 | Environment setup | ✅ Complete |
| 1 | Build xcframework | ✅ Complete |
| 2 | Minimal app shell | ✅ Complete |
| 3 | SSH connection | ✅ Complete |
| 4 | I/O bridge | ✅ Complete |
| 5 | iOS UX polish | 🔄 In Progress |
| 6 | Advanced features | 📋 Planned |
| 7 | Release prep | 📋 Planned |

**Current Status**: Working SSH terminal with Ghostty rendering. Ready for UX polish.

---

## Known Issues

1. **NoHomeDir warning** - Ghostty config looks for home directory (harmless on iOS)
2. **Scale factor** - May need adjustment for Retina displays
3. **Keyboard dismiss** - No explicit way to dismiss keyboard currently
4. **Simulator performance** - Rendering may be slower on iOS Simulator vs real device (Metal emulation overhead). Test on physical device for accurate performance assessment.
5. **Disconnect not detected** - When the remote host closes the SSH connection, the app doesn't detect it and navigate back. Need to handle EOF/channel close in the read loop.

---

## Technical Notes

### Key Implementation Details

1. **External Backend**: Using Ghostty's `GHOSTTY_BACKEND_EXTERNAL` which is designed for SSH/serial use cases where data comes from outside rather than a local PTY.

2. **IOSurfaceLayer Sizing**: On iOS, Ghostty adds its IOSurfaceLayer as a sublayer (vs. replacing the view's layer on macOS). We must manually resize it in `layoutSubviews`.

3. **addSublayer Workaround**: Ghostty's Zig code calls `objc.sel("addSublayer")` without the colon, which doesn't match ObjC conventions. We register a runtime method to handle this.

4. **Write Callback**: The external backend uses `ghostty_write_callback_fn` to notify Swift when the terminal wants to send data (user input → SSH).
