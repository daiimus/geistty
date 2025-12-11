# tmux Integration Architecture

## Vision

Bodak provides a **native Ghostty experience** for iOS/iPadOS that seamlessly integrates with tmux. Instead of fighting against tmux's window/pane model, we embrace it - mapping tmux concepts to iPadOS UI concepts.

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
| Scrollback | Ghostty Scrollback | Owned by Bodak (via %output) |

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│ Bodak App                                                           │
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
│  │ SSHConnection (EXISTING)                                     │   │
│  │  - Low-level libssh2 wrapper                                 │   │
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

### Phase 1: Multi-Pane Foundation ⬜

**Goal**: Support multiple tmux panes, each with its own Ghostty surface.

#### 1.1 TmuxSessionManager (NEW)
```swift
@MainActor
class TmuxSessionManager: ObservableObject {
    /// Current session info
    @Published var currentSession: TmuxSession?
    
    /// All windows in the current session
    @Published var windows: [TmuxWindow] = []
    
    /// All panes across all windows
    @Published var panes: [String: TmuxPane] = [:]  // paneId -> pane
    
    /// Active pane ID
    @Published var activePaneId: String = "%0"
    
    /// Ghostty surfaces for each pane
    private var paneSurfaces: [String: Ghostty.SurfaceView] = [:]
    
    // Methods
    func createSurface(for paneId: String) -> Ghostty.SurfaceView
    func routeOutput(_ data: Data, to paneId: String)
    func sendInput(_ data: Data, from paneId: String)
}
```

#### 1.2 Data Models (NEW)
```swift
struct TmuxSession {
    let id: String        // $0, $1, etc.
    let name: String
    var windows: [String] // window IDs
}

struct TmuxWindow {
    let id: String        // @0, @1, etc.
    let index: Int
    var name: String
    var panes: [String]   // pane IDs
    var activePane: String
    var layout: String
}

struct TmuxPane {
    let id: String        // %0, %1, etc.
    let windowId: String
    var width: Int
    var height: Int
    var cursorX: Int
    var cursorY: Int
    var isActive: Bool
    var title: String
}
```

#### 1.3 Enhanced TmuxControlClient
Add missing notifications:
- `%window-pane-changed` - Track active pane per window
- `%sessions-changed` - Session created/destroyed
- `%session-renamed` - Session name changed  
- `%session-window-changed` - Current window changed
- `%unlinked-window-*` - Windows in other sessions

Add query commands:
- `list-sessions -F '#{session_id} #{session_name}'`
- `list-windows -F '#{window_id} #{window_index} #{window_name} #{window_layout}'`
- `list-panes -F '#{pane_id} #{pane_width} #{pane_height} #{pane_active}'`

### Phase 2: iPadOS Window Mapping ⬜

**Goal**: Map tmux windows to iPadOS scenes/windows.

#### 2.1 Scene Management
- Each iPadOS scene can display one tmux window
- Support for Stage Manager (multiple windows)
- Support for Split View (two windows side by side)
- External display support (dedicated window)

#### 2.2 User Activities
```swift
// NSUserActivity for state restoration
let activity = NSUserActivity(activityType: "com.bodak.tmux-window")
activity.userInfo = [
    "sessionName": "main",
    "windowId": "@0"
]
```

#### 2.3 Window Commands (iPadOS Menu Bar)
- **Window → New Window** - `new-window` in tmux, opens new iPadOS scene
- **Window → Close Window** - `kill-window`, closes iPadOS scene
- **Window → Rename Window** - `rename-window`
- **Window → Move to New iPad Window** - Spawn new scene for current tmux window

### Phase 3: Pane Splitting ⬜

**Goal**: Support tmux pane splits within a single iPadOS window.

#### 3.1 Split Commands
- **View → Split Horizontally** - `split-window -h`
- **View → Split Vertically** - `split-window -v`
- **View → Close Pane** - `kill-pane`

#### 3.2 Layout Engine
- Parse tmux layout strings (e.g., `a]be,80x24,0,0{40x24,0,0,0,39x24,41,0,1}`)
- Render multiple Ghostty surfaces in a container view
- Handle layout changes from `%layout-change` notifications

#### 3.3 Pane Navigation
- Keyboard: `Ctrl+B arrow` (via tmux)
- Touch: Tap to focus pane
- Trackpad: Click to focus
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
2. Force-quit Bodak
3. Relaunch Bodak
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
4. **Scrollback**: Per-pane scrollback in Bodak or query tmux?
5. **Copy/paste**: Native iOS or tmux copy mode?
