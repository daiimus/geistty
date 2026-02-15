# Architecture

> Geistty v0.1-stable -- February 2026

Geistty is a native iOS/iPadOS SSH terminal that uses [Ghostty](https://ghostty.org)'s real terminal engine (compiled from Zig) with an External termio backend. iOS cannot spawn local shells (no `fork`/`exec`/PTY), so all terminal data flows over SSH. Ghostty handles VT parsing, Metal rendering, and tmux control mode. Swift handles SSH transport, connection management, and iOS UI.

This document describes how the pieces fit together.

---

## Table of Contents

- [Layer Diagram](#layer-diagram)
- [File Inventory](#file-inventory)
- [The Big Four](#the-big-four)
- [Data Flow: Output Path](#data-flow-output-path)
- [Data Flow: Input Path](#data-flow-input-path)
- [Data Flow: tmux Control Mode](#data-flow-tmux-control-mode)
- [Threading Model](#threading-model)
- [Surface Lifecycle](#surface-lifecycle)
- [Connection Lifecycle](#connection-lifecycle)
- [Config System](#config-system)
- [tmux State Management](#tmux-state-management)
- [Ghostty Fork: What We Changed](#ghostty-fork-what-we-changed)
- [Gap Analysis: What Would Mitchell Do?](#gap-analysis-what-would-mitchell-do)
- [Known Issues and Technical Debt](#known-issues-and-technical-debt)

---

## Layer Diagram

Geistty is an onion. Four layers, outside-in:

```mermaid
graph TB
    subgraph "Layer 1: SwiftUI"
        A[GeisttyApp] --> B[ContentView]
        B --> C[ConnectionListView]
        B --> D[TerminalContainerView]
        B --> E[SettingsView]
        D --> F[TmuxMultiPaneView]
        D --> G[TmuxWindowPickerView]
    end

    subgraph "Layer 2: UIKit Bridge"
        H[RawTerminalUIViewController]
        I[Ghostty.SurfaceView<br/>UIView + CAMetalLayer<br/>+ UIKeyInput + Gestures]
    end

    subgraph "Layer 3: State & Transport"
        J[TerminalViewModel]
        K[SSHSession]
        L[TmuxSessionManager]
        M[NIOSSHConnection<br/>SwiftNIO-SSH + Network.framework]
    end

    subgraph "Layer 4: GhosttyKit (Zig)"
        N[ghostty.h C API]
        O[External.zig<br/>termio backend]
        P[stream_handler.zig<br/>VT parser dispatch]
        Q[viewer.zig<br/>tmux state machine]
        R[Terminal.zig<br/>grid + scrollback]
        S[Metal Renderer<br/>GPU text rendering]
    end

    D --> H
    H --> I
    D --> J
    J --> K
    J --> I
    K --> L
    K --> M
    I --> N
    N --> O
    N --> P
    P --> Q
    P --> R
    R --> S

    style A fill:#4a9eff,color:#fff
    style I fill:#ff6b6b,color:#fff
    style K fill:#ffa94d,color:#fff
    style O fill:#51cf66,color:#fff
```

**Layer 1 (SwiftUI)** owns navigation, connection profiles, settings, and tmux pane layout views. It never touches Ghostty directly.

**Layer 2 (UIKit)** is where Metal rendering lives. `SurfaceView` is a `UIView` subclass that hosts an `IOSurfaceLayer` for GPU rendering and implements `UIKeyInput` for keyboard capture. This layer exists because Ghostty's renderer needs a real `CALayer`, not a SwiftUI view.

**Layer 3 (State & Transport)** manages SSH connections, terminal state, and tmux session tracking. `TerminalViewModel` coordinates between the SSH session and the surface view. `SSHSession` owns the network connection and delegates data to the view model.

**Layer 4 (GhosttyKit)** is Ghostty's Zig core compiled as a static library. It handles VT parsing, terminal grid state, Metal rendering, and (in our fork) the External termio backend and tmux control mode viewer.

---

## File Inventory

34 Swift source files across 7 directories:

| Directory | Files | Purpose |
|-----------|-------|---------|
| `App/` | `GeisttyApp.swift`, `ContentView.swift` | Entry point, root navigation, `AppState` |
| `Auth/` | `ConnectionProfile.swift`, `CredentialProvider.swift`, `KeychainManager.swift`, `SSHKeyManager.swift`, `SSHKeyParser.swift` | SSH credentials, Keychain, key generation/parsing |
| `Ghostty/` | `Ghostty.swift`, `GhosttyInput.swift`, `FontMapping.swift`, `ConfigSyncManager.swift`, `SurfaceSearchOverlay.swift` | C API bridge, keyboard input, config, search UI |
| `SFTP/` | `SFTPChannel.swift`, `SFTPClient.swift`, `SFTPClientProtocol.swift`, `MockSFTPClient.swift`, `SFTPBrowserView.swift` | SFTP implementation (dormant/archived) |
| `SSH/` | `NIOSSHConnection.swift`, `SSHSession.swift`, `TmuxSessionManager.swift`, `TmuxLayout.swift`, `TmuxSplitTree.swift`, `TmuxModels.swift`, `TmuxSessionNameResolver.swift` | SSH transport, tmux state management |
| `Terminal/` | `TerminalContainerView.swift`, `TmuxMultiPaneView.swift`, `TmuxSplitView.swift`, `TmuxWindowPickerView.swift`, `Theme.swift` | Terminal UI, multi-pane layouts, theming |
| `UI/` | `ConnectionListView.swift`, `ConnectionEditorView.swift`, `SettingsView.swift`, `KeyTableIndicatorView.swift`, `SessionResumeToastView.swift` | Connection management UI, settings |

---

## The Big Four

Four files carry most of the weight. Everything else is supporting cast.

### 1. `Ghostty.swift` (~2800 lines)

The monolith. Contains `Ghostty.Config`, `Ghostty.App`, `SurfaceConfiguration`, and `Ghostty.SurfaceView`. SurfaceView alone is ~1600 lines handling:

- Surface creation/destruction via C API
- Metal layer hosting (IOSurfaceLayer as sublayer)
- `UIKeyInput` for software keyboard
- `pressesBegan`/`pressesEnded` for hardware keyboard
- Gesture recognizers (scroll, selection, pinch-zoom)
- Write callback (user input -> SSH)
- Resize callback (terminal dimensions -> SSH/tmux)
- Search overlay coordination
- Notification posting for tmux actions

This file should eventually be split into extensions. It's our single biggest technical debt item in terms of code organization.

### 2. `SSHSession.swift` (~1384 lines)

SSH connection lifecycle, tmux control mode entry, reconnection logic, and data routing. Key responsibilities:

- Connect/disconnect/reconnect with credential storage
- `handleReceivedData()` -- routes SSH bytes to the surface view
- tmux notification observation (state changes, exits)
- Forwards tmux events to `TmuxSessionManager`
- Manages `isReconnecting` state and retry logic

### 3. `TerminalContainerView.swift` (~2389 lines)

SwiftUI view + UIKit view controller + `TerminalViewModel`. The view controller (`RawTerminalUIViewController`) creates and owns the `SurfaceView`. The view model coordinates between the SSH session and the surface. The SwiftUI view handles:

- Toolbar (connection status, tmux controls, settings)
- Multi-pane vs single-pane transitions
- Keyboard avoidance and resize handling
- Disconnect overlay

### 4. `TmuxSessionManager.swift` (~1400+ lines)

Tracks tmux windows, panes, and sessions. Manages the mapping between tmux pane IDs and Ghostty surfaces. Handles:

- `handleTmuxStateChanged()` from Ghostty notifications
- Window/pane creation and destruction
- Split tree construction from layout strings
- Active pane switching
- Resize debouncing

---

## Data Flow: Output Path

SSH server output to terminal display (non-tmux mode):

```mermaid
sequenceDiagram
    participant Server as SSH Server
    participant NIO as NIOSSHConnection
    participant SSH as SSHSession
    participant VM as TerminalViewModel
    participant SV as SurfaceView
    participant Zig as GhosttyKit (Zig)
    participant GPU as Metal Renderer

    Server->>NIO: SSH channel data
    NIO->>SSH: delegate.handleReceivedData(data)
    SSH->>VM: delegate.sshSession(didReceiveData:)
    VM->>SV: surfaceView.feedData(data)
    SV->>Zig: ghostty_surface_write_output(surface, ptr, len)
    Zig->>Zig: VT parser -> Terminal grid update
    Zig->>GPU: Dirty cells -> Metal draw call
    GPU->>SV: IOSurfaceLayer displays frame
```

In non-tmux mode, the path is straight: bytes arrive over SSH, get fed to Ghostty, Ghostty parses escape sequences, updates the terminal grid, and Metal renders the result. No tmux wrapping, no `%output` parsing.

---

## Data Flow: Input Path

User keystrokes to SSH server (non-tmux mode):

```mermaid
sequenceDiagram
    participant User as Keyboard / Touch
    participant SV as SurfaceView
    participant Zig as GhosttyKit (Zig)
    participant Ext as External.zig
    participant VM as TerminalViewModel
    participant SSH as SSHSession
    participant NIO as NIOSSHConnection
    participant Server as SSH Server

    User->>SV: insertText() / pressesBegan()
    SV->>Zig: ghostty_surface_text() / ghostty_surface_key()
    Zig->>Ext: Termio.queueWrite(data)
    Ext->>SV: write_callback(surface, data, len)
    SV->>VM: onWrite?(Data)
    VM->>SSH: sendInput(data)
    SSH->>NIO: writeAsync(data)
    NIO->>Server: SSH channel write
```

The write callback is the key mechanism: when the Zig side wants to send bytes (the terminal's response to user input), it calls back into Swift through a C function pointer. `SurfaceView` holds this as `onWrite`, which the view model connects to the SSH session.

---

## Data Flow: tmux Control Mode

This is where it gets interesting. In tmux control mode (`tmux -CC`), Ghostty's Zig code handles the entire protocol:

```mermaid
sequenceDiagram
    participant Server as tmux on Server
    participant SSH as SSHSession
    participant SV as SurfaceView
    participant VT as VT Parser (Zig)
    participant Viewer as viewer.zig
    participant Pane as Per-Pane Terminal
    participant NC as NotificationCenter
    participant TSM as TmuxSessionManager

    Note over Server,TSM: === Output Path (server -> display) ===

    Server->>SSH: %output %42 \033[1mhello\033[m
    SSH->>SV: feedData(rawBytes)
    SV->>VT: ghostty_surface_write_output()
    VT->>VT: DCS 1000p detected -> enter tmux mode
    VT->>Viewer: control parser dispatches %output
    Viewer->>Viewer: octal unescape data
    Viewer->>Pane: pane.terminal.vtStream(unescaped)
    Pane->>Pane: Terminal grid update -> Metal render

    Server->>SSH: %layout-change ...
    SSH->>SV: feedData(rawBytes)
    SV->>VT: ghostty_surface_write_output()
    VT->>Viewer: control parser dispatches %layout-change
    Viewer->>Viewer: update internal state
    Viewer->>VT: action: TMUX_STATE_CHANGED
    VT->>SV: C callback -> Ghostty.App.action()
    SV->>NC: post(.tmuxStateChanged)
    NC->>SSH: observeTmuxNotifications handler
    SSH->>TSM: handleTmuxStateChanged(windowCount, paneCount)
    TSM->>TSM: update UI state

    Note over Server,TSM: === Input Path (user -> server) ===

    Note over SV: User types "ls\n"
    SV->>VT: ghostty_surface_key() / ghostty_surface_text()
    VT->>Viewer: Termio.queueWrite() detects tmux active
    Viewer->>Viewer: sendKeys("6C 73 0D")
    Viewer->>VT: "send-keys -H -t %42 6C 73 0D\n"
    VT->>SV: External.write_callback
    SV->>SSH: writeFromGhostty(data)
    SSH->>Server: SSH write -> tmux interprets command
```

Key insight: **all stdin in tmux control mode is interpreted as tmux commands**. User keystrokes are hex-encoded and wrapped in `send-keys -H -t %<paneID>` by Ghostty's Zig code. The Swift side is a pure pass-through -- it never sees or wraps tmux commands.

### tmux protocol detail

tmux control mode uses `%`-prefixed messages. Ghostty's `control.zig` parser handles:

| Message | Format | Handling |
|---------|--------|----------|
| `%output` | `%output %<paneID> <octal-escaped-data>` | Routed to per-pane Terminal via `viewer.receivedOutput()` |
| `%begin` | `%begin <time> <num> <flags>` | Command response start (handled by viewer) |
| `%end` | `%end <time> <num> <flags>` | Command response end |
| `%error` | `%error <time> <num> <flags>` | Command error |
| `%layout-change` | `%layout-change <window> <layout>` | Triggers `TMUX_STATE_CHANGED` action to Swift |
| `%session-changed` | `%session-changed $<id> <name>` | Session switch |
| `%exit` | `%exit [reason]` | Control mode exited, triggers `TMUX_EXIT` action |

Data in `%output` uses octal escaping: bytes < 32 and `\` are encoded as `\NNN` (e.g., `\033` for ESC). Ghostty's viewer unescapes this before feeding it to the per-pane terminal.

---

## Threading Model

```mermaid
graph LR
    subgraph "Main Thread"
        A[SwiftUI Views]
        B[UIKit SurfaceView]
        C["processOutput()<br/>ghostty_surface_write_output()"]
    end

    subgraph "Ghostty IO Thread"
        D["queueWrite()<br/>(user input processing)"]
        E["resize()<br/>(terminal dimension changes)"]
        F["sendKeys()<br/>(tmux command wrapping)"]
    end

    subgraph "Render Thread"
        G["Metal draw calls<br/>(reads terminal state)"]
    end

    subgraph "NIO Event Loop"
        H["SwiftNIO-SSH<br/>Network.framework I/O"]
    end

    M{{"renderer_state.mutex"}}

    C --> M
    D --> M
    E --> M
    G --> M

    H -->|"delegate callback"| C
    D -->|"write_callback"| H
    E -->|"resize_callback"| H

    style M fill:#ff6b6b,color:#fff
```

The `renderer_state.mutex` is the critical synchronization point. It protects the terminal grid state that all threads access:

| Thread | Operations | Holds Mutex? |
|--------|-----------|--------------|
| **Main** | `ghostty_surface_write_output()` -- feeds SSH data to VT parser | Yes |
| **IO** | `queueWrite()` -- processes user input, `sendKeys()` wraps for tmux | Yes |
| **IO** | `resize()` -- updates terminal dimensions, sends `refresh-client -C` | Yes |
| **Render** | Reads terminal cells for Metal draw calls | Yes |
| **NIO** | SSH network I/O (independent, no mutex) | No |

The IO thread and render thread are created by Ghostty internally. The NIO event loop is managed by SwiftNIO with `NIOTSEventLoopGroup` (backed by Network.framework for iOS power management).

---

## Surface Lifecycle

```mermaid
stateDiagram-v2
    [*] --> Loading: App launch

    Loading --> CreatingSurface: Navigation to terminal

    state CreatingSurface {
        [*] --> ConfigInit: ghostty_config_new()
        ConfigInit --> ConfigLoad: ghostty_config_load_string()
        ConfigLoad --> ConfigFinalize: ghostty_config_finalize()
        ConfigFinalize --> AppInit: ghostty_app_new()
        AppInit --> SurfaceInit: ghostty_surface_new()<br/>with GHOSTTY_BACKEND_EXTERNAL<br/>+ write_callback + resize_callback
    }

    CreatingSurface --> WaitingForSSH: Surface ready, no data yet

    WaitingForSSH --> Connected: SSH established,<br/>first data arrives

    Connected --> TmuxActive: DCS 1000p detected<br/>(viewer.zig activates)

    TmuxActive --> Connected: %exit received<br/>(TMUX_EXIT action)

    Connected --> Disconnected: SSH connection lost

    TmuxActive --> Disconnected: SSH connection lost

    Disconnected --> Reconnecting: Auto-reconnect<br/>(stored credentials)

    Reconnecting --> Connected: SSH re-established

    Reconnecting --> Disconnected: Retry failed<br/>(up to 3 attempts)

    Connected --> Destroyed: User navigates away
    TmuxActive --> Destroyed: User navigates away
    Disconnected --> Destroyed: User disconnects

    state Destroyed {
        [*] --> ClearCallbacks: onWrite = nil
        ClearCallbacks --> FreeSurface: ghostty_surface_free()
        FreeSurface --> [*]
    }

    Destroyed --> [*]
```

**iOS-specific considerations:**

1. **IOSurfaceLayer as sublayer**: On iOS, Ghostty adds its Metal rendering surface as a sublayer (macOS replaces the layer entirely). We manually resize sublayers in `sizeDidChange()`.

2. **`addSublayer` selector mismatch**: Ghostty's Zig ObjC bridge calls `objc.sel("addSublayer")` without the colon. We register a runtime method on `SurfaceView` to handle this.

3. **Surface cleanup**: macOS Ghostty uses `Task.detached { @MainActor in ghostty_surface_free() }` in deinit. We do a direct `close()` call. This is a known gap -- see [Gap Analysis](#gap-analysis-what-would-mitchell-do).

---

## Connection Lifecycle

```mermaid
stateDiagram-v2
    [*] --> ConnectionList: App launch

    ConnectionList --> Connecting: User selects profile<br/>or Quick Connect

    state Connecting {
        [*] --> SSHHandshake: NIOSSHConnection.connect()
        SSHHandshake --> Auth: Key exchange complete
        Auth --> PTYRequest: Authentication success
        PTYRequest --> ShellOpen: PTY allocated at 80x24
        ShellOpen --> TmuxAttach: "exec tmux -CC new-session -A -s name"
    }

    Connecting --> TerminalActive: SSH + tmux established

    state TerminalActive {
        [*] --> WaitingForDCS: Shell output arriving
        WaitingForDCS --> TmuxControlMode: DCS 1000p detected
        TmuxControlMode --> CapturePaneRestore: viewer.zig runs capture-pane
        CapturePaneRestore --> Ready: Pane content restored
    }

    TerminalActive --> LayoutSync: First resize dispatched
    LayoutSync --> TerminalActive: refresh-client -C sent

    TerminalActive --> Suspended: App enters background

    Suspended --> CheckAlive: App becomes active

    CheckAlive --> TerminalActive: Connection alive
    CheckAlive --> AutoReconnect: Connection dead

    state AutoReconnect {
        [*] --> Attempt: Delay 2s, retry
        Attempt --> Success: SSH + tmux re-attached
        Attempt --> Retry: Failed (attempts < 3)
        Retry --> Attempt
        Attempt --> Failed: Max retries exceeded
    }

    AutoReconnect --> TerminalActive: Reconnect success
    AutoReconnect --> Disconnected: Reconnect failed

    Disconnected --> Connecting: User taps Reconnect (Cmd+R)
    Disconnected --> ConnectionList: User disconnects

    TerminalActive --> ConnectionList: User disconnects (Cmd+W)
```

**Credential handling for reconnect:**

- Stored in memory on successful connect (`storedPassword`, `storedProfile`, `storedCredential`)
- Cleared on explicit disconnect (prevents unwanted reconnect)
- Never persisted to disk (Keychain stores saved profiles separately)

---

## Config System

Ghostty configuration flows from `ghostty.conf` through the C API:

```mermaid
graph TD
    A["ghostty.conf<br/>(source of truth)"] -->|"ghostty_config_load_string()"| B[ghostty_config_t]
    C["Runtime defaults<br/>(font-size, theme)"] -->|"ghostty_config_load_string()"| B
    B -->|"ghostty_config_finalize()"| D[Finalized Config]
    D -->|"ghostty_app_new()"| E[Ghostty.App]
    E -->|"ghostty_surface_new()"| F[Surface with config]

    G["Live changes<br/>(font size +/-)"] -->|"ghostty_config_load_string()"| H[New ghostty_config_t]
    H -->|"ghostty_config_finalize()"| I[New Finalized Config]
    I -->|"ghostty_surface_update_config()"| F

    J["AppSettings.shared<br/>(UserDefaults)"] -.->|"showStatusBar,<br/>backgroundOpacity"| K[SwiftUI views]

    style A fill:#51cf66,color:#fff
    style J fill:#ffa94d,color:#000
```

**Current state:** `ghostty.conf` is the primary config source for terminal behavior (font, theme, colors, scrollback). However, a few UI preferences live in `AppSettings.shared` (UserDefaults): `showStatusBar`, `backgroundOpacity`. This split is a known gap -- see [Gap Analysis](#gap-analysis-what-would-mitchell-do).

**Config classes:**

- `Ghostty.Config` -- wraps `ghostty_config_t`, handles load/finalize lifecycle
- `ConfigSyncManager` -- watches `ghostty.conf` for changes, triggers reload
- `AppSettings` -- singleton for UserDefaults-based UI prefs

---

## tmux State Management

```mermaid
graph TB
    subgraph "Zig Side (viewer.zig)"
        V[Viewer State Machine]
        P1["Pane %1<br/>Terminal instance"]
        P2["Pane %2<br/>Terminal instance"]
        P3["Pane %3<br/>Terminal instance"]
        V --> P1
        V --> P2
        V --> P3
    end

    subgraph "C API Boundary"
        API["ghostty_surface_tmux_pane_count()<br/>ghostty_surface_tmux_pane_ids()<br/>ghostty_surface_tmux_set_active_pane()"]
    end

    subgraph "Swift Side"
        NC["NotificationCenter<br/>.tmuxStateChanged<br/>.tmuxExit"]
        SSH["SSHSession<br/>observeTmuxNotifications()"]
        TSM["TmuxSessionManager"]
        UI["TmuxMultiPaneView<br/>TmuxSplitView<br/>TmuxWindowPickerView"]
    end

    V -->|"TMUX_STATE_CHANGED action"| NC
    V -->|"TMUX_EXIT action"| NC
    NC --> SSH
    SSH --> TSM
    TSM --> UI
    API --> V

    style V fill:#51cf66,color:#fff
    style TSM fill:#4a9eff,color:#fff
```

**Dual state tracking:** The Zig viewer owns the authoritative tmux state (pane terminals, active pane, layout). The Swift `TmuxSessionManager` tracks a shadow of this state for UI purposes. When the viewer fires `TMUX_STATE_CHANGED`, Swift queries the C API to sync.

**Known limitation:** `TMUX_STATE_CHANGED` only carries `window_count` and `pane_count`. The viewer internally parses `%layout-change` with full geometry, but this is NOT exposed via the C API. The Swift-side split tree UI (`TmuxSplitTree`, `TmuxLayout`) parses layout strings independently. Wiring these together is future work.

---

## Ghostty Fork: What We Changed

Our fork (`daiimus/ghostty`, branch `ios-external-backend`) adds or modifies these files relative to upstream:

| File | Change | Purpose |
|------|--------|---------|
| `src/termio/External.zig` | **New** (~379 lines, 7 tests) | Termio backend that receives data via API, not PTY. Write/resize callbacks to Swift. |
| `src/terminal/tmux/viewer.zig` | **New** (~2700 lines, ~12 tests) | tmux control mode state machine. Per-pane terminals, capture-pane restore, sendKeys, resize. |
| `src/terminal/tmux/control.zig` | **New/Modified** | tmux control mode protocol parser with octal unescape. |
| `src/termio/stream_handler.zig` | Modified | DCS 1000p detection triggers Viewer. On exit, resets `renderer_state.terminal` before freeing (prevents use-after-free). |
| `src/termio/Termio.zig` | Modified | `queueWrite` intercepts when tmux viewer active -> `viewer.sendKeys()`. Resize sends `refresh-client -C`. |
| `src/termio/message.zig` | Modified | Added `write_*_direct` variants that bypass tmux send-keys wrapping. |
| `src/termio/backend.zig` | Modified | Added `external` variant to Kind/Config/Backend/ThreadData unions. |
| `src/config/CApi.zig` | Modified | Added `ghostty_config_load_file`, `ghostty_config_load_string`. |
| `src/terminal/dcs.zig` | Modified | `pending_esc` field for ESC in DCS passthrough without premature termination. |
| `include/ghostty.h` | Modified | Backend type, callbacks, `ghostty_surface_write_output()`, tmux pane APIs, action entries. |
| `src/apprt/embedded.zig` | Modified | Platform union with MacOS/IOS variants. `getTermioBackend()` returns exec or external. |

**Effective commit history (v0.1-stable):**

| # | Commit | Description |
|---|--------|-------------|
| 1 | `77402cb` | DCS passthrough fix -- ESC/CAN/SUB |
| 2 | `cceab0f` | Zig-side send-keys user input routing |
| 3 | `925ba95` | DCS passthrough fix #2 -- C1 control codes |
| 4 | `dca26cf` | Data race fix on tmux viewer and active_pane_id |
| 5 | `236c89a` | Command swallowing fix |
| 6 | `b54acee` | Blank screen fix after capture-pane restore |
| 7 | `1b59b70` | libxev sync to upstream |
| 8 | `aa6c99b` | Resize callback for External backend |
| 9 | `0a8c369` | tmux resize: data race fix, startup catch-up, pane terminal resize |
| 10 | `216ff75` | Use-after-free fix in `renderer_state.terminal` after `syncLayouts` |

Commits 11-12 (`fe750a2` persistent VT stream + `607a3c9` revert) cancel each other out.

---

## Gap Analysis: What Would Mitchell Do?

A comparison of our patterns against upstream macOS Ghostty. These are not bugs -- the app works -- but they represent deviations from the patterns Mitchell Hashimoto established.

### Critical Gaps

#### 1. No DerivedConfig Pattern

**Upstream:** macOS Ghostty extracts relevant config values into a `DerivedConfig` struct at init time. This provides type safety, avoids repeated C API calls, and makes config dependencies explicit.

**Us:** We read config values ad-hoc through the C API or construct config strings on the fly. This means config dependencies are scattered and implicit.

**Impact:** Medium. Makes it harder to reason about which config values affect which components. Also means we can't easily test config-dependent behavior.

**Fix:** Extract a `DerivedConfig` struct that captures the values we actually use (font family, font size, theme, scrollback, cursor style, etc.) and pass it through instead of the raw config handle.

#### 2. Surface Cleanup Threading

**Upstream:** macOS uses `Task.detached { @MainActor in ghostty_surface_free() }` in deinit to ensure the surface is freed on the main actor.

**Us:** We call `ghostty_surface_free()` directly in `close()` / `deinit`, which may execute on any thread.

**Impact:** Low (no crashes observed), but technically unsafe. The Metal layer and its resources should be freed on the main thread.

**Fix:** Adopt the `Task.detached { @MainActor }` pattern from upstream.

#### 3. `Ghostty.swift` Monolith

**Upstream:** macOS Ghostty splits surface functionality across multiple files: `Ghostty.SurfaceView_AppKit.swift` for the view, `Ghostty.SurfaceView+Input.swift` for keyboard, etc.

**Us:** `Ghostty.swift` is ~2800 lines with everything in one file. SurfaceView alone is ~1600 lines mixing input handling, gesture recognition, scroll physics, search, and keyboard management.

**Impact:** Low (everything works), but makes the file hard to navigate and increases merge conflict risk.

**Fix:** Split into extensions: `Ghostty+SurfaceView.swift`, `Ghostty+Input.swift`, `Ghostty+Gestures.swift`, `Ghostty+Search.swift`.

### Moderate Gaps

#### 4. Limited NotificationCenter Usage

**Upstream:** macOS uses extensive NotificationCenter for surface state changes: config changes, color changes, bell, readonly mode, key sequences, title changes.

**Us:** We use NotificationCenter for tmux state (`tmuxStateChanged`, `tmuxExit`) but handle other state changes through direct delegation or published properties.

**Impact:** Low. Our delegation pattern works fine for a single-surface app. If we add multi-window support, notifications would scale better.

#### 5. Config Source Split

**Upstream:** All terminal config lives in `ghostty.conf`. No UserDefaults.

**Us:** Most config is in `ghostty.conf`, but some UI preferences (`showStatusBar`, `backgroundOpacity`) live in `AppSettings.shared` (UserDefaults).

**Impact:** Low. These are iOS-specific UI preferences that don't have Ghostty config equivalents. But the dual-source creates ambiguity about where a setting should live.

**Fix:** For settings that have Ghostty equivalents, use `ghostty.conf`. For iOS-only UI chrome, `AppSettings` is acceptable. Document the boundary.

#### 6. `@MainActor` Annotations

**Upstream:** macOS annotates surface methods with `@MainActor` for thread safety.

**Us:** We use `@MainActor` on `SSHSession` and `TerminalViewModel`, but `SurfaceView` methods are called from C callbacks on various threads. The callback boundary is where thread safety transitions happen.

**Impact:** Low. The mutex handles synchronization at the Zig level. But Swift-side `@MainActor` annotations would make the contract explicit.

### Minor Gaps

#### 7. Logger Level Misuse

**Upstream:** Uses `logger.warning` for unexpected-but-recoverable situations, `logger.critical` for fatal issues, `logger.debug` for diagnostic output.

**Us:** Some SSH key parsing functions use `logger.error()` for what is actually debug-level diagnostic logging. `SSHSession.handleReceivedData()` hex-dumps every packet at `.info` level.

**Fix:** Audit all log calls. Demote diagnostics to `.debug`. Gate verbose hex logging behind a compile flag or `.debug` level.

#### 8. Custom Logger Struct

**Us:** `Ghostty.swift` defines a custom `Logger` struct that shadows `os.Logger`. It works (delegates to `os_log`) but is unusual and could confuse contributors.

**Fix:** Use `os.Logger` directly, consistent with the rest of the codebase.

#### 9. Dead Code

- `captureTmuxPane()` is a stub that always returns failure (from old architecture)
- SFTP directory has 5 dormant files (File Provider was shelved to `archive/file-provider-jan-2026`)
- `backgroundColor` in `Config` has a TODO and returns a hardcoded color

**Fix:** Remove dead stubs. SFTP files could stay if we plan to revisit, but should be clearly marked.

### What We Got Right

Not everything is a gap. We follow several of Mitchell's patterns correctly:

- **Callback architecture**: Zig -> C callbacks -> Swift static methods -> NotificationCenter -> SwiftUI. Same pattern as macOS.
- **`Unmanaged.passUnretained`** for userdata in C callbacks. Correct and consistent with upstream.
- **Readiness states**: `.loading`, `.error`, `.ready` -- matches upstream's state machine.
- **Guard-let + logger + graceful degradation** for error handling.
- **Config via `ghostty_config_load_string()`** instead of per-value setter calls. Clean and consistent.
- **Mutex discipline**: All terminal state access goes through `renderer_state.mutex`. No shortcuts.
- **errdefer for cleanup** in Zig code. Follows upstream patterns exactly.

---

## Known Issues and Technical Debt

Ordered by severity:

### 1. UTF-8 / Escape Sequence Splitting Across `%output`

tmux control mode splits output at arbitrary byte boundaries (confirmed from tmux source `control.c`). This can split multi-byte UTF-8 characters and escape sequences across separate `%output` messages. Currently, each `receivedOutput()` creates a fresh VT parser, so split sequences show as `?` or literal text.

We attempted a persistent VT stream fix (`fe750a2`) but it caused a freeze regression and was reverted. **Not confirmed as user-visible in normal usage** -- tmux's output buffering usually keeps sequences intact.

### 2. Monolithic `Ghostty.swift`

~2800 lines in one file. Should be split into extensions for maintainability.

### 3. Verbose Hex Logging in Production

`SSHSession.handleReceivedData()` hex-dumps every SSH packet at `.info` level. This hits disk on every byte received. Should be `.debug` or gated.

### 4. `TMUX_STATE_CHANGED` Limited Data

Only carries `window_count` and `pane_count`. No layout geometry. The viewer has the data internally but doesn't expose it through the C API. The Swift-side split tree UI can't get authoritative layout from Ghostty.

### 5. Dormant SFTP Code

5 files in `SFTP/` from the archived File Provider effort. Not harmful but adds to the codebase surface area.

### 6. `AppSettings.shared` vs `ghostty.conf`

Two config sources. Boundary is undocumented.

### 7. `captureTmuxPane()` Stub

Dead code that always returns failure. Leftover from the old gateway architecture.
