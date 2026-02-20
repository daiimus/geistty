# Agent Development Guide for Geistty

A guide for [coding agents](https://agents.md/) working on the Geistty iOS SSH terminal app.

## Project Overview

Geistty is an iOS SSH terminal app built on top of Ghostty's terminal emulator. It uses a custom fork of Ghostty with an External termio backend that enables terminal emulation without a local PTY (which iOS doesn't support).

## Development Philosophy

We're open to bleeding-edge solutions, but **favor approaches that align with the coding style and architectural patterns established by Ghostty's creator (Mitchell Hashimoto) and contributors**, as well as those of the libraries we modify (SwiftNIO-SSH). When in doubt, look at how similar problems are solved in the upstream codebases.

## Working Directives

These are behavioral rules established by the user. Follow them strictly.

1. **Agent leads architecture.** Make architectural decisions, but check in with the user before big moves.
2. **Test before deploy.** Do NOT deploy to the device and ask the user to manually test incomplete functionality. Write unit tests first. Only deploy after tests pass.
3. **Analysis first.** Don't bolt on diagnostics. Understand the problem before writing code.
4. **What would Mitchell Hashimoto do?** When stuck, study upstream macOS Ghostty patterns.
5. **Minimize fork divergence.** Ask "does this need to go in the fork, or can it live in Swift?" The less we touch the fork, the easier. See `docs/decisions/ADR-003-fork-philosophy.md`.
6. **Archive over deletion.** When removing dead code, archive it rather than delete it.
7. **Slow down.** Diagnose thoroughly, validate assumptions on device, and check with the user before making big architectural moves. Don't charge ahead without stopping to look around.
8. **Leverage tooling.** Use `idevicecrashreport`, `xcrun devicectl device copy from --domain-type systemCrashLogs`, crash log analysis, and `ci.sh test` to verify things programmatically. Don't force manual testing.
9. **Prefer simplicity.** Think about simple, standard iOS patterns before diving into complex Zig-level solutions.
10. **Reconcile issues every session.** At session start, run `gh issue list` to orient. At session end, close any issues that were resolved (with commit link + summary) and note follow-up work on any issues that were touched but not finished.

## Project Management

- **GitHub Issues** are the source of truth for bugs and features: `gh issue list --repo daiimus/geistty`
- Check active stability work: `gh issue list --repo daiimus/geistty --milestone v0.3-stable`
- When closing an issue, add a final comment summarizing what was done and linking the commit.
- **ADRs** in `docs/decisions/` capture architectural decisions that shouldn't be relitigated.
- **TODO.md** is the high-level roadmap. Actionable items are GitHub Issues.
- Labels: `p0-critical` through `p3-low`, `architecture`, `tech-debt`, `zig-fork`, `swift-only`, `ux`, `infra`
- Milestones: `v0.3-stable` (no crashes), `v0.4-polish` (UX), `v0.5-testflight` (release)

## Repository Structure

- **Main App**: `Geistty/` - Xcode project and Swift sources
- **Ghostty Fork**: `../ghostty/` - Custom ghostty with iOS support (branch: `ios-external-backend`)

## Devices

- **Icarus** = iPad Pro (primary test device)
- **Athena** = iPhone (secondary test device)
- **Dionysus** = Mac (dev machine + SSH target)

## Commands

### Building Geistty
```bash
# Quick CI build (simulator, no signing)
cd Geistty && ./ci.sh build

# Build for device
xcodebuild -project Geistty/Geistty.xcodeproj -scheme Geistty -destination "id=DEVICE_ID" -allowProvisioningUpdates

# Build for simulator
xcodebuild -project Geistty/Geistty.xcodeproj -scheme Geistty -destination "platform=iOS Simulator,name=iPhone 17 Pro"
```

### Testing
```bash
# Run all CI checks (build + lint)
cd Geistty && ./ci.sh all

# Run unit tests
cd Geistty && ./ci.sh test

# Run UI tests
cd Geistty && ./ci.sh ui-test
```

See [TESTING.md](TESTING.md) for detailed testing documentation.

### Rebuilding GhosttyKit (when Ghostty changes)
```bash
cd ../ghostty
zig build -Demit-xcframework=true -Dxcframework-target=universal

# Copy to Geistty
cp -R macos/GhosttyKit.xcframework ../geistty/Geistty/Frameworks/

# IMPORTANT: Rename module.modulemap to avoid conflicts with CSSH
for dir in ../geistty/Geistty/Frameworks/GhosttyKit.xcframework/*/Headers/; do
    [ -f "${dir}module.modulemap" ] && mv "${dir}module.modulemap" "${dir}GhosttyKit.modulemap"
done
```

## Directory Structure

```
Geistty/
├── Sources/
│   ├── App/              # App entry point, main views (2 files)
│   ├── Auth/             # SSH authentication, credentials, keychain (5 files)
│   ├── Ghostty/          # Ghostty integration, terminal surface (10 files)
│   ├── SSH/              # SSH connection management, tmux control mode (8 files)
│   ├── Terminal/         # Terminal session, view models, tmux pane UI (13 files)
│   └── UI/               # Connection list/editor, settings (4 files)
├── Frameworks/
│   └── GhosttyKit.xcframework/  # Ghostty static library
├── Resources/
│   └── Fonts/            # Bundled fonts (8 families: Departure Mono, JetBrains Mono, Fira Code, Hack, Source Code Pro, IBM Plex Mono, Inconsolata, Atkinson Hyperlegible Mono)
└── Assets.xcassets/      # App icons, colors
```

43 Swift source files across 6 directories.

## Key Files

- `Sources/Ghostty/Ghostty.swift` - SurfaceView (~2558 lines): Metal rendering, keyboard input, gestures, write callback, tmux action notifications, multi-pane observer management
- `Sources/Ghostty/Ghostty.App.swift` - App lifecycle, runtime init, action callback dispatch
- `Sources/Ghostty/Ghostty.Config.swift` - Config wrapper (create, load, finalize)
- `Sources/Ghostty/Ghostty.SearchState.swift` - Search overlay state model
- `Sources/Ghostty/Ghostty.SurfaceConfiguration.swift` - Surface init configuration
- `Sources/Ghostty/GhosttyInput.swift` - UIKit key event translation to Ghostty input
- `Sources/Ghostty/FontMapping.swift` - Centralized font name mapping (GUI <> Ghostty/CoreText)
- `Sources/Ghostty/ConfigSyncManager.swift` - ghostty.conf <> Ghostty Config synchronization
- `Sources/Ghostty/SurfaceSearchOverlay.swift` - Search bar UI overlay
- `Sources/Ghostty/TmuxSurfaceProtocol.swift` - Protocol abstraction for tmux C API queries (enables mock testing)
- `Sources/Terminal/TerminalContainerView.swift` - Terminal session UI, ViewModel, toolbar
- `Sources/Terminal/TmuxMultiPaneView.swift` - Multi-pane split rendering with divider dragging
- `Sources/Terminal/TmuxSplitView.swift` - Recursive split tree rendering
- `Sources/Terminal/TmuxWindowPickerView.swift` - tmux window tab bar
- `Sources/Terminal/CommandPaletteView.swift` - Command palette (Cmd+Shift+P) with fuzzy search
- `Sources/Terminal/KeyTableIndicatorView.swift` - Vim-style key table indicator
- `Sources/SSH/NIOSSHConnection.swift` - SwiftNIO-SSH connection with Network.framework
- `Sources/SSH/SSHSession.swift` - SSH session wrapper, tmux notification observer, data flow
- `Sources/SSH/TmuxSessionManager.swift` - Multi-pane state management, surface ownership, layout reconciliation
- `Sources/SSH/TmuxLayout.swift` - tmux layout string parser for split pane geometry
- `Sources/SSH/TmuxSplitTree.swift` - Split tree data structure (zoom, equalize, queries)
- `Sources/SSH/TmuxWireDiagnostics.swift` - Shadow parser for tmux wire protocol diagnostics
- `Sources/Auth/ConnectionProfile.swift` - Saved connection profiles
- `Sources/Auth/SSHKeyParser.swift` - SSH key format parsing (Ed25519, RSA, ECDSA)
- `Sources/Auth/SSHKeyManager.swift` - Key generation, import, Keychain storage
- `Sources/UI/SettingsView.swift` - App settings UI

## Ghostty C API Usage

Geistty uses the Ghostty C API for terminal emulation:

```swift
// Create config with settings
let cfg = ghostty_config_new()
ghostty_config_load_string(cfg, configString, configString.utf8.count)
ghostty_config_finalize(cfg)

// Create app and surface
let app = ghostty_app_new(&runtimeConfig, cfg)
let surface = ghostty_surface_new(app, &surfaceConfig)

// External backend: write data to terminal
ghostty_surface_write_output(surface, data, length)

// Live config update
ghostty_surface_update_config(surface, newConfig)
```

## Custom Ghostty APIs

The `ios-external-backend` branch adds:

1. **External Backend** (`src/termio/External.zig`)
   - Terminal emulation without PTY
   - Write callback for bidirectional I/O

2. **Config APIs** (`src/config/CApi.zig`)
   - `ghostty_config_load_file(config, path, len)` - Load config from file
   - `ghostty_config_load_string(config, str, len)` - Load config from string

3. **tmux C API** (actions + surface queries)

   **Actions:**
   - `GHOSTTY_ACTION_TMUX_STATE_CHANGED` - Action with window_count, pane_count
   - `GHOSTTY_ACTION_TMUX_EXIT` - Action when tmux control mode exits
   - `GHOSTTY_ACTION_TMUX_READY` - Action when tmux viewer is ready (capture-pane complete)

   **Pane-level queries:**
   - `ghostty_surface_tmux_pane_count()` - Get number of panes
   - `ghostty_surface_tmux_pane_ids()` - Get array of pane IDs
   - `ghostty_surface_tmux_set_active_pane(id)` - Set active pane (swaps input routing + renderer + registers observer)
   - `ghostty_surface_tmux_set_active_pane_input_only(id)` - Set active pane for input routing only (no renderer swap — used in multi-pane mode)
   - `ghostty_surface_tmux_reset_active_pane()` - Reset to default pane

   **Window-level queries:**
   - `ghostty_surface_tmux_window_count()` - Get number of tmux windows
   - `ghostty_surface_tmux_window_info(index, name_buf, name_buf_len)` - Get window ID, name, active flag
   - `ghostty_surface_tmux_window_layout(index, buf, buf_len)` - Get layout geometry string for a window
   - `ghostty_surface_tmux_active_window_id()` - Get the active window ID (-1 if none)
   - `ghostty_surface_tmux_window_focused_pane_id(index)` - Get tmux-reported focused pane for a window (-1 if unknown)

## Font Configuration

Fonts are configured via the `font-family` config option. All mapping is centralized in `Sources/Ghostty/FontMapping.swift`.

```swift
// 10 available fonts (8 bundled + 2 system)
// Bundled: Departure Mono, JetBrains Mono, Fira Code, Hack, Source Code Pro, IBM Plex Mono, Inconsolata, Atkinson Hyperlegible Mono
// System:  Menlo, Courier New
// Note: SF Mono is excluded — it requires special system font APIs, not accessible by name via CoreText

// Ghostty mapping examples
"Departure Mono" -> "Departure Mono"
"JetBrains Mono" -> "JetBrains Mono"
"Menlo"          -> "Menlo"
```

Live font updates use `ghostty_surface_update_config()` with a new config.

## Dependencies

- **Ghostty** - Terminal emulator (custom fork with External backend)
- **libxev** - Event loop (used by Ghostty internally, upstream mitchellh/libxev)
- **SwiftNIO-SSH** - SSH protocol (via daiimus/swift-nio-ssh fork with RSA support)

## tmux Integration

Geistty uses tmux Control Mode (`tmux -CC`) with Ghostty's native tmux viewer handling the protocol.

### Architecture (Feb 2026 — Ghostty Native tmux)

Ghostty's upstream code (`viewer.zig`, `control.zig`) handles all tmux control mode protocol parsing,
output routing to per-pane Terminal instances, and session restore via `capture-pane`. The Swift side
receives state change notifications and manages iOS-specific UI.

```
SSH Server → NIOSSHConnection → SSHSession.handleReceivedData()
                                        ↓
                              delegate.sshSession(didReceiveData:)
                                        ↓
                              Ghostty.Surface.writeOutput()
                                        ↓
                              [Ghostty detects DCS 1000p, creates tmux Viewer]
                                        ↓
                              viewer.zig parses %output/%begin/%end/%layout-change/etc.
                              Routes output to per-pane Terminal instances
                                        ↓
                              Action callback → TMUX_STATE_CHANGED / TMUX_EXIT / TMUX_READY
                                        ↓
                              NotificationCenter → SSHSession.observeTmuxNotifications()
                                        ↓
                              TmuxSessionManager.handleTmuxStateChanged()
                                        ↓
                              UI updates (pane count, window state)

User Input → Ghostty encodes keystroke → Termio.queueWrite()
                              [tmux viewer active?]
                                YES → viewer.sendKeys(data) → "send-keys -H -t %2 6C 73 0D\n"
                                NO  → raw bytes (non-tmux mode)
                                        ↓
                              External.queueWrite() → write_callback
                                        ↓
                              SSHSession.writeFromGhostty() → performWrite()
                                        ↓
                              NIOSSHConnection.write() → SSH → tmux stdin (as command)
```

### Key Components

| Component | Purpose |
|-----------|----------|
| `viewer.zig` (Ghostty) | State machine for tmux control mode: parses protocol, manages per-pane terminals, handles `capture-pane` restore, `sendKeys()` wraps user input |
| `control.zig` (Ghostty) | Protocol parser for `%begin/%end/%error/%output/%session-changed/%layout-change` etc. |
| `stream_handler.zig` (Ghostty) | DCS 1000p detection, creates Viewer, dispatches actions to Swift via callback |
| `Termio.zig` (Ghostty) | `queueWrite()` intercepts writes when tmux viewer is active, calls `viewer.sendKeys()` for send-keys wrapping |
| `External.zig` (Ghostty) | Pure pass-through: `queueWrite()` → `write_callback` → Swift |
| `Ghostty.swift` | SurfaceView: Metal rendering, keyboard, gestures, write callback; tmux action notifications via NotificationCenter |
| `Ghostty.App.swift` | Action callback dispatch handles `TMUX_STATE_CHANGED`/`TMUX_EXIT`/`TMUX_READY`; posts notifications |
| `SSHSession.swift` | Observes tmux notifications, forwards to TmuxSessionManager, manages connection state |
| `TmuxSessionManager` | Multi-pane state, surface ownership, layout reconciliation via window-level C API queries |
| `TmuxLayout.swift` | Parses tmux layout geometry strings for split pane UI |

### Key Design Decisions

1. **send-keys wrapping**: In tmux control mode, ALL stdin is parsed as tmux commands. User keystrokes are wrapped in `send-keys -H` commands by Ghostty's Zig-side `viewer.sendKeys()` in `Termio.queueWrite()`. All bytes are sent as uppercase hex pairs. The Swift side (`writeFromGhostty`) is a simple pass-through — no wrapping logic.
2. **No command/response**: With Ghostty handling the protocol, Swift can only do fire-and-forget commands written to stdin. `%begin/%end` responses go to Ghostty's viewer, not Swift.
3. **Session restore by Ghostty**: `viewer.zig` does `capture-pane` during its startup sequence.
4. **No DCS filter needed**: The old dual-parser conflict is gone — Ghostty is the sole tmux parser.

### Known Limitations

- `captureTmuxPane()` for search is stubbed — it relied on the old gateway command/response pattern. Use Ghostty's built-in search instead.

### Multi-Pane Architecture (Critical Context)

When tmux has multiple panes, one **primary** surface (adopted from the direct SSH surface) renders the lowest-numbered pane. Additional panes get **observer** surfaces (factory-created). Key rules:

- **Primary**: `canBecomeFirstResponder = true`, always firstResponder, full gesture suite
- **Observer**: `canBecomeFirstResponder = false`, 3 gestures only (tap, pinch-zoom, two-finger-double-tap for font reset)
- **Two `setActiveTmuxPane` variants**: `set_active_pane` swaps renderer + input routing (used for window switches). `set_active_pane_input_only` only changes input routing (used for pane focus within a window).
- **Font size is per-surface**: each Surface has independent `font_size`, `font_grid_key`, `font_metrics`. Per-pane zoom works naturally.
- **Observer registration**: Primary is registered as an observer so `fixupObservers()` corrects its renderer after `syncLayouts()` re-points it at `active_pane_id`.
- **Focus**: `selectPane()` calls `setActiveTmuxPaneInputOnly`. No guards, no hooks — clean and minimal.

### Control Mode Protocol Reference

From tmux wiki: https://github.com/tmux/tmux/wiki/Control-Mode

| Message | Format | Description |
|---------|--------|-------------|
| `%output` | `%output %pane-id data` | Pane output (octal escaped) |
| `%begin` | `%begin timestamp flags` | Command response start |
| `%end` | `%end timestamp flags` | Command response end |
| `%error` | `%error timestamp flags` | Command error |
| `%exit` | `%exit [reason]` | Control client exited |

Octal escapes: Characters <32 and `\` are encoded as `\NNN` (e.g., `\033` for ESC, `\134` for `\`)

## Development Notes

1. **No PTY on iOS** - Use External backend, not Exec backend
2. **Metal Renderer** - iOS uses Metal, not OpenGL
3. **CoreText Fonts** - Font discovery via CoreText on iOS
4. **Module Map Naming** - GhosttyKit uses `GhosttyKit.modulemap` (renamed from `module.modulemap`)

## Do NOT

- Never use `Exec` backend on iOS (no PTY support)
- Don't modify `GhosttyKit.xcframework` directly - rebuild from ghostty repo
- Don't use `print()` for logging - use `Logger` pattern
- Don't assume `log stream --device` exists - use `xcrun devicectl ... --console`

---

## Environment

| Tool | Version | Notes |
|------|---------|-------|
| Xcode | 26.2 | Build version 17C52 |
| Zig | 0.15.2 | Required for building GhosttyKit |
| Swift | 5.0 | Set in Xcode project |
| iOS deployment target | 17.0 | Minimum supported iOS version |
| macOS | Sequoia+ | For development |

## Conventions

### Current Focus

Active milestone: **v0.3-stable** — no crashes, clean lifecycle, known regressions fixed. Check what's open:
```bash
gh issue list --repo daiimus/geistty --milestone v0.3-stable
```

### Commit Messages

Use `type(scope): description` format. Types: `fix`, `feat`, `docs`, `refactor`, `test`, `chore`, `infra`. Scope is the subsystem (`ssh`, `tmux`, `ghostty`, `ci`, `ui`, etc.). Description explains the *why*, not the *what*.

Examples from this repo:
```
fix(ssh): rewrite background/reconnect flow — stop detach-client, use C1 ST reset
feat(ci): CI keychain for device builds — no more manual keychain unlocking
docs: migrate project management to GitHub Issues + ADRs
```

### Closing Issues

When closing a GitHub Issue, add a final comment that:
1. Summarizes what was done
2. Links the commit hash
3. Notes any follow-up work spawned

---

## File Provider (Archived)

**Status:** Archived January 16, 2026  
**Branch:** `archive/file-provider-jan-2026`  
**Learnings:** See `FILE_PROVIDER_LEARNINGS.md`

File Provider development was paused due to complexity outweighing benefits. The core terminal experience is the priority.

If revisiting, start fresh from the archive branch and read the learnings doc first.

---

## Architecture Decisions

| Decision | Why |
|----------|-----|
| External Backend | iOS sandboxing prevents fork/exec/PTY |
| SwiftNIO-SSH | Pure Swift, Network.framework integration, native async/await |
| Ghostty Native tmux | Ghostty's upstream viewer.zig/control.zig handles all protocol parsing, output routing, and session restore — eliminates dual-parser conflicts |
| Fire-and-forget tmux commands | With Ghostty owning the protocol, Swift can only write commands to stdin; %begin/%end responses go to Ghostty's viewer |
| send-keys wrapping | In tmux control mode, ALL stdin is tmux commands; user input wrapped in `send-keys -H` by Ghostty's Zig-side `viewer.sendKeys()` in `Termio.queueWrite()` |
| libxev (via Ghostty) | Ghostty uses upstream mitchellh/libxev internally |
| Custom module.modulemap name | Renamed to avoid Xcode module conflicts |

## Data Flow

### Regular Mode (No tmux)
```
SSH Server → NIOSSHConnection (SwiftNIO-SSH) → SSHSession → Ghostty.Surface.writeOutput()
                                                         ↓
                                                  Terminal UI (Metal)
                                                         ↓
User Input → Ghostty write callback → SSHSession → NIOSSHConnection.write()
```

### Control Mode (tmux -CC) — Ghostty Native tmux
```
SSH Server → NIOSSHConnection → SSHSession.handleReceivedData()
                                        ↓
                              Ghostty.Surface.writeOutput()
                                        ↓
                              [Ghostty detects DCS 1000p internally]
                              [viewer.zig state machine activates]
                                        ↓
                              control.zig parses %output/%begin/%end/etc.
                              viewer.zig routes output to per-pane Terminal
                                        ↓
                              Action: TMUX_STATE_CHANGED → NotificationCenter
                                        ↓
                              SSHSession → TmuxSessionManager (UI state updates)
                                        ↓
                              Terminal UI (Metal)
                                        ↓
User Input → Ghostty encodes → Termio.queueWrite()
                              [tmux viewer active?]
                                YES → viewer.sendKeys(data) → "send-keys -H -t %2 6C 73 0D\n"
                                NO  → raw bytes (non-tmux mode)
                                        ↓
                              External.queueWrite() → write_callback
                                        ↓
                              SSHSession.writeFromGhostty() → performWrite()
                                        ↓
                              NIOSSHConnection.write() → SSH → tmux stdin (as command)
```

Note: Ghostty is the sole tmux protocol parser and handles send-keys wrapping
on the Zig side. No DCS filter or Swift-side wrapping is needed.

## Common Pitfalls

- `log stream --device` doesn't exist - use `xcrun devicectl device process launch --console`
- Ghostty alternate screen has 0 scrollback (`Terminal.zig:2631`) - this is correct behavior, not a bug
- Module map conflicts: GhosttyKit must use `GhosttyKit.modulemap` not `module.modulemap`
- Device IDs change between CoreDevice UUID and UDID formats - use `xcrun devicectl list devices`

## Roadmap & Tasks

See `TODO.md` for the high-level roadmap. Active bugs and features are tracked as [GitHub Issues](https://github.com/daiimus/geistty/issues). Architectural decisions are documented in `docs/decisions/`.

## Debugging

### Logging Pattern
Use Swift's unified `Logger` with subsystem `com.geistty`:

```swift
import os
private let logger = Logger(subsystem: "com.geistty", category: "YourCategory")

// Usage
logger.info("Info message")
logger.error("Error: \(error.localizedDescription)")
logger.debug("Debug details: \(someValue)")
```

Existing categories: `Ghostty`, `Terminal`, `NIOSSHConnection`, `SSHSession`, `SSHKey`, `Credentials`, `Keychain`

### SwiftNIO-SSH Debugging

SwiftNIO-SSH provides structured logging via SwiftLog. For protocol-level debugging:

```swift
// Enable verbose logging in NIOSSHConnection
// Logs go to os.Logger category "NIOSSHConnection"
```

Network.framework path monitoring logs use the 📡 emoji prefix for easy filtering.

### Viewing Device Logs
Stream logs from a connected device in real-time using `--console`:

```bash
# Find device ID
xcrun devicectl list devices

# Launch app with console output (streams os_log in real-time)
xcrun devicectl device process launch --device <device-id> --console com.geistty.app

# With grep filter for specific logs
xcrun devicectl device process launch --device <device-id> --console com.geistty.app 2>&1 | grep -E "(SSH|Terminal|capture)" --line-buffered

# Terminate existing, then relaunch with console
xcrun devicectl device process terminate --device <device-id> com.geistty.app 2>&1; \
  xcrun devicectl device process launch --device <device-id> --console com.geistty.app
```

Or use Console.app:
1. Connect device via USB
2. Open Console.app, select device in sidebar  
3. Filter: `subsystem:com.geistty`

### Build & Deploy Workflow
```bash
# Build for device
xcodebuild -project Geistty/Geistty.xcodeproj -scheme Geistty -destination "id=<device-id>" -allowProvisioningUpdates

# Install on device
xcrun devicectl device install app --device <device-id> /path/to/Geistty.app

# Launch app (no console)
xcrun devicectl device process launch --device <device-id> com.geistty.app

# Launch with console output (preferred for debugging)
xcrun devicectl device process launch --device <device-id> --console com.geistty.app
```

### Other Debug Tools
- Check Ghostty logs for terminal errors
- Metal frame capture in Xcode for rendering issues
- Xcode Instruments for performance profiling

## Related Repositories

- `ghostty` (daiimus/ghostty, branch: ios-external-backend)
  - External termio backend for SSH/iOS
  - C API extensions for config loading
  - tmux C API: state change actions (including TMUX_READY), pane queries, active pane switching, window queries (count, info, layout, focused pane)
  
- `swift-nio-ssh` (daiimus/swift-nio-ssh, branch: add-rsa-support)
  - Fork with RSA key support added
  - Pure Swift SSH implementation with Network.framework integration
