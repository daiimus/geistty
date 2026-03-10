# ADR-003: Fork Philosophy — Minimize Divergence, Keep It in Swift

**Status:** Accepted  
**Date:** 2026-02-19  
**Context:** Ongoing project principle

## Problem

Geistty depends on a custom fork of Ghostty (`daiimus/ghostty`, branch `ios-external-backend`). Ghostty is actively developed with a constant stream of upstream commits. Every change we make to the fork increases the maintenance burden when rebasing on upstream.

## Decision

**Minimize fork divergence. Before adding code to the Zig fork, always ask: "Can this live in Swift instead?"**

### What belongs in the fork

Only changes that *cannot* be implemented from the Swift side:

1. **External termio backend** (`src/termio/External.zig`) — iOS can't fork/exec, so we need a terminal emulation backend that accepts data via API rather than a PTY
2. **C API extensions** — Functions that expose Ghostty internals needed by the iOS app (tmux pane queries, config loading, etc.)
3. **Bug fixes** that affect iOS specifically (e.g., the `resetAllObservers` UAF fix in Session 119)

### What belongs in Swift

Everything else:

- Background/reconnect flow (ADR-001) — pure Swift, uses existing `feedData()` API
- Multi-pane UI layout and focus management — Swift/SwiftUI
- Config file parsing and sync — Swift reads `ghostty.conf`, calls existing C API
- SSH connection management — SwiftNIO-SSH, pure Swift
- All UI: connection list, settings, command palette, keyboard accessory, etc.

### Rebasing protocol

1. Regularly rebase `ios-external-backend` on upstream `main`
2. Each rebase: rebuild GhosttyKit xcframework, run CI tests
3. If upstream changes conflict with our patches, adapt our patches (not the other way around)
4. Track fork-specific issues with the `zig-fork` label in GitHub Issues

## Consequences

- Fork stays small and rebasing is manageable
- Most development happens in Swift — faster iteration, better tooling
- When Ghostty adds features we want, we get them for free on rebase
- The C API surface area is the contract — as long as we keep it stable, Swift code is independent

## Current Fork Footprint

As of the March 2026 rebase (94 commits onto Ghostty 1.3.0), the fork adds:
- `src/termio/External.zig` — External backend (terminal emulation without PTY)
- `src/termio/backend.zig` — `external` variant registered in `Kind`, `Config`, `Backend`, `ThreadData` enums/unions
- `src/termio.zig` — `pub const External` export
- `src/config/CApi.zig` — Config loading extensions (`load_file`, `load_string`)
- tmux C API: 8 action types, pane/window query functions, active pane switching
- `TMUX_READY` action (signals capture-pane completion)
- Debug logging additions (planned for cleanup — see Issue #8)

Total: ~15 files modified across the fork.
