# Development Roadmap

## Overview

Geistty is a native iOS/iPadOS SSH terminal powered by Ghostty's terminal engine.

**Current state**: v0.3 — SSH + tmux control mode working end-to-end, multi-pane fully functional, background/reconnect reliable.

See [ARCHITECTURE.md](ARCHITECTURE.md) for technical details.

**Active bugs and features are tracked as [GitHub Issues](https://github.com/daiimus/geistty/issues).**

```bash
# View active work
gh issue list --repo daiimus/geistty --milestone v0.3-stable
gh issue list --repo daiimus/geistty --milestone v0.4-polish
```

---

## Milestones

| Milestone | Focus | Status |
|-----------|-------|--------|
| **v0.3-stable** | No crashes, clean lifecycle, known regressions fixed | In Progress |
| **v0.4-polish** | iOS UX polish, aesthetic features, Ghostty feature alignment | Planned |
| **v0.5-testflight** | TestFlight-ready, onboarding, accessibility, App Store assets | Planned |

---

## Architecture Decisions

Key architectural decisions are documented in `docs/decisions/`:

| ADR | Title |
|-----|-------|
| [ADR-001](docs/decisions/ADR-001-background-c1-st-reset.md) | Background flow: C1 ST reset instead of detach-client |
| [ADR-002](docs/decisions/ADR-002-multi-pane-observer-architecture.md) | Multi-pane: primary + observer surface architecture |
| [ADR-003](docs/decisions/ADR-003-fork-philosophy.md) | Fork philosophy: minimize divergence, keep it in Swift |
| [ADR-004](docs/decisions/ADR-004-config-ghostty-conf.md) | Config: ghostty.conf as source of truth, not UserDefaults |
| [ADR-005](docs/decisions/ADR-005-lazy-pull-tmux-architecture.md) | Lazy/pull tmux state: viewer owns state, Swift queries via C API |

---

## Code Cleanup Backlog

| Task | Priority | Notes |
|------|----------|-------|
| Split `TmuxSessionManager.swift` (~2062 lines) | Medium | Extract user actions/commands, surface management, split resize helpers |
| Migrate callback bridges to async/await in TmuxSessionManager | Medium | 6 closure-based callbacks from pre-Ghostty architecture |
| Extract magic numbers to constants | Low | Timeouts, marker strings |
| Review and standardize naming conventions | Low | |
| Add missing documentation comments | Low | |

### Dead Code Audit (Feb 2026) — COMPLETED

~900 lines removed across Sessions 7-10. All archived in `docs/archive/DEAD_CODE_FEB_2026.swift`.

**4 ShortcutAction enum cases** (`.newWindow`, `.closeSurface`, `.closeTab`, `.disconnect`) are defined but not yet dispatched. Kept intentionally for future use.

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
| tmux 3 | Multiple windows, Ghostty-style keybindings | Dec 2024 |
| tmux 3.5 | Disconnection handling, auto-reconnect, credential retention | Dec 2025 |
| Architecture | TmuxGateway actor migration, Swift-native SSH | Dec 2024-2025 |
| Cleanup | Dead code removal, debug code cleanup | Dec 2025-Feb 2026 |
| Docs | ARCHITECTURE.md and README.md rewrite | Feb 2026 |
| Infra | Rebase Ghostty fork on upstream (1.3.0), rebuild GhosttyKit | Feb-Mar 2026 |
| Refactor | Theme system, config introspection, font mapping, ControlModeState enum | Feb 2026 |
| Feature | Command palette, Jump to Prompt, per-pane pinch-to-zoom | Feb 2026 |
| Fix | tmux DCS passthrough freeze, 6-agent code review (63 findings) | Feb 2026 |
| Epic | Multi-pane terminal binding (Sessions 68-106) | Feb 2026 |
| Fix | Background/reconnect rewrite — C1 ST reset flow | Feb 2026 |
| Infra | CI keychain for device builds, `./ci.sh deploy` | Feb 2026 |
| Testing | Test suite: 715 tests across 23 files | Feb 2026 |

---

## Phase Roadmap

### Phase 5: iOS UX Polish (IN PROGRESS)

See [GitHub Issues with `ux` label](https://github.com/daiimus/geistty/labels/ux) for active items.

Completed features: hardware keyboard, keyboard accessory bar, Ghostty keyboard API, copy/paste, resize, scrollback, tmux multi-pane, per-pane zoom, saved connections, SSH key auth, credentials, fonts, themes, text rendering, iPad multitasking, gestures, shortcuts, bottom screen real estate.

### Phase 6: Session Management & Navigation (PLANNED)

- New Connection / Quick Connect from terminal view
- Session switching between active connections
- UISceneDelegate for multiple windows (iPadOS)
- Visual connection status indicators

### Phase 7: Configuration System (IN PROGRESS)

Completed: ghostty.conf as source of truth, reload, in-app editor, native themes, config introspection, font mapping.

Remaining: syntax validation, config import/export, theme import.

### Phase 8: Advanced Features (PLANNED)

- SFTP/Remote Files (archived — see `FILE_PROVIDER_LEARNINGS.md`)
- Secure Enclave key storage
- Clickable URLs/file paths, session recording, clipboard history
- Stretch: Mosh, snippets, port forwarding

### Phase 9: Release Preparation (PLANNED)

- Apple Developer Program enrollment
- TestFlight beta (see `TESTFLIGHT.md`)
- App Store assets (see `APP_STORE.md`)
- Onboarding, accessibility, localization, performance profiling

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
