//
//  SSHCommandRunner.swift
//  Geistty
//
//  Lightweight utility for running a single SSH exec command on a remote server.
//  Used by the public key installer to append keys to authorized_keys.
//
//  Unlike NIOSSHConnection (which opens an interactive shell with PTY),
//  this creates a short-lived exec channel — no PTY, no delegate, just
//  connect → run command → collect output → disconnect.
//

import Foundation
import NIOCore
import NIOTransportServices
import NIOSSH
import os.log

private let logger = Logger(subsystem: "com.geistty", category: "SSHCommandRunner")

/// Result of an SSH exec command
struct SSHCommandResult: Sendable {
    let exitStatus: Int?
    let stdout: String
    let stderr: String
    
    var succeeded: Bool {
        exitStatus == 0
    }
}

// MARK: - Output Collector

/// Thread-safe collector for stdout/stderr/exit status from an exec channel.
private final class ExecOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _stdout = Data()
    private var _stderr = Data()
    private var _exitStatus: Int?
    
    func appendStdout(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        _stdout.append(data)
    }
    
    func appendStderr(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        _stderr.append(data)
    }
    
    func setExitStatus(_ status: Int) {
        lock.lock()
        defer { lock.unlock() }
        _exitStatus = status
    }
    
    var result: SSHCommandResult {
        lock.lock()
        defer { lock.unlock() }
        return SSHCommandResult(
            exitStatus: _exitStatus,
            stdout: String(data: _stdout, encoding: .utf8) ?? "",
            stderr: String(data: _stderr, encoding: .utf8) ?? ""
        )
    }
}

// MARK: - Exec Channel Handler

/// Handles data from an SSH exec channel, collecting stdout/stderr and exit status.
private final class ExecChannelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    
    private let collector: ExecOutputCollector
    private let closedPromise: EventLoopPromise<Void>
    /// Guard against double promise fulfillment (#54).
    /// NIO calls errorCaught → channelInactive sequentially, which would
    /// fulfill the promise twice and hit a precondition crash.
    private var promiseFulfilled = false
    
    init(collector: ExecOutputCollector, closedPromise: EventLoopPromise<Void>) {
        self.collector = collector
        self.closedPromise = closedPromise
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        
        switch channelData.data {
        case .byteBuffer(var buffer):
            guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
            let data = Data(bytes)
            
            switch channelData.type {
            case .channel:
                collector.appendStdout(data)
            case .stdErr:
                collector.appendStderr(data)
            default:
                break
            }
        case .fileRegion:
            break
        }
    }
    
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let exitStatus = event as? SSHChannelRequestEvent.ExitStatus {
            collector.setExitStatus(Int(exitStatus.exitStatus))
        }
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        guard !promiseFulfilled else { return }
        promiseFulfilled = true
        closedPromise.succeed(())
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("Exec channel error: \(error.localizedDescription)")
        if !promiseFulfilled {
            promiseFulfilled = true
            closedPromise.fail(error)
        }
        context.close(promise: nil)
    }
}

// MARK: - SSH Command Runner

/// Lightweight SSH exec command runner.
/// Connect with password auth, run a single command, get output, disconnect.
@MainActor
final class SSHCommandRunner {
    
    private let host: String
    private let port: Int
    private let username: String
    private let timeoutSeconds: UInt64
    
    init(host: String, port: Int = 22, username: String, timeoutSeconds: UInt64 = 15) {
        self.host = host
        self.port = port
        self.username = username
        self.timeoutSeconds = timeoutSeconds
    }
    
    /// Run a command on the remote server using password authentication.
    func run(command: String, password: String) async throws -> SSHCommandResult {
        try await run(command: command, authMethod: .password(password))
    }
    
    /// Run a command on the remote server with a specific auth method.
    func run(command: String, authMethod: SSHAuthMethod) async throws -> SSHCommandResult {
        logger.info("Running command on \(self.host):\(self.port)")
        
        let group = NIOTSEventLoopGroup()
        
        defer {
            group.shutdownGracefully { error in
                if let error = error {
                    logger.warning("Event loop shutdown error: \(error.localizedDescription)")
                }
            }
        }
        
        // Build the SSH pipeline
        let clientConfig = SSHClientConfiguration(username: username, authMethod: authMethod)
        let serverAuthDelegate = TOFUHostKeyDelegate(host: self.host, port: self.port)
        
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
        
        // Connect with timeout
        let connectionHost = self.host
        let connectionPort = self.port
        let timeoutNS = self.timeoutSeconds
        
        // Sendable box for capturing the channel across concurrency boundaries
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
        
        let tcpChannel: Channel
        do {
            tcpChannel = try await withThrowingTaskGroup(of: Channel.self) { taskGroup in
                taskGroup.addTask {
                    let ch = try await bootstrap.connect(host: connectionHost, port: connectionPort).get()
                    channelBox.set(ch)
                    return ch
                }
                taskGroup.addTask {
                    try await Task.sleep(nanoseconds: timeoutNS * 1_000_000_000)
                    throw NIOSSHError.timeout
                }
                let result = try await taskGroup.next()!
                taskGroup.cancelAll()
                return result
            }
        } catch {
            if let orphanedChannel = channelBox.channel {
                logger.warning("Closing orphaned channel after timeout")
                try? await orphanedChannel.close()
            }
            throw NIOSSHError.connectionFailed(error.localizedDescription)
        }
        
        defer {
            tcpChannel.close(promise: nil)
        }
        
        logger.info("TCP connected, opening exec channel...")
        
        // Open exec channel
        let sshHandler = try await tcpChannel.pipeline.handler(type: NIOSSHHandler.self).get()
        
        let collector = ExecOutputCollector()
        let channelPromise = tcpChannel.eventLoop.makePromise(of: Channel.self)
        let closedPromise = tcpChannel.eventLoop.makePromise(of: Void.self)
        
        sshHandler.createChannel(channelPromise) { childChannel, channelType in
            guard channelType == .session else {
                return childChannel.eventLoop.makeFailedFuture(NIOSSHError.channelError("Unexpected channel type"))
            }
            
            return childChannel.pipeline.addHandlers([
                ExecChannelHandler(collector: collector, closedPromise: closedPromise)
            ])
        }
        
        let execChannel = try await channelPromise.futureResult.get()
        
        // Send exec request (no PTY needed)
        let execRequest = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        try await execChannel.triggerUserOutboundEvent(execRequest).get()
        
        logger.info("Exec request sent, waiting for completion...")
        
        // Wait for channel to close (command completion) with timeout
        do {
            try await withThrowingTaskGroup(of: Void.self) { taskGroup in
                taskGroup.addTask {
                    try await closedPromise.futureResult.get()
                }
                taskGroup.addTask {
                    // Give the command 30 seconds to complete
                    try await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                    throw NIOSSHError.timeout
                }
                _ = try await taskGroup.next()
                taskGroup.cancelAll()
            }
        } catch is CancellationError {
            // Task was cancelled, that's fine
        }
        
        let result = collector.result
        logger.info("Command completed: exit=\(result.exitStatus ?? -1) stdout=\(result.stdout.count) bytes stderr=\(result.stderr.count) bytes")
        
        return result
    }
}
