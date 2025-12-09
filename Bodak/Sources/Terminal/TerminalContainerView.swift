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

/// Container view that wraps the Ghostty terminal surface with auto-hiding chrome
struct TerminalContainerView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var ghosttyApp: Ghostty.App
    @ObservedObject private var settings = AppSettings.shared
    @State private var terminalTitle: String = "Terminal"
    @StateObject private var terminalViewModel = TerminalViewModel()
    @State private var keyboardHeight: CGFloat = 0
    
    // Auto-hide UI state
    @State private var showChrome: Bool = true
    @State private var hideTimer: Timer?
    @State private var isSelectingText: Bool = false
    @State private var showSettings: Bool = false
    
    // Link preview state
    @State private var hoverUrl: String? = nil
    @State private var hoverUrlCancellable: AnyCancellable? = nil
    
    // Constants for auto-hide behavior
    private let edgeTapThreshold: CGFloat = 60 // Pixels from edge to reveal chrome
    
    // Use pure UIKit terminal view (no SwiftUI UIViewRepresentable) to prevent flash
    // The flash was caused by SwiftUI's view update mechanism with UIViewRepresentable
    private let usePureUIKit = true
    
    /// Theme background color to prevent flash
    private var themeBackground: Color {
        Color(ThemeManager.shared.selectedTheme.background)
    }
    
    var body: some View {
        if usePureUIKit {
            // Pure UIKit UIViewController - NO FLASH!
            // This bypasses SwiftUI's view update mechanism which was causing the gray flash
            RawTerminalViewController(
                ghosttyApp: ghosttyApp,
                viewModel: terminalViewModel,
                onSetup: { setupConnection() }
            )
            .ignoresSafeArea(.all)
        } else {
            fullBody
        }
    }
    
    @ViewBuilder
    var fullBody: some View {
        GeometryReader { geometry in
            ZStack {
                // Black background behind everything
                Color.black
                    .ignoresSafeArea(.all)
                
                // Main terminal surface (full screen)
                // When status bar is hidden, use full screen
                // When status bar is shown, add top padding to avoid overlap
                BodakTerminalView(viewModel: terminalViewModel)
                    .environmentObject(ghosttyApp)
                    .ignoresSafeArea(.all)
                    .padding(.top, settings.showStatusBar ? geometry.safeAreaInsets.top : 0)
                
                // Overlay for detecting taps on edges to reveal chrome
                VStack {
                    // Top edge tap area (reveals navigation)
                    Color.clear
                        .frame(height: edgeTapThreshold)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            revealChrome()
                        }
                    
                    Spacer()
                    
                    // Bottom edge tap area (reveals toolbar)
                    Color.clear
                        .frame(height: edgeTapThreshold)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            revealChrome()
                        }
                }
                .allowsHitTesting(!showChrome && !isSelectingText)
                
                // Top chrome (navigation bar overlay)
                VStack {
                    if showChrome {
                        HStack {
                            Button(action: disconnect) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 17, weight: .semibold))
                            }
                            
                            Spacer()
                            
                            // Title and duration (only if enabled in settings)
                            if settings.showConnectionInfo {
                                VStack(spacing: 2) {
                                    Text(terminalTitle)
                                        .font(.headline)
                                        .lineLimit(1)
                                    
                                    // Connection duration badge
                                    if terminalViewModel.connectionDuration > 0 {
                                        Text(terminalViewModel.formattedDuration)
                                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            
                            Spacer()
                            
                            Menu {
                                Button(action: { terminalViewModel.paste() }) {
                                    Label("Paste", systemImage: "doc.on.clipboard")
                                }
                                Button(action: { terminalViewModel.copy() }) {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }
                                Divider()
                                Button(action: { showSettings = true }) {
                                    Label("Settings", systemImage: "gear")
                                }
                                Divider()
                                Button(role: .destructive, action: disconnect) {
                                    Label("Disconnect", systemImage: "xmark.circle")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.system(size: 20))
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, geometry.safeAreaInsets.top + 8)
                        .padding(.bottom, 12)
                        .background(
                            LinearGradient(
                                colors: [ThemeManager.shared.selectedTheme.background.opacity(0.95), ThemeManager.shared.selectedTheme.background.opacity(0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    
                    Spacer()
                }
                
                // Link preview tooltip (shows URL when hovering over a link)
                if let url = hoverUrl {
                    VStack {
                        Spacer()
                        
                        HStack(spacing: 6) {
                            Image(systemName: "link")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.blue)
                            
                            Text(url)
                                .font(.system(size: 13, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.black.opacity(0.85))
                                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                        )
                        .padding(.bottom, showChrome ? 80 + max(geometry.safeAreaInsets.bottom, keyboardHeight) : 20)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    .animation(.easeInOut(duration: 0.15), value: hoverUrl)
                }
            }
            // TEMPORARILY DISABLED: Testing if animations cause white flash
            // .animation(.easeInOut(duration: 0.3), value: showChrome)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .statusBarHidden(!settings.showStatusBar)
        .persistentSystemOverlays(.hidden) // Hides home indicator
        .navigationBarHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            if let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                keyboardHeight = keyboardFrame.height
                revealChrome() // Show chrome when keyboard appears
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardHeight = 0
        }
        // Keyboard shortcut handlers
        .onReceive(NotificationCenter.default.publisher(for: .terminalClearScreen)) { _ in
            terminalViewModel.clearScreen()
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalReset)) { _ in
            terminalViewModel.resetTerminal()
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalIncreaseFontSize)) { _ in
            terminalViewModel.increaseFontSize()
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalDecreaseFontSize)) { _ in
            terminalViewModel.decreaseFontSize()
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalResetFontSize)) { _ in
            terminalViewModel.resetFontSize()
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalDisconnect)) { _ in
            disconnect()
        }
        .onAppear {
            setupConnection()
            startAutoHideTimer()
            
            // Subscribe to hoverUrl changes from surface view
            // We need a small delay since surfaceView is created in BodakTerminalView's makeUIView
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                subscribeToHoverUrl()
            }
        }
        .onDisappear {
            hideTimer?.invalidate()
            hoverUrlCancellable?.cancel()
            hoverUrlCancellable = nil
            terminalViewModel.disconnect()
            terminalViewModel.surfaceView = nil
        }
        .onChange(of: terminalViewModel.title) { _, newTitle in
            if !newTitle.isEmpty {
                terminalTitle = newTitle
            }
        }
        .onChange(of: terminalViewModel.disconnectedByRemote) { _, disconnected in
            if disconnected {
                if let error = terminalViewModel.disconnectError {
                    appState.connectionStatus = .error(error)
                } else {
                    appState.connectionStatus = .disconnected
                }
            }
        }
        .onChange(of: terminalViewModel.isSelectingText) { _, selecting in
            isSelectingText = selecting
            if selecting {
                revealChrome() // Keep chrome visible during selection
            }
        }
        // Tap anywhere on terminal to reset auto-hide timer
        .onTapGesture {
            if showChrome {
                startAutoHideTimer()
            }
        }
        // Shake device to clear the terminal screen
        .onShake {
            terminalViewModel.clearScreen()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                currentFontSize: Int(terminalViewModel.currentFontSize),
                onFontSizeChanged: { newSize in terminalViewModel.setFontSize(newSize) },
                onResetFontSize: { terminalViewModel.resetFontSize() },
                onFontFamilyChanged: { terminalViewModel.updateConfig() },
                onThemeChanged: { terminalViewModel.updateConfig() }
            )
        }
    }
    
    // MARK: - Auto-hide Logic
    
    private func revealChrome() {
        withAnimation {
            showChrome = true
        }
        startAutoHideTimer()
    }
    
    private func hideChrome() {
        // Don't hide if disabled, keyboard is showing, or user is selecting text
        guard settings.autoHideChrome && keyboardHeight == 0 && !isSelectingText else { return }
        
        withAnimation {
            showChrome = false
        }
    }
    
    private func startAutoHideTimer() {
        guard settings.autoHideChrome else { return }
        
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: settings.autoHideDelay, repeats: false) { _ in
            Task { @MainActor in
                hideChrome()
            }
        }
    }
    
    // MARK: - Link Preview
    
    private func subscribeToHoverUrl() {
        guard let surfaceView = terminalViewModel.surfaceView else {
            // Retry after a short delay if surface view isn't ready yet
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                subscribeToHoverUrl()
            }
            return
        }
        
        // Subscribe to hoverUrl changes
        hoverUrlCancellable = surfaceView.$hoverUrl
            .receive(on: DispatchQueue.main)
            .sink { [self] url in
                withAnimation(.easeInOut(duration: 0.15)) {
                    self.hoverUrl = url
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
    
    // Settings observation
    private var settingsObserver: NSObjectProtocol?
    
    // Chrome overlay
    private var chromeView: UIView?
    private var chromeVisible = false
    private var chromeHideTimer: Timer?
    private let chromeAutoHideDelay: TimeInterval = 3.0
    
    // Status bar preference (read from UserDefaults)
    private var showStatusBar: Bool {
        UserDefaults.standard.bool(forKey: "ui.showStatusBar")
    }
    
    private var autoHideChrome: Bool {
        UserDefaults.standard.bool(forKey: "ui.autoHideChrome")
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
        
        // Create chrome overlay (after surface so it's on top)
        createChromeOverlay()
        
        // Observe settings changes
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateStatusBarAndLayout()
        }
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
    
    // MARK: - Chrome Overlay
    
    private func createChromeOverlay() {
        let chrome = UIView()
        chrome.backgroundColor = .clear
        chrome.translatesAutoresizingMaskIntoConstraints = false
        chrome.alpha = 0
        chrome.isUserInteractionEnabled = true
        view.addSubview(chrome)
        
        // Chrome covers the top area
        NSLayoutConstraint.activate([
            chrome.topAnchor.constraint(equalTo: view.topAnchor),
            chrome.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chrome.heightAnchor.constraint(equalToConstant: 100)
        ])
        
        // Gradient background
        let gradientLayer = CAGradientLayer()
        gradientLayer.colors = [
            UIColor.black.withAlphaComponent(0.8).cgColor,
            UIColor.black.withAlphaComponent(0.0).cgColor
        ]
        gradientLayer.frame = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 100)
        chrome.layer.insertSublayer(gradientLayer, at: 0)
        
        // Settings menu button (single gear with dropdown menu)
        let menuButton = UIButton(type: .system)
        menuButton.setImage(UIImage(systemName: "ellipsis.circle")?.withConfiguration(
            UIImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        ), for: .normal)
        menuButton.tintColor = .white
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.menu = createOptionsMenu()
        chrome.addSubview(menuButton)
        
        NSLayoutConstraint.activate([
            menuButton.topAnchor.constraint(equalTo: chrome.safeAreaLayoutGuide.topAnchor, constant: 8),
            menuButton.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -16),
            menuButton.widthAnchor.constraint(equalToConstant: 44),
            menuButton.heightAnchor.constraint(equalToConstant: 44)
        ])
        
        self.chromeView = chrome
        
        // Ensure chrome is always on top
        view.bringSubviewToFront(chrome)
    }
    
    private func createOptionsMenu() -> UIMenu {
        let pasteAction = UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
            self?.viewModel?.paste()
        }
        
        let copyAction = UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
            self?.viewModel?.copy()
        }
        
        let settingsAction = UIAction(title: "Settings", image: UIImage(systemName: "gear")) { [weak self] _ in
            self?.handleSettingsButton()
        }
        
        let disconnectAction = UIAction(title: "Disconnect", image: UIImage(systemName: "xmark.circle"), attributes: .destructive) { [weak self] _ in
            self?.handleBackButton()
        }
        
        return UIMenu(children: [pasteAction, copyAction, settingsAction, disconnectAction])
    }
    
    @objc private func handleEdgeTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: view)
        let edgeThreshold: CGFloat = 60
        
        // Only respond to taps near top or bottom edges
        if location.y < edgeThreshold || location.y > view.bounds.height - edgeThreshold {
            toggleChrome()
        } else if chromeVisible {
            // Tap elsewhere while chrome visible - reset timer
            startChromeHideTimer()
        }
    }
    
    private func toggleChrome() {
        if chromeVisible {
            hideChrome()
        } else {
            showChrome()
        }
    }
    
    private func showChrome() {
        chromeVisible = true
        UIView.animate(withDuration: 0.25) {
            self.chromeView?.alpha = 1
        }
        startChromeHideTimer()
    }
    
    private func hideChrome() {
        chromeHideTimer?.invalidate()
        chromeHideTimer = nil
        chromeVisible = false
        UIView.animate(withDuration: 0.25) {
            self.chromeView?.alpha = 0
        }
    }
    
    private func startChromeHideTimer() {
        chromeHideTimer?.invalidate()
        
        // Only auto-hide if setting is enabled
        guard autoHideChrome else { return }
        
        chromeHideTimer = Timer.scheduledTimer(withTimeInterval: chromeAutoHideDelay, repeats: false) { [weak self] _ in
            self?.hideChrome()
        }
    }
    
    @objc private func handleBackButton() {
        // Disconnect and go back
        viewModel?.disconnect()
        
        // Find the AppState and update connection status
        if let windowScene = view.window?.windowScene {
            for window in windowScene.windows {
                if let rootVC = window.rootViewController {
                    findAndDisconnect(in: rootVC)
                }
            }
        }
    }
    
    private func findAndDisconnect(in viewController: UIViewController) {
        // Try to find AppState through the view hierarchy
        // This navigates back by setting connection status to disconnected
        if let hostingController = viewController as? UIHostingController<AnyView> {
            // Post notification to disconnect
            NotificationCenter.default.post(name: .terminalDisconnect, object: nil)
        } else if let navController = viewController as? UINavigationController {
            navController.popViewController(animated: true)
        } else {
            // Fallback: post disconnect notification
            NotificationCenter.default.post(name: .terminalDisconnect, object: nil)
        }
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
        
        // Keep chrome visible while settings open
        chromeHideTimer?.invalidate()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        // Update top constraint based on status bar visibility
        updateTopConstraint()
        
        // Update gradient layer frame
        if let chrome = chromeView,
           let gradientLayer = chrome.layer.sublayers?.first as? CAGradientLayer {
            gradientLayer.frame = chrome.bounds
        }
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
        surfaceTopConstraint = surface.topAnchor.constraint(equalTo: view.topAnchor, constant: 0)
        
        NSLayoutConstraint.activate([
            surfaceTopConstraint!,
            surface.bottomAnchor.constraint(equalTo: view.bottomAnchor),
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
        
        // Add edge tap gesture to the surface view (since it consumes touches)
        let edgeTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleEdgeTap(_:)))
        edgeTapGesture.cancelsTouchesInView = false
        surface.addGestureRecognizer(edgeTapGesture)
        
        // Ensure chrome is on top of surface
        if let chrome = chromeView {
            view.bringSubviewToFront(chrome)
        }
        
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
        
        viewModel?.disconnect()
        viewModel?.surfaceView = nil
    }
    
    deinit {
        if let observer = settingsObserver {
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
