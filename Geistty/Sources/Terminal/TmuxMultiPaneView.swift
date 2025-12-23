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
    
    var body: some View {
        GeometryReader { geometry in
            TmuxSplitTreeView(
                tree: sessionManager.currentSplitTree,
                dividerColor: dividerColor,
                onResize: { paneId, newRatio in
                    // For now, don't send resize to tmux - local UI only
                    // TODO: Implement tmux resize-pane when needed
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
                logger.info("📐 Pane count changed, triggering resize")
                handleSizeChange(geometry.size)
            }
            .onChange(of: sessionManager.primaryCellSize) { _, newCellSize in
                // When cell size becomes available (surface initialized), send dimensions
                if newCellSize.width > 0 && newCellSize.height > 0 {
                    logger.info("📐 Cell size now available: \(Int(newCellSize.width))x\(Int(newCellSize.height))")
                    handleSizeChange(geometry.size)
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
    private let maxGridSizeRetries: Int = 3
    
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
                
                // Set the grid size after the surface is added
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
              targetRows > 0 else {
            return
        }
        
        // Skip if we've already applied these dimensions
        if targetCols == lastAppliedCols && targetRows == lastAppliedRows {
            return
        }
        
        // Tell Ghostty to use the exact grid size
        let success = surface.setExactGridSize(cols: targetCols, rows: targetRows)
        if success {
            lastAppliedCols = targetCols
            lastAppliedRows = targetRows
            gridSizeRetryCount = 0  // Reset retry counter on success
        } else {
            // Cell size not available yet - retry with limited attempts
            gridSizeRetryCount += 1
            if gridSizeRetryCount <= maxGridSizeRetries {
                DispatchQueue.main.async { [weak self] in
                    self?.setNeedsLayout()
                }
            }
            // After max retries, give up - cell size will be set when surface is ready
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
class TmuxMultiPaneContainerView: UIView {
    private var hostingController: UIHostingController<TmuxMultiPaneView>?
    private weak var parentViewController: UIViewController?
    private var sessionManager: TmuxSessionManager?
    private var splitTreeObserver: AnyCancellable?
    
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
    }
    
    /// Clean up when the view is removed
    func cleanup() {
        splitTreeObserver?.cancel()
        splitTreeObserver = nil
        
        hostingController?.willMove(toParent: nil)
        hostingController?.view.removeFromSuperview()
        hostingController?.removeFromParent()
        hostingController = nil
    }
    
    deinit {
        cleanup()
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
