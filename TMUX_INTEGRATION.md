# tmux Integration Architecture

> **⚠️ PARTIALLY OUTDATED (December 2025)**
> 
> This document's **vision and principles remain valid**, but the implementation details are outdated.
> The architecture has been migrated from `TmuxControlClient` (class-based, @MainActor) to 
> `TmuxGateway` (Swift actor with AsyncStream).
> 
> **For current architecture, see:** [AGENTS.md](AGENTS.md#tmux-integration)

## Vision

Geistty provides a **native Ghostty experience** for iOS/iPadOS that seamlessly integrates with tmux. Instead of fighting against tmux's window/pane model, we embrace it - mapping tmux concepts to iPadOS UI concepts.

## Core Principles

1. **tmux is the truth** - tmux server maintains session/window/pane state
2. **Ghostty renders** - Each tmux pane gets its own Ghostty surface
3. **iPadOS presents** - iPad windows/scenes map to tmux entities
4. **Control Mode bridges** - `-CC` protocol provides real-time sync

## Mapping: tmux → iPadOS

| tmux Concept | iPadOS Concept | Notes |
|--------------|----------------|-------|
| Session | App State / Connection | One SSH connection = one tmux session |
| Window | iPad Scene/Window | Stage Manager windows, Split View |
| Pane | Ghostty Surface | One surface per pane |
| Scrollback | Ghostty Scrollback | Owned by Geistty (via %output) |

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│ Geistty App                                                           │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ TmuxSessionManager (NEW)                                     │   │
│  │  - Tracks all sessions, windows, panes                       │   │
│  │  - Maps pane IDs to Ghostty surfaces                         │   │
│  │  - Routes %output to correct surface                         │   │
│  │  - Handles window/pane notifications                         │   │
│  └─────────────────────────────────────────────────────────────┘   │
│           │                                                         │
│           ▼                                                         │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ TmuxControlClient (EXISTING - ENHANCED)                      │   │
│  │  - Parses control mode protocol                              │   │
│  │  - Decodes octal escapes                                     │   │
│  │  - Tracks pause/continue state                               │   │
│  │  - NEW: Emits structured notifications                       │   │
│  └─────────────────────────────────────────────────────────────┘   │
│           │                                                         │
│           ▼                                                         │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ SSHSession (EXISTING)                                        │   │
│  │  - SSH connection management                                 │   │
│  │  - Routes data to/from TmuxControlClient                     │   │
│  └─────────────────────────────────────────────────────────────┘   │
│           │                                                         │
│           ▼                                                         │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ NIOSSHConnection (EXISTING)                                  │   │
│  │  - SwiftNIO-SSH wrapper with Network.framework               │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    SSH Channel (encrypted)
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Remote Server                                                       │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ tmux Server                                                  │   │
│  │                                                              │   │
│  │  Session "main"                                              │   │
│  │    Window @0 "code"                                          │   │
│  │      Pane %0 (vim)  ──────┐                                  │   │
│  │      Pane %1 (shell) ─────┤──► PTYs                          │   │
│  │    Window @1 "servers"    │                                  │   │
│  │      Pane %2 (htop) ──────┘                                  │   │
│  │                                                              │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

## Implementation Plan

### Phase 1: Multi-Pane Foundation ✅ COMPLETE

**Goal**: Support multiple tmux panes, each with its own Ghostty surface.

#### 1.1 TmuxSessionManager ✅ IMPLEMENTED
- Located in `Sources/SSH/TmuxSessionManager.swift`
- Tracks session state, windows, panes
- Maps pane IDs to Ghostty surfaces via `paneSurfaces` dictionary
- Routes `%extended-output` to correct surface
- Surface factory pattern for creating new pane surfaces
- Focus tracking with `@Published focusedPaneId`

#### 1.2 Data Models ✅ IMPLEMENTED
- Located in `Sources/SSH/TmuxModels.swift`
- `TmuxSession`, `TmuxWindow`, `TmuxPane` structs
- Layout parsing with checksum validation

#### 1.3 Enhanced TmuxControlClient ✅ IMPLEMENTED
All notifications handled:
- `%window-pane-changed` - Track active pane per window
- `%sessions-changed` - Session created/destroyed
- `%session-renamed` - Session name changed  
- `%session-window-changed` - Current window changed
- `%layout-change` - Pane layout updates
- `%extended-output` - Per-pane output routing

### Phase 2: Multi-Pane Rendering ✅ COMPLETE

**Goal**: Render tmux panes with proper split layouts.

#### 2.1 Layout Parsing ✅ IMPLEMENTED
- `TmuxLayout.swift` - Parses tmux layout strings with checksum
- `TmuxSplitTree.swift` - Converts layouts to renderable tree structure
- Supports horizontal and vertical splits, nested layouts

#### 2.2 Split View Rendering ✅ IMPLEMENTED
- `TmuxSplitTreeView.swift` - SwiftUI view for recursive split rendering
- `TmuxMultiPaneView.swift` - Main container observing TmuxSessionManager
- `GhosttyPaneSurfaceContainerView` - UIKit container for each Ghostty surface

#### 2.3 Focus & Input ✅ IMPLEMENTED
- Tap detection via `hitTest` override (works despite Ghostty touch handling)
- Input-based focus tracking (typing in pane updates focus)
- Visual focus indicator (border highlight)
- Per-pane input routing via `send-keys -H -t %N`

### Phase 2.5: Multi-Pane Polish 🔄 IN PROGRESS

- [ ] **Pane close handling** - Cleanup surfaces when `kill-pane` executed
- [ ] **Transition to single-pane** - Return to single surface when all splits closed
- [ ] **Surface cleanup** - Remove orphaned surfaces from paneSurfaces dictionary

### Phase 3: Multiple tmux Windows 🔲 TODO

**Goal**: Support switching between tmux windows.

#### 3.1 Window List UI
- Sidebar or tab bar showing window list
- Window names from tmux
- Quick switching with tap/keyboard

#### 3.2 Window Commands
- Handle `%window-add`/`%window-close` notifications
- `select-window -t @N` for switching
- Window rename support

### Phase 4: iPadOS Window Mapping 🔲 FUTURE

**Goal**: Map tmux windows to iPadOS scenes/windows.

#### 4.1 Scene Management
- Each iPadOS scene can display one tmux window
- Support for Stage Manager (multiple windows)
- Support for Split View (two windows side by side)
- External display support (dedicated window)

#### 4.2 User Activities
```swift
// NSUserActivity for state restoration
let activity = NSUserActivity(activityType: "com.geistty.tmux-window")
activity.userInfo = [
    "sessionName": "main",
    "windowId": "@0"
]
```

#### 4.3 Window Commands (iPadOS Menu Bar)
- **Window → New Window** - `new-window` in tmux, opens new iPadOS scene
- **Window → Close Window** - `kill-window`, closes iPadOS scene
- **Window → Rename Window** - `rename-window`
- **Window → Move to New iPad Window** - Spawn new scene for current tmux window

### Phase 5: Pane Splitting Commands 🔲 FUTURE

**Goal**: Support creating splits from Geistty UI.

#### 5.1 Split Commands
- **View → Split Horizontally** - `split-window -h`
- **View → Split Vertically** - `split-window -v`
- **View → Close Pane** - `kill-pane`

#### 5.2 Pane Navigation Shortcuts
- Keyboard: `Ctrl+B arrow` (via tmux) - already works
- Touch: Tap to focus pane - ✅ implemented
- Cmd+Option+arrows for direct pane navigation
- Swipe gestures for pane switching?

### Phase 4: Session Management ⬜

**Goal**: Full session lifecycle management.

#### 4.1 Session Picker
- List all tmux sessions on connect
- Create new session
- Attach to existing session
- Detach / switch sessions

#### 4.2 Connection Profiles Enhancement
```swift
struct ConnectionProfile {
    // ... existing fields ...
    
    // tmux options
    var useTmux: Bool
    var tmuxSessionName: String?
    var tmuxAutoCreate: Bool      // Create session if doesn't exist
    var tmuxAttachExisting: Bool  // Attach to existing vs new window
}
```

#### 4.3 Session Persistence
- Remember which tmux session was open
- Restore iPad windows → tmux windows mapping
- Handle reconnection gracefully

### Phase 5: Advanced Features ⬜

#### 5.1 Copy Mode Integration
- Detect `%pane-mode-changed` for copy mode
- Overlay native iOS selection UI?
- Or let tmux copy mode work natively

#### 5.2 Synchronize Panes
- `synchronize-panes` option
- Type in one pane, appears in all

#### 5.3 Popup Windows
- tmux 3.2+ popup windows
- Could map to iOS sheets/popovers

#### 5.4 Status Line
- Parse tmux status line format
- Render native iOS status bar?
- Or render in Ghostty surface

---

## Protocol Reference

### Notifications We Handle ✅
- `%output` / `%extended-output` - Pane output
- `%begin` / `%end` / `%error` - Command responses
- `%session-changed` - Attached session changed
- `%layout-change` - Window layout changed
- `%window-add` / `%window-close` - Window lifecycle
- `%window-renamed` - Window name changed
- `%exit` - Control client exit
- `%pause` / `%continue` - Flow control
- `%pane-mode-changed` - Pane entered/exited special mode
- `%client-session-changed` / `%client-detached` - Other clients

### Notifications To Add ⬜
- `%window-pane-changed @window %pane` - Active pane in window changed
- `%sessions-changed` - Session created/destroyed
- `%session-renamed $session new-name` - Session renamed
- `%session-window-changed $session @window` - Current window changed
- `%unlinked-window-add @window` - Window added in other session
- `%unlinked-window-close @window` - Window closed in other session
- `%unlinked-window-renamed @window name` - Window renamed in other session
- `%subscription-changed name ...` - Format subscription update

### Key Commands
```bash
# Session management
list-sessions -F '#{session_id} "#{q:session_name}"'
new-session -s name
kill-session -t name
switch-client -t session

# Window management
list-windows -t session -F '#{window_id} #{window_index} "#{q:window_name}" #{window_layout}'
new-window -t session -n name
kill-window -t @id
rename-window -t @id name
select-window -t @id

# Pane management
list-panes -t @window -F '#{pane_id} #{pane_width} #{pane_height} #{pane_active} #{cursor_x} #{cursor_y}'
split-window -t %pane -h/-v
kill-pane -t %pane
select-pane -t %pane

# Client/display
refresh-client -C cols,rows    # Resize
refresh-client -f pause-after=N # Flow control

# Input
send-keys -H -t %pane hex      # Send input to specific pane
```

---

## Testing Scenarios

### Scenario 1: Basic Multi-Pane
1. Connect with tmux
2. Split pane: `Ctrl+B %`
3. Both panes should render in iPad window
4. Type in each pane independently
5. Close one pane: `Ctrl+B x`

### Scenario 2: Multiple iPad Windows
1. Connect with tmux
2. Create new window: `Ctrl+B c`
3. Open new iPad scene (Stage Manager or Cmd+N)
4. New scene should show the new tmux window
5. Navigate between scenes

### Scenario 3: Session Persistence
1. Connect, create windows/panes
2. Force-quit Geistty
3. Relaunch Geistty
4. Reconnect to same server
5. Should restore all windows/panes

### Scenario 4: External Display
1. Connect iPad to external display
2. Move one tmux window to external display
3. Should render full-screen on external
4. Main iPad shows other windows

---

## Implementation Order

1. **Phase 1.1**: TmuxSessionManager + data models
2. **Phase 1.2**: Multi-surface routing (one pane per surface)
3. **Phase 1.3**: Missing notifications
4. **Phase 2.1**: iPadOS scene basics
5. **Phase 3.1**: Pane split commands
6. **Phase 3.2**: Layout parsing & rendering
7. **Phase 2.2-2.3**: Window management polish
8. **Phase 4**: Session management UI
9. **Phase 5**: Advanced features

---

## Open Questions

1. **Layout rendering**: Use SwiftUI container views or custom CALayer arrangement?
2. **Surface lifecycle**: Create surfaces on-demand or pool them?
3. **Memory**: How many Ghostty surfaces can we reasonably maintain?
4. **Scrollback**: Per-pane scrollback in Geistty or query tmux?
5. **Copy/paste**: Native iOS or tmux copy mode?
