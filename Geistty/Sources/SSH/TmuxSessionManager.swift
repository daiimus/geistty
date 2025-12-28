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

// MARK: - Pane Restore State

/// State machine for pane history restore process
/// This ensures proper sequencing: surface created -> history requested -> history received -> live output flushed
enum PaneRestoreState: Equatable {
    /// Initial state - pane exists but no surface yet
    case awaitingSurface
    
    /// Surface created, history request sent, awaiting response
    /// Live output is buffered during this phase
    case awaitingHistory(bufferedOutput: [Data])
    
    /// History received and fed to surface, live output flushed
    /// Pane is now fully operational
    case restored
    
    /// Check if we should buffer live output
    var shouldBufferOutput: Bool {
        if case .awaitingHistory = self { return true }
        return false
    }
    
    /// Append output to buffer (only valid in awaitingHistory state)
    mutating func appendBufferedOutput(_ data: Data) {
        if case .awaitingHistory(var buffered) = self {
            buffered.append(data)
            self = .awaitingHistory(bufferedOutput: buffered)
        }
    }
    
    /// Get buffered output (only valid in awaitingHistory state)
    var bufferedOutput: [Data] {
        if case .awaitingHistory(let buffered) = self {
            return buffered
        }
        return []
    }
}

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
    
    /// All panes in the current session
    @Published private(set) var panes: [String: TmuxPane] = [:]
    
    /// Currently focused pane ID
    @Published private(set) var focusedPaneId: String = "%0"
    
    /// Currently focused window ID
    @Published private(set) var focusedWindowId: String = "@0"
    
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
    private var paneSurfaces: [String: Ghostty.SurfaceView] = [:]
    
    /// The primary surface for the initial pane (%0)
    /// This is always kept alive even when in multi-pane mode
    @Published private(set) var primarySurface: Ghostty.SurfaceView?
    
    /// Cell size from the primary surface (for calculating terminal dimensions)
    /// This is updated when the surface reports its cell size
    @Published private(set) var primaryCellSize: CGSize = .zero
    
    // MARK: - Pane Restore State Machine
    
    /// State machine for each pane's history restore process
    /// This replaces the multiple buffer dictionaries with a single source of truth
    private var paneRestoreStates: [String: PaneRestoreState] = [:]
    
    /// Buffer for output received before surfaces are created (pre-factory configuration)
    /// This is separate from the restore state machine - used only during initial connection
    private var pendingOutput: [String: [Data]] = [:]
    
    /// Buffer for history content received before surface was created
    private var pendingHistoryContent: [String: String] = [:]

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
    
    // MARK: - Control Client
    
    /// The control client for parsing tmux protocol
    private var controlClient: TmuxControlClient?
    
    /// Write function to send data to SSH
    private var writeToSSH: ((String) -> Void)?
    
    // MARK: - Subscriptions
    
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    init() {
        logger.info("TmuxSessionManager initialized")
    }
    
    // MARK: - Connection
    
    /// Set up the session manager with a control client
    func setup(controlClient: TmuxControlClient, write: @escaping (String) -> Void) {
        self.controlClient = controlClient
        self.writeToSSH = write
        
        // Set ourselves as the delegate for relevant events
        // Note: SSHSession is still the primary delegate, but it forwards to us
        
        logger.info("TmuxSessionManager connected to control client")
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
        
        // Clear pane restore state machine
        paneRestoreStates.removeAll()
        pendingHistoryContent.removeAll()
        pendingOutput.removeAll()
        
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
    
    /// Refresh all state from tmux server
    /// Uses proper command routing so responses don't interfere with session restore
    func refreshState() {
        guard let client = controlClient, let write = writeToSSH else {
            logger.warning("Cannot refresh state: control client or write not available")
            return
        }
        
        logger.info("Refreshing tmux state")
        
        // Query sessions with proper callback
        client.sendCommand("list-sessions -F '\(TmuxQueryFormat.sessions)'", via: write) { [weak self] result in
            switch result {
            case .success(let response):
                self?.parseSessionsResponse(response)
            case .failure(let error):
                logger.error("Failed to list sessions: \(error.localizedDescription)")
            }
        }
        
        // Query windows in current session
        client.sendCommand("list-windows -F '\(TmuxQueryFormat.windows)'", via: write) { [weak self] result in
            switch result {
            case .success(let response):
                self?.parseWindowsResponse(response)
            case .failure(let error):
                logger.error("Failed to list windows: \(error.localizedDescription)")
            }
        }
        
        // Query all panes
        client.sendCommand("list-panes -a -F '\(TmuxQueryFormat.panes)'", via: write) { [weak self] result in
            switch result {
            case .success(let response):
                self?.parsePanesResponse(response)
            case .failure(let error):
                logger.error("Failed to list panes: \(error.localizedDescription)")
            }
        }
    }
    
    /// Query windows for a specific session
    func queryWindows(for sessionId: String) {
        guard let client = controlClient, let write = writeToSSH else { return }
        
        client.sendCommand("list-windows -t '\(sessionId)' -F '\(TmuxQueryFormat.windows)'", via: write) { [weak self] result in
            if case .success(let response) = result {
                self?.parseWindowsResponse(response)
            }
        }
    }
    
    /// Query panes for a specific window
    func queryPanes(for windowId: String) {
        guard let client = controlClient, let write = writeToSSH else { return }
        
        client.sendCommand("list-panes -t '\(windowId)' -F '\(TmuxQueryFormat.panes)'", via: write) { [weak self] result in
            if case .success(let response) = result {
                self?.parsePanesResponse(response)
            }
        }
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
    
    /// Handle session changed notification
    func handleSessionChanged(sessionId: String, sessionName: String) {
        logger.info("Session changed: \(sessionId) (\(sessionName))")
        
        // Update or create session
        var session = sessions[sessionId] ?? TmuxSession(id: sessionId, name: sessionName)
        session.name = sessionName
        session.isAttached = true
        
        sessions[sessionId] = session
        currentSession = session
        
        // Query windows for this session
        queryWindows(for: sessionId)
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
        
        // Query window details using proper command routing
        guard let client = controlClient, let write = writeToSSH else { return }
        
        // Query both window info and layout in parallel
        client.sendCommand("display-message -t '\(windowId)' -p '#{window_index} #{window_name}'", via: write) { [weak self] result in
            if case .success(let response) = result {
                let parts = response.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 1)
                if parts.count >= 2, let index = Int(parts[0]) {
                    if var window = self?.windows[windowId] {
                        window.index = index
                        window.name = String(parts[1])
                        self?.windows[windowId] = window
                        logger.info("📑 Window \(windowId) details: index=\(index) name=\(parts[1])")
                    }
                }
            }
        }
        
        // Also query the layout for this window to build its split tree
        client.sendCommand("display-message -t '\(windowId)' -p '#{window_layout}'", via: write) { [weak self] result in
            guard let self = self else { return }
            if case .success(let response) = result {
                let layoutStr = response.trimmingCharacters(in: .whitespacesAndNewlines)
                if !layoutStr.isEmpty {
                    logger.info("📑 Queried layout for new window \(windowId): \(layoutStr.prefix(50))...")
                    // Parse and create split tree
                    if let parsedLayout = try? TmuxLayout.parseWithChecksum(layoutStr) {
                        self.updatePanePositions(from: parsedLayout, in: windowId)
                        self.updateSplitTree(from: parsedLayout, for: windowId)
                    } else if let parsedLayout = try? TmuxLayout.parse(String(layoutStr.dropFirst(5))) {
                        self.updatePanePositions(from: parsedLayout, in: windowId)
                        self.updateSplitTree(from: parsedLayout, for: windowId)
                    }
                }
            }
        }
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
                
                // Clean up buffer state for this pane
                paneRestoreStates.removeValue(forKey: paneId)
                pendingHistoryContent.removeValue(forKey: paneId)
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
                    focusedPaneId = "%0"
                    focusedWindowId = "@0"
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
                // No split tree yet - query the layout
                logger.info("📑 No split tree for window \(windowId), querying layout...")
                
                guard let client = controlClient, let write = writeToSSH else { return }
                
                client.sendCommand("display-message -t '\(windowId)' -p '#{window_layout}'", via: write) { [weak self] result in
                    guard let self = self else { return }
                    if case .success(let response) = result {
                        let layoutStr = response.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !layoutStr.isEmpty {
                            logger.info("📑 Got layout for window \(windowId): \(layoutStr.prefix(50))...")
                            
                            // Parse and create split tree
                            if let parsedLayout = try? TmuxLayout.parseWithChecksum(layoutStr) {
                                self.updatePanePositions(from: parsedLayout, in: windowId)
                                self.updateSplitTree(from: parsedLayout, for: windowId)
                            } else if let parsedLayout = try? TmuxLayout.parse(String(layoutStr.dropFirst(5))) {
                                self.updatePanePositions(from: parsedLayout, in: windowId)
                                self.updateSplitTree(from: parsedLayout, for: windowId)
                            }
                        }
                    }
                }
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
                
                // Clear pane restore state to prevent memory leak
                paneRestoreStates.removeValue(forKey: paneId)
                pendingHistoryContent.removeValue(forKey: paneId)
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
        
        // Update current split tree if this is the focused window
        if windowId == focusedWindowId {
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
        
        // Query pane mode using proper command routing
        guard let client = controlClient, let write = writeToSSH else { return }
        
        client.sendCommand("display-message -t '\(paneId)' -p '#{pane_in_mode}'", via: write) { [weak self] result in
            if case .success(let response) = result {
                let inMode = response.trimmingCharacters(in: .whitespacesAndNewlines) != "0"
                if var pane = self?.panes[paneId] {
                    pane.mode = inMode ? .copy : .normal
                    self?.panes[paneId] = pane
                }
            }
        }
    }
    
    /// Handle sessions changed notification
    func handleSessionsChanged() {
        logger.info("Sessions changed - refreshing session list")
        
        guard let client = controlClient, let write = writeToSSH else { return }
        
        client.sendCommand("list-sessions -F '\(TmuxQueryFormat.sessions)'", via: write) { [weak self] result in
            if case .success(let response) = result {
                self?.parseSessionsResponse(response)
            }
        }
    }
    
    // MARK: - Pane Output Routing
    
    /// Route pane output to the appropriate Ghostty surface
    /// Uses state machine to ensure proper sequencing with history restore
    func routeOutput(_ data: Data, to paneId: String) {
        // Check pane restore state
        if let state = paneRestoreStates[paneId] {
            if state.shouldBufferOutput {
                // Buffer output while awaiting history restore
                paneRestoreStates[paneId]?.appendBufferedOutput(data)
                logger.debug("📜 Buffering live output for pane \(paneId) awaiting history: \(data.count) bytes")
                return
            }
            // State is .restored - proceed normally
        }
        
        // Get existing surface or create one if factory is available
        guard let surface = getSurfaceOrCreate(for: paneId) else {
            // No surface available - buffer the output for later
            // This happens for session restore which arrives before surface factory is configured
            if pendingOutput[paneId] == nil {
                pendingOutput[paneId] = []
            }
            pendingOutput[paneId]?.append(data)
            logger.debug("Buffered \(data.count) bytes for pane \(paneId) (total: \(self.pendingOutput[paneId]?.count ?? 0) chunks)")
            return
        }
        
        // Feed data to the surface
        surface.feedData(data)
        
        // Update pane in our model if it doesn't exist
        if panes[paneId] == nil {
            // Create a placeholder pane
            let pane = TmuxPane(id: paneId, windowId: focusedWindowId, width: 80, height: 24)
            panes[paneId] = pane
        }
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
        // or for pane %0 which always exists initially
        if let numericId = Int(paneId.dropFirst()) {  // "%0" -> 0
            let treeIsEmpty = currentSplitTree.paneIds.isEmpty
            let paneExistsInTree = currentSplitTree.paneIds.contains(numericId)
            let isPrimaryPane = numericId == 0
            
            if !treeIsEmpty && !paneExistsInTree && !isPrimaryPane {
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
        
        // If this is %0, also set as primary surface and wire up cell size callback
        if paneId == "%0" {
            assignPrimarySurface(surface, forPaneId: paneId)
        }
        
        logger.info("Created Ghostty surface for pane \(paneId)")
        
        // Handle history restore based on pane state
        handleSurfaceCreatedForRestore(surface, paneId: paneId)
        
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
    
    /// Handle surface creation in context of history restore state machine
    private func handleSurfaceCreatedForRestore(_ surface: Ghostty.SurfaceView, paneId: String) {
        let currentState = paneRestoreStates[paneId]
        
        // Check if there's buffered history content for this pane (history arrived before surface)
        if let historyContent = pendingHistoryContent.removeValue(forKey: paneId) {
            logger.info("📜 Feeding buffered history content to new surface for pane \(paneId): \(historyContent.count) chars")
            feedHistoryToSurface(surface, content: historyContent, paneId: paneId)
            
            // Flush any buffered live output that arrived during history restore
            if let state = currentState, case .awaitingHistory(let buffered) = state, !buffered.isEmpty {
                logger.info("📜 Flushing \(buffered.count) buffered live output chunks for pane \(paneId)")
                for data in buffered {
                    surface.feedData(data)
                }
            }
            
            // Flush any pre-surface output
            if let pending = pendingOutput.removeValue(forKey: paneId), !pending.isEmpty {
                logger.info("🔄 Flushing \(pending.count) pre-surface chunks for pane \(paneId)")
                for data in pending {
                    surface.feedData(data)
                }
            }
            
            // Mark as restored
            paneRestoreStates[paneId] = .restored
            
        } else if currentState == .restored {
            // History was already restored for this pane (e.g., surface recreated)
            // Safe to flush pending output directly
            if let pending = pendingOutput.removeValue(forKey: paneId), !pending.isEmpty {
                logger.info("🔄 Flushing \(pending.count) buffered chunks to surface for pane \(paneId) (already restored)")
                for data in pending {
                    surface.feedData(data)
                }
            }
        } else {
            // History restore hasn't happened yet - move pendingOutput to state buffer
            var buffered: [Data] = []
            if let pending = pendingOutput.removeValue(forKey: paneId), !pending.isEmpty {
                logger.info("📜 Moving \(pending.count) pre-surface chunks to history restore buffer for pane \(paneId)")
                buffered = pending
            }
            
            // Now start history restore
            startHistoryRestore(paneId: paneId, withBuffer: buffered)
        }
    }
    
    /// Start history restore for a pane
    private func startHistoryRestore(paneId: String, withBuffer existingBuffer: [Data] = []) {
        // Check if already restoring or restored
        if let state = paneRestoreStates[paneId] {
            if state == .restored || state.shouldBufferOutput {
                logger.debug("📜 Pane \(paneId) already in restore process, skipping")
                return
            }
        }
        
        guard let client = controlClient, let write = writeToSSH else {
            logger.warning("📜 Cannot restore pane history - control client or write not available")
            return
        }
        
        logger.info("📜 Restoring scrollback history for pane \(paneId)")
        
        // Transition to awaiting history state with any existing buffered data
        paneRestoreStates[paneId] = .awaitingHistory(bufferedOutput: existingBuffer)
        
        client.restorePaneHistory(paneId: paneId, via: write)
    }
    
    /// Called when history restore is complete for a pane
    /// Flushes any buffered live output that arrived during the restore
    func historyRestoreComplete(for paneId: String, content: String) {
        // Get the buffered output from state machine before transitioning
        let bufferedOutput: [Data]
        if let state = paneRestoreStates[paneId], case .awaitingHistory(let buffered) = state {
            bufferedOutput = buffered
        } else {
            bufferedOutput = []
        }
        
        // Try to get or create the surface
        guard let surface = getSurfaceOrCreate(for: paneId) else {
            // Surface not available yet - buffer the history for when surface is created
            logger.info("📜 History restore complete but no surface for \(paneId) - buffering content (\(content.count) chars)")
            pendingHistoryContent[paneId] = content
            // Keep the state as awaitingHistory so buffered output is preserved
            return
        }
        
        // Feed history to the surface
        feedHistoryToSurface(surface, content: content, paneId: paneId)
        
        // Flush any live output that was buffered during history restore
        if !bufferedOutput.isEmpty {
            logger.info("📜 Flushing \(bufferedOutput.count) buffered live output chunks for pane \(paneId)")
            for data in bufferedOutput {
                surface.feedData(data)
            }
        }
        
        // Transition to restored state
        paneRestoreStates[paneId] = .restored
        logger.info("📜 ✅ Pane \(paneId) history restore complete")
    }
    
    /// Feed captured history content to a surface
    private func feedHistoryToSurface(_ surface: Ghostty.SurfaceView, content: String, paneId: String) {
        // Strip trailing empty lines from captured content
        // capture-pane includes all lines up to cursor, which may include many blank lines
        var lines = content.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        let trimmedContent = lines.joined(separator: "\n")
        
        guard !trimmedContent.isEmpty else {
            logger.info("📜 No history content to feed for pane \(paneId)")
            return
        }
        
        // Clear the screen and feed history content
        // ESC[2J = clear entire screen, ESC[H = move cursor to home position
        let clearScreen = "\u{1b}[2J\u{1b}[H"
        if let clearData = clearScreen.data(using: .utf8) {
            surface.feedData(clearData)
        }
        
        // Feed captured session content to terminal
        // Convert \n to \r\n for proper terminal display (CR moves to column 0, LF moves down)
        let terminalContent = trimmedContent.replacingOccurrences(of: "\n", with: "\r\n")
        if let data = terminalContent.data(using: .utf8) {
            surface.feedData(data)
        }
        logger.info("📜 Fed history content to pane \(paneId): \(trimmedContent.count) chars (trimmed from \(content.count))")
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
    
    /// Create the primary surface for pane %0
    /// This should be called early in the connection lifecycle
    func createPrimarySurface() -> Ghostty.SurfaceView? {
        guard surfaceFactory != nil else {
            logger.warning("⚠️ Cannot create primary surface - factory not configured")
            return nil
        }
        
        // Create surface for %0 if it doesn't exist (getSurfaceOrCreate handles primarySurface assignment)
        if let existing = paneSurfaces["%0"] {
            logger.info("Primary surface already exists")
            return existing
        }
        
        let surface = getSurfaceOrCreate(for: "%0")
        logger.info("✅ Created primary surface for %0")
        return surface
    }
    
    /// Get surface for a pane (returns nil if not created)
    func getSurface(for paneId: String) -> Ghostty.SurfaceView? {
        return paneSurfaces[paneId]
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
        guard let client = controlClient, let write = writeToSSH else { return }
        
        var cmd = "new-window"
        if let name = name {
            cmd += " -n '\(name)'"
        }
        client.sendCommandFireAndForget(cmd, via: write)
    }
    
    /// Close current window
    func closeWindow() {
        guard let client = controlClient, let write = writeToSSH else { return }
        client.sendCommandFireAndForget("kill-window", via: write)
    }
    
    /// Close a specific window by ID
    func closeWindow(windowId: String) {
        guard let client = controlClient, let write = writeToSSH else { return }
        client.sendCommandFireAndForget("kill-window -t '\(windowId)'", via: write)
    }
    
    /// Rename current window
    func renameWindow(_ name: String) {
        guard let client = controlClient, let write = writeToSSH else { return }
        // Escape single quotes in name to prevent command injection
        let safeName = name.replacingOccurrences(of: "'", with: "'\\''")
        client.sendCommandFireAndForget("rename-window '\(safeName)'", via: write)
    }
    
    /// Rename a specific window by ID
    func renameWindow(windowId: String, name: String) {
        guard let client = controlClient, let write = writeToSSH else { return }
        // Escape single quotes in name to prevent command injection
        let safeName = name.replacingOccurrences(of: "'", with: "'\\''")
        client.sendCommandFireAndForget("rename-window -t '\(windowId)' '\(safeName)'", via: write)
    }
    
    /// Select a window by ID
    func selectWindow(_ windowId: String) {
        guard let client = controlClient, let write = writeToSSH else {
            logger.warning("📑 selectWindow(\(windowId)) - NO client or write!")
            return
        }
        
        logger.info("📑 selectWindow: \(windowId)")
        logger.info("📑   Current windows: \(windows.keys.sorted().joined(separator: ", "))")
        logger.info("📑   Current split trees: \(windowSplitTrees.keys.sorted().joined(separator: ", "))")
        
        // Send select-window command to tmux
        client.sendCommandFireAndForget("select-window -t '\(windowId)'", via: write)
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
            // No split tree yet - show loading state and query the layout
            logger.info("📑 No split tree for window \(windowId), querying layout...")
            
            // Clear current split tree while we load the new window's layout
            // This prevents showing the old window's content during transition
            currentSplitTree = TmuxSplitTree()
            
            client.sendCommand("display-message -t '\(windowId)' -p '#{window_layout}'", via: write) { [weak self] result in
                guard let self = self else { return }
                if case .success(let response) = result {
                    let layoutStr = response.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !layoutStr.isEmpty {
                        logger.info("📑 Got layout for window \(windowId): \(layoutStr.prefix(50))...")
                        
                        // Parse and create split tree
                        if let parsedLayout = try? TmuxLayout.parseWithChecksum(layoutStr) {
                            self.updatePanePositions(from: parsedLayout, in: windowId)
                            self.updateSplitTree(from: parsedLayout, for: windowId)
                        } else if let parsedLayout = try? TmuxLayout.parse(String(layoutStr.dropFirst(5))) {
                            self.updatePanePositions(from: parsedLayout, in: windowId)
                            self.updateSplitTree(from: parsedLayout, for: windowId)
                        } else {
                            logger.error("📑 Failed to parse layout for window \(windowId)")
                        }
                    } else {
                        logger.warning("📑 Empty layout received for window \(windowId)")
                    }
                } else if case .failure(let error) = result {
                    logger.error("📑 Failed to query layout for window \(windowId): \(error)")
                }
            }
        }
    }
    
    /// Navigate to next window (tab)
    func nextWindow() {
        guard let client = controlClient, let write = writeToSSH else { return }
        client.sendCommandFireAndForget("next-window", via: write)
    }
    
    /// Navigate to previous window (tab)
    func previousWindow() {
        guard let client = controlClient, let write = writeToSSH else { return }
        client.sendCommandFireAndForget("previous-window", via: write)
    }
    
    /// Navigate to last window (most recently used)
    func lastWindow() {
        guard let client = controlClient, let write = writeToSSH else { return }
        client.sendCommandFireAndForget("last-window", via: write)
    }
    
    /// Navigate to window by index (1-based like Ghostty Cmd+1-8)
    func selectWindowByIndex(_ index: Int) {
        guard let client = controlClient, let write = writeToSSH else { return }
        // tmux uses 0-based indexing by default, but we accept 1-based from Ghostty shortcuts
        client.sendCommandFireAndForget("select-window -t :\(index - 1)", via: write)
    }
    
    /// Navigate to next pane
    func nextPane() {
        guard let client = controlClient, let write = writeToSSH else { return }
        client.sendCommandFireAndForget("select-pane -t :.+", via: write)
    }
    
    /// Navigate to previous pane
    func previousPane() {
        guard let client = controlClient, let write = writeToSSH else { return }
        client.sendCommandFireAndForget("select-pane -t :.-", via: write)
    }
    
    /// Toggle pane zoom (tmux zoom)
    func toggleTmuxZoom() {
        guard let client = controlClient, let write = writeToSSH else { return }
        client.sendCommandFireAndForget("resize-pane -Z", via: write)
    }
    
    /// Split pane horizontally (side by side)
    func splitHorizontal() {
        guard let client = controlClient, let write = writeToSSH else { return }
        client.sendCommandFireAndForget("split-window -h", via: write)
    }
    
    /// Split pane vertically (stacked)
    func splitVertical() {
        guard let client = controlClient, let write = writeToSSH else { return }
        client.sendCommandFireAndForget("split-window -v", via: write)
    }
    
    /// Close current pane
    func closePane() {
        guard let client = controlClient, let write = writeToSSH else { return }
        client.sendCommandFireAndForget("kill-pane", via: write)
    }
    
    /// Select a pane by ID
    func selectPane(_ paneId: String) {
        guard let client = controlClient, let write = writeToSSH else { return }
        client.sendCommandFireAndForget("select-pane -t '\(paneId)'", via: write)
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
        guard let client = controlClient, let write = writeToSSH else { return }
        
        let dirFlag: String
        switch direction {
        case .up: dirFlag = "-U"
        case .down: dirFlag = "-D"
        case .left: dirFlag = "-L"
        case .right: dirFlag = "-R"
        }
        client.sendCommandFireAndForget("select-pane \(dirFlag)", via: write)
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
        guard let client = controlClient, let write = writeToSSH else { return }
        
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
        client.sendCommandFireAndForget("select-layout \(layout)", via: write)
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
        guard let client = controlClient, let write = writeToSSH else {
            logger.warning("⚠️ No tmux client or write function - cannot sync resize")
            return
        }
        
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
        client.sendCommandFireAndForget(command, via: write)
    }
    
    /// Update a split ratio and sync to tmux (legacy - use syncSplitRatioToTmux instead)
    /// Called when the user finishes dragging a divider.
    func updateSplitRatioAndSync(forPaneId paneId: Int, ratio: Double) {
        logger.info("📐 updateSplitRatioAndSync called: pane=\(paneId), ratio=\(String(format: "%.3f", ratio))")
        
        // First update local state
        updateSplitRatio(forPaneId: paneId, ratio: ratio)
        
        // Then send resize-pane to tmux
        guard let client = controlClient, let write = writeToSSH else {
            logger.warning("⚠️ No tmux client or write function - cannot sync resize")
            return
        }
        
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
        client.sendCommandFireAndForget(command, via: write)
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
        controlClient?.resize(cols: cols, rows: rows, via: { [weak self] cmd in
            self?.writeToSSH?(cmd)
        })
    }
    
    /// Send input to the focused pane
    func sendInput(_ data: Data) {
        guard let write = writeToSSH else { return }
        
        let command = controlClient?.makeSendKeysCommand(for: data, toPaneId: focusedPaneId) ?? ""
        write(command)
    }
    
    /// Send input to a specific pane
    func sendInput(_ data: Data, to paneId: String) {
        guard let write = writeToSSH else { return }
        
        let command = controlClient?.makeSendKeysCommand(for: data, toPaneId: paneId) ?? ""
        write(command)
    }
    
    // MARK: - Session Actions
    
    /// Create a new session
    func newSession(name: String) {
        guard let client = controlClient, let write = writeToSSH else { return }
        client.sendCommandFireAndForget("new-session -d -s '\(name)'", via: write)
    }
    
    /// Switch to a session
    func switchSession(_ sessionId: String) {
        guard let client = controlClient, let write = writeToSSH else { return }
        client.sendCommandFireAndForget("switch-client -t '\(sessionId)'", via: write)
    }
    
    /// Detach from current session
    func detach() {
        guard let client = controlClient, let write = writeToSSH else { return }
        client.sendCommandFireAndForget("detach-client", via: write)
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
        
        // Clear pane restore state machine
        paneRestoreStates.removeAll()
        pendingHistoryContent.removeAll()
        pendingOutput.removeAll()
        
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
