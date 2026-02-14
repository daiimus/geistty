//
//  DCSFilter.swift
//  Geistty
//
//  Pure synchronous filter for tmux DCS 1000p detection and stripping.
//
//  When tmux enters control mode, it sends:
//      \x1bP1000p%begin <timestamp> 1 0\r\n%end <timestamp> 1 0\r\n...
//
//  The DCS sequence (\x1bP1000p) must be stripped to prevent Ghostty's internal
//  tmux parser from activating (which would conflict with our TmuxGateway).
//  After the DCS, all subsequent data is tmux control mode protocol until %exit.
//
//  This filter handles:
//  - Detecting \x1bP1000p in the byte stream
//  - Stripping DCS and optional ST (\x1b\\) sequences
//  - Handling arbitrary packet boundaries (DCS split across packets)
//  - Detecting % control messages that signal activation
//
//  Design follows iTerm2's VT100DCSParser + VT100TmuxParser pattern:
//  once DCS 1000p is detected, ALL subsequent data routes to the gateway.
//
//  Reference: iTerm2/sources/VT100DCSParser.m, VT100TmuxParser.m
//

import Foundation
import os

private let logger = Logger(subsystem: "com.geistty", category: "DCSFilter")

/// Result of processing data through the DCS filter
public enum DCSFilterResult: Equatable {
    /// Data should be forwarded to the terminal (Ghostty) for rendering.
    /// This is shell output, command echoes, MOTD, etc.
    case forwardToTerminal(Data)

    /// Data should be routed to the tmux gateway for protocol parsing.
    /// DCS sequences have been stripped; data contains % messages.
    case routeToGateway(Data)

    /// Data was consumed (DCS-only, partial DCS, or empty after stripping).
    /// No action needed — filter is accumulating or waiting for more data.
    case consumed
}

/// Pure synchronous filter for DCS 1000p detection and control mode activation.
///
/// Usage:
/// ```swift
/// var filter = DCSFilter()
///
/// // For each data chunk from SSH:
/// let result = filter.process(data)
/// switch result {
/// case .forwardToTerminal(let data):
///     ghosttySurface.writeOutput(data)
/// case .routeToGateway(let data):
///     tmuxGateway.receive(data)
/// case .consumed:
///     break  // filter ate it (partial DCS, etc.)
/// }
/// ```
///
/// Once `isHooked` becomes true, all subsequent data should bypass
/// this filter and go directly to the gateway.
public struct DCSFilter: Sendable {

    /// Whether the DCS 1000p hook has been detected.
    /// Once true, the caller should route ALL subsequent data directly
    /// to the tmux gateway without calling `process()` again.
    public private(set) var isHooked: Bool = false

    /// Buffer for accumulating a partial DCS sequence across packet boundaries.
    /// For example, if packet 1 ends with `\x1b` and packet 2 starts with `P1000p%begin...`,
    /// we need to recognize that `\x1bP1000p` spans the boundary.
    private var pendingBytes: Data = Data()

    public init() {}

    // MARK: - DCS Detection Constants

    /// The DCS 1000p sequence: ESC P 1 0 0 0 p (7 bytes)
    private static let dcs1000p: [UInt8] = [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]
    /// ESC P 1 0 0 0 ; (alternate form, though tmux typically sends 'p')
    private static let dcs1000semi: [UInt8] = [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x3B]
    /// ST (String Terminator): ESC \ (2 bytes)
    private static let st: [UInt8] = [0x1B, 0x5C]

    // MARK: - Main Entry Point

    /// Process a chunk of data received from SSH.
    ///
    /// Call this for each data packet when `controlModeState == .inactive`.
    /// Once the result is `.routeToGateway`, set `controlModeState = .routing`
    /// and stop calling this method — route all subsequent data directly to the gateway.
    ///
    /// - Parameter data: Raw data from SSH channel
    /// - Returns: What to do with the (possibly filtered) data
    public mutating func process(_ data: Data) -> DCSFilterResult {
        // If already hooked (DCS detected in a previous call), route everything
        // to the gateway. This is the steady state after DCS detection.
        if isHooked {
            return .routeToGateway(data)
        }
        
        // Prepend any buffered bytes from a previous partial match
        var input: Data
        if !pendingBytes.isEmpty {
            input = pendingBytes
            input.append(data)
            pendingBytes = Data()
        } else {
            input = data
        }

        // Search for DCS 1000p in the combined input
        if let dcsRange = findDCS(in: input) {
            isHooked = true
            logger.info("DCS 1000p detected at offset \(dcsRange.lowerBound)")

            // Everything before the DCS is terminal data (command echo, etc.)
            let beforeDCS = input[..<dcsRange.lowerBound]

            // Everything after the DCS is tmux protocol data
            var afterDCS = Data(input[dcsRange.upperBound...])

            // Strip optional ST (\x1b\) that may follow the DCS
            afterDCS = stripLeadingST(afterDCS)

            // Check for % control messages in the post-DCS data
            if !afterDCS.isEmpty {
                if !beforeDCS.isEmpty {
                    // We have both terminal data (before DCS) and gateway data (after DCS).
                    // The terminal data is typically the shell echo of `exec tmux -CC ...`.
                    // We must forward it to the terminal for rendering.
                    // But we can't return two results, so we need to prioritize.
                    //
                    // Strategy: drop the terminal data before DCS. The user already saw
                    // the command echo in a previous packet (the shell echoes it before
                    // tmux sends the DCS). If this is a combined packet with both echo
                    // and DCS, the echo is just `exec tmux -CC ...` which will be
                    // replaced by the tmux surface anyway.
                    logger.info("Dropping \(beforeDCS.count)B terminal data before DCS")
                }
                return .routeToGateway(afterDCS)
            } else {
                // DCS detected but no data after it yet (DCS was at end of packet).
                // Next packet will be pure gateway data.
                if !beforeDCS.isEmpty {
                    return .forwardToTerminal(Data(beforeDCS))
                }
                return .consumed
            }
        }

        // No DCS found. Check if the input might contain a PARTIAL DCS at the end.
        // The DCS sequence is 7 bytes (\x1bP1000p). If the input ends with a prefix
        // of this sequence, buffer those bytes for the next call.
        let buffered = bufferPartialDCS(input)
        if buffered > 0 {
            let payload = input[..<(input.count - buffered)]
            pendingBytes = Data(input[(input.count - buffered)...])
            if payload.isEmpty {
                return .consumed
            }
            return checkForControlMessages(Data(payload))
        }

        // No DCS, no partial DCS — check for bare % messages
        // (in case DCS was in a previous packet and control mode detection
        //  should have already transitioned to .routing)
        return checkForControlMessages(input)
    }

    // MARK: - DCS Search

    /// Find the DCS 1000p sequence in data.
    /// Returns the range of the DCS sequence, or nil if not found.
    private func findDCS(in data: Data) -> Range<Int>? {
        for pattern in [Self.dcs1000p, Self.dcs1000semi] {
            if let offset = data.findSubsequence(pattern) {
                return offset..<(offset + pattern.count)
            }
        }
        return nil
    }

    /// Strip a leading ST (ESC \) from data.
    /// tmux may or may not send ST after DCS 1000p.
    /// Also strips a bare \ if preceded by nothing (in case ESC was part of DCS).
    private func stripLeadingST(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }

        // Check for ESC \ (the ST terminator)
        if data.count >= 2, data[data.startIndex] == 0x1B, data[data.startIndex + 1] == 0x5C {
            logger.debug("Stripped ST (ESC \\) after DCS")
            return Data(data.dropFirst(2))
        }

        return data
    }

    // MARK: - Partial DCS Buffering

    /// Check if the end of `data` contains a partial DCS sequence prefix.
    /// Returns the number of trailing bytes that are a prefix of \x1bP1000p.
    private func bufferPartialDCS(_ data: Data) -> Int {
        let pattern = Self.dcs1000p
        // Check suffixes of decreasing length (up to pattern.count - 1)
        for suffixLen in stride(from: min(pattern.count - 1, data.count), through: 1, by: -1) {
            let suffix = data[(data.count - suffixLen)...]
            let prefix = pattern[..<suffixLen]
            if suffix.elementsEqual(prefix) {
                return suffixLen
            }
        }
        return 0
    }

    // MARK: - Control Message Detection

    /// Check if data contains tmux control messages (lines starting with %).
    /// If so, return `.routeToGateway`; otherwise `.forwardToTerminal`.
    private mutating func checkForControlMessages(_ data: Data) -> DCSFilterResult {
        // Convert to string for % detection
        guard let str = String(data: data, encoding: .utf8) else {
            return .forwardToTerminal(data)
        }

        let hasControlMessage = str.hasPrefix("%")
            || str.contains("\n%")
            || str.contains("\r%")

        if hasControlMessage {
            // This can happen if DCS arrived in a previous packet and was consumed,
            // and now the % messages arrive in a new packet.
            isHooked = true
            logger.info("Control messages detected without DCS (split packet)")
            return .routeToGateway(data)
        }

        return .forwardToTerminal(data)
    }
}

// MARK: - Data Extension

extension Data {
    /// Find the first occurrence of a byte subsequence.
    /// Returns the starting index, or nil if not found.
    func findSubsequence(_ pattern: [UInt8]) -> Int? {
        guard pattern.count <= self.count else { return nil }
        let end = self.count - pattern.count
        for i in 0...end {
            var match = true
            for j in 0..<pattern.count {
                if self[self.startIndex + i + j] != pattern[j] {
                    match = false
                    break
                }
            }
            if match {
                return i
            }
        }
        return nil
    }
}
