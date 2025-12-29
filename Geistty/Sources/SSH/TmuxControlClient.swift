//
//  TmuxControlClient.swift
//  Geistty
//
//  tmux Control Mode client for proper scrollback access.
//  Uses tmux's native protocol instead of marker-based capture-pane hacks.
//
//  Architecture:
//  - TmuxProtocolParser: Pure synchronous protocol parsing (extracted)
//  - KittyKeyboardTranslator: Keyboard input translation (extracted)
//  - TmuxControlClient: Coordinates parsing, command queue, and delegate callbacks
//
//  Control Mode Protocol:
//  - Start: `tmux -CC attach` or `tmux -CC new`
//  - Responses: %begin/%end/%error blocks
//  - Pane output: %output %pane-id <octal-escaped-data>
//  - Notifications: %session-changed, %window-add, etc.
//
//  Reference: https://github.com/tmux/tmux/wiki/Control-Mode
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.geistty", category: "TmuxControl")

// MARK: - Legacy Message Type (for delegate compatibility)

/// tmux Control Mode message types (legacy, for delegate callbacks)
/// NOTE: New code should use TmuxMessage from TmuxProtocolParser.swift
enum TmuxControlMessage {
    /// Command response - successful
    case response(commandId: String, data: String)
    
    /// Command response - error
    case error(commandId: String, message: String)
    
    /// Pane output notification
    case output(paneId: String, data: Data)
    
    /// Session notifications
    case sessionChanged(sessionId: String, sessionName: String)
    case sessionRenamed(sessionId: String, newName: String)
    case sessionsChanged  // Session created or destroyed
    case sessionWindowChanged(sessionId: String, windowId: String)
    
    /// Layout changed notification  
    case layoutChanged(windowId: String, windowIndex: Int, layout: String)
    
    /// Window notification (attached session)
    case windowAdd(windowId: String)
    case windowClose(windowId: String)
    case windowRenamed(windowId: String, name: String)
    case windowPaneChanged(windowId: String, paneId: String)  // Active pane changed
    
    /// Window notification (other sessions - "unlinked")
    case unlinkedWindowAdd(windowId: String)
    case unlinkedWindowClose(windowId: String)
    case unlinkedWindowRenamed(windowId: String, name: String)
    
    /// Client notification
    case clientSessionChanged(clientName: String, sessionId: String)
    case clientDetached(clientName: String)
    
    /// Pane notification
    case paneModeChanged(paneId: String)
    case pausePaneChanged(paneId: String)
    
    /// Pause/continue notifications (tmux 3.2+)
    case pause(paneId: String)
    case `continue`(paneId: String)
    
    /// Exit notification
    case exit(reason: String?)
    
    /// Subscription changed (format subscriptions)
    case subscriptionChanged(name: String, sessionId: String?, windowId: String?, paneId: String?, value: String)
    
    /// Unknown message type
    case unknown(line: String)
}

// NOTE: PendingBlock removed - we now use TmuxBlockState from TmuxProtocolParser

/// A pending command waiting for a response
private struct PendingCommand {
    let localId: String        // Our internal tracking ID
    let commandText: String    // The command that was sent
    let callback: (Result<String, Error>) -> Void
    let timeoutTask: Task<Void, Never>?
}

/// Delegate protocol for TmuxControlClient
@MainActor
protocol TmuxControlClientDelegate: AnyObject {
    /// Called when pane output is received
    func tmuxClient(_ client: TmuxControlClient, didReceivePaneOutput data: Data, paneId: String)
    
    /// Called when control mode becomes fully active (first protocol message received)
    func tmuxClientDidActivate(_ client: TmuxControlClient)
    
    /// Called when session content has been restored (after capture-pane)
    /// - Parameters:
    ///   - content: The captured pane content (plain text, no escape sequences)
    ///   - paneId: The pane ID
    ///   - paneState: Optional pane state with cursor position and dimensions
    func tmuxClient(_ client: TmuxControlClient, didRestoreSession content: String, paneId: String, paneState: TmuxControlClient.PaneState?)
    
    /// Called when a command completes successfully
    func tmuxClient(_ client: TmuxControlClient, commandDidComplete commandId: String, response: String)
    
    /// Called when a command fails
    func tmuxClient(_ client: TmuxControlClient, commandDidFail commandId: String, error: String)
    
    /// Called when the control client exits
    func tmuxClientDidExit(_ client: TmuxControlClient, reason: String?)
}

/// Client for tmux Control Mode (-CC)
/// 
/// Usage:
/// ```
/// let client = TmuxControlClient()
/// client.delegate = self
/// 
/// // Start control mode  
/// let startCommand = client.makeAttachCommand(session: "main")
/// sshSession.write(startCommand)
/// 
/// // Feed received SSH data to parser
/// sshSession.delegate = { data in
///     client.parse(data)
/// }
/// 
/// // Send commands
/// let capturePaneCmd = "capture-pane -p -t %0 -S - -E -"
/// let (cmdId, fullCmd) = client.sendCommand(capturePaneCmd)
/// // Response will come via delegate callback
/// ```
@MainActor
class TmuxControlClient {
    
    // MARK: - Properties
    
    weak var delegate: TmuxControlClientDelegate?
    
    /// Session manager for multi-pane state tracking (optional)
    weak var sessionManager: TmuxSessionManager?
    
    /// Whether control mode is currently active
    private(set) var isActive: Bool = false
    
    /// Whether we've notified the delegate about activation
    private var hasNotifiedActivation: Bool = false
    
    /// Command counter for generating unique IDs
    private var commandCounter: Int = 0
    
    /// Pending command queue - FIFO order matches tmux's response order
    /// tmux processes commands sequentially, so responses come back in order
    private var pendingCommandQueue: [PendingCommand] = []
    
    /// Mapping of tmux command numbers to our local command IDs
    /// Populated when we see %begin with the command number
    private var commandNumberToLocalId: [String: String] = [:]
    
    /// Current pane scrollback buffers (pane ID -> content)
    /// We maintain our own copy since we're the "terminal" for tmux
    private var paneBuffers: [String: Data] = [:]
    
    // MARK: - Parser State (delegated to TmuxProtocolParser)
    
    /// Protocol parser instance (pure, synchronous)
    private let parser = TmuxProtocolParser()
    
    /// Current block state for multi-line responses
    private var blockState: TmuxBlockState?
    
    /// Unparsed data buffer (for partial line handling)
    private var parseBuffer: Data = Data()
    
    // MARK: - Keyboard Translation
    
    /// Keyboard translator for converting Kitty protocol to legacy codes
    private let keyboardTranslator: KeyboardTranslator = KittyKeyboardTranslator()
    
    /// Active pane ID (for single-pane sessions)
    private(set) var activePaneId: String = "%0"
    
    /// Whether pause mode is currently enabled
    private(set) var isPauseEnabled: Bool = false
    
    /// Panes that are currently paused
    private var pausedPanes: Set<String> = []
    
    /// Number of scrollback lines to capture on session restore (default 10000)
    var sessionRestoreScrollback: Int = 10000
    
    /// Whether session restoration has been performed
    private var hasRestoredSession: Bool = false
    
    /// Pane state captured from list-panes (currently unused but kept for future use)
    struct PaneState {
        let cursorX: Int
        let cursorY: Int
        let width: Int
        let height: Int
        let isAlternateScreen: Bool
    }
    
    // MARK: - Initialization
    
    init() {}
    
    // MARK: - Command Generation
    
    /// Generate the command to start control mode with a new or attached session
    /// - Parameters:
    ///   - session: Session name to attach or create
    ///   - detachOnDestroy: Whether to detach (vs terminate) when session is destroyed
    /// - Returns: Shell command string to start control mode
    func makeAttachCommand(session: String = "main", detachOnDestroy: Bool = true) -> String {
        // tmux -CC new-session -A -s <name>
        // -CC: Control mode with echo of output
        // -A: Attach if exists, create if not
        // -s: Session name
        return "exec tmux -CC new-session -A -s \(session)\n"
    }
    
    /// Generate a command to send in control mode
    /// - Parameter command: The tmux command (e.g., "capture-pane -p -t %0")
    /// - Returns: Tuple of (commandId, fullCommand) - the commandId is used to match response
    func makeCommand(_ command: String) -> (id: String, command: String) {
        commandCounter += 1
        let timestamp = String(format: "%.6f", Date().timeIntervalSince1970)
        // In control mode, just send the command with a newline
        // The response will be wrapped in %begin/%end with the timestamp
        return (timestamp, "\(command)\n")
    }
    
    /// Send a command and register a callback for the response
    /// Commands are queued and matched to responses in FIFO order (tmux processes sequentially)
    func sendCommand(_ command: String, via write: (String) -> Void, completion: @escaping (Result<String, Error>) -> Void) {
        commandCounter += 1
        let localId = "cmd-\(commandCounter)"
        
        // Create timeout task
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)  // 10 seconds
            await MainActor.run {
                // Find and remove this command from queue
                if let index = self.pendingCommandQueue.firstIndex(where: { $0.localId == localId }) {
                    let cmd = self.pendingCommandQueue.remove(at: index)
                    logger.warning("Command timed out: \(cmd.commandText.prefix(50))")
                    cmd.callback(.failure(TmuxControlError.timeout))
                }
            }
        }
        
        let pending = PendingCommand(
            localId: localId,
            commandText: command,
            callback: completion,
            timeoutTask: timeoutTask
        )
        
        pendingCommandQueue.append(pending)
        logger.debug("Queued command \(localId): \(command.prefix(50))")
        
        // Send the command (tmux control mode just needs newline-terminated commands)
        write("\(command)\n")
    }
    
    /// Send a command without waiting for response (fire and forget)
    /// Use for commands where we don't care about the response
    func sendCommandFireAndForget(_ command: String, via write: (String) -> Void) {
        logger.debug("Fire-and-forget command: \(command.prefix(50))")
        write("\(command)\n")
    }
    
    // MARK: - Input Handling
    
    // NOTE: Kitty keyboard protocol translation moved to KittyKeyboardTranslator.swift
    
    /// Send user input to a pane via send-keys command
    /// In control mode, we can't send raw characters - they would be interpreted as tmux commands.
    /// Instead, we use the `send-keys` command to deliver input to the target pane.
    ///
    /// - Parameters:
    ///   - data: The raw input data (from keyboard)
    ///   - paneId: Target pane ID (default: active pane)
    /// - Returns: The command string to send to tmux
    func makeSendKeysCommand(for data: Data, toPaneId paneId: String? = nil) -> String {
        let targetPane = paneId ?? activePaneId
        
        // Translate Kitty keyboard protocol sequences to legacy terminal codes
        // This handles the case where Ghostty sends Ctrl+C as ESC[99;5u instead of 0x03
        // Uses the injected keyboard translator (KittyKeyboardTranslator by default)
        let translatedData = keyboardTranslator.translate(data)
        
        // For send-keys, we use -l (literal) to send the exact characters.
        // We need to escape special characters for the tmux command line.
        // Using hex keys (-H) is the most reliable way to send arbitrary bytes.
        let hexString = translatedData.map { String(format: "%02x", $0) }.joined(separator: " ")
        
        // send-keys -H sends hex-encoded bytes directly
        // -t specifies target pane
        return "send-keys -H -t \(targetPane) \(hexString)\n"
    }
    
    /// Convenience method to send keys immediately
    func sendKeys(_ data: Data, toPaneId paneId: String? = nil, via write: (String) -> Void) {
        let command = makeSendKeysCommand(for: data, toPaneId: paneId)
        logger.debug("Sending keys: \(data.count) bytes -> \(command.prefix(50))")
        write(command)
    }
    
    // MARK: - Parsing (delegated to TmuxProtocolParser)
    
    /// Parse incoming data from tmux control mode
    /// Call this with each chunk of data received from SSH
    func parse(_ data: Data) {
        // Debug: log raw data
        if let str = String(data: data, encoding: .utf8) {
            logger.debug("Raw data received (\(data.count) bytes): \(str.prefix(200))")
        }
        
        // Delegate to pure protocol parser
        let (messages, remainingBuffer, newBlockState) = parser.parse(
            data,
            buffer: parseBuffer,
            blockState: blockState
        )
        
        // Update local state
        parseBuffer = remainingBuffer
        blockState = newBlockState
        
        // Process each parsed message
        for message in messages {
            handleParsedMessage(message)
        }
    }
    
    // MARK: - Message Handling (converts TmuxMessage to existing flow)
    
    /// Handle a parsed message from TmuxProtocolParser
    private func handleParsedMessage(_ message: TmuxMessage) {
        switch message {
        case .blockBegin(_, let commandNumber, _):
            // Map this tmux command number to our first pending command (FIFO)
            if !pendingCommandQueue.isEmpty {
                let pending = pendingCommandQueue[0]
                commandNumberToLocalId[commandNumber] = pending.localId
                logger.debug("Mapped tmux cmd \(commandNumber) -> \(pending.localId)")
            }
            // Don't trigger activation here - wait until first block completes
            
        case .blockContent:
            // Content is accumulated in blockState by the parser
            // Nothing to do here - we process it when block ends
            break
            
        case .blockEnd(_, let commandNumber):
            // Block complete - process the accumulated content
            if let block = blockState {
                finishBlockFromParser(block, commandNumber: commandNumber, success: true)
            }
            
        case .blockError(_, let commandNumber):
            // Block error - process with error
            if let block = blockState {
                finishBlockFromParser(block, commandNumber: commandNumber, success: false)
            }
            
        case .output(let paneId, let data), .extendedOutput(let paneId, _, let data):
            // Append to pane buffer
            if paneBuffers[paneId] == nil {
                paneBuffers[paneId] = Data()
            }
            paneBuffers[paneId]?.append(data)
            
            // Notify delegate
            delegate?.tmuxClient(self, didReceivePaneOutput: data, paneId: paneId)
            
        case .sessionChanged(let sessionId, let sessionName):
            logger.info("Session changed: \(sessionId) (\(sessionName))")
            notifyActivationIfNeeded()
            sessionManager?.handleSessionChanged(sessionId: sessionId, sessionName: sessionName)
            
        case .sessionRenamed(let sessionId, let newName):
            logger.info("Session renamed: \(sessionId) -> \(newName)")
            
        case .sessionsChanged:
            logger.info("Sessions changed (session created or destroyed)")
            sessionManager?.handleSessionsChanged()
            
        case .sessionWindowChanged(let sessionId, let windowId):
            logger.info("Session window changed: \(sessionId) -> \(windowId)")
            sessionManager?.handleSessionWindowChanged(sessionId: sessionId, windowId: windowId)
            
        case .layoutChanged(let windowId, let windowIndex, let layout):
            logger.debug("Layout changed: window \(windowId) index \(windowIndex)")
            sessionManager?.handleLayoutChanged(windowId: windowId, windowIndex: windowIndex, layout: layout)
            
        case .windowAdd(let windowId):
            logger.debug("Window added: \(windowId)")
            sessionManager?.handleWindowAdd(windowId: windowId)
            
        case .windowClose(let windowId):
            logger.debug("Window closed: \(windowId)")
            sessionManager?.handleWindowClose(windowId: windowId)
            
        case .windowRenamed(let windowId, let name):
            logger.debug("Window renamed: \(windowId) -> \(name)")
            sessionManager?.handleWindowRenamed(windowId: windowId, name: name)
            
        case .windowPaneChanged(let windowId, let paneId):
            logger.info("Window pane changed: \(windowId) -> \(paneId)")
            activePaneId = paneId
            sessionManager?.handleWindowPaneChanged(windowId: windowId, paneId: paneId)
            
        case .unlinkedWindowAdd(let windowId):
            logger.debug("Unlinked window added: \(windowId)")
            
        case .unlinkedWindowClose(let windowId):
            logger.debug("Unlinked window closed: \(windowId)")
            
        case .unlinkedWindowRenamed(let windowId, let name):
            logger.debug("Unlinked window renamed: \(windowId) -> \(name)")
            
        case .clientSessionChanged(let clientName, let sessionId):
            logger.debug("Client session changed: \(clientName) -> \(sessionId)")
            
        case .clientDetached(let clientName):
            logger.info("Client detached: \(clientName)")
            
        case .paneModeChanged(let paneId):
            logger.debug("Pane mode changed: \(paneId)")
            sessionManager?.handlePaneModeChanged(paneId: paneId)
            
        case .pausePaneChanged(let paneId):
            logger.debug("Pause pane changed: \(paneId)")
            
        case .pause(let paneId):
            logger.info("Pane paused: \(paneId)")
            pausedPanes.insert(paneId)
            
        case .continue(let paneId):
            logger.info("Pane continued: \(paneId)")
            pausedPanes.remove(paneId)
            
        case .subscriptionChanged(let name, let sessionId, let windowId, let paneId, let value):
            logger.debug("Subscription '\(name)' changed: session=\(sessionId ?? "-") window=\(windowId ?? "-") pane=\(paneId ?? "-") value=\(value)")
            
        case .exit(let reason):
            logger.info("tmux control mode exit: \(reason ?? "no reason")")
            isActive = false
            delegate?.tmuxClientDidExit(self, reason: reason)
            
        case .unknown(let line):
            // Check if this looks like the control mode prompt
            if line.isEmpty || line.contains("[") {
                // Likely startup or prompt line
            } else {
                logger.debug("Unknown control message: \(line)")
            }
        }
    }
    
    /// Finish a pending block using TmuxBlockState from parser
    private func finishBlockFromParser(_ block: TmuxBlockState, commandNumber: String, success: Bool) {
        let content = block.content
        
        logger.info("Block finished: cmd=\(commandNumber) success=\(success) lines=\(block.lines.count) content='\(content.prefix(100))'")
        
        // Notify activation after first block completes
        notifyActivationIfNeeded()
        
        // Clean up the command number mapping
        _ = commandNumberToLocalId.removeValue(forKey: commandNumber)
        
        // Find and remove the matching pending command from the queue (FIFO)
        if !pendingCommandQueue.isEmpty {
            let pending = pendingCommandQueue.removeFirst()
            
            // Cancel the timeout task
            pending.timeoutTask?.cancel()
            
            logger.info("📜 Matched response to command \(pending.localId): \(pending.commandText.prefix(50)), content length=\(content.count)")
            
            if success {
                pending.callback(.success(content))
                delegate?.tmuxClient(self, commandDidComplete: pending.localId, response: content)
            } else {
                pending.callback(.failure(TmuxControlError.commandFailed(content)))
                delegate?.tmuxClient(self, commandDidFail: pending.localId, error: content)
            }
        } else {
            // No pending command - this is an unsolicited response
            if success {
                logger.info("📜 Unsolicited response block: cmd=\(commandNumber), content length=\(content.count)")
            } else {
                logger.warning("📜 Unsolicited error block: cmd=\(commandNumber) - \(content)")
            }
        }
    }
    
    /// Notify delegate that control mode is now active (once)
    private func notifyActivationIfNeeded() {
        guard !hasNotifiedActivation else { return }
        hasNotifiedActivation = true
        isActive = true
        logger.info("Control mode activated, notifying delegate")
        delegate?.tmuxClientDidActivate(self)
    }
    
    // MARK: - Scrollback Access
    
    /// Get the current pane buffer content
    func getPaneBuffer(paneId: String = "%0") -> Data? {
        return paneBuffers[paneId]
    }
    
    /// Get all pane content as a string
    func getPaneContentString(paneId: String = "%0") -> String? {
        guard let data = paneBuffers[paneId] else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
    /// Clear a pane buffer
    func clearPaneBuffer(paneId: String = "%0") {
        paneBuffers[paneId] = nil
    }
    
    /// Capture pane content using capture-pane command
    /// - Parameters:
    ///   - paneId: The pane ID (default %0)
    ///   - entireHistory: If true, captures entire history (-S - -E -)
    ///   - write: Function to send data to SSH
    ///   - completion: Called with captured content or error
    func capturePaneContent(
        paneId: String = "%0",
        entireHistory: Bool = true,
        via write: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        var command = "capture-pane -p -t \(paneId)"
        if entireHistory {
            command += " -S - -E -"
        }
        
        sendCommand(command, via: write, completion: completion)
    }
    
    // MARK: - Session Restoration
    
    /// Restore session content by capturing the pane history.
    /// This should be called after control mode activates to populate
    /// the terminal with existing session content.
    ///
    /// Uses `capture-pane -p` flags:
    /// - `-p` - output to stdout (we get it via %begin/%end)
    /// - `-S -N` - capture N lines of scrollback
    ///
    /// NOTE: We intentionally do NOT use:
    /// - `-e` (escape sequences) - causes cursor positioning issues
    /// - `-J` (join wrapped lines) - destroys line structure
    ///
    /// - Parameters:
    ///   - paneId: The pane ID (default %0)
    ///   - write: Function to send data to SSH
    func restoreSession(paneId: String = "%0", via write: @escaping (String) -> Void) {
        guard !hasRestoredSession else {
            logger.debug("Session already restored, skipping")
            return
        }
        
        hasRestoredSession = true
        restorePaneHistory(paneId: paneId, via: write)
    }
    
    /// Restore scrollback history for a specific pane
    /// Unlike restoreSession(), this can be called multiple times for different panes
    ///
    /// - Parameters:
    ///   - paneId: The pane ID (e.g., "%0", "%1")
    ///   - write: Function to send data to SSH
    func restorePaneHistory(paneId: String, via write: @escaping (String) -> Void) {
        // Capture pane content with escape sequences for colors/formatting
        // -p: output to stdout (control mode captures in %begin/%end)
        // -e: include escape sequences for text and background attributes
        // -t: target pane
        // -S -: start from beginning of history (capture all scrollback)
        // Note: We don't use -J (join) as it destroys line breaks
        let captureCommand = "capture-pane -pe -t \(paneId) -S -"
        logger.info("📜 Sending capture-pane command for \(paneId): \(captureCommand)")
        
        // Use proper command routing - the response will come back via callback
        sendCommand(captureCommand, via: write) { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let content):
                logger.info("📜 Pane history received for \(paneId): \(content.count) chars")
                self.delegate?.tmuxClient(self, didRestoreSession: content, paneId: paneId, paneState: nil)
                
            case .failure(let error):
                logger.error("📜 Pane history restore failed for \(paneId): \(error.localizedDescription)")
                // Still notify delegate with empty content so UI can proceed
                self.delegate?.tmuxClient(self, didRestoreSession: "", paneId: paneId, paneState: nil)
            }
        }
    }
    
    // MARK: - Pause Mode (iOS App Lifecycle)
    
    /// Enable pause mode for flow control (tmux 3.2+).
    /// When enabled, tmux buffers output instead of sending it.
    /// This prevents data loss when iOS suspends the app.
    ///
    /// - Parameters:
    ///   - pauseAfter: Seconds of inactivity before pausing (default 1)
    ///   - write: Function to send data to SSH
    func enablePauseMode(pauseAfter: Int = 1, via write: @escaping (String) -> Void) {
        guard !isPauseEnabled else {
            logger.debug("Pause mode already enabled")
            return
        }
        
        isPauseEnabled = true  // Optimistically set
        
        // Fire-and-forget: just send the command
        let command = "refresh-client -f pause-after=\(pauseAfter)\n"
        logger.info("Enabling pause mode (fire-and-forget): \(command.trimmingCharacters(in: .newlines))")
        write(command)
    }
    
    /// Disable pause mode.
    ///
    /// - Parameter write: Function to send data to SSH
    func disablePauseMode(via write: @escaping (String) -> Void) {
        guard isPauseEnabled else { return }
        
        isPauseEnabled = false
        
        // Fire-and-forget
        let command = "refresh-client -f pause-after=0\n"
        logger.info("Disabling pause mode (fire-and-forget)")
        write(command)
    }
    
    /// Resume a paused pane.
    /// Call this when the app comes back to foreground.
    ///
    /// - Parameters:
    ///   - paneId: The pane ID to resume (default: active pane)
    ///   - write: Function to send data to SSH
    func resumePausedPane(paneId: String? = nil, via write: @escaping (String) -> Void) {
        let targetPane = paneId ?? activePaneId
        
        // Fire-and-forget
        let command = "refresh-client -A '\(targetPane):continue'\n"
        logger.info("Resuming paused pane (fire-and-forget): \(targetPane)")
        pausedPanes.remove(targetPane)
        write(command)
    }
    
    /// Resume all paused panes.
    /// Call this when the app comes back to foreground.
    ///
    /// - Parameter write: Function to send data to SSH
    func resumeAllPausedPanes(via write: @escaping (String) -> Void) {
        for paneId in pausedPanes {
            resumePausedPane(paneId: paneId, via: write)
        }
        
        // Also resume the active pane in case it wasn't tracked
        if !pausedPanes.contains(activePaneId) {
            resumePausedPane(paneId: activePaneId, via: write)
        }
    }
    
    // MARK: - Terminal Size
    
    /// Notify tmux of terminal size change.
    /// This must be called when the terminal view resizes (rotation, split view, etc.).
    ///
    /// - Parameters:
    ///   - cols: Number of columns
    ///   - rows: Number of rows
    ///   - write: Function to send data to SSH
    func resize(cols: Int, rows: Int, via write: @escaping (String) -> Void) {
        // refresh-client -C cols,rows tells tmux the new size
        let command = "refresh-client -C \(cols),\(rows)\n"
        logger.info("Resizing tmux client to \(cols)x\(rows)")
        write(command)
    }
    
    // MARK: - Reset
    
    /// Reset the client state
    func reset() {
        isActive = false
        hasNotifiedActivation = false
        hasRestoredSession = false
        isPauseEnabled = false
        pausedPanes.removeAll()
        parseBuffer = Data()
        
        // CRITICAL: Cancel timeouts AND invoke callbacks with failure
        // This prevents callers from waiting forever for responses that will never come
        let pendingCommands = pendingCommandQueue
        pendingCommandQueue.removeAll()
        commandNumberToLocalId.removeAll()
        
        for pending in pendingCommands {
            pending.timeoutTask?.cancel()
            // Invoke callback with disconnected error so callers can clean up
            pending.callback(.failure(TmuxControlError.notConnected))
        }
        
        paneBuffers.removeAll()
        
        logger.info("🔌 TmuxControlClient reset, notified \(pendingCommands.count) pending command(s) of disconnect")
    }
}

// MARK: - Errors

enum TmuxControlError: LocalizedError {
    case timeout
    case commandFailed(String)
    case notConnected
    case parseError(String)
    
    var errorDescription: String? {
        switch self {
        case .timeout:
            return "tmux command timed out"
        case .commandFailed(let message):
            return "tmux command failed: \(message)"
        case .notConnected:
            return "Not connected to tmux"
        case .parseError(let message):
            return "Parse error: \(message)"
        }
    }
}
