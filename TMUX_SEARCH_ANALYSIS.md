# Terminal Alternate Screen Architecture & tmux Search Analysis

## Executive Summary

The "alternate screen" is a **terminal feature**, not a tmux feature. It exists because full-screen applications (vim, less, tmux, htop) need a way to display their UI without destroying the user's command history and scrollback.

**Key insight:** tmux acts as a "terminal within a terminal" - it implements its own scrollback on top of the alternate screen buffer. This is why Ghostty can't search tmux's history: Ghostty's scrollback and tmux's scrollback are completely separate data structures.

---

## Part 1: Why Alternate Screen Exists

### Historical Problem (Pre-1980s)

In early terminals, there was only one screen buffer. When you ran `vi` or `less`:

1. Your shell output/history was **destroyed** to make room for the editor
2. When you quit, you saw garbage (the editor's last state) mixed with your shell
3. Your scrollback history was **gone forever**

This was terrible UX.

### The Solution: Dual Screen Buffers

DEC introduced the alternate screen buffer concept in the VT100 series:

```
┌─────────────────────────────────────────────────────┐
│  PRIMARY SCREEN                                     │
│  ─────────────────                                  │
│  • Normal shell operation                           │
│  • Has scrollback (configurable, default 10000)     │
│  • Your command history lives here                  │
│  • Preserved when you enter vim/less/tmux           │
└─────────────────────────────────────────────────────┘
                        ↕ ESC[?1049h/l
┌─────────────────────────────────────────────────────┐
│  ALTERNATE SCREEN                                   │
│  ────────────────                                   │
│  • Full-screen applications                         │
│  • NO scrollback (by design)                        │
│  • Completely independent from primary              │
│  • Cleared on entry, discarded on exit              │
└─────────────────────────────────────────────────────┘
```

### Escape Sequences

| Mode | Switch On | Switch Off | Behavior |
|------|-----------|------------|----------|
| **47** | `ESC[?47h` | `ESC[?47l` | Legacy - just switch buffers |
| **1047** | `ESC[?1047h` | `ESC[?1047l` | Clear alternate on return to primary |
| **1048** | `ESC[?1048h` | `ESC[?1048l` | Save/restore cursor only |
| **1049** | `ESC[?1049h` | `ESC[?1049l` | **Standard** - save cursor, switch, clear |

**Mode 1049** is what modern applications use. When tmux starts, it sends:
```
ESC[?1049h  (save cursor, switch to alternate, clear)
```

When you exit tmux cleanly, it sends:
```
ESC[?1049l  (switch to primary, restore cursor)
```

---

## Part 2: Why Alternate Screen Has No Scrollback

The alternate screen **intentionally** has no scrollback because:

1. **Full-screen apps manage their own display** - vim, tmux, less handle scrolling internally
2. **Terminal scrollback would fight with app scrollback** - confusing UI
3. **Memory efficiency** - no need to store history for temporary full-screen state
4. **Clean exit** - when you quit vim, you want your shell back, not vim's display history

From Ghostty's `Terminal.zig`:
```zig
.max_scrollback = switch (key) {
    .primary => primary.pages.explicit_max_size,  // Configurable (default 10000)
    .alternate => 0,                               // Always 0
},
```

This is **correct behavior** - not a bug.

---

## Part 3: How tmux Actually Works

### tmux as Terminal-in-a-Terminal

```
┌───────────────────────────────────────────────────────────────────┐
│ Ghostty (Terminal Emulator)                                       │
│ ┌───────────────────────────────────────────────────────────────┐ │
│ │ PRIMARY SCREEN (10000 lines scrollback)                       │ │
│ │ $ ls                                                          │ │
│ │ $ cd project                                                  │ │
│ │ $ tmux  ←── This command switches to ALTERNATE screen         │ │
│ └───────────────────────────────────────────────────────────────┘ │
│                                                                   │
│ ┌───────────────────────────────────────────────────────────────┐ │
│ │ ALTERNATE SCREEN (0 lines scrollback)                         │ │
│ │ ┌───────────────────────────────────────────────────────────┐ │ │
│ │ │ TMUX (Terminal Multiplexer with its OWN scrollback)       │ │ │
│ │ │ ┌───────────────────────────────────────────────────────┐ │ │ │
│ │ │ │ tmux pane (2000 lines internal scrollback)            │ │ │ │
│ │ │ │ $ git log                                             │ │ │ │
│ │ │ │ commit abc123...                                      │ │ │ │
│ │ │ │ commit def456...   ← This is in TMUX's buffer         │ │ │ │
│ │ │ │                      NOT in Ghostty's buffer          │ │ │ │
│ │ │ └───────────────────────────────────────────────────────┘ │ │ │
│ │ └───────────────────────────────────────────────────────────┘ │ │
│ └───────────────────────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────────────────────┘
```

### Two Separate Scrollback Systems

| System | Storage | Access | Search |
|--------|---------|--------|--------|
| **Ghostty Primary** | Ghostty's memory | Scroll gesture, search bar | Works! |
| **Ghostty Alternate** | Ghostty's memory (0 lines) | N/A | Only visible |
| **tmux Internal** | tmux server process | `Ctrl+B [` copy mode | `tmux capture-pane` |

**The data Ghostty sees** when you're in tmux is just the **current display frame** that tmux renders. All history is in tmux's internal buffer.

---

## Part 4: Solutions for Bodak

### Option A: Use tmux's Buffer (Recommended)

Since tmux maintains its own scrollback, we should query it:

```bash
tmux capture-pane -p -S -   # Get entire scrollback from tmux
```

**Implementation:**
1. Detect alternate screen via `screen_type` in SearchResult
2. Check if connection has `useTmux = true`
3. When searching: send `tmux capture-pane -p -S -` over SSH
4. Search the returned text locally in Swift
5. Navigate using tmux's copy-mode

**Pros:**
- Searches actual content the user expects
- Uses platform-native mechanism (tmux's own feature)
- Works with tmux's scroll position

**Cons:**
- Output parsing needed
- Navigation more complex

### Option B: Disable tmux's Alternate Screen

tmux has an option to NOT use alternate screen:

```bash
tmux set -g alternate-screen off
```

When disabled:
- tmux output goes to Ghostty's primary screen
- Ghostty accumulates scrollback
- Search "just works"

**Pros:**
- Simplest implementation
- Ghostty search works directly

**Cons:**
- Visual glitches when switching tmux windows
- Less common configuration
- Mixes tmux's UI with shell history

### Option C: Hybrid Approach (Best UX)

1. **Default:** When `isAlternateScreen && useTmux`:
   - Search bar shows "tmux" mode indicator
   - Automatically use `tmux capture-pane` for search
   - Navigate results in tmux copy mode

2. **Connection Option:** "Use terminal scrollback (disable tmux alternate screen)"
   - Inject `tmux set -g alternate-screen off`
   - Ghostty search works normally
   - For users who prefer this behavior

---

## Part 5: Split Screen Considerations

Since you mentioned Ghostty's split-screen and iPadOS Stage Manager:

### Current State
- Each Ghostty Surface has its own ScreenSet (primary + alternate)
- Splits create new Surfaces, each with independent screens
- This architecture already supports multiple simultaneous screens

### iPadOS Integration Points

1. **Stage Manager windows** = different Ghostty App instances (separate processes)
2. **Split view within Bodak** = multiple Surfaces in one view hierarchy
3. **tmux splits** = single Surface, tmux manages layout internally

### Search Implications for Splits

```
┌─────────────────┬─────────────────┐
│ Surface 1       │ Surface 2       │
│ (tmux session)  │ (plain shell)   │
│ ALT SCREEN      │ PRIMARY SCREEN  │
│                 │                 │
│ Search: tmux    │ Search: Ghostty │
│ capture-pane    │ scrollback      │
└─────────────────┴─────────────────┘
```

Each Surface should detect its own screen state and use the appropriate search strategy.

---

## Part 6: Implementation Plan

### Phase 1: Current (✅ Complete)
- Show "Alt Screen" indicator when on alternate screen
- User understands why search is limited

### Phase 2: tmux Integration
1. Add `captureTmuxPane()` to `SSHSession`
2. Add `tmuxSearch` mode to `SearchState`
3. When searching on alternate + tmux:
   - Capture pane contents
   - Search locally
   - Display results with tmux badge
4. Navigation sends tmux commands:
   - `tmux copy-mode`
   - `tmux send-keys -X goto-line N`

### Phase 3: Connection Options
1. Add `disableTmuxAlternateScreen` to `ConnectionProfile`
2. On connect with tmux: inject `tmux set -g alternate-screen off`
3. Document trade-offs in connection settings UI

---

## Key Takeaways

1. **Alternate screen is a feature, not a bug** - it preserves your shell history
2. **tmux has its own scrollback** - completely separate from the terminal
3. **The right solution uses tmux's mechanism** - `capture-pane` is the native tool
4. **This architecture will matter for splits** - each Surface needs its own search strategy
5. **User choice is good** - some prefer terminal scrollback, some prefer tmux scrollback

