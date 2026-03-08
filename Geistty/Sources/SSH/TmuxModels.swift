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
    /// Expected format (one line per session, tab-separated):
    ///   `$0\tmysession\t3\t1`
    /// Fields: session_id, session_name, session_windows, session_attached
    ///
    /// Tab delimiter is used because session names can contain colons but not tabs.
    ///
    /// - Parameters:
    ///   - response: Raw text from `list-sessions -F '#{session_id}\t#{session_name}\t#{session_windows}\t#{session_attached}'`
    ///   - currentSessionId: The session ID we're currently attached to (for `isCurrent` flag)
    /// - Returns: Parsed sessions sorted by ID. Malformed lines are silently skipped.
    static func parse(response: String, currentSessionId: String? = nil) -> [TmuxSessionInfo] {
        response.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 3)
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

// MARK: - tmux Options

/// Scope for tmux option queries and mutations.
///
/// tmux options exist at three levels:
/// - **Global** (`-g`): Global defaults, read via `show-options -gv`.
/// - **Session**: Per-session overrides, read via `show-options -v`.
/// - **Window**: Per-window overrides, read via `show-window-options -v`.
///
/// When reading, tmux returns the most-specific value (window > session > global).
/// When writing, you choose which scope to set with `set-option [-g] [-w]`.
enum TmuxOptionScope: Equatable, Sendable {
    /// Global default (show-options -gv, set-option -g)
    case global
    /// Per-session override (show-options -v)
    case session
    /// Per-window override (show-window-options -v, set-option -w)
    case window
    
    /// Build the tmux `show-options` command for this scope.
    ///
    /// The option name is assumed to be pre-sanitized by the caller
    /// (via `sanitizeOptionName`). If you pass an unsanitized name,
    /// use `sanitizeOptionName` first to prevent command injection.
    func showCommand(for option: String) -> String {
        switch self {
        case .global:
            return "show-options -gv \(option)"
        case .session:
            return "show-options -v \(option)"
        case .window:
            return "show-window-options -v \(option)"
        }
    }
    
    /// Build the tmux `set-option` command for this scope.
    ///
    /// The option name is assumed to be pre-sanitized by the caller.
    /// Values are quoted and escaped to prevent command injection over the
    /// SSH control channel (newlines normalized to spaces, backslashes and
    /// double quotes escaped, wrapped in double quotes).
    func setCommand(for option: String, value: String) -> String {
        let safeValue = Self.quoteTmuxValue(value)
        switch self {
        case .global:
            return "set-option -g \(option) \(safeValue)"
        case .session:
            return "set-option \(option) \(safeValue)"
        case .window:
            return "set-option -w \(option) \(safeValue)"
        }
    }
    
    /// Allowlist of characters valid in tmux option names.
    ///
    /// tmux option names are alphanumeric with hyphens, underscores, and `@`
    /// (for user options). Dots appear in some server options. Everything else
    /// — especially `;` (command separator), quotes, backslashes, whitespace,
    /// and control characters — is stripped to prevent command injection.
    private static let allowedOptionNameCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@_-."
    )
    
    /// Sanitize a tmux option name by keeping only allowlisted characters.
    ///
    /// Only `[A-Za-z0-9@_-.]` are permitted. Everything else (whitespace,
    /// control characters, semicolons, quotes, backslashes) is stripped.
    ///
    /// Returns `nil` if the sanitized name is empty or starts with `-`
    /// (which tmux would interpret as flags, not an option name).
    static func sanitizeOptionName(_ option: String) -> String? {
        let filtered = option.unicodeScalars.filter { scalar in
            allowedOptionNameCharacters.contains(scalar)
        }
        let sanitized = String(String.UnicodeScalarView(filtered))
        
        // Empty names would cause tmux to list all options (not what we want).
        // Names starting with "-" would be parsed as flags by tmux.
        guard !sanitized.isEmpty, !sanitized.hasPrefix("-") else {
            return nil
        }
        return sanitized
    }
    
    /// Normalize a tmux option value for cache storage.
    ///
    /// Applies the same control-character cleaning as the command builder,
    /// but does NOT escape backslashes or quotes. This produces the value
    /// as tmux will store it after unescaping the command-line form.
    ///
    /// - Newlines (`\n`, `\r`) are normalized to a single space.
    /// - Other control characters are dropped.
    static func normalizeOptionValue(_ value: String) -> String {
        let cleaned = value.unicodeScalars.compactMap { scalar -> UnicodeScalar? in
            if CharacterSet.controlCharacters.contains(scalar) {
                return (scalar == "\n" || scalar == "\r") ? UnicodeScalar(0x20) : nil
            }
            return scalar
        }
        return String(String.UnicodeScalarView(cleaned))
    }
    
    /// Quote and escape a tmux option value for safe interpolation into a command.
    ///
    /// - Newlines (`\n`, `\r`) are normalized to a single space to prevent
    ///   injecting extra commands (the SSH writer appends its own newline).
    /// - Other control characters are dropped.
    /// - Backslashes and double quotes are escaped with a backslash.
    /// - The entire value is wrapped in double quotes.
    private static func quoteTmuxValue(_ value: String) -> String {
        let cleaned = normalizeOptionValue(value)
        
        var escaped = ""
        escaped.reserveCapacity(cleaned.count + 2)
        for ch in cleaned {
            if ch == "\\" || ch == "\"" {
                escaped.append("\\")
            }
            escaped.append(ch)
        }
        return "\"\(escaped)\""
    }
}

/// Parsed value from a tmux `show-options -v` response.
///
/// tmux option values are always strings, but many have semantic types
/// (boolean on/off, integer, choice). This struct preserves the raw string
/// and provides typed accessors for common patterns.
struct TmuxOptionValue: Equatable, Sendable {
    /// Raw, non-empty string value as returned by `show-options -v`.
    /// If the option is unset or the query yields no value, `parse(response:)` returns `nil`
    /// instead of constructing a `TmuxOptionValue`.
    let rawValue: String
    
    /// Parse a `show-options -v` response into a `TmuxOptionValue`.
    ///
    /// The `-v` flag makes tmux return just the value with no option name prefix.
    /// Response typically has a trailing newline/CR which is stripped, but
    /// meaningful leading/trailing spaces are preserved (e.g., status formats).
    ///
    /// Returns `nil` if the response is empty (option does not exist at this scope).
    static func parse(response: String) -> TmuxOptionValue? {
        // Only strip trailing line terminators, not spaces/tabs which may be meaningful
        var value = response
        while let last = value.last, last == "\n" || last == "\r" {
            value.removeLast()
        }
        guard !value.isEmpty else { return nil }
        return TmuxOptionValue(rawValue: value)
    }
    
    /// Boolean interpretation: `"on"` → `true`, `"off"` → `false`, else `nil`.
    var boolValue: Bool? {
        switch rawValue.lowercased() {
        case "on": return true
        case "off": return false
        default: return nil
        }
    }
    
    /// Integer interpretation, or `nil` if the value isn't a valid integer.
    var intValue: Int? {
        Int(rawValue)
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
