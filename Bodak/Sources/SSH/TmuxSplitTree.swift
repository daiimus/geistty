//
//  TmuxSplitTree.swift
//  Bodak
//
//  A tree structure representing tmux split panes, ported from Ghostty's SplitTree.
//  Adapted for iOS/iPadOS with tmux pane ID references instead of view references.
//

import Foundation

// MARK: - TmuxSplitTree

/// A tree structure for representing tmux split panes.
///
/// Unlike Ghostty's SplitTree which holds view references, this holds pane IDs
/// that map to Ghostty surfaces. This decouples the layout from the view layer.
struct TmuxSplitTree: Equatable {
    /// The root of the tree. nil indicates an empty tree.
    let root: Node?
    
    /// The node that is currently zoomed (taking full screen).
    let zoomed: Node?
    
    // MARK: - Node
    
    /// A single node in the tree - either a leaf pane or a split container.
    indirect enum Node: Equatable, Codable {
        /// A leaf node representing a single tmux pane
        case leaf(paneId: Int)
        
        /// A split node containing two children
        case split(Split)
        
        struct Split: Equatable, Codable {
            let direction: Direction
            let ratio: Double
            let left: Node
            let right: Node
        }
    }
    
    // MARK: - Direction
    
    /// Split direction
    enum Direction: Codable {
        /// Horizontal split - children arranged left and right
        case horizontal
        
        /// Vertical split - children arranged top and bottom
        case vertical
    }
    
    // MARK: - Path
    
    /// A path to a specific node in the tree
    struct Path: Equatable, Codable {
        let components: [Component]
        
        var isEmpty: Bool { components.isEmpty }
        
        enum Component: Codable {
            case left
            case right
        }
        
        init(_ components: [Component] = []) {
            self.components = components
        }
        
        func appending(_ component: Component) -> Path {
            Path(components + [component])
        }
    }
    
    // MARK: - Errors
    
    enum SplitError: Error {
        case paneNotFound
    }
    
    // MARK: - Initialization
    
    init() {
        self.root = nil
        self.zoomed = nil
    }
    
    init(paneId: Int) {
        self.root = .leaf(paneId: paneId)
        self.zoomed = nil
    }
    
    init(root: Node?, zoomed: Node? = nil) {
        self.root = root
        self.zoomed = zoomed
    }
    
    // MARK: - From TmuxLayout
    
    /// Create a split tree from a parsed TmuxLayout
    static func from(layout: TmuxLayout) -> TmuxSplitTree {
        func convert(_ layout: TmuxLayout) -> Node {
            switch layout.content {
            case .pane(let id):
                return .leaf(paneId: id)
                
            case .horizontal(let children):
                return buildSplit(from: children, direction: .horizontal)
                
            case .vertical(let children):
                return buildSplit(from: children, direction: .vertical)
            }
        }
        
        /// Build a binary split tree from multiple children.
        /// tmux layouts can have N children, but our tree is binary.
        func buildSplit(from children: [TmuxLayout], direction: Direction) -> Node {
            guard !children.isEmpty else {
                fatalError("Empty children in tmux layout")
            }
            
            if children.count == 1 {
                return convert(children[0])
            }
            
            if children.count == 2 {
                // Calculate ratio based on dimensions
                let ratio: Double
                if direction == .horizontal {
                    let totalWidth = Double(children[0].width + children[1].width)
                    ratio = totalWidth > 0 ? Double(children[0].width) / totalWidth : 0.5
                } else {
                    let totalHeight = Double(children[0].height + children[1].height)
                    ratio = totalHeight > 0 ? Double(children[0].height) / totalHeight : 0.5
                }
                
                return .split(Node.Split(
                    direction: direction,
                    ratio: ratio,
                    left: convert(children[0]),
                    right: convert(children[1])
                ))
            }
            
            // More than 2 children: split into first and rest
            // This creates a left-heavy tree which matches tmux's layout behavior
            let firstChild = convert(children[0])
            let restChildren = buildSplit(from: Array(children.dropFirst()), direction: direction)
            
            // Calculate ratio for first child vs rest
            let firstSize = direction == .horizontal ? children[0].width : children[0].height
            let restSize = children.dropFirst().reduce(0) { sum, child in
                sum + (direction == .horizontal ? child.width : child.height)
            }
            let totalSize = Double(firstSize + restSize)
            let ratio = totalSize > 0 ? Double(firstSize) / totalSize : 0.5
            
            return .split(Node.Split(
                direction: direction,
                ratio: ratio,
                left: firstChild,
                right: restChildren
            ))
        }
        
        return TmuxSplitTree(root: convert(layout))
    }
    
    // MARK: - Properties
    
    var isEmpty: Bool {
        root == nil
    }
    
    var isSplit: Bool {
        if case .split = root { return true }
        return false
    }
    
    /// Get all pane IDs in the tree (depth-first order)
    var paneIds: [Int] {
        guard let root else { return [] }
        return root.paneIds
    }
    
    // MARK: - Queries
    
    /// Check if the tree contains a pane with the given ID
    func contains(paneId: Int) -> Bool {
        guard let root else { return false }
        return root.contains(paneId: paneId)
    }
    
    /// Find the node containing a specific pane ID
    func find(paneId: Int) -> Node? {
        guard let root else { return nil }
        return root.find(paneId: paneId)
    }
    
    /// Get the path to a pane
    func path(to paneId: Int) -> Path? {
        guard let root else { return nil }
        return root.path(to: paneId)
    }
    
    // MARK: - Modifications
    
    /// Toggle zoom state for a pane
    func toggleZoom(paneId: Int) -> TmuxSplitTree {
        guard let root else { return self }
        
        if let zoomed, case .leaf(let zoomedId) = zoomed, zoomedId == paneId {
            // Already zoomed on this pane, unzoom
            return TmuxSplitTree(root: root, zoomed: nil)
        }
        
        // Zoom the pane if it exists
        if let node = root.find(paneId: paneId) {
            return TmuxSplitTree(root: root, zoomed: node)
        }
        
        return self
    }
    
    /// Clear zoom state
    func clearZoom() -> TmuxSplitTree {
        TmuxSplitTree(root: root, zoomed: nil)
    }
    
    /// Equalize all split ratios in the tree
    func equalize() -> TmuxSplitTree {
        guard let root else { return self }
        return TmuxSplitTree(root: root.equalize(), zoomed: zoomed)
    }
}

// MARK: - Node Extensions

extension TmuxSplitTree.Node {
    
    /// Get all pane IDs in this subtree
    var paneIds: [Int] {
        switch self {
        case .leaf(let paneId):
            return [paneId]
        case .split(let split):
            return split.left.paneIds + split.right.paneIds
        }
    }
    
    /// Check if this subtree contains a pane with the given ID
    func contains(paneId: Int) -> Bool {
        switch self {
        case .leaf(let id):
            return id == paneId
        case .split(let split):
            return split.left.contains(paneId: paneId) || split.right.contains(paneId: paneId)
        }
    }
    
    /// Find the node containing a specific pane ID
    func find(paneId: Int) -> TmuxSplitTree.Node? {
        switch self {
        case .leaf(let id):
            return id == paneId ? self : nil
        case .split(let split):
            if let found = split.left.find(paneId: paneId) {
                return found
            }
            return split.right.find(paneId: paneId)
        }
    }
    
    /// Get the path to a pane
    func path(to paneId: Int) -> TmuxSplitTree.Path? {
        switch self {
        case .leaf(let id):
            return id == paneId ? TmuxSplitTree.Path() : nil
            
        case .split(let split):
            if let leftPath = split.left.path(to: paneId) {
                return TmuxSplitTree.Path([.left] + leftPath.components)
            }
            if let rightPath = split.right.path(to: paneId) {
                return TmuxSplitTree.Path([.right] + rightPath.components)
            }
            return nil
        }
    }
    
    /// Get the leftmost leaf pane ID
    var leftmostPaneId: Int {
        switch self {
        case .leaf(let paneId):
            return paneId
        case .split(let split):
            return split.left.leftmostPaneId
        }
    }
    
    /// Get the rightmost leaf pane ID
    var rightmostPaneId: Int {
        switch self {
        case .leaf(let paneId):
            return paneId
        case .split(let split):
            return split.right.rightmostPaneId
        }
    }
    
    /// Equalize all split ratios in this subtree
    func equalize() -> TmuxSplitTree.Node {
        switch self {
        case .leaf:
            return self
        case .split(let split):
            return .split(Split(
                direction: split.direction,
                ratio: 0.5,
                left: split.left.equalize(),
                right: split.right.equalize()
            ))
        }
    }
    
    /// Count the number of leaf nodes (panes) in this subtree
    var leafCount: Int {
        switch self {
        case .leaf:
            return 1
        case .split(let split):
            return split.left.leafCount + split.right.leafCount
        }
    }
}

// MARK: - Codable

extension TmuxSplitTree: Codable {
    private enum CodingKeys: String, CodingKey {
        case version
        case root
        case zoomedPaneId
    }
    
    private static let currentVersion = 1
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unsupported TmuxSplitTree version: \(version)"
                )
            )
        }
        
        self.root = try container.decodeIfPresent(Node.self, forKey: .root)
        
        // Decode zoomed pane ID and find the node
        if let zoomedPaneId = try container.decodeIfPresent(Int.self, forKey: .zoomedPaneId),
           let root = self.root {
            self.zoomed = root.find(paneId: zoomedPaneId)
        } else {
            self.zoomed = nil
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encodeIfPresent(root, forKey: .root)
        
        // Encode zoomed as pane ID
        if let zoomed, case .leaf(let paneId) = zoomed {
            try container.encode(paneId, forKey: .zoomedPaneId)
        }
    }
}

// MARK: - Debug Description

extension TmuxSplitTree: CustomDebugStringConvertible {
    var debugDescription: String {
        guard let root else { return "TmuxSplitTree(empty)" }
        
        func describe(_ node: Node, indent: String = "") -> String {
            switch node {
            case .leaf(let paneId):
                let zoomed = self.zoomed == node ? " [ZOOMED]" : ""
                return "\(indent)Pane %\(paneId)\(zoomed)"
            case .split(let split):
                let dir = split.direction == .horizontal ? "H" : "V"
                let ratio = String(format: "%.0f%%", split.ratio * 100)
                var result = "\(indent)Split(\(dir), \(ratio)):"
                result += "\n" + describe(split.left, indent: indent + "  ├─ ")
                result += "\n" + describe(split.right, indent: indent + "  └─ ")
                return result
            }
        }
        
        return describe(root)
    }
}
