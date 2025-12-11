//
//  TmuxModels.swift
//  Bodak
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

/// Parsed tmux layout for rendering
struct TmuxLayout: Equatable {
    /// Layout checksum (for change detection)
    let checksum: String
    
    /// Root node of the layout tree
    let root: LayoutNode
    
    /// A node in the layout tree (either a pane or a split container)
    indirect enum LayoutNode: Equatable {
        /// A single pane
        case pane(PaneLayout)
        
        /// Horizontal split (panes side by side)
        case horizontal(children: [LayoutNode])
        
        /// Vertical split (panes stacked)
        case vertical(children: [LayoutNode])
    }
    
    /// Layout information for a single pane
    struct PaneLayout: Equatable {
        let paneId: String
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }
    
    /// Parse a tmux layout string
    /// Format: "checksum,WxH,X,Y{...}" or "checksum,WxH,X,Y[...]" or "checksum,WxH,X,Y,paneId"
    static func parse(_ layoutString: String) -> TmuxLayout? {
        // Layout format examples:
        // Single pane: "a]be,80x24,0,0,0"
        // Horizontal split: "d2e3,80x24,0,0{40x24,0,0,0,39x24,41,0,1}"
        // Vertical split: "d2e3,80x24,0,0[80x12,0,0,0,80x11,0,13,1]"
        
        guard let commaIndex = layoutString.firstIndex(of: ",") else {
            return nil
        }
        
        let checksum = String(layoutString[..<commaIndex])
        let rest = String(layoutString[layoutString.index(after: commaIndex)...])
        
        guard let node = parseNode(rest) else {
            return nil
        }
        
        return TmuxLayout(checksum: checksum, root: node)
    }
    
    /// Parse a layout node
    private static func parseNode(_ str: String) -> LayoutNode? {
        // Find dimensions (WxH,X,Y)
        let parts = str.split(separator: ",", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        
        // Parse WxH
        let dimParts = parts[0].split(separator: "x")
        guard dimParts.count == 2,
              let width = Int(dimParts[0]),
              let height = Int(dimParts[1]) else {
            return nil
        }
        
        // Parse X,Y
        guard let x = Int(parts[1]),
              let y = Int(parts[2]) else {
            return nil
        }
        
        // Check if there's more content
        if parts.count > 3 {
            let remainder = String(parts[3])
            
            // Check for container (starts with { or [)
            if remainder.hasPrefix("{") {
                // Horizontal split
                let content = String(remainder.dropFirst().dropLast())
                let children = parseChildren(content)
                return .horizontal(children: children)
            } else if remainder.hasPrefix("[") {
                // Vertical split
                let content = String(remainder.dropFirst().dropLast())
                let children = parseChildren(content)
                return .vertical(children: children)
            } else {
                // Single pane - remainder is pane ID
                let paneId = "%\(remainder)"
                return .pane(PaneLayout(paneId: paneId, x: x, y: y, width: width, height: height))
            }
        }
        
        // No remainder - this shouldn't happen in a valid layout
        return nil
    }
    
    /// Parse children of a container
    private static func parseChildren(_ str: String) -> [LayoutNode] {
        var children: [LayoutNode] = []
        var current = ""
        var depth = 0
        
        for char in str {
            switch char {
            case "{", "[":
                depth += 1
                current.append(char)
            case "}", "]":
                depth -= 1
                current.append(char)
            case "," where depth == 0:
                // Top-level comma - separator between children
                if let node = parseNode(current) {
                    children.append(node)
                }
                current = ""
            default:
                current.append(char)
            }
        }
        
        // Don't forget the last child
        if !current.isEmpty, let node = parseNode(current) {
            children.append(node)
        }
        
        return children
    }
}

// MARK: - Query Formats

/// Format strings for tmux queries
enum TmuxQueryFormat {
    /// list-sessions format
    static let sessions = "#{session_id} #{q:session_name} #{session_windows} #{session_attached}"
    
    /// list-windows format  
    static let windows = "#{window_id} #{window_index} #{q:window_name} #{window_active} #{window_flags} #{window_layout}"
    
    /// list-panes format
    static let panes = "#{pane_id} #{pane_width} #{pane_height} #{pane_active} #{cursor_x} #{cursor_y} #{pane_in_mode} #{alternate_on}"
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
    /// Format: "@0 0 window_name 1 *- layout_string"
    static func parse(_ line: String, sessionId: String) -> TmuxWindow? {
        // Use regex-like parsing for quoted names
        let parts = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: false)
        guard parts.count >= 6 else { return nil }
        
        let id = String(parts[0])
        guard let index = Int(parts[1]) else { return nil }
        let name = String(parts[2]).replacingOccurrences(of: "\"", with: "")
        let isActive = parts[3] == "1"
        let flags = String(parts[4])
        let layout = String(parts[5])
        
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
    /// Format: "%0 80 24 1 5 10 0 0"
    static func parse(_ line: String, windowId: String) -> TmuxPane? {
        let parts = line.split(separator: " ")
        guard parts.count >= 8 else { return nil }
        
        let id = String(parts[0])
        guard let width = Int(parts[1]),
              let height = Int(parts[2]) else { return nil }
        
        let isActive = parts[3] == "1"
        let cursorX = Int(parts[4]) ?? 0
        let cursorY = Int(parts[5]) ?? 0
        let inMode = parts[6] != "0"
        let alternateOn = parts[7] == "1"
        
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
