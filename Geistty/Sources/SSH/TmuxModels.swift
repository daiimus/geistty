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
    
    /// Currently active pane ID
    var activePaneId: String?
    
    /// Layout string (tmux layout format)
    /// Example: "a]be,80x24,0,0{40x24,0,0,0,39x24,41,0,1}"
    var layout: String?
    
    /// Window flags (*, -, #, etc.)
    var flags: String = ""
    
    init(id: String, index: Int, name: String, sessionId: String) {
        self.id = id
        self.index = index
        self.name = name
        self.sessionId = sessionId
        self.paneIds = []
    }
}

// MARK: - tmux Pane

/// Represents a tmux pane within a window
struct TmuxPane: Identifiable, Equatable {
    /// Pane ID (e.g., "%0", "%1")
    let id: String
    
    /// Window this pane belongs to
    let windowId: String
    
    /// Pane dimensions
    var width: Int
    var height: Int
    
    /// Pane position within window
    var positionX: Int = 0
    var positionY: Int = 0
    
    /// Whether this is the active pane in its window
    var isActive: Bool = false
    
    init(id: String, windowId: String, width: Int, height: Int) {
        self.id = id
        self.windowId = windowId
        self.width = width
        self.height = height
    }
}

// MARK: - Layout Parsing
//
// NOTE: TmuxLayout has been moved to TmuxLayout.swift with a more robust
// implementation ported from Ghostty's layout.zig. It includes:
// - Proper checksum validation
// - Comprehensive error handling
// - Better tree traversal utilities

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
}
