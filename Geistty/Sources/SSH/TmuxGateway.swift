//
//  TmuxGateway.swift
//  Geistty
//
//  tmux Control Mode Gateway with proper actor isolation.
//
//  Architecture (following SFTPClient pattern):
//  - Swift actor for command queue and protocol state isolation
//  - Pure async/await interface (no callbacks)
//  - AsyncStream for events (output, notifications)
//  - Observes ConnectionHealth for pause/resume
//
//  This replaces the @MainActor TmuxControlClient with proper concurrency.
//  The gateway owns:
//  - Command queue (pending commands with continuations)
//  - Protocol parser state (TmuxProtocolParser)
//  - Connection health observation
//
//  Usage:
//  ```swift
//  let gateway = TmuxGateway()
//  
//  // Connect and start event stream
//  for await event in gateway.events {
//      switch event {
//      case .output(let paneId, let data):
//          surface.writeOutput(data)
//      case .activated:
//          // Control mode ready
//      case .exited(let reason):
//          // Handle disconnect
//      }
//  }
//  
//  // Send commands (async)
//  let content = try await gateway.capturePane(paneId: "%0")
//  
//  // Feed SSH data
//  gateway.receive(data)
//  ```
//
//  Reference: https://github.com/tmux/tmux/wiki/Control-Mode
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.geistty", category: "TmuxGateway")

// MARK: - Events

/// Events emitted by TmuxGateway
public enum TmuxGatewayEvent: Sendable {
    /// Pane output data (already decoded from %output)
    case output(paneId: String, data: Data)
    
    /// Control mode is now active (first protocol message received)
    case activated
    
    /// Layout changed (window resized, pane split, etc.)
    case layoutChanged(windowId: String, windowIndex: Int, layout: String)
    
    /// Active pane changed
    case activePaneChanged(windowId: String, paneId: String)
    
    /// Window added
    case windowAdded(windowId: String)
    
    /// Window closed
    case windowClosed(windowId: String)
    
    /// Session changed
    case sessionChanged(sessionId: String, sessionName: String)
    
    /// Sessions changed (a session was created or destroyed)
    case sessionsChanged
    
    /// Control mode exited
    case exited(reason: String?)
}

// MARK: - Errors

public enum TmuxGatewayError: LocalizedError, Sendable {
    case notConnected
    case timeout
    case commandFailed(String)
    case parseError(String)
    case disconnected
    
    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to tmux"
        case .timeout:
            return "tmux command timed out"
        case .commandFailed(let message):
            return "tmux command failed: \(message)"
        case .parseError(let message):
            return "Parse error: \(message)"
        case .disconnected:
            return "Connection lost"
        }
    }
}

// MARK: - Gateway Actor

/// tmux Control Mode gateway with proper actor isolation.
///
/// This actor handles:
/// - Command queue with async/await (no callbacks)
/// - Protocol parsing via TmuxProtocolParser
/// - Event streaming via AsyncStream
/// - Connection health observation (pause/resume)
public actor TmuxGateway {
    
    // MARK: - Types
    
    /// A pending command waiting for response
    private struct PendingCommand {
        let id: String
        let command: String
        let continuation: CheckedContinuation<String, Error>
        let timeoutTask: Task<Void, Never>
    }
    
    // MARK: - Properties
    
    /// Whether control mode is active
    public private(set) var isActive: Bool = false
    
    /// Active pane ID
    /// The active pane for input routing. Initially nil until we learn the real pane ID
    /// from %output, %session-changed, or %window-pane-changed events.
    /// IMPORTANT: Do NOT default to "%0" — when another client (e.g., ShellFish) already
    /// owns %0, our session's pane will be %1, %2, etc. Defaulting to %0 would send
    /// keystrokes to the wrong session's pane.
    public private(set) var activePaneId: String?
    
    /// Set the active pane ID for input routing
    /// Called when user taps on a different pane surface
    /// - Parameter paneId: The pane ID (e.g., "%0", "%1")
    public func setActivePaneId(_ paneId: String) {
        if activePaneId != paneId {
            logger.debug("🎯 Gateway active pane changed to \(paneId)")
            activePaneId = paneId
        }
    }
    
    /// Current connection health (observed from NIOSSHConnection)
    public private(set) var connectionHealth: ConnectionHealth = .healthy
    
    /// Whether command queue is paused due to unhealthy connection
    public private(set) var isCommandQueuePaused: Bool = false
    
    /// Commands queued while connection is unhealthy
    private var queuedWhilePaused: [(command: String, continuation: CheckedContinuation<String, Error>)] = []
    
    /// Protocol parser (pure, synchronous)
    private let parser = TmuxProtocolParser()
    
    /// Keyboard translator for Kitty → legacy conversion
    private let keyboardTranslator: KeyboardTranslator = KittyKeyboardTranslator()
    
    /// Parse buffer for incomplete lines
    private var parseBuffer: Data = Data()
    
    /// Current block state for multi-line responses
    private var blockState: TmuxBlockState?
    
    /// Command counter for unique IDs
    private var commandCounter: Int = 0
    
    /// Pending commands queue (FIFO - tmux processes sequentially)
    private var pendingCommands: [PendingCommand] = []
    
    /// Mapping of tmux command numbers to our local IDs
    private var commandNumberMap: [String: String] = [:]
    
    /// Pane scrollback buffers
    private var paneBuffers: [String: Data] = [:]
    
    /// Event stream continuation (set eagerly in init via makeStream)
    private let eventContinuation: AsyncStream<TmuxGatewayEvent>.Continuation
    
    /// Cached event stream (created eagerly in init via makeStream)
    private let cachedEventStream: AsyncStream<TmuxGatewayEvent>
    
    /// Write callback to send data to SSH channel
    private var writeCallback: ((String) -> Void)?
    
    /// Whether we've sent the activation event
    private var hasNotifiedActivation: Bool = false
    
    /// Paused panes (tmux 3.2+)
    private var pausedPanes: Set<String> = []
    
    /// Whether pause mode is enabled
    private var isPauseEnabled: Bool = false
    
    /// Command timeout duration
    /// Timeout for command responses (reduced for better UX)
    private let commandTimeout: Duration = .seconds(3)
    
    // MARK: - Initialization
    
    public init() {
        // Create event stream eagerly using makeStream() which avoids closure issues
        // This ensures continuation exists before any data arrives
        let (stream, continuation) = AsyncStream<TmuxGatewayEvent>.makeStream(bufferingPolicy: .unbounded)
        self.cachedEventStream = stream
        self.eventContinuation = continuation
    }
    
    // MARK: - Event Stream
    
    /// Stream of events from the gateway
    /// NOTE: This stream should only be iterated by ONE consumer.
    /// The stream is created eagerly in init() so events are never lost.
    public var events: AsyncStream<TmuxGatewayEvent> {
        return cachedEventStream
    }
    
    private func emit(_ event: TmuxGatewayEvent) {
        eventContinuation.yield(event)
    }
    
    // MARK: - Connection Setup
    
    /// Configure the write callback for sending commands
    /// - Parameter callback: Function to send string data to SSH channel
    public func setWriteCallback(_ callback: @escaping (String) -> Void) {
        self.writeCallback = callback
    }
    
    /// Generate the command to start control mode
    /// - Parameters:
    ///   - session: Session name to attach or create (e.g., "geistty-1")
    /// - Returns: Shell command string to start control mode
    public func makeAttachCommand(session: String) -> String {
        "exec tmux -CC new-session -A -s \(session)\n"
    }
    
    // MARK: - Data Reception
    
    /// Receive data from SSH channel
    /// Call this with each chunk of data received
    public func receive(_ data: Data) {
        // Debug logging
        if let str = String(data: data, encoding: .utf8) {
            logger.debug("Received \(data.count) bytes: \(str.prefix(200))")
        }
        
        // Parse using protocol parser
        let (messages, remainingBuffer, newBlockState) = parser.parse(
            data,
            buffer: parseBuffer,
            blockState: blockState
        )
        
        // Update state
        parseBuffer = remainingBuffer
        blockState = newBlockState
        
        // Process messages
        for message in messages {
            handleMessage(message)
        }
    }
    
    // MARK: - Message Handling
    
    private func handleMessage(_ message: TmuxMessage) {
        switch message {
        case .blockBegin(_, let commandNumber, _):
            // Map tmux command number to our pending command (FIFO)
            if !pendingCommands.isEmpty {
                let pending = pendingCommands[0]
                commandNumberMap[commandNumber] = pending.id
                logger.debug("Mapped tmux cmd \(commandNumber) -> \(pending.id)")
            }
            
        case .blockContent:
            // Content accumulated in blockState by parser
            break
            
        case .blockEnd(_, let commandNumber):
            if let block = blockState {
                finishBlock(block, commandNumber: commandNumber, success: true)
            }
            
        case .blockError(_, let commandNumber):
            if let block = blockState {
                finishBlock(block, commandNumber: commandNumber, success: false)
            }
            
        case .output(let paneId, let data), .extendedOutput(let paneId, _, let data):
            // Set active pane from first output if not yet known.
            // This is critical when our session's pane is not %0 (e.g., %2 when
            // another client already owns %0).
            if activePaneId == nil {
                logger.info("Setting activePaneId from first output: \(paneId)")
                activePaneId = paneId
            }
            
            // Append to buffer
            if paneBuffers[paneId] == nil {
                paneBuffers[paneId] = Data()
            }
            paneBuffers[paneId]?.append(data)
            
            // Emit event
            emit(.output(paneId: paneId, data: data))
            
        case .sessionChanged(let sessionId, let sessionName):
            logger.info("Session changed: \(sessionId) (\(sessionName))")
            notifyActivationIfNeeded()
            emit(.sessionChanged(sessionId: sessionId, sessionName: sessionName))
            
        case .layoutChanged(let windowId, let windowIndex, let layout):
            logger.debug("Layout changed: window \(windowId)")
            emit(.layoutChanged(windowId: windowId, windowIndex: windowIndex, layout: layout))
            
        case .windowAdd(let windowId):
            logger.debug("Window added: \(windowId)")
            emit(.windowAdded(windowId: windowId))
            
        case .windowClose(let windowId):
            logger.debug("Window closed: \(windowId)")
            emit(.windowClosed(windowId: windowId))
            
        case .windowPaneChanged(let windowId, let paneId):
            logger.info("Active pane changed: \(windowId) -> \(paneId)")
            activePaneId = paneId
            emit(.activePaneChanged(windowId: windowId, paneId: paneId))
            
        case .pause(let paneId):
            logger.info("Pane paused: \(paneId)")
            pausedPanes.insert(paneId)
            
        case .continue(let paneId):
            logger.info("Pane continued: \(paneId)")
            pausedPanes.remove(paneId)
            
        case .exit(let reason):
            logger.info("tmux exit: \(reason ?? "no reason")")
            isActive = false
            emit(.exited(reason: reason))
            
        case .sessionsChanged:
            logger.info("Sessions changed (session created or destroyed)")
            emit(.sessionsChanged)
            
        case .sessionRenamed, .sessionWindowChanged,
             .windowRenamed, .unlinkedWindowAdd, .unlinkedWindowClose, .unlinkedWindowRenamed,
             .clientSessionChanged, .clientDetached, .paneModeChanged, .pausePaneChanged,
             .subscriptionChanged, .unknown:
            // These are logged but not emitted as events
            // Add event cases as needed
            break
        }
    }
    
    private func finishBlock(_ block: TmuxBlockState, commandNumber: String, success: Bool) {
        let content = block.content
        
        logger.info("Block finished: cmd=\(commandNumber) success=\(success) lines=\(block.lines.count)")
        
        // Notify activation after first block
        notifyActivationIfNeeded()
        
        // Clean up mapping
        _ = commandNumberMap.removeValue(forKey: commandNumber)
        
        // Complete pending command (FIFO)
        if !pendingCommands.isEmpty {
            let pending = pendingCommands.removeFirst()
            pending.timeoutTask.cancel()
            
            logger.info("Completed command \(pending.id): \(pending.command.prefix(50))")
            
            if success {
                pending.continuation.resume(returning: content)
            } else {
                pending.continuation.resume(throwing: TmuxGatewayError.commandFailed(content))
            }
        } else {
            // Unsolicited response
            logger.info("Unsolicited response: cmd=\(commandNumber), \(content.count) chars")
        }
    }
    
    private func notifyActivationIfNeeded() {
        guard !hasNotifiedActivation else { return }
        hasNotifiedActivation = true
        isActive = true
        logger.info("Control mode activated")
        emit(.activated)
    }
    
    // MARK: - Connection Health
    
    /// Update connection health and manage command queue accordingly
    /// - Parameter health: New health state from NIOSSHConnection
    public func updateHealth(_ health: ConnectionHealth) {
        let previousHealth = connectionHealth
        connectionHealth = health
        
        switch health {
        case .healthy:
            if !previousHealth.isHealthy {
                logger.info("Connection restored, resuming command queue")
                resumeCommandQueue()
            }
            
        case .stale(let since):
            if previousHealth.isHealthy {
                logger.warning("Connection stale since \(since), pausing command queue")
                pauseCommandQueue()
            }
            
        case .dead(let reason):
            if previousHealth != health {
                logger.error("Connection dead: \(reason), failing queued commands")
                failQueuedCommands(error: TmuxGatewayError.disconnected)
            }
        }
    }
    
    /// Pause the command queue (stale connection)
    private func pauseCommandQueue() {
        isCommandQueuePaused = true
        // Commands already in-flight will time out naturally
        // New commands will be queued in queuedWhilePaused
    }
    
    /// Resume the command queue (connection restored)
    private func resumeCommandQueue() {
        isCommandQueuePaused = false
        
        // Flush queued commands
        let queued = queuedWhilePaused
        queuedWhilePaused.removeAll()
        
        logger.info("Flushing \(queued.count) queued commands")
        
        for (command, continuation) in queued {
            // Re-submit with the stored continuation
            Task {
                do {
                    let result = try await sendCommandInternal(command)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Fail all queued commands (dead connection)
    private func failQueuedCommands(error: Error) {
        isCommandQueuePaused = false
        
        // Fail queued-while-paused commands
        let queued = queuedWhilePaused
        queuedWhilePaused.removeAll()
        
        for (_, continuation) in queued {
            continuation.resume(throwing: error)
        }
        
        // Fail pending in-flight commands
        let pending = pendingCommands
        pendingCommands.removeAll()
        
        for cmd in pending {
            cmd.timeoutTask.cancel()
            cmd.continuation.resume(throwing: error)
        }
        
        logger.info("Failed \(queued.count + pending.count) commands due to connection death")
    }
    
    // MARK: - Commands (Async)
    
    /// Send a command and wait for response
    /// If connection is unhealthy, command is queued until connection restores
    /// - Parameter command: tmux command (without newline)
    /// - Returns: Command response content
    public func sendCommand(_ command: String) async throws -> String {
        // If paused, queue the command for later
        if isCommandQueuePaused {
            logger.debug("Connection unhealthy, queueing command: \(command.prefix(50))")
            return try await withCheckedThrowingContinuation { continuation in
                queuedWhilePaused.append((command: command, continuation: continuation))
            }
        }
        
        return try await sendCommandInternal(command)
    }
    
    /// Internal command send (always sends immediately)
    private func sendCommandInternal(_ command: String) async throws -> String {
        guard let write = writeCallback else {
            throw TmuxGatewayError.notConnected
        }
        
        commandCounter += 1
        let id = "cmd-\(commandCounter)"
        
        return try await withCheckedThrowingContinuation { continuation in
            // Create timeout task
            let timeoutTask = Task {
                try? await Task.sleep(for: commandTimeout)
                self.handleCommandTimeout(id: id)
            }
            
            let pending = PendingCommand(
                id: id,
                command: command,
                continuation: continuation,
                timeoutTask: timeoutTask
            )
            
            pendingCommands.append(pending)
            logger.debug("Queued command \(id): \(command.prefix(50))")
            
            // Send command
            write("\(command)\n")
        }
    }
    
    private func handleCommandTimeout(id: String) {
        if let index = pendingCommands.firstIndex(where: { $0.id == id }) {
            let pending = pendingCommands.remove(at: index)
            logger.warning("Command timed out: \(pending.command.prefix(50))")
            pending.continuation.resume(throwing: TmuxGatewayError.timeout)
        }
    }
    
    /// Send a command without waiting for response (fire-and-forget)
    /// Note: Fire-and-forget commands are still sent even if unhealthy
    /// - Parameter command: tmux command
    public func sendCommandFireAndForget(_ command: String) {
        guard let write = writeCallback else {
            logger.warning("Cannot send command - no write callback")
            return
        }
        
        if isCommandQueuePaused {
            logger.debug("Connection unhealthy, skipping fire-and-forget: \(command.prefix(50))")
            return
        }
        
        logger.debug("Fire-and-forget: \(command.prefix(50))")
        write("\(command)\n")
    }
    
    // MARK: - Input Handling
    
    /// Send keyboard input to a pane
    /// - Parameters:
    ///   - data: Raw keyboard input data
    ///   - paneId: Target pane (default: active pane)
    public func sendKeys(_ data: Data, toPaneId paneId: String? = nil) {
        guard let write = writeCallback else { return }
        
        guard let targetPane = paneId ?? activePaneId else {
            logger.warning("🔑 Cannot send keys — no active pane ID set yet")
            return
        }
        
        // Debug: log raw input
        let inputHex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        logger.info("🔑 Input: \(inputHex)")
        
        // Translate Kitty protocol to legacy codes
        let translatedData = keyboardTranslator.translate(data)
        
        // Debug: log translated output
        let outputHex = translatedData.map { String(format: "%02x", $0) }.joined(separator: " ")
        logger.info("🔑 Translated: \(outputHex)")
        
        // Encode as hex for send-keys -H
        let hexString = translatedData.map { String(format: "%02x", $0) }.joined(separator: " ")
        
        let command = "send-keys -H -t \(targetPane) \(hexString)"
        logger.debug("Sending keys: \(data.count) bytes to \(targetPane)")
        write("\(command)\n")
    }
    
    // MARK: - Pane Operations
    
    /// Capture pane content
    /// - Parameters:
    ///   - paneId: Target pane
    ///   - entireHistory: If true, capture full scrollback
    /// - Returns: Captured content
    public func capturePane(paneId: String = "%0", entireHistory: Bool = true) async throws -> String {
        var command = "capture-pane -pe -t \(paneId)"
        if entireHistory {
            command += " -S -"
        }
        
        return try await sendCommand(command)
    }
    
    /// Capture visible screen content for a pane (no scrollback).
    /// Used for session restore — captures only what's currently visible.
    /// - Parameter paneId: Target pane (e.g., "%0")
    /// - Returns: Captured ANSI content (visible screen only)
    public func capturePaneVisible(paneId: String = "%0") async throws -> String {
        return try await sendCommand("capture-pane -pe -t \(paneId)")
    }
    
    /// Pause a pane to freeze output delivery.
    /// While paused, tmux buffers %output internally.
    /// This is used during session restore to prevent race conditions
    /// between capture-pane and live output.
    /// - Parameter paneId: Target pane (e.g., "%0")
    /// - Note: This is an async command that waits for tmux to acknowledge
    ///         the pause, ensuring the command queue stays ordered.
    @discardableResult
    public func pausePane(paneId: String) async throws -> String {
        logger.info("⏸️ Pausing pane \(paneId)")
        pausedPanes.insert(paneId)
        return try await sendCommand("refresh-client -A '\(paneId):pause'")
    }
    
    /// Unpause a pane to resume output delivery.
    /// Buffered output will be delivered as %output/%continue messages.
    /// - Parameter paneId: Target pane (e.g., "%0")
    /// - Note: This is an async command that waits for tmux to acknowledge
    ///         the unpause, ensuring the command queue stays ordered.
    @discardableResult
    public func unpausePane(paneId: String) async throws -> String {
        logger.info("▶️ Unpausing pane \(paneId)")
        pausedPanes.remove(paneId)
        return try await sendCommand("refresh-client -A '\(paneId):continue'")
    }
    
    // MARK: - Terminal Size
    
    /// Notify tmux of terminal size change
    /// - Parameters:
    ///   - cols: Number of columns
    ///   - rows: Number of rows
    public func resize(cols: Int, rows: Int) {
        sendCommandFireAndForget("refresh-client -C \(cols),\(rows)")
    }
    
    // MARK: - Pause Mode (iOS Lifecycle)
    
    /// Enable pause mode for iOS app backgrounding
    /// - Parameter pauseAfter: Seconds of inactivity before pausing
    public func enablePauseMode(pauseAfter: Int = 1) {
        guard !isPauseEnabled else { return }
        isPauseEnabled = true
        sendCommandFireAndForget("refresh-client -f pause-after=\(pauseAfter)")
    }
    
    /// Disable pause mode
    public func disablePauseMode() {
        guard isPauseEnabled else { return }
        isPauseEnabled = false
        sendCommandFireAndForget("refresh-client -f pause-after=0")
    }
    
    /// Resume a paused pane
    /// - Parameter paneId: Pane to resume (default: active pane)
    public func resumePausedPane(paneId: String? = nil) {
        guard let targetPane = paneId ?? activePaneId else {
            logger.warning("Cannot resume pane — no active pane ID set yet")
            return
        }
        pausedPanes.remove(targetPane)
        sendCommandFireAndForget("refresh-client -A '\(targetPane):continue'")
    }
    
    /// Resume all paused panes
    public func resumeAllPausedPanes() {
        for paneId in pausedPanes {
            resumePausedPane(paneId: paneId)
        }
        // Also resume active pane if not tracked
        if let activePane = activePaneId, !pausedPanes.contains(activePane) {
            resumePausedPane(paneId: activePane)
        }
    }
    
    // MARK: - Scrollback Access
    
    /// Get pane buffer content
    /// - Parameter paneId: Target pane
    /// - Returns: Buffer data or nil
    public func getPaneBuffer(paneId: String = "%0") -> Data? {
        paneBuffers[paneId]
    }
    
    /// Clear a pane buffer
    /// - Parameter paneId: Target pane
    public func clearPaneBuffer(paneId: String = "%0") {
        paneBuffers[paneId] = nil
    }
    
    // MARK: - Reset
    
    /// Reset gateway state (on disconnect)
    public func reset() {
        isActive = false
        hasNotifiedActivation = false
        isPauseEnabled = false
        isCommandQueuePaused = false
        connectionHealth = .healthy
        activePaneId = nil
        pausedPanes.removeAll()
        parseBuffer = Data()
        blockState = nil
        paneBuffers.removeAll()
        commandNumberMap.removeAll()
        
        // Cancel and fail all pending commands
        let pending = pendingCommands
        pendingCommands.removeAll()
        
        for cmd in pending {
            cmd.timeoutTask.cancel()
            cmd.continuation.resume(throwing: TmuxGatewayError.disconnected)
        }
        
        // Fail queued-while-paused commands
        let queued = queuedWhilePaused
        queuedWhilePaused.removeAll()
        
        for (_, continuation) in queued {
            continuation.resume(throwing: TmuxGatewayError.disconnected)
        }
        
        logger.info("Gateway reset, cancelled \(pending.count + queued.count) pending/queued commands")
    }
}
