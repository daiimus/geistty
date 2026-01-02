# Development Roadmap

## Overview

This document tracks the development progress for the Ghostty iOS SSH Terminal project.

**Current Goal**: SSH + SSH with tmux using Ghostty as the terminal emulator.

---

## 🔥 Immediate Priorities

These are the current focus areas before continuing with other roadmap items:

### ✅ TmuxGateway Migration - COMPLETE (Dec 28, 2025)
See [Architecture: tmux Layer Alignment](#-architecture-tmux-layer-alignment--in-progress) for details.

### 🧹 Code Review Findings (Dec 28, 2025)

Comprehensive code review after TmuxGateway migration identified these items:

| Priority | Task | Effort | Status |
|----------|------|--------|--------|
| High | ~~Remove `TmuxControlClient.swift` (749 lines) - replaced by TmuxGateway~~ | Low | ✅ Done |
| High | ~~Add state enum for control mode flags → `ControlModeState`~~ | Low | ✅ Done |
| Medium | Split `TmuxSessionManager.swift` (1802 lines) into smaller components | High | 🔲 Deferred |
| Medium | ~~Fix SwiftUI AttributeGraph cycles (removed logging from view body)~~ | Medium | ✅ Done |
| Low | Migrate callback bridges to async/await in TmuxSessionManager | Medium | 🔲 |
| Low | ~~Fix SF Mono font config (removed - not accessible via CoreText)~~ | Low | ✅ Done |

**Architecture Assessment:**
- **Architecture: 8/10** - Clean separation, proper actor isolation, follows Ghostty patterns
- **Code Quality: 8/10** - Well-documented, consistent logging, state machine for control mode
- **Robustness: 8/10** - Good error handling, health monitoring, reconnect logic
- **Maintainability: 7/10** - TmuxSessionManager is large, some callback tech debt

### 🧹 Codebase Cleanup (Dec 29, 2025)

Comprehensive audit identified dead code and tech debt:

#### Dead Code Removal (Priority 1) ✅ COMPLETE
| File | Lines | Issue | Status |
|------|-------|-------|--------|
| `GhosttyAPI.swift` | 660 | Not in Xcode build, never used | ✅ Deleted |
| `SurfaceManager.swift` | 419 | Not in Xcode build, never integrated | ✅ Deleted |
| `ShakeDetector.swift` | 48 | `.onShake()` never called | ✅ Deleted |
| `SSHConnection.swift` ref | - | Dangling pbxproj reference | ✅ Removed |
| `PassthroughKeyboardTranslator` | ~10 | Defined but never instantiated | ✅ Deleted |

#### Debug Code Cleanup (Priority 2) ✅ COMPLETE
| File | Issue | Status |
|------|-------|--------|
| `SSHKeyManager.swift` | 20+ `print()` to standardError | ✅ Removed |
| `Ghostty.swift` | `NSLog("🎹 Hardware key...")` | ✅ Removed |
| `TmuxSplitView.swift` | `print("Zoom toggled...")` | ✅ In #Preview, OK |
| `ConfigSyncManager.swift` | `print()` statements | ✅ Already clean |
| `Theme.swift` | `print()` statements | ✅ Already clean |

#### Incomplete Features (Priority 3) ✅ COMPLETE
| Location | Issue | Status |
|----------|-------|--------|
| `SFTPBrowserView.swift` | Reinventing iOS Files.app | ✅ Deleted - File Provider is the right approach |
| `TerminalContainerView.swift` | Secure keyboard entry TODO | ✅ Documented - iOS sandboxes keyboard by default |
| `NIOSSHConnection.swift` | known_hosts TODO (security) | ✅ Documented TOFU model with rationale |

### 🐛 KNOWN: Multi-Pane Dimension Bug
**Symptom:** After splitting, panes don't use full available screen space.
Both panes appear undersized - neither fills its allocated area.

**Session Progress (Dec 15, 2025):**
- [x] Added `GeometryReader` to `TmuxMultiPaneView` to detect size changes
- [x] Fixed crash (integer overflow in `sizeDidChange`) with bounds guards
- [x] Wired up `shortcutDelegate` for multi-pane mode (Cmd+D, Cmd+] work)
- [x] Added `@Published primaryCellSize` to `TmuxSessionManager`
- [x] Added `onCellSizeChanged` callback to `SurfaceView` in Ghostty.swift
- [x] Wired callback to update `primaryCellSize` when surface reports cell size
- [x] Updated `TmuxMultiPaneView` to observe `sessionManager.primaryCellSize`
- [ ] **STILL BROKEN**: Panes don't use full space despite above changes

**Root Cause Investigation:**
The issue was identified as SwiftUI not being able to observe nested `@Published` properties
across different objects. We added `onCellSizeChanged` callback but the resize still isn't
triggering correctly.

**What Works:**
- Connect ✅
- Cmd+D (split) ✅  
- Cmd+] (switch panes) ✅
- Exit one pane ✅

**What's Broken:**
- Neither pane uses full available space after split

**Next Debug Steps:**
1. Check console logs for `📐 Primary cell size updated` messages
2. Verify `handleSizeChange` is being called with correct geometry
3. Check if `refresh-client -C` is actually being sent to tmux
4. Compare sent dimensions with actual available pixel space
5. May need to investigate if the issue is in `TmuxSplitTreeView` layout

**Files Modified This Session:**
- `Ghostty.swift` - Added `onCellSizeChanged` callback, `sizeDidChange` guards
- `TmuxSessionManager.swift` - Added `primaryCellSize`, wired up callbacks
- `TmuxMultiPaneView.swift` - GeometryReader, observe `primaryCellSize`

**Related Code:**
- `TmuxMultiPaneView.swift` - GeometryReader, handleSizeChange
- `Ghostty.swift` - `onCellSizeChanged` callback, `sizeDidChange()`
- `TmuxSessionManager.swift` - `primaryCellSize`, `resize(cols:rows:)`
- `TmuxSplitTreeView.swift` - Recursive split layout rendering

---

### 🔬 File Provider Analysis (Dec 29-30, 2025)

**Status:** ✅ **WORKING** (Dec 30, 2025) - Browse directories, preview files via Files.app!

#### Feature Status

| Feature | Status | Notes |
|---------|--------|-------|
| Browse directories | ✅ Working | `RemoteEnumerator.enumerateItems()` |
| View/preview files | ✅ Working | `fetchContents()` downloads to temp |
| Create folders | ✅ Implemented | `createItem()` → `mkdir()` |
| Upload files | ✅ Implemented | `createItem()` → `writeFile()` |
| Delete files/folders | ✅ Implemented | `deleteItem()` → `delete()` |
| Rename/move | ✅ Implemented | `modifyItem()` → `rename()` |
| Metadata cache | ✅ SwiftData | `CachedItem` model |
| **Sync anchors** | 🔲 → ✅ | Timestamp-based change tracking |
| **Force refresh** | 🔲 → ✅ | Always fetch fresh on browse |
| **Error handling** | 🔲 → ✅ | User-friendly error messages |
| **Thumbnails** | 🔲 Planned | `NSFileProviderThumbnailing` |
| Working Set | ✅ Fixed | Returns cached files (Dec 30 - fixed ID parsing bug) |
| Remote polling | ✅ Implemented | 5s interval for active folders |
| Offline queue | 🔲 Future | Queue changes when disconnected |
| **Syncing Paused** | ⏳ Fix Implemented | `signalErrorsResolved()` added - needs device test |

#### Phase 2: "Syncing Paused" Fix (Jan 1, 2026)

**Root Cause Analysis:**
- Files.app shows "Syncing Paused" with alert icon when **resolvable errors** persist
- Extension throws `.notAuthenticated` / `.serverUnreachable` when not connected
- These errors persist until `signalErrorResolved()` is called
- Only main app was calling this, but extension throws the errors!

**Fixes Applied:**
| Fix | Location | Description |
|-----|----------|-------------|
| Cache-first in `item(for:)` | `FileProviderExtension.swift` | Check MetadataCache before requiring server |
| Signal errors resolved | `SFTPConnectionManager` | Call `signalErrorsResolved()` after SFTP connection |
| New method | `SFTPConnectionManager.signalErrorsResolved()` | Signals `.notAuthenticated` + `.serverUnreachable` as resolved |

**Status:** All 57+ unit tests pass. **Needs device testing to verify fix.**

#### Phase 1: Essential Polish (Dec 30, 2025)

**Tasks:**
- [x] Sync anchor tracking with timestamps
- [x] Always fetch fresh data (cache as fallback only)
- [x] Better error messages for network failures
- [x] Signal enumerator after modifications
- [x] Fix WorkingSetEnumerator ID parsing (was using "sftp:" prefix, should be "conn:")

#### Fixes Applied (Dec 30, 2025)

| Fix | File | Issue |
|-----|------|-------|
| Keep observer open until SFTP completes | `FileProviderExtension.swift` | Was calling `finishEnumerating()` before fetch |
| Fix Data subscript crash | `SFTPChannel.swift` | `receiveBuffer[0]` crashed after `removeFirst()` |

**Data subscript bug:** After `Data.removeFirst()`, the startIndex may not be 0, but we were accessing `receiveBuffer[0]`. Fixed with `withUnsafeBytes` and proper `Data(...)` resets.

---

#### Previous Debug Progress (Reference)
| Step | Status |
|------|--------|
| SSH key parsing | ✅ Fixed (`readBytes()` vs `readString()` for binary) |
| SSH authentication | ✅ Working |
| SFTP subsystem request | ✅ ChannelSuccessEvent received |
| SFTP version negotiation | ✅ Version 3 negotiated |
| `channel.open()` | ✅ "SFTP channel ready!" logged |
| `realpath(".")` | ⏳ May be hanging - no log after this |
| Directory enumeration | ❌ Never reached before iOS kills extension |

#### Background: Apple's Design Assumptions

From File Provider documentation:
> "The system tracks the state of each item, distinguishing between **dataless** (exists only as metadata) and **materialized** (has content on disk) items."

This means:
- **Enumeration should return metadata only** - no network calls for content
- Content is fetched lazily via `fetchContents(for:)` when user opens a file
- The Working Set contains items of interest for Spotlight indexing

#### Future Optimizations (After Basic Pattern Works)

1. **Add metadata cache** - SwiftData for previously-seen items (faster cold starts)
2. **Background refresh** - Update cache asynchronously, call `signalEnumerator()`
3. **Skip `realpath`** - Navigate from known paths
4. **Connection warming** - Pre-establish connections from main app

#### Reference: Blink Shell (For Future Optimization)

**Repository:** https://github.com/blinksh/blink (GPL-3.0, 6.5k stars)

*Note: Blink uses libssh2 (blocking C library) + Combine, not SwiftNIO-SSH. Their architecture differs but their caching patterns are useful reference for future optimization.*

**Useful Patterns for Later:**
- `WorkingSetDatabase.swift` - SQLite for tracking synced items
- Background polling via timer for change detection
- Lazy connection establishment

---

### ✅ Architecture: tmux Layer Alignment - COMPLETE (Dec 28, 2025)

**Summary:** Migrated from @MainActor TmuxControlClient to actor-based TmuxGateway.
See [AGENTS.md](AGENTS.md#tmux-integration) for current architecture.

**Current Data Flow:**
```
SSH Server → NIOSSHConnection → SSHSession → TmuxGateway.receive()
                                                   ↓
                                        TmuxProtocolParser.parse()
                                                   ↓
                                        AsyncStream<TmuxGatewayEvent>
                                                   ↓
                              SSHSession.handleGatewayEvent() → TmuxSessionManager
                                                   ↓
                                        Ghostty.SurfaceView
```

**Completed:**

| Issue | Before | After |
|-------|--------|-------|
| Concurrency | All @MainActor | Actor isolation (TmuxGateway) |
| Write callback | Double async hop | Single-hop via gateway |
| Health state | Not observed by tmux | TmuxGateway observes health |
| Protocol parsing | Mixed in TmuxControlClient | Pure TmuxProtocolParser |
| Keyboard translation | In TmuxControlClient | Dedicated KeyboardTranslator |

#### Phase 1: Protocol Separation ✅ COMPLETE
- [x] **Extract TmuxProtocolParser** - Pure synchronous parser from TmuxControlClient
  - Created `TmuxProtocolParser.swift` with `TmuxMessage` enum
  - No async, no state machine, just `parse(Data, buffer, blockState) -> (messages, buffer, blockState)`
  - Reference: iTerm2's VT100TmuxParser pattern
- [x] **Extract KeyboardTranslator** - Kitty protocol translation utility
  - Created `KittyKeyboardTranslator.swift` with `KeyboardTranslator` protocol
  - Also includes `PassthroughKeyboardTranslator` for native Kitty support
  - TmuxControlClient now uses injected translator
- [x] **Create actor TmuxGateway** - Command queue + protocol handling
  - Created `TmuxGateway.swift` following `SFTPClient` actor pattern
  - Proper actor isolation for command queue state
  - `AsyncStream<TmuxGatewayEvent>` for output events
  - Async/await API (no callbacks)
  - Ready for ConnectionHealth integration

#### Phase 2: Integration Alignment ✅ COMPLETE
- [x] **Wire ConnectionHealth into tmux** - Pause commands when stale
  - TmuxGateway has `updateHealth()` method
  - Command queue pauses on .stale, fails on .dead
  - Resumes and flushes queued commands on .healthy
- [ ] **Single-hop write path** - Direct Ghostty → SSH channel
  - Current: `externalWriteCallback → DispatchQueue.main.async → Task @MainActor → write`
  - Target: Direct callback or AsyncChannel without main thread hop
  - Blocked: Requires SSHSession write path to be non-@MainActor
  - Note: Lower priority - current path works, just has extra latency

#### Phase 3: Lifecycle Decoupling ✅ COMPLETE
- [x] **Create SurfaceManager** - Centralized surface ownership
  - Created `SurfaceManager.swift` with `SurfaceId`, `ManagedSurface`
  - Owns all Ghostty.SurfaceView instances
  - Event-driven API (`SurfaceEvent`: created, destroyed, resize, write)
  - Surfaces can survive tmux session changes
- [ ] **Migrate TmuxSessionManager** - Map paneId → surfaceId
  - Replace direct surface ownership with SurfaceManager
  - Keep factory pattern but delegate to SurfaceManager
  - Future: enable surface reuse across reconnects

#### Phase 4: Full Migration ✅ COMPLETE (Dec 28, 2025)
SSHSession now uses TmuxGateway actor instead of TmuxControlClient.

**Changes Made:**
- Replaced `tmuxControlClient: TmuxControlClient?` with `tmuxGateway: TmuxGateway?`
- Added `gatewayEventTask: Task<Void, Never>?` for async event consumption
- New `setupTmuxGateway()` replaces `setupTmuxControlClient()`
- New `startGatewayEventLoop()` and `handleGatewayEvent()` for async/await pattern
- Removed `TmuxControlClientDelegate` extension - events via AsyncStream
- Wired `NIOSSHConnection.health` → `TmuxGateway.updateHealth()` in delegate
- TmuxSessionManager has `setupWithGateway()` method for callback-based commands
- Added helper methods `sendCommand()` and `sendCommandFireAndForget()` that abstract
  over both legacy TmuxControlClient and new TmuxGateway

**Critical Bug Fix:**
- Added DCS 1000p filter in `SSHSession.handleReceivedData()` to prevent Ghostty's internal
  tmux parser from conflicting with Swift's TmuxGateway. This was causing `GHOSTTY PANIC:
  reached unreachable code` crashes when running commands in tmux control mode.

**Data Flow (New):**
```
SSH Server → NIOSSHConnection → SSHSession → TmuxGateway.receive()
                                                   ↓
                                        TmuxProtocolParser.parse()
                                                   ↓
                                        AsyncStream<TmuxGatewayEvent>
                                                   ↓
                              handleGatewayEvent() → TmuxSessionManager
                                                   ↓
                                        Ghostty.SurfaceView
```

**Related Files:**
- `TmuxGateway.swift` (708 lines) - Actor with command queue, health observation, async/await API
- `TmuxProtocolParser.swift` (492 lines) - Pure synchronous protocol parser
- `KittyKeyboardTranslator.swift` (473 lines) - Keyboard translation (Kitty → legacy)
- `SSHSession.swift` (1257 lines) - Migration complete, DCS 1000p filter
- `TmuxSessionManager.swift` (1831 lines) - Updated with gateway support
- `TmuxControlClient.swift` (749 lines) - **LEGACY: To be removed**

---

### 🏗️ Architecture: Swift-Native SSH ✅ COMPLETE

**Migration Complete (Dec 2024):**
libssh2 has been fully replaced with SwiftNIO-SSH for pure Swift SSH networking.

| Component | Old | New |
|-----------|-----|-----|
| SSH Protocol | libssh2 (C) | SwiftNIO-SSH (Swift) |
| Networking | BSD sockets | NIOTransportServices (Network.framework) |
| Key Support | RSA, ECDSA, Ed25519 | RSA*, ECDSA, Ed25519 |

*RSA support added via [daiimus/swift-nio-ssh](https://github.com/daiimus/swift-nio-ssh) fork.

**Benefits Gained:**
- ✅ Native Swift async/await
- ✅ Network.framework integration for path monitoring
- ✅ Better iOS power management
- ✅ Swift stack traces for debugging
- ✅ No more C memory management

**Remaining Dependencies:**
| Dependency | Purpose | Notes |
|------------|---------|-------|
| GhosttyKit (Zig/C) | Terminal emulation | ~1200 lines in Ghostty.swift |
| libxev (Zig) | Event loop for Ghostty | Internal to GhosttyKit |

See [DISCONNECTION_ANALYSIS.md](DISCONNECTION_ANALYSIS.md) for connection health architecture.

---

### 1. tmux Control Mode Integration ✅ COMPLETE
- [x] Create TmuxControlClient.swift for tmux -CC protocol
- [x] Implement control message parser (%output, %begin/%end, etc.)
- [x] Add octal escape decoding for pane output
- [x] Integrate with SSHSession (two modes: legacy & control)
- [x] Control mode attachment (tmux -CC new-session)
- [x] Pane output routing to Ghostty terminal
- [x] Search via capture-pane command in control mode
- [x] Handle tmux control mode exit/reconnection
- [x] Input queueing until tmux ready (prevents dropped keystrokes)
- [x] Session restore (capture-pane on activation)
- [x] Pause mode for iOS app lifecycle
- [x] Resize handling (refresh-client -C)
- Note: Legacy mode still available but control mode is now default

### 1.5. tmux Multi-Pane Integration ✅ PHASE 1-2 COMPLETE
Comprehensive tmux integration for Ghostty-native experience across SSH + tmux + iPadOS windows.
See TMUX_INTEGRATION.md for full architecture.

#### Phase 1: Foundation ✅ COMPLETE
- [x] Data models: TmuxSession, TmuxWindow, TmuxPane (TmuxModels.swift)
- [x] TmuxSessionManager - central coordinator for state
- [x] TmuxControlClient - complete protocol coverage for all notifications:
  - [x] %window-pane-changed, %session-renamed, %sessions-changed
  - [x] %unlinked-window-add/close/renamed, %session-window-changed
  - [x] %subscription-changed for format subscriptions
- [x] Layout parsing (TmuxLayout struct with checksum validation)

#### Phase 2: Multi-Pane Support ✅ COMPLETE
- [x] Connect TmuxSessionManager to SSHSession
- [x] Multiple Ghostty surfaces (one per pane)
- [x] Split pane rendering (TmuxMultiPaneView, TmuxSplitTreeView)
- [x] Layout parsing from %layout-change messages
- [x] Per-pane output routing via %extended-output
- [x] Per-pane input via send-keys -H -t %N
- [x] Pane selection via tap gesture (hitTest-based focus)
- [x] Focus indicator (border highlight on active pane)
- [x] Input-based focus tracking (typing in pane updates focus)

#### Phase 2.5: Multi-Pane Polish ✅ COMPLETE
- [x] **Pane close handling** - Detects closed panes via layout diff, cleans up surfaces
- [x] **Pane creation handling** - Creates surfaces on-demand when new panes appear
- [x] **Transition back to single-pane** - TmuxSessionManager owns surfaces; seamless transition
- [x] **Surface ownership model** - Option A architecture: TmuxSessionManager owns ALL surfaces
- [x] **Multi-pane scrollback restore** - Proactively restore scrollback for all panes on reconnect

#### Phase 3: Multiple tmux Windows & Ghostty Keybindings 🔄 IN PROGRESS
- [x] Window list UI (TmuxWindowPickerView - horizontal tab bar)
- [x] Window switching via selectWindow command
- [x] Per-window split tree tracking (windowSplitTrees dictionary)
- [x] Window close support via swipe gesture
- [x] **Ghostty macOS Keybindings** - Full hardware keyboard support:
  - [x] ShortcutAction enum matching Ghostty actions
  - [x] ShortcutDelegate protocol for routing
  - [x] pressesBegan handler for Cmd+key shortcuts
  - [x] Split management: Cmd+D (right), Cmd+Shift+D (down)
  - [x] Split navigation: Cmd+[ / ], Cmd+Option+Arrows
  - [x] Tab/Window: Cmd+T, Cmd+1-9, Cmd+Shift+[/], Cmd+W variants
  - [x] Split zoom: Cmd+Shift+Enter, Cmd+Ctrl+= (equalize)
- [x] Handle %window-add/%window-close notifications
- [x] Window switching with layout query & surface pre-creation
- [ ] Window rename support (handler exists, UI may need work)

#### Phase 3.5: Disconnection & Error Handling ✅ COMPLETE
Handle SSH disconnection gracefully instead of frozen screen.

**Implemented:**
- [x] Detect SSH connection drop (socket error, EOF, timeout)
- [x] Show `DisconnectedPaneOverlay` with orange banner on affected pane
- [x] Preserve scrollback/history - user can still scroll and copy
- [x] Pane close via Cmd+W or swipe gesture
- [x] Handle tmux %exit notification (tmux session ended on server)
- [x] Reconnect via Cmd+R shortcut
- [x] Window rename via Cmd+Shift+R, double-tap, or context menu
- [x] Display disconnect reason in overlay
- [x] Auto-reconnect on app resume (credentials stored in memory, never persisted)

**Auto-Reconnect Behavior:**
- On app wake: Check if connection is alive
- If dead + credentials stored → Auto-reconnect (up to 3 attempts, 2s delay)
- Re-attach to existing tmux session seamlessly
- User sees brief reconnecting state, then terminal resumes
- Credentials cleared on explicit disconnect (Cmd+W)

**UX Flow:**
1. Connection drops → Pane shows "Disconnected" overlay (orange banner)
2. User can still scroll/copy from disconnected pane
3. User can close disconnected pane via Cmd+W or swipe
4. Cmd+R to manually reconnect at any time
5. On app resume: auto-reconnect if credentials available

**Implementation Notes:**
- SSHSession stores credentials in memory (storedPassword/storedProfile/storedCredential)
- Auto-reconnect on appDidBecomeActive() with retry logic (3 attempts, 2s delay)
- TmuxControlClient handles `%exit` notification → delegate callback
- DisconnectedPaneOverlay provides visual feedback and Reconnect button
- Credentials cleared on explicit disconnect to prevent unwanted auto-reconnect

#### Phase 4: iPadOS Window Integration 🔲 FUTURE
- [ ] Each pane as native iPadOS Scene
- [ ] Window management via UISceneSession
- [ ] Window title from tmux pane/window name
- [ ] Create/close windows maps to tmux split/kill-pane

#### Phase 5: Unified Tab Bar & Multiple SSH Connections 🔲 FUTURE
Safari-style pull-down tab bar unifying all sessions, connections, and windows.

**Architecture:**
- [ ] ConnectionManager - Track multiple SSHSession instances
- [ ] UnifiedTab model - Flatten tmux windows across all SSH connections
- [ ] Each tab = one tmux window (or non-tmux SSH connection)
- [ ] Visual grouping by SSH connection (color dot or icon)

**UI/UX:**
- [ ] Safari-style pull-down gesture to reveal tab bar
- [ ] Tab bar hidden by default (minimal UI, maximum terminal)
- [ ] Auto-peek on navigation (Cmd+T, Cmd+Shift+], window switch)
- [ ] Tab shows: connection name, window name, pane count badge
- [ ] Swipe between tabs
- [ ] Long-press for tab options (close, rename, move)

**Multi-Connection Support:**
- [ ] Background SSH connections (keep alive while inactive)
- [ ] Connection status indicator per tab
- [ ] Quick-switch between connections
- [ ] New connection via Cmd+N or "+" button

**Keyboard Shortcuts:**
- [ ] Cmd+T - New tab (tmux window in current connection)
- [ ] Cmd+N - New connection
- [ ] Cmd+1-9 - Switch to tab N (across all connections)
- [ ] Cmd+Shift+[/] - Previous/next tab

#### Phase 6: Seamless Reconnection & State Persistence ✅ MOSTLY COMPLETE
iOS aggressively suspends apps and drops network connections. tmux handles persistence on the server side; we handle it gracefully on the client.

**Connection Resilience: ✅ COMPLETE**
- [x] Detect SSH connection drop (socket error, timeout, EOF)
- [x] Auto-reconnect in background when app becomes active
- [x] Re-attach to existing tmux session seamlessly
- [x] Queue user input during reconnection (don't lose keystrokes) - via pendingInputQueue
- [x] Visual indicator during reconnect (DisconnectedPaneOverlay shows "Reconnecting...")
- [x] Retry logic (3 attempts, 2s delay between attempts)

**State Capture & Restore: ✅ COMPLETE**
- [x] On app suspend: Pause mode active (tmux auto-pauses after timeout)
- [x] On app resume: Reconnect SSH, re-attach tmux, restore view state
- [x] capture-pane to restore visible content immediately
- [x] Scrollback restoration via capture-pane -p -S -

**iOS Lifecycle Handling: 🔄 PARTIAL**
- [x] App lifecycle observers (willResignActive/didBecomeActive)
- [x] Credentials stored in memory for auto-reconnect
- [ ] Background task for graceful disconnect (future)
- [ ] Save connection state to UserDefaults/Keychain (future)
- [ ] Handle network transitions (WiFi ↔ cellular) (future)

**User Experience Achieved:**
- User closes iPad, opens hours later
- App auto-reconnects on resume
- tmux session re-attaches automatically
- Terminal looks exactly as they left it
- Manual reconnection rarely needed

### 2. Streamline Debugging Across Repos
- [x] Update `../ghostty/AGENTS.md` with `--console` debugging pattern
- [x] Update `../libxev-ios/AGENTS.md` with `--console` debugging pattern
- [x] Ensure consistent Logger pattern across all Swift code
- [ ] Document how to trace issues across repo boundaries

### 3. Code Cleanup (Spaghetti Reduction)
- [x] **SSHSession.swift** - Refactored with TmuxMode enum and TmuxControlClient
- [ ] **Ghostty.swift** - Review and simplify Surface class
- [ ] **TerminalContainerView.swift** - Extract search UI into separate view
- [x] **NIOSSHConnection.swift** - Error handling updated with async write + health tracking
- [x] Remove unused code and commented-out experiments (Dec 2025 cleanup)
- [ ] Consolidate duplicate logic (font mapping in 3 places)
- [ ] Add missing documentation comments
- [ ] Review and standardize naming conventions

### 4. Code Analysis Findings (Dec 2025)

#### High Priority - TODO
- [ ] Remove `TmuxControlClient.swift` (749 lines) - superseded by TmuxGateway actor
- [ ] Consolidate `controlModeActive`/`controlModeDataRouting` flags into `ControlModeState` enum

#### High Priority - DONE
- [x] Remove legacy tmux capture code (~100 lines) - superseded by TmuxControlClient
- [x] Remove unused `GhosttyTerminalView.swift` (121 lines) - superseded by RawTerminalViewController
- [x] Remove unused `GeisttyTerminalView` struct - never instantiated
- [x] Remove `TmuxMode.legacy` case - control mode is now default

#### Medium Priority - TODO
- [ ] Consolidate font mapping (currently defined in 3 places):
  - `Ghostty.swift` mapFontFamily()
  - `Ghostty.swift` reverseMapFontFamily()  
  - `SettingsView.swift` fontFamilies array
- [ ] Extract common connection logic in SSHSession (3 similar connect methods)
- [ ] Split `TerminalContainerView.swift` (1700+ lines) into multiple files
- [ ] Remove `TmuxControlClient.parsePaneState()` - never called, PaneState always nil
- [ ] Replace print() with Logger in ConfigSyncManager.swift and Theme.swift

#### Low Priority - Nice to Have
- [ ] Extract magic numbers to constants (timeouts, marker strings)
- [ ] Implement or remove TODO comments in production code
- [x] ~~Clarify SFTP status~~ - SFTP browser implemented (Dec 29, 2025)

---

## 🎯 V1 Completion Checklist

For a solid v1 release targeting **SSH + SSH with tmux**:

### Core Functionality ✅
- [x] SSH connection via SwiftNIO-SSH (migrated from libssh2)
- [x] Ghostty External backend for PTY-less terminal emulation
- [x] Full terminal emulation (vim, htop, less, etc. all work)
- [x] Hardware keyboard support with modifiers
- [x] Copy/paste support
- [x] Scrollback buffer

### tmux Integration ✅
- [x] tmux Control Mode (-CC) protocol parsing
- [x] Multi-pane layout from `%layout-change`
- [x] Per-pane output routing via `%extended-output`
- [x] Per-pane input via `send-keys -H -t %N`
- [x] Focus tracking (tap + input)
- [x] Independent Ghostty surfaces per pane

### V1 Completion ✅ COMPLETE
- [x] **Pane close handling** - Cleanup surfaces when panes are killed (detects via layout diff)
- [x] **Transition to single-pane** - Returns to single surface mode when splits closed
- [x] **Connection status** - ConnectionStatus enum with .connecting/.connected/.disconnected/.error states

### V2 Features (Post-V1) 🔲
- [ ] Multiple tmux windows - Window list UI and switching
- [ ] iPadOS Scene integration - Each pane as native window
- [x] SFTP protocol implementation (Dec 29, 2025) - SFTPChannel + SFTPClient
- [ ] SFTP File Provider Extension - Files.app integration with per-server toggle
- [ ] In-app file browser with iOS-native file handling (Quick Look, Share, Open In)
- [ ] Secure Enclave key storage
- [ ] Enhanced connecting indicator in terminal view

---

## ✅ Phase 0: Environment Setup — COMPLETE

- [x] Install Xcode 15+
- [x] Install Homebrew
- [x] Install Zig (for building libghostty)
- [x] Clone Ghostty repository
- [x] Set up development environment

---

## ✅ Phase 1: Build libghostty xcframework — COMPLETE

- [x] Study Ghostty build system
- [x] Build xcframework for iOS (arm64, arm64-simulator)
- [x] Extract and configure C headers
- [x] Create GhosttyKit.xcframework with proper structure

**Deliverable**: `GhosttyKit.xcframework` ready for import ✅

---

## ✅ Phase 2: Minimal iOS App Shell — COMPLETE

- [x] Create Xcode project (SwiftUI lifecycle, iOS 16+)
- [x] Import GhosttyKit.xcframework
- [x] Create Swift wrapper for ghostty C API (`Ghostty.swift`)
  - [x] `Ghostty.Config` wrapper
  - [x] `Ghostty.App` wrapper  
  - [x] `Ghostty.SurfaceView` (UIView subclass)
  - [x] `Ghostty.SurfaceConfiguration` for External backend
- [x] Create GhosttySurfaceView (UIViewRepresentable bridge)
- [x] Verify terminal rendering works

**Deliverable**: iOS app that displays ghostty-rendered terminal ✅

---

## ✅ Phase 3: SSH Connection Layer — COMPLETE

- [x] ~~Integrate libssh2 via SPM (CSSH package)~~ → Migrated to SwiftNIO-SSH
- [x] Implement NIOSSHConnection class (replaced SSHConnection)
  - [x] Socket connection
  - [x] SSH handshake
  - [x] Password authentication
  - [x] Channel open / PTY request
  - [x] Non-blocking read loop
- [x] Implement SSHSession wrapper with delegate pattern

**Deliverable**: Can connect, authenticate, and open PTY channel ✅

---

## ✅ Phase 4: I/O Bridge Integration — COMPLETE

- [x] Connect SSH channel output → ghostty surface (`feedData()`)
- [x] Connect ghostty input → SSH channel (`onWrite` callback)
- [x] Implement keyboard input via UIKeyInput protocol
  - [x] `insertText(_:)` for character input
  - [x] `deleteBackward()` for backspace
  - [x] `canBecomeFirstResponder` for keyboard activation
- [x] Fix IOSurfaceLayer sizing (iOS sublayer quirk)
- [x] Fix surface lifecycle (close/free without crash)
- [x] Terminal resize handling (basic)

**Deliverable**: Functional SSH terminal session ✅

---

## 🔄 Phase 5: iOS UX Polish — IN PROGRESS

### Keyboard & Input
- [x] **Hardware keyboard support**
  - [x] Arrow keys (up/down/left/right)
  - [x] Modifier keys (Ctrl+C, Ctrl+D, etc.)
  - [x] Control character handling for external apps (tmux, vim, blightmud)
  - [x] Function keys (F1-F12)
  - [x] Home/End/PageUp/PageDown
  - [x] UIKey → macOS keycode mapping
  - [x] Key repeat support (timer-based, 0.4s delay, 20/sec rate)
- [x] **Keyboard accessory bar**
  - [x] Esc button
  - [x] Ctrl toggle button (sticky modifier)
  - [x] Arrow key buttons
- [ ] **Additional keyboard improvements**
  - [x] Alt/Option modifier support (for vim, emacs) ✅ macos-option-as-alt = true
  - [ ] Tab key button in accessory bar
  - [ ] Common symbols bar (~, |, `, etc.)
  - [x] Cmd+C/V for copy/paste (intercept and handle) ✅
  - [x] Cmd+A for select all ✅
  - [x] Cmd+K for clear screen ✅
  - [x] Cmd+W for disconnect ✅
  - [x] Font size shortcuts (Cmd+0/+/-) ✅
  - [ ] Keyboard shortcuts help overlay
  - [ ] Key repeat delay/rate as configurable settings
- [x] **Proper Ghostty keyboard API integration** ✅ COMPLETE
  - [x] Refactor to use ghostty_surface_key() instead of raw byte sending
  - [x] Build KeyEvent struct matching macOS implementation (GhosttyInput.swift)
  - [x] Map UIKey to Ghostty key codes (UIKeyboardHIDUsage → macOS keycodes)
  - [x] Support all modifiers (Shift, Ctrl, Alt, Super, Caps, Num)
  - [x] Handle key repeat properly (press/repeat/release actions)
  - [x] Enable Ghostty keybinding system

### Terminal Features
- [x] **Copy/paste support**
  - [x] Text selection (long press + drag using Ghostty mouse API)
  - [x] Mouse/trackpad click-drag selection (instant response)
  - [x] Copy to clipboard (uses ghostty_surface_read_selection)
  - [x] Paste from clipboard (via toolbar menu and system paste)
  - [x] System edit menu integration (canPerformAction)
- [x] **Terminal resize on keyboard show/hide**
  - [x] Keyboard notification observers
  - [x] Animated resize with bottom padding
- [x] **Terminal environment auto-setup**
  - [x] xterm-ghostty preferred (falls back to xterm-256color)
  - [x] COLORTERM=truecolor injection for server compatibility
- [x] **Scrollback support**
  - [x] Touch scrolling with adaptive velocity
  - [x] Trackpad/mouse wheel support
  - [x] Momentum scrolling
  - [x] Scroll position indicator
  - [ ] Fine-tune scroll sensitivity settings
- [x] **tmux support**
  - [x] Ctrl+B prefix key handling
  - [x] Control character sequences working
  - [x] Bracketed paste mode (paste_from_clipboard binding action)
  - [x] All escape sequences verified working
  - [x] Window/pane navigation tested
  - [x] Auto-attach to tmux session on connect (per-connection setting)
  - [x] Custom tmux session name support

### Connection Management
- [x] **Saved connections**
  - [x] Connection profile model (host, port, username, auth method)
  - [x] UserDefaults persistence (ConnectionProfileManager)
  - [x] Connection list UI with add/edit/delete
  - [x] Quick Connect flow
  - [x] Favorites and recents tracking
  - [x] iCloud sync for connection profiles (code ready, needs paid developer account for entitlement)
- [x] **SSH Key Authentication**
  - [x] Generate Ed25519 keys in-app (SSHKeyManager)
  - [x] Generate RSA keys (2048/4096 bit options)
  - [x] Keychain storage for keys
  - [x] Key management UI (SSHKeyListView)
  - [x] View/copy public key
  - [x] Import keys from Files app (.pem, .key files)
  - [ ] Secure Enclave storage (planned, needs additional work)
- [x] **Credential Provider System**
  - [x] KeychainCredentialProvider (saved passwords)
  - [x] SSHKeyCredentialProvider (key-based auth)
  - [x] Unified CredentialManager for multiple sources
  - [x] Password entry at connection time (saved to Keychain)
  - ~~1Password/LastPass integration~~ (Not possible on iOS - their SSH integration uses desktop SSH Agent, not available via iOS APIs. Export keys from password manager and import into Geistty via Files app)
- [ ] **Connection status indicators** ⭐ MEDIUM PRIORITY
- [x] **Handle remote disconnect**
  - [x] Detect SSH channel EOF/close
  - [x] Show disconnect via navigation
  - [x] Auto-navigate back to connection screen

### iPad-Specific
- [x] Split View support (works out of box with SwiftUI)
- [x] Stage Manager support (works out of box with SwiftUI)
- [x] External display mirroring (automatic via WindowGroup)
- [x] UISupportsMultipleScenes enabled
- [x] **iPadOS menu bar integration**
  - [x] Native menu bar with File/Edit/View/Terminal menus
  - [x] Keyboard shortcuts displayed in menu items
  - [x] Embraces native iOS keyboard show/hide behavior

### Settings
- [x] **Font family selection**
  - [x] Font picker UI (Departure Mono, SF Mono, Menlo, Courier New)
  - [x] Live font updates (ghostty_surface_update_config)
  - [x] ghostty_config_load_string API for config loading
  - [x] Font preference persistence (UserDefaults)
- [x] **Font size adjustment**
  - [x] Slider control in Settings (8-32pt range)
  - [x] Live font size updates
  - [x] Reset to default button
- [x] **Theme/color scheme selection**
  - [x] 18 bundled Ghostty themes (light & dark)
  - [x] Theme picker with color palette preview
  - [x] Live theme updates
  - [x] Theme persistence (UserDefaults)
- [x] **Text rendering quality**
  - [x] Font thickening toggle for Retina displays
  - [x] Freetype hinting (light) for optimal clarity
  - [x] Proper DPI/contentScaleFactor handling throughout
- [ ] Terminal type (xterm-256color, etc.)

---

## 📋 Phase 6: Session Management & Navigation — IN PROGRESS

The goal is to complete the session lifecycle: start screen → connect → use terminal → disconnect/switch → back to start. Leverage native Ghostty and iPadOS window management.

### Session Lifecycle
- [ ] **New Connection** (Cmd+N) - Open new connection sheet from terminal
- [ ] **Quick Connect** (Cmd+O) - Quick connect dialog from anywhere
- [ ] **Close/Disconnect** (Cmd+W) - Clean session teardown
- [ ] **Reconnect** - Reconnect to same host after disconnect
- [ ] **Back to Start** - Navigate from terminal back to connection list
- [ ] **Session switching** - Switch between active sessions

### Window Management (iPadOS + Ghostty)
- [ ] **iPadOS Scenes** - Multiple independent terminal windows
  - [ ] UISceneDelegate implementation
  - [ ] Scene state restoration
  - [ ] Each scene = independent SSH session
- [ ] **Stage Manager integration** - Multiple windows side by side
- [ ] **External display** - Dedicated terminal on second screen
- [ ] **Ghostty splits** (stretch) - Multiple surfaces in one window

### Connection State
- [ ] **Connection status indicators** - Visual state (connecting/connected/disconnected)
- [ ] **Session persistence** - Remember open sessions across app restart
- [ ] **Auto-reconnect option** - Reconnect on network recovery
- [ ] **Keep-alive pings** - Prevent idle disconnect

### Menu Structure (Ghostty macOS style)

**File Menu:**
- [ ] New Connection (Cmd+N)
- [ ] Quick Connect (Cmd+O)
- [ ] Close/Disconnect (Cmd+W)

**Edit Menu:**
- [x] Copy (Cmd+C)
- [x] Paste (Cmd+V)
- [x] Select All (Cmd+A)
- [ ] Find... (Cmd+F) - stretch goal

**View Menu:**
- [x] Reset Font Size (Cmd+0)
- [x] Increase Font Size (Cmd++)
- [x] Decrease Font Size (Cmd+-)
- [ ] Toggle Full Screen (hides status bar)

**Terminal Menu:**
- [x] Clear Screen (Cmd+K)
- [ ] Reset Terminal (Cmd+Shift+R)
- [ ] Terminal Inspector (debug info)

**Connection Menu:**
- [ ] Reconnect
- [ ] Duplicate Session
- [ ] SSH Key Manager
- [ ] Connection Profiles

---

## 📋 Phase 7: Configuration System — IN PROGRESS

Config file (`ghostty.conf`) is now the source of truth.

**Completed:**
- [x] Config file as source of truth
- [x] Reload config from file (Cmd+Shift+,)
- [x] Theme selector writes inline colors to config
- [x] Settings UI adapts to theme (preferredColorScheme)
- [x] Font/cursor/theme changes write to config file
- [x] In-app config editor

**Remaining:**
- [ ] Syntax validation & error reporting
- [ ] Config import/export
- [ ] Theme import (.conf format)

---

## 📋 Phase 8: Advanced Features — PLANNED

- [ ] **Secure Enclave keys** (hardware-backed SSH keys)
- [x] **Multiple sessions** (native iOS multi-window via WindowGroup + UISupportsMultipleScenes)
- [ ] **SFTP / Remote Files** ⭐ HIGH VALUE
  - [x] SFTPChannel protocol implementation (Dec 29, 2025)
  - [x] SFTPClient async API (kept for File Provider)
  - [x] ~~In-App Browser~~ (Removed Dec 29, 2025 - iOS Files.app does this better)
  - [ ] **File Provider Extension** (The Right Way™) - See [Analysis](#-file-provider-analysis-dec-29-2025)
    - [x] NSFileProviderReplicatedExtension skeleton
    - [x] SSH/SFTP connection working in extension
    - [ ] **Metadata cache** (SQLite, like Blink Shell's WorkingSetDatabase)
    - [ ] **Fast enumeration** (return cached immediately, refresh async)
    - [ ] **Background polling** + `signalEnumerator()` for changes
    - [ ] Skip `realpath(".")` for File Provider use case
    - [ ] Per-server "Show in Files.app" toggle in connection settings
    - [ ] Offline cache with sync badges
    - [ ] Thumbnail generation for images/videos
    - [ ] Background upload/download support
- [ ] **Mosh support** (stretch goal)
- [ ] **Snippet library** (saved commands)
- [ ] **Port forwarding**
- [ ] **Selection visual feedback** (fade-out after copy-on-select)
  - [ ] Show selection highlight during drag
  - [ ] Animated fade-out after release to indicate copy succeeded
  - [ ] Would require Ghostty-side changes to keep selection visible briefly

---

## 📋 Phase 9: Release Preparation — IN PROGRESS

### Apple Developer Setup
- [ ] Enroll in Apple Developer Program ($99/year)
- [ ] Create App ID (com.geistty.app)
- [ ] Enable iCloud entitlement (for connection sync)
- [ ] Create App Store Connect listing

### TestFlight Beta
- [x] TestFlight distribution guide (TESTFLIGHT.md)
- [ ] Archive release build
- [ ] Upload to App Store Connect
- [ ] Internal testing (your devices)
- [ ] External beta testers
- [ ] Collect crash reports & feedback

### App Store Assets
- [x] App icon (1024x1024) - light/dark variants
- [x] Launch screen (UILaunchScreen in Info.plist)
- [x] App Store metadata guide (APP_STORE.md)
- [ ] Screenshots (iPad Pro, iPhone) - guide in APP_STORE.md
- [ ] App preview video (optional)
- [x] App description
- [x] Keywords for search
- [x] Privacy policy (PRIVACY.md)
- [ ] Support URL (GitHub repo)

### Customer-Facing Portal (GitHub Pages)
- [ ] Set up GitHub Pages with vanity domain
- [ ] Privacy policy page (from PRIVACY.md)
- [ ] Support/FAQ page
- [ ] App landing page with features
- [ ] Link from App Store listing

### Compliance
- [x] Export compliance (ITSAppUsesNonExemptEncryption=NO - exempt)
- [x] Privacy policy (PRIVACY.md)
- [ ] Age rating questionnaire

### Polish
- [x] Launch screen / splash
- [ ] Onboarding flow (first launch)
- [ ] Accessibility (VoiceOver, Dynamic Type)
- [ ] Localization (English first, others later)
- [ ] Performance profiling
- [ ] Memory leak check

### Submission
- [ ] App Review Guidelines compliance check
- [ ] Submit for review
- [ ] Respond to any rejections
- [ ] Release to App Store

---

## Milestones Summary

| Phase | Goal | Status |
|-------|------|--------|
| 0 | Environment setup | ✅ Complete |
| 1 | Build xcframework | ✅ Complete |
| 2 | Minimal app shell | ✅ Complete |
| 3 | SSH connection | ✅ Complete |
| 4 | I/O bridge | ✅ Complete |
| 5 | iOS UX polish | 🔄 In Progress |
| 6 | Advanced features | 📋 Planned |
| 7 | Release prep | 📋 Planned |

**Current Status**: Working SSH terminal with Ghostty rendering. Ready for UX polish.

---

## Known Issues

1. **NoHomeDir warning** - Ghostty config looks for home directory (harmless on iOS)
2. **Scale factor** - May need adjustment for Retina displays
3. **Keyboard dismiss** - No explicit way to dismiss keyboard currently
4. **Simulator performance** - Rendering may be slower on iOS Simulator vs real device (Metal emulation overhead). Test on physical device for accurate performance assessment.
5. ~~**Disconnect not detected**~~ - Fixed: Now handles EOF/channel close and navigates back
6. **Scroll sensitivity** - Touch scrolling may need per-user tuning (currently adaptive velocity)
7. ~~**SwiftUI AttributeGraph cycles**~~ - Fixed: Removed logging from view body methods
8. **IOSurfaceLayer size mismatch** - `surface is wrong size for layer, discarding` during rapid resizing. Cosmetic, indicates resize debouncing could be tighter.
9. ~~**SF Mono font fallback**~~ - Fixed: Removed SF Mono from options (not accessible via CoreText, it's a system UI font). Default changed to Menlo.

---

## 🎯 Low-Hanging Fruit (Quick Wins)

These are small improvements that would have big impact:

### Input/Keyboard
- [x] Add Tab key to accessory bar (very common in terminal)
- [x] Add pipe `|` and tilde `~` buttons (hard to type on iOS keyboard)
- [x] Haptic feedback on Ctrl toggle activation
- [x] Visual indicator when Ctrl is active (pulsing orange border)

### Terminal UX
- [x] Double-tap to select word
- [x] Triple-tap to select line
- [x] Pinch to zoom (font size)
- [x] Shake to clear screen (send Ctrl+L)
- [x] Two-finger double-tap to reset font size
- [x] Font size buttons in toolbar (A+ / A-)

### Connection UX
- [ ] Connection timeout setting
- [x] Retry connection button on disconnect
- [ ] "Keep alive" ping option
- [x] Show connection duration in header

### Polish
- [ ] App icon (currently default)
- [ ] Launch screen
- [ ] Onboarding flow for first connection
- [x] Keyboard shortcut discoverability (Cmd+hold menu on iPad)
- [x] Keyboard shortcuts (Cmd+K clear, Cmd+N new, Cmd+O quick connect, Cmd++/- zoom)
- [x] Dismiss keyboard button in toolbar
- [x] Context menu: duplicate connection, copy host/connection string

---

## 🚀 AI Coding Tools Support (Cursor/Claude Code/Aider)

Features that would make Geistty essential for developers using AI terminals:

### Large Text Handling
- [ ] **Paste large code blocks** - Handle multi-KB pastes without lag/truncation
- [ ] **Bracketed paste mode** - Proper escape sequences for pasting into vim/editors
- [ ] **Streaming output optimization** - Handle rapid AI output without flicker

### Selection & Copying
- [ ] **Select visible output** - Quick select last command output
- [ ] **Select by regex/pattern** - Find and select code blocks
- [ ] **Copy without line numbers** - Strip prompt prefixes when copying
- [ ] **Copy as markdown** - Preserve code block formatting

### Multi-Line Input
- [ ] **Multi-line paste handling** - Don't execute each line separately
- [ ] **Here-doc support** - Paste multi-line strings properly
- [ ] **Input history** - Browse previous long commands

### URL & Path Handling
- [ ] **Clickable URLs** - Open links in browser
- [ ] **Clickable file paths** - Quick actions (copy, open in Files)
- [ ] **Error line detection** - Jump to file:line from stack traces

### Session Management
- [ ] **Session persistence** - Reconnect to tmux/screen automatically
- [ ] **Multiple panes** - Split view for parallel AI sessions
- [ ] **Session recording** - Save terminal session to file
- [ ] **Quick switch** - Fast switching between multiple SSH connections

### Search & Navigation
- [x] **Search in scrollback** - Find text in terminal history (Cmd+F) ✅
  - [x] Basic search UI with search bar
  - [x] Ghostty sync search API integration (ghostty_surface_search_start/next/prev/end)
  - [x] Match count display and navigation
  - [x] Search bar scroll/drag/dismiss gestures
  - [x] Works on primary screen (non-tmux sessions)
  - [x] **Alt Screen indicator** - Shows when on alternate screen (tmux/vim) ✅
  - [x] **tmux scrollback search** - Search tmux's internal scrollback ✅
    - Analysis complete: See `TMUX_SEARCH_ANALYSIS.md` for architecture details
    - Root cause: tmux has its own scrollback buffer separate from terminal's
    - Solution: Use `tmux capture-pane -p -S -` to query tmux's scrollback
    - [x] Add `captureTmuxPane()` to SSHSession
    - [x] Add tmux search mode to SearchState
    - [x] Search captured pane text locally in Swift
    - [x] Navigate results via tmux copy-mode commands
    - [x] "tmux" badge in search bar when in tmux mode
  - [ ] Connection option: "Use terminal scrollback (disable tmux alternate screen)"
  - [ ] Auto-scroll to match position (tmux mode)
- [ ] **Jump to prompt** - Quick navigation between command prompts
- [ ] **Semantic search** - Find by description ("that curl command")

### Debug Cleanup
- [ ] **Remove debug logging from Ghostty** - Clean up SCREEN_INIT, SCREEN_SWITCH logs
  - [ ] src/terminal/Terminal.zig - Remove std.log.err calls in switchScreen/switchScreenMode
  - [ ] src/terminal/ScreenSet.zig - Remove std.log.err call in init
  - [ ] src/apprt/embedded.zig - Remove verbose search debug logging
  - [ ] src/global.zig - Review debug logging settings for lib mode
  - [ ] Rebuild GhosttyKit xcframework after cleanup

### Developer Quality of Life
- [ ] **Syntax highlighting in output** - Detect and highlight code blocks
- [ ] **JSON/YAML pretty print** - Auto-format structured output
- [ ] **Diff highlighting** - Color git diffs properly
- [ ] **Command palette** - Quick actions via Cmd+Shift+P

### Clipboard Integration
- [ ] **Clipboard history** - Access recent copies
- [ ] **Smart paste** - Detect and handle different content types
- [ ] **Share sheet** - Share terminal output via iOS share

---

## Technical Notes

### Key Implementation Details

1. **External Backend**: Using Ghostty's `GHOSTTY_BACKEND_EXTERNAL` which is designed for SSH/serial use cases where data comes from outside rather than a local PTY.

2. **IOSurfaceLayer Sizing**: On iOS, Ghostty adds its IOSurfaceLayer as a sublayer (vs. replacing the view's layer on macOS). We must manually resize it in `layoutSubviews`.

3. **addSublayer Workaround**: Ghostty's Zig code calls `objc.sel("addSublayer")` without the colon, which doesn't match ObjC conventions. We register a runtime method to handle this.

4. **Write Callback**: The external backend uses `ghostty_write_callback_fn` to notify Swift when the terminal wants to send data (user input → SSH).
