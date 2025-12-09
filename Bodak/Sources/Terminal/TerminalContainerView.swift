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

/// UIViewRepresentable wrapper for Ghostty.SurfaceView with SSH integration
struct BodakTerminalView: UIViewRepresentable {
    @EnvironmentObject var ghosttyApp: Ghostty.App
    @ObservedObject var viewModel: TerminalViewModel
    
    func makeUIView(context: Context) -> UIView {
        // Get theme background color
        let themeBgColor = UIColor(ThemeManager.shared.selectedTheme.background)
        
        // Check if Ghostty is ready
        guard ghosttyApp.readiness == .ready, let app = ghosttyApp.app else {
            logger.warning("⚠️ Ghostty not ready, showing placeholder")
            let placeholder = UIView()
            placeholder.backgroundColor = themeBgColor
            return placeholder
        }
        
        // Create surface configuration with external backend for SSH
        // The external backend doesn't spawn a subprocess - instead:
        // - SSH data → ghostty_surface_write_output() → terminal display
        // - User input → write callback → SSH connection
        var config = Ghostty.SurfaceConfiguration()
        config.backendType = .external  // Use external backend for SSH
        
        // Create Ghostty surface with the config
        let surfaceView = Ghostty.SurfaceView(app, baseConfig: config)
        
        // Background color is set in SurfaceView.init() from theme
        // No need to override here
        
        // Wire up the write callback - when terminal wants to send data, send to SSH
        surfaceView.onWrite = { [weak viewModel] data in
            Task { @MainActor in
                logger.debug("⌨️ Terminal sending \(data.count) bytes to SSH")
                viewModel?.sendInput(data)
            }
        }
        
        // Wire up the resize callback - when terminal grid size changes, resize SSH PTY
        surfaceView.onResize = { [weak viewModel] cols, rows in
            Task { @MainActor in
                logger.info("📐 Terminal grid resized to \(cols)x\(rows)")
                viewModel?.resize(cols: cols, rows: rows)
            }
        }
        
        // Store reference in view model IMMEDIATELY (not async)
        // This is crucial - we need surfaceView to be available before SSH data arrives
        viewModel.surfaceView = surfaceView
        logger.info("✅ Ghostty surface view created with external backend and assigned to viewModel")
        
        // Set initial focus
        surfaceView.focusDidChange(true)
        
        return surfaceView
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        guard let surfaceView = uiView as? Ghostty.SurfaceView else { return }
        
        // Update size if needed
        surfaceView.sizeDidChange(uiView.bounds.size)
    }
    
    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        // Properly close the Ghostty surface when the view is being destroyed
        if let surfaceView = uiView as? Ghostty.SurfaceView {
            logger.info("🔒 dismantleUIView - closing Ghostty surface")
            surfaceView.close()
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
    
    // Secure keyboard entry state
    private var secureKeyboardEntry = false
    
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
        if let surface = self.surfaceView {
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
        if let surface = self.surfaceView {
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
    
    private func createSurfaceView() {
        guard let ghosttyApp = ghosttyApp,
              ghosttyApp.readiness == .ready,
              let app = ghosttyApp.app else {
            logger.warning("⚠️ Ghostty not ready in RawTerminalUIViewController")
            return
        }
        
        // Create surface configuration with external backend
        var config = Ghostty.SurfaceConfiguration()
        config.backendType = .external
        
        // Create Ghostty surface
        let surface = Ghostty.SurfaceView(app, baseConfig: config)
        self.surfaceView = surface
        
        // Set background color to match theme
        let themeBg = ThemeManager.shared.selectedTheme.background
        surface.backgroundColor = UIColor(themeBg)
        
        // Add to view hierarchy
        surface.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(surface)
        
        // Create constraints - top constraint is variable based on status bar
        // Bottom constraint is variable based on keyboard
        surfaceTopConstraint = surface.topAnchor.constraint(equalTo: view.topAnchor, constant: 0)
        surfaceBottomConstraint = surface.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: 0)
        
        NSLayoutConstraint.activate([
            surfaceTopConstraint!,
            surfaceBottomConstraint!,
            surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        
        // Wire up callbacks
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
        
        // Store in view model
        viewModel?.surfaceView = surface
        
        // Set focus
        surface.focusDidChange(true)
        surface.becomeFirstResponder()
        
        logger.info("✅ RawTerminalUIViewController created surface view")
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
    }
}

#Preview {
    NavigationStack {
        TerminalContainerView()
            .environmentObject(AppState())
            .environmentObject(Ghostty.App())
    }
}
