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
enum ConnectionHealth: Equatable, Sendable {
    case healthy
    case stale(since: Date)
    case dead(reason: String)
    
    var isHealthy: Bool {
        if case .healthy = self { return true }
        return false
    }
}

// MARK: - Delegate Protocol

/// Delegate protocol for SSH connection events
@MainActor
protocol NIOSSHConnectionDelegate: AnyObject {
    func connectionDidConnect(_ connection: NIOSSHConnection)
    func connectionDidAuthenticate(_ connection: NIOSSHConnection)
    func connectionDidFailAuthentication(_ connection: NIOSSHConnection, error: Error)
    func connectionDidClose(_ connection: NIOSSHConnection, error: Error?)
    func connection(_ connection: NIOSSHConnection, didReceiveData data: Data)
    func connection(_ connection: NIOSSHConnection, healthDidChange health: ConnectionHealth)
}

// MARK: - Errors

/// Errors that can occur during SSH operations
enum NIOSSHError: LocalizedError {
    case notConnected
    case alreadyConnected
    case connectionFailed(String)
    case authenticationFailed(String)
    case channelError(String)
    case sessionError(String)
    case timeout
    case networkUnavailable
    case hostKeyMismatch(host: String, port: Int, expected: String, actual: String)
    
    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to server"
        case .alreadyConnected: return "Already connected"
        case .connectionFailed(let r): return "Connection failed: \(r)"
        case .authenticationFailed(let r): return "Auth failed: \(r)"
        case .channelError(let r): return "Channel error: \(r)"
        case .sessionError(let r): return "Session error: \(r)"
        case .timeout: return "Operation timed out"
        case .networkUnavailable: return "Network unavailable"
        case .hostKeyMismatch(let host, let port, _, _):
            return "WARNING: Host key for \(host):\(port) has changed. This could indicate a man-in-the-middle attack. Connection refused."
        }
    }
}

/// SSH Connection state
enum NIOSSHState: Sendable {
    case disconnected
    case connecting
    case connected  // TCP connected, SSH handshake done
    case authenticated
    case channelOpen
}

// MARK: - Authentication

/// SSH credential for authentication
enum SSHAuthMethod: Sendable {
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

/// Host key verifier using TOFU (Trust On First Use) with Keychain storage.
///
/// On first connection to a host, the server's public key is stored in the Keychain.
/// On subsequent connections, the presented key is compared against the stored key.
/// If the key has changed, the connection is rejected with `hostKeyMismatch` —
/// this is the critical security property that detects potential MITM attacks.
///
/// Stored as OpenSSH public key strings (e.g. "ssh-ed25519 AAAA...") keyed by
/// host:port in the Keychain under account "host-key:<host>:<port>".
final class TOFUHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let host: String
    private let port: Int
    
    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
    
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presentedKeyString = String(openSSHPublicKey: hostKey)
        
        do {
            let storedKeyString = try KeychainManager.shared.getHostKey(for: host, port: port)
            
            if storedKeyString == presentedKeyString {
                // Key matches stored key — trusted
                logger.debug("Host key verified for \(self.host):\(self.port)")
                validationCompletePromise.succeed(())
            } else {
                // Key CHANGED — potential MITM. Fail closed.
                logger.error("HOST KEY MISMATCH for \(self.host):\(self.port) — possible MITM attack. Stored key type differs from presented key.")
                validationCompletePromise.fail(
                    NIOSSHError.hostKeyMismatch(
                        host: host,
                        port: port,
                        expected: storedKeyString,
                        actual: presentedKeyString
                    )
                )
            }
        } catch KeychainError.itemNotFound {
            // First connection — trust and store
            logger.info("First connection to \(self.host):\(self.port) — storing host key (TOFU)")
            do {
                try KeychainManager.shared.saveHostKey(presentedKeyString, for: host, port: port)
            } catch {
                // #55: Save failure breaks TOFU guarantee — the key won't be
                // verified on next connection. Fail-closed to prevent silent
                // downgrade to accept-all behavior.
                logger.error("Failed to store host key for \(self.host):\(self.port): \(error.localizedDescription) — rejecting connection (TOFU broken)")
                validationCompletePromise.fail(error)
                return
            }
            validationCompletePromise.succeed(())
        } catch {
            // Keychain error — distinguish security-critical failures from transient glitches.
            // errSecInteractionNotAllowed means the device is locked and data protection
            // prevents Keychain access. An attacker could exploit this window to present
            // a different key, so we must reject rather than silently accept.
            if case KeychainError.unexpectedStatus(let status) = error,
               status == errSecInteractionNotAllowed {
                logger.error("Keychain locked during host key verification for \(self.host):\(self.port) — rejecting connection (device locked)")
                validationCompletePromise.fail(error)
                return
            }
            
            // #55: ALL Keychain errors must fail-closed. An attacker could
            // exploit any transient Keychain failure window to present a
            // different key. Reject the connection and let the user retry.
            logger.error("Keychain error during host key verification for \(self.host):\(self.port): \(error.localizedDescription) — rejecting connection")
            validationCompletePromise.fail(error)
        }
    }
}

// Archived: AcceptAllHostKeysDelegate replaced by TOFUHostKeyDelegate (issue #23).
// The old delegate unconditionally accepted all host keys with no storage or verification.
// See git history for the original implementation.

// MARK: - Channel Handler

/// Handler for SSH channel data
final class SSHChannelDataHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData
    
    private let onData: @Sendable (Data) -> Void
    private let onClose: @Sendable (Error?) -> Void
    /// #63: Guard against double onClose callback. NIO calls errorCaught →
    /// channelInactive sequentially, which would fire onClose twice.
    private var closeCalled = false
    
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
        guard !closeCalled else { return }
        closeCalled = true
        logger.info("🔌 SSH channel inactive")
        onClose(nil)
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("🔌 SSH channel error: \(error.localizedDescription)")
        if !closeCalled {
            closeCalled = true
            onClose(error)
        }
        context.close(promise: nil)
    }
}

// MARK: - NIOSSHConnection

/// Manages an SSH connection using SwiftNIO-SSH with Network.framework
@MainActor
class NIOSSHConnection {
    // Connection parameters
    let host: String
    let port: Int
    let username: String
    
    // State
    private(set) var state: NIOSSHState = .disconnected
    private(set) var health: ConnectionHealth = .healthy
    
    // Delegate
    weak var delegate: NIOSSHConnectionDelegate?
    
    // Terminal dimensions
    var cols: Int = 80
    var rows: Int = 24
    
    /// Connection timeout in seconds. Defaults to 15s for initial connections.
    /// Reconnect code sets this to 5s for faster failure detection.
    var connectionTimeoutSeconds: UInt64 = 15
    
    // NIO components
    private var eventLoopGroup: NIOTSEventLoopGroup?
    private var channel: Channel?
    private var sshChannel: Channel?
    
    // Network path monitoring
    private var pathMonitor: NWPathMonitor?
    private var lastKnownPath: NWPath?

    
    // MARK: - Initialization
    
    init(host: String, port: Int = 22, username: String) {
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
    func connect(password: String) async throws {
        try await connect(authMethod: .password(password))
    }
    
    /// Connect to the SSH server with a specific authentication method
    func connect(authMethod: SSHAuthMethod) async throws {
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
            let serverAuthDelegate = TOFUHostKeyDelegate(host: connectionHost, port: connectionPort)
            
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
            
            // Connect with timeout — bootstrap.connect can hang for 75s+ on unreachable hosts.
            // Use a task group race: the real connection vs a sleep-based timeout.
            //
            // IMPORTANT: NIO's bootstrap.connect() wraps an EventLoopFuture and is NOT
            // cancellation-cooperative. When the timeout wins the race:
            //   1. group.cancelAll() is called
            //   2. The connect task ignores cancellation (NIO future still resolves)
            //   3. The Channel is created but its result is discarded by the task group
            //   4. The Channel leaks until the EventLoopGroup shuts down
            //
            // To prevent this, we capture any successfully-created channel and close it
            // if the timeout won.
            logger.info("🔗 Connecting to \(connectionHost):\(connectionPort) (timeout=\(self.connectionTimeoutSeconds)s)...")
            let timeoutSeconds = self.connectionTimeoutSeconds
            
            // Sendable box to capture the channel from the connect task
            // so we can close it if the timeout wins
            final class ChannelBox: @unchecked Sendable {
                private let lock = NSLock()
                private var _channel: Channel?
                
                var channel: Channel? {
                    lock.lock()
                    defer { lock.unlock() }
                    return _channel
                }
                
                func set(_ ch: Channel) {
                    lock.lock()
                    defer { lock.unlock() }
                    _channel = ch
                }
            }
            let channelBox = ChannelBox()
            
            let channel: Channel
            do {
                channel = try await withThrowingTaskGroup(of: Channel.self) { group in
                    group.addTask {
                        let ch = try await bootstrap.connect(host: connectionHost, port: connectionPort).get()
                        channelBox.set(ch)
                        return ch
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                        throw NIOSSHError.timeout
                    }
                    // First task to complete wins; cancel the other
                    let result = try await group.next()!
                    group.cancelAll()
                    return result
                }
            } catch {
                // If the timeout won, the connect task may have created a channel
                // that was never returned. Close it to prevent leaking.
                if let orphanedChannel = channelBox.channel {
                    logger.warning("🔗 Closing orphaned channel after timeout")
                    try? await orphanedChannel.close()
                }
                throw error
            }
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
            
        } catch let error as NIOSSHError {
            // #61: Preserve NIOSSHError type (e.g., .hostKeyMismatch) so callers
            // can detect specific failure reasons instead of getting a generic string.
            logger.error("🔗 Connection failed: \(error.localizedDescription)")
            state = .disconnected
            try? await eventLoopGroup?.shutdownGracefully()
            eventLoopGroup = nil
            throw error
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
                        // Use DispatchQueue.main for strictly FIFO ordered delivery.
                        // The previous Task { @MainActor } created independent unstructured
                        // Tasks per NIO read. While Swift's MainActor executor is nominally
                        // FIFO, under high data rates (cmatrix, blightmud via tmux) the
                        // cooperative executor can interleave MainActor tasks with other
                        // work, potentially reordering SSH data chunks and corrupting the
                        // tmux control mode DCS byte stream.
                        //
                        // DispatchQueue.main is GCD's serial queue — blocks execute strictly
                        // in enqueue order with no exceptions. This matches the pattern used
                        // by Ghostty's own externalWriteCallback.
                        DispatchQueue.main.async { [weak self] in
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
    func write(_ data: Data) {
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
    func writeAsync(_ data: Data) async throws {
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
        
        // Write succeeded - ensure health is marked healthy if it was stale.
        // No MainActor.run needed — this class is already @MainActor.
        if case .stale = health {
            logger.info("📡 Write succeeded on stale connection - marking healthy")
            self.health = .healthy
            self.delegate?.connection(self, healthDidChange: self.health)
        }
    }
    
    /// Write string to channel (fire-and-forget for backwards compatibility)
    func write(_ string: String) {
        if let data = string.data(using: .utf8) {
            write(data)
        }
    }
    
    /// Write string to channel with async/await error handling
    func writeAsync(_ string: String) async throws {
        guard let data = string.data(using: .utf8) else {
            throw NIOSSHError.channelError("Invalid string encoding")
        }
        try await writeAsync(data)
    }
    
    // MARK: - PTY Resize
    
    /// Resize the PTY
    func resizePTY(cols: Int, rows: Int) {
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
    func disconnect() {
        // #60: Guard against duplicate disconnect calls
        guard state != .disconnected else { return }
        
        logger.info("Disconnecting...")
        
        // Cancel any in-flight write task
        activeWriteTask?.cancel()
        activeWriteTask = nil
        
        // Close channels
        sshChannel?.close(promise: nil)
        sshChannel = nil
        
        channel?.close(promise: nil)
        channel = nil
        
        // #60: Shutdown event loop — nil the reference inside the callback
        // to avoid racing with the async shutdown. NIOSSHConnection is @MainActor
        // so the nil assignment must be dispatched back to MainActor.
        eventLoopGroup?.shutdownGracefully { error in
            if let error = error {
                logger.warning("Event loop shutdown error: \(error.localizedDescription)")
            }
            Task { @MainActor [weak self] in
                self?.eventLoopGroup = nil
            }
        }
        
        state = .disconnected
        delegate?.connectionDidClose(self, error: nil)
    }
    
    // MARK: - Health Management
    
    /// Mark the connection as healthy (e.g., after receiving data)
    func markHealthy() {
        if !health.isHealthy {
            health = .healthy
            delegate?.connection(self, healthDidChange: health)
        }
    }
    
    /// Mark the connection as stale (e.g., after network event)
    func markStale(reason: String? = nil) {
        if health.isHealthy {
            health = .stale(since: Date())
            delegate?.connection(self, healthDidChange: health)
        }
    }
    
    /// Mark the connection as dead
    func markDead(reason: String) {
        health = .dead(reason: reason)
        delegate?.connection(self, healthDidChange: health)
    }
}
