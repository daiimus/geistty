import UIKit
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.geistty", category: "SelectionOverlay")

// MARK: - Selection Handle View

/// A teardrop-shaped handle for adjusting text selection endpoints.
/// Mirrors the native iOS text selection handle appearance.
final class SelectionHandleView: UIView {
    
    enum Position {
        case start  // Handle points upward (at top-left of selection)
        case end    // Handle points downward (at bottom-right of selection)
    }
    
    let position: Position
    
    /// The diameter of the circular part of the handle.
    static let circleDiameter: CGFloat = 12
    
    /// The height of the stem connecting the circle to the selection edge.
    static let stemHeight: CGFloat = 8
    
    /// Total size of the handle view.
    static let handleSize = CGSize(
        width: circleDiameter,
        height: circleDiameter + stemHeight
    )
    
    /// Touch target insets — extend the hit area beyond the visible handle.
    static let touchInsets = UIEdgeInsets(top: -22, left: -22, bottom: -22, right: -22)
    
    private let shapeLayer = CAShapeLayer()
    
    init(position: Position) {
        self.position = position
        super.init(frame: CGRect(origin: .zero, size: Self.handleSize))
        
        isUserInteractionEnabled = true
        backgroundColor = .clear
        
        shapeLayer.fillColor = UIColor.tintColor.cgColor
        layer.addSublayer(shapeLayer)
        
        updatePath()
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        updatePath()
    }
    
    override func tintColorDidChange() {
        super.tintColorDidChange()
        shapeLayer.fillColor = tintColor.cgColor
    }
    
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.inset(by: Self.touchInsets).contains(point)
    }
    
    private func updatePath() {
        let d = Self.circleDiameter
        let r = d / 2
        let stemW: CGFloat = 2  // Width of the thin stem
        let path = UIBezierPath()
        
        switch position {
        case .start:
            // Stem at top, circle at bottom.
            // The handle sits at the top-left of the selection:
            //   - anchor point is the bottom of the stem (where it meets text)
            //   - circle is above
            
            // Start with the circle center at (r, r)
            path.addArc(
                withCenter: CGPoint(x: r, y: r),
                radius: r,
                startAngle: 0,
                endAngle: .pi * 2,
                clockwise: true
            )
            // Stem from bottom of circle to the anchor point
            let stemPath = UIBezierPath(rect: CGRect(
                x: r - stemW / 2,
                y: d,
                width: stemW,
                height: Self.stemHeight
            ))
            path.append(stemPath)
            
        case .end:
            // Stem at top, circle at bottom.
            // The handle sits at the bottom-right of the selection:
            //   - anchor point is the top of the stem (where it meets text)
            //   - circle hangs below
            
            // Stem from anchor point (top) down to circle
            let stemPath = UIBezierPath(rect: CGRect(
                x: r - stemW / 2,
                y: 0,
                width: stemW,
                height: Self.stemHeight
            ))
            path.append(stemPath)
            // Circle below the stem
            path.addArc(
                withCenter: CGPoint(x: r, y: Self.stemHeight + r),
                radius: r,
                startAngle: 0,
                endAngle: .pi * 2,
                clockwise: true
            )
        }
        
        shapeLayer.path = path.cgPath
        shapeLayer.frame = bounds
    }
}

// MARK: - Selection Overlay

/// Transparent overlay that provides iOS-native selection chrome
/// (drag handles + context menu) on top of Ghostty's Metal-rendered
/// selection highlight.
///
/// The overlay does NOT render the selection highlight itself —
/// that's handled by Ghostty's GPU renderer. This overlay only adds:
/// 1. Teardrop drag handles at selection start/end
/// 2. UIEditMenuInteraction for Copy/Paste/Select All
/// 3. Pan gestures on handles for adjusting selection
/// 4. Haptic feedback
final class SelectionOverlay: UIView, UIEditMenuInteractionDelegate {
    
    /// The surface view this overlay is attached to.
    /// Must be set before the overlay can function.
    weak var surfaceView: Ghostty.SurfaceView?
    
    // MARK: - Handle Views
    
    private let startHandle = SelectionHandleView(position: .start)
    private let endHandle = SelectionHandleView(position: .end)
    
    // MARK: - Edit Menu
    
    private var editMenuInteraction: UIEditMenuInteraction?
    
    // MARK: - Haptics
    
    private let hapticSelection = UISelectionFeedbackGenerator()
    
    // MARK: - Handle Dragging State
    
    /// Which handle is currently being dragged (nil = not dragging).
    private var draggingHandle: SelectionHandleView.Position?
    
    /// The point in the surface view where dragging started.
    private var dragStartSurfacePoint: CGPoint = .zero
    
    // MARK: - Lifecycle
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        
        isUserInteractionEnabled = true
        backgroundColor = .clear
        isOpaque = false
        
        // Handles start hidden
        startHandle.isHidden = true
        endHandle.isHidden = true
        startHandle.alpha = 0
        endHandle.alpha = 0
        addSubview(startHandle)
        addSubview(endHandle)
        
        // Edit menu interaction
        let interaction = UIEditMenuInteraction(delegate: self)
        editMenuInteraction = interaction
        addInteraction(interaction)
        
        // Pan gestures on handles
        let startPan = UIPanGestureRecognizer(target: self, action: #selector(handleStartPan(_:)))
        startHandle.addGestureRecognizer(startPan)
        
        let endPan = UIPanGestureRecognizer(target: self, action: #selector(handleEndPan(_:)))
        endHandle.addGestureRecognizer(endPan)
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    
    // MARK: - Public API
    
    /// Call after a selection is created (long-press end, double-tap, triple-tap)
    /// to show handles and present the context menu.
    func showSelection(menuSourcePoint: CGPoint? = nil) {
        guard let surfaceView, let surface = surfaceView.surface else { return }
        guard ghostty_surface_has_selection(surface) else {
            hideSelection()
            return
        }
        
        updateHandlePositions()
        
        // Animate handles in
        startHandle.isHidden = false
        endHandle.isHidden = false
        UIView.animate(withDuration: 0.15, delay: 0, options: .curveEaseOut) {
            self.startHandle.alpha = 1
            self.endHandle.alpha = 1
        }
        
        // Present context menu after a short delay (let the user see the handles first)
        let menuPoint = menuSourcePoint ?? menuSourcePointFromHandles()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.presentEditMenu(at: menuPoint)
        }
    }
    
    /// Call when the selection is cleared (single tap, new output, etc.).
    func hideSelection() {
        UIView.animate(withDuration: 0.1) {
            self.startHandle.alpha = 0
            self.endHandle.alpha = 0
        } completion: { _ in
            self.startHandle.isHidden = true
            self.endHandle.isHidden = true
        }
        editMenuInteraction?.dismissMenu()
    }
    
    /// Call periodically (e.g., on render) to reposition handles if the
    /// selection has moved (scrolling, terminal output, etc.).
    func updateHandlePositionsIfVisible() {
        guard !startHandle.isHidden else { return }
        updateHandlePositions()
    }
    
    // MARK: - Handle Positioning
    
    private func updateHandlePositions() {
        guard let surfaceView, let surface = surfaceView.surface else { return }
        
        var bounds = ghostty_selection_bounds_s()
        guard ghostty_surface_selection_bounds(surface, &bounds) else {
            hideSelection()
            return
        }
        
        // bounds coordinates are in points relative to the surface view.
        // Convert to our overlay coordinate space.
        let startInSurface = CGPoint(x: bounds.start_x, y: bounds.start_y)
        let endInSurface = CGPoint(x: bounds.end_x, y: bounds.end_y)
        
        let startInOverlay = surfaceView.convert(startInSurface, to: self)
        let endInOverlay = surfaceView.convert(endInSurface, to: self)
        
        // Position start handle: circle above, stem connects at start point.
        // Anchor is bottom-center of the handle (bottom of stem = selection start point).
        startHandle.center = CGPoint(
            x: startInOverlay.x,
            y: startInOverlay.y - SelectionHandleView.handleSize.height / 2
        )
        
        // Position end handle: stem connects at end point, circle below.
        // Anchor is top-center of the handle (top of stem = selection end point).
        endHandle.center = CGPoint(
            x: endInOverlay.x,
            y: endInOverlay.y + SelectionHandleView.handleSize.height / 2
        )
    }
    
    // MARK: - Context Menu
    
    private func menuSourcePointFromHandles() -> CGPoint {
        // Position the menu roughly between the two handles, above the selection.
        let startCenter = startHandle.center
        let endCenter = endHandle.center
        return CGPoint(
            x: (startCenter.x + endCenter.x) / 2,
            y: min(startCenter.y, endCenter.y) - 20
        )
    }
    
    func presentEditMenu(at point: CGPoint) {
        let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: point)
        editMenuInteraction?.presentEditMenu(with: config)
    }
    
    // MARK: - UIEditMenuInteractionDelegate
    
    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        var actions: [UIAction] = []
        
        // Copy — only if there's a selection
        if let surfaceView, let surface = surfaceView.surface,
           ghostty_surface_has_selection(surface) {
            actions.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.surfaceView?.copy(nil)
                self?.hideSelection()
            })
        }
        
        // Paste — only if clipboard has content
        if UIPasteboard.general.hasStrings {
            actions.append(UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                self?.surfaceView?.paste(nil)
                self?.hideSelection()
            })
        }
        
        // Select All
        actions.append(UIAction(title: "Select All", image: UIImage(systemName: "selection.pin.in.out")) { [weak self] _ in
            self?.surfaceView?.selectAll()
            // After select all, reposition handles
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.updateHandlePositions()
            }
        })
        
        guard !actions.isEmpty else { return nil }
        return UIMenu(children: actions)
    }
    
    // MARK: - Handle Dragging
    
    @objc private func handleStartPan(_ gesture: UIPanGestureRecognizer) {
        handleDrag(gesture, handle: .start)
    }
    
    @objc private func handleEndPan(_ gesture: UIPanGestureRecognizer) {
        handleDrag(gesture, handle: .end)
    }
    
    private func handleDrag(_ gesture: UIPanGestureRecognizer, handle: SelectionHandleView.Position) {
        guard let surfaceView, let surface = surfaceView.surface else { return }
        
        let locationInSurface = gesture.location(in: surfaceView)
        let scale = surfaceView.contentScaleFactor
        let ghosttyX = locationInSurface.x * scale
        let ghosttyY = locationInSurface.y * scale
        
        switch gesture.state {
        case .began:
            draggingHandle = handle
            dragStartSurfacePoint = locationInSurface
            hapticSelection.prepare()
            
            editMenuInteraction?.dismissMenu()
            
            // To drag a handle, we need to simulate mouse events.
            // For the END handle: shift+click extends from the anchor.
            // For the START handle: we first reset the anchor to the current
            // end position by clicking there, then shift+click to extend to
            // the new start position.
            if handle == .start {
                // Get current end position to use as new anchor
                var bounds = ghostty_selection_bounds_s()
                if ghostty_surface_selection_bounds(surface, &bounds) {
                    // Click at the end position to set anchor there
                    let endX = bounds.end_x * scale
                    let endY = bounds.end_y * scale
                    ghostty_surface_mouse_pos(surface, endX, endY, GHOSTTY_MODS_NONE)
                    _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
                    _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
                }
            }
            
            // Now shift+click at the drag position to start extending
            ghostty_surface_mouse_pos(surface, ghosttyX, ghosttyY, GHOSTTY_MODS_SHIFT)
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_SHIFT)
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_SHIFT)
            
            updateHandlePositions()
            hapticSelection.selectionChanged()
            
        case .changed:
            // Continue extending selection via shift+click at new position
            ghostty_surface_mouse_pos(surface, ghosttyX, ghosttyY, GHOSTTY_MODS_SHIFT)
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_SHIFT)
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_SHIFT)
            
            updateHandlePositions()
            
        case .ended, .cancelled:
            draggingHandle = nil
            
            // Re-present the context menu
            if ghostty_surface_has_selection(surface) {
                let menuPoint = menuSourcePointFromHandles()
                presentEditMenu(at: menuPoint)
            }
            
        default:
            break
        }
    }
    
    // MARK: - Hit Testing
    
    /// Only intercept touches on the handles or when the edit menu is visible.
    /// Otherwise, pass through to the surface view below for normal interaction.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Check handles first (they have expanded touch targets)
        if !startHandle.isHidden {
            let startPoint = convert(point, to: startHandle)
            if startHandle.point(inside: startPoint, with: event) {
                return startHandle
            }
        }
        if !endHandle.isHidden {
            let endPoint = convert(point, to: endHandle)
            if endHandle.point(inside: endPoint, with: event) {
                return endHandle
            }
        }
        
        // Otherwise, pass through — let the surface view handle touches
        return nil
    }
}
