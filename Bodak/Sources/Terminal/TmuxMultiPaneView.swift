//
//  TmuxMultiPaneView.swift
//  Bodak
//
//  SwiftUI view that renders multiple tmux panes using TmuxSplitTreeView.
//  This view observes the TmuxSessionManager and automatically updates
//  when the split tree changes.
//

import SwiftUI
import Combine
import os

private let logger = Logger(subsystem: "com.bodak", category: "TmuxMultiPane")

/// A SwiftUI view that renders multiple tmux panes with proper split layout.
///
/// This view observes the `TmuxSessionManager.currentSplitTree` and renders
/// the split tree using `TmuxSplitTreeView`. Each pane gets its own Ghostty
/// surface from the session manager.
struct TmuxMultiPaneView: View {
    @ObservedObject var sessionManager: TmuxSessionManager
    
    /// Divider color (matches Ghostty's split divider)
    var dividerColor: Color = Color(white: 0.3)
    
    var body: some View {
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
            paneContent: { paneId in
                TmuxPaneSurfaceView(paneId: paneId, sessionManager: sessionManager)
            }
        )
    }
}

/// A view that wraps a Ghostty surface for a specific tmux pane.
///
/// This view gets the surface from the session manager and wraps it
/// in a UIViewRepresentable for SwiftUI rendering. Tapping the pane
/// selects it and focuses its surface.
struct TmuxPaneSurfaceView: View {
    let paneId: Int
    @ObservedObject var sessionManager: TmuxSessionManager
    
    /// Whether this pane is currently focused
    private var isFocused: Bool {
        sessionManager.focusedPaneId == "%\(paneId)"
    }
    
    var body: some View {
        // Get or create the surface for this pane
        if let surface = sessionManager.getSurface(forNumericId: paneId) {
            GhosttyPaneSurfaceWrapper(
                surface: surface,
                isFocused: isFocused,
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

/// UIViewRepresentable wrapper for a Ghostty.SurfaceView with focus support
struct GhosttyPaneSurfaceWrapper: UIViewRepresentable {
    let surface: Ghostty.SurfaceView
    let isFocused: Bool
    let onTap: () -> Void
    
    func makeUIView(context: Context) -> GhosttyPaneSurfaceContainerView {
        let container = GhosttyPaneSurfaceContainerView()
        container.surface = surface
        container.onTap = onTap
        return container
    }
    
    func updateUIView(_ container: GhosttyPaneSurfaceContainerView, context: Context) {
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

/// Container view for a Ghostty surface that handles tap gestures
class GhosttyPaneSurfaceContainerView: UIView {
    var surface: Ghostty.SurfaceView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let surface = surface {
                // Remove from any previous superview and ensure it's visible
                surface.removeFromSuperview()
                surface.isHidden = false
                
                surface.translatesAutoresizingMaskIntoConstraints = false
                addSubview(surface)
                NSLayoutConstraint.activate([
                    surface.topAnchor.constraint(equalTo: topAnchor),
                    surface.bottomAnchor.constraint(equalTo: bottomAnchor),
                    surface.leadingAnchor.constraint(equalTo: leadingAnchor),
                    surface.trailingAnchor.constraint(equalTo: trailingAnchor)
                ])
            }
        }
    }
    
    var onTap: (() -> Void)?
    
    override init(frame: CGRect) {
        super.init(frame: frame)
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
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
