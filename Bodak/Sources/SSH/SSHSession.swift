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

// MARK: - tmux Capture Helper

/// Helper class to collect tmux capture-pane output until delimiter is seen
private class TmuxCaptureOperation {
    let delimiter: String
    let startMarker: String
    private let completion: (Result<String, Error>) -> Void
    private var buffer = Data()
    private(set) var isComplete = false
    private var sawStartMarker = false
    
    init(delimiter: String, startMarker: String, completion: @escaping (Result<String, Error>) -> Void) {
        self.delimiter = delimiter
        self.startMarker = startMarker
        self.completion = completion
        logger.debug("TmuxCapture: Created with startMarker=\(startMarker), delimiter=\(delimiter)")
    }
    
    func appendData(_ data: Data) {
        buffer.append(data)
        logger.debug("TmuxCapture: Received \(data.count) bytes, total buffer: \(self.buffer.count) bytes")
        
        // Check if we've received the start and end markers
        if let str = String(data: buffer, encoding: .utf8) {
            if !sawStartMarker && str.contains(startMarker) {
                sawStartMarker = true
                logger.debug("TmuxCapture: Found start marker!")
            }
            if sawStartMarker && str.contains(delimiter) {
                isComplete = true
                logger.debug("TmuxCapture: Found end marker! Capture complete.")
            }
        } else {
            logger.warning("TmuxCapture: Buffer not valid UTF-8")
        }
    }
    
    func finish() {
        guard let fullOutput = String(data: buffer, encoding: .utf8) else {
            logger.error("TmuxCapture: Invalid UTF-8 output")
            completion(.failure(SSHError.channelError("Invalid UTF-8 output")))
            return
        }
        
        logger.debug("TmuxCapture: finish() called, fullOutput length: \(fullOutput.count)")
        logger.debug("TmuxCapture: First 500 chars: \(String(fullOutput.prefix(500)))")
        
        // Parse out the captured content between start and end markers
        // The output format is:
        // ... command echo and noise ...
        // ___BODAK_CAPTURE_START_<uuid>___
        // <captured pane content>
        // ___BODAK_CAPTURE_END_<uuid>___
        
        guard let startRange = fullOutput.range(of: startMarker) else {
            logger.error("TmuxCapture: Start marker not found in output")
            completion(.failure(SSHError.channelError("Capture start marker not found")))
            return
        }
        
        guard let endRange = fullOutput.range(of: delimiter) else {
            logger.error("TmuxCapture: End marker not found in output")
            completion(.failure(SSHError.channelError("Capture end marker not found")))
            return
        }
        
        // Get content between markers
        let contentStart = startRange.upperBound
        let contentEnd = endRange.lowerBound
        
        guard contentStart < contentEnd else {
            logger.debug("TmuxCapture: Empty capture (markers adjacent)")
            completion(.success(""))  // Empty capture
            return
        }
        
        let content = String(fullOutput[contentStart..<contentEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        logger.info("TmuxCapture: Successfully captured \(content.count) chars")
        completion(.success(content))
    }
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
        
        connection = SSHConnection(host: host, port: port, username: username)
        connection?.delegate = self
        
        #if DEBUG
        connection?.enableTracing = true
        #endif
        
        try await connection?.connect()
        try await connection?.authenticatePassword(password)
        try await connection?.openShell(term: Self.termType, cols: terminalCols, rows: terminalRows)
        
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
        
        connection = SSHConnection(host: host, port: port, username: username)
        connection?.delegate = self
        
        #if DEBUG
        connection?.enableTracing = true
        #endif
        
        try await connection?.connect()
        try await connection?.authenticateKey(privateKeyPath: privateKeyPath, passphrase: passphrase)
        try await connection?.openShell(term: Self.termType, cols: terminalCols, rows: terminalRows)
        
        // Inject shell initialization for best terminal experience
        injectTerminalSetup()
    }
    
    /// Connect using a saved connection profile and credentials
    func connect(profile: ConnectionProfile, credential: SSHCredential) async throws {
        self.host = profile.host
        self.port = profile.port
        self.username = profile.username
        self.useTmux = profile.useTmux
        self.tmuxSessionName = profile.tmuxSessionName
        
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
        
        // Inject shell initialization for best terminal experience
        injectTerminalSetup()
    }
    
    /// Inject commands to set up the terminal environment
    /// This handles cases where the SSH server doesn't accept setenv
    /// Note: Some restricted shells (like test servers) don't support these commands,
    /// so we make this optional and non-disruptive
    private func injectTerminalSetup() {
        // Small delay to let the shell initialize before injecting env vars
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.injectEnvironmentVariables()
        }
        
        // Auto-attach to tmux if enabled (with longer delay to let env vars set first)
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
        // - No newline echo, just set vars and redraw prompt
        // - 2>/dev/null suppresses any errors
        // - Uses POSIX-compatible syntax for maximum shell compatibility
        let envSetup = " eval 'export COLORTERM=truecolor TERM_PROGRAM=ghostty TERM_PROGRAM_VERSION=1.0.0; [ -z \"$LANG\" ] && export LANG=en_US.UTF-8' 2>/dev/null; clear\n"
        write(envSetup)
    }
    
    /// Auto-attach to or create a tmux session (called after delay)
    /// Uses "tmux new-session -A -s <name>" which:
    /// - Attaches to session if it exists
    /// - Creates a new session if it doesn't
    private func attachToTmuxNow() {
        let sessionName = tmuxSessionName ?? "main"
        // Use exec to replace the shell with tmux (cleaner)
        // The space prefix avoids history on many shells
        let command = " exec tmux new-session -A -s \(sessionName)\n"
        write(command)
    }
    
    // MARK: - tmux Integration
    
    /// Check if this session is using tmux
    var isTmuxSession: Bool {
        return useTmux
    }
    
    /// Capture the current tmux pane's scrollback content
    /// Uses `tmux capture-pane` to get the entire history
    /// - Parameter completion: Called with the captured text or error
    func captureTmuxPane(completion: @escaping (Result<String, Error>) -> Void) {
        logger.debug("captureTmuxPane: Called, useTmux=\(self.useTmux)")
        guard useTmux else {
            logger.warning("captureTmuxPane: Not in tmux session")
            completion(.failure(SSHError.notInTmux))
            return
        }
        
        // Generate unique markers for this capture operation
        let uuid = UUID().uuidString.prefix(8)
        let startMarker = "___BODAK_CAPTURE_START_\(uuid)___"
        let endMarker = "___BODAK_CAPTURE_END_\(uuid)___"
        
        logger.debug("captureTmuxPane: Creating capture operation with markers")
        
        // Create capture operation
        let capture = TmuxCaptureOperation(delimiter: endMarker, startMarker: startMarker, completion: completion)
        pendingTmuxCapture = capture
        
        // Send the capture command with markers:
        // 1. Echo start marker
        // 2. Capture pane (-p prints to stdout, -S - from start, -E - to end)
        // 3. Echo end marker
        // The space prefix avoids shell history
        // Note: Output will be intercepted and not displayed in terminal
        let command = " echo '\(startMarker)' && tmux capture-pane -p -S - -E - && echo '\(endMarker)'\n"
        logger.debug("captureTmuxPane: Sending capture command")
        write(command)
        
        // Timeout after 5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            if let capture = self?.pendingTmuxCapture, capture.delimiter == endMarker {
                logger.error("captureTmuxPane: Timeout after 5 seconds")
                self?.pendingTmuxCapture = nil
                completion(.failure(SSHError.timeout))
            }
        }
    }
    
    /// Pending tmux capture operation (for collecting output)
    private var pendingTmuxCapture: TmuxCaptureOperation?
    
    /// Internal: Process received data for pending tmux capture
    fileprivate func processTmuxCapture(data: Data) -> Bool {
        guard let capture = pendingTmuxCapture else { return false }
        
        capture.appendData(data)
        
        if capture.isComplete {
            pendingTmuxCapture = nil
            capture.finish()
            return true
        }
        
        return false
    }
    
    /// Resize the PTY
    func resize(cols: Int, rows: Int) {
        terminalCols = cols
        terminalRows = rows
        connection?.resizePTY(cols: cols, rows: rows)
    }
    
    /// Write data to the SSH channel
    func write(_ data: Data) {
        connection?.write(data)
    }
    
    /// Write string to the SSH channel
    func write(_ string: String) {
        connection?.write(string)
    }
    
    /// Disconnect the session
    func disconnect() {
        connection?.disconnect()
        connection = nil
        state = .disconnected
    }
    
    // Internal method to handle received data, called from connection delegate
    fileprivate func handleReceivedData(_ data: Data) {
        // Check if we're capturing tmux pane output
        // While capturing, ALL data goes to the capture buffer - don't forward to terminal
        // (otherwise the user would see the capture command output displayed)
        if pendingTmuxCapture != nil {
            logger.debug("handleReceivedData: Capture in progress, routing \(data.count) bytes to capture buffer")
            _ = processTmuxCapture(data: data)
            // Whether complete or not, don't forward capture data to terminal
            return
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
