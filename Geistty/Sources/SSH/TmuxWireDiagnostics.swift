//
//  TmuxWireDiagnostics.swift
//  Geistty
//
//  Shadow parser for tmux control mode wire data. Mirrors what Ghostty's
//  control.zig does — parses %output lines, unescapes octal, validates
//  escape sequences — but in Swift, giving us visibility into the data
//  pipeline without any Zig fork changes.
//
//  This is a pure diagnostic tool. It does NOT modify the data path.
//  It observes the same raw SSH bytes that go into ghostty_surface_write_output()
//  and reports anomalies via os.Logger.
//
//  Architecture:
//    SSH data → TerminalViewModel.sshSession(didReceiveData:)
//                  ├── surface.feedData(data)          ← production path (unchanged)
//                  └── diagnostics.analyze(data)       ← diagnostic shadow path
//

import Foundation
import os

private let logger = Logger(subsystem: "com.geistty", category: "TmuxWireDiag")

/// Diagnostic findings from analyzing tmux control mode wire data.
struct WireDiagnosticEvent: Equatable {
    enum Kind: Equatable {
        /// A %output line was successfully parsed and validated
        case outputOK(paneId: Int, byteCount: Int)
        
        /// A %output line was parsed but the unescaped data contains orphaned
        /// SGR fragments — e.g., "32m" without a preceding ESC[
        case orphanedSGR(paneId: Int, fragment: String, offset: Int)
        
        /// A %output line was parsed but the unescaped data contains a bare
        /// ESC (0x1B) not followed by [ or ] or other valid sequence initiator
        case bareESC(paneId: Int, offset: Int, nextByte: UInt8?)
        
        /// An incomplete octal escape was found in the raw wire data
        /// (e.g., \03 instead of \033 — only 2 octal digits)
        case incompleteOctal(paneId: Int, offset: Int, raw: String)
        
        /// A line starting with % was not recognized as any known notification
        case unknownNotification(command: String)
        
        /// A %output line didn't match the expected format
        case malformedOutput(line: String)
        
        /// UTF-8 decode failure in unescaped data — could produce U+FFFD
        case invalidUTF8(paneId: Int, offset: Int, bytes: [UInt8])
        
        /// Wire data contained a line not starting with % while not in a block
        /// This mirrors control.zig's "broken state" detection
        case unexpectedLine(preview: String)
        
        /// Chunk boundary split a %output line — accumulated across chunks
        case chunkBoundarySplit(accumulatedBytes: Int)
    }
    
    let kind: Kind
    let timestamp: Date
    
    init(_ kind: Kind) {
        self.kind = kind
        self.timestamp = Date()
    }
}

/// Shadow parser for tmux control mode wire data.
///
/// Feed raw SSH bytes via `analyze(_:)`. The parser accumulates bytes into lines,
/// parses `%output` notifications, unescapes octal, and validates the resulting
/// escape sequences. Anomalies are both logged and stored in `events` for
/// programmatic access (useful in tests).
///
/// This mirrors Ghostty's `control.zig` Parser but is deliberately simpler —
/// we only need to parse enough to validate, not to dispatch.
@MainActor final class TmuxWireDiagnostics {
    
    /// Whether diagnostics are actively running
    private(set) var isActive = false
    
    /// Accumulated diagnostic events (capped to prevent unbounded growth)
    private(set) var events: [WireDiagnosticEvent] = []
    
    /// Maximum events to retain (oldest are dropped)
    var maxEvents = 1000
    
    /// Line buffer for accumulating bytes across chunk boundaries
    private var lineBuffer = Data()
    
    /// Parser state — mirrors control.zig's State enum
    private enum State {
        case idle       // Expecting line starting with %
        case block      // Inside %begin/%end block, accumulate until %end
    }
    private var state: State = .idle
    
    /// Statistics
    private(set) var totalBytesAnalyzed: UInt64 = 0
    private(set) var totalOutputLines: UInt64 = 0
    private(set) var totalAnomalies: UInt64 = 0
    
    /// Known tmux notification commands
    private static let knownCommands: Set<String> = [
        "%output", "%begin", "%end", "%error", "%exit",
        "%session-changed", "%sessions-changed",
        "%layout-change", "%window-add", "%window-renamed",
        "%window-pane-changed", "%window-close",
        "%session-window-changed", "%client-detached",
        "%client-session-changed",
        // These are valid in newer tmux but Ghostty doesn't handle them:
        "%extended-output", "%pause", "%continue",
        "%pane-mode-changed", "%subscription-changed",
        "%config-error",
    ]
    
    // MARK: - Public API
    
    /// Start diagnostic collection
    func start() {
        isActive = true
        events.removeAll()
        lineBuffer = Data()
        state = .idle
        totalBytesAnalyzed = 0
        totalOutputLines = 0
        totalAnomalies = 0
        logger.info("Wire diagnostics started")
    }
    
    /// Stop diagnostic collection
    func stop() {
        isActive = false
        logger.info("Wire diagnostics stopped — \(self.totalBytesAnalyzed) bytes, \(self.totalOutputLines) outputs, \(self.totalAnomalies) anomalies")
    }
    
    /// Analyze a chunk of raw SSH data (the same bytes going to ghostty_surface_write_output).
    ///
    /// This is designed to be called from the data path without significant overhead.
    /// It accumulates bytes into lines and processes complete lines.
    func analyze(_ data: Data) {
        guard isActive else { return }
        totalBytesAnalyzed += UInt64(data.count)
        
        // Write to capture file if active
        captureData(data)
        
        for byte in data {
            if byte == 0x0A { // newline
                processLine(lineBuffer)
                lineBuffer.removeAll(keepingCapacity: true)
            } else {
                lineBuffer.append(byte)
                
                // Safety: don't let line buffer grow unbounded
                if lineBuffer.count > 1024 * 64 {
                    record(.chunkBoundarySplit(accumulatedBytes: lineBuffer.count))
                    lineBuffer.removeAll(keepingCapacity: true)
                    state = .idle
                }
            }
        }
    }
    
    /// Get a summary of diagnostics for logging
    func summary() -> String {
        let anomalyCount = events.filter { event in
            switch event.kind {
            case .outputOK: return false
            default: return true
            }
        }.count
        return "Wire: \(totalBytesAnalyzed) bytes, \(totalOutputLines) outputs, \(anomalyCount) anomalies"
    }
    
    // MARK: - Internal
    
    private func processLine(_ lineData: Data) {
        // Strip trailing CR if present (tmux sends \r\n on some platforms)
        var line = lineData
        if line.last == 0x0D { line = line.dropLast() }
        
        guard !line.isEmpty else { return }
        
        switch state {
        case .idle:
            // In idle state, lines must start with %
            guard line.first == 0x25 else { // '%'
                let preview = String(data: line.prefix(80), encoding: .utf8) ?? hexPreview(line.prefix(80))
                record(.unexpectedLine(preview: preview))
                return
            }
            
            guard let lineStr = String(data: line, encoding: .utf8) else {
                // Line contains raw bytes that aren't valid UTF-8.
                // This can happen legitimately with tmux %output containing raw
                // high bytes (>= 0x80) that tmux doesn't octal-escape.
                // Try to parse as %output using raw bytes.
                if line.count > 8 && line.starts(with: Data("%output ".utf8)) {
                    processOutputLineRaw(line)
                } else {
                    let preview = hexPreview(line.prefix(80))
                    record(.unexpectedLine(preview: preview))
                }
                return
            }
            
            // Extract command (first word)
            let command = String(lineStr.prefix(while: { $0 != " " }))
            
            if command == "%begin" {
                state = .block
                return
            }
            
            if command == "%output" {
                processOutputLine(lineStr, rawData: line)
                return
            }
            
            // Catch malformed %output (e.g., "%output%2 hello" — missing space)
            if lineStr.hasPrefix("%output") && command != "%output" {
                record(.malformedOutput(line: String(lineStr.prefix(120))))
                return
            }
            
            if command == "%end" || command == "%error" {
                // Stray %end/%error without matching %begin — unusual but not fatal
                return
            }
            
            if command == "%exit" {
                return
            }
            
            // Check if it's a known command we don't need to deeply parse
            if Self.knownCommands.contains(command) {
                return
            }
            
            // Unknown notification
            record(.unknownNotification(command: command))
            
        case .block:
            // Inside a %begin/%end block. Check if this line ends the block.
            if let lineStr = String(data: line, encoding: .utf8) {
                if lineStr.hasPrefix("%end") || lineStr.hasPrefix("%error") {
                    state = .idle
                }
            }
        }
    }
    
    /// Parse and validate a `%output %N <escaped_data>` line.
    private func processOutputLine(_ line: String, rawData: Data) {
        totalOutputLines += 1
        
        // Parse: %output %<pane_id> <data>
        // The format is: "%output %<digits> <rest>"
        guard line.hasPrefix("%output %") else {
            record(.malformedOutput(line: String(line.prefix(120))))
            return
        }
        
        let afterPrefix = line.dropFirst("%output %".count)
        guard let spaceIdx = afterPrefix.firstIndex(of: " ") else {
            record(.malformedOutput(line: String(line.prefix(120))))
            return
        }
        
        let paneIdStr = String(afterPrefix[afterPrefix.startIndex..<spaceIdx])
        guard let paneId = Int(paneIdStr) else {
            record(.malformedOutput(line: String(line.prefix(120))))
            return
        }
        
        let escapedData = String(afterPrefix[afterPrefix.index(after: spaceIdx)...])
        
        // Check for incomplete octal escapes in the raw escaped data
        checkIncompleteOctals(escapedData, paneId: paneId)
        
        // Unescape octal — mirror control.zig's unescapeOctal()
        var unescaped = unescapeOctal(escapedData)
        
        // Validate the unescaped data
        validateEscapeSequences(&unescaped, paneId: paneId)
        
        // Check UTF-8 validity
        validateUTF8(unescaped, paneId: paneId)
    }
    
    /// Parse a `%output` line from raw bytes when String(data:encoding:.utf8) fails.
    /// This handles cases where tmux sends raw high bytes (>= 0x80) in %output data.
    private func processOutputLineRaw(_ lineData: Data) {
        totalOutputLines += 1
        
        let prefixBytes = Array("%output %".utf8)
        let lineBytes = Array(lineData)
        
        // Find pane ID: scan digits after the prefix
        var idx = prefixBytes.count
        var paneDigits: [UInt8] = []
        while idx < lineBytes.count && isDigit(lineBytes[idx]) {
            paneDigits.append(lineBytes[idx])
            idx += 1
        }
        
        guard !paneDigits.isEmpty,
              idx < lineBytes.count,
              lineBytes[idx] == 0x20, // space after pane ID
              let paneIdStr = String(bytes: paneDigits, encoding: .utf8),
              let paneId = Int(paneIdStr)
        else {
            let preview = hexPreview(lineData.prefix(120))
            record(.malformedOutput(line: preview))
            return
        }
        
        // Everything after the space is the escaped data (as raw bytes)
        let dataStart = idx + 1
        let escapedBytes = Array(lineBytes[dataStart...])
        
        // Unescape octal from raw bytes
        var unescaped = Self.unescapeOctalBytes(escapedBytes)
        
        // Check for incomplete octals in the raw escaped bytes
        checkIncompleteOctalsBytes(escapedBytes, paneId: paneId)
        
        // Validate escape sequences
        validateEscapeSequences(&unescaped, paneId: paneId)
        
        // Validate UTF-8
        validateUTF8(unescaped, paneId: paneId)
    }
    
    // MARK: - Octal Unescaping (mirrors control.zig)
    
    /// Unescape tmux control mode octal escapes.
    /// tmux encodes bytes <32 and backslash as \NNN (3 octal digits).
    /// Returns the decoded byte array.
    static func unescapeOctal(_ input: String) -> [UInt8] {
        let bytes = Array(input.utf8)
        return unescapeOctalBytes(bytes)
    }
    
    /// Unescape from raw UTF-8 bytes — the core implementation.
    static func unescapeOctalBytes(_ bytes: [UInt8]) -> [UInt8] {
        var result = [UInt8]()
        result.reserveCapacity(bytes.count)
        
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x5C { // backslash
                if i + 3 < bytes.count,
                   isOctalDigit(bytes[i + 1]),
                   isOctalDigit(bytes[i + 2]),
                   isOctalDigit(bytes[i + 3])
                {
                    let value = (bytes[i + 1] - 0x30) << 6
                        | (bytes[i + 2] - 0x30) << 3
                        | (bytes[i + 3] - 0x30)
                    result.append(value)
                    i += 4
                } else {
                    result.append(bytes[i])
                    i += 1
                }
            } else {
                result.append(bytes[i])
                i += 1
            }
        }
        
        return result
    }
    
    /// Instance method wrapper for internal use
    private func unescapeOctal(_ input: String) -> [UInt8] {
        Self.unescapeOctal(input)
    }
    
    private static func isOctalDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x37 // '0'..'7'
    }
    
    // MARK: - Escape Sequence Validation
    
    /// Scan unescaped data for orphaned SGR fragments.
    ///
    /// A valid SGR sequence is: ESC [ <params> m
    /// An orphaned fragment is: digits + 'm' without a preceding ESC [
    ///
    /// We also check for bare ESC not followed by valid sequence initiators.
    private func validateEscapeSequences(_ data: inout [UInt8], paneId: Int) {
        var i = 0
        while i < data.count {
            let byte = data[i]
            
            if byte == 0x1B { // ESC
                // Valid: ESC followed by [, ], P, (, ), *, +, #, or another ESC
                if i + 1 < data.count {
                    let next = data[i + 1]
                    if next == 0x5B || next == 0x5D || next == 0x50 || // [ ] P
                       next == 0x28 || next == 0x29 || next == 0x2A || // ( ) *
                       next == 0x2B || next == 0x23 || next == 0x1B || // + # ESC
                       next == 0x37 || next == 0x38 || next == 0x63 || // 7 8 c
                       next == 0x3D || next == 0x3E || next == 0x4D || // = > M
                       next == 0x45 || next == 0x48 ||                 // E H
                       (next >= 0x40 && next <= 0x5F)                  // C1 range
                    {
                        // Valid ESC sequence start — skip
                        i += 2
                        continue
                    }
                    // Bare ESC followed by unexpected byte
                    record(.bareESC(paneId: paneId, offset: i, nextByte: next))
                } else {
                    // ESC at end of data — might be split across chunks, not necessarily bad
                    record(.bareESC(paneId: paneId, offset: i, nextByte: nil))
                }
                i += 1
                continue
            }
            
            // Look for orphaned SGR fragments: a sequence of digits followed by 'm'
            // that is NOT preceded by ESC [
            // Pattern: [0-9;]+m where the char before the digits is not [
            if byte == 0x6D { // 'm'
                if i > 0 && (isDigit(data[i - 1]) || data[i - 1] == 0x3B) { // digit or ;
                    // Walk backwards to find the start of this parameter sequence
                    var start = i - 1
                    while start > 0 && (isDigit(data[start - 1]) || data[start - 1] == 0x3B) {
                        start -= 1
                    }
                    
                    // Check what precedes the parameter sequence
                    let preceded = start > 0 ? data[start - 1] : 0
                    if preceded != 0x5B { // not '['
                        // This is an orphaned SGR fragment
                        let fragmentBytes = Array(data[start...i])
                        let fragment = String(bytes: fragmentBytes, encoding: .utf8) ?? hexPreview(Data(fragmentBytes))
                        record(.orphanedSGR(paneId: paneId, fragment: fragment, offset: start))
                    }
                }
            }
            
            i += 1
        }
    }
    
    private func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }
    
    // MARK: - Incomplete Octal Detection
    
    /// Check for backslash followed by fewer than 3 octal digits.
    /// This would indicate tmux sent malformed escaping or chunk boundary
    /// split an escape sequence.
    private func checkIncompleteOctals(_ data: String, paneId: Int) {
        checkIncompleteOctalsBytes(Array(data.utf8), paneId: paneId)
    }
    
    /// Check for incomplete octal escapes in raw byte data.
    private func checkIncompleteOctalsBytes(_ bytes: [UInt8], paneId: Int) {
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x5C { // backslash
                // Count following octal digits
                var octalCount = 0
                for j in 1...3 {
                    if i + j < bytes.count && Self.isOctalDigit(bytes[i + j]) {
                        octalCount += 1
                    } else {
                        break
                    }
                }
                
                if octalCount > 0 && octalCount < 3 {
                    // Incomplete octal escape
                    let end = min(i + 6, bytes.count)
                    let raw = String(bytes: Array(bytes[i..<end]), encoding: .utf8) ?? "?"
                    record(.incompleteOctal(paneId: paneId, offset: i, raw: raw))
                }
                
                if octalCount == 3 {
                    i += 4 // Skip valid octal escape
                } else {
                    i += 1
                }
            } else {
                i += 1
            }
        }
    }
    
    // MARK: - UTF-8 Validation
    
    /// Check if unescaped bytes form valid UTF-8.
    /// Invalid sequences would produce U+FFFD when rendered.
    private func validateUTF8(_ bytes: [UInt8], paneId: Int) {
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            
            if byte < 0x80 {
                // ASCII — always valid
                i += 1
                continue
            }
            
            // Determine expected sequence length
            let seqLen: Int
            if byte & 0xE0 == 0xC0 { seqLen = 2 }
            else if byte & 0xF0 == 0xE0 { seqLen = 3 }
            else if byte & 0xF8 == 0xF0 { seqLen = 4 }
            else {
                // Invalid start byte
                record(.invalidUTF8(paneId: paneId, offset: i, bytes: [byte]))
                i += 1
                continue
            }
            
            // Check we have enough continuation bytes
            if i + seqLen > bytes.count {
                let remaining = Array(bytes[i...])
                record(.invalidUTF8(paneId: paneId, offset: i, bytes: remaining))
                break
            }
            
            // Check continuation bytes are 10xxxxxx
            var valid = true
            for j in 1..<seqLen {
                if bytes[i + j] & 0xC0 != 0x80 {
                    valid = false
                    break
                }
            }
            
            if !valid {
                let badBytes = Array(bytes[i..<min(i + seqLen, bytes.count)])
                record(.invalidUTF8(paneId: paneId, offset: i, bytes: badBytes))
                i += 1 // Advance by 1 to resync
            } else {
                i += seqLen
            }
        }
    }
    
    // MARK: - Event Recording
    
    private func record(_ kind: WireDiagnosticEvent.Kind) {
        let event = WireDiagnosticEvent(kind)
        
        // Log based on severity
        switch kind {
        case .outputOK:
            break // Don't log normal operations
            
        case .orphanedSGR(let paneId, let fragment, let offset):
            totalAnomalies += 1
            logger.error("ORPHANED SGR pane=\(paneId) offset=\(offset) fragment=\"\(fragment)\"")
            
        case .bareESC(let paneId, let offset, let nextByte):
            totalAnomalies += 1
            let nextStr = nextByte.map { String(format: "0x%02X", $0) } ?? "EOF"
            logger.warning("BARE ESC pane=\(paneId) offset=\(offset) next=\(nextStr)")
            
        case .incompleteOctal(let paneId, let offset, let raw):
            totalAnomalies += 1
            logger.error("INCOMPLETE OCTAL pane=\(paneId) offset=\(offset) raw=\"\(raw)\"")
            
        case .unknownNotification(let command):
            totalAnomalies += 1
            logger.warning("UNKNOWN NOTIFICATION: \(command)")
            
        case .malformedOutput(let line):
            totalAnomalies += 1
            logger.error("MALFORMED %output: \(line)")
            
        case .invalidUTF8(let paneId, let offset, let bytes):
            totalAnomalies += 1
            let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            logger.warning("INVALID UTF-8 pane=\(paneId) offset=\(offset) bytes=[\(hex)]")
            
        case .unexpectedLine(let preview):
            totalAnomalies += 1
            logger.error("UNEXPECTED LINE (not %): \(preview)")
            
        case .chunkBoundarySplit(let bytes):
            totalAnomalies += 1
            logger.warning("CHUNK BOUNDARY: line buffer hit \(bytes) bytes, resetting")
        }
        
        events.append(event)
        
        // Cap events
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
    }
    
    // MARK: - Wire Capture
    
    /// File handle for writing raw wire data to disk
    private var captureHandle: FileHandle?
    
    /// Path to the current capture file
    private(set) var captureFilePath: String?
    
    /// Total bytes captured to disk
    private(set) var capturedBytes: UInt64 = 0
    
    /// Maximum capture file size (10 MB default — enough for a few minutes of cmatrix)
    var maxCaptureBytes: UInt64 = 10 * 1024 * 1024
    
    /// Start capturing raw wire data to a file in the app's documents directory.
    /// The file can be pulled from the device for offline analysis.
    ///
    /// File format: raw bytes, exactly as received from SSH. Can be replayed
    /// through `analyze()` to reproduce diagnostics offline.
    func startCapture(label: String = "tmux_wire") {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            logger.error("Failed to locate documents directory for wire capture")
            return
        }
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "\(label)_\(timestamp).bin"
        let url = docs.appendingPathComponent(filename)
        
        FileManager.default.createFile(atPath: url.path, contents: nil)
        captureHandle = FileHandle(forWritingAtPath: url.path)
        captureFilePath = url.path
        capturedBytes = 0
        
        logger.info("Wire capture started: \(url.path)")
    }
    
    /// Stop capturing and close the file.
    func stopCapture() {
        captureHandle?.closeFile()
        captureHandle = nil
        if let path = captureFilePath {
            logger.info("Wire capture stopped: \(self.capturedBytes) bytes written to \(path)")
        }
        captureFilePath = nil
    }
    
    /// Write raw data to capture file (called from analyze if capture is active)
    private func captureData(_ data: Data) {
        guard let handle = captureHandle else { return }
        guard capturedBytes + UInt64(data.count) <= maxCaptureBytes else {
            logger.warning("Wire capture file size limit reached (\(self.maxCaptureBytes) bytes), stopping capture")
            stopCapture()
            return
        }
        handle.write(data)
        capturedBytes += UInt64(data.count)
    }
    
    // MARK: - Replay
    
    /// Replay a captured wire data file through the diagnostics parser.
    /// Useful for offline analysis and in tests.
    ///
    /// - Parameter url: Path to a .bin file previously captured by `startCapture()`
    /// - Parameter chunkSize: Simulate SSH chunk boundaries by feeding data in chunks
    func replay(from url: URL, chunkSize: Int = 4096) throws {
        let data = try Data(contentsOf: url)
        logger.info("Replaying \(data.count) bytes from \(url.lastPathComponent)")
        
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let chunk = data[offset..<end]
            analyze(chunk)
            offset = end
        }
    }
    
    // MARK: - Helpers
    
    private func hexPreview(_ data: Data) -> String {
        data.prefix(40).map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
