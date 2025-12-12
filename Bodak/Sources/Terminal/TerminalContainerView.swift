//
//  TerminalContainerView.swift
//  Bodak
//
//  Terminal container using Ghostty for terminal emulation
//

import SwiftUI
import UIKit
import Combine
import GhosttyKit
import os.log

private let logger = Logger(subsystem: "com.bodak", category: "Terminal")

/// Container view that wraps the Ghostty terminal surface
struct TerminalContainerView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var ghosttyApp: Ghostty.App
    @ObservedObject private var settings = AppSettings.shared
    @State private var terminalTitle: String = "Terminal"
    @StateObject private var terminalViewModel = TerminalViewModel()
    @State private var keyboardHeight: CGFloat = 0
    
    // Link preview state
    @State private var hoverUrl: String? = nil
    @State private var hoverUrlCancellable: AnyCancellable? = nil
    
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
        } else if case .connected = appState.connectionStatus,
           let host = appState.currentHost,
           let port = appState.currentPort,
           let username = appState.currentUsername {
            logger.info("🔌 Initiating SSH connection to \(host):\(port) as \(username)")
            terminalViewModel.connect(
                host: host,
                port: port,
                username: username,
                password: appState.currentPassword
            )
        } else {
            logger.warning("🔌 Not connecting - no session or params available")
        }
    }
    
    private func disconnect() {
        terminalViewModel.disconnect()
        appState.connectionStatus = .disconnected
    }
}

/// ViewModel that bridges Ghostty with SSH connection
@MainActor
class TerminalViewModel: ObservableObject {
    @Published var title: String = ""
    @Published var isConnected: Bool = false
    @Published var disconnectedByRemote: Bool = false
    @Published var disconnectError: String? = nil
    @Published var isSelectingText: Bool = false
    @Published var currentFontSize: Float = 14.0
    @Published var connectionDuration: TimeInterval = 0
    
    /// Connection start time for duration tracking
    private var connectionStartTime: Date?
    private var durationTimer: Timer?
    
    /// Reference to the Ghostty surface view
    weak var surfaceView: Ghostty.SurfaceView? {
        didSet {
            // Cancel any existing subscription
            fontSizeCancellable?.cancel()
            fontSizeCancellable = nil
            
            // Sync font size when surfaceView is set and observe changes
            if let surface = surfaceView {
                currentFontSize = surface.currentFontSize
                
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
    private var sshSession: SSHSession?
    
    /// Terminal dimensions
    private var cols: Int = 80
    private var rows: Int = 24
    
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
            Task { @MainActor in
                self?.sshSession?.appWillResignActive()
            }
        }
        lifecycleObservers.append(resignObserver)
        
        // When app comes back, resume paused panes
        let activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.sshSession?.appDidBecomeActive()
            }
        }
        lifecycleObservers.append(activeObserver)
    }
    
    /// Start tracking connection duration
    func startDurationTimer() {
        connectionStartTime = Date()
        connectionDuration = 0
        
        // Update duration every second
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let startTime = self.connectionStartTime else { return }
                self.connectionDuration = Date().timeIntervalSince(startTime)
            }
        }
    }
    
    /// Stop duration timer
    func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }
    
    /// Formatted connection duration string
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
    
    func connect(host: String, port: Int, username: String, password: String?) {
        logger.info("📡 TerminalViewModel.connect called - \(host):\(port) user=\(username)")
        Task {
            do {
                logger.info("📡 Creating SSHSession...")
                sshSession = SSHSession()
                sshSession?.delegate = self
                
                // Start SSH connection
                logger.info("📡 Starting SSH connection...")
                try await sshSession?.connect(
                    host: host,
                    port: port,
                    username: username,
                    password: password ?? ""
                )
                
                logger.info("📡 SSH connected successfully!")
                isConnected = true
                startDurationTimer()
                
                // Send initial terminal size
                logger.info("📡 Setting terminal size: \(cols)x\(rows)")
                sshSession?.resize(cols: cols, rows: rows)
                
            } catch {
                logger.error("❌ SSH connection failed: \(error.localizedDescription)")
                isConnected = false
            }
        }
    }
    
    /// Use a pre-connected SSH session (from ConnectionListView)
    func useExistingSession(_ session: SSHSession) {
        logger.info("📡 Using existing pre-connected session")
        sshSession = session
        sshSession?.delegate = self
        isConnected = true
        startDurationTimer()
        
        // Send initial terminal size
        logger.info("📡 Setting terminal size: \(cols)x\(rows)")
        sshSession?.resize(cols: cols, rows: rows)
    }
    
    func disconnect() {
        stopDurationTimer()
        sshSession?.disconnect()
        sshSession = nil
        isConnected = false
    }
    
    /// Called when user types - send to SSH
    func sendInput(_ data: Data) {
        if let str = String(data: data, encoding: .utf8) {
            logger.debug("⌨️ sendInput: \(data.count) bytes: \(str.prefix(20))")
        } else {
            logger.debug("⌨️ sendInput: \(data.count) bytes (binary)")
        }
        sshSession?.write(data)
    }
    
    func resize(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        sshSession?.resize(cols: cols, rows: rows)
    }
    
    func copy() {
        guard let surface = surfaceView?.surface else {
            logger.warning("📋 Copy: no surface available")
            return
        }
        
        // Check if there's a selection
        guard ghostty_surface_has_selection(surface) else {
            logger.info("📋 Copy: no selection")
            return
        }
        
        // Read the selection
        var textStruct = ghostty_text_s()
        if ghostty_surface_read_selection(surface, &textStruct) {
            if let textPtr = textStruct.text, textStruct.text_len > 0 {
                let selectedText = String(cString: textPtr)
                UIPasteboard.general.string = selectedText
                logger.info("📋 Copied \(textStruct.text_len) characters to clipboard")
            }
            // Free the text
            ghostty_surface_free_text(surface, &textStruct)
        }
        
        // Clear selection state after copying
        isSelectingText = false
    }
    
    /// Called when selection state changes (from SurfaceView)
    func selectionDidChange(_ hasSelection: Bool) {
        isSelectingText = hasSelection
    }
    
    func paste() {
        if let text = UIPasteboard.general.string {
            send(text: text)
        }
    }
    
    func send(text: String) {
        if let data = text.data(using: .utf8) {
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
    
    /// Clear the terminal screen (Ctrl+L)
    func clearScreen() {
        // Send Ctrl+L (form feed / clear screen)
        send(text: "\u{0c}")
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
    
    /// Capture tmux pane content for search
    /// - Parameter completion: Called with the captured content or error
    func captureTmuxPane(completion: @escaping (Result<String, Error>) -> Void) {
        guard let session = sshSession else {
            completion(.failure(SSHError.notConnected))
            return
        }
        session.captureTmuxPane(completion: completion)
    }
    
    /// Navigate to a specific line in tmux using copy mode
    /// - Parameter lineNumber: The line number to navigate to (0-based from top of scrollback)
    func tmuxGotoLine(_ lineNumber: Int) {
        // Send tmux prefix (Ctrl+B) then copy-mode key ([)
        // Then navigate to the line using tmux copy-mode commands
        // Ctrl+B = \u{02}, [ enters copy mode
        // g goes to top, then we can use : to go to line number
        
        // Enter copy mode: Ctrl+B [
        send(text: "\u{02}[")
        
        // Small delay then go to top and line
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            // g = go to top of history
            self?.send(text: "g")
            
            // Then go down to the target line
            // In tmux copy mode, we can use : followed by line number
            // Or just send the line number followed by Enter for goto-line
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                // : enters command mode, then line number
                self?.send(text: ":\(lineNumber)\r")
            }
        }
    }
    
    enum SpecialKey {
        case escape, tab, up, down, left, right, enter, backspace
    }
}

// MARK: - SSHSessionDelegate
extension TerminalViewModel: SSHSessionDelegate {
    nonisolated func sshSession(_ session: SSHSession, didReceiveData data: Data) {
        Task { @MainActor in
            // Feed data from SSH to Ghostty terminal for display
            if let surface = surfaceView {
                logger.info("📥 Received \(data.count) bytes from SSH, feeding to Ghostty")
                if let text = String(data: data, encoding: .utf8) {
                    logger.debug("📥 Data preview: \(text.prefix(100))")
                }
                surface.feedData(data)
            } else {
                logger.error("⚠️ Received \(data.count) bytes but surfaceView is nil!")
            }
        }
    }
    
    nonisolated func sshSession(_ session: SSHSession, didDisconnectWithError error: Error?) {
        Task { @MainActor in
            isConnected = false
            // Set disconnectedByRemote for both error and clean disconnects
            // This triggers navigation back to the connection screen
            disconnectedByRemote = true
            if let error = error {
                logger.error("❌ SSH disconnected with error: \(error.localizedDescription)")
                disconnectError = error.localizedDescription
            } else {
                logger.info("🔌 SSH disconnected cleanly (remote closed)")
                disconnectError = nil
            }
        }
    }
    
    nonisolated func sshSessionDidConnect(_ session: SSHSession) {
        Task { @MainActor in
            logger.info("✅ SSH session connected!")
            isConnected = true
            disconnectedByRemote = false
            disconnectError = nil
        }
    }
}

/// Quick access toolbar for common terminal actions
struct TerminalToolbar: View {
    @ObservedObject var viewModel: TerminalViewModel
    @State private var ctrlPressed = false
    @State private var ctrlPulsePhase = false
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                // Common key shortcuts
                ToolbarButton(symbol: "escape", label: "ESC") {
                    viewModel.sendSpecialKey(.escape)
                }
                
                ToolbarButton(symbol: "arrow.right.to.line", label: "Tab") {
                    viewModel.sendSpecialKey(.tab)
                }
                
                // Ctrl toggle with visual indicator when active
                CtrlToggleButton(isActive: $ctrlPressed, pulsePhase: $ctrlPulsePhase) {
                    ctrlPressed.toggle()
                    viewModel.setCtrlToggle(ctrlPressed)
                }
                
                // Arrow keys
                ToolbarButton(symbol: "arrow.up", label: "↑") {
                    viewModel.sendSpecialKey(.up)
                }
                
                ToolbarButton(symbol: "arrow.down", label: "↓") {
                    viewModel.sendSpecialKey(.down)
                }
                
                ToolbarButton(symbol: "arrow.left", label: "←") {
                    viewModel.sendSpecialKey(.left)
                }
                
                ToolbarButton(symbol: "arrow.right", label: "→") {
                    viewModel.sendSpecialKey(.right)
                }
                
                Divider()
                    .frame(height: 24)
                    .padding(.horizontal, 4)
                
                // Common special characters hard to type on iOS keyboard
                CharacterButton(char: "|", label: "pipe") {
                    viewModel.send(text: "|")
                }
                
                CharacterButton(char: "~", label: "tilde") {
                    viewModel.send(text: "~")
                }
                
                CharacterButton(char: "`", label: "tick") {
                    viewModel.send(text: "`")
                }
                
                CharacterButton(char: "\\", label: "bslash") {
                    viewModel.send(text: "\\")
                }
                
                Spacer()
                
                ToolbarButton(symbol: "keyboard.chevron.compact.down", label: "Hide") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
            .padding(.horizontal, 8)
        }
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.7))
        // Start/stop pulsing animation when Ctrl is toggled
        .onChange(of: ctrlPressed) { _, isActive in
            if isActive {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    ctrlPulsePhase = true
                }
            } else {
                withAnimation(.easeInOut(duration: 0.15)) {
                    ctrlPulsePhase = false
                }
            }
        }
    }
}

/// Ctrl toggle button with visual pulsing indicator when active
struct CtrlToggleButton: View {
    @Binding var isActive: Bool
    @Binding var pulsePhase: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: isActive ? "control.fill" : "control")
                    .font(.system(size: 16))
                Text("Ctrl")
                    .font(.system(size: 10))
            }
            .frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(isActive ? .white : .primary)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? Color.orange : Color.clear)
                    .opacity(isActive ? (pulsePhase ? 1.0 : 0.6) : 0)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isActive ? Color.orange : Color.clear, lineWidth: 2)
                    .opacity(isActive ? (pulsePhase ? 0.3 : 1.0) : 0)
            )
        }
        .accessibilityLabel("Control key modifier")
        .accessibilityValue(isActive ? "Active" : "Inactive")
        .accessibilityHint("Double tap to toggle. When active, the next key press will include Control.")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Button for character input
struct CharacterButton: View {
    let char: String
    let label: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(char)
                .font(.system(size: 18, weight: .medium, design: .monospaced))
                .frame(minWidth: 36, minHeight: 44)
        }
        .foregroundStyle(.primary)
        .accessibilityLabel(label)
        .accessibilityHint("Inserts \(char) character")
    }
}

struct ToolbarButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 16))
                Text(label)
                    .font(.system(size: 10))
            }
            .frame(minWidth: 44, minHeight: 44)
        }
        .foregroundStyle(.primary)
        .accessibilityLabel(label)
    }
}

// MARK: - Shake to Clear

/// UIViewController subclass that detects shake gestures
class ShakeDetectingViewController: UIViewController {
    var onShake: (() -> Void)?
    
    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            // Haptic feedback
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
            onShake?()
        }
    }
    
    override var canBecomeFirstResponder: Bool { true }
}

/// SwiftUI wrapper for shake detection
struct ShakeDetector: UIViewControllerRepresentable {
    let onShake: () -> Void
    
    func makeUIViewController(context: Context) -> ShakeDetectingViewController {
        let vc = ShakeDetectingViewController()
        vc.onShake = onShake
        return vc
    }
    
    func updateUIViewController(_ uiViewController: ShakeDetectingViewController, context: Context) {
        uiViewController.onShake = onShake
    }
}

/// View modifier for adding shake detection
extension View {
    func onShake(perform action: @escaping () -> Void) -> some View {
        self.background(ShakeDetector(onShake: action))
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
}

/// Pure UIKit view controller that directly hosts the Ghostty SurfaceView
class RawTerminalUIViewController: UIViewController {
    var ghosttyApp: Ghostty.App?
    var viewModel: TerminalViewModel?
    var onSetup: (() -> Void)?
    private var surfaceView: Ghostty.SurfaceView?
    
    // Constraint for top edge - adjusted based on status bar visibility
    private var surfaceTopConstraint: NSLayoutConstraint?
    
    // Constraint for bottom edge - adjusted based on keyboard visibility
    private var surfaceBottomConstraint: NSLayoutConstraint?
    
    // Settings observation
    private var settingsObserver: NSObjectProtocol?
    
    // Keyboard observers
    private var keyboardWillShowObserver: NSObjectProtocol?
    private var keyboardWillHideObserver: NSObjectProtocol?
    
    // Search overlay hosting controller
    private var searchOverlayHostingController: UIHostingController<Ghostty.SurfaceSearchOverlay>?
    
    // Search state observer
    private var searchStateObserver: AnyCancellable?
    
    // Secure keyboard entry state
    private var secureKeyboardEntry = false
    
    // Multi-pane support
    private var multiPaneHostingController: UIHostingController<TmuxMultiPaneView>?
    private var multiPaneTopConstraint: NSLayoutConstraint?
    private var multiPaneBottomConstraint: NSLayoutConstraint?
    private var splitTreeObserver: AnyCancellable?
    private var connectionObserver: AnyCancellable?
    private var isMultiPaneMode = false
    
    // Status bar preference (read from UserDefaults)
    private var showStatusBar: Bool {
        UserDefaults.standard.bool(forKey: "ui.showStatusBar")
    }
    
    override var prefersStatusBarHidden: Bool {
        !showStatusBar
    }
    
    override var preferredStatusBarStyle: UIStatusBarStyle {
        .lightContent
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
    
    private func setupKeyboardObservers() {
        keyboardWillShowObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillShowNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleKeyboardWillShow(notification)
        }
        
        keyboardWillHideObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleKeyboardWillHide(notification)
        }
    }
    
    private func handleKeyboardWillShow(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let keyboardFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double,
              let curveValue = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int else {
            return
        }
        
        let curve = UIView.AnimationCurve(rawValue: curveValue) ?? .easeInOut
        
        // Convert keyboard frame to view coordinates
        let keyboardHeight = view.convert(keyboardFrame, from: nil).height
        
        // Calculate the new size BEFORE animating
        let newHeight = view.bounds.height - keyboardHeight
        let newSize = CGSize(width: view.bounds.width, height: newHeight)
        
        // Notify Ghostty of size change BEFORE animation to pre-render
        // This prevents the white flash during resize
        if let surface = self.surfaceView, !isMultiPaneMode {
            surface.sizeDidChange(newSize)
        }
        
        // Disable implicit CALayer animations during resize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        // Animate the bottom constraint
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: UIView.AnimationOptions(rawValue: UInt(curve.rawValue << 16)),
            animations: {
                self.surfaceBottomConstraint?.constant = -keyboardHeight
                self.multiPaneBottomConstraint?.constant = -keyboardHeight
                self.view.layoutIfNeeded()
            },
            completion: { _ in
                CATransaction.commit()
            }
        )
        
        logger.debug("⌨️ Keyboard will show, height: \(keyboardHeight)")
    }
    
    private func handleKeyboardWillHide(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double,
              let curveValue = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int else {
            return
        }
        
        let curve = UIView.AnimationCurve(rawValue: curveValue) ?? .easeInOut
        
        // Calculate the new size BEFORE animating (full height)
        let newSize = CGSize(width: view.bounds.width, height: view.bounds.height)
        
        // Notify Ghostty of size change BEFORE animation to pre-render
        if let surface = self.surfaceView, !isMultiPaneMode {
            surface.sizeDidChange(newSize)
        }
        
        // Disable implicit CALayer animations during resize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        // Animate the bottom constraint back to 0
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: UIView.AnimationOptions(rawValue: UInt(curve.rawValue << 16)),
            animations: {
                self.surfaceBottomConstraint?.constant = 0
                self.multiPaneBottomConstraint?.constant = 0
                self.view.layoutIfNeeded()
            },
            completion: { _ in
                CATransaction.commit()
            }
        )
        
        logger.debug("⌨️ Keyboard will hide")
    }
    
    private func setupMenuBarNotifications() {
        // Terminal actions
        NotificationCenter.default.addObserver(forName: .terminalClearScreen, object: nil, queue: .main) { [weak self] _ in
            self?.handleClearScreen()
        }
        NotificationCenter.default.addObserver(forName: .terminalReset, object: nil, queue: .main) { [weak self] _ in
            self?.handleResetTerminal()
        }
        NotificationCenter.default.addObserver(forName: .terminalIncreaseFontSize, object: nil, queue: .main) { [weak self] _ in
            self?.handleIncreaseFontSize()
        }
        NotificationCenter.default.addObserver(forName: .terminalDecreaseFontSize, object: nil, queue: .main) { [weak self] _ in
            self?.handleDecreaseFontSize()
        }
        NotificationCenter.default.addObserver(forName: .terminalResetFontSize, object: nil, queue: .main) { [weak self] _ in
            self?.handleResetFontSize()
        }
        NotificationCenter.default.addObserver(forName: .terminalSelectAll, object: nil, queue: .main) { [weak self] _ in
            self?.handleSelectAll()
        }
        NotificationCenter.default.addObserver(forName: .terminalToggleStatusBar, object: nil, queue: .main) { [weak self] _ in
            self?.toggleStatusBar()
        }
        NotificationCenter.default.addObserver(forName: .terminalToggleSecureKeyboard, object: nil, queue: .main) { [weak self] _ in
            self?.toggleSecureKeyboardEntry()
        }
        NotificationCenter.default.addObserver(forName: .showKeyboardShortcuts, object: nil, queue: .main) { [weak self] _ in
            self?.showKeyboardShortcutsHelp()
        }
        NotificationCenter.default.addObserver(forName: .showSettings, object: nil, queue: .main) { [weak self] _ in
            self?.handleSettingsButton()
        }
        NotificationCenter.default.addObserver(forName: .reloadConfiguration, object: nil, queue: .main) { [weak self] _ in
            self?.reloadConfiguration()
        }
        
        // Copy/Paste
        NotificationCenter.default.addObserver(forName: .terminalCopy, object: nil, queue: .main) { [weak self] _ in
            self?.viewModel?.copy()
        }
        NotificationCenter.default.addObserver(forName: .terminalPaste, object: nil, queue: .main) { [weak self] _ in
            self?.viewModel?.paste()
        }
        
        // Search/Find
        NotificationCenter.default.addObserver(forName: .terminalFind, object: nil, queue: .main) { [weak self] _ in
            self?.handleFind()
        }
        NotificationCenter.default.addObserver(forName: .terminalFindNext, object: nil, queue: .main) { [weak self] _ in
            self?.handleFindNext()
        }
        NotificationCenter.default.addObserver(forName: .terminalFindPrevious, object: nil, queue: .main) { [weak self] _ in
            self?.handleFindPrevious()
        }
        NotificationCenter.default.addObserver(forName: .terminalHideFindBar, object: nil, queue: .main) { [weak self] _ in
            self?.closeSearch()
        }
        
        // Connection management
        NotificationCenter.default.addObserver(forName: .terminalDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.handleBackButton()
        }
        // Note: terminalReconnect is handled in ContentView which has access to appState
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        // Setup connection after view appears
        onSetup?()
        
        // Initial layout update
        updateStatusBarAndLayout()
    }
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
        if showStatusBar {
            // When status bar is visible, offset by safe area top
            surfaceTopConstraint?.constant = view.safeAreaInsets.top
        } else {
            // When status bar is hidden, terminal takes full screen
            surfaceTopConstraint?.constant = 0
        }
    }
    
    // MARK: - Menu Action Handlers
    
    private func handleSelectAll() {
        // Select all text in terminal
        // TODO: Implement via Ghostty API if available
        viewModel?.surfaceView?.selectAll()
    }
    
    // MARK: - Search/Find Handlers
    
    private func handleFind() {
        guard let surface = surfaceView else { return }
        
        // Send start_search action to Ghostty, which will trigger the START_SEARCH callback
        // This matches the macOS implementation and ensures proper state management
        surface.startSearch()
    }
    
    private func handleFindNext() {
        guard let surface = surfaceView else { return }
        
        if surface.searchState != nil {
            // Search active, go to next result
            surface.searchNext()
        } else {
            // No search active, start one first
            handleFind()
        }
    }
    
    private func handleFindPrevious() {
        guard let surface = surfaceView else { return }
        
        if surface.searchState != nil {
            // Search active, go to previous result
            surface.searchPrevious()
        } else {
            // No search active, start one first
            handleFind()
        }
    }
    
    private func closeSearch() {
        guard let surface = surfaceView else { return }
        
        // Directly set searchState to nil - the didSet will send end_search to Ghostty
        // This matches the macOS implementation
        surface.searchState = nil
        
        // Return focus to terminal
        surface.becomeFirstResponder()
    }
    
    // MARK: - Search Overlay Management
    
    /// Current corner position of search bar
    private var searchBarCorner: SearchBarCorner = .topRight
    
    /// Constraints for search bar positioning (updated during drag)
    private var searchBarTopConstraint: NSLayoutConstraint?
    private var searchBarBottomConstraint: NSLayoutConstraint?
    private var searchBarLeadingConstraint: NSLayoutConstraint?
    private var searchBarTrailingConstraint: NSLayoutConstraint?
    
    enum SearchBarCorner {
        case topLeft, topRight, bottomLeft, bottomRight
    }
    
    private func updateSearchOverlay() {
        guard let surface = surfaceView else {
            removeSearchOverlay()
            return
        }
        
        if let searchState = surface.searchState {
            // Show/update search overlay
            if searchOverlayHostingController == nil {
                // Create tmux callbacks if this is a tmux session
                let tmuxCaptureCallback: ((@escaping (Result<String, Error>) -> Void) -> Void)?
                let tmuxGotoLineCallback: ((Int) -> Void)?
                
                if let vm = viewModel, vm.isTmuxSession {
                    tmuxCaptureCallback = { [weak vm] completion in
                        vm?.captureTmuxPane(completion: completion)
                    }
                    tmuxGotoLineCallback = { [weak vm] lineNumber in
                        vm?.tmuxGotoLine(lineNumber)
                    }
                } else {
                    tmuxCaptureCallback = nil
                    tmuxGotoLineCallback = nil
                }
                
                // Create and add the overlay
                let overlay = Ghostty.SurfaceSearchOverlay(
                    surfaceView: surface,
                    searchState: searchState,
                    onClose: { [weak self] in
                        self?.closeSearch()
                    },
                    onCaptureTmux: tmuxCaptureCallback,
                    onTmuxGotoLine: tmuxGotoLineCallback
                )
                
                let hostingController = UIHostingController(rootView: overlay)
                hostingController.view.backgroundColor = .clear
                
                // KEY FIX: Use Auto Layout to size the hosting view to fit its content
                // instead of stretching it full-screen. This is the iOS-native way to 
                // have an overlay that doesn't block touches on the rest of the screen.
                hostingController.view.translatesAutoresizingMaskIntoConstraints = false
                
                // Tell the hosting controller to size itself to fit content
                hostingController.sizingOptions = .intrinsicContentSize
                
                addChild(hostingController)
                view.addSubview(hostingController.view)
                
                // Create constraints for all four corners (we'll activate/deactivate as needed)
                let padding: CGFloat = 12
                searchBarTopConstraint = hostingController.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: padding)
                searchBarBottomConstraint = hostingController.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -padding)
                searchBarLeadingConstraint = hostingController.view.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: padding)
                searchBarTrailingConstraint = hostingController.view.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -padding)
                
                // Activate constraints for current corner
                updateSearchBarConstraints()
                
                // Add pan gesture for dragging
                let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handleSearchBarPan(_:)))
                hostingController.view.addGestureRecognizer(panGesture)
                
                hostingController.didMove(toParent: self)
                searchOverlayHostingController = hostingController
            }
        } else {
            removeSearchOverlay()
        }
    }
    
    private func updateSearchBarConstraints() {
        // Deactivate all
        searchBarTopConstraint?.isActive = false
        searchBarBottomConstraint?.isActive = false
        searchBarLeadingConstraint?.isActive = false
        searchBarTrailingConstraint?.isActive = false
        
        // Activate based on corner
        switch searchBarCorner {
        case .topLeft:
            searchBarTopConstraint?.isActive = true
            searchBarLeadingConstraint?.isActive = true
        case .topRight:
            searchBarTopConstraint?.isActive = true
            searchBarTrailingConstraint?.isActive = true
        case .bottomLeft:
            searchBarBottomConstraint?.isActive = true
            searchBarLeadingConstraint?.isActive = true
        case .bottomRight:
            searchBarBottomConstraint?.isActive = true
            searchBarTrailingConstraint?.isActive = true
        }
    }
    
    @objc private func handleSearchBarPan(_ gesture: UIPanGestureRecognizer) {
        guard let searchView = searchOverlayHostingController?.view else { return }
        
        switch gesture.state {
        case .changed:
            // Move the view with the finger
            let translation = gesture.translation(in: view)
            searchView.transform = CGAffineTransform(translationX: translation.x, y: translation.y)
            
        case .ended, .cancelled:
            // Get the translation and velocity
            let translation = gesture.translation(in: view)
            let velocity = gesture.velocity(in: view)
            
            // Calculate where the view visually ended up (center + translation)
            let visualCenter = CGPoint(
                x: searchView.center.x + translation.x,
                y: searchView.center.y + translation.y
            )
            
            let viewBounds = view.bounds
            let midX = viewBounds.width / 2
            let midY = viewBounds.height / 2
            
            // Flick threshold - if velocity is high enough, use velocity direction
            let flickThreshold: CGFloat = 500
            let isFlick = abs(velocity.x) > flickThreshold || abs(velocity.y) > flickThreshold
            
            let newCorner: SearchBarCorner
            if isFlick {
                // Use velocity direction to determine target corner
                let goingLeft = velocity.x < 0
                let goingUp = velocity.y < 0
                
                if goingLeft {
                    newCorner = goingUp ? .topLeft : .bottomLeft
                } else {
                    newCorner = goingUp ? .topRight : .bottomRight
                }
            } else {
                // Use final position to snap to nearest corner
                if visualCenter.x < midX {
                    newCorner = visualCenter.y < midY ? .topLeft : .bottomLeft
                } else {
                    newCorner = visualCenter.y < midY ? .topRight : .bottomRight
                }
            }
            
            // Reset transform and update corner
            searchBarCorner = newCorner
            UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseOut) {
                searchView.transform = .identity
                self.updateSearchBarConstraints()
                self.view.layoutIfNeeded()
            }
            
        default:
            break
        }
    }
    
    /// Container view for search overlay (unused now - hosting view is positioned directly)
    private var searchOverlayContainer: UIView?
    
    private func removeSearchOverlay() {
        if let hostingController = searchOverlayHostingController {
            hostingController.willMove(toParent: nil)
            hostingController.view.removeFromSuperview()
            hostingController.removeFromParent()
            searchOverlayHostingController = nil
        }
    }

    private func setupSearchStateObserver() {
        // Observe search state changes on the surface view
        guard let surface = surfaceView else { return }
        
        searchStateObserver = surface.$searchState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateSearchOverlay()
            }
    }
    
    private func handleIncreaseFontSize() {
        let currentSize = viewModel?.currentFontSize ?? 14
        viewModel?.setFontSize(Int(currentSize) + 1)
    }
    
    private func handleDecreaseFontSize() {
        let currentSize = viewModel?.currentFontSize ?? 14
        viewModel?.setFontSize(max(8, Int(currentSize) - 1))
    }
    
    private func handleResetFontSize() {
        viewModel?.resetFontSize()
    }
    
    private func toggleStatusBar() {
        let newValue = !showStatusBar
        UserDefaults.standard.set(newValue, forKey: "ui.showStatusBar")
        updateStatusBarAndLayout()
    }
    
    private func handleClearScreen() {
        // Send clear screen escape sequence (Ctrl+L equivalent)
        viewModel?.send(text: "\u{0C}")  // Form feed / Ctrl+L
    }
    
    private func handleResetTerminal() {
        // Send reset terminal escape sequence
        viewModel?.send(text: "\u{1B}c")  // ESC c - Full reset
    }
    
    private func toggleSecureKeyboardEntry() {
        secureKeyboardEntry.toggle()
        // TODO: Actually implement secure keyboard entry
        // This would prevent other apps from seeing keystrokes
    }
    
    private func showKeyboardShortcutsHelp() {
        let shortcuts = """
        Keyboard Shortcuts
        
        Cmd+C        Copy
        Cmd+V        Paste
        Cmd+K        Clear Screen
        Cmd+0        Reset Font Size
        Cmd++        Increase Font Size
        Cmd+-        Decrease Font Size
        Cmd+W        Disconnect
        
        Ctrl+C       Interrupt (SIGINT)
        Ctrl+D       EOF / Logout
        Ctrl+L       Clear Screen
        Ctrl+Z       Suspend
        
        Arrow Keys   Navigate
        Tab          Complete
        Esc          Cancel
        """
        
        let alert = UIAlertController(title: nil, message: shortcuts, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
    
    @objc private func handleBackButton() {
        // Disconnect and go back
        viewModel?.disconnect()
        NotificationCenter.default.post(name: .terminalDisconnect, object: nil)
    }
    
    @objc private func handleSettingsButton() {
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
    
    private func reloadConfiguration() {
        logger.info("🔄 Reloading configuration...")
        viewModel?.updateConfig()
        
        // Update background color in case theme changed
        let themeBg = ThemeManager.shared.selectedTheme.background
        view.backgroundColor = UIColor(themeBg)
        
        logger.info("✅ Configuration reloaded")
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        // Update top constraint based on status bar visibility
        updateTopConstraint()
    }
    
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
    
    /// Configure surface management for TmuxSessionManager
    /// This provides the factory and handlers for creating surfaces
    private func configureSurfaceManagement() {
        guard let ghosttyApp = ghosttyApp,
              let app = ghosttyApp.app,
              let tmuxManager = viewModel?.tmuxManager else {
            return
        }
        
        // Factory creates Ghostty surfaces
        let factory: (String) -> Ghostty.SurfaceView = { [weak ghosttyApp] paneId in
            guard let ghosttyApp = ghosttyApp, let app = ghosttyApp.app else {
                fatalError("Ghostty app deallocated before surface factory called")
            }
            
            logger.info("Creating Ghostty surface for pane \(paneId)")
            
            var config = Ghostty.SurfaceConfiguration()
            config.backendType = .external
            
            let surface = Ghostty.SurfaceView(app, baseConfig: config)
            let themeBg = ThemeManager.shared.selectedTheme.background
            surface.backgroundColor = UIColor(themeBg)
            
            return surface
        }
        
        // Input handler wires surface.onWrite to tmux
        let inputHandler: (Ghostty.SurfaceView, String) -> Void = { [weak self] surface, paneId in
            surface.onWrite = { [weak self] data in
                Task { @MainActor in
                    self?.viewModel?.tmuxManager?.setFocusedPane(paneId)
                    self?.viewModel?.tmuxManager?.sendInput(data, to: paneId)
                }
            }
        }
        
        // Resize handler
        let resizeHandler: (Int, Int) -> Void = { [weak self] cols, rows in
            Task { @MainActor in
                self?.viewModel?.resize(cols: cols, rows: rows)
            }
        }
        
        tmuxManager.configureSurfaceManagement(
            factory: factory,
            inputHandler: inputHandler,
            resizeHandler: resizeHandler
        )
        
        logger.info("✅ Surface management configured for TmuxSessionManager")
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
        
        // Wire up callbacks directly to SSH (non-tmux mode)
        surface.onWrite = { [weak self] data in
            Task { @MainActor in
                self?.viewModel?.sendInput(data)
            }
        }
        
        surface.onResize = { [weak self] cols, rows in
            Task { @MainActor in
                self?.viewModel?.resize(cols: cols, rows: rows)
            }
        }
        
        displaySurface(surface)
        logger.info("✅ Created direct surface (non-tmux mode)")
    }
    
    /// Display a surface in the view hierarchy
    private func displaySurface(_ surface: Ghostty.SurfaceView) {
        self.surfaceView = surface
        
        surface.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(surface)
        
        surfaceTopConstraint = surface.topAnchor.constraint(equalTo: view.topAnchor, constant: 0)
        surfaceBottomConstraint = surface.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: 0)
        
        NSLayoutConstraint.activate([
            surfaceTopConstraint!,
            surfaceBottomConstraint!,
            surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        
        viewModel?.surfaceView = surface
        
        setupSearchStateObserver()
        
        surface.focusDidChange(true)
        surface.becomeFirstResponder()
    }
    
    /// Set up surface factory for tmux multi-pane support
    /// This ensures TmuxSessionManager has what it needs to create surfaces
    private func setupTmuxSurfaceFactory() {
        // Configure surface management if not already done
        configureSurfaceManagement()
        
        // Create primary surface if it doesn't exist yet
        if surfaceView == nil, let tmuxManager = viewModel?.tmuxManager {
            if let surface = tmuxManager.createPrimarySurface() {
                displaySurface(surface)
                logger.info("✅ Created and displayed primary surface from TmuxSessionManager")
            }
        }
        
        logger.info("✅ tmux surface factory configured")
    }
    
    /// Observe split tree changes to switch between single surface and multi-pane mode
    private func setupSplitTreeObserver() {
        guard let tmuxManager = viewModel?.tmuxManager else {
            logger.debug("No tmux manager available for split tree observation")
            return
        }
        
        // Cancel any existing observer
        splitTreeObserver?.cancel()
        
        splitTreeObserver = tmuxManager.$currentSplitTree
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tree in
                self?.handleSplitTreeChange(tree)
            }
        
        logger.info("✅ Split tree observer configured")
    }
    
    /// Observe connection state to set up tmux observers when connected
    /// This is needed because tmux manager doesn't exist until after SSH connects
    private func setupConnectionObserver() {
        guard let viewModel = viewModel else { return }
        
        connectionObserver = viewModel.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isConnected in
                if isConnected {
                    // Connection established - try to set up tmux support
                    // Delay slightly to ensure tmux manager is fully initialized
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self?.setupTmuxSurfaceFactory()
                        self?.setupSplitTreeObserver()
                    }
                }
            }
    }
    
    /// Handle split tree changes - switch between single and multi-pane mode
    private func handleSplitTreeChange(_ tree: TmuxSplitTree) {
        let hasSplits = tree.isSplit
        
        logger.info("🔄 handleSplitTreeChange: panes=\(tree.paneIds), isSplit=\(hasSplits), isMultiPaneMode=\(isMultiPaneMode)")
        
        if hasSplits && !isMultiPaneMode {
            // Transition to multi-pane mode
            logger.info("🔄 Transitioning to multi-pane mode")
            transitionToMultiPaneMode()
        } else if !hasSplits && isMultiPaneMode {
            // Transition back to single surface mode
            logger.info("🔄 Transitioning to single surface mode")
            transitionToSingleSurfaceMode()
        }
    }
    
    /// Transition from single surface mode to multi-pane mode
    private func transitionToMultiPaneMode() {
        guard let tmuxManager = viewModel?.tmuxManager else { return }
        
        // Hide the single surface view
        surfaceView?.isHidden = true
        
        // Create and add the multi-pane hosting controller
        let multiPaneView = TmuxMultiPaneView(sessionManager: tmuxManager)
        let hostingController = UIHostingController(rootView: multiPaneView)
        multiPaneHostingController = hostingController
        
        // Add as child view controller
        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingController.view)
        
        // Create constraints that match the surface view constraints
        let topConstraint = hostingController.view.topAnchor.constraint(equalTo: view.topAnchor, constant: surfaceTopConstraint?.constant ?? 0)
        let bottomConstraint = hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: surfaceBottomConstraint?.constant ?? 0)
        
        multiPaneTopConstraint = topConstraint
        multiPaneBottomConstraint = bottomConstraint
        
        NSLayoutConstraint.activate([
            topConstraint,
            bottomConstraint,
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        
        hostingController.didMove(toParent: self)
        
        // Set transparent background to show through to our view background
        hostingController.view.backgroundColor = .clear
        
        isMultiPaneMode = true
    }
    
    /// Transition from multi-pane mode back to single surface mode
    private func transitionToSingleSurfaceMode() {
        guard isMultiPaneMode else { return }
        
        logger.info("🔄 Transitioning to single surface mode")
        
        // Get the primary surface from TmuxSessionManager
        // TmuxSessionManager owns all surfaces, so it's guaranteed to exist
        guard let tmuxManager = viewModel?.tmuxManager,
              let primarySurface = tmuxManager.primarySurface else {
            logger.warning("🔄 ⚠️ No primary surface available from TmuxSessionManager!")
            isMultiPaneMode = false
            return
        }
        
        // Remove the primary surface from multi-pane view hierarchy BEFORE
        // destroying the hosting controller
        primarySurface.removeFromSuperview()
        
        // Now safe to remove the multi-pane hosting controller
        if let hostingController = multiPaneHostingController {
            hostingController.willMove(toParent: nil)
            hostingController.view.removeFromSuperview()
            hostingController.removeFromParent()
            multiPaneHostingController = nil
            multiPaneTopConstraint = nil
            multiPaneBottomConstraint = nil
        }
        
        // Re-add primary surface to our view hierarchy
        primarySurface.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(primarySurface)
        
        surfaceTopConstraint = primarySurface.topAnchor.constraint(equalTo: view.topAnchor)
        surfaceBottomConstraint = primarySurface.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        
        NSLayoutConstraint.activate([
            surfaceTopConstraint!,
            surfaceBottomConstraint!,
            primarySurface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            primarySurface.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        
        // Update our reference and viewModel
        self.surfaceView = primarySurface
        viewModel?.surfaceView = primarySurface
        
        // Restore focus
        primarySurface.isHidden = false
        primarySurface.focusDidChange(true)
        let becameFirstResponder = primarySurface.becomeFirstResponder()
        
        isMultiPaneMode = false
        logger.info("🔄 ✅ Transitioned to single surface mode (becameFirstResponder=\(becameFirstResponder))")
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
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
        
        // Cancel search observer and remove overlay
        searchStateObserver?.cancel()
        searchStateObserver = nil
        removeSearchOverlay()
        
        // Cancel split tree and connection observers, cleanup multi-pane view
        splitTreeObserver?.cancel()
        splitTreeObserver = nil
        connectionObserver?.cancel()
        connectionObserver = nil
        transitionToSingleSurfaceMode()
        
        viewModel?.disconnect()
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
        searchStateObserver?.cancel()
        splitTreeObserver?.cancel()
        connectionObserver?.cancel()
    }
}

#Preview {
    NavigationStack {
        TerminalContainerView()
            .environmentObject(AppState())
            .environmentObject(Ghostty.App())
    }
}

// MARK: - Pass-Through View

/// A UIView that passes through touches to views beneath it,
/// but still allows interaction with its subviews.
class PassThroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hitView = super.hitTest(point, with: event)
        // If the hit view is self (not a subview), pass through
        if hitView === self {
            return nil
        }
        return hitView
    }
}
