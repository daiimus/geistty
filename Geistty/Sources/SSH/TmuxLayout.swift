//
//  TmuxLayout.swift
//  Geistty
//
//  tmux layout string parser, ported from Ghostty's layout.zig
//  Parses tmux layout strings into a tree structure for rendering.
//
//  Layout format examples:
//  - Single pane: "d962,80x24,0,0,42"
//  - Horizontal split: "f8f9,80x24,0,0{40x24,0,0,1,40x24,40,0,2}"
//  - Vertical split: "bb62,80x24,0,0[80x12,0,0,1,80x12,0,12,2]"
//

import Foundation

// MARK: - TmuxLayout

/// A parsed tmux layout tree structure.
///
/// This represents the hierarchical arrangement of panes in a tmux window.
/// The layout can be a single pane or a split (horizontal or vertical)
/// containing multiple child layouts.
struct TmuxLayout: Equatable {
    /// Width of this node in characters
    let width: Int
    
    /// Height of this node in characters
    let height: Int
    
    /// X offset from the top-left corner of the window
    let x: Int
    
    /// Y offset from the top-left corner of the window
    let y: Int
    
    /// The content of this node - either a pane or a split container
    let content: Content
    
    /// The content type for a layout node
    enum Content: Equatable {
        /// A leaf pane with its numeric ID
        case pane(id: Int)
        
        /// A horizontal split (children arranged left-to-right)
        case horizontal(children: [TmuxLayout])
        
        /// A vertical split (children arranged top-to-bottom)
        case vertical(children: [TmuxLayout])
    }
    
    // MARK: - Errors
    
    enum ParseError: Error, Equatable {
        /// Layout string syntax is invalid
        case syntaxError
        
        /// Checksum doesn't match the layout content
        case checksumMismatch
    }
    
    // MARK: - Parsing
    
    /// Parse a layout string that includes a 4-character checksum prefix.
    ///
    /// The expected format is: `XXXX,layout_string` where XXXX is the
    /// 4-character hexadecimal checksum and the layout string follows
    /// after the comma. For example: `f8f9,80x24,0,0{40x24,0,0,1,40x24,40,0,2}`.
    ///
    /// - Parameter str: The complete layout string with checksum
    /// - Returns: The parsed layout
    /// - Throws: `ParseError.checksumMismatch` if checksum doesn't match
    /// - Throws: `ParseError.syntaxError` if format is invalid
    static func parseWithChecksum(_ str: String) throws -> TmuxLayout {
        // Minimum: 4-char checksum + comma = 5 chars
        guard str.count >= 5 else {
            throw ParseError.syntaxError
        }
        
        let index4 = str.index(str.startIndex, offsetBy: 4)
        guard str[index4] == "," else {
            throw ParseError.syntaxError
        }
        
        let checksumStr = String(str[..<index4])
        let layoutStr = String(str[str.index(after: index4)...])
        
        // Calculate and verify checksum
        let calculated = TmuxChecksum.calculate(layoutStr)
        guard checksumStr == calculated.asString() else {
            throw ParseError.checksumMismatch
        }
        
        return try parse(layoutStr)
    }
    
    /// Parse a layout string without checksum verification.
    ///
    /// Tmux layout strings have the following format:
    /// - `WxH,X,Y,ID` - Leaf pane: width×height, x-offset, y-offset, pane ID
    /// - `WxH,X,Y{...}` - Horizontal split (left-right), children comma-separated
    /// - `WxH,X,Y[...]` - Vertical split (top-bottom), children comma-separated
    ///
    /// - Parameter str: The layout string without checksum
    /// - Returns: The parsed layout
    /// - Throws: `ParseError.syntaxError` if format is invalid
    static func parse(_ str: String) throws -> TmuxLayout {
        var offset = str.startIndex
        let layout = try parseNext(str, offset: &offset)
        
        // Ensure we consumed the entire string
        guard offset == str.endIndex else {
            throw ParseError.syntaxError
        }
        
        return layout
    }
    
    /// Parse the next layout node from the string at the given offset.
    private static func parseNext(_ str: String, offset: inout String.Index) throws -> TmuxLayout {
        // Find width (up to 'x')
        guard let xIdx = str[offset...].firstIndex(of: "x") else {
            throw ParseError.syntaxError
        }
        guard let width = Int(str[offset..<xIdx]) else {
            throw ParseError.syntaxError
        }
        offset = str.index(after: xIdx) // Consume 'x'
        
        // Find height (up to ',')
        guard let heightCommaIdx = str[offset...].firstIndex(of: ",") else {
            throw ParseError.syntaxError
        }
        guard let height = Int(str[offset..<heightCommaIdx]) else {
            throw ParseError.syntaxError
        }
        offset = str.index(after: heightCommaIdx) // Consume ','
        
        // Find X (up to ',')
        guard let xCommaIdx = str[offset...].firstIndex(of: ",") else {
            throw ParseError.syntaxError
        }
        guard let x = Int(str[offset..<xCommaIdx]) else {
            throw ParseError.syntaxError
        }
        offset = str.index(after: xCommaIdx) // Consume ','
        
        // Find Y (up to ',', '{', or '[')
        guard let yEndIdx = str[offset...].firstIndex(where: { $0 == "," || $0 == "{" || $0 == "[" }) else {
            throw ParseError.syntaxError
        }
        guard let y = Int(str[offset..<yEndIdx]) else {
            throw ParseError.syntaxError
        }
        offset = yEndIdx // Don't consume the delimiter yet
        
        // Determine content type based on delimiter
        let delimiter = str[offset]
        let content: Content
        
        switch delimiter {
        case ",":
            // Leaf pane - read pane ID
            offset = str.index(after: offset) // Consume ','
            
            // Find end of pane ID (up to ',', '}', ']', or end)
            let paneEndIdx = str[offset...].firstIndex(where: { $0 == "," || $0 == "}" || $0 == "]" }) ?? str.endIndex
            
            guard let paneId = Int(str[offset..<paneEndIdx]) else {
                throw ParseError.syntaxError
            }
            
            offset = paneEndIdx // Don't consume delimiter (might be parent's)
            content = .pane(id: paneId)
            
        case "{", "[":
            // Split container
            let opening = delimiter
            let closing: Character = opening == "{" ? "}" : "]"
            
            offset = str.index(after: offset) // Consume opening bracket
            
            var children: [TmuxLayout] = []
            
            while true {
                // Parse child node
                let child = try parseNext(str, offset: &offset)
                children.append(child)
                
                // Check what follows
                guard offset < str.endIndex else {
                    throw ParseError.syntaxError // Unclosed bracket
                }
                
                let nextChar = str[offset]
                
                if nextChar == "," {
                    // More children follow
                    offset = str.index(after: offset) // Consume ','
                    continue
                }
                
                // Must be closing bracket
                guard nextChar == closing else {
                    throw ParseError.syntaxError // Mismatched bracket
                }
                
                offset = str.index(after: offset) // Consume closing bracket
                break
            }
            
            content = opening == "{" ? .horizontal(children: children) : .vertical(children: children)
            
        default:
            throw ParseError.syntaxError
        }
        
        return TmuxLayout(width: width, height: height, x: x, y: y, content: content)
    }
    
    // MARK: - Convenience
    
    /// Get all pane IDs in this layout (depth-first order)
    var paneIds: [Int] {
        switch content {
        case .pane(let id):
            return [id]
        case .horizontal(let children), .vertical(let children):
            return children.flatMap { $0.paneIds }
        }
    }
    
    /// Find the layout node for a specific pane ID
    func findPane(_ id: Int) -> TmuxLayout? {
        switch content {
        case .pane(let paneId):
            return paneId == id ? self : nil
        case .horizontal(let children), .vertical(let children):
            for child in children {
                if let found = child.findPane(id) {
                    return found
                }
            }
            return nil
        }
    }
    
    /// Whether this is a leaf pane
    var isPane: Bool {
        if case .pane = content { return true }
        return false
    }
    
    /// Whether this is a split container
    var isSplit: Bool {
        switch content {
        case .horizontal, .vertical: return true
        case .pane: return false
        }
    }
}

// MARK: - TmuxChecksum

/// tmux layout checksum calculator.
///
/// The algorithm rotates the checksum right by 1 bit (with wraparound)
/// and adds the ASCII value of each character.
struct TmuxChecksum: Equatable {
    private let value: UInt16
    
    /// Calculate the checksum of a tmux layout string.
    static func calculate(_ str: String) -> TmuxChecksum {
        var result: UInt16 = 0
        
        for byte in str.utf8 {
            // Rotate right by 1: (result >> 1) | ((result & 1) << 15)
            result = (result >> 1) | ((result & 1) << 15)
            result &+= UInt16(byte)
        }
        
        return TmuxChecksum(value: result)
    }
    
    /// Convert the checksum to a 4-character hexadecimal string.
    /// Always zero-padded to match tmux's implementation.
    func asString() -> String {
        String(format: "%04x", value)
    }
    
    /// Create a checksum from a raw value (for testing)
    init(value: UInt16) {
        self.value = value
    }
}

// MARK: - CustomDebugStringConvertible

extension TmuxLayout: CustomDebugStringConvertible {
    var debugDescription: String {
        func describe(_ layout: TmuxLayout, indent: String = "") -> String {
            let sizePos = "\(layout.width)x\(layout.height)@(\(layout.x),\(layout.y))"
            switch layout.content {
            case .pane(let id):
                return "\(indent)Pane \(id): \(sizePos)"
            case .horizontal(let children):
                var result = "\(indent)Horizontal \(sizePos):"
                for child in children {
                    result += "\n" + describe(child, indent: indent + "  ")
                }
                return result
            case .vertical(let children):
                var result = "\(indent)Vertical \(sizePos):"
                for child in children {
                    result += "\n" + describe(child, indent: indent + "  ")
                }
                return result
            }
        }
        return describe(self)
    }
}
