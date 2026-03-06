//
//  TmuxSessionNameResolver.swift
//  Geistty
//
//  Pure logic for resolving tmux session names.
//  Parses `tmux list-sessions` output and picks the right geistty-N session.
//

import Foundation

/// Resolves the tmux session name for Geistty connections.
///
/// Strategy:
/// - If the user specified a custom name, use it verbatim.
/// - Otherwise, query existing sessions and:
///   1. Reattach to the lowest-numbered unattached `geistty-N` session
///   2. If all `geistty-N` sessions are attached, create `geistty-<max+1>`
///   3. If no `geistty-N` sessions exist, create `geistty-1`
struct TmuxSessionNameResolver {
    
    /// The prefix for auto-generated session names
    static let prefix = "geistty-"
    
    /// Generate a unique end marker with a nonce to prevent false positive
    /// detection on the shell's command echo. Without the nonce, the echoed
    /// `echo '---END---'` command itself would match `isResponseComplete`,
    /// causing discovery to resolve prematurely with zero sessions. See #4.
    static func makeEndMarker() -> String {
        let nonce = UUID().uuidString.prefix(8)
        return "---GEISTTY-END-\(nonce)---"
    }
    
    /// The shell command to query existing tmux sessions.
    /// Output format: `<session_name> <attached_count>` per line, followed by the end marker.
    /// `2>/dev/null` suppresses "no server running" errors when tmux isn't active.
    /// Returns (command, endMarker) so the caller can pass the marker to response checking.
    static func makeQueryCommand() -> (command: String, endMarker: String) {
        let marker = makeEndMarker()
        let command = "tmux list-sessions -F '#{session_name} #{session_attached}' 2>/dev/null; echo '\(marker)'\n"
        return (command, marker)
    }
    
    /// A parsed tmux session entry
    struct SessionEntry: Equatable {
        let name: String
        let attachedCount: Int
        
        var isAttached: Bool { attachedCount > 0 }
    }
    
    /// Parse the output of `tmux list-sessions -F '#{session_name} #{session_attached}'`
    ///
    /// Each line has format: `<name> <attached_count>`
    /// Lines that don't match are ignored (shell noise, errors, prompts).
    /// The end marker sentinel is stripped.
    ///
    /// - Parameters:
    ///   - output: Raw shell output string
    ///   - endMarker: The nonce-based end marker used for this query
    /// - Returns: Array of parsed session entries
    static func parseSessions(from output: String, endMarker: String) -> [SessionEntry] {
        var entries: [SessionEntry] = []
        
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Skip empty lines, sentinel, and shell noise
            if trimmed.isEmpty || trimmed == endMarker { continue }
            
            // Expected format: "<name> <count>"
            // Split from the right to handle session names with spaces (unlikely but safe)
            let parts = trimmed.split(separator: " ")
            guard parts.count >= 2,
                  let lastPart = parts.last,
                  let count = Int(lastPart) else {
                continue
            }
            
            // Session name is everything except the last part
            let name = parts.dropLast().joined(separator: " ")
            entries.append(SessionEntry(name: name, attachedCount: count))
        }
        
        return entries
    }
    
    /// Extract the numeric suffix from a `geistty-N` session name.
    ///
    /// - Parameter name: Session name (e.g., "geistty-3")
    /// - Returns: The number N, or nil if not a geistty session
    static func geisttyNumber(from name: String) -> Int? {
        guard name.hasPrefix(prefix) else { return nil }
        return Int(name.dropFirst(prefix.count))
    }
    
    /// Resolve the session name to use for this connection.
    ///
    /// - Parameter sessions: Parsed session entries from `parseSessions(from:)`
    /// - Returns: The session name to attach to or create
    static func resolve(from sessions: [SessionEntry]) -> String {
        let geisttySessions = sessions
            .compactMap { entry -> (entry: SessionEntry, number: Int)? in
                guard let n = geisttyNumber(from: entry.name) else { return nil }
                return (entry, n)
            }
            .sorted { $0.number < $1.number }
        
        // No geistty sessions exist → create geistty-1
        if geisttySessions.isEmpty {
            return "\(prefix)1"
        }
        
        // Find the lowest-numbered unattached session
        if let unattached = geisttySessions.first(where: { !$0.entry.isAttached }) {
            return unattached.entry.name
        }
        
        // All attached → create next number
        let maxNumber = geisttySessions.last?.number ?? 0
        return "\(prefix)\(maxNumber + 1)"
    }
    
    /// Check if a raw output buffer contains the end marker,
    /// meaning the list-sessions response is complete.
    ///
    /// - Parameters:
    ///   - buffer: Accumulated raw output
    ///   - endMarker: The nonce-based end marker used for this query
    /// - Returns: true if the response is complete
    static func isResponseComplete(_ buffer: String, endMarker: String) -> Bool {
        buffer.contains(endMarker)
    }
    
    /// Extract the list-sessions response from a buffer that may contain
    /// shell prompt noise before and after the actual output.
    ///
    /// Uses backwards search to find the LAST occurrence of the end marker.
    /// This is critical because the shell's command echo contains the marker
    /// embedded in `echo '---GEISTTY-END-XXXX---'`, which would match before
    /// the actual sentinel output. The real sentinel is always the last occurrence.
    ///
    /// - Parameters:
    ///   - buffer: Accumulated raw output
    ///   - endMarker: The nonce-based end marker used for this query
    /// - Returns: The portion up to and including the end marker
    static func extractResponse(from buffer: String, endMarker: String) -> String? {
        guard let range = buffer.range(of: endMarker, options: .backwards) else { return nil }
        return String(buffer[buffer.startIndex..<range.upperBound])
    }
}
