//
//  TmuxMultiPaneView.swift
//  Geistty
//
//  SwiftUI view that renders multiple tmux panes using TmuxSplitTreeView.
//  This view observes the TmuxSessionManager and automatically updates
//  when the split tree changes.
//

import SwiftUI
import Combine
import os

private let logger = Logger(subsystem: "com.geistty", category: "TmuxMultiPane")

/// A SwiftUI view that renders multiple tmux panes with proper split layout.
///
/// This view observes the `TmuxSessionManager.currentSplitTree` and renders
/// the split tree using `TmuxSplitTreeView`. Each pane gets its own Ghostty
/// surface from the session manager.
///
/// When the view's geometry changes, it calculates the total cols/rows based
/// on cell size and notifies tmux via `refresh-client -C`. This ensures tmux
/// knows the correct terminal dimensions for proper split layout.
struct TmuxMultiPaneView: View {
    @ObservedObject var sessionManager: TmuxSessionManager
    
    /// Delegate for handling keyboard shortcuts (passed to surfaces)
    weak var shortcutDelegate: Ghostty.ShortcutDelegate?
    
    /// Divider color (matches Ghostty's split divider)
    var dividerColor: Color = Color(white: 0.3)
    
    /// Track last sent dimensions to avoid redundant resize commands
    @State private var lastSentSize: CGSize = .zero
    
    /// Debounce task for divider resize sync
    @State private var resizeSyncTask: Task<Void, Never>?
    
    var body: some View {
        GeometryReader { geometry in
            // The split tree view (panes with SwiftUI dividers for visual only)
            TmuxSplitTreeView(
                tree: sessionManager.currentSplitTree,
                dividerColor: dividerColor,
                onResize: { paneId, newRatio in
                    // Update local tree immediately for smooth drag feedback
                    sessionManager.updateSplitRatio(forPaneId: paneId, ratio: newRatio)
                    
                    // Debounce the sync to tmux to avoid command flooding
                    resizeSyncTask?.cancel()
                    resizeSyncTask = Task {
                        // Wait 150ms for drag to settle before syncing
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        guard !Task.isCancelled else { return }
                        
                        await MainActor.run {
                            sessionManager.syncSplitRatioToTmux(forPaneId: paneId, ratio: newRatio)
                        }
                    }
                },
                onEqualize: {
                    sessionManager.equalizeSplits()
                },
                onToggleZoom: { paneId in
                    sessionManager.toggleZoom(paneId: paneId)
                },
                paneContent: { paneId, cols, rows in
                    // Log dimensions being passed to pane view
                    let _ = logger.info("📐 paneContent called: pane=\(paneId), dims=\(cols)x\(rows)")
                    return TmuxPaneSurfaceView(
                        paneId: paneId,
                        cols: cols,
                        rows: rows,
                        sessionManager: sessionManager,
                        shortcutDelegate: shortcutDelegate
                    )
                    .accessibilityIdentifier("TerminalPane-\(paneId)")
                }
            )
            .accessibilityIdentifier("TmuxMultiPaneContainer")
            .onChange(of: geometry.size) { _, newSize in
                handleSizeChange(newSize)
            }
            .onChange(of: sessionManager.currentSplitTree.paneIds.count) { _, _ in
                // When pane count changes (split/close), re-send dimensions
                // Reset lastSentSize to force a resize command even if geometry didn't change
                logger.info("📐 Pane count changed, forcing resize")
                lastSentSize = .zero  // Force resize to be sent
                handleSizeChange(geometry.size)
            }
            .onChange(of: sessionManager.primaryCellSize) { _, newCellSize in
                // When cell size becomes available (surface initialized), send dimensions
                if newCellSize.width > 0 && newCellSize.height > 0 {
                    logger.info("📐 Cell size now available: \(Int(newCellSize.width))x\(Int(newCellSize.height))")
                    handleSizeChange(geometry.size)
                }
            }
            .onChange(of: sessionManager.isConnected) { _, isConnected in
                // When (re)connected, force a resize to ensure tmux has correct dimensions
                if isConnected {
                    logger.info("📐 Session (re)connected, forcing resize")
                    lastSentSize = .zero  // Force resize to be sent
                    // Delay slightly to ensure tmux is ready to receive commands
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        handleSizeChange(geometry.size)
                    }
                }
            }
            .onAppear {
                // Send initial size when view appears
                logger.info("📐 TmuxMultiPaneView appeared, size: \(Int(geometry.size.width))x\(Int(geometry.size.height))")
                handleSizeChange(geometry.size)
            }
        }
    }
    
    /// Handle geometry size changes by calculating and sending terminal dimensions to tmux
    private func handleSizeChange(_ size: CGSize) {
        // Skip resize during transitions or when session is not fully active
        guard sessionManager.isConnected else {
            logger.debug("📐 Skipping resize - session not connected")
            return
        }
        
        // Ensure we have panes to resize
        guard !sessionManager.currentSplitTree.paneIds.isEmpty else {
            logger.debug("📐 Skipping resize - no panes")
            return
        }
        
        logger.info("📐 handleSizeChange called with size: \(Int(size.width))x\(Int(size.height)), lastSent: \(Int(lastSentSize.width))x\(Int(lastSentSize.height))")
        
        // Avoid redundant resize commands - use tolerance to avoid floating point issues
        let sizeDiff = abs(size.width - lastSentSize.width) + abs(size.height - lastSentSize.height)
        guard sizeDiff > 1.0, size.width > 10, size.height > 10 else {
            logger.debug("📐 Skipping - same size or too small")
            return
        }
        
        // Get cell size from session manager (observed property)
        let cellSize = sessionManager.primaryCellSize
        
        guard cellSize.width > 1, cellSize.height > 1 else {
            logger.debug("📐 Multi-pane size changed but no valid cell size available")
            return
        }
        
        // Calculate cols/rows from pixel size
        // Use floor to ensure we don't claim more space than we have
        let cols = Int(floor(size.width / cellSize.width))
        let rows = Int(floor(size.height / cellSize.height))
        
        // Sanity check dimensions - must be reasonable terminal size
        guard cols >= 10, cols <= 500, rows >= 5, rows <= 200 else {
            logger.warning("📐 Calculated unreasonable dimensions: \(cols)x\(rows), skipping")
            return
        }
        
        logger.info("📐 Multi-pane geometry: \(Int(size.width))x\(Int(size.height))px -> \(cols)x\(rows) cells (cell: \(Int(cellSize.width))x\(Int(cellSize.height)))")
        logger.info("📐 Current split tree before resize: panes=\(sessionManager.currentSplitTree.paneIds), isSplit=\(sessionManager.currentSplitTree.isSplit)")
        
        // Update tracked size
        lastSentSize = size
        
        // Send resize to tmux - this triggers refresh-client -C
        logger.info("📐 🚀 SENDING refresh-client -C \(cols),\(rows)")
        sessionManager.resize(cols: cols, rows: rows)
    }
}

/// A view that wraps a Ghostty surface for a specific tmux pane.
///
/// This view gets the surface from the session manager and wraps it
/// in a UIViewRepresentable for SwiftUI rendering. Tapping the pane
/// selects it and focuses its surface.
///
/// The cols/rows parameters are the tmux-reported character dimensions
/// and can be used to constrain the surface to exact character cell boundaries.
struct TmuxPaneSurfaceView: View {
    let paneId: Int
    let cols: Int
    let rows: Int
    @ObservedObject var sessionManager: TmuxSessionManager
    weak var shortcutDelegate: Ghostty.ShortcutDelegate?
    
    /// Whether this pane is currently focused
    private var isFocused: Bool {
        sessionManager.focusedPaneId == "%\(paneId)"
    }
    
    var body: some View {
        // Get or create the surface for this pane
        if let surface = sessionManager.getSurface(forNumericId: paneId) {
            GhosttyPaneSurfaceWrapper(
                surface: surface,
                cols: cols,
                rows: rows,
                isFocused: isFocused,
                shortcutDelegate: shortcutDelegate,
                onTap: {
                    selectPane()
                }
            )
            // Use ID that includes dimensions to force SwiftUI to recognize dimension changes
            .id("\(paneId)-\(cols)x\(rows)")
            .overlay(
                // Focus indicator border
                RoundedRectangle(cornerRadius: 0)
                    .stroke(isFocused ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 2)
            )
        } else {
            // Surface not available yet - show placeholder
            ZStack {
                Color(white: 0.1)
                VStack {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    Text("Pane %\(paneId)")
                        .foregroundColor(.secondary)
                        .font(.caption)
                        .padding(.top, 4)
                }
            }
            .onTapGesture {
                selectPane()
            }
        }
    }
    
    private func selectPane() {
        logger.info("👆 Pane tapped: %\(self.paneId), current focused: \(self.sessionManager.focusedPaneId)")
        sessionManager.selectPane("%\(paneId)")
    }
}

/// UIViewRepresentable wrapper for a Ghostty.SurfaceView with focus support.
///
/// This wrapper accepts the tmux-reported character dimensions (cols/rows)
/// and constrains the surface to match exactly when cell sizes are available.
struct GhosttyPaneSurfaceWrapper: UIViewRepresentable {
    let surface: Ghostty.SurfaceView
    let cols: Int
    let rows: Int
    let isFocused: Bool
    weak var shortcutDelegate: Ghostty.ShortcutDelegate?
    let onTap: () -> Void
    
    func makeUIView(context: Context) -> GhosttyPaneSurfaceContainerView {
        logger.info("📐 GhosttyPaneSurfaceWrapper makeUIView: cols=\(cols), rows=\(rows)")
        let container = GhosttyPaneSurfaceContainerView()
        container.surface = surface
        container.targetCols = cols
        container.targetRows = rows
        container.onTap = onTap
        // Set shortcut delegate for keyboard shortcuts
        surface.shortcutDelegate = shortcutDelegate
        return container
    }
    
    func updateUIView(_ container: GhosttyPaneSurfaceContainerView, context: Context) {
        // Log dimension updates for debugging
        if container.targetCols != cols || container.targetRows != rows {
            logger.info("📐 GhosttyPaneSurfaceWrapper updating pane dimensions: \(container.targetCols)x\(container.targetRows) -> \(cols)x\(rows)")
        }
        
        // Update target dimensions if changed
        container.targetCols = cols
        container.targetRows = rows
        
        // Ensure shortcut delegate is set (may change between updates)
        surface.shortcutDelegate = shortcutDelegate
        
        // Update focus state
        if isFocused && !surface.isFirstResponder {
            surface.focusDidChange(true)
            _ = surface.becomeFirstResponder()
        } else if !isFocused && surface.isFirstResponder {
            surface.focusDidChange(false)
            _ = surface.resignFirstResponder()
        }
    }
}

/// Container view for a Ghostty surface that handles tap gestures and size constraints.
///
/// This container can constrain the Ghostty surface to exact character cell boundaries
/// using the targetCols/targetRows properties. It directly tells Ghostty what grid size
/// to use via setExactGridSize().
class GhosttyPaneSurfaceContainerView: UIView {
    /// Target columns (character width) from tmux layout
    var targetCols: Int = 0 {
        didSet {
            if targetCols != oldValue {
                lastAppliedCols = 0  // Force re-apply on next layout
                setNeedsLayout()
            }
        }
    }
    
    /// Target rows (character height) from tmux layout
    var targetRows: Int = 0 {
        didSet {
            if targetRows != oldValue {
                lastAppliedRows = 0  // Force re-apply on next layout
                setNeedsLayout()
            }
        }
    }
    
    /// Track last successfully applied grid size to avoid redundant updates
    private var lastAppliedCols: Int = 0
    private var lastAppliedRows: Int = 0
    
    /// Retry counter to prevent infinite layout loops
    private var gridSizeRetryCount: Int = 0
    private let maxGridSizeRetries: Int = 5
    
    /// Delayed retry task for grid size application
    private var gridSizeRetryTask: DispatchWorkItem?
    
    var surface: Ghostty.SurfaceView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let surface = surface {
                // Remove from any previous superview and ensure it's visible
                surface.removeFromSuperview()
                surface.isHidden = false
                
                // Fill the container - exact size is handled by setExactGridSize
                surface.translatesAutoresizingMaskIntoConstraints = false
                addSubview(surface)
                NSLayoutConstraint.activate([
                    surface.topAnchor.constraint(equalTo: topAnchor),
                    surface.bottomAnchor.constraint(equalTo: bottomAnchor),
                    surface.leadingAnchor.constraint(equalTo: leadingAnchor),
                    surface.trailingAnchor.constraint(equalTo: trailingAnchor)
                ])
                
                // Reset tracking for new surface
                lastAppliedCols = 0
                lastAppliedRows = 0
                gridSizeRetryCount = 0
                
                // Force layout to establish bounds before setting grid size
                setNeedsLayout()
                layoutIfNeeded()
                
                // Set the grid size after the surface is added and laid out
                updateGridSize()
            }
        }
    }
    
    var onTap: (() -> Void)?
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        clipsToBounds = true
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        // Re-evaluate grid size when bounds change
        updateGridSize()
    }
    
    /// Update the Ghostty surface to use the exact grid size from tmux.
    private func updateGridSize() {
        guard let surface = surface,
              targetCols > 0,
              targetRows > 0,
              bounds.width > 10,  // Ensure we have valid container bounds
              bounds.height > 10 else {
            logger.debug("📐 updateGridSize skipped: surface=\(surface != nil), cols=\(targetCols), rows=\(targetRows), bounds=\(bounds)")
            return
        }
        
        // Skip if we've already applied these dimensions
        if targetCols == lastAppliedCols && targetRows == lastAppliedRows {
            logger.debug("📐 updateGridSize skipped: already applied \(targetCols)x\(targetRows)")
            return
        }
        
        logger.info("📐 GhosttyPaneSurfaceContainerView applying grid size: \(targetCols)x\(targetRows) (was: \(lastAppliedCols)x\(lastAppliedRows)), bounds=\(bounds)")
        
        // Tell Ghostty to use the exact grid size
        let success = surface.setExactGridSize(cols: targetCols, rows: targetRows)
        if success {
            lastAppliedCols = targetCols
            lastAppliedRows = targetRows
            gridSizeRetryCount = 0  // Reset retry counter on success
            gridSizeRetryTask?.cancel()
            gridSizeRetryTask = nil
            logger.info("📐 ✅ Grid size applied successfully: \(targetCols)x\(targetRows)")
        } else {
            // Cell size not available yet - retry with exponential backoff
            gridSizeRetryCount += 1
            logger.info("📐 ⏳ Grid size application failed (attempt \(gridSizeRetryCount)/\(maxGridSizeRetries))")
            
            if gridSizeRetryCount <= maxGridSizeRetries {
                // Cancel any pending retry
                gridSizeRetryTask?.cancel()
                
                // Exponential backoff: 50ms, 100ms, 200ms, 400ms, 800ms
                let delayMs = 50 * (1 << (gridSizeRetryCount - 1))
                let workItem = DispatchWorkItem { [weak self] in
                    self?.setNeedsLayout()
                }
                gridSizeRetryTask = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: workItem)
            } else {
                logger.warning("📐 ⚠️ Grid size application exhausted retries, giving up")
            }
        }
    }
    
    // Override hitTest to trigger focus change whenever this pane is touched
    // This fires before the touch is delivered, so we can update focus immediately
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hitView = super.hitTest(point, with: event)
        
        // If the touch is within our bounds, trigger focus change
        if hitView != nil {
            // Use async to avoid re-entrancy issues during hit testing
            DispatchQueue.main.async { [weak self] in
                self?.onTap?()
            }
        }
        
        return hitView
    }
}

// MARK: - UIKit Integration

/// A UIView container that hosts the TmuxMultiPaneView via UIHostingController.
///
/// This allows embedding the SwiftUI split view into UIKit view hierarchies.
/// Also adds a UIKit overlay for divider drag handling.
class TmuxMultiPaneContainerView: UIView {
    private var hostingController: UIHostingController<TmuxMultiPaneView>?
    private weak var parentViewController: UIViewController?
    private var sessionManager: TmuxSessionManager?
    private var splitTreeObserver: AnyCancellable?
    
    /// UIKit overlay for divider dragging - added ON TOP of the SwiftUI hosting view
    private var dividerOverlay: DividerOverlayView?
    
    /// Configure the container with a session manager and parent view controller.
    func configure(sessionManager: TmuxSessionManager, parentViewController: UIViewController) {
        self.sessionManager = sessionManager
        self.parentViewController = parentViewController
        
        // Create the hosting controller
        let multiPaneView = TmuxMultiPaneView(sessionManager: sessionManager)
        let hosting = UIHostingController(rootView: multiPaneView)
        self.hostingController = hosting
        
        // Add as child view controller
        parentViewController.addChild(hosting)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting.view)
        
        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: bottomAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        
        hosting.didMove(toParent: parentViewController)
        
        // Set transparent background
        hosting.view.backgroundColor = .clear
        backgroundColor = .clear
        
        // Add divider overlay ON TOP of the SwiftUI view
        let overlay = DividerOverlayView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.onDragEnded = { [weak sessionManager] paneId, ratio in
            sessionManager?.updateSplitRatioAndSync(forPaneId: paneId, ratio: ratio)
        }
        addSubview(overlay)
        self.dividerOverlay = overlay
        
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        
        // Observe split tree changes to update divider positions
        splitTreeObserver = sessionManager.$currentSplitTree
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tree in
                guard let self = self else { return }
                self.dividerOverlay?.updateDividers(from: tree, containerSize: self.bounds.size)
            }
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        // Update divider positions when bounds change
        if let tree = sessionManager?.currentSplitTree {
            dividerOverlay?.updateDividers(from: tree, containerSize: bounds.size)
        }
    }
    
    /// Clean up when the view is removed
    func cleanup() {
        splitTreeObserver?.cancel()
        splitTreeObserver = nil
        
        dividerOverlay?.removeFromSuperview()
        dividerOverlay = nil
        
        hostingController?.willMove(toParent: nil)
        hostingController?.view.removeFromSuperview()
        hostingController?.removeFromParent()
        hostingController = nil
    }
    
    deinit {
        cleanup()
    }
}

// MARK: - DividerOverlayView

/// UIKit view that manages divider hit areas and pan gestures.
/// This view sits on top of the SwiftUI split view and uses UIPanGestureRecognizer
/// to handle divider drags, which works reliably with UIKit views underneath.
class DividerOverlayView: UIView {
    /// Callback during drag - updates ratio for live visual feedback (no tmux sync)
    var onDragChanged: ((Int, Double) -> Void)?
    
    /// Callback when a divider drag ends - commits the new ratio to tmux
    var onDragEnded: ((Int, Double) -> Void)?
    
    /// Current divider views
    private var dividerViews: [DividerHitAreaView] = []
    
    /// Visual indicator layer that shows during drag
    private let dragIndicatorLayer = CALayer()
    
    /// Divider hit area size (invisible touch target)
    private let hitAreaSize: CGFloat = 30
    
    /// Visible drag indicator thickness
    private let indicatorThickness: CGFloat = 4
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = true
        setupDragIndicator()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isUserInteractionEnabled = true
        setupDragIndicator()
    }
    
    private func setupDragIndicator() {
        dragIndicatorLayer.backgroundColor = UIColor.systemBlue.cgColor
        dragIndicatorLayer.cornerRadius = indicatorThickness / 2
        dragIndicatorLayer.isHidden = true
        layer.addSublayer(dragIndicatorLayer)
    }
    
    /// Update dividers based on the split tree
    func updateDividers(from tree: TmuxSplitTree, containerSize: CGSize) {
        // Remove old dividers
        dividerViews.forEach { $0.removeFromSuperview() }
        dividerViews.removeAll()
        
        // Create new dividers from tree
        if let root = tree.root {
            createDividers(from: root, in: CGRect(origin: .zero, size: containerSize))
        }
    }
    
    /// Recursively create divider views from the split tree
    private func createDividers(from node: TmuxSplitTree.Node, in rect: CGRect) {
        guard case .split(let split) = node else { return }
        
        let ratio = CGFloat(split.ratio)
        let paneId = split.left.leftmostPaneId
        let dividerView = DividerHitAreaView()
        dividerView.paneId = paneId
        dividerView.direction = split.direction == .horizontal ? .horizontal : .vertical
        dividerView.hitAreaSize = hitAreaSize
        dividerView.containerRect = rect
        
        // During drag: update visual ratio and show indicator
        dividerView.onDragChanged = { [weak self] newRatio in
            self?.onDragChanged?(paneId, Double(newRatio))
        }
        
        // Show/hide the visual drag indicator
        dividerView.onDragBegan = { [weak self] frame, direction in
            self?.showDragIndicator(at: frame, direction: direction)
        }
        dividerView.onDragMoved = { [weak self] frame, direction in
            self?.updateDragIndicator(at: frame, direction: direction)
        }
        dividerView.onDragFinished = { [weak self] in
            self?.hideDragIndicator()
        }
        
        // On drag end: commit to session manager for tmux sync
        dividerView.onDragEnded = { [weak self] newRatio in
            self?.onDragEnded?(paneId, Double(newRatio))
        }
        
        // Position divider based on direction and ratio
        switch split.direction {
        case .horizontal:
            let dividerX = rect.origin.x + rect.width * ratio
            dividerView.frame = CGRect(
                x: dividerX - hitAreaSize / 2,
                y: rect.origin.y,
                width: hitAreaSize,
                height: rect.height
            )
            
            // Recurse into children
            let leftRect = CGRect(x: rect.origin.x, y: rect.origin.y,
                                  width: rect.width * ratio, height: rect.height)
            let rightRect = CGRect(x: dividerX, y: rect.origin.y,
                                   width: rect.width * (1 - ratio), height: rect.height)
            createDividers(from: split.left, in: leftRect)
            createDividers(from: split.right, in: rightRect)
            
        case .vertical:
            let dividerY = rect.origin.y + rect.height * ratio
            dividerView.frame = CGRect(
                x: rect.origin.x,
                y: dividerY - hitAreaSize / 2,
                width: rect.width,
                height: hitAreaSize
            )
            
            // Recurse into children
            let topRect = CGRect(x: rect.origin.x, y: rect.origin.y,
                                 width: rect.width, height: rect.height * ratio)
            let bottomRect = CGRect(x: rect.origin.x, y: dividerY,
                                    width: rect.width, height: rect.height * (1 - ratio))
            createDividers(from: split.left, in: topRect)
            createDividers(from: split.right, in: bottomRect)
        }
        
        addSubview(dividerView)
        dividerViews.append(dividerView)
    }
    
    // MARK: - Drag Indicator
    
    private func showDragIndicator(at frame: CGRect, direction: SplitViewDirection) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateDragIndicator(at: frame, direction: direction)
        dragIndicatorLayer.isHidden = false
        CATransaction.commit()
    }
    
    private func updateDragIndicator(at frame: CGRect, direction: SplitViewDirection) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        switch direction {
        case .horizontal:
            // Vertical line for horizontal split
            dragIndicatorLayer.frame = CGRect(
                x: frame.midX - indicatorThickness / 2,
                y: frame.origin.y,
                width: indicatorThickness,
                height: frame.height
            )
        case .vertical:
            // Horizontal line for vertical split
            dragIndicatorLayer.frame = CGRect(
                x: frame.origin.x,
                y: frame.midY - indicatorThickness / 2,
                width: frame.width,
                height: indicatorThickness
            )
        }
        
        CATransaction.commit()
    }
    
    private func hideDragIndicator() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dragIndicatorLayer.isHidden = true
        CATransaction.commit()
    }
    
    /// Only respond to touches on divider areas - pass through everything else
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for divider in dividerViews {
            if divider.frame.contains(point) {
                return divider
            }
        }
        // Return nil to pass through touches to views below
        return nil
    }
}

/// A single divider hit area with pan gesture support
class DividerHitAreaView: UIView {
    var paneId: Int = 0
    var direction: SplitViewDirection = .horizontal
    var hitAreaSize: CGFloat = 30
    var containerRect: CGRect = .zero
    
    /// Called when drag begins (to show indicator)
    var onDragBegan: ((CGRect, SplitViewDirection) -> Void)?
    
    /// Called during drag movement (to update indicator position)
    var onDragMoved: ((CGRect, SplitViewDirection) -> Void)?
    
    /// Called during drag with the new ratio (for live visual feedback)
    var onDragChanged: ((CGFloat) -> Void)?
    
    /// Called when drag ends with the final ratio (to commit to tmux)
    var onDragEnded: ((CGFloat) -> Void)?
    
    /// Called when drag finishes (to hide indicator)
    var onDragFinished: (() -> Void)?
    
    private var panGesture: UIPanGestureRecognizer!
    private var initialCenter: CGPoint = .zero
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupGesture()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupGesture()
    }
    
    private func setupGesture() {
        // Invisible hit area (was red for debugging)
        backgroundColor = .clear
        
        panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(panGesture)
    }
    
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let minRatio: CGFloat = 0.1
        let maxRatio: CGFloat = 0.9
        
        switch gesture.state {
        case .began:
            initialCenter = center
            // Notify that drag started
            onDragBegan?(frame, direction)
            
        case .changed:
            // Move the divider view directly for fluid feedback
            let translation = gesture.translation(in: superview)
            var newRatio: CGFloat = 0.5
            
            switch direction {
            case .horizontal:
                let newX = initialCenter.x + translation.x
                let minX = containerRect.origin.x + containerRect.width * minRatio
                let maxX = containerRect.origin.x + containerRect.width * maxRatio
                let clampedX = min(max(minX, newX), maxX)
                center.x = clampedX
                
                // Calculate ratio for live preview
                let relativeX = clampedX - containerRect.origin.x
                newRatio = relativeX / containerRect.width
                
            case .vertical:
                let newY = initialCenter.y + translation.y
                let minY = containerRect.origin.y + containerRect.height * minRatio
                let maxY = containerRect.origin.y + containerRect.height * maxRatio
                let clampedY = min(max(minY, newY), maxY)
                center.y = clampedY
                
                // Calculate ratio for live preview
                let relativeY = clampedY - containerRect.origin.y
                newRatio = relativeY / containerRect.height
            }
            
            // Update visual indicator position
            onDragMoved?(frame, direction)
            
            // Update the split tree for live visual resize
            onDragChanged?(newRatio)
            
        case .ended, .cancelled:
            // Calculate final ratio and commit
            let location = gesture.location(in: superview)
            var newRatio: CGFloat
            
            switch direction {
            case .horizontal:
                let relativeX = location.x - containerRect.origin.x
                newRatio = relativeX / containerRect.width
            case .vertical:
                let relativeY = location.y - containerRect.origin.y
                newRatio = relativeY / containerRect.height
            }
            
            newRatio = min(max(minRatio, newRatio), maxRatio)
            
            // Hide drag indicator
            onDragFinished?()
            
            // Commit to tmux
            onDragEnded?(newRatio)
            
        default:
            break
        }
    }
}

// MARK: - Preview

#if DEBUG
struct TmuxMultiPaneView_Previews: PreviewProvider {
    static var previews: some View {
        // Preview with mock session manager would go here
        Text("TmuxMultiPaneView Preview")
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
    }
}
#endif
