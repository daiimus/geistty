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
  - [x] Control character handling for external apps (tmux, vim, blightmud)
  - [x] Function keys (F1-F12)
  - [x] Home/End/PageUp/PageDown
  - [x] UIKey → macOS keycode mapping
  - [x] Key repeat support (timer-based, 0.4s delay, 20/sec rate)
- [x] **Keyboard accessory bar**
  - [x] Esc button
  - [x] Ctrl toggle button (sticky modifier)
  - [x] Arrow key buttons
- [ ] **Additional keyboard improvements**
  - [ ] Alt/Option modifier support (for vim, emacs) ⭐ HIGH PRIORITY - Should work now with proper Ghostty API!
  - [ ] Tab key button in accessory bar
  - [ ] Common symbols bar (~, |, `, etc.)
  - [x] Cmd+C/V for copy/paste (intercept and handle) ✅
  - [x] Cmd+A for select all ✅
  - [x] Cmd+K for clear screen ✅
  - [x] Cmd+W for disconnect ✅
  - [x] Font size shortcuts (Cmd+0/+/-) ✅
  - [ ] Keyboard shortcuts help overlay
  - [ ] Key repeat delay/rate as configurable settings
- [x] **Proper Ghostty keyboard API integration** ✅ COMPLETE
  - [x] Refactor to use ghostty_surface_key() instead of raw byte sending
  - [x] Build KeyEvent struct matching macOS implementation (GhosttyInput.swift)
  - [x] Map UIKey to Ghostty key codes (UIKeyboardHIDUsage → macOS keycodes)
  - [x] Support all modifiers (Shift, Ctrl, Alt, Super, Caps, Num)
  - [x] Handle key repeat properly (press/repeat/release actions)
  - [x] Enable Ghostty keybinding system

### Terminal Features
- [x] **Copy/paste support**
  - [x] Text selection (long press + drag using Ghostty mouse API)
  - [x] Mouse/trackpad click-drag selection (instant response)
  - [x] Copy to clipboard (uses ghostty_surface_read_selection)
  - [x] Paste from clipboard (via toolbar menu and system paste)
  - [x] System edit menu integration (canPerformAction)
- [x] **Terminal resize on keyboard show/hide**
  - [x] Keyboard notification observers
  - [x] Animated resize with bottom padding
- [x] **Terminal environment auto-setup**
  - [x] xterm-ghostty preferred (falls back to xterm-256color)
  - [x] COLORTERM=truecolor injection for server compatibility
- [x] **Scrollback support**
  - [x] Touch scrolling with adaptive velocity
  - [x] Trackpad/mouse wheel support
  - [x] Momentum scrolling
  - [x] Scroll position indicator
  - [ ] Fine-tune scroll sensitivity settings
- [x] **tmux support**
  - [x] Ctrl+B prefix key handling
  - [x] Control character sequences working
  - [x] Bracketed paste mode (paste_from_clipboard binding action)
  - [x] All escape sequences verified working
  - [x] Window/pane navigation tested
  - [x] Auto-attach to tmux session on connect (per-connection setting)
  - [x] Custom tmux session name support

### Connection Management
- [x] **Saved connections**
  - [x] Connection profile model (host, port, username, auth method)
  - [x] UserDefaults persistence (ConnectionProfileManager)
  - [x] Connection list UI with add/edit/delete
  - [x] Quick Connect flow
  - [x] Favorites and recents tracking
  - [x] iCloud sync for connection profiles (code ready, needs paid developer account for entitlement)
- [x] **SSH Key Authentication**
  - [x] Generate Ed25519 keys in-app (SSHKeyManager)
  - [x] Generate RSA keys (2048/4096 bit options)
  - [x] Keychain storage for keys
  - [x] Key management UI (SSHKeyListView)
  - [x] View/copy public key
  - [x] Import keys from Files app (.pem, .key files)
  - [ ] Secure Enclave storage (planned, needs additional work)
- [x] **Credential Provider System**
  - [x] KeychainCredentialProvider (saved passwords)
  - [x] SSHKeyCredentialProvider (key-based auth)
  - [x] Unified CredentialManager for multiple sources
  - [x] Password entry at connection time (saved to Keychain)
  - ~~1Password/LastPass integration~~ (Not possible on iOS - their SSH integration uses desktop SSH Agent, not available via iOS APIs. Export keys from password manager and import into Bodak via Files app)
- [ ] **Connection status indicators** ⭐ MEDIUM PRIORITY
- [x] **Handle remote disconnect**
  - [x] Detect SSH channel EOF/close
  - [x] Show disconnect via navigation
  - [x] Auto-navigate back to connection screen

### iPad-Specific
- [x] Split View support (works out of box with SwiftUI)
- [x] Stage Manager support (works out of box with SwiftUI)
- [x] External display mirroring (automatic via WindowGroup)
- [x] UISupportsMultipleScenes enabled
- [x] **iPadOS menu bar integration**
  - [x] Native menu bar with File/Edit/View/Terminal menus
  - [x] Keyboard shortcuts displayed in menu items
  - [x] Embraces native iOS keyboard show/hide behavior

### Settings
- [x] **Font family selection**
  - [x] Font picker UI (Departure Mono, SF Mono, Menlo, Courier New)
  - [x] Live font updates (ghostty_surface_update_config)
  - [x] ghostty_config_load_string API for config loading
  - [x] Font preference persistence (UserDefaults)
- [x] **Font size adjustment**
  - [x] Slider control in Settings (8-32pt range)
  - [x] Live font size updates
  - [x] Reset to default button
- [x] **Theme/color scheme selection**
  - [x] 18 bundled Ghostty themes (light & dark)
  - [x] Theme picker with color palette preview
  - [x] Live theme updates
  - [x] Theme persistence (UserDefaults)
- [x] **Text rendering quality**
  - [x] Font thickening toggle for Retina displays
  - [x] Freetype hinting (light) for optimal clarity
  - [x] Proper DPI/contentScaleFactor handling throughout
- [ ] Terminal type (xterm-256color, etc.)

---

## 📋 Phase 6: Session Management & Navigation — IN PROGRESS

The goal is to complete the session lifecycle: start screen → connect → use terminal → disconnect/switch → back to start. Leverage native Ghostty and iPadOS window management.

### Session Lifecycle
- [ ] **New Connection** (Cmd+N) - Open new connection sheet from terminal
- [ ] **Quick Connect** (Cmd+O) - Quick connect dialog from anywhere
- [ ] **Close/Disconnect** (Cmd+W) - Clean session teardown
- [ ] **Reconnect** - Reconnect to same host after disconnect
- [ ] **Back to Start** - Navigate from terminal back to connection list
- [ ] **Session switching** - Switch between active sessions

### Window Management (iPadOS + Ghostty)
- [ ] **iPadOS Scenes** - Multiple independent terminal windows
  - [ ] UISceneDelegate implementation
  - [ ] Scene state restoration
  - [ ] Each scene = independent SSH session
- [ ] **Stage Manager integration** - Multiple windows side by side
- [ ] **External display** - Dedicated terminal on second screen
- [ ] **Ghostty splits** (stretch) - Multiple surfaces in one window

### Connection State
- [ ] **Connection status indicators** - Visual state (connecting/connected/disconnected)
- [ ] **Session persistence** - Remember open sessions across app restart
- [ ] **Auto-reconnect option** - Reconnect on network recovery
- [ ] **Keep-alive pings** - Prevent idle disconnect

### Menu Structure (Ghostty macOS style)

**File Menu:**
- [ ] New Connection (Cmd+N)
- [ ] Quick Connect (Cmd+O)
- [ ] Close/Disconnect (Cmd+W)

**Edit Menu:**
- [x] Copy (Cmd+C)
- [x] Paste (Cmd+V)
- [x] Select All (Cmd+A)
- [ ] Find... (Cmd+F) - stretch goal

**View Menu:**
- [x] Reset Font Size (Cmd+0)
- [x] Increase Font Size (Cmd++)
- [x] Decrease Font Size (Cmd+-)
- [ ] Toggle Full Screen (hides status bar)

**Terminal Menu:**
- [x] Clear Screen (Cmd+K)
- [ ] Reset Terminal (Cmd+Shift+R)
- [ ] Terminal Inspector (debug info)

**Connection Menu:**
- [ ] Reconnect
- [ ] Duplicate Session
- [ ] SSH Key Manager
- [ ] Connection Profiles

---

## 📋 Phase 7: Configuration System — IN PROGRESS

Config file (`ghostty.conf`) is now the source of truth.

**Completed:**
- [x] Config file as source of truth
- [x] Reload config from file (Cmd+Shift+,)
- [x] Theme selector writes inline colors to config
- [x] Settings UI adapts to theme (preferredColorScheme)
- [x] Font/cursor/theme changes write to config file
- [x] In-app config editor

**Remaining:**
- [ ] Syntax validation & error reporting
- [ ] Config import/export
- [ ] Theme import (.conf format)

---

## 📋 Phase 8: Advanced Features — PLANNED

- [ ] **Secure Enclave keys** (hardware-backed SSH keys)
- [x] **Multiple sessions** (native iOS multi-window via WindowGroup + UISupportsMultipleScenes)
- [ ] **SFTP browser** (integrate with iPadOS Files app) ⭐ HIGH VALUE
  - [ ] FileProvider extension for Files.app integration
  - [ ] Browse remote directories
  - [ ] Upload/download files
  - [ ] Quick Look preview support
- [ ] **Mosh support** (stretch goal)
- [ ] **Snippet library** (saved commands)
- [ ] **Port forwarding**
- [ ] **Selection visual feedback** (fade-out after copy-on-select)
  - [ ] Show selection highlight during drag
  - [ ] Animated fade-out after release to indicate copy succeeded
  - [ ] Would require Ghostty-side changes to keep selection visible briefly

---

## 📋 Phase 9: Release Preparation — PLANNED

### Apple Developer Setup
- [ ] Enroll in Apple Developer Program ($99/year)
- [ ] Create App ID (com.bodak.app)
- [ ] Enable iCloud entitlement (for connection sync)
- [ ] Create App Store Connect listing

### TestFlight Beta
- [ ] Archive release build
- [ ] Upload to App Store Connect
- [ ] Internal testing (your devices)
- [ ] External beta testers
- [ ] Collect crash reports & feedback

### App Store Assets
- [ ] App icon (1024x1024)
- [ ] Screenshots (iPad Pro, iPhone)
- [ ] App preview video (optional)
- [ ] App description
- [ ] Keywords for search
- [ ] Privacy policy URL
- [ ] Support URL

### Compliance
- [ ] Export compliance (encryption - SSH uses crypto)
- [ ] Privacy policy (what data is collected/stored)
- [ ] Age rating questionnaire

### Polish
- [ ] Launch screen / splash
- [ ] Onboarding flow (first launch)
- [ ] Accessibility (VoiceOver, Dynamic Type)
- [ ] Localization (English first, others later)
- [ ] Performance profiling
- [ ] Memory leak check

### Submission
- [ ] App Review Guidelines compliance check
- [ ] Submit for review
- [ ] Respond to any rejections
- [ ] Release to App Store

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
5. ~~**Disconnect not detected**~~ - Fixed: Now handles EOF/channel close and navigates back
6. **Scroll sensitivity** - Touch scrolling may need per-user tuning (currently adaptive velocity)

---

## 🎯 Low-Hanging Fruit (Quick Wins)

These are small improvements that would have big impact:

### Input/Keyboard
- [x] Add Tab key to accessory bar (very common in terminal)
- [x] Add pipe `|` and tilde `~` buttons (hard to type on iOS keyboard)
- [x] Haptic feedback on Ctrl toggle activation
- [x] Visual indicator when Ctrl is active (pulsing orange border)

### Terminal UX
- [x] Double-tap to select word
- [x] Triple-tap to select line
- [x] Pinch to zoom (font size)
- [x] Shake to clear screen (send Ctrl+L)
- [x] Two-finger double-tap to reset font size
- [x] Font size buttons in toolbar (A+ / A-)

### Connection UX
- [ ] Connection timeout setting
- [x] Retry connection button on disconnect
- [ ] "Keep alive" ping option
- [x] Show connection duration in header

### Polish
- [ ] App icon (currently default)
- [ ] Launch screen
- [ ] Onboarding flow for first connection
- [x] Keyboard shortcut discoverability (Cmd+hold menu on iPad)
- [x] Keyboard shortcuts (Cmd+K clear, Cmd+N new, Cmd+O quick connect, Cmd++/- zoom)
- [x] Dismiss keyboard button in toolbar
- [x] Context menu: duplicate connection, copy host/connection string

---

## 🚀 AI Coding Tools Support (Cursor/Claude Code/Aider)

Features that would make Bodak essential for developers using AI terminals:

### Large Text Handling
- [ ] **Paste large code blocks** - Handle multi-KB pastes without lag/truncation
- [ ] **Bracketed paste mode** - Proper escape sequences for pasting into vim/editors
- [ ] **Streaming output optimization** - Handle rapid AI output without flicker

### Selection & Copying
- [ ] **Select visible output** - Quick select last command output
- [ ] **Select by regex/pattern** - Find and select code blocks
- [ ] **Copy without line numbers** - Strip prompt prefixes when copying
- [ ] **Copy as markdown** - Preserve code block formatting

### Multi-Line Input
- [ ] **Multi-line paste handling** - Don't execute each line separately
- [ ] **Here-doc support** - Paste multi-line strings properly
- [ ] **Input history** - Browse previous long commands

### URL & Path Handling
- [ ] **Clickable URLs** - Open links in browser
- [ ] **Clickable file paths** - Quick actions (copy, open in Files)
- [ ] **Error line detection** - Jump to file:line from stack traces

### Session Management
- [ ] **Session persistence** - Reconnect to tmux/screen automatically
- [ ] **Multiple panes** - Split view for parallel AI sessions
- [ ] **Session recording** - Save terminal session to file
- [ ] **Quick switch** - Fast switching between multiple SSH connections

### Search & Navigation
- [ ] **Search in scrollback** - Find text in terminal history (Cmd+F)
- [ ] **Jump to prompt** - Quick navigation between command prompts
- [ ] **Semantic search** - Find by description ("that curl command")

### Developer Quality of Life
- [ ] **Syntax highlighting in output** - Detect and highlight code blocks
- [ ] **JSON/YAML pretty print** - Auto-format structured output
- [ ] **Diff highlighting** - Color git diffs properly
- [ ] **Command palette** - Quick actions via Cmd+Shift+P

### Clipboard Integration
- [ ] **Clipboard history** - Access recent copies
- [ ] **Smart paste** - Detect and handle different content types
- [ ] **Share sheet** - Share terminal output via iOS share

---

## Technical Notes

### Key Implementation Details

1. **External Backend**: Using Ghostty's `GHOSTTY_BACKEND_EXTERNAL` which is designed for SSH/serial use cases where data comes from outside rather than a local PTY.

2. **IOSurfaceLayer Sizing**: On iOS, Ghostty adds its IOSurfaceLayer as a sublayer (vs. replacing the view's layer on macOS). We must manually resize it in `layoutSubviews`.

3. **addSublayer Workaround**: Ghostty's Zig code calls `objc.sel("addSublayer")` without the colon, which doesn't match ObjC conventions. We register a runtime method to handle this.

4. **Write Callback**: The external backend uses `ghostty_write_callback_fn` to notify Swift when the terminal wants to send data (user input → SSH).
