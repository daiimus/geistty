//
//  TmuxSplitView.swift
//  Geistty
//
//  SwiftUI split view for rendering tmux pane layouts.
//  Ported from Ghostty's SplitView.swift, adapted for iOS/iPadOS.
//

import SwiftUI
import os

private let logger = os.Logger(subsystem: "com.geistty.app", category: "TmuxSplitView")

// MARK: - SplitViewDirection

/// Direction of a split
enum SplitViewDirection: Codable {
    case horizontal  // Children side by side (left/right)
    case vertical    // Children stacked (top/bottom)
}

// MARK: - TmuxSplitDivider

/// A divider between split panes with drag and double-tap support
struct TmuxSplitDivider: View {
    let direction: SplitViewDirection
    let visibleSize: CGFloat
    let invisibleSize: CGFloat
    let color: Color
    
    @Binding var split: CGFloat
    
    var body: some View {
        switch direction {
        case .horizontal:
            // Vertical line divider for horizontal splits
            Rectangle()
                .fill(color)
                .frame(width: visibleSize)
                .padding(.horizontal, invisibleSize / 2)
                .frame(width: visibleSize + invisibleSize)
                .contentShape(Rectangle())
            
        case .vertical:
            // Horizontal line divider for vertical splits
            Rectangle()
                .fill(color)
                .frame(height: visibleSize)
                .padding(.vertical, invisibleSize / 2)
                .frame(height: visibleSize + invisibleSize)
                .contentShape(Rectangle())
        }
    }
}

// MARK: - TmuxSplitView

/// A split view that shows two views with a resizable divider between them.
///
/// The terminology "left" and "right" is used throughout but for vertical splits
/// "left" means "top" and "right" means "bottom".
struct TmuxSplitView<L: View, R: View>: View {
    /// Direction of the split
    let direction: SplitViewDirection
    
    /// Divider color
    let dividerColor: Color
    
    /// The left (or top) view
    let left: L
    
    /// The right (or bottom) view
    let right: R
    
    /// Called when the divider is double-tapped to equalize splits
    let onEqualize: () -> Void
    
    /// The minimum size (in points) of each split
    let minSize: CGFloat = 44  // iOS touch target minimum
    
    /// Current split ratio (0.0 to 1.0)
    @Binding var split: CGFloat
    
    /// Visible size of the divider
    private let dividerVisibleSize: CGFloat = 1
    
    /// Invisible hitbox size around the divider for easier touch
    private let dividerInvisibleSize: CGFloat = 20  // Larger for touch targets
    
    var body: some View {
        GeometryReader { geo in
            let leftRect = leftRect(for: geo.size)
            let rightRect = rightRect(for: geo.size, leftRect: leftRect)
            let dividerPosition = dividerPosition(for: geo.size, leftRect: leftRect)
            

            ZStack(alignment: .topLeading) {
                // Left (or top) view
                left
                    .frame(width: leftRect.width, height: leftRect.height)
                    .offset(x: leftRect.origin.x, y: leftRect.origin.y)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(direction == .horizontal ? "Left pane" : "Top pane")
                
                // Right (or bottom) view
                right
                    .frame(width: rightRect.width, height: rightRect.height)
                    .offset(x: rightRect.origin.x, y: rightRect.origin.y)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(direction == .horizontal ? "Right pane" : "Bottom pane")
                
                // Divider
                TmuxSplitDivider(
                    direction: direction,
                    visibleSize: dividerVisibleSize,
                    invisibleSize: dividerInvisibleSize,
                    color: dividerColor,
                    split: $split
                )
                .position(dividerPosition)
                .gesture(dragGesture(geo.size))
                .onTapGesture(count: 2) {
                    onEqualize()
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(direction == .horizontal ? "Horizontal split" : "Vertical split")
        }
    }
    
    init(
        _ direction: SplitViewDirection,
        _ split: Binding<CGFloat>,
        dividerColor: Color,
        @ViewBuilder left: () -> L,
        @ViewBuilder right: () -> R,
        onEqualize: @escaping () -> Void
    ) {
        self.direction = direction
        self._split = split
        self.dividerColor = dividerColor
        self.left = left()
        self.right = right()
        self.onEqualize = onEqualize
    }
    
    // MARK: - Layout Calculations
    
    private func leftRect(for size: CGSize) -> CGRect {
        var result = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        
        switch direction {
        case .horizontal:
            result.size.width = size.width * split
            result.size.width -= dividerVisibleSize / 2
            
        case .vertical:
            result.size.height = size.height * split
            result.size.height -= dividerVisibleSize / 2
        }
        
        return result
    }
    
    private func rightRect(for size: CGSize, leftRect: CGRect) -> CGRect {
        var result = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        
        switch direction {
        case .horizontal:
            result.origin.x = leftRect.width + dividerVisibleSize / 2
            result.size.width -= result.origin.x
            
        case .vertical:
            result.origin.y = leftRect.height + dividerVisibleSize / 2
            result.size.height -= result.origin.y
        }
        
        return result
    }
    
    private func dividerPosition(for size: CGSize, leftRect: CGRect) -> CGPoint {
        switch direction {
        case .horizontal:
            return CGPoint(x: leftRect.width, y: size.height / 2)
            
        case .vertical:
            return CGPoint(x: size.width / 2, y: leftRect.height)
        }
    }
    
    // MARK: - Gestures
    
    private func dragGesture(_ size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { gesture in
                switch direction {
                case .horizontal:
                    let newX = min(max(minSize, gesture.location.x), size.width - minSize)
                    split = newX / size.width
                    
                case .vertical:
                    let newY = min(max(minSize, gesture.location.y), size.height - minSize)
                    split = newY / size.height
                }
            }
    }
}

// MARK: - TmuxSplitTreeView

/// Renders a TmuxSplitTree as nested split views.
///
/// This view takes a split tree and a pane view builder, and recursively
/// renders the tree structure with appropriate split views and dividers.
struct TmuxSplitTreeView<PaneContent: View>: View {
    /// The split tree to render
    let tree: TmuxSplitTree
    
    /// Divider color
    let dividerColor: Color
    
    /// Called when a split is resized
    let onResize: (Int, Double) -> Void  // (paneId, newRatio)
    
    /// Called when splits should be equalized
    let onEqualize: () -> Void
    
    /// Called when a pane is double-tapped (toggle zoom)
    let onToggleZoom: (Int) -> Void  // paneId
    
    /// View builder for pane content (paneId, cols, rows)
    let paneContent: (Int, Int, Int) -> PaneContent
    
    var body: some View {
        if let zoomed = tree.zoomed {
            // Zoomed mode - show only the zoomed pane
            switch zoomed {
            case .leaf(let info):
                ZoomablePane(paneId: info.paneId, onToggleZoom: onToggleZoom) {
                    paneContent(info.paneId, info.cols, info.rows)
                }
                .accessibilityLabel("Zoomed pane (double-tap to unzoom)")
            case .split(let split):
                // Shouldn't happen, but handle it
                TmuxSplitNodeView(
                    node: .split(split),
                    dividerColor: dividerColor,
                    onResize: onResize,
                    onEqualize: onEqualize,
                    onToggleZoom: onToggleZoom,
                    paneContent: paneContent
                )
            }
        } else if let root = tree.root {
            // Normal mode - show full tree
            TmuxSplitNodeView(
                node: root,
                dividerColor: dividerColor,
                onResize: onResize,
                onEqualize: onEqualize,
                onToggleZoom: onToggleZoom,
                paneContent: paneContent
            )
        } else {
            // Empty tree
            Text("No panes")
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - TmuxSplitNodeView

/// Recursively renders a single node in the split tree.
private struct TmuxSplitNodeView<PaneContent: View>: View {
    let node: TmuxSplitTree.Node
    let dividerColor: Color
    let onResize: (Int, Double) -> Void
    let onEqualize: () -> Void
    let onToggleZoom: (Int) -> Void
    let paneContent: (Int, Int, Int) -> PaneContent  // (paneId, cols, rows)
    
    var body: some View {
        switch node {
        case .leaf(let info):
            ZoomablePane(paneId: info.paneId, onToggleZoom: onToggleZoom) {
                paneContent(info.paneId, info.cols, info.rows)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Terminal pane \(info.paneId)")
            
        case .split(let split):
            let direction: SplitViewDirection = split.direction == .horizontal ? .horizontal : .vertical

            
            TmuxSplitView(
                direction,
                .init(
                    get: { CGFloat(split.ratio) },
                    set: { newRatio in
                        // Report the resize to the parent
                        // We report the leftmost pane ID so the parent knows which split changed
                        onResize(split.left.leftmostPaneId, Double(newRatio))
                    }
                ),
                dividerColor: dividerColor,
                left: {
                    TmuxSplitNodeView(
                        node: split.left,
                        dividerColor: dividerColor,
                        onResize: onResize,
                        onEqualize: onEqualize,
                        onToggleZoom: onToggleZoom,
                        paneContent: paneContent
                    )
                },
                right: {
                    TmuxSplitNodeView(
                        node: split.right,
                        dividerColor: dividerColor,
                        onResize: onResize,
                        onEqualize: onEqualize,
                        onToggleZoom: onToggleZoom,
                        paneContent: paneContent
                    )
                },
                onEqualize: onEqualize
            )
        }
    }
}

// MARK: - ZoomablePane

/// A wrapper view that adds double-tap zoom gesture to a pane
private struct ZoomablePane<Content: View>: View {
    let paneId: Int
    let onToggleZoom: (Int) -> Void
    let content: Content
    
    init(paneId: Int, onToggleZoom: @escaping (Int) -> Void, @ViewBuilder content: () -> Content) {
        self.paneId = paneId
        self.onToggleZoom = onToggleZoom
        self.content = content()
    }
    
    var body: some View {
        content
            .contentShape(Rectangle())  // Make entire pane tappable
            .onTapGesture(count: 2) {
                onToggleZoom(paneId)
            }
            .accessibilityAction(named: "Toggle zoom") {
                onToggleZoom(paneId)
            }
    }
}

// MARK: - Preview

#if DEBUG
struct TmuxSplitView_Previews: PreviewProvider {
    static var previews: some View {
        // Preview with a simple horizontal split
        let tree = TmuxSplitTree(root: .split(.init(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(paneId: 0, cols: 40, rows: 24),
            right: .leaf(paneId: 1, cols: 40, rows: 24)
        )))
        
        TmuxSplitTreeView(
            tree: tree,
            dividerColor: .gray,
            onResize: { _, _ in },
            onEqualize: { },
            onToggleZoom: { paneId in print("Zoom toggled: \(paneId)") },
            paneContent: { paneId, cols, rows in
                ZStack {
                    Color(white: 0.1)
                    Text("Pane %\(paneId)\n\(cols)x\(rows)")
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                }
            }
        )
        .previewDisplayName("Horizontal Split")
        
        // Nested splits
        let nestedTree = TmuxSplitTree(root: .split(.init(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(paneId: 0, cols: 40, rows: 24),
            right: .split(.init(
                direction: .vertical,
                ratio: 0.5,
                left: .leaf(paneId: 1, cols: 40, rows: 12),
                right: .leaf(paneId: 2, cols: 40, rows: 12)
            ))
        )))
        
        TmuxSplitTreeView(
            tree: nestedTree,
            dividerColor: .gray,
            onResize: { _, _ in },
            onEqualize: { },
            onToggleZoom: { paneId in print("Zoom toggled: \(paneId)") },
            paneContent: { paneId, cols, rows in
                ZStack {
                    Color(white: 0.1)
                    Text("Pane %\(paneId)\n\(cols)x\(rows)")
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                }
            }
        )
        .previewDisplayName("Nested Splits")
    }
}
#endif
