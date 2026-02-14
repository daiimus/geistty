//
//  TmuxSessionManager.swift
//  Geistty
//
//  Manages tmux session/window/pane state and coordinates with Ghostty surfaces.
//  This is the central hub for tmux integration.
//

import Foundation
import os.log
import Combine

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

/// Whether a tmux session was newly created or resumed from an existing one
enum SessionResumeStatus: Equatable {
    /// A new session was created on the server
    case created(name: String)
    
    /// An existing session was resumed (attached to)
    case resumed(name: String)
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
    
    /// All panes in the current session
    @Published private(set) var panes: [String: TmuxPane] = [:]
    
    /// Currently focused pane ID (empty until first layout/output event resolves it)
    @Published private(set) var focusedPaneId: String = ""
    
    /// Currently focused window ID (empty until first session-changed/layout event)
    @Published private(set) var focusedWindowId: String = ""
    
    /// Connection state (legacy bool for compatibility)
    @Published private(set) var isConnected: Bool = false
    
    /// Detailed connection state
    @Published private(set) var connectionState: TmuxConnectionState = .disconnected
    
    /// Whether the current session was newly created or resumed
    /// Set after activation when we can distinguish the two cases
    @Published private(set) var sessionResumeStatus: SessionResumeStatus?
    
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
    
    /// Cell size from the primary surface (for calculating terminal dimensions)
    /// This is updated when the surface reports its cell size
    @Published private(set) var primaryCellSize: CGSize = .zero
    
    // MARK: - Output Buffering
    
    /// Buffer for output received before surfaces are created (pre-factory configuration)
    /// tmux sends %output immediately on attach; if the surface isn't ready yet,
    /// we buffer here and flush when the surface is created.
    private(set) var pendingOutput: [String: [Data]] = [:]
    
    /// Tracks whether %sessions-changed was received before %session-changed
    /// If true, the session was newly created; if false, it was resumed (attached)
    private var sawSessionsChanged: Bool = false

    /// Surface creation factory (injected before activation)
    /// This creates Ghostty surfaces with proper configuration
    private var surfaceFactory: ((String) -> Ghostty.SurfaceView)?
    
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
    
    /// Cache of last processed layout strings per window (to avoid redundant updates)
    private var lastProcessedLayouts: [String: String] = [:]
    
    /// Pending layout changes for debouncing (windowId -> (layout, timestamp))
    private var pendingLayoutChanges: [String: (layout: String, windowIndex: Int)] = [:]
    
    /// Debounce task for layout changes to prevent UI thrashing
    private var layoutDebounceTask: Task<Void, Never>?
    
    // MARK: - Direct Write Connection
    
    /// Write function to send data to SSH
    private var writeToSSH: ((String) -> Void)?
    
    // MARK: - Subscriptions
    
    private var cancellables = Set<AnyCancellable>()
    
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
        
        logger.info("✅ Control mode activated, resize state reset")
        
        // Now that we have proper command routing, we can safely query state
        // The responses will be routed to our callbacks, not mixed with session restore
        refreshState()
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
        panes.removeAll()
        windowSplitTrees.removeAll()
        currentSplitTree = TmuxSplitTree()
        lastProcessedLayouts.removeAll()
        
        // Clear output buffers
        pendingOutput.removeAll()
        sawSessionsChanged = false
        sessionResumeStatus = nil
        
        // Cancel debounce tasks to prevent crashes after cleanup
        resizeDebounceTask?.cancel()
        resizeDebounceTask = nil
        layoutDebounceTask?.cancel()
        layoutDebounceTask = nil
        pendingLayoutChanges.removeAll()
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
    
    // MARK: - State Queries
    
    /// Refresh state from tmux server.
    /// In native Ghostty tmux mode, Ghostty's viewer tracks state internally.
    /// We fire refresh-client to trigger Ghostty to re-evaluate state.
    func refreshState() {
        guard writeToSSH != nil else {
            logger.warning("Cannot refresh state: no write callback available")
            return
        }
        
        logger.info("Refreshing tmux state (native Ghostty mode)")
        
        // Trigger a refresh-client which causes tmux to re-send state notifications.
        // Ghostty's viewer will process these and fire TMUX_STATE_CHANGED.
        sendCommandFireAndForget("refresh-client")
    }
    
    /// Query windows for a specific session (fire-and-forget)
    func queryWindows(for sessionId: String) {
        // In native Ghostty mode, we can't capture responses.
        // State comes via TMUX_STATE_CHANGED notifications.
        logger.debug("queryWindows called for \(sessionId) - relying on Ghostty state tracking")
    }
    
    /// Query panes for a specific window (fire-and-forget)
    func queryPanes(for windowId: String) {
        // In native Ghostty mode, we can't capture responses.
        // State comes via TMUX_STATE_CHANGED notifications.
        logger.debug("queryPanes called for \(windowId) - relying on Ghostty state tracking")
    }
    
    // MARK: - Response Parsing
    
    /// Parse list-sessions response
    private func parseSessionsResponse(_ response: String) {
        let lines = response.split(separator: "\n", omittingEmptySubsequences: true)
        logger.info("Parsing \(lines.count) sessions")
        
        for line in lines {
            if let session = TmuxSession.parse(String(line)) {
                sessions[session.id] = session
                logger.debug("Parsed session: \(session.id) '\(session.name)'")
            }
        }
    }
    
    /// Parse list-windows response
    private func parseWindowsResponse(_ response: String) {
        let lines = response.split(separator: "\n", omittingEmptySubsequences: true)
        logger.info("Parsing \(lines.count) windows")
        
        for line in lines {
            if let window = TmuxWindow.parse(String(line)) {
                windows[window.id] = window
                logger.debug("Parsed window: \(window.id) '\(window.name)'")
                
                // Update split tree from layout if available
                if let layout = window.layout,
                   let parsedLayout = try? TmuxLayout.parseWithChecksum(layout) {
                    updateSplitTree(from: parsedLayout, for: window.id)
                }
            }
        }
    }
    
    /// Parse list-panes response
    private func parsePanesResponse(_ response: String) {
        let lines = response.split(separator: "\n", omittingEmptySubsequences: true)
        logger.info("Parsing \(lines.count) panes")
        
        for line in lines {
            if let pane = TmuxPane.parse(String(line)) {
                panes[pane.id] = pane
                logger.debug("Parsed pane: \(pane.id) \(pane.width)x\(pane.height)")
            }
        }
    }
    
    // MARK: - Notification Handling
    
    /// Handle TMUX_STATE_CHANGED from Ghostty's native tmux viewer.
    /// This is the primary state update path in the native Ghostty tmux architecture.
    /// Called from SSHSession's notification observer when Ghostty fires
    /// GHOSTTY_ACTION_TMUX_STATE_CHANGED with window_count and pane_count.
    ///
    /// Currently this is a minimal stub — window/pane state tracking will be
    /// enhanced when we add C API functions to expose layout geometry from
    /// Ghostty's viewer.
    func handleTmuxStateChanged(windowCount: Int, paneCount: Int) {
        logger.info("Ghostty tmux state changed: \(windowCount) windows, \(paneCount) panes")
        
        // TODO: Use ghostty_surface_tmux_pane_ids() to get actual pane IDs
        // and reconcile with our local state. For now, just log the counts.
        // Future work: expose layout geometry via C API and update split trees.
    }
    
    /// Handle session changed notification
    func handleSessionChanged(sessionId: String, sessionName: String) {
        logger.info("Session changed: \(sessionId) (\(sessionName))")
        
        // Determine if this session was newly created or resumed
        // %sessions-changed arriving before %session-changed means a session was created
        if sawSessionsChanged {
            sessionResumeStatus = .created(name: sessionName)
            logger.info("Session '\(sessionName)' was newly created")
        } else {
            sessionResumeStatus = .resumed(name: sessionName)
            logger.info("Session '\(sessionName)' was resumed (attached to existing)")
        }
        sawSessionsChanged = false
        
        // Update or create session
        var session = sessions[sessionId] ?? TmuxSession(id: sessionId, name: sessionName)
        session.name = sessionName
        session.isAttached = true
        
        sessions[sessionId] = session
        currentSession = session
        
        // Query windows for this session
        queryWindows(for: sessionId)
        
        // In native Ghostty tmux mode, session restore (capture-pane) is handled
        // by Ghostty's tmux viewer during its startup sequence. No action needed here.
    }
    
    
    /// Handle window added notification
    func handleWindowAdd(windowId: String) {
        logger.info("📑 Window added: \(windowId)")
        
        guard let sessionId = currentSession?.id else { return }
        
        // Create placeholder window, will be filled in by query
        let window = TmuxWindow(id: windowId, index: windows.count, name: "new", sessionId: sessionId)
        windows[windowId] = window
        
        // Add to current session's window list
        if var session = currentSession {
            if !session.windowIds.contains(windowId) {
                session.windowIds.append(windowId)
                sessions[session.id] = session
                currentSession = session
            }
        }
        
        // In native Ghostty mode, window details will arrive via %layout-change
        // which Ghostty's viewer processes, triggering TMUX_STATE_CHANGED.
        // No need to query — state comes from notifications.
        logger.info("📑 Window \(windowId) added, waiting for layout notification from Ghostty")
    }
    
    /// Handle window closed notification
    func handleWindowClose(windowId: String) {
        logger.info("🗑️ Window closed: \(windowId)")
        
        // Clean up associated panes and their surfaces
        if let window = windows[windowId] {
            for paneId in window.paneIds {
                panes.removeValue(forKey: paneId)
                
                // Check if this pane has the primary surface and clear it
                if paneSurfaces[paneId] === primarySurface {
                    logger.info("🗑️ Clearing primarySurface (was in closed window)")
                    primarySurface = nil
                    primaryCellSize = .zero
                }
                
                // Remove surface with paneActuallyClosed=true so %0 can be removed
                removeSurface(for: paneId, paneActuallyClosed: true)
                
                // Clean up output buffer for this pane
                pendingOutput.removeValue(forKey: paneId)
            }
        }
        
        // Remove window and its split tree
        windows.removeValue(forKey: windowId)
        windowSplitTrees.removeValue(forKey: windowId)
        lastProcessedLayouts.removeValue(forKey: windowId)
        
        // Update session's window list
        if var session = currentSession {
            session.windowIds.removeAll { $0 == windowId }
            sessions[session.id] = session
            currentSession = session
            
            // If this was the focused window, switch to another window
            if focusedWindowId == windowId {
                if let nextWindowId = session.windowIds.first {
                    logger.info("🗑️ Focused window closed, switching to \(nextWindowId)")
                    
                    // Use selectWindow which properly handles querying layout,
                    // creating surfaces, and assigning primarySurface for the new window
                    selectWindow(nextWindowId)
                } else {
                    // No windows left - this shouldn't normally happen,
                    // tmux should send %exit when last window closes
                    logger.warning("🗑️ All windows closed but no %exit received")
                    currentSplitTree = TmuxSplitTree()
                    focusedPaneId = ""
                    focusedWindowId = ""
                }
            }
        }
    }
    
    /// Reassign primary surface to any available surface
    private func reassignPrimarySurface() {
        // Find any available surface to be the new primary
        if let (paneId, surface) = paneSurfaces.first {
            logger.info("🔄 Reassigning primarySurface to \(paneId)")
            primarySurface = surface
            surface.onCellSizeChanged = { [weak self] cellSize in
                self?.primaryCellSize = cellSize
                logger.info("📐 Primary cell size updated: \(Int(cellSize.width))x\(Int(cellSize.height))")
            }
            // Manually trigger if cell size is already valid
            if surface.cellSize.width > 0 && surface.cellSize.height > 0 {
                primaryCellSize = surface.cellSize
                logger.info("📐 Primary cell size initialized from reassignment: \(Int(surface.cellSize.width))x\(Int(surface.cellSize.height))")
            }
        } else {
            logger.warning("🔄 No surfaces available to reassign as primary")
            primarySurface = nil
            primaryCellSize = .zero
        }
    }
    
    /// Handle window renamed notification
    func handleWindowRenamed(windowId: String, name: String) {
        logger.info("Window renamed: \(windowId) -> \(name)")
        
        if var window = windows[windowId] {
            window.name = name
            windows[windowId] = window
        }
    }
    
    /// Handle session window changed notification (window focus changed on server)
    func handleSessionWindowChanged(sessionId: String, windowId: String) {
        logger.info("📑 Session window changed: \(sessionId) -> \(windowId)")
        
        // Update focused window if it's our current session
        if currentSession?.id == sessionId {
            focusedWindowId = windowId
            
            // Switch to the split tree for the new window
            if let tree = windowSplitTrees[windowId] {
                currentSplitTree = tree
                logger.info("📑 Switched to split tree for window \(windowId): \(tree.paneIds.count) panes")
                
                // Update focused pane to first pane in this window (or active pane if known)
                if let window = windows[windowId], let activePaneId = window.activePaneId {
                    focusedPaneId = activePaneId
                } else if let firstPaneId = tree.paneIds.first {
                    focusedPaneId = "%\(firstPaneId)"
                }
            } else {
                // No split tree yet — layout will come via %layout-change from Ghostty
                logger.info("📑 No split tree for window \(windowId), waiting for layout notification from Ghostty")
            }
        }
    }
    
    /// Handle layout changed notification with debouncing
    /// Rapid layout changes are coalesced to prevent UI thrashing
    func handleLayoutChanged(windowId: String, windowIndex: Int, layout: String) {
        // Strip trailing markers like " *" (active window) or " -" (last window)
        var cleanLayout = layout
        if cleanLayout.hasSuffix(" *") || cleanLayout.hasSuffix(" -") {
            cleanLayout = String(cleanLayout.dropLast(2))
        }
        
        // Skip if this layout is identical to the last one we processed for this window
        // This prevents redundant UI updates during rapid layout changes
        if lastProcessedLayouts[windowId] == cleanLayout {
            logger.debug("📐 Skipping duplicate layout for \(windowId)")
            return
        }
        
        // Store pending layout change for this window
        pendingLayoutChanges[windowId] = (cleanLayout, windowIndex)
        
        // Cancel existing debounce task
        layoutDebounceTask?.cancel()
        
        // Debounce: wait 30ms for rapid changes to settle before updating UI
        layoutDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000)  // 30ms
            guard !Task.isCancelled, let self = self else { return }
            
            await MainActor.run {
                // Process all pending layout changes
                let changes = self.pendingLayoutChanges
                self.pendingLayoutChanges.removeAll()
                
                for (windowId, change) in changes {
                    self.processLayoutChange(windowId: windowId, windowIndex: change.windowIndex, layout: change.layout)
                }
            }
        }
    }
    
    /// Process a layout change (called after debounce)
    private func processLayoutChange(windowId: String, windowIndex: Int, layout: String) {
        lastProcessedLayouts[windowId] = layout
        
        logger.info("📐 Layout changed: \(windowId) [\(windowIndex)] layout=\(layout.prefix(80))...")
        
        // Update window info if we have it
        if var window = windows[windowId] {
            window.layout = layout
            window.index = windowIndex
            windows[windowId] = window
        } else {
            // Create window entry if it doesn't exist yet
            var window = TmuxWindow(id: windowId, index: windowIndex, name: "window-\(windowIndex)", sessionId: currentSession?.id ?? "$0")
            window.layout = layout
            windows[windowId] = window
            logger.info("📐 Created window entry for \(windowId)")
        }
        
        // Parse layout and update split tree
        if let parsedLayout = try? TmuxLayout.parseWithChecksum(layout) {
            logger.info("📐 Parsed layout: \(parsedLayout.width)x\(parsedLayout.height) content=\(parsedLayout.content)")
            updatePanePositions(from: parsedLayout, in: windowId)
            updateSplitTree(from: parsedLayout, for: windowId)
        } else if let parsedLayout = try? TmuxLayout.parse(String(layout.dropFirst(5))) {
            // Try parsing without checksum (skip "XXXX," prefix)
            logger.info("📐 Parsed layout (no checksum): \(parsedLayout.width)x\(parsedLayout.height) content=\(parsedLayout.content)")
            updatePanePositions(from: parsedLayout, in: windowId)
            updateSplitTree(from: parsedLayout, for: windowId)
        } else {
            logger.error("📐 Failed to parse layout: \(layout)")
        }
    }
    
    /// Update the split tree for a window from a parsed layout
    private func updateSplitTree(from layout: TmuxLayout, for windowId: String) {
        let newTree = TmuxSplitTree.from(layout: layout)
        let oldTree = windowSplitTrees[windowId]
        windowSplitTrees[windowId] = newTree
        
        // Detect removed panes and clean up their surfaces
        if let oldTree = oldTree {
            let oldPaneIds = Set(oldTree.paneIds.map { "%\($0)" })
            let newPaneIds = Set(newTree.paneIds.map { "%\($0)" })
            let removedPaneIds = oldPaneIds.subtracting(newPaneIds)
            
            for paneId in removedPaneIds {
                logger.info("📐 🗑️ Pane \(paneId) was closed, cleaning up surface")
                
                // Check if this was our primary surface BEFORE removing
                let wasPrimarySurface = paneSurfaces[paneId] === primarySurface
                
                removeSurface(for: paneId, paneActuallyClosed: true)
                panes.removeValue(forKey: paneId)
                
                // Clean up output buffer for this pane
                pendingOutput.removeValue(forKey: paneId)
                
                // If the removed pane had our primary surface, reassign it atomically
                if wasPrimarySurface {
                    reassignPrimarySurface(excludingPaneId: paneId, fromPaneIds: newPaneIds)
                }
            }
            
            if !removedPaneIds.isEmpty {
                logger.info("📐 Cleaned up \(removedPaneIds.count) closed pane(s): \(removedPaneIds.sorted())")
            }
        }
        
        logger.info("📐 Split tree for \(windowId): panes=\(newTree.paneIds), isSplit=\(newTree.isSplit), focusedWindow=\(focusedWindowId)")
        
        // Log the tree details including dimensions for debugging
        if let rootNode = newTree.root {
            logTreeNode(rootNode, prefix: "📐 Tree: ")
        }
        
        // Update current split tree if this is the focused window,
        // or if focusedWindowId hasn't been set yet (initial connection)
        if windowId == focusedWindowId || focusedWindowId.isEmpty {
            if focusedWindowId.isEmpty {
                logger.info("📐 Setting focusedWindowId from first layout: \(windowId)")
                focusedWindowId = windowId
            }
            currentSplitTree = newTree
            logger.info("📐 ✅ Updated currentSplitTree: \(newTree.paneIds.count) panes, isSplit=\(newTree.isSplit)")
            
            // Ensure surfaces exist for all panes in this window
            // This is important when switching to a window that hasn't received output yet
            for numericPaneId in newTree.paneIds {
                let paneId = "%\(numericPaneId)"
                if paneSurfaces[paneId] == nil {
                    logger.info("📐 🆕 Pre-creating surface for pane \(paneId) in newly focused window")
                    _ = getSurfaceOrCreate(for: paneId)
                }
            }
            
            // Ensure primarySurface is valid (might be nil after window close)
            // Use the first pane in the new tree as primary
            if primarySurface == nil, let firstPaneId = newTree.paneIds.first {
                let paneId = "%\(firstPaneId)"
                if let surface = paneSurfaces[paneId] {
                    logger.info("📐 🔄 Assigning primarySurface to \(paneId) (was nil)")
                    primarySurface = surface
                    surface.onCellSizeChanged = { [weak self] cellSize in
                        self?.primaryCellSize = cellSize
                    }
                    // Manually trigger if cell size is already valid
                    if surface.cellSize.width > 0 && surface.cellSize.height > 0 {
                        primaryCellSize = surface.cellSize
                    }
                }
            }
            
            // Update focused pane if needed
            if let firstPaneId = newTree.paneIds.first {
                let paneIdStr = "%\(firstPaneId)"
                if focusedPaneId.isEmpty || paneSurfaces[focusedPaneId] == nil {
                    logger.info("📐 Updating focusedPaneId to \(paneIdStr)")
                    focusedPaneId = paneIdStr
                }
            }
        } else {
            logger.info("📐 ⏭️ Not updating currentSplitTree - windowId \(windowId) != focusedWindowId \(focusedWindowId)")
        }
    }
    
    /// Handle window pane changed notification
    func handleWindowPaneChanged(windowId: String, paneId: String) {
        logger.info("Window pane changed: \(windowId) -> \(paneId)")
        
        if var window = windows[windowId] {
            window.activePaneId = paneId
            windows[windowId] = window
        }
        
        // Update pane active states
        for (id, var pane) in panes where pane.windowId == windowId {
            pane.isActive = (id == paneId)
            panes[id] = pane
        }
        
        focusedPaneId = paneId
    }
    
    /// Handle pane mode changed notification
    func handlePaneModeChanged(paneId: String) {
        logger.debug("Pane mode changed: \(paneId)")
        // In native Ghostty mode, we can't query pane mode via command/response.
        // Ghostty's viewer handles mode changes internally.
    }
    
    /// Handle sessions changed notification
    /// This fires when a session is created or destroyed on the server.
    /// If it arrives before %session-changed, it means our connection created a new session.
    func handleSessionsChanged() {
        logger.info("Sessions changed - a session was created or destroyed")
        
        // Mark that a session creation/destruction happened before we saw %session-changed
        // This distinguishes "new session created" from "attached to existing"
        sawSessionsChanged = true
        
        // In native Ghostty mode, we can't query sessions via command/response.
        // Ghostty's viewer tracks session state internally and notifies via
        // TMUX_STATE_CHANGED. The sawSessionsChanged flag is what matters here.
        logger.debug("Sessions changed — relying on Ghostty state tracking")
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
        
        let surface = factory(paneId)
        
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
        factory: @escaping (String) -> Ghostty.SurfaceView,
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
        if surfaceResizeHandler != nil {
            surface.onResize = { [weak self] cols, rows in
                guard let self = self else { return }
                guard !self.currentSplitTree.isSplit else {
                    logger.debug("Ignoring surface resize in multi-pane mode (handled by container)")
                    return
                }
                Task { @MainActor in
                    self.surfaceResizeHandler?(cols, rows)
                }
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
            cmd += " -n '\(name)'"
        }
        sendCommandFireAndForget(cmd)
    }
    
    /// Close current window
    func closeWindow() {
        sendCommandFireAndForget("kill-window")
    }
    
    /// Close a specific window by ID
    func closeWindow(windowId: String) {
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
            }
        } else {
            // No split tree yet — in native Ghostty mode, select-window triggers
            // %layout-change which Ghostty processes, firing TMUX_STATE_CHANGED.
            // The layout will arrive via handleLayoutChanged() when it does.
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
    
    /// Update a split ratio and sync to tmux (legacy - use syncSplitRatioToTmux instead)
    /// Called when the user finishes dragging a divider.
    func updateSplitRatioAndSync(forPaneId paneId: Int, ratio: Double) {
        logger.info("📐 updateSplitRatioAndSync called: pane=\(paneId), ratio=\(String(format: "%.3f", ratio))")
        
        // First update local state
        updateSplitRatio(forPaneId: paneId, ratio: ratio)
        
        // Then send resize-pane to tmux
        // Find the split that contains this pane to determine direction and calculate size
        guard let splitInfo = findSplitContainingWithSize(paneId: paneId) else {
            logger.warning("⚠️ Could not find split containing %\(paneId)")
            return
        }
        
        logger.info("📐 Syncing resize to tmux: pane %\(paneId), ratio \(ratio), direction \(splitInfo.direction), totalSize \(splitInfo.totalSize)")
        
        // Calculate target size in cells
        // Account for 1 cell for the divider
        let availableSize = splitInfo.totalSize - 1
        let newSize = max(1, Int(Double(availableSize) * ratio))
        
        // Use resize-pane to set the exact size
        // For horizontal splits (left|right), we set width (-x)
        // For vertical splits (top|bottom), we set height (-y)
        let sizeFlag: String
        switch splitInfo.direction {
        case .horizontal:
            sizeFlag = "-x"
        case .vertical:
            sizeFlag = "-y"
        }
        
        let command = "resize-pane -t %\(paneId) \(sizeFlag) \(newSize)"
        logger.info("📐 Sending: \(command)")
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
    
    /// Send input to the focused pane
    /// Note: In native Ghostty tmux mode, keystrokes on stdin go directly to the
    /// active pane — send-keys is NOT needed. This is legacy dead code.
    /// Input routing goes through SSHSession → Ghostty write callback → SSH.
    func sendInput(_ data: Data) {
        guard let write = writeToSSH else { return }
        
        // Convert data to hex for send-keys -H
        let hexString = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        let command = "send-keys -H -t \(focusedPaneId) \(hexString)\n"
        write(command)
    }
    
    /// Send input to a specific pane
    /// Note: In native Ghostty tmux mode, keystrokes on stdin go directly to the
    /// active pane — send-keys is NOT needed. This is legacy dead code.
    /// Input routing goes through SSHSession → Ghostty write callback → SSH.
    func sendInput(_ data: Data, to paneId: String) {
        guard let write = writeToSSH else { return }
        
        // Convert data to hex for send-keys -H
        let hexString = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        let command = "send-keys -H -t \(paneId) \(hexString)\n"
        write(command)
    }
    
    // MARK: - Session Actions
    
    /// Create a new session
    func newSession(name: String) {
        sendCommandFireAndForget("new-session -d -s '\(name)'")
    }
    
    /// Switch to a session
    func switchSession(_ sessionId: String) {
        sendCommandFireAndForget("switch-client -t '\(sessionId)'")
    }
    
    /// Detach from current session
    func detach() {
        sendCommandFireAndForget("detach-client")
    }
    
    // MARK: - Layout Helpers
    
    /// Log tree node dimensions for debugging
    private func logTreeNode(_ node: TmuxSplitTree.Node, prefix: String) {
        switch node {
        case .leaf(let info):
            logger.info("\(prefix)Leaf pane %\(info.paneId): \(info.cols)x\(info.rows)")
        case .split(let split):
            logger.info("\(prefix)Split \(split.direction) ratio=\(String(format: "%.2f", split.ratio))")
            logTreeNode(split.left, prefix: prefix + "  L: ")
            logTreeNode(split.right, prefix: prefix + "  R: ")
        }
    }
    
    /// Update pane positions from parsed layout
    private func updatePanePositions(from layout: TmuxLayout, in windowId: String) {
        // Extract pane positions from layout tree
        let positions = extractPanePositions(from: layout)
        
        for position in positions {
            // tmux pane IDs in format strings are numeric, but we store them as "%0", "%1" etc.
            let paneId = "%\(position.paneId)"
            if var pane = panes[paneId] {
                pane.positionX = position.x
                pane.positionY = position.y
                pane.width = position.width
                pane.height = position.height
                panes[paneId] = pane
            }
        }
    }
    
    /// Pane position extracted from layout
    private struct PanePosition {
        let paneId: Int
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }
    
    /// Recursively extract pane positions from layout tree
    private func extractPanePositions(from layout: TmuxLayout) -> [PanePosition] {
        switch layout.content {
        case .pane(let id):
            return [PanePosition(paneId: id, x: layout.x, y: layout.y, width: layout.width, height: layout.height)]
        case .horizontal(let children), .vertical(let children):
            return children.flatMap { extractPanePositions(from: $0) }
        }
    }
    
    // MARK: - Query Response Handling
    
    /// Handle list-sessions response
    func handleSessionsResponse(_ content: String) {
        let lines = content.split(separator: "\n").map(String.init)
        
        var newSessions: [String: TmuxSession] = [:]
        for line in lines {
            if let session = TmuxSession.parse(line) {
                newSessions[session.id] = session
            }
        }
        
        sessions = newSessions
        logger.info("Updated sessions: \(sessions.count) sessions")
    }
    
    /// Handle list-windows response (legacy - delegates to parseWindowsResponse)
    func handleWindowsResponse(_ content: String, sessionId: String) {
        parseWindowsResponse(content)
    }
    
    /// Handle list-panes response (legacy - delegates to parsePanesResponse)
    func handlePanesResponse(_ content: String, windowId: String) {
        parsePanesResponse(content)
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
        layoutDebounceTask?.cancel()
        layoutDebounceTask = nil
        pendingLayoutChanges.removeAll()
        
        // Remove all surfaces
        for paneId in paneSurfaces.keys {
            removeSurface(for: paneId)
        }
        
        // Clear output buffers
        pendingOutput.removeAll()
        sawSessionsChanged = false
        sessionResumeStatus = nil
        
        sessions.removeAll()
        windows.removeAll()
        panes.removeAll()
        lastProcessedLayouts.removeAll()
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
    /// Get the focused pane
    var focusedPane: TmuxPane? {
        return panes[focusedPaneId]
    }
    
    /// Get the focused window
    var focusedWindow: TmuxWindow? {
        return windows[focusedWindowId]
    }
    
    /// Get panes for a window
    func panes(for windowId: String) -> [TmuxPane] {
        guard let window = windows[windowId] else { return [] }
        return window.paneIds.compactMap { panes[$0] }
    }
    
    /// Get windows for current session
    var currentSessionWindows: [TmuxWindow] {
        guard let session = currentSession else { return [] }
        return session.windowIds.compactMap { windows[$0] }
    }
}
