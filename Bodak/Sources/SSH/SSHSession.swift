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
    
    // State
    @Published var state: SSHState = .disconnected
    @Published var lastError: Error?
    
    // Terminal dimensions
    private var terminalCols: Int = 80
    private var terminalRows: Int = 24
    
    init() {}
    
    /// The preferred TERM type - try ghostty first for best experience
    private static let preferredTerm = "xterm-ghostty"
    private static let fallbackTerm = "xterm-256color"
    
    /// Connect to the SSH server with password authentication
    func connect(host: String, port: Int, username: String, password: String) async throws {
        self.host = host
        self.port = port
        self.username = username
        
        connection = SSHConnection(host: host, port: port, username: username)
        connection?.delegate = self
        
        try await connection?.connect()
        try await connection?.authenticatePassword(password)
        try await connection?.openShell(term: Self.preferredTerm, cols: terminalCols, rows: terminalRows)
        
        // Inject shell initialization for best terminal experience
        injectTerminalSetup()
    }
    
    /// Connect to the SSH server with key-based authentication
    func connectWithKey(host: String, port: Int, username: String, privateKeyPath: String, passphrase: String? = nil) async throws {
        self.host = host
        self.port = port
        self.username = username
        
        connection = SSHConnection(host: host, port: port, username: username)
        connection?.delegate = self
        
        try await connection?.connect()
        try await connection?.authenticateKey(privateKeyPath: privateKeyPath, passphrase: passphrase)
        try await connection?.openShell(term: Self.preferredTerm, cols: terminalCols, rows: terminalRows)
        
        // Inject shell initialization for best terminal experience
        injectTerminalSetup()
    }
    
    /// Connect using a saved connection profile and credentials
    func connect(profile: ConnectionProfile, credential: SSHCredential) async throws {
        self.host = profile.host
        self.port = profile.port
        self.username = profile.username
        
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
        
        try await connection?.openShell(term: Self.preferredTerm, cols: terminalCols, rows: terminalRows)
        
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
        // Disable auto-setup for now - it causes issues on restricted shells
        // Users can manually configure their shell profile if needed
        // 
        // TODO: Detect shell type first, or make this a per-connection setting
        // 
        // The ideal setup would be:
        // - Check if we're in a real shell (bash/zsh/fish)
        // - Only then inject environment setup
        // - Consider using SSH channel env requests as primary method
        
        // For now, we rely on the TERM set during PTY request
        // which is xterm-ghostty or xterm-256color
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
