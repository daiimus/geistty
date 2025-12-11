//
//  TmuxControlClient.swift
//  Bodak
//
//  tmux Control Mode client for proper scrollback access.
//  Uses tmux's native protocol instead of marker-based capture-pane hacks.
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

private let logger = Logger(subsystem: "com.bodak", category: "TmuxControl")

/// tmux Control Mode message types
enum TmuxControlMessage {
    /// Command response - successful
    case response(commandId: String, data: String)
    
    /// Command response - error
    case error(commandId: String, message: String)
    
    /// Pane output notification
    case output(paneId: String, data: Data)
    
    /// Session changed notification
    case sessionChanged(sessionId: String, sessionName: String)
    
    /// Layout changed notification  
    case layoutChanged(windowId: String, windowIndex: Int, layout: String)
    
    /// Window notification
    case windowAdd(windowId: String)
    case windowClose(windowId: String)
    case windowRenamed(windowId: String, name: String)
    
    /// Client notification
    case clientSessionChanged(clientName: String, sessionId: String)
    case clientDetached(clientName: String)
    
    /// Pane notification
    case paneChanged(paneId: String)
    case pausePaneChanged(paneId: String)
    
    /// Pause/continue notifications (tmux 3.2+)
    case pause(paneId: String)
    case `continue`(paneId: String)
    
    /// Exit notification
    case exit(reason: String?)
    
    /// Unknown message type
    case unknown(line: String)
}

/// State for parsing a multi-line %begin/%end block
private struct PendingBlock {
    let commandId: String
    let timestamp: String
    var lines: [String] = []
}

/// Delegate protocol for TmuxControlClient
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
    
    /// Whether control mode is currently active
    private(set) var isActive: Bool = false
    
    /// Whether we've notified the delegate about activation
    private var hasNotifiedActivation: Bool = false
    
    /// Command counter for generating unique IDs
    private var commandCounter: Int = 0
    
    /// Pending command callbacks, keyed by command ID (timestamp)
    private var pendingCommands: [String: (Result<String, Error>) -> Void] = [:]
    
    /// Current pane scrollback buffers (pane ID -> content)
    /// We maintain our own copy since we're the "terminal" for tmux
    private var paneBuffers: [String: Data] = [:]
    
    /// Current block being parsed (nil when not inside a block)
    private var pendingBlock: PendingBlock?
    
    /// Unparsed data buffer (for partial line handling)
    private var parseBuffer: Data = Data()
    
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
    
    /// Whether we're waiting for session restore response
    private var isWaitingForSessionRestore: Bool = false
    
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
    func sendCommand(_ command: String, via write: (String) -> Void, completion: @escaping (Result<String, Error>) -> Void) {
        let (cmdId, fullCommand) = makeCommand(command)
        pendingCommands[cmdId] = completion
        write(fullCommand)
        
        // Timeout after 10 seconds
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if let callback = self.pendingCommands.removeValue(forKey: cmdId) {
                callback(.failure(TmuxControlError.timeout))
            }
        }
    }
    
    // MARK: - Input Handling
    
    // MARK: - Kitty Keyboard Protocol Translation
    
    /// Kitty keyboard protocol modifier bits (after subtracting 1 from sequence value)
    private struct KittyModifiers {
        let shift: Bool
        let alt: Bool
        let ctrl: Bool
        let superKey: Bool
        let hyper: Bool
        let meta: Bool
        let capsLock: Bool
        let numLock: Bool
        
        init(sequenceValue: Int) {
            // Sequence encodes mods+1, so subtract 1 to get raw bits
            let bits = sequenceValue > 0 ? sequenceValue - 1 : 0
            self.shift = (bits & 1) != 0
            self.alt = (bits & 2) != 0
            self.ctrl = (bits & 4) != 0
            self.superKey = (bits & 8) != 0
            self.hyper = (bits & 16) != 0
            self.meta = (bits & 32) != 0
            self.capsLock = (bits & 64) != 0
            self.numLock = (bits & 128) != 0
        }
        
        var hasBindingModifiers: Bool {
            ctrl || alt || superKey || hyper || meta
        }
    }
    
    /// Functional key codes in the kitty protocol
    /// Maps kitty protocol codes to legacy escape sequences
    private enum FunctionalKey {
        case escape         // 27
        case enter          // 13
        case tab            // 9
        case backspace      // 127
        case insert         // 2~
        case delete         // 3~
        case arrowLeft      // D
        case arrowRight     // C
        case arrowUp        // A
        case arrowDown      // B
        case pageUp         // 5~
        case pageDown       // 6~
        case home           // H
        case end            // F
        case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
        case f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24, f25
        
        /// Convert kitty code to legacy bytes
        func toLegacyBytes(mods: KittyModifiers) -> [UInt8] {
            // For modified keys, we need to include the modifier in the sequence
            let modParam = mods.hasBindingModifiers ? modifierParam(mods) : nil
            
            switch self {
            case .escape:
                return [0x1b]
            case .enter:
                return [0x0d]  // CR
            case .tab:
                if mods.shift {
                    return [0x1b, 0x5b, 0x5a]  // ESC[Z for Shift+Tab
                }
                return [0x09]
            case .backspace:
                if mods.ctrl {
                    return [0x08]  // Ctrl+Backspace = BS
                }
                return [0x7f]  // DEL
            case .insert:
                return csiSequence(code: 2, final: 0x7e, mods: modParam)
            case .delete:
                return csiSequence(code: 3, final: 0x7e, mods: modParam)
            case .arrowUp:
                return csiSequence(code: modParam != nil ? 1 : nil, final: 0x41, mods: modParam)
            case .arrowDown:
                return csiSequence(code: modParam != nil ? 1 : nil, final: 0x42, mods: modParam)
            case .arrowRight:
                return csiSequence(code: modParam != nil ? 1 : nil, final: 0x43, mods: modParam)
            case .arrowLeft:
                return csiSequence(code: modParam != nil ? 1 : nil, final: 0x44, mods: modParam)
            case .home:
                return csiSequence(code: modParam != nil ? 1 : nil, final: 0x48, mods: modParam)
            case .end:
                return csiSequence(code: modParam != nil ? 1 : nil, final: 0x46, mods: modParam)
            case .pageUp:
                return csiSequence(code: 5, final: 0x7e, mods: modParam)
            case .pageDown:
                return csiSequence(code: 6, final: 0x7e, mods: modParam)
            case .f1:
                return csiSequence(code: modParam != nil ? 1 : nil, final: 0x50, mods: modParam)  // ESC[P or ESC[1;modP
            case .f2:
                return csiSequence(code: modParam != nil ? 1 : nil, final: 0x51, mods: modParam)
            case .f3:
                return csiSequence(code: 13, final: 0x7e, mods: modParam)
            case .f4:
                return csiSequence(code: modParam != nil ? 1 : nil, final: 0x53, mods: modParam)
            case .f5:
                return csiSequence(code: 15, final: 0x7e, mods: modParam)
            case .f6:
                return csiSequence(code: 17, final: 0x7e, mods: modParam)
            case .f7:
                return csiSequence(code: 18, final: 0x7e, mods: modParam)
            case .f8:
                return csiSequence(code: 19, final: 0x7e, mods: modParam)
            case .f9:
                return csiSequence(code: 20, final: 0x7e, mods: modParam)
            case .f10:
                return csiSequence(code: 21, final: 0x7e, mods: modParam)
            case .f11:
                return csiSequence(code: 23, final: 0x7e, mods: modParam)
            case .f12:
                return csiSequence(code: 24, final: 0x7e, mods: modParam)
            case .f13:
                return csiSequence(code: 25, final: 0x7e, mods: modParam)
            case .f14:
                return csiSequence(code: 26, final: 0x7e, mods: modParam)
            case .f15:
                return csiSequence(code: 28, final: 0x7e, mods: modParam)
            case .f16:
                return csiSequence(code: 29, final: 0x7e, mods: modParam)
            case .f17:
                return csiSequence(code: 31, final: 0x7e, mods: modParam)
            case .f18:
                return csiSequence(code: 32, final: 0x7e, mods: modParam)
            case .f19:
                return csiSequence(code: 33, final: 0x7e, mods: modParam)
            case .f20:
                return csiSequence(code: 34, final: 0x7e, mods: modParam)
            case .f21, .f22, .f23, .f24, .f25:
                // F21-F25 don't have standard legacy codes, pass as-is
                return []
            }
        }
        
        private func modifierParam(_ mods: KittyModifiers) -> Int {
            var param = 1
            if mods.shift { param += 1 }
            if mods.alt { param += 2 }
            if mods.ctrl { param += 4 }
            if mods.superKey { param += 8 }
            return param
        }
        
        private func csiSequence(code: Int?, final: UInt8, mods: Int?) -> [UInt8] {
            var result: [UInt8] = [0x1b, 0x5b]  // ESC [
            
            if let code = code {
                for char in String(code).utf8 {
                    result.append(char)
                }
            }
            
            if let mods = mods {
                result.append(0x3b)  // ;
                for char in String(mods).utf8 {
                    result.append(char)
                }
            }
            
            result.append(final)
            return result
        }
        
        /// Create from kitty protocol code and final byte
        static func from(code: Int, final: UInt8) -> FunctionalKey? {
            switch (code, final) {
            // CSI u sequences (final = 'u')
            case (27, 0x75): return .escape
            case (13, 0x75): return .enter
            case (9, 0x75): return .tab
            case (127, 0x75): return .backspace
            
            // CSI ~ sequences (final = '~')
            case (2, 0x7e): return .insert
            case (3, 0x7e): return .delete
            case (5, 0x7e): return .pageUp
            case (6, 0x7e): return .pageDown
            case (13, 0x7e): return .f3
            case (15, 0x7e): return .f5
            case (17, 0x7e): return .f6
            case (18, 0x7e): return .f7
            case (19, 0x7e): return .f8
            case (20, 0x7e): return .f9
            case (21, 0x7e): return .f10
            case (23, 0x7e): return .f11
            case (24, 0x7e): return .f12
            
            // High-numbered function keys (kitty-specific codes)
            case (57376, 0x75): return .f13
            case (57377, 0x75): return .f14
            case (57378, 0x75): return .f15
            case (57379, 0x75): return .f16
            case (57380, 0x75): return .f17
            case (57381, 0x75): return .f18
            case (57382, 0x75): return .f19
            case (57383, 0x75): return .f20
            case (57384, 0x75): return .f21
            case (57385, 0x75): return .f22
            case (57386, 0x75): return .f23
            case (57387, 0x75): return .f24
            case (57388, 0x75): return .f25
            
            // CSI letter sequences (code = 1 typically)
            case (_, 0x41): return .arrowUp      // A
            case (_, 0x42): return .arrowDown    // B
            case (_, 0x43): return .arrowRight   // C
            case (_, 0x44): return .arrowLeft    // D
            case (_, 0x48): return .home         // H
            case (_, 0x46): return .end          // F
            case (_, 0x50): return .f1           // P
            case (_, 0x51): return .f2           // Q
            case (_, 0x53): return .f4           // S
            
            default: return nil
            }
        }
    }
    
    /// Comprehensive translator for Kitty keyboard protocol sequences to legacy terminal codes.
    ///
    /// The Kitty keyboard protocol (https://sw.kovidgoyal.net/kitty/keyboard-protocol/)
    /// encodes keys as CSI sequences with different final bytes:
    /// - `ESC [ <code> ; <mods> u` - Unicode codepoints and special keys
    /// - `ESC [ <code> ; <mods> ~` - Function keys, insert, delete, page up/down  
    /// - `ESC [ 1 ; <mods> <letter>` - Arrow keys (A/B/C/D), Home (H), End (F), F1-F4 (P/Q/R/S)
    ///
    /// Modifier encoding: sequence value = modifier_bits + 1
    /// - shift=1, alt=2, ctrl=4, super=8, hyper=16, meta=32, caps_lock=64, num_lock=128
    ///
    /// Event types (after colon): 1=press, 2=repeat, 3=release
    ///
    /// This translator converts these to legacy terminal sequences that tmux understands.
    private func translateKittyToLegacy(_ data: Data) -> Data {
        var result = Data()
        var i = 0
        let bytes = Array(data)
        
        while i < bytes.count {
            // Check for CSI sequence: ESC [
            if i + 2 < bytes.count && bytes[i] == 0x1b && bytes[i + 1] == 0x5b {
                if let (translated, consumed) = parseAndTranslateCSI(bytes: bytes, startIndex: i + 2) {
                    result.append(contentsOf: translated)
                    i += consumed + 2  // +2 for ESC [
                    continue
                }
            }
            
            // Not a translatable CSI sequence - copy byte as-is
            result.append(bytes[i])
            i += 1
        }
        
        return result
    }
    
    /// Parse and translate a CSI sequence starting after "ESC ["
    /// Returns (translated bytes, number of bytes consumed from input) or nil if not translatable
    private func parseAndTranslateCSI(bytes: [UInt8], startIndex: Int) -> (translated: [UInt8], consumed: Int)? {
        var j = startIndex
        
        // Parse the first number (code)
        var code: Int = 0
        var hasCode = false
        while j < bytes.count && bytes[j] >= 0x30 && bytes[j] <= 0x39 {
            code = code * 10 + Int(bytes[j] - 0x30)
            hasCode = true
            j += 1
        }
        
        // Parse alternates (colon-separated, used in kitty for shifted/base keys)
        // Format: code:shifted:base
        while j < bytes.count && bytes[j] == 0x3a {  // ':'
            j += 1
            while j < bytes.count && bytes[j] >= 0x30 && bytes[j] <= 0x39 {
                j += 1
            }
        }
        
        // Parse modifiers (after semicolon)
        var mods: Int = 1
        if j < bytes.count && bytes[j] == 0x3b {  // ';'
            j += 1
            mods = 0
            while j < bytes.count && bytes[j] >= 0x30 && bytes[j] <= 0x39 {
                mods = mods * 10 + Int(bytes[j] - 0x30)
                j += 1
            }
            
            // Skip event type (after colon) - we only care about the key, not press/release
            if j < bytes.count && bytes[j] == 0x3a {  // ':'
                j += 1
                while j < bytes.count && bytes[j] >= 0x30 && bytes[j] <= 0x39 {
                    j += 1
                }
            }
        }
        
        // Parse text section (after second semicolon, kitty report_associated mode)
        // Format: ;mods;text1:text2:...
        if j < bytes.count && bytes[j] == 0x3b {  // ';'
            j += 1
            // Skip the text codepoints
            while j < bytes.count && (bytes[j] >= 0x30 && bytes[j] <= 0x39 || bytes[j] == 0x3a) {
                j += 1
            }
        }
        
        // Check for final byte (must be in range 0x40-0x7e for CSI sequences)
        guard j < bytes.count && bytes[j] >= 0x40 && bytes[j] <= 0x7e else {
            return nil
        }
        
        let finalByte = bytes[j]
        let consumed = j - startIndex + 1
        let modifiers = KittyModifiers(sequenceValue: mods)
        
        // Try to match as a functional key
        if let functionalKey = FunctionalKey.from(code: code, final: finalByte) {
            let translated = functionalKey.toLegacyBytes(mods: modifiers)
            if !translated.isEmpty {
                logger.debug("Kitty functional key: code=\(code), final=\(String(format: "0x%02x", finalByte)), mods=\(mods) -> \(translated.count) bytes")
                return (translated, consumed)
            }
        }
        
        // Handle CSI u sequences for regular characters
        if finalByte == 0x75 {  // 'u'
            // Ctrl+letter -> C0 control code
            if modifiers.ctrl && !modifiers.shift {
                if code >= 0x40 && code <= 0x7f {
                    // Standard ctrl translation
                    var ctrlChar = code
                    if code >= 0x61 && code <= 0x7a {  // lowercase a-z
                        ctrlChar = code - 0x20  // convert to uppercase
                    }
                    let c0Code = UInt8((ctrlChar - 0x40) & 0x1f)
                    
                    var translated: [UInt8] = []
                    if modifiers.alt {
                        translated.append(0x1b)  // ESC prefix for Alt
                    }
                    translated.append(c0Code)
                    
                    logger.debug("Kitty Ctrl+char: code=\(code), mods=\(mods) -> C0=0x\(String(format: "%02x", c0Code))")
                    return (translated, consumed)
                }
                
                // Special control codes (code < 0x20)
                if code < 0x20 {
                    var translated: [UInt8] = []
                    if modifiers.alt {
                        translated.append(0x1b)
                    }
                    translated.append(UInt8(code))
                    
                    logger.debug("Kitty special ctrl: code=\(code), mods=\(mods)")
                    return (translated, consumed)
                }
            }
            
            // Alt+character -> ESC + character
            if modifiers.alt && !modifiers.ctrl && !modifiers.shift {
                if code > 0 && code < 128 {
                    logger.debug("Kitty Alt+char: code=\(code)")
                    return ([0x1b, UInt8(code)], consumed)
                }
            }
            
            // Plain character (no modifiers or just shift) -> pass the character
            if !modifiers.hasBindingModifiers || (modifiers.shift && !modifiers.ctrl && !modifiers.alt) {
                if code > 0 && code < 128 {
                    logger.debug("Kitty plain char: code=\(code)")
                    return ([UInt8(code)], consumed)
                }
                // For Unicode characters, encode as UTF-8
                if code > 127 {
                    var utf8: [UInt8] = []
                    if code < 0x80 {
                        utf8.append(UInt8(code))
                    } else if code < 0x800 {
                        utf8.append(UInt8(0xC0 | (code >> 6)))
                        utf8.append(UInt8(0x80 | (code & 0x3F)))
                    } else if code < 0x10000 {
                        utf8.append(UInt8(0xE0 | (code >> 12)))
                        utf8.append(UInt8(0x80 | ((code >> 6) & 0x3F)))
                        utf8.append(UInt8(0x80 | (code & 0x3F)))
                    } else {
                        utf8.append(UInt8(0xF0 | (code >> 18)))
                        utf8.append(UInt8(0x80 | ((code >> 12) & 0x3F)))
                        utf8.append(UInt8(0x80 | ((code >> 6) & 0x3F)))
                        utf8.append(UInt8(0x80 | (code & 0x3F)))
                    }
                    logger.debug("Kitty Unicode: code=\(code) -> UTF-8")
                    return (utf8, consumed)
                }
            }
        }
        
        // For CSI ~ and letter sequences without special handling, 
        // reconstruct legacy sequence format
        if finalByte == 0x7e || (finalByte >= 0x41 && finalByte <= 0x5a) {  // ~ or A-Z
            var legacy: [UInt8] = [0x1b, 0x5b]  // ESC [
            
            if hasCode && (finalByte == 0x7e || mods > 1) {
                for char in String(code).utf8 {
                    legacy.append(char)
                }
            }
            
            if mods > 1 {
                legacy.append(0x3b)  // ;
                for char in String(mods).utf8 {
                    legacy.append(char)
                }
            }
            
            legacy.append(finalByte)
            
            logger.debug("Kitty CSI passthrough: code=\(code), final=\(String(format: "0x%02x", finalByte)), mods=\(mods)")
            return (legacy, consumed)
        }
        
        // Unknown sequence - don't translate
        logger.debug("Kitty unknown: code=\(code), final=\(String(format: "0x%02x", finalByte)), mods=\(mods)")
        return nil
    }
    
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
        let translatedData = translateKittyToLegacy(data)
        
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
    
    // MARK: - Parsing
    
    /// Parse incoming data from tmux control mode
    /// Call this with each chunk of data received from SSH
    func parse(_ data: Data) {
        parseBuffer.append(data)
        
        // Debug: log raw data
        if let str = String(data: data, encoding: .utf8) {
            logger.debug("Raw data received (\(data.count) bytes): \(str.prefix(200))")
        }
        
        // Process complete lines
        while let newlineIndex = parseBuffer.firstIndex(of: 0x0A) { // \n
            let lineData = parseBuffer[..<newlineIndex]
            parseBuffer = Data(parseBuffer[(newlineIndex + 1)...])
            
            guard let line = String(data: lineData, encoding: .utf8) else {
                logger.warning("Failed to decode line as UTF-8")
                continue
            }
            
            parseLine(line)
        }
    }
    
    /// Parse a single line of control mode output
    private func parseLine(_ line: String) {
        // Remove trailing \r if present (tmux sometimes sends \r\n)
        let trimmedLine = line.hasSuffix("\r") ? String(line.dropLast()) : line
        
        // Check if we're inside a %begin/%end block
        if let block = pendingBlock {
            if trimmedLine.hasPrefix("%end ") {
                // Block complete
                finishBlock(block, success: true)
                pendingBlock = nil
            } else if trimmedLine.hasPrefix("%error ") {
                // Block failed
                finishBlock(block, success: false)
                pendingBlock = nil
            } else {
                // Content line - add to block
                pendingBlock?.lines.append(trimmedLine)
            }
            return
        }
        
        // Parse control mode message
        let message = parseMessage(trimmedLine)
        handleMessage(message)
    }
    
    /// Parse a control mode message line
    private func parseMessage(_ line: String) -> TmuxControlMessage {
        guard line.hasPrefix("%") else {
            // Not a control message - could be startup banner or prompt
            logger.debug("Non-control line: \(line.prefix(100))")
            return .unknown(line: line)
        }
        
        logger.info("Control message: \(line.prefix(100))")
        
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
            // Start of command response block
            // The command-number is unique and used to match %begin with %end
            let beginParts = rest.split(separator: " ")
            let timestamp = beginParts.count > 0 ? String(beginParts[0]) : ""
            let commandNumber = beginParts.count > 1 ? String(beginParts[1]) : timestamp
            let flags = beginParts.count > 2 ? String(beginParts[2]) : "0"
            logger.info("%begin block: time=\(timestamp) cmd=\(commandNumber) flags=\(flags)")
            pendingBlock = PendingBlock(commandId: commandNumber, timestamp: timestamp)
            // Don't trigger activation here - wait until first block completes
            // This ensures tmux is ready to receive commands
            return .unknown(line: line) // Don't emit a separate message
            
        case "%output":
            // %output <pane-id> <octal-escaped-data>
            let outputParts = rest.split(separator: " ", maxSplits: 1)
            if outputParts.count >= 2 {
                let paneId = String(outputParts[0])
                let escapedData = String(outputParts[1])
                if let decodedData = decodeOctalEscapes(escapedData) {
                    return .output(paneId: paneId, data: decodedData)
                } else {
                    logger.error("%output failed to decode octal escapes")
                }
            } else {
                logger.warning("%output unexpected format: \(rest.prefix(50))")
            }
            return .unknown(line: line)
            
        case "%extended-output":
            // %extended-output %<pane-id> <latency> : <octal-escaped-data>
            // Used by tmux 3.2+ when pause mode is enabled
            // Format: %extended-output %0 0 : data
            
            // Find the colon separator - data starts after ": "
            if let colonRange = rest.range(of: " : ") {
                let prefix = rest[..<colonRange.lowerBound]
                let prefixParts = prefix.split(separator: " ")
                
                if prefixParts.count >= 1 {
                    let paneId = String(prefixParts[0])
                    let escapedData = String(rest[colonRange.upperBound...])
                    
                    if let decodedData = decodeOctalEscapes(escapedData) {
                        return .output(paneId: paneId, data: decodedData)
                    } else {
                        logger.error("%extended-output failed to decode octal escapes")
                    }
                }
            } else {
                logger.warning("%extended-output unexpected format (no colon): \(rest.prefix(50))")
            }
            return .unknown(line: line)
            
        case "%session-changed":
            // %session-changed $<id> <name>
            let sessionParts = rest.split(separator: " ", maxSplits: 1)
            if sessionParts.count >= 2 {
                let sessionId = String(sessionParts[0])
                let sessionName = String(sessionParts[1])
                return .sessionChanged(sessionId: sessionId, sessionName: sessionName)
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
            
        case "%exit":
            // %exit [reason]
            let reason = rest.isEmpty ? nil : rest
            return .exit(reason: reason)
            
        case "%window-add":
            return .windowAdd(windowId: rest)
            
        case "%window-close":
            return .windowClose(windowId: rest)
            
        case "%window-renamed":
            let renameParts = rest.split(separator: " ", maxSplits: 1)
            if renameParts.count >= 2 {
                return .windowRenamed(windowId: String(renameParts[0]), name: String(renameParts[1]))
            }
            return .unknown(line: line)
            
        case "%pane-mode-changed":
            return .paneChanged(paneId: rest)
            
        case "%pause-pane-changed":
            return .pausePaneChanged(paneId: rest)
            
        case "%pause":
            // %pause %pane-id - pane output is paused
            return .pause(paneId: rest)
            
        case "%continue":
            // %continue %pane-id - pane output resumed
            return .continue(paneId: rest)
            
        case "%client-session-changed":
            let clientParts = rest.split(separator: " ", maxSplits: 1)
            if clientParts.count >= 2 {
                return .clientSessionChanged(clientName: String(clientParts[0]), sessionId: String(clientParts[1]))
            }
            return .unknown(line: line)
            
        case "%client-detached":
            return .clientDetached(clientName: rest)
            
        default:
            return .unknown(line: line)
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
    
    /// Handle a parsed control mode message
    private func handleMessage(_ message: TmuxControlMessage) {
        // Note: Activation is ONLY triggered after the first %begin/%end block completes
        // (in finishBlock). This ensures tmux is fully ready for commands.
        // Early %output messages with shell prompts should not trigger activation.
        
        switch message {
        case .output(let paneId, let data):
            // Append to pane buffer
            if paneBuffers[paneId] == nil {
                paneBuffers[paneId] = Data()
            }
            paneBuffers[paneId]?.append(data)
            
            // Notify delegate
            delegate?.tmuxClient(self, didReceivePaneOutput: data, paneId: paneId)
            
        case .exit(let reason):
            logger.info("tmux control mode exit: \(reason ?? "no reason")")
            isActive = false
            delegate?.tmuxClientDidExit(self, reason: reason)
            
        case .sessionChanged(let sessionId, let sessionName):
            logger.info("Session changed: \(sessionId) (\(sessionName))")
            // %session-changed means tmux session is ready - trigger activation
            notifyActivationIfNeeded()
            
        case .layoutChanged(let windowId, let windowIndex, _):
            logger.debug("Layout changed: window \(windowId) index \(windowIndex)")
            
        case .windowAdd(let windowId):
            logger.debug("Window added: \(windowId)")
            
        case .windowClose(let windowId):
            logger.debug("Window closed: \(windowId)")
            
        case .windowRenamed(let windowId, let name):
            logger.debug("Window renamed: \(windowId) -> \(name)")
            
        case .clientSessionChanged(let clientName, let sessionId):
            logger.debug("Client session changed: \(clientName) -> \(sessionId)")
            
        case .clientDetached(let clientName):
            logger.info("Client detached: \(clientName)")
            
        case .paneChanged(let paneId):
            logger.debug("Pane mode changed: \(paneId)")
            
        case .pausePaneChanged(let paneId):
            logger.debug("Pause pane changed: \(paneId)")
            
        case .pause(let paneId):
            // Pane output is now paused (tmux 3.2+)
            logger.info("Pane paused: \(paneId)")
            pausedPanes.insert(paneId)
            
        case .continue(let paneId):
            // Pane output has resumed
            logger.info("Pane continued: \(paneId)")
            pausedPanes.remove(paneId)
            
        case .response, .error:
            // These are handled in finishBlock
            break
            
        case .unknown(let line):
            // Check if this looks like the control mode prompt
            if line.isEmpty || line.contains("[") {
                // Likely startup or prompt line
            } else {
                logger.debug("Unknown control message: \(line)")
            }
        }
    }
    
    /// Finish a pending %begin/%end block
    private func finishBlock(_ block: PendingBlock, success: Bool) {
        let content = block.lines.joined(separator: "\n")
        
        logger.info("Block finished: id=\(block.commandId) success=\(success) lines=\(block.lines.count) content='\(content.prefix(100))'")
        
        // Notify activation after first block completes
        // This is the right time because tmux has finished its initial response
        // and is now ready to receive new commands
        notifyActivationIfNeeded()
        
        // Find matching pending command by timestamp
        // Note: tmux uses the timestamp from the command as the block ID
        // We need to find a matching command within a small time window
        var matchedId: String?
        for (cmdId, _) in pendingCommands {
            // Try exact match first
            if cmdId == block.commandId {
                matchedId = cmdId
                break
            }
            // Or within 0.1 second
            if let cmdTimestamp = Double(cmdId),
               let blockTimestamp = Double(block.commandId),
               abs(cmdTimestamp - blockTimestamp) < 0.1 {
                matchedId = cmdId
                break
            }
        }
        
        if let id = matchedId, let callback = pendingCommands.removeValue(forKey: id) {
            if success {
                callback(.success(content))
                delegate?.tmuxClient(self, commandDidComplete: id, response: content)
            } else {
                callback(.failure(TmuxControlError.commandFailed(content)))
                delegate?.tmuxClient(self, commandDidFail: id, error: content)
            }
        } else {
            // No pending command found - check for session restore response
            
            // Is this the capture-pane response for session restore?
            if success && isWaitingForSessionRestore {
                isWaitingForSessionRestore = false
                
                logger.info("Session restore received: \(content.count) chars")
                delegate?.tmuxClient(self, didRestoreSession: content, paneId: activePaneId, paneState: nil)
            } else if success {
                logger.debug("Unmatched response block: \(block.commandId), content length=\(content.count)")
            } else {
                logger.warning("Unmatched error block: \(block.commandId) - \(content)")
            }
        }
    }
    
    // MARK: - Octal Escape Decoding
    
    /// Decode octal escapes in tmux control mode output
    /// Characters < 32 and `\` are encoded as octal (e.g., \033 for ESC, \134 for \)
    private func decodeOctalEscapes(_ string: String) -> Data? {
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
        isWaitingForSessionRestore = true
        
        // Capture pane content (plain text, preserving line structure)
        // -p: output to stdout (control mode captures in %begin/%end)
        // -t: target pane
        // -S -N: start from N lines before current position
        // Note: We don't use -J (join) as it destroys line breaks
        let captureCommand = "capture-pane -p -t \(paneId) -S -\(sessionRestoreScrollback)\n"
        logger.info("Capturing session content: \(captureCommand.trimmingCharacters(in: .newlines))")
        write(captureCommand)
    }
    
    /// Parse pane state from list-panes -F response
    /// Expected format: "cursor_x,cursor_y,width,height,alternate_on"
    /// Example: "5,10,80,24,0"
    private func parsePaneState(_ content: String) -> PaneState? {
        // Take first line (there may be trailing newline)
        let line = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = line.split(separator: ",")
        
        guard parts.count >= 5,
              let cursorX = Int(parts[0]),
              let cursorY = Int(parts[1]),
              let width = Int(parts[2]),
              let height = Int(parts[3]) else {
            return nil
        }
        
        // alternate_on is "0" or "1"
        let isAlternate = parts[4] == "1"
        
        return PaneState(
            cursorX: cursorX,
            cursorY: cursorY,
            width: width,
            height: height,
            isAlternateScreen: isAlternate
        )
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
        isWaitingForSessionRestore = false
        isPauseEnabled = false
        pausedPanes.removeAll()
        pendingBlock = nil
        parseBuffer = Data()
        pendingCommands.removeAll()
        paneBuffers.removeAll()
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
