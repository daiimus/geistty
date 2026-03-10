# ADR-005: Lazy/Pull Architecture for tmux Control Mode

**Status:** Accepted  
**Date:** 2026-03-09  
**Context:** Ghostty rebase onto 1.3.0, tmux C API design

## Problem

tmux control mode (`tmux -CC`, DCS 1000p) generates a stream of protocol events: `%output`, `%layout-change`, `%session-changed`, `%window-pane-changed`, etc. The app runtime (Swift) needs to reflect this state in the UI. Two architectural patterns exist for bridging the Zig terminal core and the Swift apprt:

1. **Eager/push** — Parse protocol events and immediately push full event data to the apprt. The apprt reacts to each event by creating/mutating UI objects. This is what iTerm2 does.
2. **Lazy/pull** — Parse protocol events, update internal state in the terminal core, fire a lightweight "state changed" notification, and let the apprt query for details when it's ready.

## Decision

**Use the lazy/pull pattern.** Ghostty's `viewer.zig` owns all tmux state internally. The Swift side receives minimal notifications and queries the C API for details.

### How it works

1. `control.zig` parses tmux protocol bytes into `Notification` structs
2. `stream_handler.zig` feeds notifications to `viewer.zig` via `viewer.next()`
3. The viewer updates its internal state: `windows`, `panes` (each with a full `Terminal` instance), `window_metadata`
4. The viewer returns lightweight `Action`s (`.exit`, `.command`, `.windows`)
5. `stream_handler` converts `.windows` into a `tmux_state_changed` surface message containing only counts and pane IDs — not full state
6. The Swift apprt receives the notification and queries for details:

```
tmux protocol bytes
  │
  ▼
control.Parser → Notification
  │
  ▼
viewer.next() → updates internal state, returns Action[]
  │
  ├─ .windows → Surface.tmux_state_changed{window_count, pane_count, pane_ids}
  │                                        (summary only — no layout, no names)
  │
  ▼
Swift receives "state changed"
  │
  ├─ ghostty_surface_tmux_window_count()
  ├─ ghostty_surface_tmux_window_info(index, ...)
  ├─ ghostty_surface_tmux_window_layout(index, ...)
  ├─ ghostty_surface_tmux_window_focused_pane_id(index)
  └─ ghostty_surface_tmux_active_window_id()
       │
       └─ reads viewer's internal state (mutex-protected)
```

### Hybrid: some eager signals

A handful of events ARE pushed eagerly because the Swift side needs to react immediately to a specific event, not just "something changed":

| Signal | Why eager |
|--------|-----------|
| `tmux_active_window_changed` | UI must switch window tabs immediately |
| `tmux_focused_pane_changed` | Input routing must update |
| `tmux_session_renamed` | Status bar text update |
| `tmux_subscription_changed` | Status bar variable update |
| `tmux_command_response` | Response to a user-initiated command |
| `tmux_ready` | One-shot signal that viewer startup (including capture-pane) is complete |

### Pane output: fully internal

`%output` data never crosses the Zig/Swift boundary. The viewer decodes it and writes directly into each pane's `Terminal` instance. The apprt renders by pointing a Metal renderer at the pane's terminal. This is the same pattern Ghostty uses for regular (non-tmux) terminal rendering.

## Why this is native to Ghostty

The lazy/pull pattern matches how Ghostty handles everything else:

- **Rendering:** The core owns `Terminal` instances, the renderer reads from them. The apprt doesn't maintain shadow state.
- **Config:** The core owns `Config`. The apprt queries via `ghostty_config_get()`.
- **Input:** The apprt translates platform events and hands them to the core. The core decides what to do.
- **Actions:** Surface messages are deliberately minimal — constrained to a 24-byte `CValue` union (`action.zig:485`). Rich data doesn't fit; query functions do.

The viewer is just another piece of state the core owns, queried by the apprt when notified.

## Why eager/push wouldn't work well here

1. **24-byte CValue constraint** — Window names, layout trees, pane metadata can't fit in a 24-byte action payload. Pointers to heap-allocated structures would create lifetime and ownership issues across the Zig/C/Swift boundary.

2. **Dual state** — The apprt would need its own representation of windows, panes, and layouts, populated by pushed events. Two sources of truth that can drift.

3. **Event ordering** — Rapid tmux notifications (layout-change + window-add + pane-output in one batch) would require the apprt to process them in order and handle intermediate states. With lazy/pull, the viewer absorbs the entire batch atomically, and the apprt queries the final state.

4. **Protocol awareness in the apprt** — The Swift layer would need to understand tmux protocol semantics. Currently it doesn't — it just knows "state changed, re-query."

## Prior art

The landscape for tmux control mode clients is sparse:

| Terminal | tmux Control Mode | Architecture |
|---|---|---|
| **iTerm2** | Yes (reference impl) | Eager/push. `TmuxGateway` parses protocol, immediately creates real UI objects (tabs, sessions, panes). No query API — the UI objects ARE the state. |
| **Ghostty** | In progress (upstream) | Lazy/pull via `viewer.zig`. Not yet shipped. |
| **Geistty** | Yes (via Ghostty fork) | First external consumer of Ghostty's lazy/pull viewer via C API. |
| **kitty** | No | Own remote control protocol, no tmux -CC support. |
| **Alacritty** | No | Deliberately minimal, no multiplexer integration. |
| **WezTerm** | No | Own multiplexer, no tmux -CC consumption. |

The lazy/pull pattern is unusual compared to iTerm2, but iTerm2 is a monolithic Objective-C app where the protocol parser and UI live in the same process with shared memory. Ghostty's multi-apprt architecture (macOS, GTK, iOS from one Zig core) makes eager push impractical.

## Tradeoffs

### What we gain

- **Decoupling** — Viewer knows nothing about the apprt. Works for macOS, GTK, iOS identically.
- **Thread safety** — State is behind `renderer_state.mutex`. The apprt reads at its own pace.
- **Batching** — Multiple notifications are absorbed atomically. No intermediate UI flicker.
- **Small action surface** — No complex payload types in the action system.
- **Upstream alignment** — When Ghostty ships their macOS tmux UI, it will use the same viewer and the same pull pattern. Our fork stays compatible.

### What it costs

- **Lost granularity** — The apprt doesn't know *what* changed, only *that* something changed. `TmuxSessionManager.handleTmuxStateChanged()` re-queries everything and diffs against previous state.
- **Growing C API surface** — Every queryable property needs a dedicated C function. As tmux features grow, so does the API.
- **Harder debugging** — Push-based models leave a clear event trail. Pull-based requires inspecting state snapshots.

## Consequences

- `TmuxSessionManager` is structured as a "react to notification, query for current state, diff against previous" state machine
- Adding new tmux features means: (1) viewer stores the state, (2) add a C API query function, (3) Swift queries it on notification
- The 6 eager signals exist as escape hatches for cases where "something changed" isn't specific enough
- This architecture is a key reason why the fork stays small — the viewer does the heavy lifting, the Swift side is a thin query + UI layer
