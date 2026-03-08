//
//  TerminalContainerView.swift
//  Geistty
//
//  Terminal container using Ghostty for terminal emulation
//

import SwiftUI
import UIKit
import Combine
import GhosttyKit
import os.log

private let logger = Logger(subsystem: "com.geistty", category: "Terminal")

/// Container view that wraps the Ghostty terminal surface
struct TerminalContainerView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var ghosttyApp: Ghostty.App
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var terminalViewModel = TerminalViewModel()
    
    /// Theme background color to prevent flash
    private var themeBackground: Color {
        Color(ThemeManager.shared.selectedTheme.background)
    }
    
    var body: some View {
        // Pure UIKit UIViewController - NO FLASH!
        // This bypasses SwiftUI's view update mechanism which was causing the gray flash
        RawTerminalViewController(
            ghosttyApp: ghosttyApp,
            viewModel: terminalViewModel,
            onSetup: { setupConnection() }
        )
        .ignoresSafeArea(.all)
        // Handle remote disconnect - navigate back to connection screen
        .onChange(of: terminalViewModel.disconnectedByRemote) { _, disconnected in
            if disconnected {
                logger.info("🔌 Remote disconnect detected, navigating back")
                if let error = terminalViewModel.disconnectError {
                    appState.connectionStatus = .error(error)
                } else {
                    // Clean disconnect - show error with reconnect option
                    appState.connectionStatus = .error("Connection closed by remote host")
                }
            }
        }
    }
    
    // MARK: - Connection
    
    private func setupConnection() {
        logger.info("🔌 TerminalContainerView appeared")
        
        if let existingSession = appState.sshSession {
            logger.info("🔌 Using pre-connected session")
            terminalViewModel.useExistingSession(existingSession)
            appState.connectionStatus = .connected
        } else if let host = appState.currentHost,
           let port = appState.currentPort,
           let username = appState.currentUsername {
            logger.info("🔌 Initiating SSH connection to \(host):\(port) as \(username)")
            terminalViewModel.connect(
                host: host,
                port: port,
                username: username,
                password: appState.currentPassword.flatMap { String(data: $0, encoding: .utf8) },
                onConnected: { [weak appState] in
                    appState?.connectionStatus = .connected
                    // Zero and release password immediately after successful handshake.
                    // It's no longer needed — reconnect uses SSHSession's stored creds. See #28.
                    appState?.zeroAndClearPassword()
                },
                onError: { [weak appState] error in
                    appState?.connectionStatus = .error(error)
                }
            )
        } else {
            logger.warning("🔌 Not connecting - no session or params available")
        }
    }
}

/// ViewModel that bridges Ghostty with SSH connection
@MainActor
class TerminalViewModel: ObservableObject {
    // T2: title and currentFontSize are read imperatively — not @Published
    // to avoid unnecessary objectWillChange churn. isConnected stays @Published
    // because it's consumed via Combine $isConnected sink in +Tmux.swift.
    // disconnectedByRemote and disconnectError drive SwiftUI view updates. See #42.
    var title: String = ""
    @Published var isConnected: Bool = false
    @Published var disconnectedByRemote: Bool = false
    @Published var disconnectError: String? = nil
    var currentFontSize: Float = 14.0
    
    /// Buffer for data received before surface is ready
    private var preSurfaceBuffer: [Data] = []
    
    /// Wire diagnostics for tmux control mode data inspection.
    /// Shadows the raw SSH data path, parsing %output lines and validating
    /// escape sequences without modifying the production data flow.
    let wireDiagnostics = TmuxWireDiagnostics()
    
    /// Reference to the Ghostty surface view
    weak var surfaceView: Ghostty.SurfaceView? {
        didSet {
            // Cancel any existing subscription
            fontSizeCancellable?.cancel()
            fontSizeCancellable = nil
            
            // Wire surface to SSHSession for tmux pane switching
            sshSession?.ghosttySurface = surfaceView
            
            // Sync font size when surfaceView is set and observe changes
            if let surface = surfaceView {
                currentFontSize = surface.currentFontSize
                
                // Flush any buffered data received before surface was ready
                if !preSurfaceBuffer.isEmpty {
                    logger.info("📤 Flushing \(preSurfaceBuffer.count) pre-surface data chunks")
                    for data in preSurfaceBuffer {
                        surface.feedData(data)
                    }
                    preSurfaceBuffer.removeAll()
                }
                
                // Observe font size changes from the surface (e.g., pinch-to-zoom)
                fontSizeCancellable = surface.$currentFontSize
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] newSize in
                        self?.currentFontSize = newSize
                    }
            }
        }
    }
    
    /// Cancellable for font size observation
    private var fontSizeCancellable: AnyCancellable?
    
    /// The SSH session
    private(set) var sshSession: SSHSession?
    
    /// Terminal dimensions
    private var cols: Int = 80
    private var rows: Int = 24
    
    /// Pending resize from layoutSubviews that arrived before sshSession was set.
    /// When onResize fires during the layout pass, sshSession is still nil (it's set
    /// later in useExistingSession). We store the resize here and flush it once the
    /// session is wired up, guaranteeing the SSH PTY gets the real terminal dimensions.
    var pendingResize: (cols: Int, rows: Int)?
    
    /// Observers for app lifecycle events
    private var lifecycleObservers: [NSObjectProtocol] = []
    
    // MARK: - Lifecycle
    
    init() {
        setupLifecycleObservers()
    }
    
    deinit {
        // Remove lifecycle observers
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    /// Set up observers for app lifecycle events
    private func setupLifecycleObservers() {
        // When app goes to background, tmux pause mode handles buffering
        let resignObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // CRITICAL: Must run synchronously — NOT in a Task wrapper.
            // The backgroundState must be set BEFORE any other
            // willResignActive handlers run (e.g., Ghostty.App's focus-false),
            // because those can trigger tmux_exit which checks the flag.
            // A Task wrapper defers to the next run loop iteration, too late.
            self?.sshSession?.appWillResignActive()
        }
        lifecycleObservers.append(resignObserver)
        
        // When app comes back, resume paused panes
        let activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Synchronous for same reason as resign — must run before other
            // didBecomeActive handlers that might inspect connection state.
            self?.sshSession?.appDidBecomeActive()
        }
        lifecycleObservers.append(activeObserver)
    }
    
    func connect(host: String, port: Int, username: String, password: String?,
                 onConnected: @escaping @MainActor () -> Void = {},
                 onError: @escaping @MainActor (String) -> Void = { _ in }) {
        logger.info("TerminalViewModel.connect called - \(host):\(port) user=\(username)")
        Task {
            do {
                logger.info("Creating SSHSession...")
                sshSession = SSHSession()
                sshSession?.delegate = self
                sshSession?.ghosttySurface = surfaceView
                
                // Start SSH connection
                logger.info("Starting SSH connection...")
                try await sshSession?.connect(
                    host: host,
                    port: port,
                    username: username,
                    password: password ?? ""
                )
                
                logger.info("SSH connected successfully!")
                isConnected = true
                onConnected()
                
                // Auto-start wire diagnostics for tmux sessions
                if sshSession?.isTmuxSession == true {
                    wireDiagnostics.start()
                    wireDiagnostics.startCapture(label: "tmux_wire")
                    logger.info("Wire diagnostics auto-started for tmux session")
                }
                
                // Read the actual grid size from Ghostty surface rather than
                // relying on callback-updated cols/rows which may still be the
                // 80x24 defaults if onResize hasn't fired yet.
                if let size = surfaceView?.surfaceSize, size.columns > 0, size.rows > 0 {
                    cols = Int(size.columns)
                    rows = Int(size.rows)
                }
                
                // Send initial terminal size
                logger.info("📡 Setting terminal size: \(cols)x\(rows)")
                sshSession?.resize(cols: cols, rows: rows)
                
            } catch {
                logger.error("❌ SSH connection failed: \(error.localizedDescription)")
                isConnected = false
                onError(error.localizedDescription)
            }
        }
    }
    
    /// Use a pre-connected SSH session (from ConnectionListView)
    func useExistingSession(_ session: SSHSession) {
        logger.info("Using existing pre-connected session")
        sshSession = session
        sshSession?.delegate = self
        sshSession?.ghosttySurface = surfaceView
        isConnected = true
        
        // Auto-start wire diagnostics for tmux sessions
        if session.isTmuxSession {
            wireDiagnostics.start()
            wireDiagnostics.startCapture(label: "tmux_wire")
            logger.info("Wire diagnostics auto-started for tmux session")
        }
        
        // Flush any pending resize that arrived before the session was wired.
        // This handles the common case: layoutSubviews → onResize fired with
        // real dimensions but sshSession was nil, so the resize was stored.
        if let pending = pendingResize {
            logger.info("📡 Flushing pending resize: \(pending.cols)x\(pending.rows)")
            sshSession?.resize(cols: pending.cols, rows: pending.rows)
            pendingResize = nil
        } else {
            // No pending resize — read the actual grid size from Ghostty surface.
            // The SSH PTY was created with 80x24 defaults before the terminal view
            // existed. Now that the surface is laid out, read the real dimensions.
            if let size = surfaceView?.surfaceSize, size.columns > 0, size.rows > 0 {
                cols = Int(size.columns)
                rows = Int(size.rows)
            }
            
            // Send initial terminal size
            logger.info("📡 Setting terminal size: \(cols)x\(rows)")
            sshSession?.resize(cols: cols, rows: rows)
        }
    }
    
    func disconnect() {
        wireDiagnostics.stopCapture()
        wireDiagnostics.stop()
        sshSession?.disconnect()
        sshSession = nil
        isConnected = false
    }
    
    /// Called when Ghostty's write_callback fires — send to SSH.
    /// This uses writeFromGhostty() which bypasses the tmux control mode queueing
    /// guard, because Ghostty's outbound data includes both user keystrokes AND
    /// internal viewer commands that must reach tmux immediately during startup.
    func sendInput(_ data: Data) {
        if let str = String(data: data, encoding: .utf8) {
            logger.debug("⌨️ sendInput: \(data.count) bytes: \(str.prefix(20))")
        } else {
            logger.debug("⌨️ sendInput: \(data.count) bytes (binary)")
        }
        sshSession?.writeFromGhostty(data)
    }
    
    func resize(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        if sshSession != nil {
            sshSession?.resize(cols: cols, rows: rows)
            pendingResize = nil
        } else {
            // SSH session not yet wired — store for flush in useExistingSession().
            // This handles the common case where layoutSubviews fires before
            // viewDidAppear sets up the connection.
            pendingResize = (cols: cols, rows: rows)
        }
    }
    
    func copy() {
        if surfaceView == nil {
            logger.warning("ViewModel.copy: surfaceView is nil")
        }
        surfaceView?.copy(nil)
    }
    
    func paste() {
        if surfaceView == nil {
            logger.warning("ViewModel.paste: surfaceView is nil")
        }
        surfaceView?.paste(nil)
    }
    
    func send(text: String) {
        // Route through Ghostty's input path so tmux send-keys wrapping
        // is applied by the Zig side (Termio.queueWrite → viewer.sendKeys).
        // Falls back to SSHSession.write() if no surface is available.
        if let surface = surfaceView {
            surface.sendText(text)
        } else if let data = text.data(using: .utf8) {
            sshSession?.write(data)
        }
    }
    
    func sendSpecialKey(_ key: SpecialKey) {
        // Use Ghostty's key encoding for proper application cursor mode support
        // This ensures tmux, vim, etc. receive the correct escape sequences
        guard let surfaceView = surfaceView else {
            // Fallback to raw escape sequences if no surface
            let sequence: String
            switch key {
            case .escape: sequence = "\u{1b}"
            case .tab: sequence = "\t"
            case .up: sequence = "\u{1b}[A"
            case .down: sequence = "\u{1b}[B"
            case .left: sequence = "\u{1b}[D"
            case .right: sequence = "\u{1b}[C"
            case .enter: sequence = "\r"
            case .backspace: sequence = "\u{7f}"
            }
            send(text: sequence)
            return
        }
        
        // Send through Ghostty's key encoding
        let virtualKey: Ghostty.SurfaceView.VirtualKey
        switch key {
        case .escape: virtualKey = .escape
        case .tab: virtualKey = .tab
        case .up: virtualKey = .upArrow
        case .down: virtualKey = .downArrow
        case .left: virtualKey = .leftArrow
        case .right: virtualKey = .rightArrow
        case .enter: virtualKey = .enter
        case .backspace: virtualKey = .delete
        }
        
        surfaceView.sendVirtualKey(virtualKey)
    }
    
    /// Set Ctrl toggle state for next keypress (from toolbar button)
    func setCtrlToggle(_ active: Bool) {
        surfaceView?.setCtrlToggle(active)
    }
    
    /// Increase terminal font size
    func increaseFontSize() {
        surfaceView?.increaseFontSize()
        if let surface = surfaceView {
            currentFontSize = surface.currentFontSize
        }
    }
    
    /// Decrease terminal font size
    func decreaseFontSize() {
        surfaceView?.decreaseFontSize()
        if let surface = surfaceView {
            currentFontSize = surface.currentFontSize
        }
    }
    
    /// Set terminal font size to a specific value
    func setFontSize(_ size: Int) {
        surfaceView?.setFontSize(Float(size))
        if let surface = surfaceView {
            currentFontSize = surface.currentFontSize
        }
    }
    
    /// Reset terminal font size to default
    func resetFontSize() {
        surfaceView?.resetFontSize()
        if let surface = surfaceView {
            currentFontSize = surface.currentFontSize
        }
    }
    
    /// Update terminal configuration (e.g., after font family change)
    func updateConfig() {
        surfaceView?.updateConfig()
    }
    
    /// Clear the terminal screen using Ghostty's clear_screen binding action.
    /// This clears selection, erases scrollback history, and at a prompt erases
    /// the display then sends form-feed — superior to raw Ctrl+L.
    func clearScreen() {
        guard let surface = surfaceView?.surface else { return }
        let action = "clear_screen"
        action.withCString { cstr in
            ghostty_surface_binding_action(surface, cstr, UInt(action.utf8.count))
        }
    }
    
    /// Jump to the next or previous shell prompt (requires OSC 133 shell integration).
    /// - Parameter delta: -1 for previous prompt, 1 for next prompt
    func jumpToPrompt(delta: Int) {
        guard let surface = surfaceView?.surface else { return }
        let action = "jump_to_prompt:\(delta)"
        action.withCString { cstr in
            ghostty_surface_binding_action(surface, cstr, UInt(action.utf8.count))
        }
    }
    
    /// Reset the terminal (ESC c - full reset)
    func resetTerminal() {
        // Send ESC c (RIS - Reset to Initial State)
        send(text: "\u{1b}c")
    }
    
    // MARK: - tmux Integration
    
    /// Whether the current session is a tmux session
    var isTmuxSession: Bool {
        sshSession?.isTmuxSession ?? false
    }
    
    /// Access the tmux session manager for multi-pane support
    var tmuxManager: TmuxSessionManager? {
        sshSession?.tmuxSessionManager
    }
    
    enum SpecialKey {
        case escape, tab, up, down, left, right, enter, backspace
    }
}

// MARK: - SSHSessionDelegate
// SSHSessionDelegate is @MainActor. TerminalViewModel is @MainActor. Delegate calls
// arrive synchronously from SSHSession.handleReceivedData() on MainActor. No nonisolated
// or Task wrapper needed — methods execute synchronously, preserving SSH chunk ordering.
extension TerminalViewModel: SSHSessionDelegate {
    func sshSession(_ session: SSHSession, didReceiveData data: Data) {
        // Feed data from SSH to Ghostty terminal for display
        if let surface = surfaceView {
            logger.debug("Received \(data.count) bytes from SSH, feeding to Ghostty")
            
            // Shadow-analyze for tmux wire diagnostics (no-op if not active)
            wireDiagnostics.analyze(data)
            
            surface.feedData(data)
        } else {
            // Buffer data until surface is ready
            logger.debug("Buffering \(data.count) bytes (surface not ready yet)")
            preSurfaceBuffer.append(data)
        }
    }
    
    func sshSession(_ session: SSHSession, didDisconnectWithError error: Error?) {
        // Stop wire diagnostics and log summary
        if wireDiagnostics.isActive {
            logger.info("Wire diagnostics summary: \(self.wireDiagnostics.summary())")
            wireDiagnostics.stopCapture()
            wireDiagnostics.stop()
        }
        
        isConnected = false
        // Set disconnectedByRemote for both error and clean disconnects
        // This triggers navigation back to the connection screen
        disconnectedByRemote = true
        if let error = error {
            logger.error("SSH disconnected with error: \(error.localizedDescription)")
            disconnectError = error.localizedDescription
        } else {
            logger.info("SSH disconnected cleanly (remote closed)")
            disconnectError = nil
        }
    }
    
    func sshSessionDidConnect(_ session: SSHSession) {
        logger.info("✅ SSH session connected!")
        isConnected = true
        disconnectedByRemote = false
        disconnectError = nil
    }
}

// MARK: - Ultra Barebones Mode: Pure UIKit Terminal

/// A UIViewControllerRepresentable that hosts a pure UIKit view controller
/// containing the Ghostty SurfaceView. This bypasses all SwiftUI view management
/// to test if the flash is caused by SwiftUI.
struct RawTerminalViewController: UIViewControllerRepresentable {
    let ghosttyApp: Ghostty.App
    @ObservedObject var viewModel: TerminalViewModel
    let onSetup: () -> Void
    
    func makeUIViewController(context: Context) -> RawTerminalUIViewController {
        let vc = RawTerminalUIViewController()
        vc.ghosttyApp = ghosttyApp
        vc.viewModel = viewModel
        vc.onSetup = onSetup
        return vc
    }
    
    func updateUIViewController(_ uiViewController: RawTerminalUIViewController, context: Context) {
        // No updates needed
    }
    
    /// T3: Guaranteed cleanup when SwiftUI removes this representable.
    /// Catches cases where viewWillDisappear is not called (e.g., conditional
    /// view removal, navigation pop without animation). See #42.
    static func dismantleUIViewController(_ uiViewController: RawTerminalUIViewController, coordinator: ()) {
        uiViewController.performTeardown()
    }
}

/// Pure UIKit view controller that directly hosts the Ghostty SurfaceView
///
/// Explicitly @MainActor to guarantee all ThemeManager.shared and UIKit
/// access is provably main-actor-isolated under Swift 6 concurrency.
@MainActor
class RawTerminalUIViewController: UIViewController {
    var ghosttyApp: Ghostty.App?
    var viewModel: TerminalViewModel?
    var onSetup: (() -> Void)?
    var surfaceView: Ghostty.SurfaceView?
    
    /// T3: Idempotency guard — prevents double teardown when both
    /// viewWillDisappear and dismantleUIViewController fire. See #42.
    private var tornDown = false
    
    // Constraint for top edge - adjusted based on status bar visibility
    var surfaceTopConstraint: NSLayoutConstraint?
    
    // Constraint for bottom edge - adjusted based on keyboard visibility
    var surfaceBottomConstraint: NSLayoutConstraint?
    
    // Cached safe area top inset — used to avoid redundant layout updates
    // when viewDidLayoutSubviews fires without an actual inset change. (#44 Bug 2)
    private var lastSafeAreaTopInset: CGFloat = -1
    
    // Settings observation
    private var settingsObserver: NSObjectProtocol?
    
    // Menu bar notification observers (must be stored for cleanup)
    var menuBarObservers: [NSObjectProtocol] = []
    
    // Keyboard observers
    var keyboardWillShowObserver: NSObjectProtocol?
    var keyboardWillHideObserver: NSObjectProtocol?
    
    // Tracked keyboard height — used by status bar constraint logic to determine
    // whether the keyboard is currently pushing the terminal up.
    var currentKeyboardHeight: CGFloat = 0
    
    // Search overlay hosting controller
    var searchOverlayHostingController: UIHostingController<Ghostty.SurfaceSearchOverlay>?
    
    // Search state observer
    var searchStateObserver: AnyCancellable?
    
    // Search bar position and constraints (managed by +Search.swift)
    enum SearchBarCorner {
        case topLeft, topRight, bottomLeft, bottomRight
    }
    var searchBarCorner: SearchBarCorner = .topRight
    var searchBarTopConstraint: NSLayoutConstraint?
    var searchBarBottomConstraint: NSLayoutConstraint?
    var searchBarLeadingConstraint: NSLayoutConstraint?
    var searchBarTrailingConstraint: NSLayoutConstraint?
    
    // Key table indicator (vim-style modal keys)
    private var keyTableIndicatorHostingController: UIHostingController<KeyTableIndicatorView>?
    var keyTableObserver: AnyCancellable?
    
    // Multi-pane support
    var multiPaneHostingController: UIHostingController<TmuxMultiPaneView>?
    var multiPaneTopConstraint: NSLayoutConstraint?
    var multiPaneBottomConstraint: NSLayoutConstraint?
    var splitTreeObserver: AnyCancellable?
    var connectionObserver: AnyCancellable?
    var isMultiPaneMode = false
    
    // UIKit divider overlay for drag gestures (sits on top of multi-pane view)
    var dividerOverlayView: DividerOverlayView?
    var dividerTreeObserver: AnyCancellable?
    
    // Command palette overlay
    var commandPaletteHostingController: UIHostingController<AnyView>?
    
    // Reconnecting overlay (WS-R2)
    var reconnectingOverlay: UIView?
    var reconnectingObserver: AnyCancellable?
    
    // Window picker support (shown when multiple tmux windows exist)
    var windowPickerHostingController: UIHostingController<TmuxWindowPickerView>?
    var windowsObserver: AnyCancellable?
    var isShowingWindowPicker = false
    let windowPickerHeight: CGFloat = 36
    
    // tmux status bar (shown at bottom when tmux provides status-left/right)
    var statusBarHostingController: UIHostingController<TmuxStatusBarView>?
    var statusBarObserver: AnyCancellable?
    var isShowingTmuxStatusBar = false
    let tmuxStatusBarHeight: CGFloat = TmuxStatusBarView.barHeight
    
    // Status bar preference (read from UserDefaults)
    var showStatusBar: Bool {
        UserDefaults.standard.bool(forKey: UserDefaultsKey.showStatusBar)
    }
    
    override var prefersStatusBarHidden: Bool {
        // On iPad, never force-hide the status bar. Doing so puts the app into
        // full-screen immersive mode which suppresses the iPadOS system menu bar
        // (File/Edit/View/Terminal/Connection/Help) that users with hardware
        // keyboards depend on. The status bar is minimal on iPad and the menu bar
        // is critical for discoverability.
        if UIDevice.current.userInterfaceIdiom == .pad {
            return false
        }
        return !showStatusBar
    }
    
    override var preferredStatusBarStyle: UIStatusBarStyle {
        .lightContent
    }
    
    /// Auto-hide the home indicator after a few seconds of inactivity.
    /// Terminal apps are full-screen immersive experiences — the persistent
    /// home indicator bar wastes bottom screen real estate and is visually
    /// distracting on a dark terminal background.
    override var prefersHomeIndicatorAutoHidden: Bool {
        true
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Set the view's background to theme color
        let themeBg = ThemeManager.shared.selectedTheme.background
        view.backgroundColor = UIColor(themeBg)
        
        // Create and add the surface view
        createSurfaceView()
        
        // Set up surface factory for tmux multi-pane support
        setupTmuxSurfaceFactory()
        
        // Observe split tree changes for multi-pane mode
        setupSplitTreeObserver()
        
        // Observe windows changes for window picker
        setupWindowsObserver()
        
        // Observe status bar changes for tmux status-left/right
        setupStatusBarObserver()
        
        // Also observe connection state - tmux manager may not exist yet at viewDidLoad
        setupConnectionObserver()
        
        // Observe settings changes
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateStatusBarAndLayout()
        }
        
        // Observe keyboard frame changes
        setupKeyboardObservers()
        
        // Observe menu bar commands
        setupMenuBarNotifications()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        // Setup connection after view appears
        onSetup?()
        
        // Initial layout update
        updateStatusBarAndLayout()
    }
    
    // MARK: - Status Bar & Layout
    
    private func updateStatusBarAndLayout() {
        // Tell UIKit to re-query prefersStatusBarHidden
        setNeedsStatusBarAppearanceUpdate()
        
        // Update the layout
        UIView.animate(withDuration: 0.25) {
            self.updateTopConstraint()
            self.view.layoutIfNeeded()
        }
        
        // Notify surface of size change
        if let surface = surfaceView {
            surface.sizeDidChange(surface.bounds.size)
        }
    }
    
    private func updateTopConstraint() {
        // Delegate to updateTerminalTopConstraint() which accounts for both
        // status bar visibility AND window picker visibility. (#44 T6)
        updateTerminalTopConstraint()
    }
    
    func toggleStatusBar() {
        let newValue = !showStatusBar
        UserDefaults.standard.set(newValue, forKey: UserDefaultsKey.showStatusBar)
        updateStatusBarAndLayout()
    }
    
    // MARK: - Settings
    
    @objc func handleSettingsButton() {
        // Present settings as a sheet
        let settingsView = SettingsView(
            currentFontSize: Int(viewModel?.currentFontSize ?? 14),
            onFontSizeChanged: { [weak self] newSize in
                self?.viewModel?.setFontSize(newSize)
            },
            onResetFontSize: { [weak self] in
                self?.viewModel?.resetFontSize()
            },
            onFontFamilyChanged: { [weak self] in
                self?.viewModel?.updateConfig()
            },
            onThemeChanged: { [weak self] in
                self?.viewModel?.updateConfig()
                // Update our background color too
                let themeBg = ThemeManager.shared.selectedTheme.background
                self?.view.backgroundColor = UIColor(themeBg)
            }
        )
        
        let hostingController = UIHostingController(rootView: settingsView)
        hostingController.modalPresentationStyle = .pageSheet
        
        if let sheet = hostingController.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        
        present(hostingController, animated: true)
    }
    
    func reloadConfiguration() {
        logger.info("🔄 Reloading configuration...")
        viewModel?.updateConfig()
        
        // Update background color in case theme changed
        let themeBg = ThemeManager.shared.selectedTheme.background
        view.backgroundColor = UIColor(themeBg)
        
        logger.info("✅ Configuration reloaded")
    }
    
    // MARK: - Reconnecting Overlay (WS-R2)
    
    /// Observe `sshSession.isReconnecting` and show/hide the reconnecting overlay.
    func setupReconnectingObserver() {
        guard let session = viewModel?.sshSession else { return }
        
        reconnectingObserver = session.$isReconnecting
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isReconnecting in
                if isReconnecting {
                    self?.showReconnectingOverlay()
                } else {
                    self?.hideReconnectingOverlay()
                }
            }
    }
    
    /// Show a translucent "Reconnecting..." overlay on top of the terminal.
    /// The terminal surfaces remain visible underneath for visual continuity.
    func showReconnectingOverlay() {
        guard reconnectingOverlay == nil else { return }
        
        // Blur background
        let blurEffect = UIBlurEffect(style: .dark)
        let blurView = UIVisualEffectView(effect: blurEffect)
        blurView.alpha = 0.85
        blurView.translatesAutoresizingMaskIntoConstraints = false
        
        // Content stack: spinner + label
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.startAnimating()
        
        let label = UILabel()
        label.text = "Reconnecting..."
        label.textColor = .white
        label.font = .systemFont(ofSize: 18, weight: .medium)
        
        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        
        blurView.contentView.addSubview(stack)
        
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: blurView.contentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: blurView.contentView.centerYAnchor),
        ])
        
        view.addSubview(blurView)
        
        NSLayoutConstraint.activate([
            blurView.topAnchor.constraint(equalTo: view.topAnchor),
            blurView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            blurView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        
        reconnectingOverlay = blurView
        
        // Fade in
        blurView.alpha = 0
        UIView.animate(withDuration: 0.3) {
            blurView.alpha = 0.85
        }
        
        logger.info("Showing reconnecting overlay")
    }
    
    /// Hide the reconnecting overlay with a fade-out animation.
    func hideReconnectingOverlay() {
        guard let overlay = reconnectingOverlay else { return }
        
        UIView.animate(withDuration: 0.3, animations: {
            overlay.alpha = 0
        }, completion: { _ in
            overlay.removeFromSuperview()
        })
        
        reconnectingOverlay = nil
        logger.info("Hiding reconnecting overlay")
    }
    
    // MARK: - Key Table Indicator
    
    func updateKeyTableIndicator(tableName: String?) {
        if let name = tableName {
            // Show or update key table indicator
            if keyTableIndicatorHostingController == nil {
                let indicator = KeyTableIndicatorView(tableName: name)
                let hostingController = UIHostingController(rootView: indicator)
                hostingController.view.backgroundColor = .clear
                hostingController.view.translatesAutoresizingMaskIntoConstraints = false
                
                addChild(hostingController)
                view.addSubview(hostingController.view)
                
                // Position at bottom-left corner with safe area consideration
                NSLayoutConstraint.activate([
                    hostingController.view.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
                    hostingController.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
                ])
                
                hostingController.didMove(toParent: self)
                keyTableIndicatorHostingController = hostingController
            } else {
                // Update existing indicator
                keyTableIndicatorHostingController?.rootView = KeyTableIndicatorView(tableName: name)
            }
        } else {
            // Hide indicator
            removeKeyTableIndicator()
        }
    }
    
    private func removeKeyTableIndicator() {
        if let hostingController = keyTableIndicatorHostingController {
            hostingController.willMove(toParent: nil)
            hostingController.view.removeFromSuperview()
            hostingController.removeFromParent()
            keyTableIndicatorHostingController = nil
        }
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        // Only update the top constraint when the safe area has actually changed.
        // viewDidLayoutSubviews can fire frequently (hover, animation frames, etc.)
        // and redundant updateTerminalTopConstraint() calls trigger unnecessary
        // layout animations that cause visible jitter. (#44 Bug 2)
        let currentTopInset = view.safeAreaInsets.top
        if currentTopInset != lastSafeAreaTopInset {
            lastSafeAreaTopInset = currentTopInset
            updateTopConstraint()
        }
        
        // Refresh divider overlay positions after container bounds change
        // (e.g., rotation, keyboard show/hide, multitasking resize)
        if let overlay = dividerOverlayView,
           let tmuxManager = viewModel?.tmuxManager {
            let size = multiPaneHostingController?.view.bounds.size ?? .zero
            overlay.cellSize = tmuxManager.primaryCellSize
            overlay.updateDividers(from: tmuxManager.currentSplitTree, containerSize: size)
        }
    }
    
    // MARK: - Surface Creation
    
    /// Create surface view - for non-tmux mode, creates directly.
    /// For tmux mode, this sets up the factory and waits for TmuxSessionManager to create.
    private func createSurfaceView() {
        guard let ghosttyApp = ghosttyApp,
              ghosttyApp.readiness == .ready,
              let _ = ghosttyApp.app else {
            logger.warning("⚠️ Ghostty not ready in RawTerminalUIViewController")
            return
        }
        
        // Always configure the surface management first
        // This allows TmuxSessionManager to create surfaces when ready
        configureSurfaceManagement()
        
        // Check if we're in tmux mode with an existing manager
        if let tmuxManager = viewModel?.tmuxManager {
            // Ask TmuxSessionManager to create the primary surface
            if let surface = tmuxManager.createPrimarySurface() {
                displaySurface(surface)
                logger.info("✅ Using TmuxSessionManager-owned primary surface")
            } else {
                // Factory might not be ready yet - will be created on connection
                logger.info("Primary surface not ready yet, will create on connection")
            }
        } else {
            // Non-tmux mode - create surface directly (legacy path)
            createDirectSurface()
        }
    }
    
    /// Create a surface directly (non-tmux legacy path)
    private func createDirectSurface() {
        guard let ghosttyApp = ghosttyApp,
              let app = ghosttyApp.app else {
            return
        }
        
        var config = Ghostty.SurfaceConfiguration()
        config.backendType = .external
        
        let surface = Ghostty.SurfaceView(app, baseConfig: config)
        
        let themeBg = ThemeManager.shared.selectedTheme.background
        surface.backgroundColor = UIColor(themeBg)
        
        // Wire up shortcut delegate for Ghostty keybindings
        surface.shortcutDelegate = self
        
        // Wire up callbacks directly to SSH (non-tmux mode)
        // onWrite arrives on main thread (C callback dispatches via DispatchQueue.main.async)
        surface.onWrite = { [weak self] data in
            self?.viewModel?.sendInput(data)
        }
        
        // onResize fires synchronously from layoutSubviews → sizeDidChange(),
        // which is always on the main thread. Do NOT wrap in Task — the async
        // deferral introduces a race where connect()/useExistingSession() reads
        // stale 80x24 defaults before the deferred Task updates cols/rows.
        surface.onResize = { [weak self] cols, rows in
            self?.viewModel?.resize(cols: cols, rows: rows)
        }
        
        displaySurface(surface)
        logger.info("✅ Created direct surface (non-tmux mode)")
    }
    
    /// Display a surface in the view hierarchy
    func displaySurface(_ surface: Ghostty.SurfaceView) {
        self.surfaceView = surface
        
        // Ensure shortcut delegate is wired up (may already be set by factory)
        if surface.shortcutDelegate == nil {
            surface.shortcutDelegate = self
        }
        
        surface.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(surface)
        
        let topConstraint = surface.topAnchor.constraint(equalTo: view.topAnchor, constant: 0)
        let bottomConstraint = surface.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: 0)
        surfaceTopConstraint = topConstraint
        surfaceBottomConstraint = bottomConstraint
        
        NSLayoutConstraint.activate([
            topConstraint,
            bottomConstraint,
            surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        
        viewModel?.surfaceView = surface
        
        setupSearchStateObserver()
        
        surface.focusDidChange(true)
        _ = surface.becomeFirstResponder()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        // Only perform full teardown when the VC is actually being removed from
        // the navigation stack or dismissed, NOT when a sheet (Settings, etc.) is
        // presented over it — presenting a pageSheet triggers viewWillDisappear
        // on the presenting VC.
        guard isMovingFromParent || isBeingDismissed else { return }
        
        performTeardown()
    }
    
    /// Shared teardown for both viewWillDisappear and dismantleUIViewController.
    /// Idempotent — safe to call multiple times (guarded by `tornDown`). See #42 T3.
    func performTeardown() {
        guard !tornDown else { return }
        tornDown = true
        
        // Remove settings observer
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
            settingsObserver = nil
        }
        
        // Remove keyboard observers
        if let observer = keyboardWillShowObserver {
            NotificationCenter.default.removeObserver(observer)
            keyboardWillShowObserver = nil
        }
        if let observer = keyboardWillHideObserver {
            NotificationCenter.default.removeObserver(observer)
            keyboardWillHideObserver = nil
        }
        
        // Remove menu bar observers
        for observer in menuBarObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        menuBarObservers.removeAll()
        
        // Cancel search observer and remove overlay
        searchStateObserver?.cancel()
        searchStateObserver = nil
        removeSearchOverlay()
        
        // Cancel key table observer and remove indicator
        keyTableObserver?.cancel()
        keyTableObserver = nil
        removeKeyTableIndicator()
        
        // Cancel split tree and connection observers, cleanup multi-pane view
        splitTreeObserver?.cancel()
        splitTreeObserver = nil
        connectionObserver?.cancel()
        connectionObserver = nil
        
        // Cancel status bar observer and remove overlay
        statusBarObserver?.cancel()
        statusBarObserver = nil
        hideTmuxStatusBar()
        
        transitionToSingleSurfaceMode()
        
        viewModel?.disconnect()
        viewModel?.surfaceView?.close()
        viewModel?.surfaceView = nil
    }
    
    deinit {
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = keyboardWillShowObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = keyboardWillHideObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        for observer in menuBarObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        menuBarObservers.removeAll()
        searchStateObserver?.cancel()
        splitTreeObserver?.cancel()
        connectionObserver?.cancel()
        keyTableObserver?.cancel()
        reconnectingObserver?.cancel()
        statusBarObserver?.cancel()
    }
}

#Preview {
    NavigationStack {
        TerminalContainerView()
            .environmentObject(AppState())
            .environmentObject(Ghostty.App())
    }
}

// MARK: - Key Table Indicator View
// See KeyTableIndicatorView.swift in UI/
