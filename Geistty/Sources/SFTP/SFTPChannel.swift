//
//  SFTPChannel.swift
//  Geistty
//
//  SFTP subsystem channel handler using SwiftNIO-SSH
//
//  SFTP Protocol Reference: https://datatracker.ietf.org/doc/html/draft-ietf-secsh-filexfer-02
//  The protocol is a binary request/response format over the SSH "sftp" subsystem.
//

import Foundation
import NIOCore
import NIOTransportServices
import NIOSSH
import os.log

private let logger = Logger(subsystem: "com.geistty", category: "SFTP")

// MARK: - SFTP Protocol Constants

/// SFTP packet types
enum SFTPPacketType: UInt8 {
    case initialize = 1      // SSH_FXP_INIT
    case version = 2         // SSH_FXP_VERSION
    case open = 3            // SSH_FXP_OPEN
    case close = 4           // SSH_FXP_CLOSE
    case read = 5            // SSH_FXP_READ
    case write = 6           // SSH_FXP_WRITE
    case lstat = 7           // SSH_FXP_LSTAT
    case fstat = 8           // SSH_FXP_FSTAT
    case setstat = 9         // SSH_FXP_SETSTAT
    case fsetstat = 10       // SSH_FXP_FSETSTAT
    case opendir = 11        // SSH_FXP_OPENDIR
    case readdir = 12        // SSH_FXP_READDIR
    case remove = 13         // SSH_FXP_REMOVE
    case mkdir = 14          // SSH_FXP_MKDIR
    case rmdir = 15          // SSH_FXP_RMDIR
    case realpath = 16       // SSH_FXP_REALPATH
    case stat = 17           // SSH_FXP_STAT
    case rename = 18         // SSH_FXP_RENAME
    case readlink = 19       // SSH_FXP_READLINK
    case symlink = 20        // SSH_FXP_SYMLINK
    
    case status = 101        // SSH_FXP_STATUS
    case handle = 102        // SSH_FXP_HANDLE
    case data = 103          // SSH_FXP_DATA
    case name = 104          // SSH_FXP_NAME
    case attrs = 105         // SSH_FXP_ATTRS
    
    case extended = 200      // SSH_FXP_EXTENDED
    case extendedReply = 201 // SSH_FXP_EXTENDED_REPLY
}

/// SFTP status codes
enum SFTPStatusCode: UInt32 {
    case ok = 0              // SSH_FX_OK
    case eof = 1             // SSH_FX_EOF
    case noSuchFile = 2      // SSH_FX_NO_SUCH_FILE
    case permissionDenied = 3 // SSH_FX_PERMISSION_DENIED
    case failure = 4         // SSH_FX_FAILURE
    case badMessage = 5      // SSH_FX_BAD_MESSAGE
    case noConnection = 6    // SSH_FX_NO_CONNECTION
    case connectionLost = 7  // SSH_FX_CONNECTION_LOST
    case opUnsupported = 8   // SSH_FX_OP_UNSUPPORTED
}

/// SFTP open flags
struct SFTPOpenFlags: OptionSet {
    let rawValue: UInt32
    
    static let read       = SFTPOpenFlags(rawValue: 0x00000001) // SSH_FXF_READ
    static let write      = SFTPOpenFlags(rawValue: 0x00000002) // SSH_FXF_WRITE
    static let append     = SFTPOpenFlags(rawValue: 0x00000004) // SSH_FXF_APPEND
    static let create     = SFTPOpenFlags(rawValue: 0x00000008) // SSH_FXF_CREAT
    static let truncate   = SFTPOpenFlags(rawValue: 0x00000010) // SSH_FXF_TRUNC
    static let exclusive  = SFTPOpenFlags(rawValue: 0x00000020) // SSH_FXF_EXCL
}

/// SFTP file attribute flags
struct SFTPAttributeFlags: OptionSet {
    let rawValue: UInt32
    
    static let size        = SFTPAttributeFlags(rawValue: 0x00000001)
    static let uidgid      = SFTPAttributeFlags(rawValue: 0x00000002)
    static let permissions = SFTPAttributeFlags(rawValue: 0x00000004)
    static let acmodtime   = SFTPAttributeFlags(rawValue: 0x00000008)
    static let extended    = SFTPAttributeFlags(rawValue: 0x80000000)
}

// MARK: - SFTP Channel Handler

/// Channel handler for SFTP subsystem data
final class SFTPChannelHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData
    
    /// Callback for received SFTP data
    private let onData: @Sendable (Data) -> Void
    
    /// Callback for channel close
    private let onClose: @Sendable (Error?) -> Void
    
    /// Callback for channel events (success/failure for subsystem request)
    private let onEvent: @Sendable (Any) -> Void
    
    /// Buffer for incomplete packets
    private var receiveBuffer = Data()
    
    init(
        onData: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable (Error?) -> Void,
        onEvent: @escaping @Sendable (Any) -> Void
    ) {
        self.onData = onData
        self.onClose = onClose
        self.onEvent = onEvent
    }
    
    func channelActive(context: ChannelHandlerContext) {
        logger.info("📂 SFTP channel active")
        context.fireChannelActive()
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        
        // Only process regular channel data
        guard case .channel = channelData.type else { 
            logger.debug("📂 Received non-channel data type, ignoring")
            return 
        }
        
        switch channelData.data {
        case .byteBuffer(var buffer):
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                logger.info("📂 SFTPChannelHandler received \(bytes.count) bytes")
                receiveBuffer.append(contentsOf: bytes)
                processBuffer()
            }
        case .fileRegion:
            logger.debug("📂 Received file region, ignoring")
            break
        }
    }
    
    /// Process buffered data, extracting complete SFTP packets
    private func processBuffer() {
        // SFTP packets are: length (4 bytes) + type (1 byte) + data
        while receiveBuffer.count >= 4 {
            let length = UInt32(receiveBuffer[0]) << 24 |
                         UInt32(receiveBuffer[1]) << 16 |
                         UInt32(receiveBuffer[2]) << 8 |
                         UInt32(receiveBuffer[3])
            
            let totalLength = Int(length) + 4
            
            if receiveBuffer.count >= totalLength {
                // Extract complete packet
                let packet = receiveBuffer.prefix(totalLength)
                receiveBuffer.removeFirst(totalLength)
                onData(Data(packet))
            } else {
                break // Wait for more data
            }
        }
    }
    
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        logger.info("📂 SFTP channel event: \(type(of: event))")
        onEvent(event)
        context.fireUserInboundEventTriggered(event)
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        logger.info("🔌 SFTP channel inactive")
        onClose(nil)
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("🔌 SFTP channel error: \(error.localizedDescription)")
        onClose(error)
        context.close(promise: nil)
    }
    
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        let channelData = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        context.write(wrapOutboundOut(channelData), promise: promise)
    }
}

// MARK: - SFTP Channel

/// Manages an SFTP channel over SSH
actor SFTPChannel {
    /// The underlying SSH channel
    private var channel: Channel?
    
    /// The parent SSH connection's NIOSSHHandler
    private weak var sshHandler: NIOSSHHandler?
    
    /// The parent SSH channel (connection channel)
    private let parentChannel: Channel
    
    /// Request ID counter
    private var requestId: UInt32 = 0
    
    /// Pending requests waiting for responses
    private var pendingRequests: [UInt32: CheckedContinuation<Data, Error>] = [:]
    
    /// Continuation waiting for subsystem success event
    private var subsystemContinuation: CheckedContinuation<Void, Error>?
    
    /// SFTP protocol version
    private var protocolVersion: UInt32 = 0
    
    /// Whether the channel is initialized
    private var isInitialized = false
    
    /// Connection state - true only after SFTP subsystem is open and initialized
    private(set) var isConnected = false
    
    init(parentChannel: Channel) {
        self.parentChannel = parentChannel
    }
    
    /// Open the SFTP subsystem channel
    func open() async throws {
        logger.info("📂 Opening SFTP channel...")
        
        // Get the SSH handler from the parent channel
        let handler = try await parentChannel.pipeline.handler(type: NIOSSHHandler.self).get()
        self.sshHandler = handler
        
        // Create the SFTP child channel
        let channelPromise = parentChannel.eventLoop.makePromise(of: Channel.self)
        
        handler.createChannel(channelPromise) { [weak self] childChannel, channelType in
            guard channelType == .session else {
                return childChannel.eventLoop.makeFailedFuture(
                    SFTPError.connectionFailed("Unexpected channel type")
                )
            }
            
            return childChannel.pipeline.addHandler(
                SFTPChannelHandler(
                    onData: { data in
                        Task { await self?.handleIncomingData(data) }
                    },
                    onClose: { error in
                        Task { await self?.handleChannelClose(error) }
                    },
                    onEvent: { event in
                        Task { await self?.handleChannelEvent(event) }
                    }
                )
            )
        }
        
        // Wait for channel to be created
        let childChannel = try await channelPromise.futureResult.get()
        self.channel = childChannel
        logger.info("📂 SSH child channel created")
        
        // Request SFTP subsystem and wait for success/failure
        logger.info("📂 Requesting SFTP subsystem...")
        let subsystemRequest = SSHChannelRequestEvent.SubsystemRequest(
            subsystem: "sftp",
            wantReply: true
        )
        
        // First send the subsystem request
        try await childChannel.triggerUserOutboundEvent(subsystemRequest).get()
        logger.info("📂 SFTP subsystem request sent, waiting for response...")
        
        // Then wait for success/failure event with timeout
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Task 1: Wait for the event callback to fire
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    // Store continuation - handleChannelEvent will resume it
                    Task { @MainActor in
                        await self.setSubsystemContinuation(continuation)
                    }
                }
            }
            
            // Task 2: Timeout after 10 seconds  
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                throw SFTPError.connectionFailed("Subsystem request timeout (10s)")
            }
            
            // Wait for first task to complete (success or timeout)
            try await group.next()
            group.cancelAll()
        }
        
        logger.info("📂 SFTP subsystem request succeeded")
        
        // Initialize SFTP protocol
        try await initializeSFTP()
        
        isConnected = true
        logger.info("📂 SFTP channel ready (version \(self.protocolVersion))")
    }
    
    /// Clear the subsystem continuation (actor-isolated)
    private func clearSubsystemContinuation() {
        subsystemContinuation = nil
    }
    
    /// Set the subsystem continuation (actor-isolated)
    private func setSubsystemContinuation(_ continuation: CheckedContinuation<Void, Error>) {
        subsystemContinuation = continuation
    }

    /// Handle channel events (subsystem success/failure)
    private func handleChannelEvent(_ event: Any) {
        logger.info("📂 Processing channel event: \(type(of: event))")
        
        if event is ChannelSuccessEvent {
            logger.info("📂 Received ChannelSuccessEvent - subsystem request succeeded")
            if let continuation = subsystemContinuation {
                subsystemContinuation = nil
                continuation.resume()
            }
        } else if event is ChannelFailureEvent {
            logger.error("📂 Received ChannelFailureEvent - subsystem request failed")
            if let continuation = subsystemContinuation {
                subsystemContinuation = nil
                continuation.resume(throwing: SFTPError.connectionFailed("Subsystem request was rejected by server"))
            }
        }
    }
    
    /// Initialize the SFTP protocol (version negotiation)
    private func initializeSFTP() async throws {
        // Build SSH_FXP_INIT packet
        var initPacket = Data()
        
        // Version 3 (most widely supported)
        let version: UInt32 = 3
        initPacket.append(contentsOf: version.bigEndianBytes)
        
        // Send init packet
        try await sendPacket(type: .initialize, data: initPacket)
        
        // Wait for version response (first packet back)
        let response = try await receiveNextPacket()
        
        guard response.count >= 5 else {
            throw SFTPError.parseError("Invalid version response")
        }
        
        let responseType = response[4]
        guard responseType == SFTPPacketType.version.rawValue else {
            throw SFTPError.parseError("Expected version response, got type \(responseType)")
        }
        
        // Parse version
        protocolVersion = UInt32(response[5]) << 24 |
                          UInt32(response[6]) << 16 |
                          UInt32(response[7]) << 8 |
                          UInt32(response[8])
        
        isInitialized = true
    }
    
    /// Send an SFTP packet
    private func sendPacket(type: SFTPPacketType, data: Data, requestId: UInt32? = nil) async throws {
        guard let channel = channel else {
            throw SFTPError.notConnected
        }
        
        var packet = Data()
        
        // Packet type
        packet.append(type.rawValue)
        
        // Request ID (if applicable)
        if let id = requestId {
            packet.append(contentsOf: id.bigEndianBytes)
        }
        
        // Data
        packet.append(data)
        
        // Length prefix (total packet length excluding this field)
        var finalPacket = Data()
        let length = UInt32(packet.count)
        finalPacket.append(contentsOf: length.bigEndianBytes)
        finalPacket.append(packet)
        
        // Send
        var buffer = channel.allocator.buffer(capacity: finalPacket.count)
        buffer.writeBytes(finalPacket)
        
        try await channel.writeAndFlush(buffer).get()
    }
    
    /// Handle incoming SFTP data
    private func handleIncomingData(_ data: Data) {
        // Parse packet
        guard data.count >= 5 else {
            logger.warning("⚠️ SFTP packet too small: \(data.count) bytes")
            return
        }
        
        // Skip length (4 bytes), get type
        let type = data[4]
        
        // For requests with IDs, extract the ID and resume the continuation
        if data.count >= 9 {
            let requestId = UInt32(data[5]) << 24 |
                            UInt32(data[6]) << 16 |
                            UInt32(data[7]) << 8 |
                            UInt32(data[8])
            
            if let continuation = pendingRequests.removeValue(forKey: requestId) {
                continuation.resume(returning: data)
            } else if type == SFTPPacketType.version.rawValue {
                // Version response doesn't have request ID
                // Store for initializeSFTP to pick up
                if let continuation = pendingRequests.removeValue(forKey: 0) {
                    continuation.resume(returning: data)
                }
            }
        }
    }
    
    /// Wait for the next packet with timeout (used during initialization)
    private func receiveNextPacket(timeout: TimeInterval = 30) async throws -> Data {
        logger.info("📂 Waiting for SFTP version response (timeout: \(timeout)s)...")
        
        // Store continuation in actor-isolated storage, then race with timeout
        let result: Data = try await withCheckedThrowingContinuation { continuation in
            pendingRequests[0] = continuation
            
            // Schedule timeout
            Task {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                // If still pending after timeout, fail it
                if let cont = await self.pendingRequests.removeValue(forKey: 0) {
                    cont.resume(throwing: SFTPError.connectionFailed("SFTP initialization timeout after \(timeout) seconds"))
                }
            }
        }
        
        return result
    }
    
    /// Handle channel close
    private func handleChannelClose(_ error: Error?) {
        isConnected = false
        isInitialized = false
        channel = nil
        
        // Cancel all pending requests
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: error ?? SFTPError.notConnected)
        }
        pendingRequests.removeAll()
    }
    
    /// Send a request and wait for response
    private func request(type: SFTPPacketType, data: Data) async throws -> Data {
        guard isConnected else {
            throw SFTPError.notConnected
        }
        
        let id = nextRequestId()
        
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
            
            Task {
                do {
                    try await sendPacket(type: type, data: data, requestId: id)
                } catch {
                    pendingRequests.removeValue(forKey: id)
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Get next request ID
    private func nextRequestId() -> UInt32 {
        requestId += 1
        return requestId
    }
    
    // MARK: - SFTP Operations
    
    /// Get real path (canonicalize)
    func realpath(_ path: String) async throws -> String {
        var data = Data()
        data.appendSFTPString(path)
        
        let response = try await request(type: .realpath, data: data)
        
        // Parse SSH_FXP_NAME response
        return try parseNameResponse(response).first?.name ?? path
    }
    
    /// Open a directory for reading
    func opendir(_ path: String) async throws -> Data {
        var data = Data()
        data.appendSFTPString(path)
        
        let response = try await request(type: .opendir, data: data)
        
        // Parse SSH_FXP_HANDLE response
        return try parseHandleResponse(response)
    }
    
    /// Read directory entries
    func readdir(handle: Data) async throws -> [SFTPFileAttributes] {
        var data = Data()
        data.appendSFTPString(handle)
        
        let response = try await request(type: .readdir, data: data)
        
        // Check if EOF
        if response.count >= 5 && response[4] == SFTPPacketType.status.rawValue {
            let status = try parseStatusResponse(response)
            if status.code == .eof {
                return []
            }
            throw SFTPError.commandFailed(status.message)
        }
        
        // Parse SSH_FXP_NAME response
        return try parseNameResponse(response)
    }
    
    /// Close a file/directory handle
    func close(handle: Data) async throws {
        var data = Data()
        data.appendSFTPString(handle)
        
        let response = try await request(type: .close, data: data)
        let status = try parseStatusResponse(response)
        
        if status.code != .ok {
            throw SFTPError.commandFailed(status.message)
        }
    }
    
    /// Get file attributes
    func stat(_ path: String) async throws -> SFTPFileAttributes {
        var data = Data()
        data.appendSFTPString(path)
        
        let response = try await request(type: .stat, data: data)
        
        // Check for error
        if response.count >= 5 && response[4] == SFTPPacketType.status.rawValue {
            let status = try parseStatusResponse(response)
            throw sftpStatusToError(status)
        }
        
        // Parse SSH_FXP_ATTRS response
        return try parseAttrsResponse(response, name: (path as NSString).lastPathComponent)
    }
    
    /// Get file attributes (don't follow symlinks)
    func lstat(_ path: String) async throws -> SFTPFileAttributes {
        var data = Data()
        data.appendSFTPString(path)
        
        let response = try await request(type: .lstat, data: data)
        
        if response.count >= 5 && response[4] == SFTPPacketType.status.rawValue {
            let status = try parseStatusResponse(response)
            throw sftpStatusToError(status)
        }
        
        return try parseAttrsResponse(response, name: (path as NSString).lastPathComponent)
    }
    
    /// Open a file
    func open(_ path: String, flags: SFTPOpenFlags, attrs: SFTPFileAttributes? = nil) async throws -> Data {
        var data = Data()
        data.appendSFTPString(path)
        data.append(contentsOf: flags.rawValue.bigEndianBytes)
        
        // Empty attributes
        data.append(contentsOf: UInt32(0).bigEndianBytes) // flags = 0 (no attrs)
        
        let response = try await request(type: .open, data: data)
        
        if response.count >= 5 && response[4] == SFTPPacketType.status.rawValue {
            let status = try parseStatusResponse(response)
            throw sftpStatusToError(status)
        }
        
        return try parseHandleResponse(response)
    }
    
    /// Read data from a file
    func read(handle: Data, offset: UInt64, length: UInt32) async throws -> Data {
        var data = Data()
        data.appendSFTPString(handle)
        data.append(contentsOf: offset.bigEndianBytes)
        data.append(contentsOf: length.bigEndianBytes)
        
        let response = try await request(type: .read, data: data)
        
        if response.count >= 5 && response[4] == SFTPPacketType.status.rawValue {
            let status = try parseStatusResponse(response)
            if status.code == .eof {
                return Data()
            }
            throw sftpStatusToError(status)
        }
        
        return try parseDataResponse(response)
    }
    
    /// Write data to a file
    func write(handle: Data, offset: UInt64, data: Data) async throws {
        var requestData = Data()
        requestData.appendSFTPString(handle)
        requestData.append(contentsOf: offset.bigEndianBytes)
        requestData.appendSFTPString(data)
        
        let response = try await request(type: .write, data: requestData)
        let status = try parseStatusResponse(response)
        
        if status.code != .ok {
            throw sftpStatusToError(status)
        }
    }
    
    /// Create a directory
    func mkdir(_ path: String, mode: UInt32 = 0o755) async throws {
        var data = Data()
        data.appendSFTPString(path)
        
        // Attributes with permissions
        data.append(contentsOf: SFTPAttributeFlags.permissions.rawValue.bigEndianBytes)
        data.append(contentsOf: mode.bigEndianBytes)
        
        let response = try await request(type: .mkdir, data: data)
        let status = try parseStatusResponse(response)
        
        if status.code != .ok {
            throw sftpStatusToError(status)
        }
    }
    
    /// Remove a directory
    func rmdir(_ path: String) async throws {
        var data = Data()
        data.appendSFTPString(path)
        
        let response = try await request(type: .rmdir, data: data)
        let status = try parseStatusResponse(response)
        
        if status.code != .ok {
            throw sftpStatusToError(status)
        }
    }
    
    /// Remove a file
    func remove(_ path: String) async throws {
        var data = Data()
        data.appendSFTPString(path)
        
        let response = try await request(type: .remove, data: data)
        let status = try parseStatusResponse(response)
        
        if status.code != .ok {
            throw sftpStatusToError(status)
        }
    }
    
    /// Rename a file/directory
    func rename(from oldPath: String, to newPath: String) async throws {
        var data = Data()
        data.appendSFTPString(oldPath)
        data.appendSFTPString(newPath)
        
        let response = try await request(type: .rename, data: data)
        let status = try parseStatusResponse(response)
        
        if status.code != .ok {
            throw sftpStatusToError(status)
        }
    }
    
    /// Close the SFTP channel
    func close() async {
        if let channel = channel {
            channel.close(promise: nil)
        }
        channel = nil
        isConnected = false
        isInitialized = false
    }
    
    // MARK: - Response Parsing
    
    private struct StatusResponse {
        let code: SFTPStatusCode
        let message: String
    }
    
    private func parseStatusResponse(_ data: Data) throws -> StatusResponse {
        // Format: length (4) + type (1) + id (4) + code (4) + message (string) + language (string)
        guard data.count >= 13 else {
            throw SFTPError.parseError("Status response too short")
        }
        
        let code = UInt32(data[9]) << 24 |
                   UInt32(data[10]) << 16 |
                   UInt32(data[11]) << 8 |
                   UInt32(data[12])
        
        let statusCode = SFTPStatusCode(rawValue: code) ?? .failure
        
        // Parse message string if present
        var message = "Unknown error"
        if data.count >= 17 {
            let msgLen = Int(UInt32(data[13]) << 24 |
                            UInt32(data[14]) << 16 |
                            UInt32(data[15]) << 8 |
                            UInt32(data[16]))
            if data.count >= 17 + msgLen {
                message = String(data: data[17..<(17 + msgLen)], encoding: .utf8) ?? "Unknown error"
            }
        }
        
        return StatusResponse(code: statusCode, message: message)
    }
    
    private func parseHandleResponse(_ data: Data) throws -> Data {
        // Format: length (4) + type (1) + id (4) + handle (string)
        guard data.count >= 13 else {
            throw SFTPError.parseError("Handle response too short")
        }
        
        guard data[4] == SFTPPacketType.handle.rawValue else {
            throw SFTPError.parseError("Expected handle response, got type \(data[4])")
        }
        
        let handleLen = Int(UInt32(data[9]) << 24 |
                           UInt32(data[10]) << 16 |
                           UInt32(data[11]) << 8 |
                           UInt32(data[12]))
        
        guard data.count >= 13 + handleLen else {
            throw SFTPError.parseError("Handle response truncated")
        }
        
        return Data(data[13..<(13 + handleLen)])
    }
    
    private func parseDataResponse(_ data: Data) throws -> Data {
        // Format: length (4) + type (1) + id (4) + data (string)
        guard data.count >= 13 else {
            throw SFTPError.parseError("Data response too short")
        }
        
        guard data[4] == SFTPPacketType.data.rawValue else {
            throw SFTPError.parseError("Expected data response, got type \(data[4])")
        }
        
        let dataLen = Int(UInt32(data[9]) << 24 |
                         UInt32(data[10]) << 16 |
                         UInt32(data[11]) << 8 |
                         UInt32(data[12]))
        
        guard data.count >= 13 + dataLen else {
            throw SFTPError.parseError("Data response truncated")
        }
        
        return Data(data[13..<(13 + dataLen)])
    }
    
    private func parseNameResponse(_ data: Data) throws -> [SFTPFileAttributes] {
        // Format: length (4) + type (1) + id (4) + count (4) + entries...
        guard data.count >= 13 else {
            throw SFTPError.parseError("Name response too short")
        }
        
        guard data[4] == SFTPPacketType.name.rawValue else {
            throw SFTPError.parseError("Expected name response, got type \(data[4])")
        }
        
        let count = Int(UInt32(data[9]) << 24 |
                       UInt32(data[10]) << 16 |
                       UInt32(data[11]) << 8 |
                       UInt32(data[12]))
        
        var offset = 13
        var results: [SFTPFileAttributes] = []
        
        for _ in 0..<count {
            // Parse filename
            guard offset + 4 <= data.count else { break }
            let nameLen = Int(UInt32(data[offset]) << 24 |
                             UInt32(data[offset + 1]) << 16 |
                             UInt32(data[offset + 2]) << 8 |
                             UInt32(data[offset + 3]))
            offset += 4
            
            guard offset + nameLen <= data.count else { break }
            let name = String(data: data[offset..<(offset + nameLen)], encoding: .utf8) ?? ""
            offset += nameLen
            
            // Parse longname (we skip this for now)
            guard offset + 4 <= data.count else { break }
            let longNameLen = Int(UInt32(data[offset]) << 24 |
                                 UInt32(data[offset + 1]) << 16 |
                                 UInt32(data[offset + 2]) << 8 |
                                 UInt32(data[offset + 3]))
            offset += 4 + longNameLen
            
            // Parse attributes
            guard offset + 4 <= data.count else { break }
            let attrs = try parseAttributes(data: data, offset: &offset)
            
            if !name.isEmpty && name != "." && name != ".." {
                results.append(SFTPFileAttributes(
                    name: name,
                    size: attrs.size,
                    permissions: attrs.permissions,
                    modificationDate: attrs.modificationDate,
                    isDirectory: attrs.isDirectory,
                    isSymlink: attrs.isSymlink
                ))
            }
        }
        
        return results
    }
    
    private func parseAttrsResponse(_ data: Data, name: String) throws -> SFTPFileAttributes {
        // Format: length (4) + type (1) + id (4) + attrs...
        guard data.count >= 9 else {
            throw SFTPError.parseError("Attrs response too short")
        }
        
        guard data[4] == SFTPPacketType.attrs.rawValue else {
            throw SFTPError.parseError("Expected attrs response, got type \(data[4])")
        }
        
        var offset = 9
        let attrs = try parseAttributes(data: data, offset: &offset)
        
        return SFTPFileAttributes(
            name: name,
            size: attrs.size,
            permissions: attrs.permissions,
            modificationDate: attrs.modificationDate,
            isDirectory: attrs.isDirectory,
            isSymlink: attrs.isSymlink
        )
    }
    
    private struct ParsedAttributes {
        var size: UInt64 = 0
        var permissions: UInt32 = 0
        var modificationDate: Date?
        var isDirectory: Bool = false
        var isSymlink: Bool = false
    }
    
    private func parseAttributes(data: Data, offset: inout Int) throws -> ParsedAttributes {
        guard offset + 4 <= data.count else {
            throw SFTPError.parseError("Attributes truncated")
        }
        
        let flags = SFTPAttributeFlags(rawValue:
            UInt32(data[offset]) << 24 |
            UInt32(data[offset + 1]) << 16 |
            UInt32(data[offset + 2]) << 8 |
            UInt32(data[offset + 3])
        )
        offset += 4
        
        var attrs = ParsedAttributes()
        
        // Size (8 bytes)
        if flags.contains(.size) {
            guard offset + 8 <= data.count else { return attrs }
            attrs.size = UInt64(data[offset]) << 56 |
                         UInt64(data[offset + 1]) << 48 |
                         UInt64(data[offset + 2]) << 40 |
                         UInt64(data[offset + 3]) << 32 |
                         UInt64(data[offset + 4]) << 24 |
                         UInt64(data[offset + 5]) << 16 |
                         UInt64(data[offset + 6]) << 8 |
                         UInt64(data[offset + 7])
            offset += 8
        }
        
        // UID/GID (8 bytes total)
        if flags.contains(.uidgid) {
            guard offset + 8 <= data.count else { return attrs }
            offset += 8
        }
        
        // Permissions (4 bytes)
        if flags.contains(.permissions) {
            guard offset + 4 <= data.count else { return attrs }
            attrs.permissions = UInt32(data[offset]) << 24 |
                               UInt32(data[offset + 1]) << 16 |
                               UInt32(data[offset + 2]) << 8 |
                               UInt32(data[offset + 3])
            offset += 4
            
            // Check file type from permissions
            let fileType = attrs.permissions & 0o170000
            attrs.isDirectory = (fileType == 0o040000)  // S_IFDIR
            attrs.isSymlink = (fileType == 0o120000)    // S_IFLNK
        }
        
        // Access/modification time (8 bytes total)
        if flags.contains(.acmodtime) {
            guard offset + 8 <= data.count else { return attrs }
            offset += 4 // Skip atime
            let mtime = UInt32(data[offset]) << 24 |
                        UInt32(data[offset + 1]) << 16 |
                        UInt32(data[offset + 2]) << 8 |
                        UInt32(data[offset + 3])
            offset += 4
            attrs.modificationDate = Date(timeIntervalSince1970: TimeInterval(mtime))
        }
        
        return attrs
    }
    
    private func sftpStatusToError(_ status: StatusResponse) -> SFTPError {
        switch status.code {
        case .ok:
            return SFTPError.commandFailed("Unexpected OK status")
        case .eof:
            return SFTPError.commandFailed("End of file")
        case .noSuchFile:
            return SFTPError.fileNotFound(status.message)
        case .permissionDenied:
            return SFTPError.permissionDenied(status.message)
        default:
            return SFTPError.commandFailed(status.message)
        }
    }
}

// MARK: - Data Extensions

extension Data {
    mutating func appendSFTPString(_ string: String) {
        let bytes = Array(string.utf8)
        append(contentsOf: UInt32(bytes.count).bigEndianBytes)
        append(contentsOf: bytes)
    }
    
    mutating func appendSFTPString(_ data: Data) {
        append(contentsOf: UInt32(data.count).bigEndianBytes)
        append(data)
    }
}

extension UInt32 {
    var bigEndianBytes: [UInt8] {
        [
            UInt8((self >> 24) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8(self & 0xFF)
        ]
    }
}

extension UInt64 {
    var bigEndianBytes: [UInt8] {
        [
            UInt8((self >> 56) & 0xFF),
            UInt8((self >> 48) & 0xFF),
            UInt8((self >> 40) & 0xFF),
            UInt8((self >> 32) & 0xFF),
            UInt8((self >> 24) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8(self & 0xFF)
        ]
    }
}
