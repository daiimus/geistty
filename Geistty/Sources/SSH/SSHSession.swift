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

/// Control mode lifecycle state
/// Tracks whether Ghostty's native tmux viewer is active.
/// Ghostty handles DCS 1000p detection, protocol parsing, and pane output routing
/// internally — we only need to know when it's active for input queueing and UI.
enum ControlModeState: Equatable, CustomStringConvertible {
    /// Not using tmux control mode (or tmux exited)
    case inactive
    
    /// Ghostty's native tmux viewer is active, ready for user input.
    /// In tmux control mode, keystrokes on stdin go directly to the active pane —
    /// no send-keys wrapping is needed.
    case active
    
    var description: String {
        switch self {
        case .inactive: return "inactive"
        case .active: return "active"
        }
    }
    
    /// Whether user input can flow through to tmux
    var isActive: Bool {
        self == .active
    }
}

/// SSH session errors
enum SSHSessionError: LocalizedError {
    case notConnected
    case invalidKey(String)
    
    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected"
        case .invalidKey(let msg): return "Invalid SSH key: \(msg)"
        }
    }
}

/// Represents an SSH session - wraps NIOSSHConnection for SwiftUI usage
@MainActor
class SSHSession: ObservableObject, Identifiable {
    let id = UUID()
    
    // Delegate
    weak var delegate: SSHSessionDelegate? {
        didSet {
            // Flush any data that arrived before the delegate was set.
            // This covers the pre-connected session flow where SSH data
            // (including DCS 1000p) can arrive between connect() returning
            // and useExistingSession() setting the delegate.
            if delegate != nil && !earlyReceiveBuffer.isEmpty {
                let buffered = earlyReceiveBuffer
                earlyReceiveBuffer.removeAll()
                logger.info("Flushing \(buffered.count) early-received chunks (\(buffered.reduce(0) { $0 + $1.count })B) to new delegate")
                for chunk in buffered {
                    delegate?.sshSession(self, didReceiveData: chunk)
                }
            }
        }
    }
    
    /// Buffer for data received before delegate is set (pre-connected session flow)
    private var earlyReceiveBuffer: [Data] = []
    
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
    
    /// Public accessor for the profile ID (for File Provider refresh signaling)
    var profileId: String? {
        storedProfile?.id.uuidString
    }
    
    // Reconnection state
    @Published private(set) var isReconnecting: Bool = false
    private var reconnectAttempts: Int = 0
    private let maxReconnectAttempts: Int = 3
    
    // tmux options
    private var useTmux: Bool = false
    private var tmuxSessionName: String?
    private var tmuxMode: TmuxMode = .none
    
    /// tmux Session Manager for multi-pane state management
    /// Access this to get session/window/pane info and route output to surfaces
    private(set) var tmuxSessionManager: TmuxSessionManager?
    
    /// Notification observers for Ghostty's tmux action callbacks
    private var tmuxNotificationObservers: [NSObjectProtocol] = []
    
    /// Ghostty surface for tmux pane switching.
    /// Set by TerminalViewModel after creating the surface.
    /// Used to call setActiveTmuxPane() when TMUX_STATE_CHANGED fires.
    weak var ghosttySurface: Ghostty.SurfaceView? {
        didSet {
            logger.debug("ghosttySurface set: \(ghosttySurface != nil ? "non-nil" : "nil"), controlModeState=\(controlModeState), viewerReady=\(viewerReady)")
            // If control mode is already active AND the viewer is ready when the surface
            // gets wired, activate the first pane immediately. This handles the race where
            // TMUX_READY fired before ghosttySurface was set.
            if ghosttySurface != nil && controlModeState.isActive && viewerReady {
                logger.info("ghosttySurface set while viewer ready, attempting pane activation")
                activateFirstTmuxPane()
            }
        }
    }
    
    /// Whether we've successfully activated a tmux pane for rendering.
    /// Prevents redundant activation calls on subsequent state changes.
    private(set) var tmuxPaneActivated: Bool = false
    
    /// The tmux pane ID that the Ghostty renderer is displaying.
    /// Set when activateFirstTmuxPane() calls ghostty_surface_tmux_set_active_pane().
    /// Cleared on tmux exit/disconnect. Ghostty's Zig-side Termio.queueWrite()
    /// uses the viewer's active_pane_id (set via the same C API call) for
    /// send-keys wrapping — this Swift property is for UI state tracking only.
    private(set) var activeTmuxPaneId: Int? = nil
    
    /// Whether the tmux viewer's initial command queue has drained.
    /// Set to true when GHOSTTY_ACTION_TMUX_READY fires (viewer.zig emits .ready
    /// after all startup commands complete). Reset on disconnect/tmux exit.
    ///
    /// This gates user input: when false, input is queued in pendingInputQueue
    /// to prevent interleaving with viewer commands. When true,
    /// activateFirstTmuxPane() is called which sets activeTmuxPaneId and
    /// flushes pending input with proper send-keys wrapping.
    private(set) var viewerReady: Bool = false
    
    /// Control mode lifecycle state
    /// Ghostty's native tmux viewer handles DCS 1000p detection and protocol parsing.
    /// This state tracks whether the viewer is active (from TMUX_STATE_CHANGED action).
    private(set) var controlModeState: ControlModeState = .inactive
    
    /// Session name discovery state for geistty-N auto-naming.
    /// When no custom tmux session name is set, we query `tmux list-sessions`
    /// before entering control mode. This state tracks that pre-control-mode query.
    private enum SessionDiscoveryState {
        /// Not performing session discovery (custom name set, or already resolved)
        case idle
        /// Waiting for `tmux list-sessions` response
        case querying(buffer: String)
    }
    private var sessionDiscoveryState: SessionDiscoveryState = .idle
    
    // Queue of input data waiting to be sent once control mode activates
    // This prevents input from going to tmux's command prompt before the shell is ready
    private(set) var pendingInputQueue: [Data] = []
    
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
    
    /// Common setup before connection
    private func prepareConnection(
        host: String,
        port: Int,
        username: String,
        useTmux: Bool,
        tmuxSessionName: String?
    ) -> NIOSSHConnection {
        self.host = host
        self.port = port
        self.username = username
        self.useTmux = useTmux
        self.tmuxSessionName = tmuxSessionName
        self.tmuxMode = useTmux ? .controlMode : .none
        
        let conn = NIOSSHConnection(host: host, port: port, username: username)
        conn.cols = terminalCols
        conn.rows = terminalRows
        conn.delegate = self
        connection = conn
        return conn
    }
    
    /// Common setup after successful connection
    private func finalizeConnection() {
        // Reset reconnect attempts on successful connection
        reconnectAttempts = 0
        
        // Initialize session manager if using control mode
        logger.debug("finalizeConnection: tmuxMode=\(tmuxMode)")
        if tmuxMode == .controlMode {
            setupTmuxSessionManager()
        }
        
        // Inject shell initialization for best terminal experience
        injectTerminalSetup()
    }
    
    /// Connect to the SSH server with password authentication
    func connect(host: String, port: Int, username: String, password: String, useTmux: Bool = false, tmuxSessionName: String? = nil) async throws {
        let conn = prepareConnection(
            host: host, port: port, username: username,
            useTmux: useTmux, tmuxSessionName: tmuxSessionName
        )
        
        // Store auth method for reconnect (in memory only)
        self.storedAuthMethod = .password(password)
        self.storedProfile = nil
        self.storedCredential = nil
        
        try await conn.connect(password: password)
        finalizeConnection()
    }
    
    /// Connect using a saved connection profile and credentials
    /// - Note: Control mode is enabled by default for testing
    func connect(profile: ConnectionProfile, credential: SSHCredential) async throws {
        let conn = prepareConnection(
            host: profile.host, port: profile.port, username: profile.username,
            useTmux: profile.useTmux, tmuxSessionName: profile.tmuxSessionName
        )
        
        // Store profile and credential for reconnect (in memory only)
        self.storedProfile = profile
        self.storedCredential = credential
        
        // Build auth method from credential
        let authMethod = try buildAuthMethod(from: credential)
        self.storedAuthMethod = authMethod
        
        try await conn.connect(authMethod: authMethod)
        
        // Mark profile as recently connected
        ConnectionProfileManager.shared.markConnected(profile)
        
        finalizeConnection()
    }
    
    // MARK: - Key Parsing
    
    /// Parse a private key from PEM data
    private func parsePrivateKey(_ data: Data, passphrase: String?) throws -> NIOSSHPrivateKey {
        logger.debug("[KeyParse] parsePrivateKey called with \(data.count) bytes")
        
        guard let pemString = String(data: data, encoding: .utf8) else {
            throw SSHSessionError.invalidKey("[v2] Unable to read key as UTF-8")
        }
        
        logger.debug("[KeyParse] PEM header check: contains OPENSSH=\(pemString.contains("OPENSSH PRIVATE KEY"))")
        
        // Encrypted keys require passphrase handling
        if pemString.contains("ENCRYPTED") && passphrase == nil {
            throw SSHSessionError.invalidKey("[v2] Key is encrypted but no passphrase provided")
        }
        
        // Try OpenSSH format first (most common modern format from ssh-keygen)
        if pemString.contains("OPENSSH PRIVATE KEY") {
            logger.debug("[KeyParse] Detected OpenSSH format, calling parseOpenSSHPrivateKey")
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


    private func parseOpenSSHPrivateKey(_ pemString: String, passphrase: String?) throws -> NIOSSHPrivateKey {
        logger.debug("[KeyParse] parseOpenSSHPrivateKey: Starting")
        
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
        
        logger.debug("[KeyParse] Base64 content length: \(base64Content.count)")
        
        guard let keyData = Data(base64Encoded: base64Content) else {
            throw SSHSessionError.invalidKey("Invalid base64 in OpenSSH key")
        }
        
        logger.debug("[KeyParse] Decoded key data: \(keyData.count) bytes")
        
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
        logger.debug("[KeyParse] Magic verified, offset now: \(offset)")
        
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
            logger.debug("[KeyParse] readString: length=\(length) at offset \(offset - 4)")
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
        logger.debug("[KeyParse] Cipher: '\(cipherName)'")
        
        // KDF name
        let kdfData = try readString()
        let kdfName = String(data: kdfData, encoding: .utf8) ?? ""
        logger.debug("[KeyParse] KDF: '\(kdfName)'")
        
        // KDF options
        let kdfOptions = try readString()
        logger.debug("[KeyParse] KDF options: \(kdfOptions.count) bytes")
        
        // Number of keys (usually 1)
        let numKeys = try readUInt32()
        logger.debug("[KeyParse] Number of keys: \(numKeys)")
        guard numKeys == 1 else {
            throw SSHSessionError.invalidKey("Multiple keys in file not supported")
        }
        
        // Public key (we skip this, will extract from private section)
        let publicKeyBlob = try readString()
        logger.debug("[KeyParse] Public key blob: \(publicKeyBlob.count) bytes")
        
        // Private key section (may be encrypted)
        // IMPORTANT: Create a new Data to reset indices to 0
        let privateData = Data(try readString())
        logger.debug("[KeyParse] Private data: \(privateData.count) bytes")
        
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
        guard let keyType = String(data: keyTypeData, encoding: .utf8) else {
            throw SSHSessionError.invalidKey("Invalid key type encoding")
        }
        
        logger.debug("[KeyParse] Parsed key type: '\(keyType)'")
        
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
    
    /// Set up the tmux session manager for control mode.
    /// Ghostty's native tmux viewer handles DCS 1000p detection, protocol parsing,
    /// and pane output routing internally. The session manager coordinates iOS-specific
    /// UI concerns: surface management, split trees, window picker, detach on background.
    ///
    /// Data flow with Ghostty's native tmux:
    /// SSH → SSHSession.handleReceivedData → delegate.didReceiveData → Ghostty.writeOutput
    ///   → VT parser detects DCS 1000p → tmux viewer activates
    ///   → viewer parses %output/%layout-change/etc → routes to per-pane Terminals
    ///   → TMUX_STATE_CHANGED action → NotificationCenter → TmuxSessionManager
    private func setupTmuxSessionManager() {
        logger.info("Setting up tmux session manager (native Ghostty tmux)")
        
        let manager = TmuxSessionManager()
        tmuxSessionManager = manager
        
        // Provide the write function for fire-and-forget tmux commands.
        // In control mode, commands written to stdin go directly to tmux.
        manager.setupWithDirectWrite { [weak self] command in
            Task { @MainActor in
                self?.writeControlCommand(command)
            }
        }
        
        // Observe Ghostty's native tmux notifications.
        // These fire when Ghostty's internal tmux viewer detects state changes
        // via the TMUX_STATE_CHANGED and TMUX_EXIT action callbacks.
        observeTmuxNotifications()
    }
    
    /// Register for Ghostty's tmux state notifications.
    /// TMUX_STATE_CHANGED fires when the tmux viewer activates or pane state changes.
    /// TMUX_EXIT fires when the tmux control mode session ends.
    private func observeTmuxNotifications() {
        // Remove any existing observers first (idempotent)
        removeTmuxNotificationObservers()
        
        let stateObserver = NotificationCenter.default.addObserver(
            forName: .tmuxStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else {
                return
            }
            
            let windowCount = notification.userInfo?["windowCount"] as? UInt ?? 0
            let paneCount = notification.userInfo?["paneCount"] as? UInt ?? 0
            
            logger.info("tmux state changed: \(windowCount) windows, \(paneCount) panes, current state=\(self.controlModeState)")
            
            if self.controlModeState == .inactive {
                // First state change — control mode just activated
                self.controlModeState = .active
                logger.info("Control mode activated via TMUX_STATE_CHANGED")
                self.tmuxSessionManager?.controlModeActivated()
                // NOTE: Do NOT activate pane or flush input here.
                // Wait for TMUX_READY which fires after the viewer's command queue drains.
                // Activating here would cause user input to interleave with viewer commands.
            }
            
            // Subsequent state changes update pane/window info
            self.tmuxSessionManager?.handleTmuxStateChanged(
                windowCount: Int(windowCount),
                paneCount: Int(paneCount)
            )
            
            // If viewerReady was already set (subsequent state changes after initial ready),
            // activate pane for any new panes that may have appeared.
            if self.viewerReady {
                self.activateFirstTmuxPane()
            }
        }
        
        let exitObserver = NotificationCenter.default.addObserver(
            forName: .tmuxExited,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            
            logger.info("tmux control mode exited via TMUX_EXIT")
            self.controlModeState = .inactive
            self.tmuxPaneActivated = false
            self.activeTmuxPaneId = nil
            self.viewerReady = false
            self.tmuxSessionManager?.controlModeExited(reason: "Ghostty tmux viewer exited")
        }
        
        let readyObserver = NotificationCenter.default.addObserver(
            forName: .tmuxReady,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            
            logger.info("tmux viewer startup complete (TMUX_READY), safe to send user input")
            self.viewerReady = true
            
            // NOW it's safe to activate the first pane and flush pending input.
            // The viewer's command queue has drained — no risk of interleaving.
            self.activateFirstTmuxPane()
        }
        
        tmuxNotificationObservers = [stateObserver, exitObserver, readyObserver]
    }
    
    /// Remove tmux notification observers
    private func removeTmuxNotificationObservers() {
        for observer in tmuxNotificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        tmuxNotificationObservers.removeAll()
    }
    
    /// Flush pending input queue after control mode activates and pane is set.
    /// Routes through Ghostty's sendText() so user input gets Zig-side send-keys wrapping.
    /// Falls back to writeFromGhostty() for non-text data.
    private func flushPendingInput() {
        guard !pendingInputQueue.isEmpty else { return }
        
        logger.info("Flushing \(pendingInputQueue.count) queued input chunks")
        tmuxSessionManager?.clearPendingInputDisplay()
        
        for data in pendingInputQueue {
            // Try to route through Ghostty for proper send-keys wrapping
            if let text = String(data: data, encoding: .utf8), let surface = ghosttySurface {
                surface.sendText(text)
            } else {
                // Non-text data or no surface — write directly (best effort)
                writeFromGhostty(data)
            }
        }
        pendingInputQueue.removeAll()
    }
    
    /// Switch the Metal renderer to display the first tmux pane's Terminal.
    ///
    /// When Ghostty enters tmux control mode, the viewer creates per-pane Terminal
    /// instances and routes %output data to them. But the renderer still points at
    /// the main (empty) Terminal. We must call ghostty_surface_tmux_set_active_pane()
    /// to swap the renderer's terminal pointer to the pane Terminal.
    ///
    /// This is called from two places:
    /// 1. The TMUX_STATE_CHANGED notification handler (normal path)
    /// 2. The ghosttySurface didSet (fallback for race condition where the
    ///    notification fired before the surface was wired)
    private func activateFirstTmuxPane() {
        guard !tmuxPaneActivated else {
            logger.debug("tmux pane already activated, skipping")
            return
        }
        
        guard let surface = ghosttySurface else {
            logger.info("activateFirstTmuxPane: ghosttySurface is nil, will retry when set")
            return
        }
        
        let paneCount = surface.tmuxPaneCount
        logger.info("activateFirstTmuxPane: paneCount=\(paneCount)")
        
        guard paneCount > 0 else {
            logger.info("activateFirstTmuxPane: no panes yet, will retry on next state change")
            return
        }
        
        let paneIds = surface.getTmuxPaneIds()
        logger.info("activateFirstTmuxPane: paneIds=\(paneIds)")
        
        guard let firstPaneId = paneIds.first else {
            logger.warning("activateFirstTmuxPane: getTmuxPaneIds returned empty despite paneCount=\(paneCount)")
            return
        }
        
        let success = surface.setActiveTmuxPane(firstPaneId)
        logger.info("activateFirstTmuxPane: set active pane to %\(firstPaneId): \(success)")
        
        if success {
            tmuxPaneActivated = true
            activeTmuxPaneId = firstPaneId
            logger.info("activateFirstTmuxPane: activeTmuxPaneId set to %\(firstPaneId)")
            
            // Now that we have a pane ID, flush any queued input with send-keys wrapping.
            // This must happen AFTER activeTmuxPaneId is set so writeFromGhostty()
            // correctly wraps user input instead of sending raw bytes to tmux stdin.
            flushPendingInput()
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
        if let data = envSetup.data(using: .utf8) {
            write(data)
        }
    }
    
    /// Auto-attach to or create a tmux session.
    ///
    /// If the user set a custom `tmuxSessionName`, uses it directly.
    /// Otherwise, queries existing sessions to find an unattached `geistty-N`
    /// session to reattach to, or creates the next `geistty-<N+1>`.
    ///
    /// The query happens as a raw shell command before entering control mode:
    /// 1. Send `tmux list-sessions ...` to the shell
    /// 2. Intercept the response in `handleReceivedData()` (via `sessionDiscoveryState`)
    /// 3. Parse the response with `TmuxSessionNameResolver`
    /// 4. Send `exec tmux -CC new-session -A -s <resolved-name>`
    private func attachToTmuxNow() {
        guard tmuxMode == .controlMode else { return }
        
        // If the user specified a custom session name, skip discovery
        if let customName = tmuxSessionName, !customName.isEmpty {
            logger.info("Using custom tmux session name: \(customName)")
            sendTmuxAttachCommand(sessionName: customName)
            return
        }
        
        // Begin session discovery: query existing sessions
        logger.info("Starting geistty-N session discovery")
        sessionDiscoveryState = .querying(buffer: "")
        let query = TmuxSessionNameResolver.queryCommand
        if let data = query.data(using: .utf8) {
            writeControlCommand(data)
        }
    }
    
    /// Send the actual tmux attach command after session name is resolved
    private func sendTmuxAttachCommand(sessionName: String) {
        // Use control mode (-CC) for proper scrollback access
        // exec replaces the shell with tmux
        // Shell-escape the session name to prevent command injection
        let escapedName = sessionName.replacingOccurrences(of: "'", with: "'\\''")
        let command = "exec tmux -CC new-session -A -s '\(escapedName)'\n"
        logger.info("Attaching to tmux in control mode: \(sessionName)")
        // Write directly to connection — don't go through self.write() which would queue it!
        if let data = command.data(using: .utf8) {
            writeControlCommand(data)
        }
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
    
    /// Resize the PTY
    func resize(cols: Int, rows: Int) {
        terminalCols = cols
        terminalRows = rows
        connection?.resizePTY(cols: cols, rows: rows)
    }
    
    /// Write user input data to the SSH channel.
    ///
    /// Called as a fallback from `TerminalContainerView.send(text:)` when no Ghostty
    /// surface is available. Normally, user input is routed through Ghostty's
    /// `ghostty_surface_text()` → `queueWrite()` → Zig send-keys wrapping →
    /// `writeFromGhostty()`, which handles tmux control mode automatically.
    ///
    /// This direct path does NOT apply tmux send-keys wrapping. In tmux control
    /// mode, data written here would be interpreted as raw tmux commands. This is
    /// acceptable because this path is only used when there's no surface (pre-
    /// connection, post-disconnect), and we queue the data for later anyway.
    func write(_ data: Data) {
        if let str = String(data: data, encoding: .utf8) {
            logger.debug("SSHSession.write: \(data.count) bytes: \(str.prefix(20))")
        }
        
        // Check connection health — if stale/dead, queue instead of sending
        if !connectionHealth.isHealthy {
            logger.debug("Connection unhealthy (\(String(describing: connectionHealth))), queueing \(data.count) bytes of input")
            pendingInputQueue.append(data)
            updatePendingInputDisplay()
            return
        }
        
        // If we're in control mode, queue the input. Without a Ghostty surface,
        // we can't apply send-keys wrapping, so raw data must not reach tmux stdin.
        // It will be flushed through Ghostty's path when the surface is ready.
        if tmuxMode == .controlMode && controlModeState.isActive {
            logger.info("write() in control mode without Ghostty path, queueing \(data.count) bytes")
            pendingInputQueue.append(data)
            updatePendingInputDisplay()
            return
        }
        
        // If we're in control mode but tmux isn't ready yet, queue the input.
        if tmuxMode == .controlMode && !controlModeState.isActive {
            logger.info("Control mode pending (state=\(controlModeState)), queueing \(data.count) bytes of input")
            pendingInputQueue.append(data)
            updatePendingInputDisplay()
            return
        }
        
        performWrite(data, originalData: data)
    }
    
    // MARK: - Ghostty write callback
    
    /// Write data from Ghostty's write_callback directly to SSH.
    ///
    /// Ghostty's External backend sends ALL outbound data through its write_callback.
    /// After the Zig-side send-keys routing (Termio.queueWrite → viewer.sendKeys),
    /// ALL data arriving here is already properly formatted:
    /// - Viewer commands: "list-windows\n", "capture-pane ...\n"
    /// - User input: "send-keys -H -t %2 6C 73 0D\n" (wrapped by Zig)
    ///
    /// The Swift side just passes everything through to SSH. No heuristics,
    /// no wrapping, no queueing needed.
    ///
    /// Connection health checks still apply — if the connection is dead, there's
    /// nowhere to send data regardless.
    func writeFromGhostty(_ data: Data) {
        // Connection health check still applies
        if !connectionHealth.isHealthy {
            logger.debug("Connection unhealthy, dropping Ghostty write of \(data.count) bytes")
            return
        }
        
        performWrite(data, originalData: data)
    }
    
    /// Perform the actual write with error handling
    /// - Parameters:
    ///   - command: The data to write (may be tmux-wrapped command)
    ///   - originalData: The original user input (for queueing on failure)
    private func performWrite(_ command: Data, originalData: Data) {
        guard let connection = connection else {
            logger.warning("⚠️ No connection for write, queueing")
            pendingInputQueue.append(originalData)
            updatePendingInputDisplay()
            return
        }
        
        Task {
            do {
                try await connection.writeAsync(command)
                // Success! If we were stale, NIOSSHConnection will mark us healthy
            } catch {
                // Write failed - queue the ORIGINAL data (not the tmux command)
                logger.error("❌ Write failed: \(error.localizedDescription) - queueing input")
                await MainActor.run {
                    self.pendingInputQueue.append(originalData)
                    self.updatePendingInputDisplay()
                    
                    // Update health state if not already dead
                    if self.connectionHealth.isHealthy || self.connectionHealth != .dead(reason: error.localizedDescription) {
                        self.connectionHealth = .dead(reason: error.localizedDescription)
                        self.delegate?.sshSession(self, healthDidChange: self.connectionHealth)
                    }
                }
            }
        }
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
    
    /// Write a control command (not user input) to the connection
    /// Control commands don't get queued on failure - they're ephemeral
    /// - Parameter command: The command data to write
    private func writeControlCommand(_ command: Data) {
        guard let connection = connection else {
            logger.warning("⚠️ writeControlCommand called but no connection")
            return
        }
        
        // Log what we're sending
        if let str = String(data: command, encoding: .utf8) {
            logger.info("📤 writeControlCommand: \(str.prefix(100))")
        }
        
        Task {
            do {
                try await connection.writeAsync(command)
                logger.debug("📤 writeControlCommand completed successfully")
            } catch {
                // Control commands failing is expected if connection is dead
                // The connection will handle marking itself as dead
                logger.warning("⚠️ Control command write failed: \(error.localizedDescription)")
            }
        }
    }
    
    /// Convenience overload for string commands
    private func writeControlCommand(_ command: String) {
        logger.info("📤 writeControlCommand(String): \(command.prefix(100))")
        guard let data = command.data(using: .utf8) else { return }
        writeControlCommand(data)
    }
    
    /// Disconnect the session
    func disconnect() {
        controlModeState = .inactive
        tmuxPaneActivated = false
        activeTmuxPaneId = nil
        viewerReady = false
        sessionDiscoveryState = .idle
        pendingInputQueue.removeAll()
        removeTmuxNotificationObservers()
        
        // Send clean detach before tearing down, so tmux session survives
        // on the server and can be reattached later (like iTerm2's behavior)
        tmuxSessionManager?.detach()
        
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
    /// Sends a clean detach to tmux so the session is immediately available
    /// for reattach when the app returns to foreground. Without this, the
    /// tmux session would show as "attached" to a dead client until the
    /// TCP keepalive timeout expires.
    func appWillResignActive() {
        guard controlModeState.isActive else { return }
        logger.info("App resigning active, sending clean detach to tmux")
        tmuxSessionManager?.detach()
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
        
        // If connection is alive, nothing to do — tmux session was detached
        // on background and will be reattached via reconnect flow
        if isConnectionAlive, controlModeState.isActive {
            logger.info("🔄 Connection alive, control mode active")
            return
        }
        
        // Connection is dead — attempt to reconnect if we have credentials
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
        controlModeState = .inactive
        tmuxPaneActivated = false
        activeTmuxPaneId = nil
        viewerReady = false
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
        
        // Re-setup tmux session manager (Ghostty handles tmux protocol natively)
        if tmuxMode == .controlMode {
            setupTmuxSessionManager()
        }
        
        // Re-attach to tmux session
        injectTerminalSetup()
    }
    
    // Internal method to handle received data, called from connection delegate
    fileprivate func handleReceivedData(_ data: Data) {
        #if DEBUG
        logger.debug("[recv] \(data.count)B state=\(self.controlModeState) tmux=\(String(describing: self.tmuxMode))")
        #endif
        
        // Session discovery: intercept tmux list-sessions response before control mode starts.
        // This runs as a raw shell command before `exec tmux -CC`, so the output arrives
        // as normal shell data. We accumulate it until we see the ---END--- sentinel.
        if case .querying(var buffer) = sessionDiscoveryState {
            if let str = String(data: data, encoding: .utf8) {
                buffer += str
                
                if TmuxSessionNameResolver.isResponseComplete(buffer) {
                    // Parse and resolve
                    let responseText = TmuxSessionNameResolver.extractResponse(from: buffer) ?? buffer
                    let sessions = TmuxSessionNameResolver.parseSessions(from: responseText)
                    let resolvedName = TmuxSessionNameResolver.resolve(from: sessions)
                    
                    logger.info("Session discovery complete: found \(sessions.count) sessions, resolved to '\(resolvedName)'")
                    
                    // Done with discovery
                    sessionDiscoveryState = .idle
                    
                    // Now send the actual tmux attach command
                    sendTmuxAttachCommand(sessionName: resolvedName)
                } else {
                    // Still accumulating response
                    sessionDiscoveryState = .querying(buffer: buffer)
                }
            }
            return
        }
        
        // All data goes to Ghostty, which handles DCS 1000p detection and tmux
        // control mode protocol parsing natively via its internal tmux viewer.
        // No gateway routing or DCS filtering needed on the Swift side.
        if let delegate = delegate {
            logger.info("📥 Forwarding \(data.count)B to delegate")
            delegate.sshSession(self, didReceiveData: data)
        } else {
            // No delegate yet — buffer for flush when delegate is set.
            // This happens in the pre-connected session flow between connect()
            // returning and useExistingSession() setting the delegate.
            logger.info("📥 Buffering \(data.count)B (no delegate yet, \(earlyReceiveBuffer.count) chunks queued)")
            earlyReceiveBuffer.append(data)
        }
    }
    
    // MARK: - Test Helpers
    
    #if DEBUG
    /// Set control mode state for testing. Only available in DEBUG builds.
    func setControlModeStateForTesting(_ state: ControlModeState) {
        controlModeState = state
    }
    
    /// Set active tmux pane ID for testing. Only available in DEBUG builds.
    func setActiveTmuxPaneIdForTesting(_ paneId: Int?) {
        activeTmuxPaneId = paneId
    }
    
    /// Set tmux mode for testing. Only available in DEBUG builds.
    func setTmuxModeForTesting(_ mode: TmuxMode) {
        tmuxMode = mode
    }
    
    /// Set connection health for testing. Only available in DEBUG builds.
    func setConnectionHealthForTesting(_ health: ConnectionHealth) {
        connectionHealth = health
    }
    #endif
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
            
            // If connection became healthy again and we have pending input, flush it.
            // Route through Ghostty for proper send-keys wrapping in tmux mode.
            if health.isHealthy && !self.pendingInputQueue.isEmpty {
                logger.info("Connection healthy, flushing \(self.pendingInputQueue.count) queued inputs")
                self.flushPendingInput()
            }
        }
    }
}

