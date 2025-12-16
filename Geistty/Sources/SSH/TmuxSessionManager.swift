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
    
    /// Connection state
    @Published private(set) var isConnected: Bool = false
    
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
    
    /// Panes that have had their history restored (to avoid duplicate restores)
    private var restoredPanes: Set<String> = []
    
    /// Panes awaiting history restore - live output is buffered until history arrives
    /// This prevents the race condition where live output arrives before capture-pane response
    private var awaitingHistoryRestore: Set<String> = []
    
    /// Buffer for live output received while awaiting history restore
    /// This is separate from pendingOutput (which is for pre-surface output)
    private var historyRestoreBuffer: [String: [Data]] = [:]
    
    /// Buffer for history content received before surface was created
    /// This is fed to the surface when it's created
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
    /// Buffer for output received before surfaces are created
    /// This is essential for session restore which arrives before surface factory is configured
    private var pendingOutput: [String: [Data]] = [:]
    
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
        
        // Now that we have proper command routing, we can safely query state
        // The responses will be routed to our callbacks, not mixed with session restore
        refreshState()
    }
    
    /// Called when control mode exits
    func controlModeExited() {
        logger.info("🔌 Control mode exited, cleaning up state")
        isConnected = false
        currentSession = nil
        sessions.removeAll()
        windows.removeAll()
        panes.removeAll()
        windowSplitTrees.removeAll()
        currentSplitTree = TmuxSplitTree()
        restoredPanes.removeAll()
        lastProcessedLayouts.removeAll()
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
                removeSurface(for: paneId)
            }
        }
        
        // Remove window and its split tree
        windows.removeValue(forKey: windowId)
        windowSplitTrees.removeValue(forKey: windowId)
        
        // Update session's window list
        if var session = currentSession {
            session.windowIds.removeAll { $0 == windowId }
            sessions[session.id] = session
            currentSession = session
            
            // If this was the focused window, switch to another window
            if focusedWindowId == windowId {
                if let nextWindowId = session.windowIds.first {
                    logger.info("🗑️ Focused window closed, switching to \(nextWindowId)")
                    focusedWindowId = nextWindowId
                    
                    // Update current split tree to the new window
                    if let tree = windowSplitTrees[nextWindowId] {
                        currentSplitTree = tree
                        if let firstPaneId = tree.paneIds.first {
                            focusedPaneId = "%\(firstPaneId)"
                        }
                    }
                } else {
                    // No windows left - this shouldn't normally happen,
                    // tmux should send %exit when last window closes
                    logger.warning("🗑️ All windows closed but no %exit received")
                    currentSplitTree = TmuxSplitTree()
                }
            }
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
    
    /// Handle layout changed notification
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
        lastProcessedLayouts[windowId] = cleanLayout
        
        logger.info("📐 Layout changed: \(windowId) [\(windowIndex)] layout=\(cleanLayout.prefix(80))...")
        
        // Update window info if we have it
        if var window = windows[windowId] {
            window.layout = cleanLayout
            window.index = windowIndex
            windows[windowId] = window
        } else {
            // Create window entry if it doesn't exist yet
            var window = TmuxWindow(id: windowId, index: windowIndex, name: "window-\(windowIndex)", sessionId: currentSession?.id ?? "$0")
            window.layout = cleanLayout
            windows[windowId] = window
            logger.info("📐 Created window entry for \(windowId)")
        }
        
        // Parse layout and update split tree
        if let parsedLayout = try? TmuxLayout.parseWithChecksum(cleanLayout) {
            logger.info("📐 Parsed layout with checksum: \(parsedLayout.content)")
            updatePanePositions(from: parsedLayout, in: windowId)
            updateSplitTree(from: parsedLayout, for: windowId)
        } else if let parsedLayout = try? TmuxLayout.parse(String(cleanLayout.dropFirst(5))) {
            // Try parsing without checksum (skip "XXXX," prefix)
            logger.info("📐 Parsed layout without checksum: \(parsedLayout.content)")
            updatePanePositions(from: parsedLayout, in: windowId)
            updateSplitTree(from: parsedLayout, for: windowId)
        } else {
            logger.error("📐 Failed to parse layout: \(cleanLayout)")
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
                removeSurface(for: paneId)
                panes.removeValue(forKey: paneId)
                
                // If the removed pane was our primary surface, reassign it
                if paneId == "%0" {
                    // Find the first remaining pane's surface
                    if let firstRemainingPaneId = newPaneIds.sorted().first,
                       let remainingSurface = paneSurfaces[firstRemainingPaneId] {
                        logger.info("📐 🔄 Primary pane %0 closed, reassigning primarySurface to \(firstRemainingPaneId)")
                        primarySurface = remainingSurface
                        remainingSurface.onCellSizeChanged = { [weak self] cellSize in
                            self?.primaryCellSize = cellSize
                        }
                        // Manually trigger if cell size is already valid
                        if remainingSurface.cellSize.width > 0 && remainingSurface.cellSize.height > 0 {
                            primaryCellSize = remainingSurface.cellSize
                        }
                    }
                }
            }
            
            if !removedPaneIds.isEmpty {
                logger.info("📐 Cleaned up \(removedPaneIds.count) closed pane(s): \(removedPaneIds.sorted())")
            }
        }
        
        logger.info("📐 Split tree for \(windowId): panes=\(newTree.paneIds), isSplit=\(newTree.isSplit), focusedWindow=\(focusedWindowId)")
        
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
            
            // If we're down to a single pane, update focused pane ID and ensure primarySurface is set
            if newTree.paneIds.count == 1 {
                let remainingPaneId = "%\(newTree.paneIds[0])"
                if focusedPaneId != remainingPaneId {
                    logger.info("📐 Single pane remaining, updating focus to \(remainingPaneId)")
                    focusedPaneId = remainingPaneId
                }
                // Ensure primarySurface points to the remaining surface
                if let remainingSurface = paneSurfaces[remainingPaneId], primarySurface !== remainingSurface {
                    logger.info("📐 🔄 Reassigning primarySurface to remaining pane \(remainingPaneId)")
                    primarySurface = remainingSurface
                    remainingSurface.onCellSizeChanged = { [weak self] cellSize in
                        self?.primaryCellSize = cellSize
                    }
                    // Manually trigger if cell size is already valid
                    if remainingSurface.cellSize.width > 0 && remainingSurface.cellSize.height > 0 {
                        primaryCellSize = remainingSurface.cellSize
                    }
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
    func routeOutput(_ data: Data, to paneId: String) {
        // If this pane is awaiting history restore, buffer the live output
        // This prevents the race condition where live output arrives before capture-pane response
        if awaitingHistoryRestore.contains(paneId) {
            if historyRestoreBuffer[paneId] == nil {
                historyRestoreBuffer[paneId] = []
            }
            historyRestoreBuffer[paneId]?.append(data)
            logger.debug("📜 Buffering live output for pane \(paneId) awaiting history restore: \(data.count) bytes")
            return
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
        // Only the focused pane triggers resize to avoid thrashing with multiple windows
        // Also uses debouncing to coalesce rapid resize events
        if surfaceResizeHandler != nil {
            surface.onResize = { [weak self] cols, rows in
                guard let self = self else { return }
                // Only trigger resize from the focused pane to avoid multiple surfaces
                // all sending resize commands simultaneously
                if self.focusedPaneId == paneId {
                    self.debouncedResize(cols: cols, rows: rows)
                }
            }
        }
        
        paneSurfaces[paneId] = surface
        
        // If this is %0, also set as primary surface and wire up cell size callback
        if paneId == "%0" {
            primarySurface = surface
            surface.onCellSizeChanged = { [weak self] cellSize in
                self?.primaryCellSize = cellSize
                logger.info("📐 Primary cell size updated: \(Int(cellSize.width))x\(Int(cellSize.height))")
            }
            // CRITICAL: Manually trigger if cell size is already valid
            // The callback won't fire via didSet if the value was set before the callback was assigned
            if surface.cellSize.width > 0 && surface.cellSize.height > 0 {
                primaryCellSize = surface.cellSize
                logger.info("📐 Primary cell size initialized: \(Int(surface.cellSize.width))x\(Int(surface.cellSize.height))")
            }
        }
        
        logger.info("Created Ghostty surface for pane \(paneId)")
        
        // Check if there's buffered history content for this pane
        // This happens when history restore completed before the surface was created
        if let historyContent = pendingHistoryContent.removeValue(forKey: paneId) {
            logger.info("📜 Feeding buffered history content to new surface for pane \(paneId): \(historyContent.count) chars")
            feedHistoryToSurface(surface, content: historyContent, paneId: paneId)
            
            // Also flush any live output that was buffered during history restore
            if let buffered = historyRestoreBuffer.removeValue(forKey: paneId), !buffered.isEmpty {
                logger.info("📜 Flushing \(buffered.count) buffered live output chunks for pane \(paneId)")
                for data in buffered {
                    surface.feedData(data)
                }
            }
        }
        
        // Flush any pending output that was buffered before surface was available
        // This is critical for session restore which arrives before factory is configured
        if let pending = pendingOutput.removeValue(forKey: paneId), !pending.isEmpty {
            logger.info("🔄 Flushing \(pending.count) buffered chunks to new surface for pane \(paneId)")
            for data in pending {
                surface.feedData(data)
            }
        }
        
        // Restore scrollback history for this pane if not already done
        restorePaneHistoryIfNeeded(paneId: paneId)
        
        return surface
    }
    
    /// Restore scrollback history for a pane if not already restored
    private func restorePaneHistoryIfNeeded(paneId: String) {
        guard !restoredPanes.contains(paneId) else {
            logger.debug("📜 Pane \(paneId) history already restored, skipping")
            return
        }
        
        guard let client = controlClient, let write = writeToSSH else {
            logger.warning("📜 Cannot restore pane history - control client or write not available")
            return
        }
        
        logger.info("📜 Restoring scrollback history for pane \(paneId)")
        restoredPanes.insert(paneId)
        
        // Mark pane as awaiting history - live output will be buffered until history arrives
        awaitingHistoryRestore.insert(paneId)
        
        client.restorePaneHistory(paneId: paneId, via: write)
    }
    
    /// Called when history restore is complete for a pane
    /// Flushes any buffered live output that arrived during the restore
    func historyRestoreComplete(for paneId: String, content: String) {
        // Remove from awaiting set
        awaitingHistoryRestore.remove(paneId)
        
        // Try to get or create the surface
        guard let surface = getSurfaceOrCreate(for: paneId) else {
            // Surface not available yet - buffer the history for when surface is created
            logger.info("📜 History restore complete but no surface for \(paneId) - buffering content (\(content.count) chars)")
            pendingHistoryContent[paneId] = content
            return
        }
        
        // Feed history to the surface
        feedHistoryToSurface(surface, content: content, paneId: paneId)
        
        // Flush any live output that was buffered during history restore
        if let buffered = historyRestoreBuffer.removeValue(forKey: paneId), !buffered.isEmpty {
            logger.info("📜 Flushing \(buffered.count) buffered live output chunks for pane \(paneId)")
            for data in buffered {
                surface.feedData(data)
            }
        }
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
    
    /// Remove surface for a pane (but never remove primary surface)
    func removeSurface(for paneId: String) {
        // Never remove the primary surface - it's always kept alive
        if paneId == "%0" {
            logger.info("Keeping primary surface %0 alive")
            return
        }
        
        if let surface = paneSurfaces.removeValue(forKey: paneId) {
            // Clean up surface
            logger.info("Removed Ghostty surface for pane \(paneId)")
            // Surface will be deallocated when no longer referenced
            _ = surface
        }
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
        client.sendCommandFireAndForget("rename-window '\(name)'", via: write)
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
    func equalizeSplits() {
        guard let client = controlClient, let write = writeToSSH else { return }
        client.sendCommandFireAndForget("select-layout even-horizontal", via: write)
    }
    
    /// Debounced resize to prevent thrashing with rapid resize events
    /// Waits 50ms to coalesce multiple resize calls into one
    private func debouncedResize(cols: Int, rows: Int) {
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
    
    // MARK: - Cleanup
    
    /// Clean up all state
    func cleanup() {
        // Remove all surfaces
        for paneId in paneSurfaces.keys {
            removeSurface(for: paneId)
        }
        
        sessions.removeAll()
        windows.removeAll()
        panes.removeAll()
        lastProcessedLayouts.removeAll()
        currentSession = nil
        isConnected = false
        
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
