//
//  TmuxProtocolParser.swift
//  Geistty
//
//  Pure synchronous parser for tmux Control Mode protocol.
//  No async, no state machine side effects - just `parse(Data) -> [TmuxMessage]`.
//
//  This separation follows the iTerm2 VT100TmuxParser pattern where parsing
//  is decoupled from session management and command routing.
//
//  Reference: https://github.com/tmux/tmux/wiki/Control-Mode
//

import Foundation

// MARK: - Protocol Messages

/// tmux Control Mode message types
/// These represent the parsed output from tmux -CC
public enum TmuxMessage: Equatable, Sendable {
    // MARK: - Command Responses
    
    /// Start of a command response block
    /// Contains: timestamp, command number (tmux-assigned sequential ID), flags
    case blockBegin(timestamp: String, commandNumber: String, flags: String)
    
    /// Content line within a %begin/%end block
    case blockContent(line: String)
    
    /// End of a successful command response block
    case blockEnd(timestamp: String, commandNumber: String)
    
    /// End of a failed command response block
    case blockError(timestamp: String, commandNumber: String)
    
    // MARK: - Pane Output
    
    /// Pane output notification - raw terminal data
    /// Format: %output %pane-id <octal-escaped-data>
    case output(paneId: String, data: Data)
    
    /// Extended output (tmux 3.2+ with pause mode)
    /// Format: %extended-output %pane-id latency : <octal-escaped-data>
    case extendedOutput(paneId: String, latency: String, data: Data)
    
    // MARK: - Session Notifications
    
    /// Session changed (attached to different session)
    case sessionChanged(sessionId: String, sessionName: String)
    
    /// Session was renamed
    case sessionRenamed(sessionId: String, newName: String)
    
    /// A session was created or destroyed
    case sessionsChanged
    
    /// Active window changed in a session
    case sessionWindowChanged(sessionId: String, windowId: String)
    
    // MARK: - Window Notifications (Attached Session)
    
    /// Window added to attached session
    case windowAdd(windowId: String)
    
    /// Window closed in attached session
    case windowClose(windowId: String)
    
    /// Window renamed in attached session
    case windowRenamed(windowId: String, name: String)
    
    /// Active pane changed in a window
    case windowPaneChanged(windowId: String, paneId: String)
    
    /// Layout changed for a window
    case layoutChanged(windowId: String, windowIndex: Int, layout: String)
    
    // MARK: - Window Notifications (Other Sessions - "Unlinked")
    
    /// Window added to another session
    case unlinkedWindowAdd(windowId: String)
    
    /// Window closed in another session
    case unlinkedWindowClose(windowId: String)
    
    /// Window renamed in another session
    case unlinkedWindowRenamed(windowId: String, name: String)
    
    // MARK: - Client Notifications
    
    /// Client switched to different session
    case clientSessionChanged(clientName: String, sessionId: String)
    
    /// Client detached
    case clientDetached(clientName: String)
    
    // MARK: - Pane Notifications
    
    /// Pane mode changed (e.g., copy mode entered/exited)
    case paneModeChanged(paneId: String)
    
    /// Pause state changed for pane
    case pausePaneChanged(paneId: String)
    
    /// Pane output paused (tmux 3.2+)
    case pause(paneId: String)
    
    /// Pane output resumed (tmux 3.2+)
    case `continue`(paneId: String)
    
    // MARK: - Subscription Notifications
    
    /// Format subscription value changed
    case subscriptionChanged(name: String, sessionId: String?, windowId: String?, paneId: String?, value: String)
    
    // MARK: - Control Flow
    
    /// Control mode exit
    case exit(reason: String?)
    
    /// Unrecognized or non-control line
    case unknown(line: String)
}

// MARK: - Parser State

/// State for parsing multi-line %begin/%end blocks
public struct TmuxBlockState: Equatable, Sendable {
    public let commandNumber: String
    public let timestamp: String
    public var lines: [String]
    
    public init(commandNumber: String, timestamp: String, lines: [String] = []) {
        self.commandNumber = commandNumber
        self.timestamp = timestamp
        self.lines = lines
    }
}

// MARK: - Parser

/// Pure synchronous parser for tmux Control Mode protocol.
///
/// Usage:
/// ```swift
/// let parser = TmuxProtocolParser()
/// let (messages, newState) = parser.parse(data, currentBlockState: nil)
/// for message in messages {
///     handleMessage(message)
/// }
/// ```
///
/// The parser is stateless except for the block state passed in and returned.
/// This allows the caller to manage state storage (useful for actors).
public struct TmuxProtocolParser: Sendable {
    
    public init() {}
    
    // MARK: - Main Parse Entry Point
    
    /// Parse incoming data from tmux control mode.
    ///
    /// - Parameters:
    ///   - data: Raw data received from SSH
    ///   - buffer: Unparsed data from previous call (partial lines)
    ///   - blockState: Current %begin/%end block state, if inside a block
    ///
    /// - Returns: Tuple of (parsed messages, remaining buffer, updated block state)
    public func parse(
        _ data: Data,
        buffer: Data,
        blockState: TmuxBlockState?
    ) -> (messages: [TmuxMessage], remainingBuffer: Data, blockState: TmuxBlockState?) {
        var parseBuffer = buffer
        parseBuffer.append(data)
        
        var messages: [TmuxMessage] = []
        var currentBlockState = blockState
        
        // Process complete lines (newline-terminated)
        while let newlineIndex = parseBuffer.firstIndex(of: 0x0A) {
            let lineData = parseBuffer[..<newlineIndex]
            parseBuffer = Data(parseBuffer[(newlineIndex + 1)...])
            
            guard let line = String(data: lineData, encoding: .utf8) else {
                continue
            }
            
            // Remove trailing \r if present (tmux sends \r\n)
            let trimmedLine = line.hasSuffix("\r") ? String(line.dropLast()) : line
            
            // Parse the line, potentially updating block state
            let (lineMessages, updatedBlockState) = parseLine(trimmedLine, blockState: currentBlockState)
            messages.append(contentsOf: lineMessages)
            currentBlockState = updatedBlockState
        }
        
        return (messages, parseBuffer, currentBlockState)
    }
    
    // MARK: - Line Parsing
    
    /// Parse a single line of control mode output.
    ///
    /// - Parameters:
    ///   - line: A complete line (without newline)
    ///   - blockState: Current block state if inside %begin/%end
    ///
    /// - Returns: Tuple of (messages to emit, updated block state)
    public func parseLine(
        _ line: String,
        blockState: TmuxBlockState?
    ) -> (messages: [TmuxMessage], blockState: TmuxBlockState?) {
        // Inside a %begin/%end block?
        if var block = blockState {
            if line.hasPrefix("%end ") {
                // Block complete - emit blockEnd
                let parts = line.dropFirst(5).split(separator: " ")
                let timestamp = parts.count > 0 ? String(parts[0]) : block.timestamp
                let cmdNum = parts.count > 1 ? String(parts[1]) : block.commandNumber
                return ([.blockEnd(timestamp: timestamp, commandNumber: cmdNum)], nil)
                
            } else if line.hasPrefix("%error ") {
                // Block error - emit blockError
                let parts = line.dropFirst(7).split(separator: " ")
                let timestamp = parts.count > 0 ? String(parts[0]) : block.timestamp
                let cmdNum = parts.count > 1 ? String(parts[1]) : block.commandNumber
                return ([.blockError(timestamp: timestamp, commandNumber: cmdNum)], nil)
                
            } else if line.hasPrefix("%") {
                // Notification interleaved inside block - parse separately but keep block open
                let notificationMessage = parseControlMessage(line)
                return ([notificationMessage], block)
                
            } else {
                // Content line inside block
                block.lines.append(line)
                return ([.blockContent(line: line)], block)
            }
        }
        
        // Not inside a block - parse as control message
        let message = parseControlMessage(line)
        
        // Check if this starts a new block
        if case .blockBegin(_, let commandNumber, _) = message {
            // Extract timestamp from the message
            let parts = line.dropFirst(7).split(separator: " ")
            let timestamp = parts.count > 0 ? String(parts[0]) : ""
            let newBlock = TmuxBlockState(commandNumber: commandNumber, timestamp: timestamp)
            return ([message], newBlock)
        }
        
        return ([message], nil)
    }
    
    // MARK: - Control Message Parsing
    
    /// Parse a single control mode message line.
    public func parseControlMessage(_ line: String) -> TmuxMessage {
        guard line.hasPrefix("%") else {
            return .unknown(line: line)
        }
        
        // Split on first space
        let parts = line.split(separator: " ", maxSplits: 1)
        guard !parts.isEmpty else {
            return .unknown(line: line)
        }
        
        let messageType = String(parts[0])
        let rest = parts.count > 1 ? String(parts[1]) : ""
        
        switch messageType {
        case "%begin":
            // %begin <timestamp> <command-number> <flags>
            let beginParts = rest.split(separator: " ")
            let timestamp = beginParts.count > 0 ? String(beginParts[0]) : ""
            let commandNumber = beginParts.count > 1 ? String(beginParts[1]) : "0"
            let flags = beginParts.count > 2 ? String(beginParts[2]) : "0"
            return .blockBegin(timestamp: timestamp, commandNumber: commandNumber, flags: flags)
            
        case "%output":
            // %output <pane-id> <octal-escaped-data>
            let outputParts = rest.split(separator: " ", maxSplits: 1)
            if outputParts.count >= 2 {
                let paneId = String(outputParts[0])
                let escapedData = String(outputParts[1])
                if let decodedData = decodeOctalEscapes(escapedData) {
                    return .output(paneId: paneId, data: decodedData)
                }
            }
            return .unknown(line: line)
            
        case "%extended-output":
            // %extended-output %<pane-id> <latency> : <octal-escaped-data>
            if let colonRange = rest.range(of: " : ") {
                let prefix = rest[..<colonRange.lowerBound]
                let prefixParts = prefix.split(separator: " ")
                
                if prefixParts.count >= 1 {
                    let paneId = String(prefixParts[0])
                    let latency = prefixParts.count > 1 ? String(prefixParts[1]) : "0"
                    let escapedData = String(rest[colonRange.upperBound...])
                    
                    if let decodedData = decodeOctalEscapes(escapedData) {
                        return .extendedOutput(paneId: paneId, latency: latency, data: decodedData)
                    }
                }
            }
            return .unknown(line: line)
            
        case "%session-changed":
            // %session-changed $<id> <name>
            let sessionParts = rest.split(separator: " ", maxSplits: 1)
            if sessionParts.count >= 2 {
                return .sessionChanged(sessionId: String(sessionParts[0]), sessionName: String(sessionParts[1]))
            }
            return .unknown(line: line)
            
        case "%session-renamed":
            // %session-renamed $session name
            let parts = rest.split(separator: " ", maxSplits: 1)
            if parts.count >= 2 {
                return .sessionRenamed(sessionId: String(parts[0]), newName: String(parts[1]))
            }
            return .unknown(line: line)
            
        case "%sessions-changed":
            return .sessionsChanged
            
        case "%session-window-changed":
            // %session-window-changed $session @window
            let parts = rest.split(separator: " ")
            if parts.count >= 2 {
                return .sessionWindowChanged(sessionId: String(parts[0]), windowId: String(parts[1]))
            }
            return .unknown(line: line)
            
        case "%layout-change":
            // %layout-change @<window-id> <window-index> <layout>
            let layoutParts = rest.split(separator: " ", maxSplits: 2)
            if layoutParts.count >= 3 {
                let windowId = String(layoutParts[0])
                let windowIndex = Int(layoutParts[1]) ?? 0
                let layout = String(layoutParts[2])
                return .layoutChanged(windowId: windowId, windowIndex: windowIndex, layout: layout)
            }
            return .unknown(line: line)
            
        case "%window-add":
            return .windowAdd(windowId: rest)
            
        case "%window-close":
            return .windowClose(windowId: rest)
            
        case "%window-renamed":
            let parts = rest.split(separator: " ", maxSplits: 1)
            if parts.count >= 2 {
                return .windowRenamed(windowId: String(parts[0]), name: String(parts[1]))
            }
            return .unknown(line: line)
            
        case "%window-pane-changed":
            // %window-pane-changed @window %pane
            let parts = rest.split(separator: " ")
            if parts.count >= 2 {
                return .windowPaneChanged(windowId: String(parts[0]), paneId: String(parts[1]))
            }
            return .unknown(line: line)
            
        case "%unlinked-window-add":
            return .unlinkedWindowAdd(windowId: rest)
            
        case "%unlinked-window-close":
            return .unlinkedWindowClose(windowId: rest)
            
        case "%unlinked-window-renamed":
            let parts = rest.split(separator: " ", maxSplits: 1)
            if parts.count >= 2 {
                return .unlinkedWindowRenamed(windowId: String(parts[0]), name: String(parts[1]))
            }
            return .unknown(line: line)
            
        case "%client-session-changed":
            let parts = rest.split(separator: " ", maxSplits: 1)
            if parts.count >= 2 {
                return .clientSessionChanged(clientName: String(parts[0]), sessionId: String(parts[1]))
            }
            return .unknown(line: line)
            
        case "%client-detached":
            return .clientDetached(clientName: rest)
            
        case "%pane-mode-changed":
            return .paneModeChanged(paneId: rest)
            
        case "%pause-pane-changed":
            return .pausePaneChanged(paneId: rest)
            
        case "%pause":
            return .pause(paneId: rest)
            
        case "%continue":
            return .continue(paneId: rest)
            
        case "%subscription-changed":
            // %subscription-changed name session-id window-id pane-id value
            let parts = rest.split(separator: " ", maxSplits: 4)
            if parts.count >= 5 {
                let name = String(parts[0])
                let sessionId = parts[1] == "-" ? nil : String(parts[1])
                let windowId = parts[2] == "-" ? nil : String(parts[2])
                let paneId = parts[3] == "-" ? nil : String(parts[3])
                let value = String(parts[4])
                return .subscriptionChanged(name: name, sessionId: sessionId, windowId: windowId, paneId: paneId, value: value)
            }
            return .unknown(line: line)
            
        case "%exit":
            return .exit(reason: rest.isEmpty ? nil : rest)
            
        default:
            return .unknown(line: line)
        }
    }
    
    // MARK: - Octal Escape Decoding
    
    /// Decode octal escapes in tmux control mode output.
    /// Characters < 32 and `\` are encoded as octal (e.g., \033 for ESC, \134 for \)
    public func decodeOctalEscapes(_ string: String) -> Data? {
        var result = Data()
        var index = string.startIndex
        
        while index < string.endIndex {
            let char = string[index]
            
            if char == "\\" {
                // Potential octal escape
                let afterBackslash = string.index(after: index)
                if afterBackslash < string.endIndex {
                    var octalDigits = ""
                    var scanIndex = afterBackslash
                    
                    // Read up to 3 octal digits
                    while scanIndex < string.endIndex && octalDigits.count < 3 {
                        let c = string[scanIndex]
                        if c >= "0" && c <= "7" {
                            octalDigits.append(c)
                            scanIndex = string.index(after: scanIndex)
                        } else {
                            break
                        }
                    }
                    
                    if !octalDigits.isEmpty, let value = UInt8(octalDigits, radix: 8) {
                        // Valid octal escape
                        result.append(value)
                        index = scanIndex
                        continue
                    }
                }
                
                // Not a valid octal escape - output backslash literally
                result.append(UInt8(ascii: "\\"))
                index = string.index(after: index)
            } else {
                // Regular character
                let scalar = char.unicodeScalars.first!
                if scalar.value < 128 {
                    result.append(UInt8(scalar.value))
                } else {
                    // Multi-byte UTF-8
                    result.append(contentsOf: String(char).utf8)
                }
                index = string.index(after: index)
            }
        }
        
        return result
    }
}

// MARK: - Block Content Helper

extension TmuxBlockState {
    /// Get the accumulated content as a single string
    public var content: String {
        lines.joined(separator: "\n")
    }
}
