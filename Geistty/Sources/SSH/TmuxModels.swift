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
    
    /// Cursor position
    var cursorX: Int = 0
    var cursorY: Int = 0
    
    /// Whether this is the active pane in its window
    var isActive: Bool = false
    
    /// Pane title (from escape sequences)
    var title: String = ""
    
    /// Current command/process running
    var currentCommand: String?
    
    /// Whether pane is in alternate screen mode
    var isAlternateScreen: Bool = false
    
    /// Whether pane is in a special mode (copy, choose, etc.)
    var mode: PaneMode = .normal
    
    /// Pane mode
    enum PaneMode: Equatable {
        case normal
        case copy
        case choose
        case view
    }
    
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

// MARK: - Query Formats

/// Format strings for tmux queries
enum TmuxQueryFormat {
    /// list-sessions format
    static let sessions = "#{session_id} #{q:session_name} #{session_windows} #{session_attached}"
    
    /// list-windows format (includes session_id for self-contained parsing)
    static let windows = "#{session_id} #{window_id} #{window_index} #{q:window_name} #{window_active} #{window_flags} #{window_layout}"
    
    /// list-panes format (includes window_id for self-contained parsing)
    static let panes = "#{window_id} #{pane_id} #{pane_width} #{pane_height} #{pane_active} #{cursor_x} #{cursor_y} #{pane_in_mode} #{alternate_on}"
}

// MARK: - Response Parsing

extension TmuxSession {
    /// Parse from list-sessions -F response line
    /// Format: "$0 session_name 3 1"
    static func parse(_ line: String) -> TmuxSession? {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 4 else { return nil }
        
        let id = String(parts[0])
        let name = String(parts[1]).replacingOccurrences(of: "\"", with: "")
        let attached = parts[3] == "1"
        
        var session = TmuxSession(id: id, name: name)
        session.isAttached = attached
        return session
    }
}

extension TmuxWindow {
    /// Parse from list-windows -F response line
    /// Format: "$session_id @window_id index window_name active flags layout"
    static func parse(_ line: String) -> TmuxWindow? {
        // Use regex-like parsing for quoted names
        let parts = line.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: false)
        guard parts.count >= 7 else { return nil }
        
        let sessionId = String(parts[0])
        let id = String(parts[1])
        guard let index = Int(parts[2]) else { return nil }
        let name = String(parts[3]).replacingOccurrences(of: "\"", with: "")
        let isActive = parts[4] == "1"
        let flags = String(parts[5])
        let layout = String(parts[6])
        
        var window = TmuxWindow(id: id, index: index, name: name, sessionId: sessionId)
        window.flags = flags
        window.layout = layout
        if isActive {
            // Mark in parent session
        }
        return window
    }
}

extension TmuxPane {
    /// Parse from list-panes -F response line  
    /// Format: "@window_id %pane_id width height active cursor_x cursor_y in_mode alternate_on"
    static func parse(_ line: String) -> TmuxPane? {
        let parts = line.split(separator: " ")
        guard parts.count >= 9 else { return nil }
        
        let windowId = String(parts[0])
        let id = String(parts[1])
        guard let width = Int(parts[2]),
              let height = Int(parts[3]) else { return nil }
        
        let isActive = parts[4] == "1"
        let cursorX = Int(parts[5]) ?? 0
        let cursorY = Int(parts[6]) ?? 0
        let inMode = parts[7] != "0"
        let alternateOn = parts[8] == "1"
        
        var pane = TmuxPane(id: id, windowId: windowId, width: width, height: height)
        pane.isActive = isActive
        pane.cursorX = cursorX
        pane.cursorY = cursorY
        pane.isAlternateScreen = alternateOn
        if inMode {
            pane.mode = .copy // Simplified - could be other modes
        }
        return pane
    }
}
