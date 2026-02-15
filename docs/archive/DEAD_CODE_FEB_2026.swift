// DEAD_CODE_FEB_2026.swift
// Archived dead code removed during Feb 2026 codebase audit
// These methods/properties/types were confirmed unused via codebase-wide grep

// ============================================================================
// FROM: Ghostty.swift (SurfaceView)
// ============================================================================

// MARK: - Byte sending helpers (superseded by Ghostty key API)

/// Send raw bytes directly to SSH (bypasses terminal emulator)
/// REASON: Never called anywhere. Ghostty key API (ghostty_surface_key) handles all input.
private func sendBytes(_ bytes: [UInt8]) {
    guard !bytes.isEmpty else { return }
    let data = Data(bytes)
    onWrite?(data)
    }
}

// MARK: - Session 30 — Phase B H10 Dead Code Audit (Feb 15, 2026)
// ================================================================

// --- From NIOSSHConnection.swift (lines 411-439) ---
// Never called. The connect flow goes straight from bootstrap.connect()
// to openShellChannel(). This method creates a test channel to verify auth
// works, then closes it — an unnecessary extra round-trip.

//    /// Open an SSH shell channel with PTY
//    /// Verify that SSH authentication completed successfully by creating a test channel
//    /// This is necessary because bootstrap.connect() returns before auth finishes.
//    private func verifyAuthentication(on channel: Channel) async throws {
//        logger.info("🔐 Verifying SSH authentication...")
//        
//        let sshHandler = try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
//        
//        // Attempt to create a session channel - this will fail if auth isn't complete
//        let channelPromise = channel.eventLoop.makePromise(of: Channel.self)
//        
//        sshHandler.createChannel(channelPromise) { childChannel, channelType in
//            guard channelType == .session else {
//                return childChannel.eventLoop.makeFailedFuture(
//                    NIOSSHError.channelError("Unexpected channel type during auth verification")
//                )
//            }
//            // No handlers needed - we're just verifying auth works
//            return childChannel.eventLoop.makeSucceededVoidFuture()
//        }
//        
//        // Wait for channel creation - this blocks until auth completes
//        let testChannel = try await channelPromise.futureResult.get()
//        
//        // Close the test channel immediately - we only needed it to verify auth
//        try await testChannel.close().get()
//        
//        logger.info("🔐 SSH authentication verified successfully")
//    }

// --- From TmuxSessionManager.swift (lines 1119-1123) ---
// Never referenced. Also depends on windowIds which is initialized to []
// and never populated.

//    /// Get windows for current session
//    var currentSessionWindows: [TmuxWindow] {
//        guard let session = currentSession else { return [] }
//        return session.windowIds.compactMap { windows[$0] }
//    }

    if value >= 0x41 && value <= 0x5A {  // A-Z
        return [UInt8(value - 0x40)]
    }
    
    // Special control characters
    switch scalar {
    case "[":  return [0x1B]  // ESC
    case "\\":  return [0x1C]  // FS
    case "]":  return [0x1D]  // GS
    case "^":  return [0x1E]  // RS
    case "_":  return [0x1F]  // US
    case "@":  return [0x00]  // NUL
    case " ":  return [0x00]  // Ctrl+Space = NUL
    default:   return []
    }
}

// MARK: - Duplicate/unused text input method

/// Send text input to the terminal (user typing -> SSH)
/// REASON: Identical to sendText(). sendText() is the one used externally.
func sendInput(_ text: String) {
    guard let surface = surface else { return }
    
    let len = text.utf8CString.count
    guard len > 0 else { return }
    
    text.withCString { ptr in
        ghostty_surface_text(surface, ptr, UInt(len - 1))
    }
}

/// Send a key event to the terminal using the new Input types
/// REASON: Zero external callers. sendVirtualKey() is used instead.
func sendKeyEvent(_ event: Input.KeyEvent) {
    guard let surface = surface else { return }
    
    event.withCValue { cEvent in
        _ = ghostty_surface_key(surface, cEvent)
    }
}

// MARK: - Invalid search binding actions (real search uses performSyncSearch via Combine)

/// Start a search with a query (parameterized)
/// REASON: "search:\(query)" is not a valid Ghostty binding action. Never called.
func startSearch(_ query: String = "") {
    guard let surface = surface else { return }
    let action = query.isEmpty ? "start_search" : "search:\(query)"
    ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
}

/// Update the search query
/// REASON: "search:\(query)" is not a valid Ghostty binding action.
/// Real search driven by searchState.$needle -> performSyncSearch() -> ghostty_surface_search_start()
func updateSearch(_ query: String) {
    guard let surface = surface else { return }
    let action = "search:\(query)"
    ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
}

/// End the current search
/// REASON: Zero callers. Search ends via searchState = nil didSet -> ghostty_surface_search_end()
func endSearch() {
    guard let surface = surface else { return }
    let action = "end_search"
    ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
}

// MARK: - Unused accessibility method

/// Update accessibility value with current terminal state
/// REASON: Defined but never invoked from anywhere.
func updateAccessibilityValue() {
    var value = ""
    if let currentPwd = pwd {
        value += "Current directory: \(currentPwd). "
    }
    if !title.isEmpty && title != "Terminal" {
        value += "Title: \(title). "
    }
    if let scrollState = scrollbar, scrollState.total > scrollState.len {
        let scrollPercent = Int(Double(scrollState.offset) / Double(scrollState.total - scrollState.len) * 100)
        value += "Scrolled \(scrollPercent) percent. "
    }
    accessibilityValue = value.isEmpty ? nil : value
}

// MARK: - Unused ShortcutAction enum cases

// These enum cases were defined but never dispatched by any keyboard shortcut:
//   case newWindow     — iOS doesn't support multiple windows in the traditional sense
//   case closeSurface  — Cmd+W handled by SwiftUI menu, not ShortcutAction
//   case closeTab      — no keybinding maps to this
//   case disconnect    — Cmd+W handled by SwiftUI menu

// ============================================================================
// FROM: SurfaceSearchOverlay.swift
// ============================================================================

// MARK: - Dead search debounce handler (real search uses Combine subscriber)

/// REASON: Called updateSearch() which used an invalid binding action "search:\(query)".
/// Real search driven by searchState.$needle Combine publisher -> performSyncSearch().
// @State private var searchDebounceTimer: Timer?
// .onChange(of: searchState.needle) { ... handleSearchQueryChanged() }

func handleSearchQueryChanged() {
    searchDebounceTimer?.invalidate()
    searchDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in
        // This called surfaceView.updateSearch(searchState.needle)
        // which was a no-op (invalid binding action)
    }
}

// Also removed: unused `import Combine`

// ============================================================================
// FROM: TerminalContainerView.swift
// ============================================================================

// MARK: - Unused @State properties on TerminalContainerView

// @State private var terminalTitle: String = "Terminal"
// REASON: Declared but never read or displayed anywhere.

// @State private var keyboardHeight: CGFloat = 0
// REASON: Declared but never read. Keyboard handling is in RawTerminalUIViewController.

// @State private var hoverUrl: URL? = nil
// @State private var hoverUrlCancellable: AnyCancellable? = nil
// REASON: Declared but never read or set. Vestigial from planned link-preview feature.

// MARK: - PassThroughView (never instantiated)

/// A UIView subclass that passes through touches to views beneath it
/// REASON: Defined but never instantiated anywhere in the codebase.
class PassThroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hitView = super.hitTest(point, with: event)
        // Return nil if the hit view is self, allowing touches to pass through
        return hitView == self ? nil : hitView
    }
}

// MARK: - Unused searchOverlayContainer property

// private var searchOverlayContainer: UIView?
// REASON: Declared with comment "unused now - hosting view is positioned directly." Never read/written.

// MARK: - updateSinglePaneSurface (superseded by transitionToSingleSurfaceMode)

/// REASON: Private method defined but never called. Superseded by transitionToSingleSurfaceMode().
private func updateSinglePaneSurface() {
    guard let tmuxManager = viewModel?.tmuxManager,
          let newPrimarySurface = tmuxManager.primarySurface else {
        logger.warning("🔄 No primary surface available for single-pane update")
        return
    }
    if surfaceView === newPrimarySurface {
        logger.debug("🔄 Already showing correct primary surface")
        return
    }
    logger.info("🔄 Updating single-pane surface (old != new primary)")
    if let oldSurface = surfaceView { oldSurface.removeFromSuperview() }
    newPrimarySurface.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(newPrimarySurface)
    surfaceTopConstraint = newPrimarySurface.topAnchor.constraint(equalTo: view.topAnchor)
    surfaceBottomConstraint = newPrimarySurface.bottomAnchor.constraint(equalTo: view.bottomAnchor)
    NSLayoutConstraint.activate([
        surfaceTopConstraint!, surfaceBottomConstraint!,
        newPrimarySurface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        newPrimarySurface.trailingAnchor.constraint(equalTo: view.trailingAnchor)
    ])
    self.surfaceView = newPrimarySurface
    viewModel?.surfaceView = newPrimarySurface
    view.layoutIfNeeded()
    newPrimarySurface.sizeDidChange(newPrimarySurface.frame.size)
    newPrimarySurface.isHidden = false
    newPrimarySurface.focusDidChange(true)
    _ = newPrimarySurface.becomeFirstResponder()
    logger.info("🔄 ✅ Updated single-pane surface (frame=\(newPrimarySurface.frame))")
}

// MARK: - connectionDuration / formattedDuration (published but no subscriber)

// @Published var connectionDuration: TimeInterval = 0
// private var connectionStartTime: Date?
// private var durationTimer: Timer?
// var formattedDuration: String { ... }
// func startDurationTimer() { ... }
// func stopDurationTimer() { ... }
// REASON: Timer infrastructure is running but connectionDuration and formattedDuration are
// never read by any UI code. Published but no view subscribes to them.
// Also removed: call sites in connect() and useExistingSession(), stopDurationTimer() in disconnect()

func startDurationTimer() {
    connectionStartTime = Date()
    connectionDuration = 0
    durationTimer?.invalidate()
    durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
        Task { @MainActor in
            guard let self = self, let startTime = self.connectionStartTime else { return }
            self.connectionDuration = Date().timeIntervalSince(startTime)
        }
    }
}

func stopDurationTimer() {
    durationTimer?.invalidate()
    durationTimer = nil
}

var formattedDuration: String {
    let hours = Int(connectionDuration) / 3600
    let minutes = (Int(connectionDuration) % 3600) / 60
    let seconds = Int(connectionDuration) % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    } else {
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - toggleSecureKeyboardEntry (no-op on iOS)

// private var secureKeyboardEntry = false
// func toggleSecureKeyboardEntry() { secureKeyboardEntry.toggle() }
// NotificationCenter observer for .terminalToggleSecureKeyboard
// Button("Toggle Secure Keyboard Entry") in GeisttyApp.swift menu
// static let terminalToggleSecureKeyboard notification name
// REASON: Toggles a boolean that is never consumed. Comment says "kept for UI parity but has no effect."
// Also removed: the property, notification observer, menu item, and notification name.

private func toggleSecureKeyboardEntry() {
    secureKeyboardEntry.toggle()
    // Note: On iOS, keyboard input is already sandboxed per-app.
    // There's no system API equivalent to macOS "Secure Keyboard Entry".
    // This toggle is kept for UI parity but has no effect.
}

// MARK: - disconnect() on TerminalContainerView (never called)

// private func disconnect() { viewModel.disconnect() }
// REASON: Defined but never called. Back-button flow uses handleBackButton() notification instead.

// ============================================================================
// FROM: SSHSession.swift
// ============================================================================

// MARK: - Dead stripMPIntPadding instance method

/// REASON: Private instance method never called. A local function with the same logic
/// (stripMpintPadding, line ~584) is defined inside parseOpenSSHPrivateKey and used instead.
private func stripMPIntPadding(_ data: Data) -> Data {
    guard let first = data.first, first == 0x00 else { return data }
    return data.dropFirst()
}

// MARK: - Unused connect methods

/// REASON: connect(host:...:password:) is NOT dead — called from TerminalViewModel.connect().
/// connect(profile:credential:) is the primary path but the simpler overload is also used.
/// CORRECTION: Only connectWithKey was confirmed dead.

/// REASON: Never called anywhere. Profile/credential API or direct password connect used instead.
func connectWithKey(host: String, port: Int, username: String, privateKeyPath: String,
                    passphrase: String? = nil, useTmux: Bool = false,
                    tmuxSessionName: String? = nil) async throws {
    let conn = prepareConnection(
        host: host, port: port, username: username,
        useTmux: useTmux, tmuxSessionName: tmuxSessionName
    )
    let keyData = try Data(contentsOf: URL(fileURLWithPath: privateKeyPath))
    let privateKey = try parsePrivateKey(keyData, passphrase: passphrase)
    self.storedAuthMethod = .publicKey(privateKey: privateKey)
    self.storedProfile = nil
    self.storedCredential = nil
    try await conn.connect(authMethod: .publicKey(privateKey: privateKey))
    finalizeConnection()
}

// MARK: - Dead performWrite(String) overload

/// REASON: write(_ string: String) is NOT dead — called internally at line 866.
/// CORRECTION: Only the String overload of performWrite was confirmed dead.

/// REASON: String convenience overload of performWrite, never called.
/// All call sites pass Data, hitting the Data overload at line 1004.
private func performWrite(_ command: String, originalData: Data) {
    guard let data = command.data(using: .utf8) else {
        pendingInputQueue.append(originalData)
        updatePendingInputDisplay()
        return
    }
    performWrite(data, originalData: originalData)
}

// MARK: - Unused error cases

// SSHSessionError.notInTmux — never thrown or matched
// SSHSessionError.tmuxExited(reason:) — never thrown or matched

// ============================================================================
// FROM: TmuxSessionManager.swift
// ============================================================================

// MARK: - Dead reassignPrimarySurface() no-arg overload

/// REASON: Private method never called. Codebase uses reassignPrimarySurface(excludingPaneId:fromPaneIds:).
private func reassignPrimarySurface() {
    if let (paneId, surface) = paneSurfaces.first {
        logger.info("🔄 Reassigning primarySurface to \(paneId)")
        primarySurface = surface
        surface.onCellSizeChanged = { [weak self] cellSize in
            self?.primaryCellSize = cellSize
            logger.info("📐 Primary cell size updated: \(Int(cellSize.width))x\(Int(cellSize.height))")
        }
        if surface.cellSize.width > 0 && surface.cellSize.height > 0 {
            primaryCellSize = surface.cellSize
        }
    } else {
        logger.warning("🔄 No surfaces available to reassign as primary")
        primarySurface = nil
        primaryCellSize = .zero
    }
}

// MARK: - Query stubs (legacy from TmuxGateway architecture)

/// REASON: Stub that only logs. Called from handleSessionChanged but was a no-op.
func queryWindows(for sessionId: String) {
    logger.debug("queryWindows called for \(sessionId) - relying on Ghostty state tracking")
}

/// REASON: Stub that only logs. Never called externally.
func queryPanes(for windowId: String) {
    logger.debug("queryPanes called for \(windowId) - relying on Ghostty state tracking")
}

/// REASON: Near-stub, never called externally. Sends refresh-client but Ghostty handles state.
func refreshState() {
    guard writeToSSH != nil else {
        logger.warning("Cannot refresh state: no write callback available")
        return
    }
    logger.info("Refreshing tmux state (native Ghostty mode)")
    sendCommandFireAndForget("refresh-client")
}

// MARK: - Dead parse/handle methods

/// REASON: Private, called only from handleSessionsResponse (also dead).
private func parseSessionsResponse(_ response: String) {
    let lines = response.split(separator: "\n", omittingEmptySubsequences: true)
    logger.info("Parsing \(lines.count) sessions")
    for line in lines {
        if let session = TmuxSession.parse(String(line)) {
            sessions[session.id] = session
        }
    }
}

private func parseWindowsResponse(_ response: String) {
    let lines = response.split(separator: "\n", omittingEmptySubsequences: true)
    for line in lines {
        if let window = TmuxWindow.parse(String(line)) {
            windows[window.id] = window
            if let layout = window.layout,
               let parsedLayout = try? TmuxLayout.parseWithChecksum(layout) {
                updateSplitTree(from: parsedLayout, for: window.id)
            }
        }
    }
}

private func parsePanesResponse(_ response: String) {
    let lines = response.split(separator: "\n", omittingEmptySubsequences: true)
    for line in lines {
        if let pane = TmuxPane.parse(String(line)) {
            panes[pane.id] = pane
        }
    }
}

/// REASON: Public wrappers never called externally. Legacy from TmuxGateway.
func handleSessionsResponse(_ content: String) {
    let lines = content.split(separator: "\n").map(String.init)
    var newSessions: [String: TmuxSession] = [:]
    for line in lines {
        if let session = TmuxSession.parse(line) { newSessions[session.id] = session }
    }
    sessions = newSessions
}

func handleWindowsResponse(_ content: String, sessionId: String) {
    parseWindowsResponse(content)
}

func handlePanesResponse(_ content: String, windowId: String) {
    parsePanesResponse(content)
}

// MARK: - Unreachable UI methods

/// REASON: Not called from any UI. No session creation UI exists.
func newSession(name: String) {
    sendCommandFireAndForget("new-session -d -s '\(name)'")
}

/// REASON: Not called from any UI. No session switching UI exists.
func switchSession(_ sessionId: String) {
    sendCommandFireAndForget("switch-client -t '\(sessionId)'")
}

// MARK: - Stub notification handler

/// REASON: Only logs. No callers.
func handlePaneModeChanged(paneId: String) {
    logger.debug("Pane mode changed: \(paneId)")
    // In native Ghostty mode, we can't query pane mode via command/response.
    // Ghostty's viewer handles mode changes internally.
}

// ============================================================================
// BATCH 2: Dead TmuxGateway Legacy Code (~500 lines)
// Removed: Feb 2026
// These are remnants from old architecture where Swift parsed tmux control mode
// protocol. Now Ghostty's viewer.zig handles all of this.
// ============================================================================

// ============================================================================
// FROM: TmuxSessionManager.swift — 8 dead handler methods (B1)
// REASON: Zero callers anywhere. These were called by the old TmuxGateway
// which routed %session-changed, %window-add, etc. to these handlers.
// Ghostty's viewer.zig now handles all protocol parsing internally.
// ============================================================================

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

// ============================================================================
// FROM: TmuxSessionManager.swift — SessionResumeStatus + sawSessionsChanged (B6)
// REASON: handleSessionChanged (the only setter) is dead. The toast in
// TerminalContainerView observes sessionResumeStatus but it never fires.
// The entire chain is broken: enum -> property -> observer -> toast view.
// ============================================================================

/// Whether a tmux session was newly created or resumed from an existing one
enum SessionResumeStatus: Equatable {
    /// A new session was created on the server
    case created(name: String)
    
    /// An existing session was resumed (attached to)
    case resumed(name: String)
}

// @Published private(set) var sessionResumeStatus: SessionResumeStatus?
// private var sawSessionsChanged: Bool = false
// (Set in handleSessionChanged, handleSessionsChanged — both dead)
// (Read by TerminalContainerView.setupSessionResumeObserver — never triggers)

// ============================================================================
// FROM: TerminalContainerView.swift — Session resume toast infrastructure (B6)
// REASON: Observer subscribes to sessionResumeStatus which is never set
// (setter is in dead handleSessionChanged). Toast never appears.
// ============================================================================

// private var sessionResumeToastHostingController: UIHostingController<SessionResumeToastView>?
// private var sessionResumeObserver: AnyCancellable?
// private var sessionResumeToastDismissTask: Task<Void, Never>?

private func setupSessionResumeObserver() {
    guard let manager = viewModel?.tmuxManager else { return }
    
    sessionResumeObserver = manager.$sessionResumeStatus
        .receive(on: DispatchQueue.main)
        .sink { [weak self] status in
            guard let status = status else { return }
            self?.showSessionResumeToast(status: status)
    }
}

// ============================================================================
// FROM: SSHKeyManager.swift — Session 27 Phase A (C3)
// ============================================================================

// MARK: - getPrivateKeyPath (dead code — no callers, temp file leak)

/// Get a temporary file path containing the private key (for libssh2)
/// REASON: No callers found. Was intended for libssh2 path-based API, but we
/// use in-memory Data via getPrivateKey() instead. Also leaked temp files —
/// no cleanup after use.
func getPrivateKeyPath(name: String) throws -> String {
    let keyData = try getPrivateKey(name: name)
    
    // Write to temporary file
    let tempDir = FileManager.default.temporaryDirectory
    let keyFile = tempDir.appendingPathComponent("ghostty_key_\(name)")
    
    try keyData.write(to: keyFile)
    
    // Set restrictive permissions
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: keyFile.path
    )
    
    return keyFile.path
}

private func showSessionResumeToast(status: SessionResumeStatus) {
    // Remove any existing toast
    removeSessionResumeToast()
    sessionResumeToastDismissTask?.cancel()
    
    let toast = SessionResumeToastView(status: status)
    let hostingController = UIHostingController(rootView: toast)
    hostingController.view.backgroundColor = .clear
    hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    hostingController.view.alpha = 0
    
    addChild(hostingController)
    view.addSubview(hostingController.view)
    
    // Position at top-center
    NSLayoutConstraint.activate([
        hostingController.view.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
        hostingController.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12)
    ])
    
    hostingController.didMove(toParent: self)
    sessionResumeToastHostingController = hostingController
    
    // Fade in
    UIView.animate(withDuration: 0.3) {
        hostingController.view.alpha = 1
    }
    
    // Auto-dismiss after 3 seconds
    sessionResumeToastDismissTask = Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        guard !Task.isCancelled else { return }
        self?.dismissSessionResumeToast()
    }
}

private func dismissSessionResumeToast() {
    guard let hostingController = sessionResumeToastHostingController else { return }
    UIView.animate(withDuration: 0.3, animations: {
        hostingController.view.alpha = 0
    }) { [weak self] _ in
        self?.removeSessionResumeToast()
    }
}

private func removeSessionResumeToast() {
    if let hostingController = sessionResumeToastHostingController {
        hostingController.willMove(toParent: nil)
        hostingController.view.removeFromSuperview()
        hostingController.removeFromParent()
        sessionResumeToastHostingController = nil
    }
}

// ============================================================================
// FROM: SessionResumeToastView.swift (entire file archived, then deleted)
// REASON: Only consumer of SessionResumeStatus enum. Dead chain.
// ============================================================================

// struct SessionResumeToastView: View {
//     let status: SessionResumeStatus
//     ... (see full file in git history at commit before this removal)
// }

// ============================================================================
// FROM: TmuxModels.swift — Dead model parsing (B2)
// REASON: Zero callers in production code. Only called from tests that
// were also removed. Legacy from TmuxGateway command/response parsing.
// ============================================================================

/// Format strings for tmux queries
enum TmuxQueryFormat {
    /// list-sessions format
    static let sessions = "#{session_id} #{q:session_name} #{session_windows} #{session_attached}"
    
    /// list-windows format (includes session_id for self-contained parsing)
    static let windows = "#{session_id} #{window_id} #{window_index} #{q:window_name} #{window_active} #{window_flags} #{window_layout}"
    
    /// list-panes format (includes window_id for self-contained parsing)
    static let panes = "#{window_id} #{pane_id} #{pane_width} #{pane_height} #{pane_active} #{cursor_x} #{cursor_y} #{pane_in_mode} #{alternate_on}"
}

extension TmuxSession {
    /// Parse from list-sessions -F response line
    /// Format: "$0 session_name 3 1"
    static func parse(_ line: String) -> TmuxSession? {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 4 else { return nil }
        
        let id = String(parts[0])
        let name = String(parts[1]).replacingOccurrences(of: "\"", with: "")
        let attached = parts[3] == "1"
        
        var session = TmuxSession(id: id, name: name)
        session.isAttached = attached
        return session
    }
}

extension TmuxWindow {
    /// Parse from list-windows -F response line
    /// Format: "$session_id @window_id index window_name active flags layout"
    static func parse(_ line: String) -> TmuxWindow? {
        // Use regex-like parsing for quoted names
        let parts = line.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: false)
        guard parts.count >= 7 else { return nil }
        
        let sessionId = String(parts[0])
        let id = String(parts[1])
        guard let index = Int(parts[2]) else { return nil }
        let name = String(parts[3]).replacingOccurrences(of: "\"", with: "")
        let isActive = parts[4] == "1"
        let flags = String(parts[5])
        let layout = String(parts[6])
        
        var window = TmuxWindow(id: id, index: index, name: name, sessionId: sessionId)
        window.flags = flags
        window.layout = layout
        if isActive {
            // Mark in parent session
        }
        return window
    }
}

extension TmuxPane {
    /// Parse from list-panes -F response line  
    /// Format: "@window_id %pane_id width height active cursor_x cursor_y in_mode alternate_on"
    static func parse(_ line: String) -> TmuxPane? {
        let parts = line.split(separator: " ")
        guard parts.count >= 9 else { return nil }
        
        let windowId = String(parts[0])
        let id = String(parts[1])
        guard let width = Int(parts[2]),
              let height = Int(parts[3]) else { return nil }
        
        let isActive = parts[4] == "1"
        let cursorX = Int(parts[5]) ?? 0
        let cursorY = Int(parts[6]) ?? 0
        let inMode = parts[7] != "0"
        let alternateOn = parts[8] == "1"
        
        var pane = TmuxPane(id: id, windowId: windowId, width: width, height: height)
        pane.isActive = isActive
        pane.cursorX = cursorX
        pane.cursorY = cursorY
        pane.isAlternateScreen = alternateOn
        if inMode {
            pane.mode = .copy // Simplified - could be other modes
        }
        return pane
    }
}

// ============================================================================
// FROM: TmuxModels.swift — Dead TmuxPane properties (B3)
// REASON: Only set in TmuxPane.parse() (dead) and tested in dead tests.
// Never read by any live production code.
// ============================================================================

// On TmuxPane struct:
//     var cursorX: Int = 0
//     var cursorY: Int = 0
//     var title: String = ""
//     var currentCommand: String?
//     var isAlternateScreen: Bool = false
//     var mode: PaneMode = .normal
//     enum PaneMode: Equatable {
//         case normal
//         case copy
//         case choose
//         case view
//     }

// ============================================================================
// BATCH 1 (Session 10) — Redundancy removals: Swift duplicating Ghostty
// Archived: Feb 14, 2026
// ============================================================================

// --- A1: TerminalViewModel.paste() — bypassed bracketed paste mode ---
// File: Sources/Terminal/TerminalContainerView.swift
// Replaced with: surfaceView?.paste(nil) delegation to Ghostty SurfaceView
//
//     func paste() {
//         if let text = UIPasteboard.general.string {
//             send(text: text)
//         }
//     }

// --- A2: TerminalViewModel.copy() — duplicated SurfaceView.copy ---
// File: Sources/Terminal/TerminalContainerView.swift
// Replaced with: surfaceView?.copy(nil) delegation to Ghostty SurfaceView
//
//     func copy() {
//         guard let surface = surfaceView?.surface else {
//             logger.warning("📋 Copy: no surface available")
//             return
//         }
//
//         // Check if there's a selection
//         guard ghostty_surface_has_selection(surface) else {
//             logger.info("📋 Copy: no selection")
//             return
//         }
//
//         // Read the selection
//         var textStruct = ghostty_text_s()
//         if ghostty_surface_read_selection(surface, &textStruct) {
//             if let textPtr = textStruct.text, textStruct.text_len > 0 {
//                 let selectedText = String(cString: textPtr)
//                 UIPasteboard.general.string = selectedText
//                 logger.info("📋 Copied \(textStruct.text_len) characters to clipboard")
//             }
//             // Free the text
//             ghostty_surface_free_text(surface, &textStruct)
//         }
//
//         // Clear selection state after copying
//         isSelectingText = false
//     }

// --- A8: isSelectingText property and selectionDidChange() — dead, zero readers ---
// File: Sources/Terminal/TerminalContainerView.swift
//
//     @Published var isSelectingText: Bool = false
//
//     /// Called when selection state changes (from SurfaceView)
//     func selectionDidChange(_ hasSelection: Bool) {
//         isSelectingText = hasSelection
//     }

// --- A3: clearScreen() — sent raw Ctrl+L, missing Ghostty's scrollback clear ---
// File: Sources/Terminal/TerminalContainerView.swift
// Replaced with: ghostty_surface_binding_action("clear_screen")
//
//     /// Clear the terminal screen (Ctrl+L)
//     func clearScreen() {
//         // Send Ctrl+L (form feed / clear screen)
//         send(text: "\u{0c}")
//     }
//
// Also: handleClearScreen() duplicated logic instead of calling clearScreen()
//     private func handleClearScreen() {
//         // Send clear screen escape sequence (Ctrl+L equivalent)
//         viewModel?.send(text: "\u{0C}")  // Form feed / Ctrl+L
//     }

// --- A4: handleResetTerminal() — duplicated resetTerminal() logic ---
// File: Sources/Terminal/TerminalContainerView.swift
// Fixed to call viewModel?.resetTerminal() instead of duplicating
//
//     private func handleResetTerminal() {
//         // Send reset terminal escape sequence
//         viewModel?.send(text: "\u{1B}c")  // ESC c - Full reset
//     }

// --- A5: Redundant config parser cases (overwrite API results) ---
// File: Sources/Ghostty/ConfigSyncManager.swift, parseConfigFileForGUI()
// These 3 cases were redundant with syncFromConfig() API path:
//
//             case "cursor-style":
//                 if ["block", "bar", "underline"].contains(value) {
//                     defaults.set(value, forKey: "terminal.cursorStyle")
//                     logger.debug("File parser: cursor-style = \(value)")
//                 }
//
//             case "font-thicken":
//                 defaults.set(value == "true", forKey: "terminal.fontThicken")
//                 logger.debug("File parser: font-thicken = \(value)")
//
//             case "background-opacity":
//                 if let opacity = Double(value) {
//                     defaults.set(opacity, forKey: "terminal.backgroundOpacity")
//                     logger.debug("File parser: background-opacity = \(opacity)")
//                 }

// --- A7: SET_TITLE action handler was a no-op ---
// File: Sources/Ghostty/Ghostty.swift
// Was: returned true but discarded the title
// Fixed to: extract title and set surfaceView.title (following macOS pattern)
//
//             case GHOSTTY_ACTION_SET_TITLE:
//                 // Handle title change
//                 return true

// --- A9: fontThickenStrength — dead @AppStorage, zero readers ---
// File: Sources/UI/SettingsView.swift
//
//     @AppStorage("terminal.fontThickenStrength") var fontThickenStrength: Int = 255

// --- A10: colorTheme — dead @AppStorage on AppSettings, accessed via UserDefaults.standard elsewhere ---
// File: Sources/UI/SettingsView.swift
//
//     @AppStorage("terminal.colorTheme") var colorTheme: String = "Default"

// --- Final sweep: SSHSession.write(_ string: String) — dead String overload, zero callers ---
// File: Sources/SSH/SSHSession.swift
//
//     /// Write string to the SSH channel.
//     /// Delegates to `write(_ data: Data)` for consistent send-keys wrapping in
//     /// tmux control mode.
//     func write(_ string: String) {
//         logger.debug("SSHSession.write(string): \(string.prefix(20))")
//         guard let data = string.data(using: .utf8) else { return }
//         write(data)
//     }
import Foundation

// MARK: - TmuxSendKeys

/// Pure-function utility for wrapping raw terminal input bytes in tmux `send-keys`
/// commands suitable for control mode.
///
/// Uses iTerm2's proven approach:
/// - Safe chars (alphanumeric + `+/):,_.`): `send -lt %<id> '<chars>'`
/// - Everything else (control chars, escape seqs, space, special): `send -t %<id> 0x<hex>`
///
/// Batches consecutive same-type bytes. Commands are joined with ` ; ` separators
/// (tmux command separator) to reduce the number of SSH writes.
enum TmuxSendKeys {

    /// Characters that can be sent via `send -lt` (literal mode) without escaping.
    /// This matches iTerm2's safe character set for tmux send-keys.
    static let literalSafe: Set<UInt8> = {
        var safe = Set<UInt8>()
        // a-z
        for c in UInt8(ascii: "a")...UInt8(ascii: "z") { safe.insert(c) }
        // A-Z
        for c in UInt8(ascii: "A")...UInt8(ascii: "Z") { safe.insert(c) }
        // 0-9
        for c in UInt8(ascii: "0")...UInt8(ascii: "9") { safe.insert(c) }
        // iTerm2's additional safe chars: + / ) : , _ .
        for c: UInt8 in [
            UInt8(ascii: "+"), UInt8(ascii: "/"), UInt8(ascii: ")"),
            UInt8(ascii: ":"), UInt8(ascii: ","), UInt8(ascii: "_"),
            UInt8(ascii: ".")
        ] {
            safe.insert(c)
        }
        return safe
    }()

    /// Wrap raw user input bytes in tmux `send-keys` commands for a given pane.
    ///
    /// - Parameters:
    ///   - data: Raw bytes from Ghostty's key encoder
    ///   - paneId: The tmux pane ID (e.g. `2` for `%2`)
    /// - Returns: The wrapped command(s) as UTF-8 Data terminated by `\n`, or `nil` if
    ///   `data` is empty.
    static func wrap(_ data: Data, paneId: Int) -> Data? {
        guard !data.isEmpty else { return nil }

        let target = "%\(paneId)"
        var commands: [String] = []
        var literalBuffer = ""

        /// Flush accumulated literal chars into a send-keys command
        func flushLiteral() {
            guard !literalBuffer.isEmpty else { return }
            // Single-quote the literal string to prevent tmux from interpreting
            // special characters. Escape embedded single quotes with '\'' .
            let escaped = literalBuffer.replacingOccurrences(of: "'", with: "'\\''")
            commands.append("send -lt \(target) '\(escaped)'")
            literalBuffer = ""
        }

        for byte in data {
            if literalSafe.contains(byte) {
                literalBuffer.append(Character(UnicodeScalar(byte)))
            } else {
                // Non-literal byte — flush any accumulated literals first
                flushLiteral()
                // Send as hex
                commands.append("send -t \(target) 0x\(String(format: "%02x", byte))")
            }
        }

        // Flush any remaining literals
        flushLiteral()

        guard !commands.isEmpty else { return nil }

        // Join with tmux command separator and terminate with newline.
        // tmux reads one command per line in control mode, but ` ; ` allows
        // multiple commands on a single line.
        let line = commands.joined(separator: " ; ") + "\n"

        return line.data(using: .utf8)
    }
}
import XCTest
@testable import Geistty

// MARK: - TmuxSendKeys Tests

final class TmuxSendKeysTests: XCTestCase {

    // MARK: - Helpers

    /// Convert wrap() output to a String for easier assertion.
    private func wrapped(_ bytes: [UInt8], paneId: Int = 2) -> String? {
        guard let data = TmuxSendKeys.wrap(Data(bytes), paneId: paneId) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Convenience: wrap a UTF-8 string.
    private func wrapped(_ string: String, paneId: Int = 2) -> String? {
        guard let data = TmuxSendKeys.wrap(Data(string.utf8), paneId: paneId) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Empty Input

    func testEmptyDataReturnsNil() {
        XCTAssertNil(TmuxSendKeys.wrap(Data(), paneId: 2))
    }

    // MARK: - Literal-Safe Characters

    func testAlphanumericLiteral() {
        let result = wrapped("ls")
        XCTAssertEqual(result, "send -lt %2 'ls'\n")
    }

    func testUppercaseLiteral() {
        let result = wrapped("ABC")
        XCTAssertEqual(result, "send -lt %2 'ABC'\n")
    }

    func testDigitsLiteral() {
        let result = wrapped("123")
        XCTAssertEqual(result, "send -lt %2 '123'\n")
    }

    func testSafeSpecialCharsLiteral() {
        // iTerm2's safe set: + / ) : , _ .
        let result = wrapped("+/):,_.")
        XCTAssertEqual(result, "send -lt %2 '+/):,_.'\n")
    }

    func testMixedAlphanumericAndSafeSpecial() {
        let result = wrapped("file_name.txt")
        XCTAssertEqual(result, "send -lt %2 'file_name.txt'\n")
    }

    // MARK: - Hex-Encoded Characters

    func testCarriageReturnHex() {
        // \r = 0x0d
        let result = wrapped([0x0D])
        XCTAssertEqual(result, "send -t %2 0x0d\n")
    }

    func testEscapeHex() {
        // ESC = 0x1b
        let result = wrapped([0x1B])
        XCTAssertEqual(result, "send -t %2 0x1b\n")
    }

    func testBackspaceHex() {
        // BS = 0x08
        let result = wrapped([0x08])
        XCTAssertEqual(result, "send -t %2 0x08\n")
    }

    func testTabHex() {
        // TAB = 0x09
        let result = wrapped([0x09])
        XCTAssertEqual(result, "send -t %2 0x09\n")
    }

    func testSpaceIsHex() {
        // Space = 0x20 — NOT in the literal-safe set
        let result = wrapped(" ")
        XCTAssertEqual(result, "send -t %2 0x20\n")
    }

    func testNullByteHex() {
        let result = wrapped([0x00])
        XCTAssertEqual(result, "send -t %2 0x00\n")
    }

    // MARK: - Mixed Input (Literal + Hex)

    func testCommandWithCR() {
        // "ls\r" — "ls" is literal, \r is hex
        let result = wrapped([0x6C, 0x73, 0x0D]) // l, s, CR
        XCTAssertEqual(result, "send -lt %2 'ls' ; send -t %2 0x0d\n")
    }

    func testCommandWithSpaces() {
        // "ls -alf" — "ls" literal, space hex, "-alf" has '-' as hex then "alf" literal
        // '-' = 0x2D, not in safe set
        let result = wrapped("ls -alf")
        XCTAssertEqual(result, "send -lt %2 'ls' ; send -t %2 0x20 ; send -t %2 0x2d ; send -lt %2 'alf'\n")
    }

    func testCommandWithSpaceAndCR() {
        // "ls\r" with a space: "ls -l\r"
        let bytes: [UInt8] = [0x6C, 0x73, 0x20, 0x2D, 0x6C, 0x0D] // l, s, space, -, l, CR
        let result = wrapped(bytes)
        XCTAssertEqual(result, "send -lt %2 'ls' ; send -t %2 0x20 ; send -t %2 0x2d ; send -lt %2 'l' ; send -t %2 0x0d\n")
    }

    // MARK: - Single Quote Escaping

    func testSingleQuoteInLiteralRun() {
        // Input: echo 'hello' — the quotes themselves are not literal-safe (0x27),
        // but let's verify: ' = 0x27, not in safe set → should be hex
        let result = wrapped([0x27]) // single quote
        XCTAssertEqual(result, "send -t %2 0x27\n")
    }

    func testDoubleQuoteIsHex() {
        // " = 0x22, not in safe set
        let result = wrapped([0x22])
        XCTAssertEqual(result, "send -t %2 0x22\n")
    }

    // MARK: - Pane ID Variations

    func testPaneIdZero() {
        let data = Data("ls".utf8)
        let result = TmuxSendKeys.wrap(data, paneId: 0)
        let str = result.flatMap { String(data: $0, encoding: .utf8) }
        XCTAssertEqual(str, "send -lt %0 'ls'\n")
    }

    func testPaneIdLargeNumber() {
        let data = Data("x".utf8)
        let result = TmuxSendKeys.wrap(data, paneId: 42)
        let str = result.flatMap { String(data: $0, encoding: .utf8) }
        XCTAssertEqual(str, "send -lt %42 'x'\n")
    }

    // MARK: - All-Hex Input

    func testAllControlChars() {
        // Multiple consecutive control chars: ESC [ A (arrow up escape sequence)
        let bytes: [UInt8] = [0x1B, 0x5B, 0x41] // ESC, [, A
        let result = wrapped(bytes)
        // '[' = 0x5B not in safe set, 'A' IS safe
        XCTAssertEqual(result, "send -t %2 0x1b ; send -t %2 0x5b ; send -lt %2 'A'\n")
    }

    func testOnlyCR() {
        // Just pressing Enter
        let result = wrapped([0x0D])
        XCTAssertEqual(result, "send -t %2 0x0d\n")
    }

    // MARK: - Multi-Byte / UTF-8 Sequences

    func testHighBytesAreHex() {
        // UTF-8 multi-byte: é = 0xC3 0xA9
        let bytes: [UInt8] = [0xC3, 0xA9]
        let result = wrapped(bytes)
        XCTAssertEqual(result, "send -t %2 0xc3 ; send -t %2 0xa9\n")
    }

    func testMixedASCIIAndUTF8() {
        // "café" = 63 61 66 C3 A9
        let bytes: [UInt8] = [0x63, 0x61, 0x66, 0xC3, 0xA9] // c, a, f, é
        let result = wrapped(bytes)
        XCTAssertEqual(result, "send -lt %2 'caf' ; send -t %2 0xc3 ; send -t %2 0xa9\n")
    }

    // MARK: - literalSafe Set Verification

    func testLiteralSafeContainsExpectedChars() {
        let safe = TmuxSendKeys.literalSafe

        // All lowercase letters
        for c in UInt8(ascii: "a")...UInt8(ascii: "z") {
            XCTAssertTrue(safe.contains(c), "Expected '\(Character(UnicodeScalar(c)))' to be literal-safe")
        }

        // All uppercase letters
        for c in UInt8(ascii: "A")...UInt8(ascii: "Z") {
            XCTAssertTrue(safe.contains(c), "Expected '\(Character(UnicodeScalar(c)))' to be literal-safe")
        }

        // All digits
        for c in UInt8(ascii: "0")...UInt8(ascii: "9") {
            XCTAssertTrue(safe.contains(c), "Expected '\(Character(UnicodeScalar(c)))' to be literal-safe")
        }

        // iTerm2 safe specials
        for ch: Character in ["+", "/", ")", ":", ",", "_", "."] {
            let byte = ch.asciiValue!
            XCTAssertTrue(safe.contains(byte), "Expected '\(ch)' to be literal-safe")
        }
    }

    func testLiteralSafeExcludesDangerousChars() {
        let safe = TmuxSendKeys.literalSafe

        // These must NOT be in the safe set
        let dangerous: [UInt8] = [
            0x20,                   // space
            0x0D,                   // CR
            0x0A,                   // LF
            0x1B,                   // ESC
            0x08,                   // BS
            0x09,                   // TAB
            0x00,                   // NULL
            UInt8(ascii: "'"),      // single quote
            UInt8(ascii: "\""),     // double quote
            UInt8(ascii: "\\"),     // backslash
            UInt8(ascii: "-"),      // hyphen (tmux flag prefix)
            UInt8(ascii: ";"),      // semicolon (tmux command separator)
            UInt8(ascii: "#"),      // hash
            UInt8(ascii: "~"),      // tilde
            UInt8(ascii: "`"),      // backtick
            UInt8(ascii: "("),      // open paren (close is safe, open is not)
            UInt8(ascii: "{"),      // open brace
            UInt8(ascii: "}"),      // close brace
            UInt8(ascii: "["),      // open bracket
            UInt8(ascii: "]"),      // close bracket
            UInt8(ascii: "<"),      // less than
            UInt8(ascii: ">"),      // greater than
            UInt8(ascii: "|"),      // pipe
            UInt8(ascii: "&"),      // ampersand
            UInt8(ascii: "*"),      // asterisk
            UInt8(ascii: "?"),      // question mark
            UInt8(ascii: "!"),      // exclamation
            UInt8(ascii: "$"),      // dollar
            UInt8(ascii: "="),      // equals
            UInt8(ascii: "@"),      // at sign
            UInt8(ascii: "^"),      // caret
        ]

        for byte in dangerous {
            XCTAssertFalse(safe.contains(byte), "Expected 0x\(String(format: "%02x", byte)) to NOT be literal-safe")
        }
    }

    func testLiteralSafeCount() {
        // 26 lowercase + 26 uppercase + 10 digits + 7 specials = 69
        XCTAssertEqual(TmuxSendKeys.literalSafe.count, 69)
    }

    // MARK: - Output Format

    func testOutputEndsWithNewline() {
        let data = TmuxSendKeys.wrap(Data("x".utf8), paneId: 1)!
        let str = String(data: data, encoding: .utf8)!
        XCTAssertTrue(str.hasSuffix("\n"), "Output must end with newline")
    }

    func testOutputIsValidUTF8() {
        // Even with high bytes in input, the output is always valid UTF-8
        // because we format as hex strings
        let data = TmuxSendKeys.wrap(Data([0xFF, 0xFE]), paneId: 3)!
        let str = String(data: data, encoding: .utf8)
        XCTAssertNotNil(str, "Output must be valid UTF-8")
    }

    func testSemicolonSeparator() {
        // Two commands should be separated by " ; "
        let result = wrapped([0x61, 0x0D]) // 'a', CR
        XCTAssertTrue(result!.contains(" ; "), "Commands must be separated by ' ; '")
    }
}
