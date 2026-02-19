# Development Roadmap

## Overview

Geistty is a native iOS/iPadOS SSH terminal powered by Ghostty's terminal engine.

**Current state**: v0.2 — SSH + tmux control mode working end-to-end, multi-pane fully functional.
See [ARCHITECTURE.md](ARCHITECTURE.md) for technical details.

---

## Current Known Issues

| # | Issue | Severity | Notes |
|---|-------|----------|-------|
| 1 | tmux teardown SIGSEGV | High | `%exit` → `controlModeExited()` → `surface.close()` without `detachTmuxPane()` first → use-after-free in Zig. Intentional skip — dereferencing `binding.source` during teardown hits freed memory. Relies on Ghostty internal cleanup ordering. |
| 2 | tmux session name grabbing | Medium | Grabs arbitrary tmux sessions instead of targeting a specific one. |
| 3 | SwiftUI AttributeGraph cycles | Medium | ~26 per layout pass. Cosmetic but noisy. From nested `@Published` + `GeometryReader`. |
| 4 | IOSurfaceLayer size mismatch during rapid resize | Low | Cosmetic — `surface is wrong size for layer, discarding`. Resize debouncing could be tighter. |
| 5 | Write interleaving | Low | Rapid keystrokes can interleave across SSH writes. No user-visible corruption observed. |
| 6 | `unexpected block output err=false` | Low | Benign but noisy Zig-side log during tmux command processing. |
| 7 | Session resume/reconnect after iOS backgrounding | Medium | No `beginBackgroundTask` — TCP dies immediately when app backgrounds. `attemptReconnect()` exists (3 retries) but is fragile. See WS-D plan. |
| 8 | `captureTmuxPane()` for search is stubbed | Low | Relied on old gateway command/response pattern. Use Ghostty's built-in search instead. |
| 9 | NoHomeDir warning from Ghostty config | Low | Harmless on iOS — Ghostty looks for `~/.config/ghostty/` |
| 10 | `failed to get pin for clicked point` | Low | Benign Zig warning from `Surface.zig:4484` during resize — viewport coordinates exceed page list dimensions. Not a bug. |

---

## Code Cleanup Backlog

### High Priority

| Task | Effort | Notes |
|------|--------|-------|
| Dead code removal across 4 big files | **DONE** | Completed Feb 2026. ~900 lines removed across Sessions 7-10. All archived in `docs/archive/DEAD_CODE_FEB_2026.swift`. |

### Medium Priority

| Task | Effort | Notes |
|------|--------|-------|
| ~~Split `TerminalContainerView.swift`~~ | **DONE** | Decomposed from ~2330 → ~912 lines via VC extensions (Keyboard, MenuBar, Search, Shortcuts, Tmux, WindowPicker). Completed Feb 2026. |
| Split `TmuxSessionManager.swift` (~1550 lines) | High | Extract user actions/commands, surface management, split resize helpers. Deferred from Dec 2025 |
| Migrate callback bridges to async/await in TmuxSessionManager | Medium | 6 closure-based callbacks from pre-Ghostty architecture. Working but tech debt |

### Low Priority

| Task | Effort | Notes |
|------|--------|-------|
| Extract magic numbers to constants | Low | Timeouts, marker strings |
| Review and standardize naming conventions | Low | |
| Add missing documentation comments | Low | |

### Dead Code Audit (Feb 2026) — COMPLETED

Comprehensive audit of the 4 largest files. All items resolved across Sessions 7-10:

- **Session 7**: ~465 lines removed from Ghostty.swift, SurfaceSearchOverlay.swift, TerminalContainerView.swift, GeisttyApp.swift, SSHSession.swift, TmuxSessionManager.swift (commit `362b2a2`)
- **Sessions 8-9 (Batch 2)**: ~420 lines of dead TmuxGateway legacy code removed — layout helpers, QueryFormat, dead pane properties, SessionResumeStatus chain (commit `3a77551`)
- **Session 10 (Batch 1)**: Fixed Swift code duplicating Ghostty — paste() bracketed paste bug, copy() redundancy, clearScreen() scrollback clearing, SET_TITLE wiring, config parser redundancies, dead properties (commit `0cb98d1`)
- **Session 10 (final sweep)**: Removed last dead method — `SSHSession.write(_ string:)`

**4 ShortcutAction enum cases** (`.newWindow`, `.closeSurface`, `.closeTab`, `.disconnect`) are defined but not yet dispatched by keyboard shortcuts. Kept intentionally — they have handler arms wired in `handleShortcut` for future use.

All removed code archived in `docs/archive/DEAD_CODE_FEB_2026.swift`.

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
| Cleanup | Docs cleanup, SFTP archive, dead tmux search mode removal | Feb 2026 |
| Infra | Rebase Ghostty fork on upstream, rebuild GhosttyKit | Feb 2026 |
| Refactor | Theme system simplification — native Ghostty theme resolution | Feb 2026 |
| Refactor | Config introspection via ghostty_config_get() with hybrid fallback | Feb 2026 |
| Cleanup | Font mapping consolidation (FontMapping.swift), SF Mono default fix | Feb 2026 |
| Refactor | ControlModeState enum (replaced controlModeActive/controlModeDataRouting booleans) | Feb 2026 |
| Cleanup | Dead code audit complete — ~900 lines removed, Ghostty delegation fixes, SET_TITLE wired | Feb 2026 |
| Feature | Command palette (Cmd+Shift+P) with search, 30 tests | Feb 2026 |
| Feature | Jump to Prompt implementation | Feb 2026 |
| Fix | tmux DCS passthrough display freeze — persistent VT parser + absorbing state reset in viewer.zig | Feb 2026 |
| Fix | 6-agent code review (63 findings): Phase A Critical (C1-C8), Phase B High (H3-H13), Phase C Medium (M1-M20), Phase D Low (L3-L19) — all complete | Feb 2026 |
| Infra | TmuxWireDiagnostics shadow parser for tmux control mode debugging (48 tests) | Feb 2026 |
| Testing | Test suite expanded from 470 to 550 tests across 25 suites | Feb 2026 |
| Feature | Multi-pane terminal binding — per-pane rendering with shared mutex observer system (Sessions 68-106, 38-session epic) | Feb 2026 |
| Fix | Observer wakeup — iOS has no display link, so observer renderers need explicit notify_cb callback | Feb 2026 |
| Fix | Renderer bleed — `syncLayouts()` re-pointed primary renderer at wrong pane; fixed by registering primary as observer for `fixupObservers()` | Feb 2026 |
| Fix | Nuke-and-pave focus system — replaced 9 layered guards (Fixes A-I) with clean `canBecomeFirstResponder = !isMultiPaneObserver` | Feb 2026 |
| Fix | Multi-pane echo — added `setActiveTmuxPaneInputOnly` (input routing without renderer swap) | Feb 2026 |
| Fix | Multi-pane sizing — divider-aware ratios, thin 2pt dividers, negative width clamp, lexicographic sort fix | Feb 2026 |
| Feature | Per-pane pinch-to-zoom — observer surfaces get pinch + two-finger-double-tap gestures (WS-Z) | Feb 2026 |
| Fix | Bottom screen real estate — disable safe area propagation on tmux hosting controller, auto-hide home indicator (WS-B) | Feb 2026 |
| Testing | Test suite: 25 suites, 649+ tests across 22 test files (~10,200 lines) | Feb 2026 |

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
- **tmux multi-pane**: per-pane rendering, observer surfaces, focus switching, close/create handling
- **Per-pane pinch-to-zoom**: independent font size per observer surface, two-finger reset
- Saved connections: profiles, UserDefaults, add/edit/delete, favorites, iCloud sync (code ready)
- SSH key auth: Ed25519/RSA generation, Keychain storage, key management UI, Files import
- Credential provider system: Keychain + SSH key providers, unified CredentialManager
- Font: family selection, size adjustment, live updates, persistence
- Theme: 18 bundled themes, color preview, live updates, persistence
- Text rendering: font thickening, freetype hinting, proper DPI handling
- iPad: Split View, Stage Manager, external display, menu bar integration
- Gestures: double-tap word select, triple-tap line select, pinch zoom, two-finger reset
- Shortcuts: Cmd+C/V/A/K/W/0/+/-, font size buttons, dismiss keyboard
- **Bottom screen real estate**: safe area propagation disabled, home indicator auto-hidden

### Remaining

| Task | Priority | Notes |
|------|----------|-------|
| Graceful disconnect/reconnect (WS-D) | High | Safe tmux teardown, `beginBackgroundTask`, reconnection UX, SSH keepalive. See [Phase 5.5](#phase-55-graceful-disconnect--reconnect-planned). |
| Common symbols bar (~, \|, `, etc.) | Medium | Hard to type on iOS software keyboard |
| Keyboard shortcuts help overlay | Low | Discoverability |
| Key repeat delay/rate as configurable settings | Low | Currently hardcoded 0.4s/20Hz |
| Fine-tune scroll sensitivity settings | Low | |
| Connection timeout setting | Low | |
| Keep-alive ping option | Low | Partially addressed by WS-D |

---

## Phase 5.5: Graceful Disconnect & Reconnect (PLANNED)

Designed in Session 107, planned for Sessions 110-113.

| Step | Scope | Description |
|------|-------|-------------|
| WS-D1 | Safe teardown | Fix tmux teardown SIGSEGV — `detachTmuxPane()` before `surface.close()` in `controlModeExited()` |
| WS-D2 | Background task | Add `beginBackgroundTask` to keep TCP alive during iOS backgrounding |
| WS-D3 | Reconnection UX | Visual status indicators, robust retry logic, session re-attach |
| WS-D4 | SSH keepalive | Periodic keepalive pings to prevent idle disconnect |

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
- Native theme resolution via `GHOSTTY_RESOURCES_DIR` (theme = name)
- Config introspection via `ghostty_config_get()` for supported types
- Hybrid sync: C API for simple types, file parser for RepeatableString/Theme
- Font mapping consolidated in `FontMapping.swift`

### Remaining

- [ ] Syntax validation & error reporting
- [ ] Config import/export
- [ ] Theme import (.conf format)

---

## Phase 8: Advanced Features (PLANNED)

### SFTP / Remote Files

**Status:** Protocol layer archived (branch `archive/file-provider-jan-2026`). `Sources/SFTP/` directory removed Feb 2026; code archived in `docs/archive/DEAD_CODE_FEB_2026.swift`.
See `FILE_PROVIDER_LEARNINGS.md` for post-mortem.

Future File Provider work (would require reimplementation):
- [ ] Metadata cache (SQLite, like Blink Shell's WorkingSetDatabase)
- [ ] Fast enumeration (return cached immediately, refresh async)
- [ ] Background polling + `signalEnumerator()` for changes
- [ ] Per-server "Show in Files.app" toggle
- [ ] Offline cache with sync badges

### Security

- [ ] Secure Enclave key storage (hardware-backed SSH keys)

### Developer Features

- [x] Command palette (Cmd+Shift+P) — **DONE** (Session 46, 30 tests)
- [ ] Clickable URLs (open in browser)
- [ ] Clickable file paths (quick actions)
- [ ] Error line detection (jump to file:line from stack traces)
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

> **Note:** Swift-side logger level misuse (SSH key parsing at `.error`, hex-dump at `.info`) was largely addressed in the Session 57 code review (Phase B/C fixes). Some verbose logging remains gated behind `.debug` level.

---

## Technical Notes

1. **External Backend**: `GHOSTTY_BACKEND_EXTERNAL` — terminal emulation without PTY (iOS can't fork/exec).
2. **IOSurfaceLayer sizing**: On iOS, Ghostty adds IOSurfaceLayer as sublayer (not replacing view's layer like macOS). Manual resize in `layoutSubviews`.
3. **addSublayer workaround**: Ghostty's Zig code calls `objc.sel("addSublayer")` without colon. Runtime method registered to handle this.
4. **Write callback**: External backend uses `ghostty_write_callback_fn` to notify Swift when terminal wants to send data.
