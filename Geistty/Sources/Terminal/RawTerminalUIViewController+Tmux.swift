//
//  RawTerminalUIViewController+Tmux.swift
//  Geistty
//
//  tmux multi-pane management, surface factory, split tree observation,
//  and mode transitions for the terminal view controller.
//

import UIKit
import SwiftUI
import Combine
import GhosttyKit
import os.log

private let logger = Logger(subsystem: "com.geistty", category: "Terminal")

// MARK: - tmux Multi-Pane Support

extension RawTerminalUIViewController {
    
    /// Configure surface management for TmuxSessionManager
    /// This provides the factory and handlers for creating surfaces
    func configureSurfaceManagement() {
        guard let ghosttyApp = ghosttyApp,
              let _ = ghosttyApp.app,
              let tmuxManager = viewModel?.tmuxManager else {
            return
        }
        
        // Factory creates Ghostty surfaces
        let factory: (String) -> Ghostty.SurfaceView? = { [weak ghosttyApp, weak self] paneId in
            guard let ghosttyApp = ghosttyApp, let app = ghosttyApp.app else {
                logger.error("Ghostty app deallocated before surface factory called for pane \(paneId)")
                return nil
            }
            
            logger.info("Creating Ghostty surface for pane \(paneId)")
            
            var config = Ghostty.SurfaceConfiguration()
            config.backendType = .external
            
            let surface = Ghostty.SurfaceView(app, baseConfig: config)
            let themeBg = ThemeManager.shared.selectedTheme.background
            surface.backgroundColor = UIColor(themeBg)
            
            // Wire up shortcut delegate for Ghostty keybindings
            surface.shortcutDelegate = self
            
            return surface
        }
        
        // Input handler wires surface.onWrite through SSHSession.
        // In native Ghostty tmux mode, the Zig-side viewer.sendKeys() uses
        // active_pane_id (set by selectPane → setActiveTmuxPane) to route
        // keystrokes to the correct pane. The onWrite callback just needs
        // to forward the data to SSH — focus tracking is handled by
        // selectPane() when the user taps a pane.
        //
        // IMPORTANT: Do NOT call setFocusedPane(paneId) here. The paneId
        // captured in this closure is static (wired at surface creation).
        // In multi-pane mode the primary surface handles ALL input and
        // the captured paneId would always be the primary's initial pane,
        // overwriting whatever selectPane() set.
        let inputHandler: (Ghostty.SurfaceView, String) -> Void = { [weak self] surface, _ in
            surface.onWrite = { [weak self] data in
                self?.viewModel?.sendInput(data)
            }
        }
        
        // Resize handler — called synchronously from layoutSubviews on main thread.
        // No Task deferral: cols/rows must update before connect()/useExistingSession() reads them.
        let resizeHandler: (Int, Int) -> Void = { [weak self] cols, rows in
            self?.viewModel?.resize(cols: cols, rows: rows)
        }
        
        tmuxManager.configureSurfaceManagement(
            factory: factory,
            inputHandler: inputHandler,
            resizeHandler: resizeHandler
        )
        
        logger.info("✅ Surface management configured for TmuxSessionManager")
    }
    
    /// Set up surface factory for tmux multi-pane support
    /// This ensures TmuxSessionManager has what it needs to create surfaces
    func setupTmuxSurfaceFactory() {
        // Configure surface management if not already done
        configureSurfaceManagement()
        
        // CRITICAL: Do NOT replace the existing direct surface with a new one.
        // When tmux activates, the DCS 1000p response has already been fed to
        // the direct surface created at viewDidLoad. Ghostty created its tmux
        // viewer INSIDE that surface's C-side state (viewer.zig, control.zig).
        // Destroying that surface and creating a new one would lose the viewer
        // and all protocol state — the new surface would be blank.
        //
        // Instead, we adopt the existing surface into TmuxSessionManager so it
        // gets the tmux-aware input handler (pane tracking) while preserving
        // the Ghostty-side tmux viewer.
        if let tmuxManager = viewModel?.tmuxManager {
            if let existingSurface = surfaceView, tmuxManager.primarySurface == nil {
                // Adopt the existing direct surface as the tmux primary surface.
                // This preserves Ghostty's internal tmux viewer state.
                logger.info("🔄 Adopting existing direct surface as tmux primary (preserving viewer state)")
                tmuxManager.adoptExistingSurface(existingSurface)
            } else if surfaceView == nil {
                // No surface exists yet — create one from the factory
                if let surface = tmuxManager.createPrimarySurface() {
                    displaySurface(surface)
                    logger.info("✅ Created and displayed primary surface from TmuxSessionManager")
                }
            }
        }
        
        logger.info("✅ tmux surface factory configured")
    }
    
    /// Observe split tree changes to switch between single surface and multi-pane mode
    func setupSplitTreeObserver() {
        guard let tmuxManager = viewModel?.tmuxManager else {
            logger.debug("No tmux manager available for split tree observation")
            return
        }
        
        // Cancel any existing observer
        splitTreeObserver?.cancel()
        
        splitTreeObserver = tmuxManager.$currentSplitTree
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tree in
                self?.handleSplitTreeChange(tree)
            }
        
        logger.info("✅ Split tree observer configured")
    }
    
    /// Observe connection state to set up tmux observers when connected
    /// This is needed because tmux manager doesn't exist until after SSH connects
    func setupConnectionObserver() {
        guard let viewModel = viewModel else { return }
        
        connectionObserver = viewModel.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isConnected in
                if isConnected {
                    // Connection established - set up tmux support immediately
                    // No delay - surface factory should be ready as soon as possible
                    self?.setupTmuxSurfaceFactory()
                    self?.setupSplitTreeObserver()
                    self?.setupWindowsObserver()
                    self?.setupStatusBarObserver()
                    self?.setupReconnectingObserver()
                }
            }
    }
    
    /// Handle split tree changes - switch between single and multi-pane mode
    func handleSplitTreeChange(_ tree: TmuxSplitTree) {
        let hasSplits = tree.isSplit
        let hasPanes = !tree.paneIds.isEmpty
        
        logger.info("🔄 handleSplitTreeChange: panes=\(tree.paneIds), isSplit=\(hasSplits), hasPanes=\(hasPanes), isMultiPaneMode=\(isMultiPaneMode)")
        
        // Log the actual tree structure for debugging
        if let root = tree.root {
            switch root {
            case .leaf(let info):
                logger.info("🔄 Tree root is LEAF: pane=\(info.paneId)")
            case .split(let split):
                logger.info("🔄 Tree root is SPLIT: direction=\(split.direction), ratio=\(split.ratio)")
            }
        } else {
            logger.info("🔄 Tree root is NIL")
        }
        
        // Handle empty tree (all panes closed) - just clean up multi-pane mode
        // The disconnect handler will navigate away when tmux sends %exit
        //
        // GUARD: If we're backgrounded with an active session, do NOT clean up
        // multi-pane mode. Removing the hosting controller triggers a primary surface
        // resize while the tmux viewer is dead → renderer use-after-free SIGSEGV.
        // The split tree will be repopulated by TMUX_STATE_CHANGED when we reattach.
        if !hasPanes {
            if isMultiPaneMode {
                if viewModel?.sshSession?.isDetachingForBackground == true {
                    logger.info("🔄 No panes remaining but backgrounded with active session — preserving multi-pane mode")
                    return
                }
                logger.info("🔄 No panes remaining, cleaning up multi-pane mode")
                cleanupMultiPaneMode()
            }
            return
        }
        
        // SIMPLIFIED: Once we enter multi-pane mode, STAY in multi-pane mode
        // The SwiftUI TmuxMultiPaneView can handle showing 1 pane just fine
        // This avoids the complex surface re-parenting that was causing blank screens
        if hasPanes && !isMultiPaneMode {
            // First time we have panes and splits - enter multi-pane mode
            if hasSplits {
                logger.info("🔄 PATH: hasPanes && hasSplits && !isMultiPaneMode -> transitionToMultiPaneMode")
                transitionToMultiPaneMode()
            }
            // If single pane and not in multi-pane mode, stay with single surface
            // This handles initial connection with no splits
        }
        // If we're in multi-pane mode, stay there - TmuxMultiPaneView handles all pane counts
    }
    
    /// Clean up multi-pane mode without requiring a primary surface
    func cleanupMultiPaneMode() {
        // Clean up divider overlay
        dividerTreeObserver?.cancel()
        dividerTreeObserver = nil
        dividerOverlayView?.removeFromSuperview()
        dividerOverlayView = nil
        
        if let hostingController = multiPaneHostingController {
            hostingController.willMove(toParent: nil)
            hostingController.view.removeFromSuperview()
            hostingController.removeFromParent()
            multiPaneHostingController = nil
            multiPaneTopConstraint = nil
            multiPaneBottomConstraint = nil
        }
        
        // Clear the exact-grid-size suppression on the primary surface.
        // In multi-pane mode, usesExactGridSize=true prevents Zig-side
        // "refresh-client -C" with pane dimensions. Clear it so the surface
        // can auto-resize normally when re-added to the single-pane view.
        viewModel?.tmuxManager?.primarySurface?.clearExactGridSize()
        
        isMultiPaneMode = false
        logger.info("🔄 ✅ Cleaned up multi-pane mode")
    }
    
    /// Transition from single surface mode to multi-pane mode
    func transitionToMultiPaneMode() {
        guard let tmuxManager = viewModel?.tmuxManager else { return }
        
        // Hide the single surface view
        surfaceView?.isHidden = true
        
        // Create and add the multi-pane hosting controller
        var multiPaneView = TmuxMultiPaneView(sessionManager: tmuxManager)
        multiPaneView.shortcutDelegate = self  // Wire up keyboard shortcuts
        let hostingController = UIHostingController(rootView: multiPaneView)
        multiPaneHostingController = hostingController
        
        // Prevent UIHostingController from propagating safe area insets to
        // SwiftUI content. Without this, the GeometryReader in TmuxMultiPaneView
        // reports a size reduced by the bottom safe area (home indicator), leaving
        // ~20px of unused space at the bottom on Face ID iPads.
        if #available(iOS 16.4, *) {
            hostingController.safeAreaRegions = []
        }
        
        // Add as child view controller
        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingController.view)
        
        // Create constraints that match the surface view constraints
        let topConstraint = hostingController.view.topAnchor.constraint(equalTo: view.topAnchor, constant: surfaceTopConstraint?.constant ?? 0)
        let bottomConstraint = hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: surfaceBottomConstraint?.constant ?? 0)
        
        multiPaneTopConstraint = topConstraint
        multiPaneBottomConstraint = bottomConstraint
        
        NSLayoutConstraint.activate([
            topConstraint,
            bottomConstraint,
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        
        hostingController.didMove(toParent: self)
        
        // Set transparent background to show through to our view background
        hostingController.view.backgroundColor = .clear
        
        // Add UIKit divider overlay ON TOP of the SwiftUI view for drag handling
        let overlay = DividerOverlayView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        
        // On drag end: update local layout and commit to tmux
        // We don't update during drag - the blue indicator provides visual feedback
        overlay.onDragEnded = { [weak tmuxManager] paneId, ratio in
            // Update local UI state, then sync to tmux
            tmuxManager?.updateSplitRatio(forPaneId: paneId, ratio: ratio)
            tmuxManager?.syncSplitRatioToTmux(forPaneId: paneId, ratio: ratio)
        }
        view.addSubview(overlay)
        dividerOverlayView = overlay
        
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: hostingController.view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: hostingController.view.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: hostingController.view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: hostingController.view.trailingAnchor)
        ])
        
        // Observe split tree changes to update divider positions
        dividerTreeObserver = tmuxManager.$currentSplitTree
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak overlay] tree in
                guard let self = self, let overlay = overlay else { return }
                let size = self.multiPaneHostingController?.view.bounds.size ?? .zero
                overlay.cellSize = self.viewModel?.tmuxManager?.primaryCellSize ?? .zero
                overlay.updateDividers(from: tree, containerSize: size)
            }
        
        isMultiPaneMode = true
    }
    
    /// Transition from multi-pane mode back to single surface mode
    func transitionToSingleSurfaceMode() {
        guard isMultiPaneMode else {
            logger.warning("🔄 transitionToSingleSurfaceMode called but NOT in multi-pane mode!")
            return
        }
        
        logger.info("🔄 Transitioning to single surface mode")
        
        // Get the primary surface from TmuxSessionManager
        guard let tmuxManager = viewModel?.tmuxManager,
              let primarySurface = tmuxManager.primarySurface else {
            logger.warning("🔄 ⚠️ No primary surface available from TmuxSessionManager!")
            // Still clean up multi-pane mode even without a surface
            cleanupMultiPaneMode()
            return
        }
        
        logger.info("🔄 Got primarySurface: \(primarySurface), current superview: \(String(describing: primarySurface.superview))")
        
        // Clean up the multi-pane hosting controller FIRST
        // This destroys the SwiftUI view that contains the surface
        cleanupMultiPaneMode()
        
        // Now the surface should have no superview (SwiftUI container is gone)
        // If it still has a superview, remove it
        if primarySurface.superview != nil {
            logger.info("🔄 Surface still has superview after cleanup, removing")
            primarySurface.removeFromSuperview()
        }
        
        // Re-add primary surface to our view hierarchy
        primarySurface.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(primarySurface)
        view.bringSubviewToFront(primarySurface)  // Ensure it's on top
        
        let topConstraint = primarySurface.topAnchor.constraint(equalTo: view.topAnchor)
        let bottomConstraint = primarySurface.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        surfaceTopConstraint = topConstraint
        surfaceBottomConstraint = bottomConstraint
        
        NSLayoutConstraint.activate([
            topConstraint,
            bottomConstraint,
            primarySurface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            primarySurface.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        
        // Update our reference and viewModel
        self.surfaceView = primarySurface
        viewModel?.surfaceView = primarySurface
        
        // Force layout to establish the frame
        view.layoutIfNeeded()
        
        logger.info("🔄 Surface frame after layout: \(primarySurface.frame)")
        
        // CRITICAL: Clear the exact-grid-size suppression that was set during
        // multi-pane mode. In multi-pane mode, the primary surface has
        // usesExactGridSize=true to prevent Zig-side "refresh-client -C" with
        // pane dimensions. Now that we're back in single-pane mode, the surface
        // should auto-resize normally from layoutSubviews.
        primarySurface.clearExactGridSize()
        
        // CRITICAL: Notify surface of its new size after re-parenting
        // The surface needs to know its size changed to update its Metal rendering
        // NOTE: clearExactGridSize() above calls sizeDidChange internally,
        // but we call it again here explicitly to ensure the correct frame is used
        // after the layout pass.
        primarySurface.sizeDidChange(primarySurface.frame.size)
        
        // Restore focus
        primarySurface.isHidden = false
        primarySurface.focusDidChange(true)
        let becameFirstResponder = primarySurface.becomeFirstResponder()
        
        // isMultiPaneMode already set to false by cleanupMultiPaneMode()
        logger.info("🔄 ✅ Transitioned to single surface mode (becameFirstResponder=\(becameFirstResponder), frame=\(primarySurface.frame))")
    }
}
