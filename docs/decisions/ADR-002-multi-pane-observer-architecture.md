# ADR-002: Multi-Pane — Primary + Observer Surface Architecture

**Status:** Accepted  
**Date:** 2026-02-19  
**Context:** Sessions 68-106 (38-session implementation epic)

## Problem

tmux control mode can have multiple panes, but Ghostty's architecture ties one Terminal instance to one Surface. We need to render N panes simultaneously on screen, each with independent content, while Ghostty's tmux viewer internally manages per-pane Terminal instances.

## Decision

Use a **primary + observer** surface model:

1. **Primary surface** — The original SurfaceView created during SSH connection. It becomes the "control surface" for tmux queries and input routing. It's adopted (not recreated) when tmux control mode activates.

2. **Observer surfaces** — Factory-created SurfaceView instances for additional panes. Each observer surface gets its own Metal renderer but shares the primary's Ghostty app instance. Marked with `isMultiPaneObserver = true`.

3. **Two `setActiveTmuxPane` variants** in the C API:
   - `setActiveTmuxPane(id)` — Full swap: changes renderer + input routing. Used for **window switches** (different set of panes).
   - `setActiveTmuxPaneInputOnly(id)` — Input routing only, no renderer swap. Used for **pane focus** within the current window.

### Key Rules

| Property | Primary | Observer |
|----------|---------|----------|
| `canBecomeFirstResponder` | `true` | `false` |
| First responder | Always | Never |
| Gestures | Full suite | Tap, pinch-zoom, two-finger-double-tap only |
| Font size | Independent | Independent (per-pane zoom) |
| Created by | SSH connection flow | Surface factory during `handleTmuxStateChanged` |
| Destroyed on | Session end | Window switch, background, session end |

### Focus Model

Focus is minimal: `selectPane()` calls `setActiveTmuxPaneInputOnly()`. No guards, no hooks, no focus-tracking booleans. The observer surface's tap gesture triggers `onTapCallback`, which the TmuxSessionManager uses to call `selectPane()`.

### Observer Registration

The primary surface is registered as an observer of itself so that `fixupObservers()` can correct its renderer after `syncLayouts()` temporarily re-points it at `active_pane_id`. This was a critical fix — without it, the primary would render the wrong pane after layout sync.

## Consequences

- Each pane renders independently via Metal — no compositor needed
- Per-pane font size works naturally (each Surface has its own `font_size`, `font_grid_key`, `font_metrics`)
- Focus is clean: one boolean (`isMultiPaneObserver`) controls `canBecomeFirstResponder`
- Observer surfaces are lightweight — create/destroy on window switches is fast
- The 38-session implementation resolved multiple subtle issues: renderer bleed, echo, wakeup (iOS has no display link), and sizing

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|-------------|
| Single surface, compositor | Complex rendering, no per-pane zoom, doesn't leverage Ghostty's per-pane Terminal instances |
| Multiple Ghostty apps | Heavy, each app has its own event loop and config |
| SwiftUI-level compositing | Too far from the Metal layer, performance concerns |
| Shared renderer, viewport clipping | Ghostty's renderer assumes one viewport per surface |
