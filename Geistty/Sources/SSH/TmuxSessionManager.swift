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
    
    /// The primary surface for the initial pane (%0)
    /// This is always kept alive even when in multi-pane mode
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
    private func sendCommandFireAndForget(_ command: String) {
        guard let write = writeToSSH else {
            logger.warning("Cannot send command - no write function available")
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
        
        // Clear output buffers
        pendingOutput.removeAll()
        
        // Cancel debounce tasks to prevent crashes after cleanup
        resizeDebounceTask?.cancel()
        resizeDebounceTask = nil
        lastResizeCols = 0
        lastResizeRows = 0
        lastRefreshSize = nil
        
        // CRITICAL: Clear surface state to ensure fresh surfaces on reconnect
        // Old surfaces may be in bad state and won't properly report cell size
        for (paneId, surface) in paneSurfaces {
            // Clear callbacks to break retain cycles
            surface.onResize = nil
            surface.onCellSizeChanged = nil
            logger.debug("Cleaned up surface for pane \(paneId)")
        }
        paneSurfaces.removeAll()
        primarySurface = nil
        primaryCellSize = .zero
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
                    layout: surface.getTmuxWindowLayout(at: index)
                )
            },
            activeWindowId: activeWindowId,
            paneIds: paneIds
        )
        
        // Reconcile state and get the pane ID to activate
        let activePaneId = reconcileTmuxState(snapshot)
        
        // --- Surface reconciliation (requires real Ghostty surface) ---
        let allActivePaneIds = Set(paneIds.map { "%\($0)" })
        
        // Create surfaces for new panes
        for paneId in allActivePaneIds {
            if paneSurfaces[paneId] == nil {
                logger.info("  Creating surface for new pane \(paneId)")
                _ = getSurfaceOrCreate(for: paneId)
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
        
        // Set active pane on the Ghostty surface for rendering
        if let numericPaneId = activePaneId {
            surface.setActiveTmuxPane(numericPaneId)
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
                // Keep any existing tree we had for this window
                if let existingTree = windowSplitTrees[windowId] {
                    newSplitTrees[windowId] = existingTree
                }
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
        // If the focused window changed, update focusedPaneId to the first pane of the new window
        if focusedWindowId != previousFocusedWindowId || focusedPaneId.isEmpty {
            if let tree = windowSplitTrees[focusedWindowId],
               let firstPaneId = tree.paneIds.first {
                let newFocusedPaneId = "%\(firstPaneId)"
                if focusedPaneId != newFocusedPaneId {
                    focusedPaneId = newFocusedPaneId
                    logger.info("  Focused pane set to \(focusedPaneId) (from window \(focusedWindowId))")
                }
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
        
        logger.info("Created Ghostty surface for pane \(paneId)")
        
        // Flush any output that was buffered before this surface existed
        if let pending = pendingOutput.removeValue(forKey: paneId), !pending.isEmpty {
            logger.info("🔄 Flushing \(pending.count) buffered output chunks to new surface for pane \(paneId)")
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
        let initialPaneId = resolveInitialPaneId()
        
        logger.info("Adopting existing surface as tmux primary for \(initialPaneId)")
        
        // Register in paneSurfaces
        paneSurfaces[initialPaneId] = surface
        
        // Wire up the tmux-aware input handler (pane-tracking)
        if let inputHandler = surfaceInputHandler {
            inputHandler(surface, initialPaneId)
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
        
        // Assign as primary
        assignPrimarySurface(surface, forPaneId: initialPaneId)
        
        logger.info("Adopted existing surface as tmux primary for \(initialPaneId)")
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
        if let firstPendingPaneId = pendingOutput.keys.sorted().first {
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
            // Clean up surface callbacks to break retain cycles
            surface.onResize = nil
            surface.onCellSizeChanged = nil
            logger.info("Removed Ghostty surface for pane \(paneId) (paneActuallyClosed=\(paneActuallyClosed))")
        }
    }
    
    /// Reassign primary surface when the current primary pane is closed
    /// This is an atomic operation that avoids gaps in cell size callbacks
    private func reassignPrimarySurface(excludingPaneId closedPaneId: String, fromPaneIds remainingPaneIds: Set<String>) {
        logger.info("📐 🔄 Primary surface's pane \(closedPaneId) closed, reassigning...")
        
        // Sort to get deterministic ordering (lowest numeric ID first)
        let sortedPaneIds = remainingPaneIds.sorted()
        
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
            
            // Update focused pane to first pane in this window
            if let firstPaneId = tree.paneIds.first {
                focusedPaneId = "%\(firstPaneId)"
                // Swap the Ghostty renderer to show this pane's terminal
                primarySurface?.setActiveTmuxPane(firstPaneId)
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
        // tmux uses 0-based indexing by default, but we accept 1-based from Ghostty shortcuts
        sendCommandFireAndForget("select-window -t :\(index - 1)")
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
    }
    
    /// Update focused pane locally without sending a tmux command.
    /// Used for input-based focus tracking (when user types in a pane).
    func setFocusedPane(_ paneId: String) {
        if focusedPaneId != paneId {
            logger.info("🎯 Focus changed to pane \(paneId)")
            focusedPaneId = paneId
            // Swap the Ghostty renderer to show this pane's terminal
            if let numericPaneId = TmuxId.numericPaneId(paneId) {
                primarySurface?.setActiveTmuxPane(numericPaneId)
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
        
        // Remove all surfaces (paneActuallyClosed: true ensures %0 is also cleaned up)
        for paneId in paneSurfaces.keys {
            removeSurface(for: paneId, paneActuallyClosed: true)
        }
        
        // Clear output buffers
        pendingOutput.removeAll()
        
        sessions.removeAll()
        windows.removeAll()
        windowSplitTrees.removeAll()
        currentSplitTree = TmuxSplitTree()
        currentSession = nil
        isConnected = false
        connectionState = .disconnected
        
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
