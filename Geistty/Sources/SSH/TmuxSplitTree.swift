//
//  TmuxSplitTree.swift
//  Geistty
//
//  A tree structure representing tmux split panes, ported from Ghostty's SplitTree.
//  Adapted for iOS/iPadOS with tmux pane ID references instead of view references.
//

import Foundation
import os

private let logger = Logger(subsystem: "com.geistty", category: "TmuxSplitTree")

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
    
    // MARK: - PaneInfo
    
    /// Information about a terminal pane - its identity and dimensions
    struct PaneInfo: Equatable, Codable {
        /// Unique pane identifier (tmux %N format, stored as Int)
        let paneId: Int
        
        /// Column count (character width)
        var cols: Int
        
        /// Row count (character height)
        var rows: Int
        
        /// Create pane info with default dimensions
        init(paneId: Int, cols: Int = 80, rows: Int = 24) {
            self.paneId = paneId
            self.cols = cols
            self.rows = rows
        }
        
        /// Size as a tuple for convenience
        var size: (cols: Int, rows: Int) {
            (cols, rows)
        }
    }
    
    // MARK: - Node
    
    /// A single node in the tree - either a leaf pane or a split container.
    indirect enum Node: Equatable, Codable {
        /// A leaf node representing a single tmux pane with its dimensions
        case leaf(PaneInfo)
        
        /// A split node containing two children
        case split(Split)
        
        struct Split: Equatable, Codable {
            let direction: Direction
            let ratio: Double
            let left: Node
            let right: Node
        }
        
        /// Convenience initializer for leaf nodes
        static func leaf(paneId: Int, cols: Int, rows: Int) -> Node {
            .leaf(PaneInfo(paneId: paneId, cols: cols, rows: rows))
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
    
    init(paneId: Int, cols: Int = 80, rows: Int = 24) {
        self.root = .leaf(paneId: paneId, cols: cols, rows: rows)
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
                // Include tmux's exact dimensions for the pane
                return .leaf(paneId: id, cols: layout.width, rows: layout.height)
                
            case .horizontal(let children):
                // Pass the parent's width as the container size (includes divider space)
                return buildSplit(from: children, direction: .horizontal, containerSize: layout.width)
                
            case .vertical(let children):
                // Pass the parent's height as the container size (includes divider space)
                return buildSplit(from: children, direction: .vertical, containerSize: layout.height)
            }
        }
        
        /// Build a binary split tree from multiple children.
        /// tmux layouts can have N children, but our tree is binary.
        ///
        /// `containerSize` is the parent node's width (horizontal) or height (vertical).
        /// tmux includes 1-cell dividers between children in this dimension, so the
        /// correct ratio is `child.size / containerSize`, NOT `child.size / sum(children)`.
        func buildSplit(from children: [TmuxLayout], direction: Direction, containerSize: Int) -> Node {
            guard !children.isEmpty else {
                logger.error("Empty children in tmux layout — returning placeholder pane")
                return .leaf(paneId: -1, cols: 80, rows: 24)
            }
            
            if children.count == 1 {
                return convert(children[0])
            }
            
            if children.count == 2 {
                // Calculate ratio using the parent's container size as denominator.
                // This accounts for tmux's 1-cell divider between children.
                // Example: parent=80, left=40, right=39, divider=1 → ratio = 40/80 = 0.5
                let ratio: Double
                let childSize = Double(direction == .horizontal ? children[0].width : children[0].height)
                let container = Double(containerSize)
                ratio = container > 0 ? childSize / container : 0.5
                
                if direction == .horizontal {
                    logger.info("📐 Split ratio: left=\(children[0].width) right=\(children[1].width) container=\(containerSize) ratio=\(String(format: "%.3f", ratio))")
                } else {
                    logger.info("📐 Split ratio: top=\(children[0].height) bottom=\(children[1].height) container=\(containerSize) ratio=\(String(format: "%.3f", ratio))")
                }
                
                return .split(Node.Split(
                    direction: direction,
                    ratio: ratio,
                    left: convert(children[0]),
                    right: convert(children[1])
                ))
            }
            
            // More than 2 children: split into first and rest.
            // This creates a left-heavy binary tree matching tmux's layout behavior.
            //
            // The first child takes `firstSize` of the container. The remaining
            // container for the rest is: containerSize - firstSize - 1 (the 1 is
            // the divider cell between the first child and the rest).
            let firstSize = direction == .horizontal ? children[0].width : children[0].height
            let restContainerSize = containerSize - firstSize - 1
            
            let firstChild = convert(children[0])
            let restChildren = buildSplit(from: Array(children.dropFirst()), direction: direction, containerSize: restContainerSize)
            
            // Ratio: fraction of the full container that the first child occupies
            let container = Double(containerSize)
            let ratio = container > 0 ? Double(firstSize) / container : 0.5
            
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
    
    /// Get pane info for a specific pane
    func paneInfo(for paneId: Int) -> PaneInfo? {
        guard let root else { return nil }
        return root.findPaneInfo(paneId: paneId)
    }
    
    /// Get all pane infos in the tree
    var allPaneInfos: [PaneInfo] {
        guard let root else { return [] }
        return root.allPaneInfos
    }
    
    // MARK: - Modifications
    
    /// Toggle zoom state for a pane
    func toggleZoom(paneId: Int) -> TmuxSplitTree {
        guard let root else { return self }
        
        // Check if already zoomed on this pane using the paneInfo accessor
        if let zoomed, zoomed.paneId == paneId {
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
    
    /// Update the split ratio for a split that contains the given pane ID
    /// The pane ID should be the leftmost pane ID of the left side of the split
    func updateRatio(forPaneId paneId: Int, ratio: Double) -> TmuxSplitTree {
        guard let root else { return self }
        return TmuxSplitTree(root: root.updateRatio(forPaneId: paneId, ratio: ratio), zoomed: zoomed)
    }
    
    /// Update dimensions for a specific pane (e.g., when Ghostty reports a resize)
    /// Returns a new tree with updated dimensions
    func updatingDimensions(paneId: Int, cols: Int, rows: Int) -> TmuxSplitTree {
        guard let root else { return self }
        let newRoot = root.updatingDimensions(paneId: paneId, cols: cols, rows: rows)
        
        // Also update zoomed node if it's the same pane
        let newZoomed: Node?
        if let zoomed, zoomed.paneId == paneId {
            newZoomed = newRoot.find(paneId: paneId)
        } else {
            newZoomed = zoomed
        }
        
        return TmuxSplitTree(root: newRoot, zoomed: newZoomed)
    }
}

// MARK: - Node Extensions

extension TmuxSplitTree.Node {
    
    // MARK: - Leaf Accessors
    
    /// Get the pane info if this is a leaf node
    var paneInfo: TmuxSplitTree.PaneInfo? {
        if case .leaf(let info) = self { return info }
        return nil
    }
    
    /// Get the pane ID if this is a leaf node
    var paneId: Int? {
        paneInfo?.paneId
    }
    
    /// Get the dimensions if this is a leaf node
    var dimensions: (cols: Int, rows: Int)? {
        paneInfo?.size
    }
    
    /// Check if this node is a leaf with the given pane ID
    func isPane(_ paneId: Int) -> Bool {
        self.paneId == paneId
    }
    
    // MARK: - Tree Queries
    
    /// Get all pane IDs in this subtree
    var paneIds: [Int] {
        switch self {
        case .leaf(let info):
            return [info.paneId]
        case .split(let split):
            return split.left.paneIds + split.right.paneIds
        }
    }
    
    /// Get all pane infos in this subtree
    var allPaneInfos: [TmuxSplitTree.PaneInfo] {
        switch self {
        case .leaf(let info):
            return [info]
        case .split(let split):
            return split.left.allPaneInfos + split.right.allPaneInfos
        }
    }
    
    /// Check if this subtree contains a pane with the given ID
    func contains(paneId: Int) -> Bool {
        switch self {
        case .leaf(let info):
            return info.paneId == paneId
        case .split(let split):
            return split.left.contains(paneId: paneId) || split.right.contains(paneId: paneId)
        }
    }
    
    /// Find the node containing a specific pane ID
    func find(paneId: Int) -> TmuxSplitTree.Node? {
        switch self {
        case .leaf(let info):
            return info.paneId == paneId ? self : nil
        case .split(let split):
            if let found = split.left.find(paneId: paneId) {
                return found
            }
            return split.right.find(paneId: paneId)
        }
    }
    
    /// Find pane info for a specific pane ID
    func findPaneInfo(paneId: Int) -> TmuxSplitTree.PaneInfo? {
        find(paneId: paneId)?.paneInfo
    }
    
    /// Get the path to a pane
    func path(to paneId: Int) -> TmuxSplitTree.Path? {
        switch self {
        case .leaf(let info):
            return info.paneId == paneId ? TmuxSplitTree.Path() : nil
            
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
        case .leaf(let info):
            return info.paneId
        case .split(let split):
            return split.left.leftmostPaneId
        }
    }
    
    /// Get the rightmost leaf pane ID
    var rightmostPaneId: Int {
        switch self {
        case .leaf(let info):
            return info.paneId
        case .split(let split):
            return split.right.rightmostPaneId
        }
    }
    
    // MARK: - Tree Modifications
    
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
    
    /// Update the ratio for a split whose left child contains the given pane ID as its leftmost pane
    func updateRatio(forPaneId paneId: Int, ratio: Double) -> TmuxSplitTree.Node {
        switch self {
        case .leaf:
            return self
        case .split(let split):
            // Check if this split's left child has the target pane as its leftmost
            if split.left.leftmostPaneId == paneId {
                // Update this split's ratio
                return .split(Split(
                    direction: split.direction,
                    ratio: ratio,
                    left: split.left,
                    right: split.right
                ))
            } else {
                // Recurse into children
                return .split(Split(
                    direction: split.direction,
                    ratio: split.ratio,
                    left: split.left.updateRatio(forPaneId: paneId, ratio: ratio),
                    right: split.right.updateRatio(forPaneId: paneId, ratio: ratio)
                ))
            }
        }
    }
    
    /// Update dimensions for a specific pane, returning a new node tree
    func updatingDimensions(paneId: Int, cols: Int, rows: Int) -> TmuxSplitTree.Node {
        switch self {
        case .leaf(let info):
            if info.paneId == paneId {
                return .leaf(TmuxSplitTree.PaneInfo(paneId: paneId, cols: cols, rows: rows))
            }
            return self
        case .split(let split):
            return .split(Split(
                direction: split.direction,
                ratio: split.ratio,
                left: split.left.updatingDimensions(paneId: paneId, cols: cols, rows: rows),
                right: split.right.updatingDimensions(paneId: paneId, cols: cols, rows: rows)
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
        
        // Encode zoomed as pane ID (dimensions are stored in the tree)
        if let zoomedPaneId = zoomed?.paneId {
            try container.encode(zoomedPaneId, forKey: .zoomedPaneId)
        }
    }
}

// MARK: - Debug Description

extension TmuxSplitTree: CustomDebugStringConvertible {
    var debugDescription: String {
        guard let root else { return "TmuxSplitTree(empty)" }
        
        func describe(_ node: Node, indent: String = "") -> String {
            switch node {
            case .leaf(let info):
                let zoomed = self.zoomed == node ? " [ZOOMED]" : ""
                return "\(indent)Pane %\(info.paneId) (\(info.cols)x\(info.rows))\(zoomed)"
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
