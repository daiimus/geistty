# Bodak Terminal Rendering Architecture Analysis

## Executive Summary

This document provides a comprehensive analysis of the terminal rendering pipeline in Bodak, focusing on the sizing synchronization issues between SSH, tmux, Ghostty, and iPadOS. The goal is to achieve a "Ghostty-native experience using SSH + tmux integration."

---

## Table of Contents

1. [Current Architecture](#current-architecture)
2. [The Sizing Problem](#the-sizing-problem)
3. [Research Findings](#research-findings)
4. [Root Cause Analysis](#root-cause-analysis)
5. [Proposed Solutions](#proposed-solutions)
6. [Implementation Roadmap](#implementation-roadmap)

---

## Current Architecture

### Data Flow Overview

```
┌────────────────────────────────────────────────────────────────────────────┐
│                           iPadOS Device                                    │
├────────────────────────────────────────────────────────────────────────────┤
│                                                                            │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                        SwiftUI Layer                                 │  │
│  │  ┌────────────────────┐  ┌──────────────────────────────────────┐   │  │
│  │  │ TmuxMultiPaneView  │  │ TmuxSplitTreeView (recursive splits) │   │  │
│  │  └─────────┬──────────┘  └────────────────┬─────────────────────┘   │  │
│  │            │                               │                         │  │
│  │            ▼                               ▼                         │  │
│  │  ┌──────────────────────────────────────────────────────────────┐   │  │
│  │  │           TmuxPaneSurfaceView (per-pane wrapper)             │   │  │
│  │  │  • Gets tmux-reported cols/rows                              │   │  │
│  │  │  • Calls setExactGridSize() to constrain Ghostty             │   │  │
│  │  └─────────────────────────────┬────────────────────────────────┘   │  │
│  └────────────────────────────────┼────────────────────────────────────┘  │
│                                   │                                        │
│  ┌────────────────────────────────▼────────────────────────────────────┐  │
│  │                         Ghostty Layer                               │  │
│  │  ┌────────────────────────────────────────────────────────────┐    │  │
│  │  │ SurfaceView (UIView + CAMetalLayer + UIKeyInput)           │    │  │
│  │  │  • Metal rendering of terminal grid                        │    │  │
│  │  │  • Processes VT100/xterm escape sequences                  │    │  │
│  │  │  • Maintains scrollback buffer (primary screen only)       │    │  │
│  │  │  • onResize callback for size changes                      │    │  │
│  │  └────────────────────────────────┬───────────────────────────┘    │  │
│  │                                   │                                 │  │
│  │  ┌────────────────────────────────▼───────────────────────────┐    │  │
│  │  │ External Backend (termio/External.zig)                     │    │  │
│  │  │  • No PTY (iOS doesn't support fork/exec/pty)              │    │  │
│  │  │  • write_callback → SSHSession                             │    │  │
│  │  │  • ghostty_surface_write_output() ← SSH data               │    │  │
│  │  └────────────────────────────────┬───────────────────────────┘    │  │
│  └───────────────────────────────────┼─────────────────────────────────┘  │
│                                      │                                     │
│  ┌───────────────────────────────────▼─────────────────────────────────┐  │
│  │                          SSH/tmux Layer                             │  │
│  │  ┌─────────────────────────────────────────────────────────────┐   │  │
│  │  │ SSHSession                                                  │   │  │
│  │  │  • Manages SSHConnection (libssh2)                          │   │  │
│  │  │  • Handles TmuxControlClient for -CC mode                   │   │  │
│  │  │  • Routes input through send-keys                           │   │  │
│  │  └─────────────────────────────────────────────────────────────┘   │  │
│  │                                                                     │  │
│  │  ┌─────────────────────────────────────────────────────────────┐   │  │
│  │  │ TmuxControlClient                                           │   │  │
│  │  │  • Parses %output, %begin/%end, notifications               │   │  │
│  │  │  • Decodes octal escapes in pane output                     │   │  │
│  │  │  • Tracks pane state (size, pause status)                   │   │  │
│  │  └─────────────────────────────────────────────────────────────┘   │  │
│  │                                                                     │  │
│  │  ┌─────────────────────────────────────────────────────────────┐   │  │
│  │  │ TmuxSessionManager                                          │   │  │
│  │  │  • Maintains currentSplitTree: TmuxSplitTree                │   │  │
│  │  │  • Maps pane IDs → Ghostty surfaces                         │   │  │
│  │  │  • Routes %output to correct surface                        │   │  │
│  │  └─────────────────────────────────────────────────────────────┘   │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                                                            │
└────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      │ TCP/SSH
                                      ▼
┌────────────────────────────────────────────────────────────────────────────┐
│                            Remote Server                                   │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  SSH Server (sshd)                                                   │  │
│  │    └── PTY (pseudo-terminal) ← SSH "window-change" request           │  │
│  │          └── tmux server (control mode: -CC)                         │  │
│  │                └── Panes → programs (shell, vim, cmatrix, etc.)      │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────────┘
```

### Size Information Flow (Current)

```
                    DIMENSION SOURCES
                    
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────────┐
│   iOS View      │     │   tmux Server    │     │  Ghostty Surface    │
│   Bounds        │     │   Pane Size      │     │  Grid Size          │
│   (pixels)      │     │   (cols×rows)    │     │  (cols×rows)        │
└────────┬────────┘     └────────┬─────────┘     └──────────┬──────────┘
         │                       │                          │
         │ layoutSubviews        │ %layout-change           │ onResize callback
         ▼                       │ list-panes -F            │
┌────────────────────────────────▼──────────────────────────▼──────────────┐
│                       TmuxSplitTree.PaneInfo                             │
│                       (paneId, cols, rows)                               │
│                                                                          │
│   PROBLEM: These three sources may disagree!                             │
│   - iOS view might be 1000×700 px                                        │
│   - tmux reports 80×24                                                   │
│   - Ghostty calculates 120×40 based on cell size                         │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## The Sizing Problem

### Symptoms Observed

1. **cmatrix/htop rendering issues** - Full-screen TUI apps don't fill the pane properly or render at wrong offsets
2. **Split pane sizing mismatch** - When splitting with Ctrl+D, new panes don't match expected dimensions
3. **Alternate screen mode issues** - tmux/vim/less display incorrectly when switching modes

### Why This Happens

Terminal sizing involves **four different coordinate spaces** that must stay synchronized:

| Coordinate Space | Owner | Unit | When Updated |
|------------------|-------|------|--------------|
| **View bounds** | iOS/SwiftUI | Pixels | Layout pass |
| **SSH PTY size** | Remote sshd | chars (cols×rows) | `window-change` request |
| **tmux pane size** | tmux server | chars | `resize-pane`, layout changes |
| **Ghostty grid** | Ghostty/Metal | chars | `ghostty_surface_set_size` |

The **fundamental problem**: These update at different times via different mechanisms, and there's no single authoritative source.

### Current Update Paths

```
Path A: iOS View Size Change
─────────────────────────────
1. iOS layoutSubviews fires
2. SurfaceView.updateSize() called
3. Ghostty recalculates grid from pixels
4. onResize(cols, rows) callback fires
5. SSHSession.resizePTY(cols, rows) called
6. SSH "window-change" sent to server
7. Server delivers SIGWINCH to tmux
8. tmux resizes its internal state
9. tmux sends %layout-change notification
10. Bodak updates TmuxSplitTree

Path B: tmux Split Created (Ctrl+D)
───────────────────────────────────
1. User presses Ctrl+D
2. Input routed to tmux via send-keys
3. tmux creates new pane
4. tmux sends %layout-change
5. Bodak parses, creates new surface
6. Surface.setExactGridSize() called
7. Ghostty resizes to tmux dimensions
8. ... but iOS container might be different size!

Path C: Window Resize on iPad
─────────────────────────────
1. iPad split-screen or rotation
2. SwiftUI re-layouts
3. Container bounds change
4. Each pane's layoutSubviews fires
5. TmuxPaneSurfaceView.updateUIView
6. ... race between Path A and current size
```

---

## Research Findings

### How Blink Shell Handles This

From analyzing [Blink Shell's source](https://github.com/blinksh/blink):

1. **Single Source of Truth**: hterm (web-based terminal) calculates grid size from font metrics and viewport
2. **Message Bridge**: Uses `WKWebView` JS bridge instead of SIGWINCH
3. **Deduplication**: `TermDevice.viewWinSizeChanged()` only propagates if size actually changed
4. **Layout Debouncing**: Timer-based debounce prevents resize storms
5. **Async Non-Blocking**: SSH resize uses Combine publishers on dedicated runloop

Key insight: **The terminal emulator owns the grid size calculation**, then propagates to SSH.

### How iTerm2/tmux Control Mode Works

From [tmux wiki](https://github.com/tmux/tmux/wiki/Control-Mode):

1. iTerm2 **owns the terminal rendering**, including scrollback
2. tmux `-CC` mode is essentially a **command protocol**, not a terminal
3. `%output` delivers raw data; iTerm2's terminal processes escape sequences
4. iTerm2 uses `refresh-client -C WxH` to tell tmux its size
5. tmux adjusts pane layouts to fit within client size

Key insight: **The client tells tmux its size, not the other way around**.

### SSH Protocol Semantics (RFC 4254)

The SSH `window-change` request:
- Is **fire-and-forget** (`want_reply = FALSE`)
- Server processes it **asynchronously**
- No guarantee of timing relative to data flow
- SIGWINCH delivery to remote process is non-deterministic

Key insight: **SSH resize is advisory, not synchronous**.

### Ghostty's Terminal.zig Behavior

From analyzing Ghostty source:

```zig
// Terminal.zig line 2631
// Alternate screen has 0 scrollback BY DESIGN
.max_scrollback = switch (key) {
    .primary => primary.pages.explicit_max_size,
    .alternate => 0,  // <-- This is correct!
},
```

The alternate screen (used by tmux, vim, less) has **zero scrollback** because:
1. Full-screen apps own the entire visible area
2. They redraw on resize (SIGWINCH)
3. Scrollback is meaningless for modal UI

Key insight: **Don't fight the alternate screen design; embrace it**.

---

## Root Cause Analysis

### The Core Issue

Bodak currently has **split-brain syndrome** for terminal dimensions:

1. **SwiftUI** thinks it owns layout (via GeometryReader and constraints)
2. **Ghostty** calculates grid from pixel size
3. **tmux** thinks its pane size is authoritative
4. **SSH PTY** is told a size that may be stale

### Specific Problems

#### Problem 1: setExactGridSize Fighting Auto-Layout

```swift
// TmuxMultiPaneView.swift
struct GhosttyPaneSurfaceContainerView: UIView {
    // Container fills its parent (SwiftUI-determined size)
    // But we call setExactGridSize to override Ghostty's calculation
    surface.setExactGridSize(cols: targetCols, rows: targetRows)
}
```

Issue: SwiftUI container is (e.g.) 500×300 pixels, but we tell Ghostty to render 80×24 chars. Ghostty resizes to 80×24 × cell_size ≈ 640×480 pixels. **The view bounds and Ghostty size don't match**.

#### Problem 2: SSH PTY Size Lags Behind

```swift
// SSHSession connects with initial size
try await connection?.openShell(term: Self.termType, cols: terminalCols, rows: terminalRows)
// terminalCols/Rows are hardcoded 80×24!
```

The SSH PTY is opened with 80×24 regardless of actual surface size. By the time `onResize` fires, there's a race.

#### Problem 3: tmux Layout vs SwiftUI Layout

tmux sends `%layout-change` with character dimensions:
```
%layout-change @0 ,160x40,0,0{80x40,0,0,0,79x40,81,0,1}
```

But SwiftUI's split view might divide space differently than tmux's integer-division algorithm.

#### Problem 4: Alternate Screen Redraw Timing

When cmatrix starts, it:
1. Switches to alternate screen (CSI ?1049h)
2. Queries terminal size (CSI 18t or checks LINES/COLUMNS)
3. Draws at whatever size it received

If the terminal hasn't finished resizing, cmatrix draws at the old size.

---

## Proposed Solutions

### Solution Architecture: "tmux as Source of Truth with Ghostty as Renderer"

The key insight from iTerm2: **The client tells tmux its capabilities, tmux adapts**.

```
┌────────────────────────────────────────────────────────────────────┐
│                    NEW ARCHITECTURE                                │
├────────────────────────────────────────────────────────────────────┤
│                                                                    │
│   iOS View Bounds                                                  │
│         │                                                          │
│         ▼                                                          │
│   ┌─────────────────────────────────────────────────────────────┐  │
│   │ SizeCalculator (NEW)                                        │  │
│   │  • Input: view bounds (pixels)                              │  │
│   │  • Input: font metrics (cell width/height)                  │  │
│   │  • Output: maximum grid size (cols×rows)                    │  │
│   │  • Handles insets, padding, dividers                        │  │
│   └─────────────────────────────┬───────────────────────────────┘  │
│                                 │                                  │
│                                 ▼                                  │
│   ┌─────────────────────────────────────────────────────────────┐  │
│   │ TmuxClientSize (NEW)                                        │  │
│   │  • refresh-client -C WxH (tell tmux our max size)           │  │
│   │  • tmux adjusts all pane layouts within this constraint     │  │
│   └─────────────────────────────┬───────────────────────────────┘  │
│                                 │                                  │
│                                 ▼                                  │
│   ┌─────────────────────────────────────────────────────────────┐  │
│   │ tmux Server                                                 │  │
│   │  • Owns pane dimensions                                     │  │
│   │  • %layout-change notifications                             │  │
│   │  • All splits/resizes go through tmux                       │  │
│   └─────────────────────────────┬───────────────────────────────┘  │
│                                 │                                  │
│                                 ▼                                  │
│   ┌─────────────────────────────────────────────────────────────┐  │
│   │ Ghostty Surfaces (one per pane)                             │  │
│   │  • Render at EXACTLY tmux-reported size                     │  │
│   │  • setExactGridSize(tmux.cols, tmux.rows)                   │  │
│   │  • No onResize callback needed (tmux owns size)             │  │
│   └─────────────────────────────────────────────────────────────┘  │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

### Detailed Implementation

#### Step 1: Calculate Client Size from iOS Bounds

```swift
// NEW: SizeCalculator.swift

struct TerminalSizeCalculator {
    /// Cell dimensions from Ghostty
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    
    /// Calculate the maximum grid that fits in the given bounds
    func maxGridSize(forBounds bounds: CGRect, padding: UIEdgeInsets = .zero) -> (cols: Int, rows: Int) {
        let availableWidth = bounds.width - padding.left - padding.right
        let availableHeight = bounds.height - padding.top - padding.bottom
        
        let cols = max(1, Int(floor(availableWidth / cellWidth)))
        let rows = max(1, Int(floor(availableHeight / cellHeight)))
        
        return (cols, rows)
    }
    
    /// For split view: account for divider thickness
    func maxGridSize(forBounds bounds: CGRect, dividerThickness: CGFloat, splitCount: Int) -> (cols: Int, rows: Int) {
        let totalDividers = CGFloat(max(0, splitCount - 1))
        // ...
    }
}
```

#### Step 2: Notify tmux of Client Size

```swift
// TmuxControlClient.swift - ADD

/// Tell tmux our client viewport size
/// tmux will constrain all pane layouts to fit within this
func setClientSize(cols: Int, rows: Int, send: @escaping (String) -> Void) {
    let command = "refresh-client -C \(cols)x\(rows)\n"
    send(command)
}
```

#### Step 3: Update SSH PTY on Connect

```swift
// SSHSession.swift - MODIFY connect()

func connect(...) async throws {
    // Calculate initial size from the surface that will be used
    let surface = // ... get the surface
    guard let cellSize = surface.surfaceSize else {
        // Fallback
        terminalCols = 80
        terminalRows = 24
    }
    
    // Use the surface's actual size
    let gridSize = surface.surfaceSize?.grid() ?? (80, 24)
    terminalCols = gridSize.cols
    terminalRows = gridSize.rows
    
    try await connection?.openShell(term: Self.termType, cols: terminalCols, rows: terminalRows)
}
```

#### Step 4: Respect tmux as Layout Authority

```swift
// TmuxSplitTreeView.swift - MODIFY

// DO NOT use GeometryReader to calculate sizes
// Instead, use tmux-reported sizes and let iOS adapt

struct TmuxSplitTreeView<PaneContent: View>: View {
    // Current: Uses GeometryReader to divide space
    // NEW: Use tmux dimensions directly, calculate pixel sizes from cell dimensions
    
    var body: some View {
        // Let tmux determine the character grid
        // We just render at the size tmux tells us
        renderNode(tree.root)
    }
    
    @ViewBuilder
    private func renderNode(_ node: TmuxSplitTree.Node) -> some View {
        switch node {
        case .leaf(let info):
            // Pane renders at EXACTLY info.cols × info.rows characters
            paneContent(info.paneId, info.cols, info.rows)
                .frame(
                    width: CGFloat(info.cols) * cellWidth,
                    height: CGFloat(info.rows) * cellHeight
                )
        case .split(let split):
            // ...
        }
    }
}
```

#### Step 5: Bidirectional Sync with Debouncing

```swift
// TmuxSessionManager.swift - ADD

private var resizeDebouncer: Timer?

/// Called when iOS view bounds change
func viewBoundsDidChange(to bounds: CGRect) {
    // Debounce rapid changes (rotation, split-screen adjustment)
    resizeDebouncer?.invalidate()
    resizeDebouncer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
        self?.performDebouncedResize(bounds: bounds)
    }
}

private func performDebouncedResize(bounds: CGRect) {
    // 1. Calculate max grid from bounds + cell size
    let maxGrid = sizeCalculator.maxGridSize(forBounds: bounds)
    
    // 2. Tell tmux our new client size
    controlClient.setClientSize(cols: maxGrid.cols, rows: maxGrid.rows) { [weak self] cmd in
        self?.sshSession?.connection?.write(cmd)
    }
    
    // 3. tmux will respond with %layout-change
    // 4. We'll update surfaces when that arrives
}
```

#### Step 6: Handle %layout-change Properly

```swift
// TmuxControlClient.swift - ENHANCE parsing

func handleLayoutChange(_ line: String) {
    // Parse layout string to get exact pane dimensions
    let layout = parseLayoutString(line)  // Returns [(paneId, x, y, cols, rows)]
    
    for pane in layout {
        // Update tree with exact dimensions from tmux
        currentSplitTree.updatePaneDimensions(
            paneId: pane.id,
            cols: pane.cols,
            rows: pane.rows
        )
        
        // Update corresponding Ghostty surface
        if let surface = getSurface(forPaneId: pane.id) {
            surface.setExactGridSize(cols: pane.cols, rows: pane.rows)
        }
    }
}
```

### Summary of Key Changes

| Component | Current | Proposed |
|-----------|---------|----------|
| Size authority | Split between iOS/Ghostty/tmux | tmux is single authority |
| SSH PTY init | Hardcoded 80×24 | Calculated from surface |
| Resize trigger | iOS layout → SSH → tmux | iOS layout → tmux client size → tmux → surfaces |
| Surface sizing | setExactGridSize sometimes | Always setExactGridSize from tmux |
| Debouncing | None | 100ms debounce on resize |

---

## Implementation Roadmap

### Phase 1: Fix Immediate Issues (1-2 days)

1. **Remove hardcoded 80×24** in SSHSession
2. **Add resize debouncing** to prevent rapid-fire changes
3. **Implement `refresh-client -C`** to set tmux client size

### Phase 2: Refactor Size Flow (2-3 days)

1. **Create SizeCalculator** utility class
2. **Modify TmuxSplitTreeView** to use pixel-based frames from tmux cols×rows
3. **Update TmuxSessionManager** to handle bidirectional sync

### Phase 3: Alternate Screen Handling (1-2 days)

1. **Detect mode switches** via Ghostty (CSI ?1049h/l)
2. **Ensure full redraw** after resize during alternate screen
3. **Test with cmatrix, vim, tmux-within-tmux**

### Phase 4: Edge Cases & Polish (1-2 days)

1. **iPad split-screen** transitions
2. **Keyboard show/hide** (affects available height)
3. **Rotation** handling
4. **Multiple windows** (Stage Manager)

---

## Appendix: Mitchell Hashimoto's Design Principles

Based on Ghostty's architecture and Mitchell's engineering blog posts, key principles to follow:

1. **Simple mental model**: One component owns each piece of state
2. **Explicit over implicit**: No "magic" size calculations spread across files
3. **Performance-conscious**: Avoid redundant redraws; batch updates
4. **Correctness first**: Get it right, then optimize
5. **Unix philosophy**: Terminal emulator does terminal things; tmux does multiplexing

The proposed architecture aligns with these by making tmux the explicit owner of pane dimensions, with Ghostty as a faithful renderer of those dimensions.

---

## Appendix: Code Audit - What Exists vs What's Missing

### ✅ Already Implemented

1. **`TmuxControlClient.resize(cols:rows:via:)`** - Sends `refresh-client -C`
2. **`SSHSession.resize(cols:rows:)`** - Calls both SSH PTY resize AND tmux resize
3. **`TmuxSessionManager.resize(cols:rows:)`** - Forwards to control client
4. **Debounced resize in TmuxSessionManager** - 50ms debounce
5. **`setExactGridSize(cols:rows:)`** - Forces Ghostty to exact character grid
6. **PaneInfo struct** - Encapsulates (paneId, cols, rows) together

### ❌ Missing or Broken

1. **Initial PTY size is hardcoded**:
   ```swift
   // SSHSession.swift - always 80x24 regardless of surface!
   private var terminalCols: Int = 80
   private var terminalRows: Int = 24
   ```

2. **Layout change doesn't update all surfaces**:
   The `%layout-change` parsing updates the tree, but doesn't call `setExactGridSize` on each surface.

3. **Cell size not available at connect time**:
   The Ghostty surface may not have cell dimensions computed when SSH connects.

4. **No bidirectional sync from tmux → SwiftUI**:
   When tmux resizes a pane (user drag or select-layout), SwiftUI constraints don't update.

5. **Split pane creation race**:
   When Ctrl+D creates a split, the new surface is created before tmux reports final dimensions.

### 🔧 Quick Fixes to Try

**Fix 1: Use actual surface size for SSH connect**
```swift
// In SSHSession connect methods, add:
func connect(...) async throws {
    // Get initial size from the first surface that will be created
    // This is a chicken-egg problem - solve by:
    // 1. Using a reasonable default (120x40 for iPad)
    // 2. Immediately resizing once surface is ready
    terminalCols = 120  // Better default for iPad
    terminalRows = 40
    // ... rest of connect
}
```

**Fix 2: Call setExactGridSize when %layout-change received**
```swift
// In TmuxSessionManager.handleLayoutChange:
for pane in parsedLayout {
    if let surface = getSurface(forNumericId: pane.id) {
        surface.setExactGridSize(cols: pane.cols, rows: pane.rows)
    }
    // Also update the tree
    currentSplitTree.updatePaneDimensions(paneId: pane.id, cols: pane.cols, rows: pane.rows)
}
```

**Fix 3: Trigger resize after surface creation**
```swift
// When a new surface is created for a pane, immediately tell it the size:
func createSurface(forPaneId paneId: String, cols: Int, rows: Int) -> Ghostty.SurfaceView {
    let surface = Ghostty.SurfaceView(...)
    // Wait for cell size to be computed, then set exact grid
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        surface.setExactGridSize(cols: cols, rows: rows)
    }
    return surface
}
```

---

## References

- [tmux Control Mode Wiki](https://github.com/tmux/tmux/wiki/Control-Mode)
- [XTerm Control Sequences](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html)
- [RFC 4254 - SSH Connection Protocol](https://tools.ietf.org/html/rfc4254#section-6.7)
- [Blink Shell Source](https://github.com/blinksh/blink)
- [Ghostty Source - Terminal.zig](../ghostty/src/terminal/Terminal.zig)
- [Ghostty Source - External.zig](../ghostty/src/termio/External.zig)
