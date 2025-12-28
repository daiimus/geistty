//
//  SSHSession.swift
//  Geistty
//
//  High-level SSH session wrapper for SwiftUI usage
//  Uses SwiftNIO-SSH with Network.framework for native iOS network monitoring
//

import Foundation
import NIOSSH
import Crypto
@_spi(CryptoExtras) import _CryptoExtras
import os

private let logger = Logger(subsystem: "com.geistty", category: "SSHSession")

/// Delegate protocol for SSHSession events
protocol SSHSessionDelegate: AnyObject {
    func sshSessionDidConnect(_ session: SSHSession)
    func sshSession(_ session: SSHSession, didReceiveData data: Data)
    func sshSession(_ session: SSHSession, didDisconnectWithError error: Error?)
    func sshSession(_ session: SSHSession, healthDidChange health: ConnectionHealth)
}

// Default implementation for optional delegate methods
extension SSHSessionDelegate {
    func sshSession(_ session: SSHSession, healthDidChange health: ConnectionHealth) {}
}

/// tmux integration mode
enum TmuxMode {
    /// No tmux integration
    case none
    
    /// Control mode: tmux -CC with proper scrollback buffering
    case controlMode
}

/// SSH session errors
enum SSHSessionError: LocalizedError {
    case notConnected
    case notInTmux
    case tmuxExited(reason: String?)
    case invalidKey(String)
    
    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected"
        case .notInTmux: return "Not in tmux session"
        case .tmuxExited(let reason): return "tmux exited: \(reason ?? "unknown")"
        case .invalidKey(let msg): return "Invalid SSH key: \(msg)"
        }
    }
}

/// Represents an SSH session - wraps NIOSSHConnection for SwiftUI usage
@MainActor
class SSHSession: ObservableObject, Identifiable {
    let id = UUID()
    
    // Delegate
    weak var delegate: SSHSessionDelegate?
    
    // Connection
    private var connection: NIOSSHConnection?
    
    // Connection parameters (stored after connect)
    private(set) var host: String = ""
    private(set) var port: Int = 22
    private(set) var username: String = ""
    
    // Stored credentials for reconnect (in memory only, never persisted)
    private var storedAuthMethod: SSHAuthMethod?
    private var storedProfile: ConnectionProfile?
    private var storedCredential: SSHCredential?
    
    // Reconnection state
    @Published private(set) var isReconnecting: Bool = false
    private var reconnectAttempts: Int = 0
    private let maxReconnectAttempts: Int = 3
    
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
    @Published var state: NIOSSHState = .disconnected
    @Published var lastError: Error?
    
    /// Connection health - reflects network path monitoring from NIOSSHConnection
    @Published private(set) var connectionHealth: ConnectionHealth = .healthy
    
    // Terminal dimensions
    private var terminalCols: Int = 80
    private var terminalRows: Int = 24
    
    init() {}
    
    /// The TERM type to use - xterm-256color is universally supported
    /// Note: xterm-ghostty would be ideal but most servers don't have the terminfo
    private static let termType = "xterm-256color"
    
    // MARK: - Connect Methods
    
    /// Connect to the SSH server with password authentication
    func connect(host: String, port: Int, username: String, password: String, useTmux: Bool = false, tmuxSessionName: String? = nil) async throws {
        self.host = host
        self.port = port
        self.username = username
        self.useTmux = useTmux
        self.tmuxSessionName = tmuxSessionName
        self.tmuxMode = useTmux ? .controlMode : .none
        
        // Store auth method for reconnect (in memory only)
        self.storedAuthMethod = .password(password)
        self.storedProfile = nil
        self.storedCredential = nil
        
        let conn = NIOSSHConnection(host: host, port: port, username: username)
        conn.cols = terminalCols
        conn.rows = terminalRows
        conn.delegate = self
        connection = conn
        
        try await conn.connect(password: password)
        
        // Reset reconnect attempts on successful connection
        reconnectAttempts = 0
        
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
        
        // Load and parse the private key
        let keyData = try Data(contentsOf: URL(fileURLWithPath: privateKeyPath))
        let privateKey = try parsePrivateKey(keyData, passphrase: passphrase)
        
        // Store auth method for reconnect
        self.storedAuthMethod = .publicKey(privateKey: privateKey)
        self.storedProfile = nil
        self.storedCredential = nil
        
        let conn = NIOSSHConnection(host: host, port: port, username: username)
        conn.cols = terminalCols
        conn.rows = terminalRows
        conn.delegate = self
        connection = conn
        
        try await conn.connect(authMethod: .publicKey(privateKey: privateKey))
        
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
        
        // Store profile and credential for reconnect (in memory only)
        self.storedProfile = profile
        self.storedCredential = credential
        
        let conn = NIOSSHConnection(host: profile.host, port: profile.port, username: profile.username)
        conn.cols = terminalCols
        conn.rows = terminalRows
        conn.delegate = self
        connection = conn
        
        // Build auth method from credential
        let authMethod = try buildAuthMethod(from: credential)
        self.storedAuthMethod = authMethod
        
        try await conn.connect(authMethod: authMethod)
        
        // Reset reconnect attempts on successful connection
        reconnectAttempts = 0
        
        // Mark profile as recently connected
        ConnectionProfileManager.shared.markConnected(profile)
        
        // Initialize control client if using control mode
        if tmuxMode == .controlMode {
            setupTmuxControlClient()
        }
        
        // Inject shell initialization for best terminal experience
        injectTerminalSetup()
    }
    
    // MARK: - Key Parsing
    
    /// Parse a private key from PEM data
    private func parsePrivateKey(_ data: Data, passphrase: String?) throws -> NIOSSHPrivateKey {
        logger.error("🔑 parsePrivateKey called with \(data.count) bytes")
        
        guard let pemString = String(data: data, encoding: .utf8) else {
            throw SSHSessionError.invalidKey("[v2] Unable to read key as UTF-8")
        }
        
        logger.error("🔑 PEM header check: contains OPENSSH=\(pemString.contains("OPENSSH PRIVATE KEY"))")
        
        // Encrypted keys require passphrase handling
        if pemString.contains("ENCRYPTED") && passphrase == nil {
            throw SSHSessionError.invalidKey("[v2] Key is encrypted but no passphrase provided")
        }
        
        // Try OpenSSH format first (most common modern format from ssh-keygen)
        if pemString.contains("OPENSSH PRIVATE KEY") {
            logger.error("🔑 Detected OpenSSH format, calling parseOpenSSHPrivateKey")
            return try parseOpenSSHPrivateKey(pemString, passphrase: passphrase)
        }
        
        // Try RSA (common for cloud providers)
        if pemString.contains("RSA PRIVATE KEY") || pemString.contains("BEGIN PRIVATE KEY") {
            do {
                // Use swift-crypto's _RSA for PEM parsing
                let rsaKey = try _RSA.Signing.PrivateKey(pemRepresentation: pemString)
                return NIOSSHPrivateKey(rsaKey: rsaKey)
            } catch {
                logger.warning("RSA key parsing failed: \(error.localizedDescription)")
                throw SSHSessionError.invalidKey("Failed to parse RSA key: \(error.localizedDescription)")
            }
        }
        
        // Try ECDSA
        if pemString.contains("EC PRIVATE KEY") {
            // Try P-256 first (most common)
            if let p256Key = try? P256.Signing.PrivateKey(pemRepresentation: pemString) {
                return NIOSSHPrivateKey(p256Key: p256Key)
            }
            // Try P-384
            if let p384Key = try? P384.Signing.PrivateKey(pemRepresentation: pemString) {
                return NIOSSHPrivateKey(p384Key: p384Key)
            }
            // Try P-521
            if let p521Key = try? P521.Signing.PrivateKey(pemRepresentation: pemString) {
                return NIOSSHPrivateKey(p521Key: p521Key)
            }
            throw SSHSessionError.invalidKey("ECDSA key curve not supported")
        }
        
        throw SSHSessionError.invalidKey("[v2] Unsupported key format. Supported: RSA, ECDSA, Ed25519")
    }
    
    /// Parse OpenSSH private key format (-----BEGIN OPENSSH PRIVATE KEY-----)
    /// This is the default format generated by ssh-keygen since OpenSSH 6.5
    /// Strip leading zero byte from SSH mpint format
    /// SSH mpint format adds a 0x00 prefix when the high bit is set to indicate positive number.
    /// swift-crypto expects raw unsigned integers without this padding.
    private func stripMPIntPadding(_ data: Data) -> Data {
        guard data.count > 1, data[0] == 0 else { return data }
        return Data(data.dropFirst())
    }


    private func parseOpenSSHPrivateKey(_ pemString: String, passphrase: String?) throws -> NIOSSHPrivateKey {
        logger.error("🔑 parseOpenSSHPrivateKey: Starting")
        
        // Extract base64 content between PEM headers
        let lines = pemString.components(separatedBy: .newlines)
        var base64Content = ""
        var inKey = false
        
        for line in lines {
            if line.contains("BEGIN OPENSSH PRIVATE KEY") {
                inKey = true
                continue
            }
            if line.contains("END OPENSSH PRIVATE KEY") {
                break
            }
            if inKey {
                base64Content += line.trimmingCharacters(in: .whitespaces)
            }
        }
        
        logger.error("🔑 Base64 content length: \(base64Content.count)")
        
        guard let keyData = Data(base64Encoded: base64Content) else {
            throw SSHSessionError.invalidKey("Invalid base64 in OpenSSH key")
        }
        
        logger.error("🔑 Decoded key data: \(keyData.count) bytes")
        logger.error("🔑 First 50 bytes hex: \(keyData.prefix(50).map { String(format: "%02x", $0) }.joined(separator: " "))")
        
        // Parse OpenSSH key format
        // See: https://github.com/openssh/openssh-portable/blob/master/PROTOCOL.key
        var offset = 0
        
        // Magic: "openssh-key-v1\0"
        let magic = "openssh-key-v1\0"
        let magicBytes = Array(magic.utf8)
        guard keyData.count > magicBytes.count else {
            throw SSHSessionError.invalidKey("Key too short")
        }
        
        let actualMagic = Array(keyData.prefix(magicBytes.count))
        guard actualMagic == magicBytes else {
            throw SSHSessionError.invalidKey("Invalid OpenSSH key magic")
        }
        offset = magicBytes.count
        logger.error("🔑 Magic verified, offset now: \(offset)")
        
        // Helper to read a uint32
        func readUInt32() throws -> UInt32 {
            guard offset + 4 <= keyData.count else {
                throw SSHSessionError.invalidKey("Unexpected end of key data at offset \(offset)")
            }
            let value = keyData.withUnsafeBytes { ptr in
                ptr.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian
            }
            offset += 4
            return value
        }
        
        // Helper to read a string (length-prefixed)
        func readString() throws -> Data {
            let length = try Int(readUInt32())
            logger.error("🔑 readString: length=\(length) at offset \(offset - 4)")
            guard length >= 0 && offset + length <= keyData.count else {
                throw SSHSessionError.invalidKey("Invalid string length \(length) at offset \(offset)")
            }
            let data = keyData[offset..<(offset + length)]
            offset += length
            return Data(data)
        }
        
        // Cipher name
        let cipherData = try readString()
        let cipherName = String(data: cipherData, encoding: .utf8) ?? ""
        logger.error("🔑 Cipher: '\(cipherName)'")
        
        // KDF name
        let kdfData = try readString()
        let kdfName = String(data: kdfData, encoding: .utf8) ?? ""
        logger.error("🔑 KDF: '\(kdfName)'")
        
        // KDF options
        let kdfOptions = try readString()
        logger.error("🔑 KDF options: \(kdfOptions.count) bytes")
        
        // Number of keys (usually 1)
        let numKeys = try readUInt32()
        logger.error("🔑 Number of keys: \(numKeys)")
        guard numKeys == 1 else {
            throw SSHSessionError.invalidKey("Multiple keys in file not supported")
        }
        
        // Public key (we skip this, will extract from private section)
        let publicKeyBlob = try readString()
        logger.error("🔑 Public key blob: \(publicKeyBlob.count) bytes")
        
        // Private key section (may be encrypted)
        // IMPORTANT: Create a new Data to reset indices to 0
        let privateData = Data(try readString())
        logger.error("🔑 Private data: \(privateData.count) bytes")
        logger.error("🔑 Private data first 50 bytes: \(privateData.prefix(50).map { String(format: "%02x", $0) }.joined(separator: " "))")
        
        // Check if encrypted
        if cipherName != "none" {
            guard passphrase != nil else {
                throw SSHSessionError.invalidKey("Key is encrypted but no passphrase provided")
            }
            // TODO: Implement decryption for aes256-ctr, aes256-cbc, etc.
            throw SSHSessionError.invalidKey("Encrypted OpenSSH keys not yet supported. Use: ssh-keygen -p -m PEM -f <keyfile> to convert")
        }
        
        // Parse unencrypted private key section
        var privOffset = 0
        
        func readPrivUInt32() throws -> UInt32 {
            guard privOffset + 4 <= privateData.count else {
                throw SSHSessionError.invalidKey("Unexpected end of private key data")
            }
            let value = privateData.withUnsafeBytes { ptr in
                ptr.loadUnaligned(fromByteOffset: privOffset, as: UInt32.self).bigEndian
            }
            privOffset += 4
            return value
        }
        
        func readPrivString() throws -> Data {
            let length = try Int(readPrivUInt32())
            guard privOffset + length <= privateData.count else {
                throw SSHSessionError.invalidKey("Unexpected end of private key data")
            }
            let data = Data(privateData[privOffset..<(privOffset + length)])
            privOffset += length
            return data
        }
        
        // Check bytes (should be identical - used for passphrase verification)
        let check1 = try readPrivUInt32()
        let check2 = try readPrivUInt32()
        guard check1 == check2 else {
            throw SSHSessionError.invalidKey("Key decryption failed (check bytes mismatch)")
        }
        
        // Key type
        let keyTypeData = try readPrivString()
        logger.error("🔑 Key type data: \(keyTypeData.count) bytes, hex: \(keyTypeData.map { String(format: "%02x", $0) }.joined())")
        guard let keyType = String(data: keyTypeData, encoding: .utf8) else {
            throw SSHSessionError.invalidKey("Invalid key type encoding, raw: \(keyTypeData.prefix(20).map { String(format: "%02x", $0) }.joined())")
        }
        
        logger.error("🔑 Parsed key type: '\(keyType)'")
        
        switch keyType {
        case "ssh-ed25519":
            // Ed25519: public key (32 bytes) + private key (64 bytes = seed + public)
            let publicKey = try readPrivString()  // 32 bytes
            let privateKey = try readPrivString() // 64 bytes
            
            guard publicKey.count == 32, privateKey.count == 64 else {
                throw SSHSessionError.invalidKey("Invalid Ed25519 key length")
            }
            
            // The first 32 bytes of the private key is the seed
            let seed = privateKey.prefix(32)
            let ed25519Key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            return NIOSSHPrivateKey(ed25519Key: ed25519Key)
            
        case "ecdsa-sha2-nistp256":
            // ECDSA P-256
            _ = try readPrivString() // curve identifier "nistp256"
            let publicPoint = try readPrivString() // uncompressed point
            let privateScalar = try readPrivString() // private scalar
            
            let p256Key = try P256.Signing.PrivateKey(rawRepresentation: privateScalar)
            return NIOSSHPrivateKey(p256Key: p256Key)
            
        case "ecdsa-sha2-nistp384":
            // ECDSA P-384
            _ = try readPrivString()
            _ = try readPrivString()
            let privateScalar = try readPrivString()
            
            let p384Key = try P384.Signing.PrivateKey(rawRepresentation: privateScalar)
            return NIOSSHPrivateKey(p384Key: p384Key)
            
        case "ecdsa-sha2-nistp521":
            // ECDSA P-521
            _ = try readPrivString()
            _ = try readPrivString()
            let privateScalar = try readPrivString()
            
            let p521Key = try P521.Signing.PrivateKey(rawRepresentation: privateScalar)
            return NIOSSHPrivateKey(p521Key: p521Key)
            
        case "ssh-rsa":
            // RSA key in OpenSSH format
            // OpenSSH stores: n, e, d, iqmp, p, q as SSH mpints
            // swift-crypto needs: n, e, d, p, q as raw unsigned integers
            // SSH mpints have a leading 0x00 byte if the high bit is set (to indicate positive)
            // We must strip that leading zero before passing to swift-crypto
            
            func stripMpintPadding(_ data: Data) -> Data {
                // SSH mpint format adds 0x00 prefix when high bit is set
                // swift-crypto expects raw unsigned integer bytes
                if let first = data.first, first == 0x00, data.count > 1 {
                    return Data(data.dropFirst())
                }
                return data
            }
            
            let nRaw = try readPrivString() // modulus
            let eRaw = try readPrivString() // public exponent  
            let dRaw = try readPrivString() // private exponent
            _ = try readPrivString() // iqmp (inverse of q mod p) - not needed for swift-crypto
            let pRaw = try readPrivString() // prime 1
            let qRaw = try readPrivString() // prime 2
            
            // Strip mpint padding from all components
            let n = stripMpintPadding(nRaw)
            let e = stripMpintPadding(eRaw)
            let d = stripMpintPadding(dRaw)
            let p = stripMpintPadding(pRaw)
            let q = stripMpintPadding(qRaw)
            
            logger.debug("RSA key components (after mpint strip): n=\(n.count) bytes, e=\(e.count) bytes, d=\(d.count) bytes, p=\(p.count) bytes, q=\(q.count) bytes")
            
            let rsaKey = try _RSA.Signing.PrivateKey(n: n, e: e, d: d, p: p, q: q)
            return NIOSSHPrivateKey(rsaKey: rsaKey)
            
        default:
            throw SSHSessionError.invalidKey("Unsupported key type: \(keyType)")
        }
    }
    
    /// Build an SSHAuthMethod from an SSHCredential
    private func buildAuthMethod(from credential: SSHCredential) throws -> SSHAuthMethod {
        switch credential.authType {
        case .password(let password):
            return .password(password)
            
        case .privateKey(let path, let passphrase):
            let keyData = try Data(contentsOf: URL(fileURLWithPath: path))
            let privateKey = try parsePrivateKey(keyData, passphrase: passphrase)
            return .publicKey(privateKey: privateKey)
            
        case .privateKeyData(let keyData, let passphrase):
            let privateKey = try parsePrivateKey(keyData, passphrase: passphrase)
            return .publicKey(privateKey: privateKey)
        }
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
            completion(.failure(SSHSessionError.notInTmux))
            return
        }
        
        guard tmuxMode == .controlMode, let client = tmuxControlClient else {
            logger.error("captureTmuxPane: Control mode not active")
            completion(.failure(NIOSSHError.channelError("tmux control mode not active")))
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
        
        // Check connection health - if stale/dead, queue instead of sending
        if !connectionHealth.isHealthy {
            logger.debug("Connection unhealthy (\(String(describing: connectionHealth))), queueing \(data.count) bytes of input")
            pendingInputQueue.append(data)
            updatePendingInputDisplay()
            return
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
            updatePendingInputDisplay()
            return
        }
        
        connection?.write(data)
    }
    
    /// Write string to the SSH channel
    func write(_ string: String) {
        logger.debug("SSHSession.write(string): \(string.prefix(20))")
        
        // Check connection health first
        if !connectionHealth.isHealthy, let data = string.data(using: .utf8) {
            logger.debug("Connection unhealthy, queueing string input")
            pendingInputQueue.append(data)
            updatePendingInputDisplay()
            return
        }
        
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
            updatePendingInputDisplay()
            return
        }
        
        connection?.write(string)
    }
    
    /// Update the visual display of pending input using preedit
    private func updatePendingInputDisplay() {
        // Build a displayable string from the queue (filter out control chars)
        let displayText = pendingInputQueue
            .compactMap { String(data: $0, encoding: .utf8) }
            .joined()
            .filter { !$0.isASCII || $0.asciiValue! >= 32 || $0 == "\n" || $0 == "\t" }
        
        logger.info("📝 updatePendingInputDisplay: '\(displayText)' tmuxSessionManager=\(tmuxSessionManager != nil)")
        tmuxSessionManager?.displayPendingInput(displayText)
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
        
        // Clear stored credentials on explicit disconnect
        storedAuthMethod = nil
        storedProfile = nil
        storedCredential = nil
    }
    
    // MARK: - App Lifecycle & Auto-Reconnect
    
    /// Check if the connection is alive
    var isConnectionAlive: Bool {
        guard let conn = connection else { return false }
        return conn.state != .disconnected
    }
    
    /// Check if we have stored credentials for reconnect
    var canReconnect: Bool {
        return storedAuthMethod != nil
    }
    
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
    /// Checks connection health and auto-reconnects if needed.
    func appDidBecomeActive() {
        logger.info("🔄 App became active, checking connection health...")
        
        // If already reconnecting, don't start another attempt
        guard !isReconnecting else {
            logger.info("🔄 Already reconnecting, skipping")
            return
        }
        
        // If connection is alive and tmux is active, just resume paused panes
        if isConnectionAlive, controlModeActive, let client = tmuxControlClient {
            logger.info("🔄 Connection alive, resuming paused panes")
            client.resumeAllPausedPanes(via: { [weak self] command in
                self?.connection?.write(command)
            })
            return
        }
        
        // Connection is dead - attempt to reconnect if we have credentials
        if !isConnectionAlive && canReconnect {
            logger.info("🔄 Connection dead, attempting auto-reconnect...")
            Task {
                await attemptReconnect()
            }
        } else if !isConnectionAlive {
            logger.warning("🔄 Connection dead but no stored credentials for reconnect")
            // Notify session manager of connection loss
            tmuxSessionManager?.controlModeExited(reason: "Connection lost")
        }
    }
    
    /// Attempt to reconnect to the SSH server
    private func attemptReconnect() async {
        guard !isReconnecting else { return }
        guard reconnectAttempts < maxReconnectAttempts else {
            logger.error("🔄 Max reconnect attempts (\(maxReconnectAttempts)) reached")
            tmuxSessionManager?.controlModeExited(reason: "Reconnect failed after \(maxReconnectAttempts) attempts")
            return
        }
        
        isReconnecting = true
        reconnectAttempts += 1
        logger.info("🔄 Reconnect attempt \(reconnectAttempts)/\(maxReconnectAttempts)")
        
        // Clean up old connection state (but keep tmuxSessionManager for surface reuse)
        controlModeActive = false
        tmuxControlClient?.reset()
        tmuxControlClient = nil
        connection?.disconnect()
        connection = nil
        
        do {
            // Reconnect using stored auth method
            guard let authMethod = storedAuthMethod else {
                throw SSHSessionError.notConnected
            }
            
            try await reconnectWithAuth(authMethod)
            
            // Success!
            isReconnecting = false
            reconnectAttempts = 0
            logger.info("🔄 ✅ Reconnect successful!")
            
        } catch {
            logger.error("🔄 Reconnect failed: \(error.localizedDescription)")
            isReconnecting = false
            
            // Retry after delay if attempts remaining
            if reconnectAttempts < maxReconnectAttempts {
                logger.info("🔄 Retrying in 2 seconds...")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await attemptReconnect()
            } else {
                tmuxSessionManager?.controlModeExited(reason: "Reconnect failed: \(error.localizedDescription)")
            }
        }
    }
    
    /// Reconnect using stored auth method
    private func reconnectWithAuth(_ authMethod: SSHAuthMethod) async throws {
        let conn = NIOSSHConnection(host: host, port: port, username: username)
        conn.cols = terminalCols
        conn.rows = terminalRows
        conn.delegate = self
        connection = conn
        
        try await conn.connect(authMethod: authMethod)
        
        // Re-setup tmux control mode
        if tmuxMode == .controlMode {
            setupTmuxControlClient()
        }
        
        // Re-attach to tmux session
        injectTerminalSetup()
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

// MARK: - NIOSSHConnectionDelegate

extension SSHSession: NIOSSHConnectionDelegate {
    nonisolated func connectionDidConnect(_ connection: NIOSSHConnection) {
        Task { @MainActor in
            self.state = .connected
        }
    }
    
    nonisolated func connectionDidAuthenticate(_ connection: NIOSSHConnection) {
        Task { @MainActor in
            self.state = .authenticated
            self.delegate?.sshSessionDidConnect(self)
        }
    }
    
    nonisolated func connectionDidFailAuthentication(_ connection: NIOSSHConnection, error: Error) {
        Task { @MainActor in
            self.lastError = error
            self.state = .disconnected
            self.delegate?.sshSession(self, didDisconnectWithError: error)
        }
    }
    
    nonisolated func connectionDidClose(_ connection: NIOSSHConnection, error: Error?) {
        Task { @MainActor in
            self.lastError = error
            self.state = .disconnected
            self.delegate?.sshSession(self, didDisconnectWithError: error)
        }
    }
    
    nonisolated func connection(_ connection: NIOSSHConnection, didReceiveData data: Data) {
        Task { @MainActor in
            self.handleReceivedData(data)
        }
    }
    
    nonisolated func connection(_ connection: NIOSSHConnection, healthDidChange health: ConnectionHealth) {
        Task { @MainActor in
            self.connectionHealth = health
            logger.info("🔌 Connection health changed: \(String(describing: health))")
            
            // Notify delegate
            self.delegate?.sshSession(self, healthDidChange: health)
            
            // If connection became healthy again and we have pending input, flush it
            if health.isHealthy && !self.pendingInputQueue.isEmpty {
                logger.info("🔌 Connection healthy, flushing \(self.pendingInputQueue.count) queued inputs")
                self.tmuxSessionManager?.clearPendingInputDisplay()
                
                for data in self.pendingInputQueue {
                    if let client = self.tmuxControlClient, client.isActive {
                        client.sendKeys(data) { [weak self] command in
                            self?.connection?.write(command)
                        }
                    } else {
                        self.connection?.write(data)
                    }
                }
                self.pendingInputQueue.removeAll()
            }
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
            
            // Clear the pending input display before flushing
            tmuxSessionManager?.clearPendingInputDisplay()
            
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
        
        // Route through TmuxSessionManager which handles:
        // 1. Clearing the screen
        // 2. Feeding history content
        // 3. Flushing any buffered live output that arrived during capture
        if let manager = tmuxSessionManager {
            manager.historyRestoreComplete(for: paneId, content: content)
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
        
        // Notify session manager with reason
        tmuxSessionManager?.controlModeExited(reason: reason)
        
        // Notify delegate - this will typically trigger disconnect handling
        // The SSH connection is still open, but tmux has terminated
        delegate?.sshSession(self, didDisconnectWithError: SSHSessionError.tmuxExited(reason: reason))
    }
}
