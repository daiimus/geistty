# Development Roadmap

## Overview

Geistty is a native iOS/iPadOS SSH terminal powered by Ghostty's terminal engine.

**Current state**: v0.1-stable — SSH + tmux control mode working end-to-end.
See [ARCHITECTURE.md](ARCHITECTURE.md) for technical details.

---

## Current Known Issues

| # | Issue | Severity | Notes |
|---|-------|----------|-------|
| 1 | Multi-pane dimension bug — panes don't use full available space after split | Medium | SwiftUI can't observe nested `@Published` across objects. See [details](#multi-pane-dimension-bug). |
| 2 | IOSurfaceLayer size mismatch during rapid resize | Low | Cosmetic — `surface is wrong size for layer, discarding`. Resize debouncing could be tighter. |
| 3 | NoHomeDir warning from Ghostty config | Low | Harmless on iOS — Ghostty looks for `~/.config/ghostty/` |
| 4 | Scroll sensitivity not configurable | Low | Adaptive velocity works but some users may want tuning |

### Multi-Pane Dimension Bug

**Symptom:** After `Cmd+D` split, neither pane fills its allocated area.

**Root cause:** SwiftUI doesn't observe nested `@Published` properties across different objects.
`onCellSizeChanged` callback was added but resize still doesn't trigger correctly.

**What works:** Connect, Cmd+D (split), Cmd+] (switch panes), exit one pane.
**What's broken:** Neither pane uses full available space after split.

**Next steps:**
1. Check console for `📐 Primary cell size updated` messages
2. Verify `handleSizeChange` is called with correct geometry
3. Check if `refresh-client -C` is actually sent to tmux
4. Compare sent dimensions with actual available pixel space
5. May need to investigate `TmuxSplitTreeView` layout

**Related files:** `TmuxMultiPaneView.swift`, `Ghostty.swift` (sizeDidChange), `TmuxSessionManager.swift` (primaryCellSize), `TmuxSplitTreeView.swift`

---

## Code Cleanup Backlog

### High Priority

| Task | Effort | Notes |
|------|--------|-------|
| Remove dead tmux search mode code | Medium | `captureTmuxPane()` stub always fails → entire tmux search codepath is dead. See [details](#dead-tmux-search-mode-code). |
| Consolidate `controlModeActive`/`controlModeDataRouting` → `ControlModeState` enum | Low | Two booleans tracking same concept |

### Medium Priority

| Task | Effort | Notes |
|------|--------|-------|
| Consolidate font mapping (3 places) | Low | `Ghostty.swift` mapFontFamily/reverseMapFontFamily + `SettingsView.swift` fontFamilies |
| Split `TerminalContainerView.swift` (~1700 lines) | High | Extract search UI into separate view |
| Split `TmuxSessionManager.swift` (~1800 lines) | High | Deferred from Dec 2025 |
| Extract common connection logic in SSHSession | Medium | 3 similar connect methods |
| Migrate callback bridges to async/await in TmuxSessionManager | Medium | Tech debt from TmuxGateway migration |

### Low Priority

| Task | Effort | Notes |
|------|--------|-------|
| Extract magic numbers to constants | Low | Timeouts, marker strings |
| Review and standardize naming conventions | Low | |
| Add missing documentation comments | Low | |

### Dead tmux Search Mode Code

The `captureTmuxPane()` stub in `TerminalContainerView.swift` always returns failure, making the entire tmux search mode codepath dead. Ghostty's native sync search works correctly as fallback.

**Files affected:**
- `TerminalContainerView.swift`: `captureTmuxPane()` stub (491-503), `tmuxGotoLine()` (507-529), callback wiring (1182-1195, 1204-1205)
- `SurfaceSearchOverlay.swift`: extensive tmux search mode branches (lines 110, 122-124, 133, 136, 153-155, 163-188, 191-211, etc.)
- `Ghostty.swift`: `SearchMode.tmux` enum case, `tmuxContent`, `tmuxMatchLines`, `isCapturing`, `captureError` on `SearchState` (3307-3341)

Removing this would significantly simplify `SurfaceSearchOverlay`.

---

## Completed Milestones (Summary)

| Phase | What | When |
|-------|------|------|
| 0 | Environment setup (Xcode, Zig, Homebrew) | 2024 |
| 1 | Build GhosttyKit.xcframework for iOS | 2024 |
| 2 | Minimal iOS app shell with Ghostty rendering | 2024 |
| 3 | SSH connection via SwiftNIO-SSH (migrated from libssh2) | Dec 2024 |
| 4 | I/O bridge — SSH ↔ Ghostty bidirectional data flow | Dec 2024 |
| tmux 1 | tmux control mode (-CC) protocol parsing | Dec 2024 |
| tmux 2 | Multi-pane: per-pane surfaces, output routing, split layout | Dec 2024 |
| tmux 2.5 | Multi-pane polish: close/create handling, scrollback restore | Dec 2024 |
| tmux 3 | Multiple windows, Ghostty-style keybindings (Cmd+D, Cmd+], etc.) | Dec 2024 |
| tmux 3.5 | Disconnection handling, auto-reconnect, credential retention | Dec 2025 |
| Architecture | TmuxGateway actor migration (from TmuxControlClient) | Dec 2025 |
| Architecture | Swift-native SSH (libssh2 → SwiftNIO-SSH) | Dec 2024 |
| Cleanup | Dead code removal (GhosttyAPI.swift, SurfaceManager.swift, etc.) | Dec 2025 |
| Cleanup | Debug code cleanup (print → Logger) | Dec 2025 |
| Docs | ARCHITECTURE.md and README.md rewrite for v0.1-stable | Feb 2026 |

---

## Phase 5: iOS UX Polish (IN PROGRESS)

### Completed

- Hardware keyboard: arrows, modifiers, function keys, Home/End/PgUp/PgDn, key repeat
- Keyboard accessory bar: Esc, Ctrl toggle, Tab, pipe, tilde, arrows
- Ghostty keyboard API integration (ghostty_surface_key, KeyEvent, HID mapping)
- Copy/paste: long-press selection, click-drag, clipboard, system edit menu
- Terminal resize on keyboard show/hide
- Scrollback: touch scrolling, trackpad, momentum, position indicator
- tmux support: Ctrl+B prefix, bracketed paste, auto-attach, custom session name
- Saved connections: profiles, UserDefaults, add/edit/delete, favorites, iCloud sync (code ready)
- SSH key auth: Ed25519/RSA generation, Keychain storage, key management UI, Files import
- Credential provider system: Keychain + SSH key providers, unified CredentialManager
- Font: family selection, size adjustment, live updates, persistence
- Theme: 18 bundled themes, color preview, live updates, persistence
- Text rendering: font thickening, freetype hinting, proper DPI handling
- iPad: Split View, Stage Manager, external display, menu bar integration
- Gestures: double-tap word select, triple-tap line select, pinch zoom, two-finger reset
- Shortcuts: Cmd+C/V/A/K/W/0/+/-, font size buttons, dismiss keyboard

### Remaining

| Task | Priority | Notes |
|------|----------|-------|
| Common symbols bar (~, \|, `, etc.) | Medium | Hard to type on iOS software keyboard |
| Keyboard shortcuts help overlay | Low | Discoverability |
| Key repeat delay/rate as configurable settings | Low | Currently hardcoded 0.4s/20Hz |
| Fine-tune scroll sensitivity settings | Low | |
| Connection timeout setting | Low | |
| Keep-alive ping option | Low | |

---

## Phase 6: Session Management & Navigation (PLANNED)

### Session Lifecycle

- [ ] New Connection (Cmd+N) from terminal view
- [ ] Quick Connect (Cmd+O) from anywhere
- [ ] Back to connection list from terminal
- [ ] Session switching between active connections

### Window Management (iPadOS)

- [ ] UISceneDelegate for multiple independent terminal windows
- [ ] Scene state restoration
- [ ] Each scene = independent SSH session
- [ ] External display: dedicated terminal on second screen

### Connection State

- [ ] Visual connection status indicators (connecting/connected/disconnected)
- [ ] Session persistence across app restart
- [ ] Keep-alive pings to prevent idle disconnect

### Menu Completion

Already done: Copy, Paste, Select All, Clear Screen, font size shortcuts.

Remaining:
- [ ] Find (Cmd+F) — search overlay exists, needs menu wiring
- [ ] Toggle Full Screen (hide status bar)
- [ ] Reset Terminal (Cmd+Shift+R)
- [ ] Terminal Inspector (debug info)
- [ ] Connection menu: Reconnect, Duplicate Session, SSH Key Manager, Profiles

---

## Phase 7: Configuration System (IN PROGRESS)

### Completed

- Config file (`ghostty.conf`) as source of truth
- Reload config from file (Cmd+Shift+,)
- Theme/font/cursor changes write to config
- In-app config editor

### Remaining

- [ ] Syntax validation & error reporting
- [ ] Config import/export
- [ ] Theme import (.conf format)

---

## Phase 8: Advanced Features (PLANNED)

### SFTP / Remote Files

**Status:** Protocol layer implemented, File Provider archived (branch `archive/file-provider-jan-2026`).
See `FILE_PROVIDER_LEARNINGS.md` for post-mortem.

SFTP code (`Sources/SFTP/`) is dormant but retained for future File Provider work:
- `SFTPChannel.swift` — low-level SFTP protocol
- `SFTPClient.swift` — high-level async API
- `SFTPClientProtocol.swift` — protocol abstraction
- `MockSFTPClient.swift` — mock for testing

Future File Provider work:
- [ ] Metadata cache (SQLite, like Blink Shell's WorkingSetDatabase)
- [ ] Fast enumeration (return cached immediately, refresh async)
- [ ] Background polling + `signalEnumerator()` for changes
- [ ] Per-server "Show in Files.app" toggle
- [ ] Offline cache with sync badges

### Security

- [ ] Secure Enclave key storage (hardware-backed SSH keys)

### Developer Features

- [ ] Clickable URLs (open in browser)
- [ ] Clickable file paths (quick actions)
- [ ] Error line detection (jump to file:line from stack traces)
- [ ] Command palette (Cmd+Shift+P)
- [ ] Session recording (save terminal to file)
- [ ] Clipboard history

### Stretch Goals

- [ ] Mosh support
- [ ] Snippet library (saved commands)
- [ ] Port forwarding
- [ ] Syntax highlighting in output
- [ ] JSON/YAML pretty print
- [ ] Selection visual feedback (fade-out after copy)

---

## Phase 9: Release Preparation (PLANNED)

### Apple Developer Setup

- [ ] Enroll in Apple Developer Program ($99/year)
- [ ] Create App ID (com.geistty.app)
- [ ] Enable iCloud entitlement
- [ ] Create App Store Connect listing

### TestFlight Beta

- [x] TestFlight distribution guide (TESTFLIGHT.md)
- [ ] Archive release build
- [ ] Upload to App Store Connect
- [ ] Internal testing → External beta → Collect feedback

### App Store Assets

- [x] App icon (1024x1024, light/dark variants)
- [x] Launch screen
- [x] App Store metadata guide (APP_STORE.md)
- [x] App description + keywords
- [x] Privacy policy (PRIVACY.md)
- [ ] Screenshots (iPad Pro, iPhone)
- [ ] App preview video (optional)
- [ ] Support URL (GitHub Pages)

### Compliance

- [x] Export compliance (ITSAppUsesNonExemptEncryption=NO)
- [x] Privacy policy
- [ ] Age rating questionnaire

### Polish

- [ ] Onboarding flow (first launch)
- [ ] Accessibility (VoiceOver, Dynamic Type)
- [ ] Localization (English first)
- [ ] Performance profiling
- [ ] Memory leak check

---

## Ghostty Debug Logging Cleanup

When ready to remove verbose debug logging from the Ghostty fork:

- [ ] `src/terminal/Terminal.zig` — Remove `std.log.err` in switchScreen/switchScreenMode
- [ ] `src/terminal/ScreenSet.zig` — Remove `std.log.err` in init
- [ ] `src/apprt/embedded.zig` — Remove verbose search debug logging
- [ ] `src/global.zig` — Review debug logging settings for lib mode
- [ ] Rebuild GhosttyKit xcframework after cleanup

---

## Technical Notes

1. **External Backend**: `GHOSTTY_BACKEND_EXTERNAL` — terminal emulation without PTY (iOS can't fork/exec).
2. **IOSurfaceLayer sizing**: On iOS, Ghostty adds IOSurfaceLayer as sublayer (not replacing view's layer like macOS). Manual resize in `layoutSubviews`.
3. **addSublayer workaround**: Ghostty's Zig code calls `objc.sel("addSublayer")` without colon. Runtime method registered to handle this.
4. **Write callback**: External backend uses `ghostty_write_callback_fn` to notify Swift when terminal wants to send data.
