//
//  TmuxSessionManager.swift
//  Geistty
//
//  Manages tmux session/window/pane state and coordinates with Ghostty surfaces.
//  This is the central hub for tmux integration.
//

import Foundation
import os.log
private let logger = Logger(subsystem: "com.geistty", category: "TmuxSession")

// MARK: - Connection State

/// Connection state for the tmux session
enum TmuxConnectionState: Equatable {
    /// Not connected to SSH/tmux
    case disconnected
    
    /// SSH connected, tmux control mode activating
    case connecting
    
    /// Fully connected and operational
    case connected
    
    /// Connection lost, may attempt reconnect
    case connectionLost(reason: String?)
}

/// Manages the mapping between tmux server state and Geistty UI
@MainActor
class TmuxSessionManager: ObservableObject {
    
    // MARK: - Published State
    
    /// Current attached session
    @Published private(set) var currentSession: TmuxSession?
    
    /// All known sessions on the server
    @Published private(set) var sessions: [String: TmuxSession] = [:]
    
    /// All windows in the current session
    @Published private(set) var windows: [String: TmuxWindow] = [:]
    
    /// Currently focused pane ID (empty until first layout/output event resolves it)
    @Published private(set) var focusedPaneId: String = ""
    
    /// Currently focused window ID (empty until first session-changed/layout event)
    @Published private(set) var focusedWindowId: String = ""
    
    /// Connection state (legacy bool for compatibility)
    @Published private(set) var isConnected: Bool = false
    
    /// Detailed connection state
    @Published private(set) var connectionState: TmuxConnectionState = .disconnected
    
    /// Current split tree for the focused window (for UI rendering)
    @Published private(set) var currentSplitTree: TmuxSplitTree = TmuxSplitTree()
    
    /// Split trees for each window (windowId -> tree)
    private var windowSplitTrees: [String: TmuxSplitTree] = [:]
    
    // MARK: - Surface Management
    
    /// Ghostty surfaces for each pane (paneId -> surface)
    /// TmuxSessionManager owns ALL surfaces - views just display them
    private(set) var paneSurfaces: [String: Ghostty.SurfaceView] = [:]
    
    /// The primary surface that owns the tmux viewer (C-side state).
    /// Adopted from the direct surface at connection time. Initially stored
    /// WITHOUT a paneSurfaces entry (pane ID unknown); registered under its
    /// real pane ID when handleTmuxStateChanged provides real pane IDs.
    @Published private(set) var primarySurface: Ghostty.SurfaceView?
    
    /// Protocol-typed accessor for tmux C API queries.
    /// In production, returns `primarySurface`. In tests, returns `tmuxQuerySurfaceOverride`.
    var tmuxQuerySurface: (any TmuxSurfaceProtocol)? {
        #if DEBUG
        if let override = tmuxQuerySurfaceOverride { return override }
        #endif
        return primarySurface
    }
    
    #if DEBUG
    /// Test-only override for tmux C API queries. Set this to a MockTmuxSurface
    /// to test handleTmuxStateChanged() without a real Ghostty surface.
    var tmuxQuerySurfaceOverride: (any TmuxSurfaceProtocol)?
    
    /// Test-only: populate pendingOutput for testing pending output paths
    func setPendingOutputForTesting(_ output: [String: [Data]]) {
        pendingOutput = output
    }
    
    /// Test-only: read the set of pane IDs deferred because factory wasn't ready
    var pendingSurfaceCreationForTesting: Set<String> {
        pendingSurfaceCreation
    }
    
    /// Test-only: read the commands queued while viewer was not ready
    var pendingCommandsForTesting: [String] {
        pendingCommands
    }
    
    /// Test-only: tracks the order in which surfaces are closed during teardown.
    /// Each entry is (paneId, isObserver). Observers should always come before primaries.
    var teardownOrderForTesting: [(paneId: String, isObserver: Bool)] = []
    
    // ARCHIVED: Session 127 — needsReattach + needsReattachForTesting removed
    // (destroy-and-recreate approach). See docs/archive/REATTACH_PRESERVED_SURFACES_FEB_2026.swift
    #endif
    
    /// Cell size from the primary surface (for calculating terminal dimensions)
    /// This is updated when the surface reports its cell size
    @Published private(set) var primaryCellSize: CGSize = .zero
    
    // MARK: - Output Buffering
    
    /// Buffer for output received before surfaces are created (pre-factory configuration)
    /// tmux sends %output immediately on attach; if the surface isn't ready yet,
    /// we buffer here and flush when the surface is created.
    private(set) var pendingOutput: [String: [Data]] = [:]
    
    /// Surface creation factory (injected before activation)
    /// This creates Ghostty surfaces with proper configuration
    private var surfaceFactory: ((String) -> Ghostty.SurfaceView?)?
    
    /// Pane IDs that need surfaces but couldn't be created because the factory
    /// wasn't configured yet. Drained by `configureSurfaceManagement()` once the
    /// factory becomes available. This handles the race where `handleTmuxStateChanged`
    /// fires before the Combine `$isConnected` sink configures the factory.
    private var pendingSurfaceCreation: Set<String> = []
    
    /// Callback to wire up surface input to SSH
    /// Called after surface is created to connect onWrite
    private var surfaceInputHandler: ((Ghostty.SurfaceView, String) -> Void)?
    
    /// Callback for resize events
    private var surfaceResizeHandler: ((Int, Int) -> Void)?
    
    /// Debounce task for resize events to prevent thrashing
    private var resizeDebounceTask: Task<Void, Never>?
    
    /// Last resize dimensions (to avoid duplicate resize commands)
    private var lastResizeCols: Int = 0
    private var lastResizeRows: Int = 0
    

    
    // MARK: - Direct Write Connection
    
    /// Write function to send data to SSH
    private var writeToSSH: ((String) -> Void)?
    
    // MARK: - Viewer Ready Gating
    
    /// Whether the Ghostty tmux viewer's startup command queue has drained.
    /// Until this is true, ALL Swift-side commands (refresh-client, select-pane,
    /// etc.) are queued rather than sent — sending them would interleave bytes
    /// on the SSH channel with the viewer's capture-pane commands, corrupting
    /// the tmux control mode protocol and causing %exit.
    ///
    /// Starts as `true` (no viewer, no gating needed). Set to `false` by
    /// `controlModeActivated()` when the viewer begins its startup sequence,
    /// then set back to `true` by `viewerBecameReady()` once `TMUX_READY` fires.
    private(set) var viewerReady: Bool = true
    
    /// Commands queued while the viewer's startup sequence is in progress.
    /// Flushed in order when `viewerBecameReady()` is called.
    private var pendingCommands: [String] = []
    
    // MARK: - Initialization
    
    init() {
        logger.info("TmuxSessionManager initialized")
    }
    
    // MARK: - Connection
    
    /// Set up the session manager with a direct write function.
    /// In native Ghostty tmux mode, commands are fire-and-forget —
    /// written to stdin where tmux processes them. Ghostty's internal
    /// tmux viewer handles all protocol parsing and state tracking.
    /// - Parameter write: Function to write raw strings to SSH stdin
    func setupWithDirectWrite(_ write: @escaping (String) -> Void) {
        self.writeToSSH = write
        logger.info("TmuxSessionManager connected with direct write")
    }
    
    // MARK: - Command Abstraction
    
    /// Send a fire-and-forget command (no response expected).
    /// In native Ghostty tmux mode, all commands are fire-and-forget
    /// because Ghostty's viewer consumes the %begin/%end responses.
    ///
    /// IMPORTANT: If the viewer's startup command queue hasn't drained yet
    /// (`viewerReady == false`), the command is queued and flushed later.
    /// Sending commands to tmux during viewer startup would interleave
    /// bytes on the SSH channel with the viewer's capture-pane commands,
    /// corrupting the control mode protocol.
    private func sendCommandFireAndForget(_ command: String) {
        guard let write = writeToSSH else {
            logger.warning("Cannot send command - no write function available")
            return
        }
        
        guard viewerReady else {
            logger.info("Queuing command (viewer not ready): \(command)")
            pendingCommands.append(command)
            return
        }
        
        write("\(command)\n")
    }
    
    /// Called when control mode becomes active
    func controlModeActivated() {
        isConnected = true
        connectionState = .connected
        
        // Reset resize tracking state on (re)connection
        // This ensures we send fresh dimensions to tmux for existing sessions
        lastResizeCols = 0
        lastResizeRows = 0
        lastRefreshSize = nil
        resizeDebounceTask?.cancel()
        resizeDebounceTask = nil
        
        logger.info("Control mode activated, resize state reset")
        
        // Reset viewer ready state — the viewer's command queue hasn't drained yet.
        // All sendCommandFireAndForget calls will be queued until viewerBecameReady().
        viewerReady = false
        pendingCommands.removeAll()
        
        // NOTE: Do NOT send any commands here (e.g. refresh-client).
        // Ghostty's viewer.zig handles all startup commands (display-message,
        // list-windows, capture-pane, list-panes) through its own command queue.
        // Sending commands from Swift would interleave bytes on the SSH channel
        // with Ghostty's commands, potentially corrupting both and causing tmux
        // parse errors.
    }
    
    /// Called when control mode exits
    func controlModeExited(reason: String? = nil) {
        logger.info("🔌 Control mode exited, cleaning up state. Reason: \(reason ?? "unknown")")
        
        // Update connection state
        isConnected = false
        connectionState = reason != nil ? .connectionLost(reason: reason) : .disconnected
        
        currentSession = nil
        sessions.removeAll()
        windows.removeAll()
        windowSplitTrees.removeAll()
        currentSplitTree = TmuxSplitTree()
        
        // Clear output buffers and deferred surface creation
        pendingOutput.removeAll()
        pendingSurfaceCreation.removeAll()
        
        // Reset viewer ready state and discard queued commands
        viewerReady = false
        pendingCommands.removeAll()
        
        // CRITICAL: Clear surface state to ensure fresh surfaces on reconnect
        // Old surfaces may be in bad state and won't properly report cell size
        //
        // ORDERING INVARIANT: Observer surfaces MUST be freed before the primary.
        // ghostty_surface_free → Surface.zig deinit chases binding.source pointer
        // (which points to the primary surface) to unregister from the viewer's
        // observer list. If the primary is freed first, this dereference hits
        // freed memory → SIGSEGV.
        //
        // We close() WITHOUT calling detachTmuxPane() first because detachTmuxPane()
        // chases the same binding.source pointer chain. The ordering guarantee
        // makes ghostty_surface_free's internal cleanup safe.
        
        let observers = paneSurfaces.filter { $0.value.isMultiPaneObserver }
        let primaries = paneSurfaces.filter { !$0.value.isMultiPaneObserver }
        
        for (paneId, surface) in observers {
            #if DEBUG
            teardownOrderForTesting.append((paneId: paneId, isObserver: true))
            #endif
            surface.close()
            logger.debug("Closed observer surface for pane \(paneId)")
        }
        for (paneId, surface) in primaries {
            #if DEBUG
            teardownOrderForTesting.append((paneId: paneId, isObserver: false))
            #endif
            surface.close()
            logger.debug("Closed primary surface for pane \(paneId)")
        }
        paneSurfaces.removeAll()
        primarySurface = nil
        primaryCellSize = .zero
    }
    
    /// Lightweight reset for background → foreground reconnect.
    ///
    /// Called from SSHSession's TMUX_EXIT handler when `isDetachingForBackground`
    /// is true — meaning this exit was triggered by the C1 ST (0x9C) sent in
    /// `appDidBecomeActive()` to exit the stale DCS passthrough, not a real tmux
    /// session teardown by the user.
    ///
    /// Preserves `primarySurface` (the view controller's surfaceView that owns the
    /// Ghostty C surface) and `currentSplitTree` (to avoid SIGSEGV from resizing
    /// into a dead viewer). Clears everything else so the reconnect flow can treat
    /// this like a fresh initial connection.
    func prepareForReattach() {
        logger.info("Preparing for reattach — preserving primarySurface, destroying \(paneSurfaces.count - 1) observer surfaces")
        
        // Clear connection state (will be re-set by controlModeActivated on reattach)
        isConnected = false
        connectionState = .disconnected
        
        // Close and remove observer surfaces. The primary surface stays alive —
        // it's the view controller's surfaceView and will receive DCS 1000p on
        // reconnect, creating a new Ghostty tmux viewer inside it.
        //
        // ORDERING: observers must be freed before primary (binding.source pointer
        // chase). We're not freeing primary, so just free observers.
        let observers = paneSurfaces.filter { $0.value !== primarySurface }
        for (paneId, surface) in observers {
            surface.close()
            logger.debug("Closed observer surface for pane \(paneId)")
        }
        
        // Clear paneSurfaces entirely. The primary will be re-registered under its
        // real pane ID when handleTmuxStateChanged → getSurfaceOrCreate finds
        // primarySurface not in paneSurfaces (the standard initial-connect path).
        paneSurfaces.removeAll()
        
        // Clear transient protocol state — the new viewer will rebuild this
        pendingOutput.removeAll()
        pendingSurfaceCreation.removeAll()
        viewerReady = false
        pendingCommands.removeAll()
        
        // Clear window/session metadata — will be repopulated by TMUX_STATE_CHANGED
        // on the new connection. We keep focusedWindowId and focusedPaneId so the
        // UI doesn't flash to a different window/pane during the brief reconnect.
        currentSession = nil
        sessions.removeAll()
        windows.removeAll()
        windowSplitTrees.removeAll()
        // IMPORTANT: Do NOT clear currentSplitTree here. Setting it to an empty
        // TmuxSplitTree() triggers the splitTreeObserver → handleSplitTreeChange()
        // → cleanupMultiPaneMode() → removes the multi-pane hosting controller
        // from the view hierarchy → primary surface auto-resizes → Ghostty resize
        // while the tmux viewer is dead → renderer use-after-free SIGSEGV.
        //
        // The split tree must be preserved so the multi-pane view hierarchy stays
        // intact during background. When we reattach, TMUX_STATE_CHANGED will
        // repopulate windowSplitTrees and update currentSplitTree naturally.
        
        // Reset resize tracking
        lastResizeCols = 0
        lastResizeRows = 0
        lastRefreshSize = nil
        resizeDebounceTask?.cancel()
        resizeDebounceTask = nil
        
        // DO NOT clear: primarySurface, primaryCellSize, surfaceFactory,
        // surfaceInputHandler, surfaceResizeHandler, writeToSSH.
        // primarySurface is the view controller's surfaceView — it stays alive.
        // The factory/handlers are captured closures from the view controller.
        
        logger.info("prepareForReattach complete: primarySurface preserved, focusedWindow=\(focusedWindowId), focusedPane=\(focusedPaneId)")
    }
    
    /// Called when the Ghostty tmux viewer's startup command queue has fully drained.
    /// After this point, Swift-side commands (refresh-client, select-pane, etc.) are
    /// safe to send — they won't interleave with viewer commands on the SSH channel.
    func viewerBecameReady() {
        guard !viewerReady else {
            logger.debug("viewerBecameReady called but already ready, ignoring")
            return
        }
        
        viewerReady = true
        
        // Flush any commands that were queued during viewer startup
        if !pendingCommands.isEmpty {
            logger.info("Viewer ready — flushing \(pendingCommands.count) queued commands")
            guard let write = writeToSSH else {
                logger.warning("Cannot flush queued commands - no write function available")
                pendingCommands.removeAll()
                return
            }
            
            for command in pendingCommands {
                logger.info("  Sending queued command: \(command)")
                write("\(command)\n")
            }
            pendingCommands.removeAll()
        } else {
            logger.info("Viewer ready — no queued commands to flush")
        }
    }
    
    // MARK: - Notification Handling
    
    /// Snapshot of tmux state queried from the C API.
    /// Decoupled from Ghostty types so the reconciliation logic can be unit tested.
    struct TmuxStateSnapshot {
        /// Window info (id, name, layout string) — ordered by window index
        struct WindowInfo {
            let id: Int
            let name: String
            let layout: String?
            /// Pane that tmux considers focused in this window (-1 if unknown)
            let focusedPaneId: Int
        }
        let windows: [WindowInfo]
        /// Active window ID from the tmux server, or -1 if none
        let activeWindowId: Int
        /// All pane IDs currently known to the tmux viewer
        let paneIds: [Int]
    }
    
    /// Handle TMUX_STATE_CHANGED from Ghostty's native tmux viewer.
    /// This is the primary state update path in the native Ghostty tmux architecture.
    /// Called from SSHSession's notification observer when Ghostty fires
    /// GHOSTTY_ACTION_TMUX_STATE_CHANGED with window_count and pane_count.
    ///
    /// Queries the new window C API to populate the windows dict, parse layouts
    /// into split trees, set the active window, and reconcile pane surfaces.
    func handleTmuxStateChanged(windowCount: Int, paneCount: Int) {
        guard let surface = tmuxQuerySurface else {
            logger.warning("handleTmuxStateChanged: no tmuxQuerySurface, cannot query C API")
            return
        }
        
        logger.info("handleTmuxStateChanged: \(windowCount) windows, \(paneCount) panes")
        
        // --- 1. Query window info from C API ---
        let windowInfos = surface.getAllTmuxWindows()
        let activeWindowId = surface.tmuxActiveWindowId
        let paneIds = surface.getTmuxPaneIds()
        
        logger.info("  C API: \(windowInfos.count) windows, activeWindowId=\(activeWindowId), paneIds=\(paneIds)")
        
        // Build snapshot from C API data
        let snapshot = TmuxStateSnapshot(
            windows: windowInfos.enumerated().map { index, info in
                TmuxStateSnapshot.WindowInfo(
                    id: info.id,
                    name: info.name,
                    layout: surface.getTmuxWindowLayout(at: index),
                    focusedPaneId: surface.tmuxWindowFocusedPaneId(at: index)
                )
            },
            activeWindowId: activeWindowId,
            paneIds: paneIds
        )
        
        // Reconcile state and get the pane ID to activate
        let activePaneId = reconcileTmuxState(snapshot)
        
        // --- Surface reconciliation (requires real Ghostty surface) ---
        let allActivePaneIds = Set(paneIds.map { "%\($0)" })
        
        // Create surfaces for new panes.
        // If the factory isn't configured yet (race: Combine sink hasn't fired),
        // record the pane IDs so configureSurfaceManagement() can create them later.
        // IMPORTANT: Sort NUMERICALLY so the lowest-numbered pane gets processed first.
        // When an adopted primarySurface exists but isn't registered yet,
        // getSurfaceOrCreate() assigns it to the FIRST pane that needs a surface.
        // Numeric sort ensures this is deterministic — lexicographic sort would put
        // "%10" before "%9", causing the wrong pane to get the primary surface.
        for paneId in TmuxId.sortedNumerically(allActivePaneIds) {
            if paneSurfaces[paneId] == nil {
                logger.info("  Creating surface for new pane \(paneId)")
                if let _ = getSurfaceOrCreate(for: paneId) {
                    // Surface created successfully
                } else if surfaceFactory == nil {
                    // Factory not yet configured — defer creation
                    logger.info("  Deferring surface creation for \(paneId) (factory not configured)")
                    pendingSurfaceCreation.insert(paneId)
                }
            }
        }
        
        // Remove surfaces for panes that no longer exist
        let orphanedPaneIds = Set(paneSurfaces.keys).subtracting(allActivePaneIds)
        for paneId in orphanedPaneIds {
            logger.info("  Removing orphaned surface for pane \(paneId)")
            
            // Check if primary surface is being removed
            if paneSurfaces[paneId] === primarySurface {
                reassignPrimarySurface(excludingPaneId: paneId, fromPaneIds: allActivePaneIds)
            }
            
            removeSurface(for: paneId, paneActuallyClosed: true)
        }
        
        // Set active pane for input routing only — observers handle rendering
        if let numericPaneId = activePaneId {
            surface.setActiveTmuxPaneInputOnly(numericPaneId)
        }
        
        logger.info("handleTmuxStateChanged complete: focusedWindow=\(focusedWindowId), focusedPane=\(focusedPaneId), windows=\(windows.count), splitTrees=\(windowSplitTrees.count)")
    }
    
    /// Pure state reconciliation: builds windows dict, parses layouts into split trees,
    /// determines focused window/pane. Returns the numeric pane ID to activate (or nil).
    ///
    /// This method updates `windows`, `windowSplitTrees`, `currentSplitTree`,
    /// `focusedWindowId`, and `focusedPaneId`. It does NOT touch surfaces.
    func reconcileTmuxState(_ snapshot: TmuxStateSnapshot) -> Int? {
        // --- 2. Build windows dict ---
        var newWindows: [String: TmuxWindow] = [:]
        for (index, winInfo) in snapshot.windows.enumerated() {
            let windowId = "@\(winInfo.id)"
            
            var window = TmuxWindow(
                id: windowId,
                index: index,
                name: winInfo.name,
                sessionId: currentSession?.id ?? "$0"
            )
            window.layout = winInfo.layout
            
            newWindows[windowId] = window
        }
        
        // --- 3. Parse layouts into split trees ---
        var newSplitTrees: [String: TmuxSplitTree] = [:]
        for (windowId, window) in newWindows {
            guard let layoutStr = window.layout, !layoutStr.isEmpty else {
                logger.debug("  Window \(windowId): no layout string")
                continue
            }
            
            do {
                let layout = try TmuxLayout.parseWithChecksum(layoutStr)
                let tree = TmuxSplitTree.from(layout: layout)
                newSplitTrees[windowId] = tree
                
                // Back-fill pane IDs on the window model
                let treePaneIds = tree.paneIds.map { "%\($0)" }
                newWindows[windowId]?.paneIds = treePaneIds
                
                logger.info("  Window \(windowId) '\(window.name)': \(tree.paneIds.count) panes, layout parsed OK")
            } catch {
                logger.warning("  Window \(windowId): layout parse failed: \(error)")
                // Don't keep stale trees — they would be inconsistent with the
                // freshly-built newWindows dict. Omitting the tree causes the UI
                // to fall back to a single-pane view for this window.
            }
        }
        
        // --- 4. Update state atomically ---
        windows = newWindows
        windowSplitTrees = newSplitTrees
        
        // --- 5. Set focused window ---
        let previousFocusedWindowId = focusedWindowId
        if snapshot.activeWindowId >= 0 {
            let newFocusedWindowId = "@\(snapshot.activeWindowId)"
            if windows[newFocusedWindowId] != nil {
                focusedWindowId = newFocusedWindowId
            } else if focusedWindowId.isEmpty || windows[focusedWindowId] == nil {
                // Active window not found — pick first window
                focusedWindowId = snapshot.windows.first.map { "@\($0.id)" } ?? ""
            }
        } else if focusedWindowId.isEmpty || windows[focusedWindowId] == nil {
            // No active window from C API — pick first
            focusedWindowId = snapshot.windows.first.map { "@\($0.id)" } ?? ""
        }
        
        // --- 6. Update current split tree ---
        if let tree = windowSplitTrees[focusedWindowId] {
            currentSplitTree = tree
        } else if !focusedWindowId.isEmpty {
            // No tree for focused window — clear (don't show stale layout)
            currentSplitTree = TmuxSplitTree()
        }
        
        // --- 7. Update focused pane ---
        // Use tmux's reported focused pane for the active window if available.
        // Falls back to first pane in the split tree if tmux hasn't sent a
        // %window-pane-changed yet (focusedPaneId == -1 in the snapshot).
        if focusedWindowId != previousFocusedWindowId || focusedPaneId.isEmpty {
            // Look up the tmux-reported focused pane for the focused window
            let tmuxFocusedPane: Int? = {
                guard !focusedWindowId.isEmpty else { return nil }
                // Find the snapshot entry for our focused window
                for winInfo in snapshot.windows {
                    if "@\(winInfo.id)" == focusedWindowId && winInfo.focusedPaneId >= 0 {
                        return winInfo.focusedPaneId
                    }
                }
                return nil
            }()
            
            let newFocusedPaneId: String? = if let tmuxPane = tmuxFocusedPane {
                // tmux told us which pane is focused — use it
                "%\(tmuxPane)"
            } else if let tree = windowSplitTrees[focusedWindowId],
                      let firstPaneId = tree.paneIds.first {
                // No focus info from tmux — fall back to first pane
                "%\(firstPaneId)"
            } else {
                nil
            }
            
            if let newFocusedPaneId, focusedPaneId != newFocusedPaneId {
                focusedPaneId = newFocusedPaneId
                logger.info("  Focused pane set to \(focusedPaneId) (from window \(focusedWindowId))")
            }
        }
        
        // Return the numeric pane ID to activate on the surface
        return TmuxId.numericPaneId(focusedPaneId)
    }
    

    
    // MARK: - Surface Management
    
    /// Get or create a Ghostty surface for a pane (returns nil if not possible)
    private func getSurfaceOrCreate(for paneId: String) -> Ghostty.SurfaceView? {
        if let existing = paneSurfaces[paneId] {
            return existing
        }
        
        // Check if the adopted primarySurface hasn't been registered yet.
        // This is the normal path after adoptExistingSurface(): the primary surface
        // exists but is not in paneSurfaces because we didn't know the real pane ID.
        // The FIRST pane to request a surface gets the adopted primary (it owns the
        // tmux viewer and must be the "source" for observer bindings).
        if let primary = primarySurface, !paneSurfaces.values.contains(where: { $0 === primary }) {
            // primarySurface exists but isn't registered under any pane ID — adopt it
            paneSurfaces[paneId] = primary
            
            // Re-wire the input handler with the real pane ID
            if let inputHandler = surfaceInputHandler {
                inputHandler(primary, paneId)
            }
            
            // NOTE: We intentionally do NOT call setActiveTmuxPane() here.
            // activateFirstTmuxPane() in SSHSession handles renderer binding
            // when TMUX_READY fires. Calling setActiveTmuxPane during surface
            // creation races with observer surface IO thread initialization
            // and causes a Zig PANIC ("reached unreachable code" during resize).
            // The numeric sort fix ensures the primary always gets the lowest
            // pane ID, matching what activateFirstTmuxPane() sets.
            
            logger.info("Registered adopted primarySurface under real pane ID \(paneId)")
            
            // Flush any pending output for this pane (primary owns the viewer,
            // so feedData goes to the right terminal)
            if let pending = pendingOutput.removeValue(forKey: paneId), !pending.isEmpty {
                logger.info("Flushing \(pending.count) buffered output chunks to adopted surface for pane \(paneId)")
                for data in pending {
                    primary.feedData(data)
                }
                primary.setNeedsDisplay()
            }
            
            return primary
        }
        
        // Don't create new surfaces when disconnected.
        // After prepareForReattach() clears paneSurfaces, SwiftUI re-renders the
        // preserved split tree and calls getSurface(forNumericId:) for each pane.
        // Without this guard, the factory creates premature observer surfaces that
        // have no tmux viewer to bind to — they become zombies that block real
        // surface creation on reconnect.
        guard isConnected else {
            logger.debug("Not creating surface for \(paneId) — not connected")
            return nil
        }
        
        // Try to create new surface if factory is available
        guard let factory = surfaceFactory else {
            return nil
        }
        
        // Don't create surfaces for panes that no longer exist in the split tree
        // This prevents race conditions during pane close transitions
        // BUT: allow creation when split tree is empty (initial connection state)
        // or when no surfaces exist yet (first pane of a new session)
        if let numericId = Int(paneId.dropFirst()) {  // "%0" -> 0
            let treeIsEmpty = currentSplitTree.paneIds.isEmpty
            let paneExistsInTree = currentSplitTree.paneIds.contains(numericId)
            let noSurfacesYet = paneSurfaces.isEmpty
            
            if !treeIsEmpty && !paneExistsInTree && !noSurfacesYet {
                logger.debug("Not creating surface for closed pane \(paneId)")
                return nil
            }
        }
        
        guard let surface = factory(paneId) else {
            logger.warning("Surface factory returned nil for pane \(paneId) — app may be deallocating")
            return nil
        }
        
        // Wire up input handler for this surface
        if let inputHandler = surfaceInputHandler {
            inputHandler(surface, paneId)
        }
        
        // Wire up resize handler for this surface
        // IMPORTANT: In multi-pane mode, we do NOT use individual surface resize callbacks.
        // The TmuxMultiPaneView.handleSizeChange() calculates the total container size
        // and sends refresh-client -C with the correct total dimensions.
        // Individual surface callbacks would report the pane's size (smaller than window),
        // which would override the correct total window size.
        //
        // For single-pane mode (no splits), the surface resize is still needed.
        if surfaceResizeHandler != nil {
            surface.onResize = { [weak self] cols, rows in
                guard let self = self else { return }
                // Only use surface resize in single-pane mode
                // In multi-pane mode, TmuxMultiPaneView handles resize
                guard !self.currentSplitTree.isSplit else {
                    logger.debug("📐 Ignoring surface resize in multi-pane mode (handled by container)")
                    return
                }
                
                // Single pane mode - use surface resize
                if self.focusedPaneId == paneId {
                    self.debouncedResize(cols: cols, rows: rows)
                }
            }
        }
        
        paneSurfaces[paneId] = surface
        
        // Assign primary surface if none exists yet.
        // The first surface created becomes primary — this is NOT always %0.
        // When another tmux client (e.g., ShellFish) owns %0, our session's
        // initial pane might be %2, %3, etc.
        if primarySurface == nil {
            assignPrimarySurface(surface, forPaneId: paneId)
        }
        
        // Bind this surface's renderer to the pane terminal in the tmux viewer.
        // The primarySurface (adopted from the direct surface) owns the tmux viewer —
        // it is the "source" surface. Factory-created surfaces for OTHER panes
        // become observers that render from the viewer's per-pane Terminal instances.
        // Skip binding for the primarySurface itself — its renderer is already
        // managed by setActiveTmuxPane() (it owns the viewer).
        var boundToPane = false
        if let source = primarySurface, surface !== source,
           let numericId = Int(paneId.dropFirst()) {  // "%3" -> 3
            let attached = surface.attachToTmuxPane(source: source, paneId: numericId)
            if attached {
                boundToPane = true
            } else {
                logger.warning("Failed to attach surface for pane \(paneId) to tmux viewer")
            }
        }
        
        logger.info("Created Ghostty surface for pane \(paneId)")
        
        // Flush any output that was buffered before this surface existed.
        // IMPORTANT: Skip the flush if the surface was bound to a pane terminal.
        // After attachToTmuxPane, the surface's renderer points at the pane terminal
        // (which already has capture-pane content from viewer.zig). feedData() would
        // write to the surface's OWN io.terminal — the wrong terminal — corrupting
        // the observer's local state while the renderer reads from the pane terminal.
        if boundToPane {
            if let pending = pendingOutput.removeValue(forKey: paneId), !pending.isEmpty {
                logger.info("Discarding \(pending.count) buffered output chunks for pane \(paneId) (bound to pane terminal, content already in viewer)")
            }
        } else if let pending = pendingOutput.removeValue(forKey: paneId), !pending.isEmpty {
            logger.info("Flushing \(pending.count) buffered output chunks to new surface for pane \(paneId)")
            for data in pending {
                surface.feedData(data)
            }
            surface.setNeedsDisplay()
        }
        
        return surface
    }
    
    /// Assign a surface as the primary surface (atomic operation)
    /// This ensures cell size callbacks are properly wired up without gaps
    private func assignPrimarySurface(_ surface: Ghostty.SurfaceView, forPaneId paneId: String) {
        // Clear old callback first
        primarySurface?.onCellSizeChanged = nil
        
        // Assign new primary surface
        primarySurface = surface
        
        // Wire up cell size callback IMMEDIATELY
        surface.onCellSizeChanged = { [weak self] cellSize in
            self?.primaryCellSize = cellSize
            logger.info("📐 Primary cell size updated: \(Int(cellSize.width))x\(Int(cellSize.height))")
        }
        
        // CRITICAL: Manually trigger if cell size is already valid
        // The callback won't fire via didSet if the value was set before the callback was assigned
        if surface.cellSize.width > 0 && surface.cellSize.height > 0 {
            primaryCellSize = surface.cellSize
            logger.info("📐 Primary cell size initialized from \(paneId): \(Int(surface.cellSize.width))x\(Int(surface.cellSize.height))")
        } else {
            // Reset to zero so UI knows we're waiting for cell size
            primaryCellSize = .zero
            logger.info("📐 Primary surface assigned to \(paneId), awaiting cell size")
        }
    }
    
    /// Configure surface management with factory and handlers
    /// Call this before any surfaces are created
    func configureSurfaceManagement(
        factory: @escaping (String) -> Ghostty.SurfaceView?,
        inputHandler: @escaping (Ghostty.SurfaceView, String) -> Void,
        resizeHandler: @escaping (Int, Int) -> Void
    ) {
        self.surfaceFactory = factory
        self.surfaceInputHandler = inputHandler
        self.surfaceResizeHandler = resizeHandler
        logger.info("✅ Surface management configured")
        
        // Drain any pane IDs that were deferred because the factory wasn't ready.
        // This closes the race where handleTmuxStateChanged fires before the Combine
        // $isConnected sink configures the factory.
        if !pendingSurfaceCreation.isEmpty {
            let deferred = pendingSurfaceCreation
            pendingSurfaceCreation.removeAll()
            logger.info("Draining \(deferred.count) deferred surface creations: \(TmuxId.sortedNumerically(deferred))")
            for paneId in TmuxId.sortedNumerically(deferred) {
                if paneSurfaces[paneId] == nil {
                    _ = getSurfaceOrCreate(for: paneId)
                }
            }
        }
    }
    
    /// Create the primary surface for the session's initial pane.
    /// The pane ID is determined dynamically — it may be %0, %2, etc. depending on
    /// what other tmux clients have already claimed. We use the first pane from the
    /// split tree, or the first pane with pending output, or fall back to focusedPaneId.
    func createPrimarySurface() -> Ghostty.SurfaceView? {
        guard surfaceFactory != nil else {
            logger.warning("⚠️ Cannot create primary surface - factory not configured")
            return nil
        }
        
        // Determine the initial pane ID (may not be %0 if other clients exist)
        let initialPaneId = resolveInitialPaneId()
        
        if let existing = paneSurfaces[initialPaneId] {
            logger.info("Primary surface already exists for \(initialPaneId)")
            return existing
        }
        
        let surface = getSurfaceOrCreate(for: initialPaneId)
        logger.info("✅ Created primary surface for \(initialPaneId)")
        return surface
    }
    
    /// Adopt an existing direct surface as the tmux primary surface.
    ///
    /// When a tmux connection starts, the SSH data (including DCS 1000p) is fed
    /// to the direct surface created at viewDidLoad. Ghostty detects DCS 1000p
    /// and creates the tmux viewer INSIDE that surface's C-side state. If we
    /// destroy that surface and create a new one, we lose the viewer and all
    /// tmux protocol state — the new surface would be blank.
    ///
    /// Instead, we adopt the existing surface into TmuxSessionManager's
    /// paneSurfaces dictionary and wire up the tmux-aware input handler.
    func adoptExistingSurface(_ surface: Ghostty.SurfaceView) {
        logger.info("Adopting existing surface as tmux primary (deferred pane registration)")
        
        // DO NOT register in paneSurfaces yet.
        // At this point, no tmux state has arrived — resolveInitialPaneId() would
        // fall back to "%0", which may not match any real pane ID (e.g., the real
        // panes might be %25, %51, %52). Registering under a stale key causes the
        // orphan cleanup in handleTmuxStateChanged() to destroy this surface —
        // taking the tmux viewer with it.
        //
        // Instead, store ONLY as primarySurface. When handleTmuxStateChanged()
        // fires with real pane IDs, getSurfaceOrCreate() will find primarySurface
        // has no entry in paneSurfaces and re-use it for the first pane.
        
        // Wire up the tmux-aware input handler.
        // Use a placeholder pane ID — it will be re-wired when the surface is
        // registered under its real pane ID in getSurfaceOrCreate().
        if let inputHandler = surfaceInputHandler {
            inputHandler(surface, "__adopted__")
        }
        
        // Wire up resize handler for single-pane mode
        // onResize fires synchronously from layoutSubviews on main thread —
        // no Task deferral needed (same fix as createDirectSurface).
        if surfaceResizeHandler != nil {
            surface.onResize = { [weak self] cols, rows in
                guard let self = self else { return }
                guard !self.currentSplitTree.isSplit else {
                    logger.debug("Ignoring surface resize in multi-pane mode (handled by container)")
                    return
                }
                self.surfaceResizeHandler?(cols, rows)
            }
        }
        
        // Assign as primary (cell size callbacks, etc.)
        assignPrimarySurface(surface, forPaneId: "__adopted__")
        
        logger.info("Adopted existing surface as tmux primary (awaiting real pane IDs)")
    }
    
    /// Get surface for a pane (returns nil if not created)
    func getSurface(for paneId: String) -> Ghostty.SurfaceView? {
        return paneSurfaces[paneId]
    }
    
    /// Resolve the initial pane ID for this session.
    /// Priority: split tree pane > pane with pending output > focusedPaneId > "%0"
    private func resolveInitialPaneId() -> String {
        // 1. Use first pane from split tree (authoritative source from layout)
        if let firstPaneId = currentSplitTree.paneIds.first {
            let paneId = "%\(firstPaneId)"
            logger.info("resolveInitialPaneId: from split tree → \(paneId)")
            return paneId
        }
        
        // 2. Use first pane that has pending output (data has arrived)
        if let firstPendingPaneId = TmuxId.sortedNumerically(pendingOutput.keys).first {
            logger.info("resolveInitialPaneId: from pending output → \(firstPendingPaneId)")
            return firstPendingPaneId
        }
        
        // 3. Use focusedPaneId if it's been set to something meaningful
        if !focusedPaneId.isEmpty {
            logger.info("resolveInitialPaneId: from focusedPaneId → \(focusedPaneId)")
            return focusedPaneId
        }
        
        // 4. Fallback — shouldn't normally reach here
        logger.warning("resolveInitialPaneId: fallback to %0")
        return "%0"
    }
    
    /// Get surface for a numeric pane ID (e.g., 0 -> "%0")
    /// This is used by the split tree view which stores numeric IDs
    func getSurface(forNumericId paneId: Int) -> Ghostty.SurfaceView? {
        return getSurfaceOrCreate(for: "%\(paneId)")
    }
    
    /// Remove surface for a pane
    /// - Parameters:
    ///   - paneId: The pane ID to remove
    ///   - paneActuallyClosed: If true, the pane was actually closed in tmux (allow %0 removal).
    ///                         If false (default), this is cleanup during disconnect (keep %0 alive).
    func removeSurface(for paneId: String, paneActuallyClosed: Bool = false) {
        // Only keep %0 alive during disconnect (not when pane actually closes)
        // When pane %0 actually closes, we need to remove it to avoid zombie surface
        if paneId == "%0" && !paneActuallyClosed {
            logger.info("Keeping primary surface %0 alive (disconnect, not pane close)")
            return
        }
        
        if let surface = paneSurfaces.removeValue(forKey: paneId) {
            // Close the surface synchronously to free the Zig Surface and
            // invalidate its userdata pointer BEFORE ARC releases the SurfaceView.
            //
            // NOTE: We intentionally skip detachTmuxPane() before close().
            // Surface.deinit handles tmux_pane_binding restoration internally
            // (mutex, terminal pointer, observer unregistration). Calling
            // detachTmuxPane() separately is redundant and dangerous during
            // teardown — it chases binding.source pointers that may be stale
            // if the source surface is mid-teardown → SIGSEGV.
            // See: Geistty-2026-02-17-211930.ips, Geistty-2026-02-17-211214.ips
            #if DEBUG
            teardownOrderForTesting.append((paneId: paneId, isObserver: surface.isMultiPaneObserver))
            #endif
            surface.close()
            
            logger.info("Removed and closed Ghostty surface for pane \(paneId) (paneActuallyClosed=\(paneActuallyClosed))")
        }
    }
    
    /// Reassign primary surface when the current primary pane is closed
    /// This is an atomic operation that avoids gaps in cell size callbacks
    private func reassignPrimarySurface(excludingPaneId closedPaneId: String, fromPaneIds remainingPaneIds: Set<String>) {
        logger.info("📐 🔄 Primary surface's pane \(closedPaneId) closed, reassigning...")
        
        // Sort numerically to get deterministic ordering (lowest numeric ID first)
        let sortedPaneIds = TmuxId.sortedNumerically(remainingPaneIds)
        
        guard let firstRemainingPaneId = sortedPaneIds.first else {
            // No remaining panes - clear primary surface
            primarySurface?.onCellSizeChanged = nil
            primarySurface = nil
            primaryCellSize = .zero
            logger.info("📐 No remaining panes, primary surface cleared")
            return
        }
        
        // Ensure surface exists for the remaining pane
        if paneSurfaces[firstRemainingPaneId] == nil {
            logger.info("📐 🆕 Creating surface for remaining pane \(firstRemainingPaneId)")
            _ = getSurfaceOrCreate(for: firstRemainingPaneId)
        }
        
        guard let remainingSurface = paneSurfaces[firstRemainingPaneId] else {
            logger.error("📐 ❌ Failed to get/create surface for \(firstRemainingPaneId)")
            primarySurface = nil
            primaryCellSize = .zero
            return
        }
        
        // Use the atomic assignment helper
        assignPrimarySurface(remainingSurface, forPaneId: firstRemainingPaneId)
        logger.info("📐 🔄 Reassigned primarySurface to \(firstRemainingPaneId)")
    }
    
    /// Get all active surfaces
    var activeSurfaces: [String: Ghostty.SurfaceView] {
        return paneSurfaces
    }
    
    // MARK: - User Actions
    
    /// Create a new window
    func newWindow(name: String? = nil) {
        var cmd = "new-window"
        if let name = name {
            // Escape single quotes in name to prevent command injection
            let safeName = name.replacingOccurrences(of: "'", with: "'\\''")
            cmd += " -n '\(safeName)'"
        }
        sendCommandFireAndForget(cmd)
    }
    
    /// Close current window
    func closeWindow() {
        sendCommandFireAndForget("kill-window")
    }
    
    /// Close a specific window by ID
    func closeWindow(windowId: String) {
        // Window IDs are system-generated (@N format) — no user input to escape
        sendCommandFireAndForget("kill-window -t '\(windowId)'")
    }
    
    /// Rename current window
    func renameWindow(_ name: String) {
        // Escape single quotes in name to prevent command injection
        let safeName = name.replacingOccurrences(of: "'", with: "'\\''")
        sendCommandFireAndForget("rename-window '\(safeName)'")
    }
    
    /// Rename a specific window by ID
    func renameWindow(windowId: String, name: String) {
        // Escape single quotes in name to prevent command injection
        let safeName = name.replacingOccurrences(of: "'", with: "'\\''")
        sendCommandFireAndForget("rename-window -t '\(windowId)' '\(safeName)'")
    }
    
    /// Select a window by ID
    func selectWindow(_ windowId: String) {
        logger.info("📑 selectWindow: \(windowId)")
        logger.info("📑   Current windows: \(windows.keys.sorted().joined(separator: ", "))")
        logger.info("📑   Current split trees: \(windowSplitTrees.keys.sorted().joined(separator: ", "))")
        
        // Send select-window command to tmux
        sendCommandFireAndForget("select-window -t '\(windowId)'")
        focusedWindowId = windowId
        
        // Update current split tree for the newly focused window
        if let tree = windowSplitTrees[windowId] {
            currentSplitTree = tree
            logger.info("📑 Switched to existing split tree for window \(windowId): \(tree.paneIds.count) panes")
            
            // Ensure surfaces exist for all panes in this window
            for numericPaneId in tree.paneIds {
                let paneId = "%\(numericPaneId)"
                if paneSurfaces[paneId] == nil {
                    logger.info("📑 🆕 Pre-creating surface for pane \(paneId)")
                    _ = getSurfaceOrCreate(for: paneId)
                }
            }
            
            // Update focused pane: prefer tmux's reported focus for this window,
            // fall back to first pane if no focus info available
            let focusPaneId: Int? = {
                guard let window = windows[windowId],
                      let surface = tmuxQuerySurface else { return nil }
                let paneId = surface.tmuxWindowFocusedPaneId(at: window.index)
                return paneId >= 0 ? paneId : nil
            }()
            
            if let focusPaneId {
                focusedPaneId = "%\(focusPaneId)"
                tmuxQuerySurface?.setActiveTmuxPane(focusPaneId)
            } else if let firstPaneId = tree.paneIds.first {
                focusedPaneId = "%\(firstPaneId)"
                tmuxQuerySurface?.setActiveTmuxPane(firstPaneId)
            }
        } else {
            // No split tree yet — in native Ghostty mode, select-window triggers
            // %layout-change which Ghostty processes, firing TMUX_STATE_CHANGED.
            // The layout will arrive via Ghostty's TMUX_STATE_CHANGED notification when it does.
            logger.info("📑 No split tree for window \(windowId), waiting for layout notification from Ghostty")
            
            // Clear current split tree while we wait for the layout notification
            // This prevents showing the old window's content during transition
            currentSplitTree = TmuxSplitTree()
        }
    }
    
    /// Navigate to next window (tab)
    func nextWindow() {
        sendCommandFireAndForget("next-window")
    }
    
    /// Navigate to previous window (tab)
    func previousWindow() {
        sendCommandFireAndForget("previous-window")
    }
    
    /// Navigate to last window (most recently used)
    func lastWindow() {
        sendCommandFireAndForget("last-window")
    }
    
    /// Navigate to window by index (1-based like Ghostty Cmd+1-8)
    func selectWindowByIndex(_ index: Int) {
        // Sort windows by their tmux index to map positional shortcuts correctly,
        // regardless of the tmux base-index setting
        let sortedWindows = windows.values.sorted { $0.index < $1.index }
        let position = index - 1  // Cmd+1 = first window
        guard position >= 0, position < sortedWindows.count else { return }
        let window = sortedWindows[position]
        sendCommandFireAndForget("select-window -t \(window.id)")
    }
    
    /// Navigate to next pane
    func nextPane() {
        sendCommandFireAndForget("select-pane -t :.+")
    }
    
    /// Navigate to previous pane
    func previousPane() {
        sendCommandFireAndForget("select-pane -t :.-")
    }
    
    /// Toggle pane zoom (tmux zoom)
    func toggleTmuxZoom() {
        sendCommandFireAndForget("resize-pane -Z")
    }
    
    /// Split pane horizontally (side by side)
    func splitHorizontal() {
        sendCommandFireAndForget("split-window -h")
    }
    
    /// Split pane vertically (stacked)
    func splitVertical() {
        sendCommandFireAndForget("split-window -v")
    }
    
    /// Close current pane
    func closePane() {
        sendCommandFireAndForget("kill-pane")
    }
    
    /// Select a pane by ID
    func selectPane(_ paneId: String) {
        sendCommandFireAndForget("select-pane -t '\(paneId)'")
        focusedPaneId = paneId
        
        // Route input (send-keys) to this pane WITHOUT swapping the renderer.
        // In multi-surface mode, each pane has its own observer surface for
        // rendering — the primary surface should keep showing its own pane.
        if let numericPaneId = TmuxId.numericPaneId(paneId) {
            tmuxQuerySurface?.setActiveTmuxPaneInputOnly(numericPaneId)
        }
    }
    
    /// Update focused pane locally without sending a tmux command.
    /// Used by handleTmuxStateChanged when the tmux server reports a different
    /// focused pane (e.g. after window switch). Unlike selectPane(), this does
    /// NOT send `select-pane` to tmux.
    func setFocusedPane(_ paneId: String) {
        if focusedPaneId != paneId {
            logger.info("🎯 Focus changed to pane \(paneId)")
            focusedPaneId = paneId
            // Route input to this pane — do NOT swap the renderer (observers handle that)
            if let numericPaneId = TmuxId.numericPaneId(paneId) {
                tmuxQuerySurface?.setActiveTmuxPaneInputOnly(numericPaneId)
            }
        }
    }
    
    /// Navigate to pane in direction
    func navigatePane(_ direction: PaneDirection) {
        let dirFlag: String
        switch direction {
        case .up: dirFlag = "-U"
        case .down: dirFlag = "-D"
        case .left: dirFlag = "-L"
        case .right: dirFlag = "-R"
        }
        sendCommandFireAndForget("select-pane \(dirFlag)")
    }
    
    enum PaneDirection {
        case up, down, left, right
    }
    
    /// Toggle zoom state for a pane (local UI zoom, not tmux zoom)
    func toggleZoom(paneId: Int) {
        currentSplitTree = currentSplitTree.toggleZoom(paneId: paneId)
        
        // Store updated tree
        windowSplitTrees[focusedWindowId] = currentSplitTree
    }
    
    /// Clear zoom state
    func clearZoom() {
        currentSplitTree = currentSplitTree.clearZoom()
        windowSplitTrees[focusedWindowId] = currentSplitTree
    }
    
    /// Equalize all splits in the current window
    /// Detects the root split direction and uses the appropriate layout
    func equalizeSplits() {
        // Determine layout based on root split direction
        let layout: String
        if case .split(let split) = currentSplitTree.root {
            // Use direction-appropriate layout, or tiled for complex trees
            if split.left.leafCount > 1 || split.right.leafCount > 1 {
                // Complex nested tree - use tiled for even distribution
                layout = "tiled"
            } else {
                // Simple two-pane split - use direction-specific layout
                layout = split.direction == .horizontal ? "even-horizontal" : "even-vertical"
            }
        } else {
            // Single pane or empty - default to tiled
            layout = "tiled"
        }
        
        logger.info("📐 Equalizing splits with layout: \(layout)")
        sendCommandFireAndForget("select-layout \(layout)")
    }
    
    /// Update a split ratio locally (for UI drag feedback)
    /// This updates the local split tree immediately for smooth dragging.
    /// The ratio will be synced to tmux when the drag ends.
    func updateSplitRatio(forPaneId paneId: Int, ratio: Double) {
        currentSplitTree = currentSplitTree.updateRatio(forPaneId: paneId, ratio: ratio)
        windowSplitTrees[focusedWindowId] = currentSplitTree
    }
    
    /// Sync a split ratio to tmux (called after drag settles)
    /// This sends the resize-pane command to tmux.
    func syncSplitRatioToTmux(forPaneId paneId: Int, ratio: Double) {
        // Find the split that contains this pane
        guard let splitInfo = findSplitContainingWithSize(paneId: paneId) else {
            logger.warning("⚠️ Could not find split containing %\(paneId)")
            return
        }
        
        // Calculate target size in cells (account for 1 cell divider)
        let availableSize = splitInfo.totalSize - 1
        let newSize = max(1, Int(Double(availableSize) * ratio))
        
        // Use resize-pane with -x (width) for horizontal, -y (height) for vertical
        let sizeFlag = splitInfo.direction == .horizontal ? "-x" : "-y"
        let command = "resize-pane -t %\(paneId) \(sizeFlag) \(newSize)"
        
        logger.info("📐 Syncing resize to tmux: \(command)")
        sendCommandFireAndForget(command)
    }
    
    /// Find the split node that contains the given pane ID and return its direction and total size
    private func findSplitContainingWithSize(paneId: Int) -> (direction: TmuxSplitTree.Direction, ratio: Double, totalSize: Int)? {
        guard let root = currentSplitTree.root else {
            logger.warning("⚠️ No root node in currentSplitTree")
            return nil
        }
        
        // Get the total window size first
        guard let size = lastRefreshSize else {
            logger.warning("⚠️ No lastRefreshSize available for split calculation")
            return nil
        }
        
        logger.info("📐 findSplitContainingWithSize: paneId=\(paneId), lastRefreshSize=\(size.cols)x\(size.rows)")
        
        return findSplitContainingWithSizeHelper(node: root, paneId: paneId, totalCols: size.cols, totalRows: size.rows)
    }
    
    private func findSplitContainingWithSizeHelper(
        node: TmuxSplitTree.Node, 
        paneId: Int, 
        totalCols: Int, 
        totalRows: Int
    ) -> (direction: TmuxSplitTree.Direction, ratio: Double, totalSize: Int)? {
        guard case .split(let split) = node else { return nil }
        
        if split.left.leftmostPaneId == paneId {
            // Found the split - calculate total size based on direction
            let totalSize = split.direction == .horizontal ? totalCols : totalRows
            return (split.direction, split.ratio, totalSize)
        }
        
        // Recurse into children with adjusted sizes
        let leftCols: Int
        let leftRows: Int
        let rightCols: Int
        let rightRows: Int
        
        switch split.direction {
        case .horizontal:
            // Split divides columns
            let leftWidth = Int(Double(totalCols - 1) * split.ratio) // -1 for divider
            leftCols = leftWidth
            rightCols = totalCols - leftWidth - 1
            leftRows = totalRows
            rightRows = totalRows
        case .vertical:
            // Split divides rows
            let leftHeight = Int(Double(totalRows - 1) * split.ratio) // -1 for divider
            leftCols = totalCols
            rightCols = totalCols
            leftRows = leftHeight
            rightRows = totalRows - leftHeight - 1
        }
        
        if let result = findSplitContainingWithSizeHelper(node: split.left, paneId: paneId, totalCols: leftCols, totalRows: leftRows) {
            return result
        }
        return findSplitContainingWithSizeHelper(node: split.right, paneId: paneId, totalCols: rightCols, totalRows: rightRows)
    }

    /// Track last refresh size for re-syncing
    private var lastRefreshSize: (cols: Int, rows: Int)?
    
    /// Debounced resize to prevent thrashing with rapid resize events
    /// Waits 50ms to coalesce multiple resize calls into one
    private func debouncedResize(cols: Int, rows: Int) {
        // Track for later re-sync
        lastRefreshSize = (cols, rows)
        
        // Skip if dimensions haven't changed
        guard cols != lastResizeCols || rows != lastResizeRows else {
            return
        }
        
        // Cancel any pending resize
        resizeDebounceTask?.cancel()
        
        // Store dimensions for the debounced call
        let pendingCols = cols
        let pendingRows = rows
        
        resizeDebounceTask = Task { [weak self] in
            // Wait 50ms for resize events to settle
            try? await Task.sleep(nanoseconds: 50_000_000)
            
            guard !Task.isCancelled, let self = self else { return }
            
            // Only send if dimensions still different from last sent
            if pendingCols != self.lastResizeCols || pendingRows != self.lastResizeRows {
                self.lastResizeCols = pendingCols
                self.lastResizeRows = pendingRows
                self.surfaceResizeHandler?(pendingCols, pendingRows)
            }
        }
    }
    
    /// Resize terminal (all panes)
    func resize(cols: Int, rows: Int) {
        // Use the abstracted sendCommandFireAndForget
        sendCommandFireAndForget("refresh-client -C \(cols),\(rows)")
    }
    
    /// Detach from current session
    func detach() {
        sendCommandFireAndForget("detach-client")
    }
    
    // MARK: - Pending Input Visual Feedback
    
    /// Display pending input text as preedit (inverted preview) in the focused pane
    /// This gives visual feedback that keystrokes are being queued during disconnection
    func displayPendingInput(_ text: String) {
        logger.info("📝 displayPendingInput: '\(text)' focusedPaneId=\(focusedPaneId) paneSurfaces.keys=\(Array(paneSurfaces.keys))")
        guard let surface = paneSurfaces[focusedPaneId] else {
            logger.warning("📝 No surface for focused pane \(focusedPaneId), cannot display pending input")
            return
        }
        
        logger.info("📝 Calling surface.setPreedit with text: '\(text)'")
        surface.setPreedit(text.isEmpty ? nil : text)
    }
    
    /// Clear pending input display from terminal
    func clearPendingInputDisplay() {
        guard let surface = paneSurfaces[focusedPaneId] else { return }
        surface.setPreedit(nil)
    }
    
    // MARK: - Cleanup
    
    /// Clean up all state
    func cleanup() {
        // Clear any pending input display
        clearPendingInputDisplay()
        
        // Cancel debounce tasks to prevent crashes after cleanup
        resizeDebounceTask?.cancel()
        resizeDebounceTask = nil
        
        // ORDERING INVARIANT: Observer surfaces MUST be freed before the primary.
        // ghostty_surface_free → Surface.zig deinit chases binding.source pointer
        // (which points to the primary surface) to unregister from the viewer's
        // observer list. If the primary is freed first, this dereference hits
        // freed memory → SIGSEGV.
        //
        // paneActuallyClosed: true ensures %0 is also cleaned up (not kept alive).
        let observerPanes = paneSurfaces.filter { $0.value.isMultiPaneObserver }
        let primaryPanes = paneSurfaces.filter { !$0.value.isMultiPaneObserver }
        
        for (paneId, _) in observerPanes {
            removeSurface(for: paneId, paneActuallyClosed: true)
        }
        for (paneId, _) in primaryPanes {
            removeSurface(for: paneId, paneActuallyClosed: true)
        }
        
        // Clear output buffers and deferred surface creation
        pendingOutput.removeAll()
        pendingSurfaceCreation.removeAll()
        
        sessions.removeAll()
        windows.removeAll()
        windowSplitTrees.removeAll()
        currentSplitTree = TmuxSplitTree()
        currentSession = nil
        isConnected = false
        connectionState = .disconnected
        focusedPaneId = ""
        focusedWindowId = ""
        
        // Reset resize tracking
        lastResizeCols = 0
        lastResizeRows = 0
        lastRefreshSize = nil
        
        logger.info("TmuxSessionManager cleaned up")
    }
}

// MARK: - Convenience Extensions

extension TmuxSessionManager {
    /// Get the focused window
    var focusedWindow: TmuxWindow? {
        return windows[focusedWindowId]
    }
}
