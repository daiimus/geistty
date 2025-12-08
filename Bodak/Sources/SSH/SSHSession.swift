//
//  SSHSession.swift
//  Bodak
//
//  High-level SSH session wrapper for SwiftUI usage
//

import Foundation

/// Delegate protocol for SSHSession events
protocol SSHSessionDelegate: AnyObject {
    func sshSessionDidConnect(_ session: SSHSession)
    func sshSession(_ session: SSHSession, didReceiveData data: Data)
    func sshSession(_ session: SSHSession, didDisconnectWithError error: Error?)
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
        // Auto-attach to tmux if enabled
        if useTmux {
            attachToTmux()
        }
    }
    
    /// Auto-attach to or create a tmux session
    /// Uses "tmux new-session -A -s <name>" which:
    /// - Attaches to session if it exists
    /// - Creates a new session if it doesn't
    private func attachToTmux() {
        let sessionName = tmuxSessionName ?? "main"
        
        // Small delay to let the shell initialize
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            // Use exec to replace the shell with tmux (cleaner)
            // clear && exec prevents the command from being visible in history
            // The space prefix also helps avoid history on some shells
            let command = " exec tmux new-session -A -s \(sessionName)\n"
            self?.write(command)
        }
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
