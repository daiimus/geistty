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
    
    /// Track last sent cols/rows to deduplicate at the character grid level.
    /// Pixel-level dedup (lastSentSize) can miss cases where floating-point
    /// geometry changes produce the same cols/rows. This prevents sending
    /// redundant "refresh-client -C" commands that differ only in sub-cell pixels.
    @State private var lastSentCols: Int = 0
    @State private var lastSentRows: Int = 0
    
    /// Debounce task for divider resize sync
    @State private var resizeSyncTask: Task<Void, Never>?
    
    var body: some View {
        GeometryReader { geometry in
            // The split tree view (panes with SwiftUI dividers for visual only).
            // Disable the SwiftUI DragGesture on dividers — the UIKit
            // DividerOverlayView handles all drag interaction. (#45)
            TmuxSplitTreeView(
                tree: sessionManager.currentSplitTree,
                dividerColor: dividerColor,
                cellSize: sessionManager.primaryCellSize,
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
                    TmuxPaneSurfaceView(
                        paneId: paneId,
                        cols: cols,
                        rows: rows,
                        sessionManager: sessionManager,
                        shortcutDelegate: shortcutDelegate,
                        onToggleZoom: { sessionManager.toggleZoom(paneId: paneId) }
                    )
                    .accessibilityIdentifier("TerminalPane-\(paneId)")
                }
            )
            .environment(\.dividerDragEnabled, false)
            .accessibilityIdentifier("TmuxMultiPaneContainer")
            .onChange(of: geometry.size) { _, newSize in
                handleSizeChange(newSize)
            }
            .onChange(of: sessionManager.currentSplitTree.paneIds.count) { _, _ in
                // When pane count changes (split/close), re-send dimensions
                // Reset lastSent to force a resize command even if geometry didn't change
                logger.info("📐 Pane count changed, forcing resize")
                lastSentSize = .zero  // Force resize to be sent
                lastSentCols = 0
                lastSentRows = 0
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
                    lastSentCols = 0
                    lastSentRows = 0
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
            .onDisappear {
                resizeSyncTask?.cancel()
                resizeSyncTask = nil
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
        
        logger.debug("📐 handleSizeChange called with size: \(Int(size.width))x\(Int(size.height)), lastSent: \(Int(lastSentSize.width))x\(Int(lastSentSize.height))")
        
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
        
        // Character-grid-level dedup: skip if the calculated cols/rows are identical
        // to what we last sent. This prevents redundant "refresh-client -C" when
        // floating-point pixel geometry changes but the character grid is the same.
        guard cols != lastSentCols || rows != lastSentRows else {
            logger.debug("📐 Skipping - same grid dimensions \(cols)x\(rows)")
            return
        }
        
        logger.debug("📐 Multi-pane geometry: \(Int(size.width))x\(Int(size.height))px -> \(cols)x\(rows) cells (cell: \(Int(cellSize.width))x\(Int(cellSize.height)))")
        logger.debug("📐 Current split tree before resize: panes=\(sessionManager.currentSplitTree.paneIds), isSplit=\(sessionManager.currentSplitTree.isSplit))")
        
        // Update tracked size at both pixel and grid levels
        lastSentSize = size
        lastSentCols = cols
        lastSentRows = rows
        
        // Send resize to tmux - this triggers refresh-client -C
        logger.debug("📐 SENDING refresh-client -C \(cols),\(rows)")
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
    /// Called when the pane is double-tapped (toggle zoom).
    /// Moved from SwiftUI ZoomablePane to UIKit container (Fix I, session 95).
    var onToggleZoom: (() -> Void)?
    
    /// Whether this pane is currently focused
    private var isFocused: Bool {
        sessionManager.focusedPaneId == "%\(paneId)"
    }
    
    /// Whether this surface is the primary (owns the tmux viewer).
    /// The primary surface must NOT have setExactGridSize() called on it
    /// because that flows through ghostty_surface_set_size → Zig Termio.resize()
    /// → "refresh-client -C" with the PANE's dimensions, conflicting with the
    /// correct container-wide resize from TmuxMultiPaneView.handleSizeChange().
    private var isPrimarySurface: Bool {
        guard let surface = sessionManager.getSurface(forNumericId: paneId) else { return false }
        return surface === sessionManager.primarySurface
    }
    
    /// Whether the connection is lost
    private var isConnectionLost: Bool {
        if case .connectionLost = sessionManager.connectionState { return true }
        return false
    }
    
    /// Disconnect reason if available
    private var disconnectReason: String? {
        if case .connectionLost(let reason) = sessionManager.connectionState { return reason }
        return nil
    }
    
    var body: some View {
        // Get or create the surface for this pane
        if let surface = sessionManager.getSurface(forNumericId: paneId) {
            GhosttyPaneSurfaceWrapper(
                surface: surface,
                cols: cols,
                rows: rows,
                isFocused: isFocused,
                isPrimarySurface: isPrimarySurface,
                shortcutDelegate: shortcutDelegate,
                onTap: {
                    selectPane()
                },
                onDoubleTap: onToggleZoom
            )
            // Stable identity per pane — dimension changes are handled by updateUIView.
            // IMPORTANT: Do NOT include cols/rows in .id(). That causes SwiftUI to
            // destroy + recreate the UIViewRepresentable on every layout change,
            // re-parenting the surface, which fires didMoveToWindow → sizeDidChange
            // → ghostty_surface_set_size → Zig Termio.resize → "refresh-client -C"
            // with pane dimensions, creating a resize oscillation loop.
            .id("\(paneId)")
            .overlay(
                // Focus indicator border
                Rectangle()
                    .stroke(isFocused ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 2)
            )
            .overlay(
                // Connection lost overlay - subtle, non-blocking
                DisconnectedPaneOverlay(
                    isVisible: isConnectionLost,
                    reason: disconnectReason
                )
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
///
/// **Input routing in multi-pane mode:**
/// Only the primary surface (which owns the tmux viewer) should be firstResponder.
/// All keyboard input must flow through the primary's Zig `Termio.queueWrite()`,
/// which wraps keystrokes in `send-keys -H -t %N` for the active pane.
/// Observer surfaces bypass this wrapping — their `Termio` has no tmux viewer,
/// so raw bytes would be sent to the SSH channel as tmux commands (broken).
///
/// When an observer pane is tapped, we call `selectPane()` (which sets the
/// active pane on the primary via `setActiveTmuxPane`), then ensure the
/// primary surface keeps/regains firstResponder.
struct GhosttyPaneSurfaceWrapper: UIViewRepresentable {
    let surface: Ghostty.SurfaceView
    let cols: Int
    let rows: Int
    let isFocused: Bool
    /// When true, this surface owns the tmux viewer and must NOT have
    /// setExactGridSize() called — that would trigger Zig-side
    /// "refresh-client -C" with pane dimensions, causing a resize storm.
    let isPrimarySurface: Bool
    weak var shortcutDelegate: Ghostty.ShortcutDelegate?
    let onTap: () -> Void
    /// Called when the pane is double-tapped (toggle zoom).
    /// Moved from SwiftUI ZoomablePane to UIKit container (Fix I, session 95).
    var onDoubleTap: (() -> Void)?
    
    func makeUIView(context: Context) -> GhosttyPaneSurfaceContainerView {
        logger.info("📐 GhosttyPaneSurfaceWrapper makeUIView: cols=\(cols), rows=\(rows), isPrimary=\(isPrimarySurface)")
        let container = GhosttyPaneSurfaceContainerView()
        container.skipGridSizeUpdate = isPrimarySurface
        container.surface = surface
        container.targetCols = cols
        container.targetRows = rows
        container.onDoubleTap = onDoubleTap
        // Wire the surface's onPaneTap so observer taps trigger pane selection.
        // The SurfaceView's handleTap() checks isMultiPaneObserver and calls
        // this callback instead of becoming firstResponder.
        surface.onPaneTap = onTap
        // Set shortcut delegate for keyboard shortcuts
        surface.shortcutDelegate = shortcutDelegate
        return container
    }
    
    func updateUIView(_ container: GhosttyPaneSurfaceContainerView, context: Context) {
        // Log dimension updates for debugging
        if container.targetCols != cols || container.targetRows != rows {
            logger.info("📐 GhosttyPaneSurfaceWrapper updating pane dimensions: \(container.targetCols)x\(container.targetRows) -> \(cols)x\(rows)")
        }
        
        // Update primary surface flag (can change if primary is reassigned)
        container.skipGridSizeUpdate = isPrimarySurface
        
        // Update target dimensions if changed
        container.targetCols = cols
        container.targetRows = rows
        
        // Ensure shortcut delegate is set (may change between updates)
        surface.shortcutDelegate = shortcutDelegate
        
        // Keep double-tap callback in sync
        container.onDoubleTap = onDoubleTap
        
        // Ensure the primary surface has keyboard focus. Observers have
        // canBecomeFirstResponder=false, so they can never steal it.
        if isFocused && !surface.isFirstResponder {
            _ = surface.becomeFirstResponder()
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
    
    /// When true, skip calling setExactGridSize() on the surface.
    ///
    /// This is set for the PRIMARY surface in multi-pane tmux mode.
    /// The primary surface's Zig Termio owns the tmux viewer, so calling
    /// ghostty_surface_set_size() (via setExactGridSize) triggers
    /// Termio.resize() → "refresh-client -C {pane_cols}x{pane_rows}",
    /// sending PANE dimensions to tmux. This conflicts with the correct
    /// CONTAINER-wide "refresh-client -C" from TmuxMultiPaneView.handleSizeChange(),
    /// creating a resize storm that interleaves %layout-change with capture-pane
    /// and ultimately triggers a Zig PANIC.
    ///
    /// Instead, the primary surface gets usesExactGridSize=true (suppresses
    /// layoutSubviews auto-resize) and relies on updateSublayerFrames() to
    /// match its Metal layer to the SwiftUI frame. The renderer reads from
    /// the viewer's per-pane Terminal (via tmux_pane_binding), not the
    /// surface's own terminal grid, so the grid size mismatch is harmless.
    ///
    /// Observer surfaces (non-primary) don't have this problem because their
    /// Termio has no tmux_viewer — Termio.resize() skips "refresh-client -C".
    var skipGridSizeUpdate: Bool = false
    
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
                
                // For the primary surface, suppress layoutSubviews auto-resize
                // immediately. This prevents sizeDidChange → ghostty_surface_set_size
                // → Zig Termio.resize → "refresh-client -C" with pane dimensions.
                if skipGridSizeUpdate {
                    surface.usesExactGridSize = true
                }
                
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
    
    /// Called when the pane is double-tapped (toggle zoom).
    /// Moved from SwiftUI ZoomablePane to UIKit container (Fix I, session 95).
    var onDoubleTap: (() -> Void)?
    
    /// Double-tap gesture recognizer for pane zoom toggle (Fix I, session 95).
    /// Previously this was a SwiftUI `.onTapGesture(count: 2)` on ZoomablePane,
    /// but that installed a gesture at the SwiftUI hosting level which intercepted
    /// ALL touches via `.contentShape(Rectangle())`, preventing the UIKit SurfaceView's
    /// gesture recognizers from ever firing.
    private lazy var doubleTapGesture: UITapGestureRecognizer = {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        gesture.numberOfTapsRequired = 2
        gesture.cancelsTouchesInView = false
        return gesture
    }()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        addGestureRecognizer(doubleTapGesture)
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        clipsToBounds = true
        addGestureRecognizer(doubleTapGesture)
    }
    
    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if gesture.state == .ended {
            if let onDoubleTap = onDoubleTap {
                logger.info("[ContainerView.handleDoubleTap] container double-tap recognized, toggling zoom")
                onDoubleTap()
            }
        }
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
        
        // For the primary surface, DON'T call setExactGridSize().
        // setExactGridSize → ghostty_surface_set_size → Zig Termio.resize()
        // → "refresh-client -C {pane_cols}x{pane_rows}" — this sends PANE
        // dimensions to tmux, conflicting with the correct container-wide
        // "refresh-client -C" from TmuxMultiPaneView.handleSizeChange().
        //
        // The primary surface already has usesExactGridSize=true (set in the
        // surface didSet above), which suppresses layoutSubviews auto-resize.
        // Its Metal layer frame is managed by updateSublayerFrames(). The
        // renderer reads from the viewer's per-pane Terminal (via
        // tmux_pane_binding), so the surface's own grid size is irrelevant.
        if skipGridSizeUpdate {
            // Still mark as "applied" to avoid redundant log spam
            if targetCols != lastAppliedCols || targetRows != lastAppliedRows {
                logger.debug("📐 updateGridSize: SKIPPING setExactGridSize for primary surface (\(targetCols)x\(targetRows)) — resize storm prevention")
                lastAppliedCols = targetCols
                lastAppliedRows = targetRows
            }
            return
        }
        
        // Skip if we've already applied these dimensions
        if targetCols == lastAppliedCols && targetRows == lastAppliedRows {
            logger.debug("📐 updateGridSize skipped: already applied \(targetCols)x\(targetRows)")
            return
        }
        
        logger.debug("📐 GhosttyPaneSurfaceContainerView applying grid size: \(targetCols)x\(targetRows) (was: \(lastAppliedCols)x\(lastAppliedRows)), bounds=\(bounds)")
        
        // Tell Ghostty to use the exact grid size
        let success = surface.setExactGridSize(cols: targetCols, rows: targetRows)
        if success {
            lastAppliedCols = targetCols
            lastAppliedRows = targetRows
            gridSizeRetryCount = 0  // Reset retry counter on success
            gridSizeRetryTask?.cancel()
            gridSizeRetryTask = nil
            logger.debug("📐 Grid size applied successfully: \(targetCols)x\(targetRows)")
        } else {
            // Cell size not available yet - retry with exponential backoff
            gridSizeRetryCount += 1
            logger.debug("📐 Grid size application failed (attempt \(gridSizeRetryCount)/\(maxGridSizeRetries))")
            
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
    
    // hitTest is no longer overridden for focus change (H11 fix).
    // The UITapGestureRecognizer above handles focus changes correctly
    // without triggering on scroll/pan gestures.
}

// MARK: - UIKit Integration

/// A UIView container that hosts the TmuxMultiPaneView via UIHostingController.
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
    
    /// Cell size from the primary Ghostty surface.
    /// Reserved for potential future use (e.g., snapping divider drag to cell boundaries).
    /// Divider visual width is now a constant 2pt (matching TmuxSplitNodeView and focus border).
    var cellSize: CGSize = .zero
    
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
        dividerView.updateAccessibilityLabel()
        
        // Thin visual divider (2pt) — matches TmuxSplitNodeView and focus border.
        // tmux's 1-character-cell divider is accounted for in the split *ratio*,
        // so child rect calculations use this thin value for visual positioning only.
        let dividerWidth: CGFloat = 2
        
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
        
        // Position divider based on direction and ratio.
        // The divider center sits at ratio * containerSize, matching TmuxSplitView's layout.
        switch split.direction {
        case .horizontal:
            let dividerX = rect.origin.x + rect.width * ratio
            dividerView.frame = CGRect(
                x: dividerX - hitAreaSize / 2,
                y: rect.origin.y,
                width: hitAreaSize,
                height: rect.height
            )
            
            // Recurse into children — account for divider width
            let leftWidth = rect.width * ratio - dividerWidth / 2
            let rightWidth = rect.width * (1 - ratio) - dividerWidth / 2
            let leftRect = CGRect(x: rect.origin.x, y: rect.origin.y,
                                  width: max(0, leftWidth), height: rect.height)
            let rightRect = CGRect(x: dividerX + dividerWidth / 2, y: rect.origin.y,
                                   width: max(0, rightWidth), height: rect.height)
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
            
            // Recurse into children — account for divider height
            let topHeight = rect.height * ratio - dividerWidth / 2
            let bottomHeight = rect.height * (1 - ratio) - dividerWidth / 2
            let topRect = CGRect(x: rect.origin.x, y: rect.origin.y,
                                 width: rect.width, height: max(0, topHeight))
            let bottomRect = CGRect(x: rect.origin.x, y: dividerY + dividerWidth / 2,
                                    width: rect.width, height: max(0, bottomHeight))
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
        
        // Accessibility: make dividers discoverable by VoiceOver
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        accessibilityHint = "Swipe up or down to resize panes"
    }
    
    /// Update the accessibility label when paneId or direction changes.
    func updateAccessibilityLabel() {
        let directionText = direction == .horizontal ? "vertical" : "horizontal"
        accessibilityLabel = "Pane \(paneId) \(directionText) divider"
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

// MARK: - Disconnected Pane Overlay

/// Overlay shown on panes when connection is lost
/// Non-blocking - user can still scroll and copy text
struct DisconnectedPaneOverlay: View {
    let isVisible: Bool
    let reason: String?
    
    var body: some View {
        if isVisible {
            VStack {
                // Top banner with disconnect indicator
                HStack(spacing: 8) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 12, weight: .semibold))
                    
                    Text("Disconnected")
                        .font(.system(size: 12, weight: .medium))
                    
                    if let reason = reason {
                        Text("• \(reason)")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    
                    Spacer()
                    
                    // Keyboard shortcut hint
                    Text("⌘R to reconnect")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Color.orange.opacity(0.85)
                        .blur(radius: 0.5)
                )
                .foregroundColor(.white)
                
                Spacer()
            }
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.3), value: isVisible)
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
