//
//  SSHConnection.swift
//  Bodak
//
//  SSH connection implementation using libssh2 via CSSH
//

import Foundation
import os.log
@_implementationOnly import CSSH

private let logger = Logger(subsystem: "com.bodak", category: "SSHConnection")
private let sshTraceLogger = Logger(subsystem: "com.bodak", category: "libssh2")

// MARK: - libssh2 Trace Handler

/// Global trace handler callback for libssh2 debug output
/// This is called from C code, so it must be a global function
private func libssh2TraceHandler(
    _ session: OpaquePointer?,
    _ context: UnsafeMutableRawPointer?,
    _ data: UnsafePointer<CChar>?,
    _ length: Int
) {
    guard let data = data else { return }
    let message = String(cString: data).trimmingCharacters(in: .whitespacesAndNewlines)
    if !message.isEmpty {
        sshTraceLogger.debug("\(message)")
    }
}

/// Delegate protocol for SSH connection events
@MainActor
public protocol SSHConnectionDelegate: AnyObject {
    func connectionDidConnect(_ connection: SSHConnection)
    func connectionDidAuthenticate(_ connection: SSHConnection)
    func connectionDidFailAuthentication(_ connection: SSHConnection, error: Error)
    func connectionDidClose(_ connection: SSHConnection, error: Error?)
    func connection(_ connection: SSHConnection, didReceiveData data: Data)
}

/// Errors that can occur during SSH operations
public enum SSHError: LocalizedError {
    case notConnected
    case alreadyConnected
    case connectionFailed(String)
    case authenticationFailed(String)
    case channelError(String)
    case sessionError(String)
    case timeout
    case notInTmux
    case tmuxExited(reason: String?)
    
    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to server"
        case .alreadyConnected: return "Already connected"
        case .connectionFailed(let r): return "Connection failed: \(r)"
        case .authenticationFailed(let r): return "Auth failed: \(r)"
        case .channelError(let r): return "Channel error: \(r)"
        case .sessionError(let r): return "Session error: \(r)"
        case .timeout: return "Operation timed out"
        case .notInTmux: return "Not in a tmux session"
        case .tmuxExited(let reason): return "tmux session ended\(reason.map { ": \($0)" } ?? "")"
        }
    }
}

/// SSH Connection state
public enum SSHState: Sendable {
    case disconnected
    case connecting
    case connected  // TCP connected, SSH handshake done
    case authenticated
    case channelOpen
}

/// Manages an SSH connection using libssh2
@MainActor
public class SSHConnection: ObservableObject {
    // Connection parameters
    public let host: String
    public let port: Int
    public let username: String
    
    // State
    @Published public private(set) var state: SSHState = .disconnected
    
    // Delegate
    public weak var delegate: SSHConnectionDelegate?
    
    // Terminal dimensions
    public var cols: Int = 80
    public var rows: Int = 24
    
    // libssh2 handles - stored as raw pointers
    // Using nonisolated(unsafe) to allow access from background queue
    nonisolated(unsafe) private var session: OpaquePointer?
    nonisolated(unsafe) private var channel: OpaquePointer?
    nonisolated(unsafe) private var socketFd: Int32 = -1
    
    // Background queue for SSH operations
    private let sshQueue = DispatchQueue(label: "ssh.operations", qos: .userInitiated)
    
    // Read timer
    private var readTimer: DispatchSourceTimer?
    
    // libssh2 global init (do once)
    nonisolated(unsafe) private static var libssh2Initialized = false
    
    /// Enable libssh2 protocol-level tracing (logged to os.Logger category "libssh2")
    /// Set this before calling connect() to capture handshake/auth tracing
    public var enableTracing: Bool = false
    
    /// Trace categories to enable. Only used when enableTracing is true.
    /// Default: AUTH, KEX, ERROR, PUBLICKEY, SFTP (excludes noisy CONN/TRANS/SOCKET)
    /// Set to ~0 for all categories, or combine specific LIBSSH2_TRACE_* constants.
    public var traceCategories: Int32 = LIBSSH2_TRACE_AUTH | LIBSSH2_TRACE_KEX | LIBSSH2_TRACE_ERROR | LIBSSH2_TRACE_PUBLICKEY | LIBSSH2_TRACE_SFTP
    
    public init(host: String, port: Int = 22, username: String) {
        self.host = host
        self.port = port
        self.username = username
        
        // Initialize libssh2 once
        if !Self.libssh2Initialized {
            libssh2_init(0)
            Self.libssh2Initialized = true
        }
    }
    
    deinit {
        // Note: deinit in MainActor class, but we'll handle cleanup inline
    }
    
    nonisolated private func cleanupSSHResources() {
        if let chan = channel {
            libssh2_channel_close(chan)
            libssh2_channel_free(chan)
            channel = nil
        }
        
        if let sess = session {
            // SSH_DISCONNECT_BY_APPLICATION = 11
            libssh2_session_disconnect_ex(sess, 11, "disconnect", "")
            libssh2_session_free(sess)
            session = nil
        }
        
        if socketFd >= 0 {
            close(socketFd)
            socketFd = -1
        }
    }
    
    /// Connect to the SSH server and perform handshake
    public func connect() async throws {
        logger.info("🔗 SSHConnection.connect() - host=\(host) port=\(port)")
        guard state == .disconnected else {
            logger.info("🔗 Already connected, throwing error")
            throw SSHError.alreadyConnected
        }
        
        state = .connecting
        
        // Create socket and connect synchronously on background
        logger.info("🔗 Creating socket and connecting...")
        let sock = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            sshQueue.async { [self] in
                do {
                    let sock = try self.createSocketAndConnect()
                    logger.info("🔗 Socket connected: fd=\(sock)")
                    continuation.resume(returning: sock)
                } catch {
                    logger.info("🔗 Socket connection failed: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
        
        socketFd = sock
        
        // Create and setup session
        logger.info("🔗 Creating libssh2 session...")
        let tracing = self.enableTracing
        let traceCategories = self.traceCategories
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sshQueue.async { [self] in
                // Create libssh2 session
                guard let sess = libssh2_session_init_ex(nil, nil, nil, nil) else {
                    logger.info("🔗 Failed to create libssh2 session")
                    continuation.resume(throwing: SSHError.sessionError("Failed to create session"))
                    return
                }
                self.session = sess
                logger.info("🔗 libssh2 session created")
                
                // Enable tracing if requested (must be before handshake to capture it)
                if tracing {
                    logger.info("🔗 Enabling libssh2 tracing with categories=\(traceCategories)")
                    libssh2_trace(sess, traceCategories)
                    libssh2_trace_sethandler(sess, nil, libssh2TraceHandler)
                }
                
                // Set blocking mode for simplicity
                libssh2_session_set_blocking(sess, 1)
                
                // Set timeout (10 seconds)
                libssh2_session_set_timeout(sess, 10000)
                
                // Perform SSH handshake
                logger.info("🔗 Performing SSH handshake...")
                let rc = libssh2_session_handshake(sess, self.socketFd)
                
                if rc != 0 {
                    logger.info("🔗 Handshake failed with rc=\(rc)")
                    continuation.resume(throwing: SSHError.sessionError("Handshake failed: \(rc)"))
                } else {
                    logger.info("🔗 Handshake successful!")
                    continuation.resume()
                }
            }
        }
        
        state = .connected
        logger.info("🔗 SSH connection established, notifying delegate")
        delegate?.connectionDidConnect(self)
    }
    
    /// Authenticate with password
    public func authenticatePassword(_ password: String) async throws {
        logger.info("🔐 Authenticating with password for user=\(username)")
        guard state == .connected, let sess = session else {
            logger.info("🔐 Not connected, throwing error")
            throw SSHError.notConnected
        }
        
        let user = username
        
        // Capture sess as nonisolated(unsafe) to avoid Sendable warning
        nonisolated(unsafe) let unsafeSess = sess
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sshQueue.async {
                logger.info("🔐 Calling libssh2_userauth_password_ex...")
                let rc = user.withCString { userPtr in
                    password.withCString { passPtr in
                        libssh2_userauth_password_ex(
                            unsafeSess,
                            userPtr,
                            UInt32(user.utf8.count),
                            passPtr,
                            UInt32(password.utf8.count),
                            nil
                        )
                    }
                }
                
                if rc == 0 {
                    logger.info("🔐 Authentication successful!")
                    continuation.resume()
                } else {
                    logger.info("🔐 Authentication failed with rc=\(rc)")
                    continuation.resume(throwing: SSHError.authenticationFailed("Password auth failed: \(rc)"))
                }
            }
        }
        
        logger.info("🔐 State -> authenticated")
        state = .authenticated
        delegate?.connectionDidAuthenticate(self)
    }
    
    /// Authenticate with public key
    public func authenticateKey(privateKeyPath: String, publicKeyPath: String? = nil, passphrase: String? = nil) async throws {
        guard state == .connected, let sess = session else {
            throw SSHError.notConnected
        }
        
        let user = username
        
        // Capture sess as nonisolated(unsafe) to avoid Sendable warning
        nonisolated(unsafe) let unsafeSess = sess
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sshQueue.async {
                let rc = user.withCString { userPtr in
                    privateKeyPath.withCString { privPtr in
                        if let pass = passphrase {
                            return pass.withCString { passPtr in
                                libssh2_userauth_publickey_fromfile_ex(
                                    unsafeSess,
                                    userPtr,
                                    UInt32(user.utf8.count),
                                    nil,
                                    privPtr,
                                    passPtr
                                )
                            }
                        } else {
                            return libssh2_userauth_publickey_fromfile_ex(
                                unsafeSess,
                                userPtr,
                                UInt32(user.utf8.count),
                                nil,
                                privPtr,
                                nil
                            )
                        }
                    }
                }
                
                if rc == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: SSHError.authenticationFailed("Key auth failed: \(rc)"))
                }
            }
        }
        
        logger.info("🔐 State -> authenticated")
        state = .authenticated
        delegate?.connectionDidAuthenticate(self)
    }
    
    /// Open a shell channel with PTY
    public func openShell(term: String = "xterm-256color", cols: Int = 80, rows: Int = 24) async throws {
        logger.info("🖥️ openShell called - term=\(term) cols=\(cols) rows=\(rows)")
        guard state == .authenticated, let sess = session else {
            logger.info("🖥️ Not authenticated, throwing error")
            throw SSHError.notConnected
        }
        
        self.cols = cols
        self.rows = rows
        
        // Capture sess as nonisolated(unsafe) to avoid Sendable warning
        nonisolated(unsafe) let unsafeSess = sess
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sshQueue.async { [self] in
                // Open channel
                logger.info("🖥️ Opening channel...")
                guard let chan = "session".withCString({ typePtr in
                    libssh2_channel_open_ex(
                        unsafeSess,
                        typePtr,
                        7,  // strlen("session")
                        UInt32(2 * 1024 * 1024),  // LIBSSH2_CHANNEL_WINDOW_DEFAULT
                        UInt32(32768),  // LIBSSH2_CHANNEL_PACKET_DEFAULT
                        nil, 0
                    )
                }) else {
                    logger.info("🖥️ Failed to open channel")
                    continuation.resume(throwing: SSHError.channelError("Failed to open channel"))
                    return
                }
                logger.info("🖥️ Channel opened")
                
                // Request PTY
                logger.info("🖥️ Requesting PTY...")
                var rc = term.withCString { termPtr in
                    libssh2_channel_request_pty_ex(
                        chan,
                        termPtr,
                        UInt32(term.utf8.count),
                        nil, 0,
                        Int32(cols), Int32(rows),
                        0, 0
                    )
                }
                
                if rc != 0 {
                    logger.info("🖥️ PTY request failed with rc=\(rc)")
                    libssh2_channel_free(chan)
                    continuation.resume(throwing: SSHError.channelError("Failed to request PTY: \(rc)"))
                    return
                }
                logger.info("🖥️ PTY acquired")
                
                // Set environment variables for better terminal support
                // Note: Many SSH servers disable AcceptEnv by default, so these may not work
                // But we try anyway for servers that do allow them
                Self.setEnv(chan, name: "COLORTERM", value: "truecolor")
                Self.setEnv(chan, name: "TERM_PROGRAM", value: "ghostty")
                Self.setEnv(chan, name: "TERM_PROGRAM_VERSION", value: "1.0.0")
                
                // Start shell
                logger.info("🖥️ Starting shell...")
                rc = "shell".withCString { shellPtr in
                    libssh2_channel_process_startup(
                        chan,
                        shellPtr,
                        5,  // strlen("shell")
                        nil, 0
                    )
                }
                
                if rc != 0 {
                    logger.info("🖥️ Shell start failed with rc=\(rc)")
                    libssh2_channel_free(chan)
                    continuation.resume(throwing: SSHError.channelError("Failed to start shell: \(rc)"))
                    return
                }
                logger.info("🖥️ Shell started!")
                
                // Set channel to non-blocking for reads
                libssh2_channel_set_blocking(chan, 0)
                
                self.channel = chan
                continuation.resume()
            }
        }
        
        logger.info("🖥️ State -> channelOpen, starting read loop")
        state = .channelOpen
        startReadLoop()
    }
    
    /// Resize the PTY
    public func resizePTY(cols: Int, rows: Int) {
        guard let chan = channel else { return }
        
        self.cols = cols
        self.rows = rows
        
        // Capture chan as nonisolated(unsafe) to avoid Sendable warning
        // This is safe because we only use it for libssh2 calls on sshQueue
        nonisolated(unsafe) let unsafeChan = chan
        sshQueue.async {
            _ = libssh2_channel_request_pty_size_ex(unsafeChan, Int32(cols), Int32(rows), 0, 0)
        }
    }
    
    /// Set an environment variable on the channel
    /// Note: This requires AcceptEnv to be configured on the SSH server
    nonisolated private static func setEnv(_ channel: OpaquePointer, name: String, value: String) {
        let rc = name.withCString { namePtr in
            value.withCString { valuePtr in
                libssh2_channel_setenv_ex(
                    channel,
                    namePtr, UInt32(name.utf8.count),
                    valuePtr, UInt32(value.utf8.count)
                )
            }
        }
        if rc == 0 {
            logger.info("🌍 Set env \(name)=\(value)")
        } else {
            // This is expected to fail on most servers - AcceptEnv is usually restricted
            logger.debug("🌍 Failed to set env \(name) (rc=\(rc)) - server may not accept this variable")
        }
    }
    
    /// Write data to the channel
    public func write(_ data: Data) {
        guard state == .channelOpen, let chan = channel else { return }
        
        // Capture chan as nonisolated(unsafe) to avoid Sendable warning
        // This is safe because we only use it for libssh2 calls on sshQueue
        nonisolated(unsafe) let unsafeChan = chan
        sshQueue.async {
            data.withUnsafeBytes { buffer in
                guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
                var written = 0
                let total = buffer.count
                
                while written < total {
                    let rc = libssh2_channel_write_ex(unsafeChan, 0, ptr.advanced(by: written), total - written)
                    
                    if rc < 0 {
                        // LIBSSH2_ERROR_EAGAIN = -37
                        if rc == -37 {
                            // Would block, try again
                            usleep(1000)
                            continue
                        }
                        break
                    }
                    written += rc
                }
            }
        }
    }
    
    /// Write string to channel
    public func write(_ string: String) {
        if let data = string.data(using: .utf8) {
            write(data)
        }
    }
    
    /// Disconnect
    public func disconnect() {
        readTimer?.cancel()
        readTimer = nil
        cleanupSSHResources()
        state = .disconnected
        delegate?.connectionDidClose(self, error: nil)
    }
    
    // MARK: - Private
    
    nonisolated private func createSocketAndConnect() throws -> Int32 {
        // Resolve host
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        
        var result: UnsafeMutablePointer<addrinfo>?
        let portStr = String(port)
        
        let ret = getaddrinfo(host, portStr, &hints, &result)
        if ret != 0 {
            throw SSHError.connectionFailed("DNS resolution failed: \(ret)")
        }
        
        defer { freeaddrinfo(result) }
        
        guard let addr = result else {
            throw SSHError.connectionFailed("No address found")
        }
        
        // Create socket
        let sock = socket(addr.pointee.ai_family, addr.pointee.ai_socktype, addr.pointee.ai_protocol)
        if sock < 0 {
            throw SSHError.connectionFailed("Socket creation failed")
        }
        
        // Connect
        if Darwin.connect(sock, addr.pointee.ai_addr, addr.pointee.ai_addrlen) < 0 {
            Darwin.close(sock)
            throw SSHError.connectionFailed("Connection refused")
        }
        
        return sock
    }
    
    private func startReadLoop() {
        let timer = DispatchSource.makeTimerSource(queue: sshQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        
        timer.setEventHandler { [weak self] in
            self?.readFromChannel()
        }
        
        readTimer = timer
        timer.resume()
    }
    
    private func readFromChannel() {
        guard let chan = channel else { return }
        
        var buffer = [CChar](repeating: 0, count: 32768)
        
        // Read from channel (stream ID 0 = stdout)
        let rc = buffer.withUnsafeMutableBufferPointer { ptr in
            libssh2_channel_read_ex(chan, 0, ptr.baseAddress, ptr.count)
        }
        
        if rc > 0 {
            let data = Data(bytes: buffer, count: rc)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.delegate?.connection(self, didReceiveData: data)
            }
        } else if rc == 0 || rc == -1 {
            // rc == 0: No data available
            // rc == -1: EOF or error
            // Check for EOF - remote host closed the connection
            let isEof = libssh2_channel_eof(chan) != 0
            if isEof {
                logger.info("🔌 SSH channel EOF detected - remote host disconnected")
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    // Stop the read timer first
                    self.readTimer?.cancel()
                    self.readTimer = nil
                    // Clean up and notify
                    self.cleanupSSHResources()
                    self.state = .disconnected
                    self.delegate?.connectionDidClose(self, error: SSHError.channelError("Remote host closed connection"))
                }
                return
            }
        }
        // EAGAIN (-37) is normal in non-blocking mode - just continue
    }
}
