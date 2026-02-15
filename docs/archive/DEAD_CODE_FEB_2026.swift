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

/// Convert character to control sequence (Ctrl+A = 0x01, etc.)
/// REASON: Never called anywhere. Ghostty handles Ctrl modifier internally.
private func applyControlToCharacter(_ scalar: UnicodeScalar) -> [UInt8] {
    let value = scalar.value
    
    // Ctrl+A through Ctrl+Z -> 0x01-0x1A
    if value >= 0x61 && value <= 0x7A {  // a-z
        return [UInt8(value - 0x60)]
    }
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
