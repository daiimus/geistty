# ADR-001: Background Flow — C1 ST Reset Instead of detach-client

**Status:** Accepted  
**Date:** 2026-02-19  
**Context:** Session 132 (implemented), Session 133 (verified on device)

## Problem

When iOS backgrounds Geistty, the SSH TCP connection dies (iOS suspends the process). When the app returns to foreground, Ghostty's VT parser is stuck in DCS passthrough state from the tmux control mode session (`DCS 1000p`). The old tmux session is dead server-side, but Ghostty doesn't know that.

Previous approaches tried:
1. **`detach-client`** — Sent `detach-client` command to tmux before backgrounding. Failed because iOS gives ~5 seconds of background time, and the SSH connection may already be dead by the time we try to send it. Also caused race conditions with the viewer teardown.
2. **Reconnect without parser reset** — Reconnected SSH and sent fresh `tmux -CC attach`. Failed because the parser was still in DCS passthrough state, so the new DCS 1000p sequence was interpreted as nested DCS (which VT100 doesn't support).

## Decision

Send **C1 ST (0x9C)** directly to the Ghostty surface via `feedData()` when the app returns to foreground. This is a local-only operation — no network I/O required.

### How it works

1. **App backgrounds** → `beginBackgroundTask`, save `backgroundState` (was control mode active? what session?)
2. **iOS kills TCP** → `connectionDidClose` fires, but `backgroundState != nil` suppresses delegate notification
3. **App foregrounds** → `appDidBecomeActive()`:
   - Feed `0x9C` (C1 ST) to the Ghostty surface
   - VT parser transitions: `dcs_passthrough → ground` (via the "anywhere" transition for 0x9C)
   - Ghostty calls `dcs_unhook`, which triggers `.tmux = .exit` → viewer teardown → `TMUX_EXIT` action
4. **TMUX_EXIT handler** sees `isDetachingForBackground == true` → calls `prepareForReattach()` (lightweight reset preserving primary surface) instead of `controlModeExited()` (nuclear teardown)
5. **`attemptReconnect()`** opens fresh SSH connection → sends `tmux -CC attach` → Ghostty detects new DCS 1000p → viewer reinitializes → panes restore via `capture-pane`

### Why C1 ST

- **No network required** — pure parser reset, works even when TCP is dead
- **Follows the VT100 spec** — ST (String Terminator) is the correct way to end a DCS sequence
- **Ghostty handles it natively** — the "anywhere" transitions in the VT parser already handle 0x9C
- **No fork changes needed** — uses existing `feedData()` API (Swift-only solution)

## Consequences

- Background/foreground cycle is reliable — tested with 3-pane tmux session
- Primary surface is preserved across reconnect (no flash/recreate)
- Observer surfaces are destroyed and recreated fresh (they're lightweight)
- The approach is parser-correct: we're not hacking around Ghostty, we're using VT100 semantics as designed

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|-------------|
| `detach-client` before background | Unreliable — TCP may already be dead |
| ESC + `\` (C0 ST) | Only works in 7-bit mode; C1 ST is universal |
| Reinitialize Ghostty surface | Expensive, loses scrollback, observer setup is complex |
| Parser state surgery in Zig | Fork divergence, fragile, violates Directive #4 |
