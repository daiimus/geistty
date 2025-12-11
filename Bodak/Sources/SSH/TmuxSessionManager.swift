//
//  TmuxSessionManager.swift
//  Bodak
//
//  Manages tmux session/window/pane state and coordinates with Ghostty surfaces.
//  This is the central hub for tmux integration.
//

import Foundation
import os.log
import Combine

private let logger = Logger(subsystem: "com.bodak", category: "TmuxSession")

/// Manages the mapping between tmux server state and Bodak UI
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
    
    // MARK: - Surface Management
    
    /// Ghostty surfaces for each pane (paneId -> surface)
    /// Surfaces are created on-demand when output is received
    private var paneSurfaces: [String: Ghostty.SurfaceView] = [:]
    
    /// Surface creation factory (injected from terminal view)
    var surfaceFactory: ((String) -> Ghostty.SurfaceView)?
    
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
        
        // Query the current state
        refreshState()
    }
    
    /// Called when control mode exits
    func controlModeExited() {
        isConnected = false
        currentSession = nil
        sessions.removeAll()
        windows.removeAll()
        panes.removeAll()
    }
    
    // MARK: - State Queries
    
    /// Refresh all state from tmux server
    func refreshState() {
        guard let write = writeToSSH else { return }
        
        logger.info("Refreshing tmux state")
        
        // Query sessions
        let sessionsCmd = "list-sessions -F '\(TmuxQueryFormat.sessions)'\n"
        write(sessionsCmd)
        
        // Query windows in current session
        let windowsCmd = "list-windows -F '\(TmuxQueryFormat.windows)'\n"
        write(windowsCmd)
        
        // Query panes in current window
        let panesCmd = "list-panes -a -F '\(TmuxQueryFormat.panes)'\n"
        write(panesCmd)
    }
    
    /// Query windows for a specific session
    func queryWindows(for sessionId: String) {
        guard let write = writeToSSH else { return }
        
        let cmd = "list-windows -t '\(sessionId)' -F '\(TmuxQueryFormat.windows)'\n"
        write(cmd)
    }
    
    /// Query panes for a specific window
    func queryPanes(for windowId: String) {
        guard let write = writeToSSH else { return }
        
        let cmd = "list-panes -t '\(windowId)' -F '\(TmuxQueryFormat.panes)'\n"
        write(cmd)
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
        logger.info("Window added: \(windowId)")
        
        guard let sessionId = currentSession?.id else { return }
        
        // Create placeholder window, will be filled in by query
        let window = TmuxWindow(id: windowId, index: windows.count, name: "new", sessionId: sessionId)
        windows[windowId] = window
        
        // Query window details
        let cmd = "display-message -t '\(windowId)' -p '#{window_index} #{window_name}'\n"
        writeToSSH?(cmd)
    }
    
    /// Handle window closed notification
    func handleWindowClose(windowId: String) {
        logger.info("Window closed: \(windowId)")
        
        // Clean up associated panes
        if let window = windows[windowId] {
            for paneId in window.paneIds {
                panes.removeValue(forKey: paneId)
                removeSurface(for: paneId)
            }
        }
        
        windows.removeValue(forKey: windowId)
        
        // Update session's window list
        if var session = currentSession {
            session.windowIds.removeAll { $0 == windowId }
            sessions[session.id] = session
            currentSession = session
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
    
    /// Handle layout changed notification
    func handleLayoutChanged(windowId: String, windowIndex: Int, layout: String) {
        logger.debug("Layout changed: \(windowId) [\(windowIndex)] \(layout.prefix(50))...")
        
        if var window = windows[windowId] {
            window.layout = layout
            window.index = windowIndex
            windows[windowId] = window
            
            // Parse layout to update pane positions
            if let parsedLayout = TmuxLayout.parse(layout) {
                updatePanePositions(from: parsedLayout, in: windowId)
            }
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
        
        // Query pane mode
        let cmd = "display-message -t '\(paneId)' -p '#{pane_in_mode}'\n"
        writeToSSH?(cmd)
    }
    
    /// Handle sessions changed notification
    func handleSessionsChanged() {
        logger.info("Sessions changed - refreshing session list")
        
        let cmd = "list-sessions -F '\(TmuxQueryFormat.sessions)'\n"
        writeToSSH?(cmd)
    }
    
    // MARK: - Pane Output Routing
    
    /// Route pane output to the appropriate Ghostty surface
    func routeOutput(_ data: Data, to paneId: String) {
        // Get existing surface or create one if factory is available
        guard let surface = getSurfaceOrCreate(for: paneId) else {
            // No surface available - this can happen before surface factory is set
            // or for panes we're not rendering yet
            logger.debug("No surface available for pane \(paneId), output dropped")
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
        
        let surface = factory(paneId)
        paneSurfaces[paneId] = surface
        
        logger.info("Created Ghostty surface for pane \(paneId)")
        
        return surface
    }
    
    /// Get or create a Ghostty surface for a pane
    /// - Warning: Crashes if factory is not set and surface doesn't exist
    func getOrCreateSurface(for paneId: String) -> Ghostty.SurfaceView {
        if let existing = paneSurfaces[paneId] {
            return existing
        }
        
        // Create new surface
        guard let factory = surfaceFactory else {
            fatalError("Surface factory not set - call setSurfaceFactory before routing output")
        }
        
        let surface = factory(paneId)
        paneSurfaces[paneId] = surface
        
        logger.info("Created Ghostty surface for pane \(paneId)")
        
        return surface
    }
    
    /// Register an existing surface for a pane (e.g., the initial surface for %0)
    func registerExistingSurface(_ surface: Ghostty.SurfaceView, for paneId: String) {
        paneSurfaces[paneId] = surface
        logger.info("Registered existing surface for pane \(paneId)")
    }
    
    /// Get surface for a pane (returns nil if not created)
    func getSurface(for paneId: String) -> Ghostty.SurfaceView? {
        return paneSurfaces[paneId]
    }
    
    /// Remove surface for a pane
    func removeSurface(for paneId: String) {
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
        var cmd = "new-window"
        if let name = name {
            cmd += " -n '\(name)'"
        }
        cmd += "\n"
        writeToSSH?(cmd)
    }
    
    /// Close current window
    func closeWindow() {
        writeToSSH?("kill-window\n")
    }
    
    /// Rename current window
    func renameWindow(_ name: String) {
        writeToSSH?("rename-window '\(name)'\n")
    }
    
    /// Select a window by ID
    func selectWindow(_ windowId: String) {
        writeToSSH?("select-window -t '\(windowId)'\n")
        focusedWindowId = windowId
    }
    
    /// Split pane horizontally (side by side)
    func splitHorizontal() {
        writeToSSH?("split-window -h\n")
    }
    
    /// Split pane vertically (stacked)
    func splitVertical() {
        writeToSSH?("split-window -v\n")
    }
    
    /// Close current pane
    func closePane() {
        writeToSSH?("kill-pane\n")
    }
    
    /// Select a pane by ID
    func selectPane(_ paneId: String) {
        writeToSSH?("select-pane -t '\(paneId)'\n")
        focusedPaneId = paneId
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
        writeToSSH?("select-pane \(dirFlag)\n")
    }
    
    enum PaneDirection {
        case up, down, left, right
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
        writeToSSH?("new-session -d -s '\(name)'\n")
    }
    
    /// Switch to a session
    func switchSession(_ sessionId: String) {
        writeToSSH?("switch-client -t '\(sessionId)'\n")
    }
    
    /// Detach from current session
    func detach() {
        writeToSSH?("detach-client\n")
    }
    
    // MARK: - Layout Helpers
    
    /// Update pane positions from parsed layout
    private func updatePanePositions(from layout: TmuxLayout, in windowId: String) {
        // Extract pane positions from layout tree
        let positions = extractPanePositions(from: layout.root)
        
        for position in positions {
            if var pane = panes[position.paneId] {
                pane.positionX = position.x
                pane.positionY = position.y
                pane.width = position.width
                pane.height = position.height
                panes[position.paneId] = pane
            }
        }
    }
    
    /// Recursively extract pane positions from layout tree
    private func extractPanePositions(from node: TmuxLayout.LayoutNode) -> [TmuxLayout.PaneLayout] {
        switch node {
        case .pane(let layout):
            return [layout]
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
    
    /// Handle list-windows response
    func handleWindowsResponse(_ content: String, sessionId: String) {
        let lines = content.split(separator: "\n").map(String.init)
        
        var newWindows: [String: TmuxWindow] = [:]
        for line in lines {
            if let window = TmuxWindow.parse(line, sessionId: sessionId) {
                newWindows[window.id] = window
            }
        }
        
        // Merge with existing windows (preserve pane info)
        for (id, window) in newWindows {
            if var existing = windows[id] {
                existing.name = window.name
                existing.index = window.index
                existing.layout = window.layout
                existing.flags = window.flags
                windows[id] = existing
            } else {
                windows[id] = window
            }
        }
        
        logger.info("Updated windows: \(windows.count) windows")
    }
    
    /// Handle list-panes response
    func handlePanesResponse(_ content: String, windowId: String) {
        let lines = content.split(separator: "\n").map(String.init)
        
        for line in lines {
            if let pane = TmuxPane.parse(line, windowId: windowId) {
                panes[pane.id] = pane
                
                // Update window's pane list
                if var window = windows[windowId] {
                    if !window.paneIds.contains(pane.id) {
                        window.paneIds.append(pane.id)
                    }
                    if pane.isActive {
                        window.activePaneId = pane.id
                    }
                    windows[windowId] = window
                }
            }
        }
        
        logger.info("Updated panes for window \(windowId): \(panes.count) total panes")
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
