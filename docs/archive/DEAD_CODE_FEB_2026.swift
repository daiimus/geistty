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
