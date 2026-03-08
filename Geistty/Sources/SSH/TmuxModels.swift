//
//  TmuxModels.swift
//  Geistty
//
//  Data models for tmux session/window/pane state.
//  These represent the tmux server's view of the world.
//

import Foundation

// MARK: - tmux Session

/// Represents a tmux session
struct TmuxSession: Identifiable, Equatable {
    /// Session ID (e.g., "$0", "$1")
    let id: String
    
    /// Session name (user-defined)
    var name: String
    
    /// Window IDs in this session
    var windowIds: [String]
    
    /// Currently active window ID
    var activeWindowId: String?
    
    /// Whether this session is attached
    var isAttached: Bool = false
    
    /// Creation time
    var createdAt: Date?
    
    init(id: String, name: String) {
        self.id = id
        self.name = name
        self.windowIds = []
    }
}

// MARK: - tmux Window

/// Represents a tmux window within a session
struct TmuxWindow: Identifiable, Equatable {
    /// Window ID (e.g., "@0", "@1")
    let id: String
    
    /// Window index (0-based)
    var index: Int
    
    /// Window name
    var name: String
    
    /// Session this window belongs to
    let sessionId: String
    
    /// Pane IDs in this window
    var paneIds: [String]
    
    /// Layout string (tmux layout format)
    /// Example: "a]be,80x24,0,0{40x24,0,0,0,39x24,41,0,1}"
    var layout: String?
    
    init(id: String, index: Int, name: String, sessionId: String) {
        self.id = id
        self.index = index
        self.name = name
        self.sessionId = sessionId
        self.paneIds = []
    }
}

// MARK: - Layout Parsing
//
// NOTE: TmuxLayout has been moved to TmuxLayout.swift with a more robust
// implementation ported from Ghostty's layout.zig. It includes:
// - Proper checksum validation
// - Comprehensive error handling
// - Better tree traversal utilities

// MARK: - Session Info (from list-sessions response)

/// Lightweight snapshot of a tmux session returned by `list-sessions`.
/// Unlike `TmuxSession`, this is a pure value type parsed from a single
/// command response — no mutable state, no window/pane tracking.
struct TmuxSessionInfo: Identifiable, Equatable {
    /// Session ID (e.g., "$0", "$1")
    let id: String
    
    /// Session name
    let name: String
    
    /// Number of windows in this session
    let windowCount: Int
    
    /// Whether this session is currently attached (by any client)
    let isAttached: Bool
    
    /// Whether this is the session we're currently controlling
    let isCurrent: Bool
    
    /// Parse a list of `TmuxSessionInfo` from a `list-sessions` response.
    ///
    /// Expected format (one line per session):
    ///   `$0:mysession:3:1`
    /// Fields: session_id, session_name, session_windows, session_attached
    ///
    /// - Parameters:
    ///   - response: Raw text from `list-sessions -F '#{session_id}:#{session_name}:#{session_windows}:#{session_attached}'`
    ///   - currentSessionId: The session ID we're currently attached to (for `isCurrent` flag)
    /// - Returns: Parsed sessions sorted by ID, or empty array if parsing fails
    static func parse(response: String, currentSessionId: String? = nil) -> [TmuxSessionInfo] {
        response.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 3)
            guard parts.count == 4 else { return nil }
            
            let sessionId = String(parts[0])
            guard TmuxId.isValidSessionId(sessionId) else { return nil }
            
            let name = String(parts[1])
            let windowCount = Int(parts[2]) ?? 0
            let attachedCount = Int(parts[3]) ?? 0
            
            return TmuxSessionInfo(
                id: sessionId,
                name: name,
                windowCount: windowCount,
                isAttached: attachedCount > 0,
                isCurrent: sessionId == currentSessionId
            )
        }.sorted { a, b in
            // Sort by numeric ID
            let aNum = TmuxId.numericSessionId(a.id) ?? Int.max
            let bNum = TmuxId.numericSessionId(b.id) ?? Int.max
            return aNum < bNum
        }
    }
}

// MARK: - ID Validation

/// Validates and parses tmux identifiers
enum TmuxId {
    /// Validate a session ID (format: $N where N is a number)
    static func isValidSessionId(_ id: String) -> Bool {
        guard id.hasPrefix("$"), id.count > 1 else { return false }
        return Int(id.dropFirst()) != nil
    }
    
    /// Validate a window ID (format: @N where N is a number)
    static func isValidWindowId(_ id: String) -> Bool {
        guard id.hasPrefix("@"), id.count > 1 else { return false }
        return Int(id.dropFirst()) != nil
    }
    
    /// Validate a pane ID (format: %N where N is a number)
    static func isValidPaneId(_ id: String) -> Bool {
        guard id.hasPrefix("%"), id.count > 1 else { return false }
        return Int(id.dropFirst()) != nil
    }
    
    /// Extract numeric ID from pane ID string (e.g., "%5" -> 5)
    static func numericPaneId(_ id: String) -> Int? {
        guard isValidPaneId(id) else { return nil }
        return Int(id.dropFirst())
    }
    
    /// Create pane ID string from numeric ID (e.g., 5 -> "%5")
    static func paneIdString(_ numericId: Int) -> String {
        "%\(numericId)"
    }
    
    /// Extract numeric ID from window ID string (e.g., "@3" -> 3)
    static func numericWindowId(_ id: String) -> Int? {
        guard isValidWindowId(id) else { return nil }
        return Int(id.dropFirst())
    }
    
    /// Extract numeric ID from session ID string (e.g., "$0" -> 0)
    static func numericSessionId(_ id: String) -> Int? {
        guard isValidSessionId(id) else { return nil }
        return Int(id.dropFirst())
    }
    
    /// Sort tmux ID strings by their numeric suffix.
    /// Lexicographic sort puts "%10" before "%9" — this sorts numerically:
    /// ["%10", "%11", "%9"] -> ["%9", "%10", "%11"]
    static func sortedNumerically(_ ids: some Collection<String>) -> [String] {
        ids.sorted { a, b in
            let aNum = Int(a.dropFirst()) ?? Int.max
            let bNum = Int(b.dropFirst()) ?? Int.max
            return aNum < bNum
        }
    }
}
