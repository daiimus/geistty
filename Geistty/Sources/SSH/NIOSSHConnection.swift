//
//  NIOSSHConnection.swift
//  Geistty
//
//  SSH connection implementation using SwiftNIO-SSH with Network.framework
//  Provides native iOS network path monitoring and connection viability tracking
//

import Foundation
import Network
import NIOCore
import NIOTransportServices
import NIOSSH
import os.log

private let logger = Logger(subsystem: "com.geistty", category: "NIOSSHConnection")

// MARK: - Connection Health

/// Connection health state for tracking network viability
public enum ConnectionHealth: Equatable, Sendable {
    case healthy
    case stale(since: Date)
    case dead(reason: String)
    
    public var isHealthy: Bool {
        if case .healthy = self { return true }
        return false
    }
}

// MARK: - Delegate Protocol

/// Delegate protocol for SSH connection events
@MainActor
public protocol NIOSSHConnectionDelegate: AnyObject {
    func connectionDidConnect(_ connection: NIOSSHConnection)
    func connectionDidAuthenticate(_ connection: NIOSSHConnection)
    func connectionDidFailAuthentication(_ connection: NIOSSHConnection, error: Error)
    func connectionDidClose(_ connection: NIOSSHConnection, error: Error?)
    func connection(_ connection: NIOSSHConnection, didReceiveData data: Data)
    func connection(_ connection: NIOSSHConnection, healthDidChange health: ConnectionHealth)
}

// MARK: - Errors

/// Errors that can occur during SSH operations
public enum NIOSSHError: LocalizedError {
    case notConnected
    case alreadyConnected
    case connectionFailed(String)
    case authenticationFailed(String)
    case channelError(String)
    case sessionError(String)
    case timeout
    case networkUnavailable
    
    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to server"
        case .alreadyConnected: return "Already connected"
        case .connectionFailed(let r): return "Connection failed: \(r)"
        case .authenticationFailed(let r): return "Auth failed: \(r)"
        case .channelError(let r): return "Channel error: \(r)"
        case .sessionError(let r): return "Session error: \(r)"
        case .timeout: return "Operation timed out"
        case .networkUnavailable: return "Network unavailable"
        }
    }
}

/// SSH Connection state
public enum NIOSSHState: Sendable {
    case disconnected
    case connecting
    case connected  // TCP connected, SSH handshake done
    case authenticated
    case channelOpen
}

// MARK: - Authentication

/// SSH credential for authentication
public enum SSHAuthMethod: Sendable {
    case password(String)
    case publicKey(privateKey: NIOSSHPrivateKey, publicKey: NIOSSHPublicKey? = nil)
}

// MARK: - Client Configuration

/// SSH client configuration for authentication
final class SSHClientConfiguration: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let authMethod: SSHAuthMethod
    private let _lock = NSLock()
    private var _authAttempted = false
    
    init(username: String, authMethod: SSHAuthMethod) {
        self.username = username
        self.authMethod = authMethod
    }
    
    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        // Only try once to avoid infinite loops.
        // Thread-safe: nextAuthenticationType is called from NIO event loop threads.
        let alreadyAttempted: Bool = _lock.withLock {
            let was = _authAttempted
            _authAttempted = true
            return was
        }
        guard !alreadyAttempted else {
            logger.error("Authentication already attempted, failing")
            nextChallengePromise.succeed(nil)
            return
        }
        
        switch authMethod {
        case .password(let password):
            if availableMethods.contains(.password) {
                logger.info("🔐 Attempting password authentication")
                nextChallengePromise.succeed(.init(
                    username: username,
                    serviceName: "ssh-connection",
                    offer: .password(.init(password: password))
                ))
            } else {
                logger.error("🔐 Password auth not available, methods: \(String(describing: availableMethods))")
                nextChallengePromise.succeed(nil)
            }
            
        case .publicKey(let privateKey, _):
            if availableMethods.contains(.publicKey) {
                logger.info("🔐 Attempting public key authentication")
                nextChallengePromise.succeed(.init(
                    username: username,
                    serviceName: "ssh-connection",
                    offer: .privateKey(.init(privateKey: privateKey))
                ))
            } else {
                logger.error("🔐 Public key auth not available, methods: \(String(describing: availableMethods))")
                nextChallengePromise.succeed(nil)
            }
        }
    }
}

// MARK: - Server Authentication (Host Key Verification)

/// Host key verifier using TOFU (Trust On First Use) model.
///
/// # Security Note
/// This implementation accepts all host keys on first connection without verification
/// against a known_hosts file. This is a known limitation.
///
/// ## Why TOFU?
/// - SwiftNIO-SSH doesn't provide built-in known_hosts parsing
/// - Implementing full OpenSSH known_hosts format is complex (hashed hosts, wildcards, etc.)
/// - Most mobile SSH apps (Termius, Prompt) also use TOFU or simpler verification
///
/// ## Future Improvements
/// - Store host keys in Keychain after first connection
/// - Warn user if host key changes (potential MITM)
/// - Optional: per-connection fingerprint display for manual verification
///
/// ## Risk Mitigation
/// - iOS sandboxing limits attack surface
/// - Credentials are stored in Secure Enclave (when available)
/// - TLS-level certificate pinning is not applicable to SSH
final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        // Accept all host keys (TOFU model) - see class documentation for rationale
        logger.info("🔑 Accepting host key (TOFU): \(String(describing: hostKey))")
        validationCompletePromise.succeed(())
    }
}

// MARK: - Channel Handler

/// Handler for SSH channel data
final class SSHChannelDataHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData
    
    private let onData: @Sendable (Data) -> Void
    private let onClose: @Sendable (Error?) -> Void
    
    init(onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (Error?) -> Void) {
        self.onData = onData
        self.onClose = onClose
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        
        // Process both stdout (.channel) and stderr (.stdErr).
        // SSH multiplexes both over the same interactive channel — terminal apps
        // display them inline (stderr is not a separate stream in a PTY session).
        switch channelData.type {
        case .channel, .stdErr:
            break
        default:
            return
        }
        
        // Convert IOData to Data
        switch channelData.data {
        case .byteBuffer(var buffer):
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                onData(Data(bytes))
            }
        case .fileRegion:
            // File regions not expected in shell sessions
            break
        }
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        logger.info("🔌 SSH channel inactive")
        onClose(nil)
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("🔌 SSH channel error: \(error.localizedDescription)")
        onClose(error)
        context.close(promise: nil)
    }
}

// MARK: - NIOSSHConnection

/// Manages an SSH connection using SwiftNIO-SSH with Network.framework
@MainActor
public class NIOSSHConnection {
    // Connection parameters
    public let host: String
    public let port: Int
    public let username: String
    
    // State
    public private(set) var state: NIOSSHState = .disconnected
    public private(set) var health: ConnectionHealth = .healthy
    
    // Delegate
    public weak var delegate: NIOSSHConnectionDelegate?
    
    // Terminal dimensions
    public var cols: Int = 80
    public var rows: Int = 24
    
    // NIO components
    private var eventLoopGroup: NIOTSEventLoopGroup?
    private var channel: Channel?
    private var sshChannel: Channel?
    
    // Network path monitoring
    private var pathMonitor: NWPathMonitor?
    private var lastKnownPath: NWPath?

    
    // MARK: - Initialization
    
    public init(host: String, port: Int = 22, username: String) {
        self.host = host
        self.port = port
        self.username = username
        
        setupPathMonitor()
    }
    
    deinit {
        pathMonitor?.cancel()
    }
    
    // MARK: - Network Path Monitoring
    
    private func setupPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.handlePathUpdate(path)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.geistty.pathmonitor"))
        pathMonitor = monitor
    }
    
    private func handlePathUpdate(_ path: NWPath) {
        let previousPath = lastKnownPath
        lastKnownPath = path
        
        logger.info("📡 Network path update: status=\(String(describing: path.status)) interfaces=\(path.availableInterfaces.map { $0.name })")
        
        // Check if we lost network
        if path.status != .satisfied {
            if health.isHealthy && state == .channelOpen {
                logger.warning("📡 Network path unsatisfied - marking connection stale")
                health = .stale(since: Date())
                delegate?.connection(self, healthDidChange: health)
            }
            return
        }
        
        // Network is back - check if it was down before
        if let previous = previousPath, previous.status != .satisfied {
            logger.info("📡 Network restored")
            // Don't immediately mark healthy - let SSH keepalive confirm
            // For now, we stay in stale state until we get data or reconnect
        }
        
        // Check for interface change (e.g., WiFi to cellular)
        if let previous = previousPath,
           previous.status == .satisfied,
           path.status == .satisfied {
            let previousInterfaces = Set(previous.availableInterfaces.map { $0.name })
            let currentInterfaces = Set(path.availableInterfaces.map { $0.name })
            
            if previousInterfaces != currentInterfaces {
                logger.warning("📡 Network interface changed - connection may be stale")
                if health.isHealthy && state == .channelOpen {
                    health = .stale(since: Date())
                    delegate?.connection(self, healthDidChange: health)
                }
            }
        }
    }
    
    // MARK: - Connection
    
    /// Connect to the SSH server and perform handshake with password authentication
    public func connect(password: String) async throws {
        try await connect(authMethod: .password(password))
    }
    
    /// Connect to the SSH server with a specific authentication method
    public func connect(authMethod: SSHAuthMethod) async throws {
        logger.info("🔗 NIOSSHConnection.connect() - host=\(self.host) port=\(self.port)")
        
        guard state == .disconnected else {
            throw NIOSSHError.alreadyConnected
        }
        
        // Check network availability
        if let path = lastKnownPath, path.status != .satisfied {
            throw NIOSSHError.networkUnavailable
        }
        
        state = .connecting
        
        // Create event loop group using Network.framework (NIOTransportServices)
        let group = NIOTSEventLoopGroup()
        self.eventLoopGroup = group
        
        // Capture connection parameters for closures
        let connectionHost = self.host
        let connectionPort = self.port
        
        do {
            // Configure SSH client
            let clientConfig = SSHClientConfiguration(username: username, authMethod: authMethod)
            let serverAuthDelegate = AcceptAllHostKeysDelegate()
            
            // Bootstrap the connection
            let bootstrap = NIOTSConnectionBootstrap(group: group)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelInitializer { channel in
                    channel.pipeline.addHandlers([
                        NIOSSHHandler(
                            role: .client(.init(
                                userAuthDelegate: clientConfig,
                                serverAuthDelegate: serverAuthDelegate
                            )),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: nil
                        )
                    ])
                }
            
            // Connect
            logger.info("🔗 Connecting to \(connectionHost):\(connectionPort)...")
            let channel = try await bootstrap.connect(host: connectionHost, port: connectionPort).get()
            self.channel = channel
            
            logger.info("🔗 TCP connected, SSH handshake in progress...")
            
            // Wait for SSH handshake and authentication
            // The NIOSSHHandler will call our auth delegate
            // We need to wait for the channel to be ready
            
            // Create a child channel for the shell
            try await openShellChannel(on: channel)
            
            state = .channelOpen
            health = .healthy
            
            logger.info("🔗 Connection established!")
            delegate?.connectionDidConnect(self)
            delegate?.connectionDidAuthenticate(self)
            
        } catch {
            logger.error("🔗 Connection failed: \(error.localizedDescription)")
            state = .disconnected
            try? await eventLoopGroup?.shutdownGracefully()
            eventLoopGroup = nil
            throw NIOSSHError.connectionFailed(error.localizedDescription)
        }
    }
    
    // MARK: - Shell Channel
    
    private func openShellChannel(on channel: Channel) async throws {
        logger.info("🖥️ Opening shell channel...")
        
        let sshHandler = try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
        
        // Create child channel for the shell session
        let channelPromise = channel.eventLoop.makePromise(of: Channel.self)
        sshHandler.createChannel(channelPromise) { childChannel, channelType in
            guard channelType == .session else {
                return childChannel.eventLoop.makeFailedFuture(NIOSSHError.channelError("Unexpected channel type"))
            }
            
            // Add our data handler
            return childChannel.pipeline.addHandlers([
                SSHChannelDataHandler(
                    onData: { [weak self] data in
                        Task { @MainActor [weak self] in
                            guard let self = self else { return }
                            // Received data means connection is healthy
                            if !self.health.isHealthy {
                                self.health = .healthy
                                self.delegate?.connection(self, healthDidChange: .healthy)
                            }
                            self.delegate?.connection(self, didReceiveData: data)
                        }
                    },
                    onClose: { [weak self] error in
                        Task { @MainActor [weak self] in
                            self?.handleChannelClose(error: error)
                        }
                    }
                )
            ])
        }
        
        let childChannel = try await channelPromise.futureResult.get()
        
        self.sshChannel = childChannel
        
        // Capture PTY dimensions for closures
        let ptyCols = self.cols
        let ptyRows = self.rows
        
        // Request PTY
        logger.info("🖥️ Requesting PTY (cols=\(ptyCols) rows=\(ptyRows))...")
        let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: ptyCols,
            terminalRowHeight: ptyRows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        
        try await childChannel.triggerUserOutboundEvent(ptyRequest).get()
        logger.info("🖥️ PTY allocated")
        
        // Request shell
        logger.info("🖥️ Starting shell...")
        let shellRequest = SSHChannelRequestEvent.ShellRequest(wantReply: true)
        try await childChannel.triggerUserOutboundEvent(shellRequest).get()
        
        logger.info("🖥️ Shell started!")
    }
    
    private func handleChannelClose(error: Error?) {
        logger.info("🔌 Channel closed")
        sshChannel = nil
        
        if state != .disconnected {
            state = .disconnected
            health = .dead(reason: error?.localizedDescription ?? "Channel closed")
            delegate?.connectionDidClose(self, error: error)
        }
    }
    
    // MARK: - Write
    
    // Active write task — tracked so disconnect() can cancel in-flight writes
    private var activeWriteTask: Task<Void, Never>?
    
    /// Write data to the channel (fire-and-forget for backwards compatibility)
    public func write(_ data: Data) {
        activeWriteTask = Task {
            do {
                try await writeAsync(data)
            } catch {
                logger.warning("Write failed: \(error.localizedDescription)")
                // Mark connection as dead on write failure.
                // No MainActor.run needed — this class is already @MainActor.
                if self.health.isHealthy || self.health != .dead(reason: error.localizedDescription) {
                    self.health = .dead(reason: error.localizedDescription)
                    self.delegate?.connection(self, healthDidChange: self.health)
                }
            }
        }
    }
    
    /// Write data to the channel with async/await error handling
    /// - Parameter data: The data to write
    /// - Throws: NIOSSHError if write fails
    public func writeAsync(_ data: Data) async throws {
        guard state == .channelOpen, let channel = sshChannel else {
            logger.warning("⚠️ Write called but channel not open")
            throw NIOSSHError.notConnected
        }
        
        // If connection is stale, warn but still try
        if case .stale = health {
            logger.debug("⚠️ Writing to stale connection")
        }
        
        // Convert Data to ByteBuffer
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        
        let channelData = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        
        // Create promise to track write completion
        let promise = channel.eventLoop.makePromise(of: Void.self)
        channel.writeAndFlush(channelData, promise: promise)
        
        // Wait for write to complete or fail
        try await promise.futureResult.get()
        
        // Write succeeded - ensure health is marked healthy if it was stale
        if case .stale = health {
            await MainActor.run {
                logger.info("📡 Write succeeded on stale connection - marking healthy")
                self.health = .healthy
                self.delegate?.connection(self, healthDidChange: self.health)
            }
        }
    }
    
    /// Write string to channel (fire-and-forget for backwards compatibility)
    public func write(_ string: String) {
        if let data = string.data(using: .utf8) {
            write(data)
        }
    }
    
    /// Write string to channel with async/await error handling
    public func writeAsync(_ string: String) async throws {
        guard let data = string.data(using: .utf8) else {
            throw NIOSSHError.channelError("Invalid string encoding")
        }
        try await writeAsync(data)
    }
    
    // MARK: - PTY Resize
    
    /// Resize the PTY
    public func resizePTY(cols: Int, rows: Int) {
        // Always update stored dimensions, even if we can't send yet.
        // This mirrors Ghostty's External.zig pattern: internal state is updated
        // unconditionally, then the callback/channel is invoked if available.
        self.cols = cols
        self.rows = rows
        
        guard let channel = sshChannel else { return }
        
        let windowChange = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )
        
        channel.triggerUserOutboundEvent(windowChange, promise: nil)
    }
    
    // MARK: - Disconnect
    
    /// Disconnect from the server
    public func disconnect() {
        logger.info("Disconnecting...")
        
        // Cancel any in-flight write task
        activeWriteTask?.cancel()
        activeWriteTask = nil
        
        // Close channels
        sshChannel?.close(promise: nil)
        sshChannel = nil
        
        channel?.close(promise: nil)
        channel = nil
        
        // Shutdown event loop
        eventLoopGroup?.shutdownGracefully { _ in }
        eventLoopGroup = nil
        
        state = .disconnected
        delegate?.connectionDidClose(self, error: nil)
    }
    
    // MARK: - Health Management
    
    /// Mark the connection as healthy (e.g., after receiving data)
    public func markHealthy() {
        if !health.isHealthy {
            health = .healthy
            delegate?.connection(self, healthDidChange: health)
        }
    }
    
    /// Mark the connection as stale (e.g., after network event)
    public func markStale(reason: String? = nil) {
        if health.isHealthy {
            health = .stale(since: Date())
            delegate?.connection(self, healthDidChange: health)
        }
    }
    
    /// Mark the connection as dead
    public func markDead(reason: String) {
        health = .dead(reason: reason)
        delegate?.connection(self, healthDidChange: health)
    }
}
