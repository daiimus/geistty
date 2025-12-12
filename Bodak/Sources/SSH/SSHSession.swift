//
//  SSHSession.swift
//  Bodak
//
//  High-level SSH session wrapper for SwiftUI usage
//

import Foundation
import os

private let logger = Logger(subsystem: "com.bodak", category: "SSHSession")

/// Delegate protocol for SSHSession events
protocol SSHSessionDelegate: AnyObject {
    func sshSessionDidConnect(_ session: SSHSession)
    func sshSession(_ session: SSHSession, didReceiveData data: Data)
    func sshSession(_ session: SSHSession, didDisconnectWithError error: Error?)
}

/// tmux integration mode
enum TmuxMode {
    /// No tmux integration
    case none
    
    /// Control mode: tmux -CC with proper scrollback buffering
    case controlMode
}

/// Represents an SSH session - wraps SSHConnection for SwiftUI usage
@MainActor
class SSHSession: ObservableObject, Identifiable {
    let id = UUID()
    
    // Delegate
    weak var delegate: SSHSessionDelegate?
    
    // Connection
    private var connection: SSHConnection?
    
    // Connection parameters (stored after connect)
    private(set) var host: String = ""
    private(set) var port: Int = 22
    private(set) var username: String = ""
    
    // tmux options
    private var useTmux: Bool = false
    private var tmuxSessionName: String?
    private var tmuxMode: TmuxMode = .none
    
    // tmux Control Mode client (for .controlMode)
    private var tmuxControlClient: TmuxControlClient?
    
    /// tmux Session Manager for multi-pane state management
    /// Access this to get session/window/pane info and route output to surfaces
    private(set) var tmuxSessionManager: TmuxSessionManager?
    
    // Whether control mode is actually active (tmux -CC has started)
    private var controlModeActive: Bool = false
    
    // Queue of input data waiting to be sent once control mode activates
    // This prevents input from going to tmux's command prompt before the shell is ready
    private var pendingInputQueue: [Data] = []
    
    // State
    @Published var state: SSHState = .disconnected
    @Published var lastError: Error?
    
    // Terminal dimensions
    private var terminalCols: Int = 80
    private var terminalRows: Int = 24
    
    init() {}
    
    /// The TERM type to use - xterm-256color is universally supported
    /// Note: xterm-ghostty would be ideal but most servers don't have the terminfo
    private static let termType = "xterm-256color"
    
    /// Connect to the SSH server with password authentication
    func connect(host: String, port: Int, username: String, password: String, useTmux: Bool = false, tmuxSessionName: String? = nil) async throws {
        self.host = host
        self.port = port
        self.username = username
        self.useTmux = useTmux
        self.tmuxSessionName = tmuxSessionName
        self.tmuxMode = useTmux ? .controlMode : .none
        
        connection = SSHConnection(host: host, port: port, username: username)
        connection?.delegate = self
        
        #if DEBUG
        connection?.enableTracing = true
        #endif
        
        try await connection?.connect()
        try await connection?.authenticatePassword(password)
        try await connection?.openShell(term: Self.termType, cols: terminalCols, rows: terminalRows)
        
        // Initialize control client if using control mode
        if tmuxMode == .controlMode {
            setupTmuxControlClient()
        }
        
        // Inject shell initialization for best terminal experience
        injectTerminalSetup()
    }
    
    /// Connect to the SSH server with key-based authentication
    func connectWithKey(host: String, port: Int, username: String, privateKeyPath: String, passphrase: String? = nil, useTmux: Bool = false, tmuxSessionName: String? = nil) async throws {
        self.host = host
        self.port = port
        self.username = username
        self.useTmux = useTmux
        self.tmuxSessionName = tmuxSessionName
        self.tmuxMode = useTmux ? .controlMode : .none
        
        connection = SSHConnection(host: host, port: port, username: username)
        connection?.delegate = self
        
        #if DEBUG
        connection?.enableTracing = true
        #endif
        
        try await connection?.connect()
        try await connection?.authenticateKey(privateKeyPath: privateKeyPath, passphrase: passphrase)
        try await connection?.openShell(term: Self.termType, cols: terminalCols, rows: terminalRows)
        
        // Initialize control client if using control mode
        if tmuxMode == .controlMode {
            setupTmuxControlClient()
        }
        
        // Inject shell initialization for best terminal experience
        injectTerminalSetup()
    }
    
    /// Connect using a saved connection profile and credentials
    /// - Note: Control mode is enabled by default for testing
    func connect(profile: ConnectionProfile, credential: SSHCredential) async throws {
        self.host = profile.host
        self.port = profile.port
        self.username = profile.username
        self.useTmux = profile.useTmux
        self.tmuxSessionName = profile.tmuxSessionName
        // Enable control mode by default for testing
        self.tmuxMode = profile.useTmux ? .controlMode : .none
        
        connection = SSHConnection(host: profile.host, port: profile.port, username: profile.username)
        connection?.delegate = self
        
        #if DEBUG
        connection?.enableTracing = true
        #endif
        
        try await connection?.connect()
        
        // Authenticate based on credential type
        switch credential.authType {
        case .password(let password):
            try await connection?.authenticatePassword(password)
            
        case .privateKey(let path, let passphrase):
            try await connection?.authenticateKey(privateKeyPath: path, passphrase: passphrase)
            
        case .privateKeyData(let keyData, let passphrase):
            // Write key data to temp file for libssh2
            let tempPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("ghostty_temp_key_\(UUID().uuidString)")
            try keyData.write(to: tempPath)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempPath.path)
            defer { try? FileManager.default.removeItem(at: tempPath) }
            
            try await connection?.authenticateKey(privateKeyPath: tempPath.path, passphrase: passphrase)
        }
        
        try await connection?.openShell(term: Self.termType, cols: terminalCols, rows: terminalRows)
        
        // Mark profile as recently connected
        ConnectionProfileManager.shared.markConnected(profile)
        
        // Initialize control client if using control mode
        if tmuxMode == .controlMode {
            setupTmuxControlClient()
        }
        
        // Inject shell initialization for best terminal experience
        injectTerminalSetup()
    }
    
    // MARK: - tmux Control Mode Setup
    
    /// Set up the tmux control mode client
    private func setupTmuxControlClient() {
        logger.info("Setting up tmux control mode client")
        tmuxControlClient = TmuxControlClient()
        tmuxControlClient?.delegate = self
        
        // Set up session manager for multi-pane state tracking
        tmuxSessionManager = TmuxSessionManager()
        if let client = tmuxControlClient, let manager = tmuxSessionManager {
            // Connect session manager to control client
            client.sessionManager = manager
            manager.setup(controlClient: client) { [weak self] command in
                self?.connection?.write(command)
            }
        }
    }
    
    /// Inject commands to set up the terminal environment
    /// This handles cases where the SSH server doesn't accept setenv
    /// Note: Some restricted shells (like test servers) don't support these commands,
    /// so we make this optional and non-disruptive
    private func injectTerminalSetup() {
        // In control mode, we skip env var injection and go straight to tmux
        // The tmux attach command is sent immediately - the shell will execute it
        // when it's ready. We don't need delays because:
        // 1. SSH channel is already open with a PTY
        // 2. Commands are queued by the shell
        // 3. We wait for %session-changed to know tmux is ready
        if tmuxMode == .controlMode {
            attachToTmuxNow()
            return
        }
        
        // For legacy mode or no tmux, use the traditional delay-based approach
        // to let the shell initialize and show MOTD first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.injectEnvironmentVariables()
        }
        
        if useTmux {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.attachToTmuxNow()
            }
        }
    }
    
    /// Inject environment variables for optimal TUI app experience
    /// These help apps like Yazi, kew, aichat, browsh detect terminal capabilities
    /// Uses a single-line command that suppresses output and avoids shell history
    private func injectEnvironmentVariables() {
        // Truly silent injection:
        // - Space prefix: avoids bash/zsh history (HISTCONTROL=ignorespace)
        // - eval "...": single command execution
        // - All on one line with semicolons
        // - 2>/dev/null suppresses any errors
        // - Uses POSIX-compatible syntax for maximum shell compatibility
        // NOTE: No 'clear' - it interferes with session restore
        let envSetup = " eval 'export COLORTERM=truecolor TERM_PROGRAM=ghostty TERM_PROGRAM_VERSION=1.0.0; [ -z \"$LANG\" ] && export LANG=en_US.UTF-8' 2>/dev/null\n"
        write(envSetup)
    }
    
    /// Auto-attach to or create a tmux session
    /// Uses "tmux -CC new-session -A -s <name>" which:
    /// - Attaches to session if it exists
    /// - Creates a new session if it doesn't
    /// - Uses control mode (-CC) for proper scrollback access
    private func attachToTmuxNow() {
        guard tmuxMode == .controlMode else { return }
        
        let sessionName = tmuxSessionName ?? "main"
        
        // Use control mode (-CC) for proper scrollback access
        // exec replaces the shell with tmux
        let command = tmuxControlClient?.makeAttachCommand(session: sessionName) ?? "exec tmux -CC new-session -A -s \(sessionName)\n"
        logger.info("Attaching to tmux in control mode: \(sessionName)")
        // Write directly to connection - don't go through self.write() which would queue it!
        connection?.write(command)
    }
    
    // MARK: - tmux Integration
    
    /// Check if this session is using tmux
    var isTmuxSession: Bool {
        return useTmux
    }
    
    /// Check if this session is using tmux control mode
    var isTmuxControlMode: Bool {
        return tmuxMode == .controlMode
    }
    
    /// Capture the current tmux pane's scrollback content
    /// Uses control mode's TmuxControlClient for proper protocol-based capture
    /// - Parameter completion: Called with the captured text or error
    func captureTmuxPane(completion: @escaping (Result<String, Error>) -> Void) {
        logger.debug("captureTmuxPane: Called, tmuxMode=\(String(describing: self.tmuxMode))")
        guard useTmux else {
            logger.warning("captureTmuxPane: Not in tmux session")
            completion(.failure(SSHError.notInTmux))
            return
        }
        
        guard tmuxMode == .controlMode, let client = tmuxControlClient else {
            logger.error("captureTmuxPane: Control mode not active")
            completion(.failure(SSHError.channelError("tmux control mode not active")))
            return
        }
        
        logger.info("captureTmuxPane: Using control mode")
        client.capturePaneContent(via: { [weak self] cmd in
            self?.write(cmd)
        }, completion: completion)
    }
    
    /// Resize the PTY
    func resize(cols: Int, rows: Int) {
        terminalCols = cols
        terminalRows = rows
        connection?.resizePTY(cols: cols, rows: rows)
        
        // Also notify tmux if in control mode
        if controlModeActive, let client = tmuxControlClient {
            client.resize(cols: cols, rows: rows) { [weak self] command in
                self?.connection?.write(command)
            }
        }
    }
    
    /// Write data to the SSH channel
    func write(_ data: Data) {
        if let str = String(data: data, encoding: .utf8) {
            logger.debug("SSHSession.write: \(data.count) bytes: \(str.prefix(20))")
        }
        
        // In control mode, user input must go through send-keys command
        // Raw characters would be interpreted as tmux control commands!
        // Use tmuxControlClient.isActive (not controlModeActive) to ensure tmux
        // has completed its initial %begin/%end handshake and is ready for commands.
        if let client = tmuxControlClient, client.isActive {
            client.sendKeys(data) { [weak self] command in
                self?.connection?.write(command)
            }
            return
        }
        
        // If we're in control mode but tmux isn't ready yet, queue the input
        // This prevents input from being sent before tmux is ready for send-keys
        if tmuxMode == .controlMode {
            // Either control client doesn't exist yet, or it exists but isn't active
            logger.debug("Control mode pending (isActive=\(tmuxControlClient?.isActive ?? false)), queueing \(data.count) bytes of input")
            pendingInputQueue.append(data)
            return
        }
        
        connection?.write(data)
    }
    
    /// Write string to the SSH channel
    func write(_ string: String) {
        logger.debug("SSHSession.write(string): \(string.prefix(20))")
        
        // In control mode, user input must go through send-keys command
        // Use tmuxControlClient.isActive to ensure tmux is ready for commands
        if let client = tmuxControlClient, client.isActive, let data = string.data(using: .utf8) {
            client.sendKeys(data) { [weak self] command in
                self?.connection?.write(command)
            }
            return
        }
        
        // Queue string input too if in control mode but not yet active
        if tmuxMode == .controlMode, let data = string.data(using: .utf8) {
            logger.debug("Control mode pending, queueing string input: \(data.count) bytes")
            pendingInputQueue.append(data)
            return
        }
        
        connection?.write(string)
    }
    
    /// Disconnect the session
    func disconnect() {
        controlModeActive = false
        pendingInputQueue.removeAll()
        tmuxControlClient?.reset()
        tmuxControlClient = nil
        tmuxSessionManager?.cleanup()
        tmuxSessionManager = nil
        connection?.disconnect()
        connection = nil
        state = .disconnected
    }
    
    // MARK: - App Lifecycle (Pause Mode)
    
    /// Called when the app is about to go to background.
    /// In tmux control mode, this resumes paused panes to prevent
    /// the pause timeout from triggering unnecessarily.
    func appWillResignActive() {
        guard controlModeActive, let client = tmuxControlClient else { return }
        logger.info("App resigning active, pause mode is \(client.isPauseEnabled ? "enabled" : "disabled")")
        // Pause mode is already enabled - tmux will auto-pause after the timeout
        // No additional action needed here
    }
    
    /// Called when the app becomes active again.
    /// In tmux control mode, this resumes any paused panes.
    func appDidBecomeActive() {
        guard controlModeActive, let client = tmuxControlClient else { return }
        logger.info("App became active, resuming paused panes")
        
        // Resume all paused panes
        client.resumeAllPausedPanes(via: { [weak self] command in
            self?.connection?.write(command)
        })
    }
    
    // Internal method to handle received data, called from connection delegate
    fileprivate func handleReceivedData(_ data: Data) {
        // If control mode is active, route through the control client
        if controlModeActive, let client = tmuxControlClient {
            // Control client will parse the data and forward pane output via delegate
            client.parse(data)
            return
        }
        
        // Check if this data contains the start of control mode
        // tmux -CC sends control messages starting with %
        if tmuxMode == .controlMode, !controlModeActive {
            if let str = String(data: data, encoding: .utf8) {
                if str.contains("%begin") || str.contains("%output") || str.contains("%session") {
                    logger.info("Control mode detected! Activating control client.")
                    controlModeActive = true
                    tmuxControlClient?.parse(data)
                    return
                }
            }
            // Before control mode activates, forward all data to terminal normally
            // This shows MOTD, prompt, command echo - standard SSH behavior
        }
        
        delegate?.sshSession(self, didReceiveData: data)
    }
}

// MARK: - SSHConnectionDelegate

extension SSHSession: SSHConnectionDelegate {
    nonisolated func connectionDidConnect(_ connection: SSHConnection) {
        Task { @MainActor in
            self.state = .connected
        }
    }
    
    nonisolated func connectionDidAuthenticate(_ connection: SSHConnection) {
        Task { @MainActor in
            self.state = .authenticated
            self.delegate?.sshSessionDidConnect(self)
        }
    }
    
    nonisolated func connectionDidFailAuthentication(_ connection: SSHConnection, error: Error) {
        Task { @MainActor in
            self.lastError = error
            self.state = .disconnected
            self.delegate?.sshSession(self, didDisconnectWithError: error)
        }
    }
    
    nonisolated func connectionDidClose(_ connection: SSHConnection, error: Error?) {
        Task { @MainActor in
            self.lastError = error
            self.state = .disconnected
            self.delegate?.sshSession(self, didDisconnectWithError: error)
        }
    }
    
    nonisolated func connection(_ connection: SSHConnection, didReceiveData data: Data) {
        Task { @MainActor in
            self.handleReceivedData(data)
        }
    }
}

// MARK: - TmuxControlClientDelegate

extension SSHSession: TmuxControlClientDelegate {
    func tmuxClient(_ client: TmuxControlClient, didReceivePaneOutput data: Data, paneId: String) {
        // Route pane output through session manager
        // The session manager handles routing to the appropriate Ghostty surface
        if let manager = tmuxSessionManager {
            manager.routeOutput(data, to: paneId)
        } else {
            // Fallback: if no session manager, forward directly to delegate
            delegate?.sshSession(self, didReceiveData: data)
        }
    }
    
    func tmuxClientDidActivate(_ client: TmuxControlClient) {
        // Control mode is now fully active - the first %begin/%end block has completed
        // This means tmux has finished its initial response and is ready for commands
        logger.info("Control mode fully activated")
        
        // Notify session manager
        tmuxSessionManager?.controlModeActivated()
        
        // Flush any queued input that came in before control mode was ready
        if !pendingInputQueue.isEmpty {
            logger.info("Flushing \(self.pendingInputQueue.count) queued input chunks")
            for data in pendingInputQueue {
                client.sendKeys(data) { [weak self] command in
                    self?.connection?.write(command)
                }
            }
            pendingInputQueue.removeAll()
        }
        
        // Note: Session history restoration is now handled per-pane in TmuxSessionManager
        // when surfaces are created. This ensures all panes get their history, not just %0.
        
        // Enable pause mode for iOS app lifecycle handling (tmux 3.2+)
        // This buffers output when the app is backgrounded
        client.enablePauseMode(pauseAfter: 1) { [weak self] command in
            self?.connection?.write(command)
        }
    }
    
    func tmuxClient(_ client: TmuxControlClient, didRestoreSession content: String, paneId: String, paneState: TmuxControlClient.PaneState?) {
        // Session content has been restored from capture-pane
        // Feed it to the terminal so the user sees their session history
        logger.info("Restoring session content to terminal: \(content.count) chars for pane \(paneId)")
        
        // Route through TmuxSessionManager to ensure it goes to the correct surface
        // This is important because the displayed surface might be different from
        // the delegate's surfaceView (e.g., after surface replacement in Option A)
        if let manager = tmuxSessionManager {
            // Clear the screen first to remove pre-tmux SSH output (MOTD, command echo, etc.)
            // ESC[2J = clear entire screen, ESC[H = move cursor to home position
            let clearScreen = "\u{1b}[2J\u{1b}[H"
            if let clearData = clearScreen.data(using: .utf8) {
                manager.routeOutput(clearData, to: paneId)
            }
            
            // Feed captured session content to terminal
            // Convert \n to \r\n for proper terminal display (CR moves to column 0, LF moves down)
            if !content.isEmpty {
                let terminalContent = content.replacingOccurrences(of: "\n", with: "\r\n")
                if let data = terminalContent.data(using: .utf8) {
                    manager.routeOutput(data, to: paneId)
                }
            }
        } else {
            // Fallback for non-tmux mode (shouldn't happen in practice)
            logger.warning("No tmux session manager, using delegate fallback for session restore")
            let clearScreen = "\u{1b}[2J\u{1b}[H"
            if let clearData = clearScreen.data(using: .utf8) {
                delegate?.sshSession(self, didReceiveData: clearData)
            }
            if !content.isEmpty {
                let terminalContent = content.replacingOccurrences(of: "\n", with: "\r\n")
                if let data = terminalContent.data(using: .utf8) {
                    delegate?.sshSession(self, didReceiveData: data)
                }
            }
        }
    }
    
    func tmuxClient(_ client: TmuxControlClient, commandDidComplete commandId: String, response: String) {
        logger.debug("tmux command completed: \(commandId) - \(response.prefix(100))")
    }
    
    func tmuxClient(_ client: TmuxControlClient, commandDidFail commandId: String, error: String) {
        logger.error("tmux command failed: \(commandId) - \(error)")
    }
    
    func tmuxClientDidExit(_ client: TmuxControlClient, reason: String?) {
        let reasonText = reason ?? "no reason"
        logger.info("tmux control mode exited: \(reasonText)")
        
        // Reset control mode state
        controlModeActive = false
        tmuxControlClient?.reset()
        
        // Notify session manager
        tmuxSessionManager?.controlModeExited()
        
        // Notify delegate - this will typically trigger disconnect handling
        // The SSH connection is still open, but tmux has terminated
        delegate?.sshSession(self, didDisconnectWithError: SSHError.tmuxExited(reason: reason))
    }
}
