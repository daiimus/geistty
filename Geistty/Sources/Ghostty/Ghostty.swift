//
//  Ghostty.swift
//  Geistty
//
//  Swift wrappers for the GhosttyKit C API
//

import Foundation
import UIKit
import Metal
import QuartzCore
import GhosttyKit
import ObjectiveC
import UserNotifications
import Combine

/// Ghostty namespace containing all Ghostty-related types
enum Ghostty {
    /// Logger for Ghostty-related operations
    static let logger = Logger(subsystem: "com.geistty", category: "Ghostty")
    
    // MARK: - Keyboard Shortcut Actions (matches Ghostty macOS keybindings)
    
    /// Actions that can be triggered by keyboard shortcuts
    /// These mirror Ghostty's macOS keybinding actions
    enum ShortcutAction {
        // Window/Tab management
        case newWindow
        case newTab
        case closeSurface
        case closeTab
        case closeWindow
        
        // Split management
        case newSplitRight      // Cmd+D
        case newSplitDown       // Cmd+Shift+D
        case gotoSplitPrevious  // Cmd+[
        case gotoSplitNext      // Cmd+]
        case gotoSplitUp        // Cmd+Option+Up
        case gotoSplitDown      // Cmd+Option+Down
        case gotoSplitLeft      // Cmd+Option+Left
        case gotoSplitRight     // Cmd+Option+Right
        case toggleSplitZoom    // Cmd+Shift+Enter
        case equalizeSplits     // Cmd+Ctrl+=
        
        // Tab navigation
        case previousTab        // Cmd+Shift+[
        case nextTab            // Cmd+Shift+]
        case gotoTab(Int)       // Cmd+1-8
        case lastTab            // Cmd+9
        
        // Connection management
        case reconnect          // Cmd+R
        case disconnect         // Cmd+W (close without reconnect)
        
        // Window operations
        case renameWindow       // Cmd+Shift+R or ,
        
        // Session management
        case showSessions       // Cmd+Shift+S
    }
    
    /// Delegate protocol for handling app-level keyboard shortcuts
    /// Implement this to receive Ghostty-style keyboard shortcuts
    protocol ShortcutDelegate: AnyObject {
        /// Called when a keyboard shortcut is triggered
        /// - Parameter action: The shortcut action to perform
        /// - Returns: true if the action was handled, false to pass through
        func handleShortcut(_ action: ShortcutAction) -> Bool
    }
}

// MARK: - Simple Logger wrapper around os.Logger

import os

struct Logger {
    private let osLogger: os.Logger
    
    init(subsystem: String, category: String) {
        osLogger = os.Logger(subsystem: subsystem, category: category)
    }
    
    func info(_ message: String) {
        osLogger.info("\(message, privacy: .public)")
    }
    
    func warning(_ message: String) {
        osLogger.warning("\(message, privacy: .public)")
    }
    
    func error(_ message: String) {
        osLogger.error("\(message, privacy: .public)")
    }
    
    func debug(_ message: String) {
        osLogger.debug("\(message, privacy: .public)")
    }
}

// MARK: - Ghostty.Config → Ghostty.Config.swift

// MARK: - Ghostty.App → Ghostty.App.swift

// MARK: - Ghostty.SurfaceConfiguration → Ghostty.SurfaceConfiguration.swift

// MARK: - Ghostty.SurfaceView

extension Ghostty {
    /// UIView implementation for a Ghostty terminal surface
    /// Uses CAMetalLayer for hardware-accelerated rendering
    /// Conforms to UIKeyInput to handle keyboard input
    class SurfaceView: UIView, ObservableObject, UIKeyInput, UIPointerInteractionDelegate, UIGestureRecognizerDelegate {
        /// Unique identifier for this surface
        let uuid: UUID
        
        /// The current title of the surface
        @Published var title: String = "Terminal"
        
        /// The current working directory
        @Published var pwd: String? = nil
        
        /// Cell size for the terminal grid
        @Published var cellSize: CGSize = .zero {
            didSet {
                if cellSize != oldValue && cellSize.width > 0 && cellSize.height > 0 {
                    onCellSizeChanged?(cellSize)
                }
            }
        }
        
        /// Callback when cell size changes (for multi-pane layout coordination)
        var onCellSizeChanged: ((CGSize) -> Void)?
        
        /// Scrollbar state (total rows, offset, visible length)
        @Published var scrollbar: (total: UInt64, offset: UInt64, len: UInt64)? = nil
        
        /// URL being hovered over (OSC 8 hyperlinks or detected URLs)
        @Published var hoverUrl: String? = nil
        
        /// Current mouse cursor shape (for trackpad/mouse users)
        var currentMouseShape: ghostty_action_mouse_shape_e = GHOSTTY_MOUSE_SHAPE_DEFAULT
        
        /// When true, the surface uses an explicit grid size set via setExactGridSize()
        /// and won't auto-resize based on view bounds. This prevents layout thrashing
        /// in multi-pane tmux layouts where each pane has a fixed character size.
        var usesExactGridSize: Bool = false
        
        /// When true, this surface is an observer in multi-pane tmux mode.
        /// Observer surfaces must NOT become firstResponder — their Zig Termio
        /// has tmux_active=false, so keystrokes would bypass send-keys wrapping
        /// and arrive as raw bytes on the tmux control channel.
        /// Set to true by attachToTmuxPane().
        var isMultiPaneObserver: Bool = false
        
        /// Selection overlay providing iOS-native drag handles and context menu
        /// on top of Ghostty's GPU-rendered selection highlight.
        private var selectionOverlay: SelectionOverlay?
        
        /// Callback invoked when an observer surface is tapped in multi-pane mode.
        /// UIKit's gesture recognizer mutual exclusion prevents a parent view's tap
        /// gesture from firing when a child view's tap gesture recognizes first (the
        /// child wins, the parent is automatically failed). Since SurfaceView has its
        /// own tap gesture, the container's tap gesture (which calls selectPane())
        /// never fires. This callback bridges that gap: the surface's handleTap()
        /// calls it for observers, routing the tap to the container's pane selection
        /// logic without requiring gesture recognizer coexistence.
        var onPaneTap: (() -> Void)?
        
        /// Active key table name - when non-nil, a key table is active (vim-style modal keys)
        @Published var activeKeyTable: String? = nil
        
        /// Search state - when non-nil, search is active
        @Published var searchState: SearchState? = nil {
            didSet {
                if let searchState {
                    logger.debug("🔍 SearchState set, subscribing to needle changes")
                    // Set up debounced search using new ScreenSearch-based sync API
                    // Use 200ms debounce to avoid crashes from rapid typing
                    searchNeedleCancellable = searchState.$needle
                        .dropFirst() // Skip initial empty value when SearchState is created
                        .removeDuplicates()
                        .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
                        .sink { [weak self] needle in
                            logger.debug("🔍 Needle changed to: '\(needle)', calling performSyncSearch")
                            self?.performSyncSearch(needle: needle)
                        }
                } else if oldValue != nil {
                    // Search ended - cancel pending debounce and end search in Ghostty
                    searchNeedleCancellable = nil
                    // End search (clears highlights) on main thread
                    if let surface = self.surface {
                        ghostty_surface_search_end(surface)
                    }
                }
            }
        }
        
        /// Cancellable for search state needle changes (debounced search)
        private var searchNeedleCancellable: AnyCancellable?
        
        /// Perform synchronous search on main thread.
        /// Ghostty's search APIs operate on in-memory terminal screen data and are fast.
        /// Running on main thread eliminates the TOCTOU race where surface could be
        /// freed between capture and use on a background queue (C1 fix).
        private func performSyncSearch(needle: String) {
            assert(Thread.isMainThread, "performSyncSearch must run on main thread")
            logger.debug("🔍 performSyncSearch called with needle: '\(needle)'")
            
            guard let surface = self.surface else { return }
            guard !needle.isEmpty else {
                // Empty needle - end search
                ghostty_surface_search_end(surface)
                self.searchState?.total = nil
                self.searchState?.selected = nil
                return
            }
            
            // Call the search_start API (initializes search and scrolls to first match)
            logger.debug("🔍 Calling ghostty_surface_search_start with needle: '\(needle)'")
            let result = needle.withCString { needlePtr in
                ghostty_surface_search_start(surface, needlePtr, UInt(needle.utf8.count))
            }
            
            // screen_type: 0 = primary (has scrollback), 1 = alternate (e.g. tmux - no scrollback)
            let isAlternateScreen = result.screen_type == 1
            if isAlternateScreen {
                logger.info("🔍 Search on alternate screen (tmux/vim) - limited to visible rows only")
            }
            logger.info("🔍 ghostty_surface_search_start returned: success=\(result.success), total=\(result.total), selected=\(result.selected), screen_type=\(result.screen_type), total_rows=\(result.total_rows), visible_rows=\(result.visible_rows)")
            
            if result.success {
                self.searchState?.total = result.total >= 0 ? UInt(result.total) : nil
                self.searchState?.selected = result.selected >= 0 ? UInt(result.selected) : nil
                self.searchState?.isAlternateScreen = isAlternateScreen
            }
        }
        
        /// Current font size (starts at config default)
        @Published var currentFontSize: Float = 14.0
        
        /// Font size constraints
        static let minFontSize: Float = 6.0
        static let maxFontSize: Float = 72.0
        static let defaultFontSize: Float = 14.0
        
        /// Pinch gesture state
        private var pinchStartFontSize: Float = 14.0
        
        /// Shared haptic feedback generators — reuse across gestures to avoid
        /// per-tap allocation overhead (Apple recommends long-lived instances).
        private let hapticLight = UIImpactFeedbackGenerator(style: .light)
        private let hapticMedium = UIImpactFeedbackGenerator(style: .medium)
        private let hapticNotification = UINotificationFeedbackGenerator()
        
        /// Scroll indicator view
        private var scrollIndicator: UIView?
        private var scrollIndicatorHideTimer: Timer?
        
        /// Whether the surface is healthy
        @Published var healthy: Bool = true
        
        /// Any initialization error
        @Published var error: Error? = nil
        
        /// The underlying ghostty_surface_t handle
        private(set) var surface: ghostty_surface_t?
        
        /// Callback for when the surface wants to write data (user input)
        var onWrite: ((Data) -> Void)?
        
        /// Callback for when the terminal grid size changes (cols, rows)
        var onResize: ((Int, Int) -> Void)?
        
        /// Delegate for handling Ghostty-style keyboard shortcuts (Cmd+D, etc.)
        weak var shortcutDelegate: ShortcutDelegate?
        
        /// Focus state tracking
        private var hasFocusState: Bool = false
        private var focusInstant: ContinuousClock.Instant? = nil
        
        /// Whether the software keyboard is currently visible (height >= 100pt).
        /// Used to conditionally return the input accessory view — on iPad with
        /// a hardware keyboard, returning `nil` prevents the Esc/Tab/arrow bar
        /// from floating at the bottom of the screen. (#44 Bug 2 regression)
        private var softwareKeyboardVisible = false
        
        /// Terminal symbols bar — displayed above the software keyboard.
        /// Lazy-initialized on first access; nil for observer surfaces.
        private lazy var terminalAccessoryView: TerminalAccessoryView? = {
            // Observer surfaces (multi-pane) never become first responder,
            // so they don't need an accessory view.
            guard !isMultiPaneObserver else { return nil }
            let accessory = TerminalAccessoryView()
            accessory.onSendText = { [weak self] text in
                self?.sendText(text)
            }
            accessory.onSendVirtualKey = { [weak self] tag in
                guard let vk = Self.virtualKeyForTag(tag) else { return }
                self?.sendVirtualKey(vk)
            }
            accessory.onSetCtrlToggle = { [weak self] active in
                self?.setCtrlToggle(active)
            }
            return accessory
        }()
        
        // MARK: - UIKeyInput conformance
        
        // Note: canBecomeFirstResponder is declared in "First Responder & Keyboard" section
        
        // MARK: - UITextInputTraits (stored properties for keyboard configuration)
        
        /// Disable autocorrection for terminal input
        private var _autocorrectionType: UITextAutocorrectionType = .no
        
        /// Disable autocapitalization for terminal input
        private var _autocapitalizationType: UITextAutocapitalizationType = .none
        
        /// Disable spell checking for terminal input
        private var _spellCheckingType: UITextSpellCheckingType = .no
        
        /// Use ASCII keyboard as default
        private var _keyboardType: UIKeyboardType = .asciiCapable
        
        /// Standard return key
        private var _returnKeyType: UIReturnKeyType = .default
        
        /// Disable smart quotes for terminal
        private var _smartQuotesType: UITextSmartQuotesType = .no
        
        /// Disable smart dashes for terminal
        private var _smartDashesType: UITextSmartDashesType = .no
        
        /// Disable smart insert/delete for terminal
        private var _smartInsertDeleteType: UITextSmartInsertDeleteType = .no
        
        /// Required: Does the view have text? (Always yes for terminal)
        var hasText: Bool { true }
        
        /// Required: Insert text from keyboard (software keyboard)
        /// Uses ghostty_surface_text() for plain text, ghostty_surface_key() when Ctrl is active
        /// Special handling for Enter/Return and Tab which need key events
        func insertText(_ text: String) {
            guard let surface = surface else { return }
            
            // Handle special keys that need to be sent as key events
            // Enter/Return - needs proper key event for terminal handling
            if text == "\n" || text == "\r" {
                let keyEvent = Input.KeyEvent(key: .enter, action: .press)
                keyEvent.withCValue { cEvent in
                    _ = ghostty_surface_key(surface, cEvent)
                }
                return
            }
            
            // Tab - needs proper key event
            if text == "\t" {
                let keyEvent = Input.KeyEvent(key: .tab, action: .press)
                keyEvent.withCValue { cEvent in
                    _ = ghostty_surface_key(surface, cEvent)
                }
                return
            }
            
            // Escape character (in case it comes through insertText from soft keyboard)
            if text == "\u{1B}" {
                let keyEvent = Input.KeyEvent(key: .escape, action: .press)
                keyEvent.withCValue { cEvent in
                    _ = ghostty_surface_key(surface, cEvent)
                }
                return
            }
            
            // Check if Ctrl toggle is active (from on-screen button)
            if ctrlToggleActive {
                ctrlToggleActive = false
                terminalAccessoryView?.resetCtrlState()
                
                // With Ctrl active, send as key events to get proper control character handling
                for char in text {
                    let textInput = Input.TextInputEvent(text: String(char), mods: [.ctrl])
                    let keyEvent = textInput.toKeyEvent()
                    
                    keyEvent.withCValue { cEvent in
                        _ = ghostty_surface_key(surface, cEvent)
                    }
                }
                return
            }
            
            // Plain text - use ghostty_surface_text() for direct UTF-8 handling
            // This bypasses key events but correctly handles all Unicode
            let len = text.utf8CString.count
            if len > 0 {
                text.withCString { ptr in
                    ghostty_surface_text(surface, ptr, UInt(len - 1))
                }
            }
        }
        
        /// Required: Handle backspace/delete
        /// Uses ghostty_surface_key() with backspace key code
        func deleteBackward() {
            guard let surface = surface else { return }
            
            let keyEvent = Input.KeyEvent(key: .backspace, action: .press)
            keyEvent.withCValue { cEvent in
                _ = ghostty_surface_key(surface, cEvent)
            }
        }
        
        /// Convenience accessor for the Metal layer
        var metalLayer: CAMetalLayer {
            return layer as! CAMetalLayer
        }
        
        /// Initialize with a Ghostty app
        init(_ app: ghostty_app_t, baseConfig: SurfaceConfiguration? = nil, uuid: UUID? = nil) {
            self.uuid = uuid ?? UUID()
            
            // Initialize with a reasonable default frame (non-zero so layer bounds are non-zero)
            super.init(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
            
            // Configure the view and its CAMetalLayer to prevent white flashes
            // CRITICAL: Disable implicit animations to prevent any white flash during setup
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            
            backgroundColor = .black
            isOpaque = true
            layer.isOpaque = true
            if let metalLayer = layer as? CAMetalLayer {
                metalLayer.backgroundColor = UIColor.black.cgColor
                metalLayer.isOpaque = true
            }
            
            CATransaction.commit()
            
            // NOTE: We do NOT configure the metal layer here.
            // Ghostty's Metal renderer creates its own IOSurfaceLayer and adds it as a sublayer.
            // The renderer handles all Metal configuration internally.
            
            // Setup the surface - this is where Ghostty's Metal renderer is initialized
            // and where addSublayer will be called on this view
            let surfaceConfig = baseConfig ?? SurfaceConfiguration()
            
            // For external backend, we need to set up a write callback
            // The callback will be invoked when the terminal wants to send data (user input)
            let writeCallback: ghostty_write_callback_fn? = surfaceConfig.backendType == .external
                ? Self.externalWriteCallback
                : nil
            
            // For external backend, set up a resize callback
            // The callback will be invoked from the IO thread when the terminal is resized
            let resizeCallback: ghostty_resize_callback_fn? = surfaceConfig.backendType == .external
                ? Self.externalResizeCallback
                : nil
            
            let surface = surfaceConfig.withCValue(view: self, writeCallback: writeCallback, resizeCallback: resizeCallback) { config in
                ghostty_surface_new(app, &config)
            }
            
            guard let surface = surface else {
                self.error = GhosttyError.surfaceCreationFailed
                logger.error("Failed to create Ghostty surface")
                return
            }
            
            self.surface = surface
            
            // Set background color to match theme to prevent flash during screen transitions
            // CRITICAL: Disable implicit animations to prevent white curtain effect
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            
            let themeBg = ThemeManager.shared.selectedTheme.background
            self.backgroundColor = UIColor(themeBg)
            self.isOpaque = true
            self.layer.isOpaque = true
            if let metalLayer = self.layer as? CAMetalLayer {
                metalLayer.backgroundColor = UIColor(themeBg).cgColor
            }
            
            CATransaction.commit()
            
            logger.info("Ghostty surface created successfully with backend: \(surfaceConfig.backendType)")
            
            // Add accessibility identifiers for UI testing
            isAccessibilityElement = true
            accessibilityIdentifier = "TerminalSurface-\(self.uuid.uuidString.prefix(8))"
            accessibilityLabel = "Terminal Surface"
            
            // Enable user interaction and add tap gesture to become first responder
            isUserInteractionEnabled = true
            let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            addGestureRecognizer(tapGesture)
            
            // Add double-tap for word selection
            let doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            doubleTapGesture.numberOfTapsRequired = 2
            addGestureRecognizer(doubleTapGesture)
            tapGesture.require(toFail: doubleTapGesture)
            
            // Add triple-tap for line selection
            let tripleTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTripleTap(_:)))
            tripleTapGesture.numberOfTapsRequired = 3
            addGestureRecognizer(tripleTapGesture)
            doubleTapGesture.require(toFail: tripleTapGesture)
            
            // Add two-finger tap to open links (equivalent to Cmd+click on macOS)
            let twoFingerTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
            twoFingerTapGesture.numberOfTouchesRequired = 2
            addGestureRecognizer(twoFingerTapGesture)
            
            // Add two-finger double-tap to reset font size
            let twoFingerDoubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerDoubleTap(_:)))
            twoFingerDoubleTapGesture.numberOfTouchesRequired = 2
            twoFingerDoubleTapGesture.numberOfTapsRequired = 2
            addGestureRecognizer(twoFingerDoubleTapGesture)
            twoFingerTapGesture.require(toFail: twoFingerDoubleTapGesture)
            
            // Add long press gesture to START text selection
            let longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            longPressGesture.minimumPressDuration = 0.3
            longPressGesture.delegate = self  // Allow gesture delegation for scroll/selection coordination
            addGestureRecognizer(longPressGesture)
            
            // Add single-finger pan gesture for scrolling
            let singleFingerScrollGesture = UIPanGestureRecognizer(target: self, action: #selector(handleSingleFingerScroll(_:)))
            singleFingerScrollGesture.minimumNumberOfTouches = 1
            singleFingerScrollGesture.maximumNumberOfTouches = 1
            singleFingerScrollGesture.delegate = self
            addGestureRecognizer(singleFingerScrollGesture)
            
            // Add two-finger pan gesture for scrolling (original working gesture)
            let twoFingerScrollGesture = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
            twoFingerScrollGesture.minimumNumberOfTouches = 2
            twoFingerScrollGesture.maximumNumberOfTouches = 2
            addGestureRecognizer(twoFingerScrollGesture)
            
            // Add trackpad/mouse scroll gesture (indirect input like Magic Keyboard trackpad)
            let trackpadScrollGesture = UIPanGestureRecognizer(target: self, action: #selector(handleTrackpadScroll(_:)))
            trackpadScrollGesture.allowedScrollTypesMask = [.continuous, .discrete]
            trackpadScrollGesture.minimumNumberOfTouches = 0  // Trackpad scrolls don't register as touches
            trackpadScrollGesture.maximumNumberOfTouches = 0
            addGestureRecognizer(trackpadScrollGesture)
            
            // Note: Mouse click-drag selection is handled via touchesBegan/Moved/Ended
            // for instant response (no gesture delay)
            
            // Add pointer interaction for external mouse/trackpad support
            let pointerInteraction = UIPointerInteraction(delegate: self)
            addInteraction(pointerInteraction)
            
            // Add hover gesture for mouse movement tracking
            let hoverGesture = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
            addGestureRecognizer(hoverGesture)
            
            // Add pinch gesture for font size zoom
            let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            addGestureRecognizer(pinchGesture)
            
            // Setup selection overlay (handles + context menu for text selection)
            let overlay = SelectionOverlay(frame: bounds)
            overlay.surfaceView = self
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(overlay)
            selectionOverlay = overlay
            
            // Setup scroll indicator
            setupScrollIndicator()
            
            // Register for trait changes (dark/light mode)
            registerForTraitChanges()
            
            // Set initial color scheme based on current trait collection
            updateColorScheme()
            
            // Configure accessibility
            setupAccessibility()
            
            // Observe app lifecycle to restore keyboard focus
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(appDidBecomeActiveForKeyboard),
                name: UIApplication.didBecomeActiveNotification,
                object: nil
            )
            
            // Track software keyboard visibility so inputAccessoryView returns
            // nil when only a hardware keyboard is attached. (#44 Bug 2)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(softwareKeyboardWillShow(_:)),
                name: UIResponder.keyboardWillShowNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(softwareKeyboardWillHide(_:)),
                name: UIResponder.keyboardWillHideNotification,
                object: nil
            )
        }
        
        /// Restore keyboard focus when app becomes active
        @objc private func appDidBecomeActiveForKeyboard() {
            // Only restore if we're in a window and were previously first responder
            // or if the user had the keyboard visible
            guard window != nil else { return }
            
            // Use a slight delay to ensure the app is fully active
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self, self.window != nil else { return }
                
                // Restore first responder if needed
                if !self.isFirstResponder {
                    _ = self.becomeFirstResponder()
                } else {
                    // Already first responder, reload input views to refresh keyboard state
                    self.reloadInputViews()
                }
            }
        }
        
        /// Track software keyboard visibility to gate inputAccessoryView.
        /// A "real" software keyboard has a frame height >= 100pt; the
        /// inputAccessoryView alone is ~44pt and should not count.
        @objc private func softwareKeyboardWillShow(_ notification: Notification) {
            guard let userInfo = notification.userInfo,
                  let frame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
                return
            }
            
            // Calculate overlap with our view, matching the logic in
            // RawTerminalUIViewController+Keyboard.swift.
            let frameInView = convert(frame, from: nil)
            let overlap = max(0, bounds.maxY - frameInView.minY)
            
            let isSoftwareKeyboard = overlap >= 100
            if isSoftwareKeyboard != softwareKeyboardVisible {
                softwareKeyboardVisible = isSoftwareKeyboard
                reloadInputViews()
            }
        }
        
        /// Software keyboard is hiding — clear the flag and reload so
        /// inputAccessoryView returns nil.
        @objc private func softwareKeyboardWillHide(_ notification: Notification) {
            if softwareKeyboardVisible {
                softwareKeyboardVisible = false
                reloadInputViews()
            }
        }
        
        // MARK: - Accessibility
        
        /// Configure accessibility for VoiceOver and other assistive technologies
        private func setupAccessibility() {
            isAccessibilityElement = true
            accessibilityTraits = [.allowsDirectInteraction, .keyboardKey]
            accessibilityLabel = "Terminal"
            accessibilityHint = "SSH terminal connection. Double tap to focus and show keyboard."
            
            // Enable VoiceOver to read terminal output
            accessibilityViewIsModal = true
        }
        
        // MARK: - Dark Mode Support
        
        /// Update Ghostty color scheme based on iOS appearance
        private func updateColorScheme() {
            guard let surface = surface else { return }
            let scheme: ghostty_color_scheme_e = traitCollection.userInterfaceStyle == .dark
                ? GHOSTTY_COLOR_SCHEME_DARK
                : GHOSTTY_COLOR_SCHEME_LIGHT
            ghostty_surface_set_color_scheme(surface, scheme)
            logger.info("🎨 Color scheme set to: \(traitCollection.userInterfaceStyle == .dark ? "dark" : "light")")
        }
        
        /// Register for trait changes using modern API (iOS 17+)
        private func registerForTraitChanges() {
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
                self.updateColorScheme()
            }
        }
        
        // MARK: - Scroll Indicator
        
        private func setupScrollIndicator() {
            let indicator = UIView()
            indicator.backgroundColor = UIColor.white.withAlphaComponent(0.4)
            indicator.layer.cornerRadius = 2
            indicator.alpha = 0
            // Start with x = -10 (off-screen left); layoutSubviews will position it correctly
            // This prevents the visual "slide in from left" when bounds.width is initially 0
            indicator.frame = CGRect(x: -10, y: 0, width: 4, height: 40)
            addSubview(indicator)
            scrollIndicator = indicator
        }
        
        /// Update scroll indicator based on scrollbar state
        func updateScrollIndicator(total: UInt64, offset: UInt64, len: UInt64) {
            scrollbar = (total, offset, len)
            
            guard let indicator = scrollIndicator else { return }
            guard total > 0 else {
                indicator.alpha = 0
                return
            }
            
            let viewHeight = bounds.height
            let margin: CGFloat = 4
            let availableHeight = viewHeight - (margin * 2)
            
            // Calculate indicator size and position
            let indicatorHeight = max(20, availableHeight * CGFloat(len) / CGFloat(total))
            let indicatorY = margin + (availableHeight - indicatorHeight) * CGFloat(offset) / CGFloat(max(1, total - len))
            
            // Position on right edge
            indicator.frame = CGRect(
                x: bounds.width - 6,
                y: indicatorY,
                width: 4,
                height: indicatorHeight
            )
            
            // Show indicator
            showScrollIndicator()
        }
        
        private func showScrollIndicator() {
            scrollIndicatorHideTimer?.invalidate()
            
            UIView.animate(withDuration: 0.15) { [weak self] in
                self?.scrollIndicator?.alpha = 1
            }
            
            // Hide after delay
            scrollIndicatorHideTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                UIView.animate(withDuration: 0.3) { [weak self] in
                    self?.scrollIndicator?.alpha = 0
                }
            }
        }
        
        // MARK: - UIPointerInteractionDelegate
        
        func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
            // Map Ghostty mouse shape to iOS pointer style
            switch currentMouseShape {
            case GHOSTTY_MOUSE_SHAPE_TEXT, GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT:
                return UIPointerStyle(shape: .verticalBeam(length: 20))
            case GHOSTTY_MOUSE_SHAPE_POINTER:
                // Link cursor - use default pointer which shows hand on hover
                return UIPointerStyle(effect: .automatic(UITargetedPreview(view: self)))
            case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
                return UIPointerStyle(shape: .verticalBeam(length: 20)) // iOS doesn't have crosshair
            case GHOSTTY_MOUSE_SHAPE_GRAB, GHOSTTY_MOUSE_SHAPE_GRABBING:
                return UIPointerStyle(effect: .automatic(UITargetedPreview(view: self)))
            case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP:
                return UIPointerStyle(effect: .automatic(UITargetedPreview(view: self)))
            case GHOSTTY_MOUSE_SHAPE_E_RESIZE, GHOSTTY_MOUSE_SHAPE_W_RESIZE, GHOSTTY_MOUSE_SHAPE_EW_RESIZE:
                return UIPointerStyle(shape: .horizontalBeam(length: 20))
            case GHOSTTY_MOUSE_SHAPE_N_RESIZE, GHOSTTY_MOUSE_SHAPE_S_RESIZE, GHOSTTY_MOUSE_SHAPE_NS_RESIZE:
                return UIPointerStyle(shape: .verticalBeam(length: 20))
            default:
                // Default to text cursor for terminal
                return UIPointerStyle(shape: .verticalBeam(length: 20))
            }
        }
        
        // MARK: - Mouse Hover for Position Tracking
        
        @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
            guard let surface = surface else { return }
            
            let point = gesture.location(in: self)
            let scale = contentScaleFactor
            
            switch gesture.state {
            case .began, .changed:
                // Track mouse position (needed for cursor and mouse-aware apps)
                ghostty_surface_mouse_pos(surface, point.x * scale, point.y * scale, GHOSTTY_MODS_NONE)
                
            case .ended:
                break
                
            default:
                break
            }
        }
        
        // MARK: - Mouse/Scroll Wheel Support (for trackpad and external mouse)
        
        /// Track scroll state for physics-based scrolling
        private var scrollDisplayLink: CADisplayLink?
        private var scrollDisplayLinkProxy: DisplayLinkProxy?
        private var scrollVelocity: CGFloat = 0
        private var initialMomentumVelocity: CGFloat = 0  // Track initial velocity for dynamic deceleration
        private var momentumFrameCount: Int = 0  // Track frames for initial kick
        
        /// Base deceleration - adjusted dynamically based on initial velocity
        private let baseDeceleration: CGFloat = 0.96
        private let maxDeceleration: CGFloat = 0.985  // For fast flicks - coast longer
        private let scrollMinVelocity: CGFloat = 0.12   // Stop when velocity falls below this
        
        /// Track accumulated scroll for gesture
        private var accumulatedScrollY: CGFloat = 0
        
        /// Base scroll sensitivity
        private let touchScrollSensitivity: CGFloat = 0.18
        
        /// Momentum velocity multiplier for touch
        private let touchMomentumMultiplier: CGFloat = 0.012
        
        /// Trackpad/mouse scroll sensitivity (higher = faster)
        private let trackpadScrollSensitivity: CGFloat = 0.35
        
        /// Trackpad momentum multiplier
        private let trackpadMomentumMultiplier: CGFloat = 0.012
        
        /// Track if we're currently scrolled up (not at bottom)
        /// Updated by scrollbar callback and scroll gestures
        var isScrolledUp: Bool = false
        
        /// Build scroll mods for Ghostty API (packed struct: precision bit + momentum phase)
        private func makeScrollMods(precision: Bool, momentum: UInt8 = 0) -> Int32 {
            // ScrollMods is packed: bit 0 = precision, bits 1-3 = momentum phase
            var mods: Int32 = 0
            if precision {
                mods |= 1  // bit 0
            }
            mods |= Int32(momentum & 0x7) << 1  // bits 1-3
            return mods
        }
        
        /// Handle two-finger touch scrolling - lifelike iOS-style physics
        @objc private func handleScroll(_ gesture: UIPanGestureRecognizer) {
            guard let surface = surface else { return }
            
            let translation = gesture.translation(in: self)
            let velocity = gesture.velocity(in: self).y
            
            switch gesture.state {
            case .began:
                stopScrollMomentum()
                accumulatedScrollY = 0
                
            case .changed:
                let deltaY = translation.y - accumulatedScrollY
                accumulatedScrollY = translation.y
                
                // Velocity-adaptive sensitivity - faster movement = slightly more responsive
                // This creates that "alive" feeling where the content follows your finger naturally
                let velocityFactor = 1.0 + min(abs(velocity) / 3000.0, 0.3)  // Up to 30% boost at high speed
                let effectiveSensitivity = touchScrollSensitivity * velocityFactor
                
                let scrollY = -deltaY * effectiveSensitivity
                let mods = makeScrollMods(precision: true, momentum: 3)
                ghostty_surface_mouse_scroll(surface, 0, Double(scrollY), mods)
                
                if scrollY < 0 {
                    isScrolledUp = true
                }
                
            case .ended, .cancelled:
                // Natural momentum - directly proportional to release velocity
                let momentumVelocity = -velocity * touchMomentumMultiplier
                if abs(momentumVelocity) > scrollMinVelocity {
                    startScrollMomentum(velocity: momentumVelocity)
                }
                accumulatedScrollY = 0
                
            default:
                break
            }
        }
        
        /// Track accumulated trackpad scroll
        private var accumulatedTrackpadScrollY: CGFloat = 0
        
        /// Handle trackpad/mouse wheel scrolling (Magic Keyboard, external mouse)
        /// This should feel snappier and more direct than touch scrolling
        @objc private func handleTrackpadScroll(_ gesture: UIPanGestureRecognizer) {
            guard let surface = surface else { return }
            
            let translation = gesture.translation(in: self)
            let velocity = gesture.velocity(in: self).y
            
            switch gesture.state {
            case .began:
                stopScrollMomentum()
                accumulatedTrackpadScrollY = 0
                
            case .changed:
                // Convert trackpad pan to scroll delta - always smooth for trackpad/mouse
                let deltaY = translation.y - accumulatedTrackpadScrollY
                accumulatedTrackpadScrollY = translation.y
                
                // Direct smooth scrolling - trackpad/mouse should feel immediate and responsive
                let scrollY = deltaY * trackpadScrollSensitivity
                let mods = makeScrollMods(precision: true, momentum: 3)
                ghostty_surface_mouse_scroll(surface, 0, Double(scrollY), mods)
                
                if scrollY > 0 {
                    isScrolledUp = true
                }
                
            case .ended, .cancelled:
                // Start momentum scrolling (natural direction)
                let momentumVelocity = velocity * trackpadMomentumMultiplier
                if abs(momentumVelocity) > scrollMinVelocity {
                    startScrollMomentum(velocity: momentumVelocity)
                }
                accumulatedTrackpadScrollY = 0
                
            default:
                break
            }
        }
        
        // MARK: - Momentum Scrolling
        
        /// Weak proxy target for CADisplayLink to avoid retain cycles.
        /// CADisplayLink strongly retains its target — using the SurfaceView directly
        /// creates a cycle: SurfaceView → displayLink → SurfaceView. This proxy
        /// holds a weak reference so the SurfaceView can be deallocated normally.
        private class DisplayLinkProxy {
            weak var target: SurfaceView?
            
            init(_ target: SurfaceView) {
                self.target = target
            }
            
            @objc func tick(_ displayLink: CADisplayLink) {
                if let target = target {
                    target.updateScrollMomentum()
                } else {
                    // Target was deallocated — clean up the display link
                    displayLink.invalidate()
                }
            }
        }
        
        private func startScrollMomentum(velocity: CGFloat) {
            guard abs(velocity) > scrollMinVelocity else { return }
            
            scrollVelocity = velocity
            initialMomentumVelocity = abs(velocity)
            momentumFrameCount = 0
            
            scrollDisplayLink?.invalidate()
            let proxy = DisplayLinkProxy(self)
            scrollDisplayLinkProxy = proxy
            scrollDisplayLink = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
            scrollDisplayLink?.add(to: .main, forMode: .common)
        }
        
        private func stopScrollMomentum() {
            scrollDisplayLink?.invalidate()
            scrollDisplayLink = nil
            scrollDisplayLinkProxy = nil
            scrollVelocity = 0
            initialMomentumVelocity = 0
            momentumFrameCount = 0
        }
        
        /// Scroll to the bottom of the terminal (return to prompt)
        /// This is called automatically when the user starts typing
        func scrollToBottom() {
            guard let surface = surface, isScrolledUp else { return }
            
            // Use Ghostty's built-in scroll_to_bottom binding action
            let action = "scroll_to_bottom"
            _ = action.withCString { cstr in
                ghostty_surface_binding_action(surface, cstr, UInt(action.utf8.count))
            }
            isScrolledUp = false
            stopScrollMomentum()
        }
        
        /// Track if momentum scrolling is active (for tap-to-stop)
        var isMomentumScrolling: Bool {
            scrollDisplayLink != nil
        }
        
        /// Immediately stop momentum scrolling when any touch begins
        /// Also handle mouse click for instant selection start
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            if isMomentumScrolling {
                stopScrollMomentum()
            }
            
            // Handle mouse click (indirect pointer) for instant selection start
            // This fires before the pan gesture recognizes, giving us immediate response
            if let touch = touches.first, touch.type == .indirectPointer, let surface = surface {
                let point = touch.location(in: self)
                let scale = contentScaleFactor
                let ghosttyX = point.x * scale
                let ghosttyY = point.y * scale
                
                isMouseSelecting = true
                isSelecting = true
                mouseClickPoint = point  // Remember where we clicked
                
                // Immediately send mouse press at click position
                ghostty_surface_mouse_pos(surface, ghosttyX, ghosttyY, GHOSTTY_MODS_NONE)
                _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
            }
            
            super.touchesBegan(touches, with: event)
        }
        
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            // Update mouse selection position during drag
            if isMouseSelecting, let touch = touches.first, touch.type == .indirectPointer, let surface = surface {
                let point = touch.location(in: self)
                let scale = contentScaleFactor
                ghostty_surface_mouse_pos(surface, point.x * scale, point.y * scale, GHOSTTY_MODS_NONE)
            }
            super.touchesMoved(touches, with: event)
        }
        
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            // Complete mouse selection on mouse release
            if isMouseSelecting, let touch = touches.first, touch.type == .indirectPointer, let surface = surface {
                let point = touch.location(in: self)
                let scale = contentScaleFactor
                ghostty_surface_mouse_pos(surface, point.x * scale, point.y * scale, GHOSTTY_MODS_NONE)
                _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
                isMouseSelecting = false
                isSelecting = false
                markJustFinishedSelecting()
                
                // Show selection overlay for mouse/trackpad selections too
                if ghostty_surface_has_selection(surface) {
                    selectionOverlay?.showSelection(menuSourcePoint: point)
                }
            }
            super.touchesEnded(touches, with: event)
        }
        
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            // Cancel mouse selection
            if isMouseSelecting, let touch = touches.first, touch.type == .indirectPointer, let surface = surface {
                let point = touch.location(in: self)
                let scale = contentScaleFactor
                ghostty_surface_mouse_pos(surface, point.x * scale, point.y * scale, GHOSTTY_MODS_NONE)
                _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
                isMouseSelecting = false
                isSelecting = false
            }
            super.touchesCancelled(touches, with: event)
        }
        
        /// Track where mouse was clicked (for determining if it was a click vs drag)
        private var mouseClickPoint: CGPoint = .zero
        
        private func updateScrollMomentum() {
            guard let surface = surface else {
                stopScrollMomentum()
                return
            }
            
            momentumFrameCount += 1
            
            // Dynamic deceleration based on initial velocity
            // Fast flicks coast longer (higher deceleration = slower decay)
            let velocityFactor = min(initialMomentumVelocity / 10.0, 1.0)
            let dynamicDeceleration = baseDeceleration + (maxDeceleration - baseDeceleration) * velocityFactor
            
            // Initial "kick" - first few frames maintain more velocity for tactile feel
            let kickFrames = 3
            let deceleration: CGFloat
            if momentumFrameCount <= kickFrames {
                // Minimal deceleration during kick phase
                deceleration = 0.995
            } else {
                deceleration = dynamicDeceleration
            }
            
            // Apply deceleration
            scrollVelocity *= deceleration
            
            // Stop if velocity is too low
            if abs(scrollVelocity) < scrollMinVelocity {
                // Send momentum ended
                let mods = makeScrollMods(precision: true, momentum: 4)  // 4 = ended
                ghostty_surface_mouse_scroll(surface, 0, 0, mods)
                stopScrollMomentum()
                return
            }
            
            // Apply scroll momentum with precision mode
            let mods = makeScrollMods(precision: true, momentum: 3)  // 3 = changed (momentum phase)
            ghostty_surface_mouse_scroll(surface, 0, Double(scrollVelocity), mods)
        }
        
        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            // Observer surfaces in multi-pane tmux mode: ALWAYS route to pane
            // selection. This MUST come before the justFinishedSelecting and
            // isMomentumScrolling guards because mouse/trackpad clicks set
            // justFinishedSelecting via touchesEnded (isMouseSelecting path)
            // before the tap gesture recognizer fires (~200-300ms delay).
            // Without this early return, pane switching is completely blocked
            // for mouse/trackpad users.
            //
            // Observer surfaces must NOT become firstResponder — their Zig
            // Termio has tmux_active=false, so keystrokes would bypass
            // send-keys wrapping and arrive as raw bytes on the tmux control
            // channel. The onPaneTap callback routes to selectPane(), which
            // sets the active pane on the primary surface instead.
            if isMultiPaneObserver {
                if let onPaneTap = onPaneTap {
                    Ghostty.logger.info("[handleTap] observer pane tapped, calling onPaneTap")
                    onPaneTap()
                } else {
                    Ghostty.logger.warning("[handleTap] observer pane tapped but onPaneTap is nil — pane selection will not work")
                }
                return
            }
            
            // Don't process tap if we just finished selecting (prevents clearing selection)
            if justFinishedSelecting {
                justFinishedSelecting = false
                // Re-present context menu when tapping near the selection
                selectionOverlay?.showSelection()
                return
            }
            
            // Tap to stop momentum scrolling (like hitting a spinning wheel to stop)
            if isMomentumScrolling {
                stopScrollMomentum()
                return
            }
            
            _ = becomeFirstResponder()
            
            // Hide selection overlay — a regular tap clears any existing selection
            // (Ghostty clears the selection on the next mouse click internally)
            selectionOverlay?.hideSelection()
            
            // In multi-pane mode, tapping the primary surface must also route
            // input back to the primary's pane. The onPaneTap callback (set by
            // TmuxMultiPaneView for all surfaces) calls selectPane() which
            // updates focusedPaneId and calls setActiveTmuxPaneInputOnly().
            // Without this, after tapping an observer pane, tapping back on the
            // primary just re-confirms firstResponder (no-op) but never restores
            // input routing to the primary's pane.
            if let onPaneTap = onPaneTap {
                Ghostty.logger.info("[handleTap] primary pane tapped in multi-pane mode, calling onPaneTap")
                onPaneTap()
                // #65: Return after pane routing to prevent the Ctrl+click block
                // below from firing on the wrong surface in multi-pane mode.
                return
            }
            
            // If Ctrl toggle is active, this tap should open a link
            if ctrlToggleActive, let surface = surface {
                let point = gesture.location(in: self)
                let scale = contentScaleFactor
                
                // Send mouse position and click with Ctrl modifier
                ghostty_surface_mouse_pos(surface, point.x * scale, point.y * scale, GHOSTTY_MODS_CTRL)
                _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_CTRL)
                _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_CTRL)
                
                // Reset Ctrl toggle
                ctrlToggleActive = false
                terminalAccessoryView?.resetCtrlState()
            }
        }
        
        /// Handle two-finger tap to open links (equivalent to Cmd+click on macOS)
        @objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
            guard let surface = surface else { return }
            
            // Get the midpoint of the two touches
            let point = gesture.location(in: self)
            let scale = contentScaleFactor
            
            // Send mouse position
            ghostty_surface_mouse_pos(surface, point.x * scale, point.y * scale, GHOSTTY_MODS_CTRL)
            
            // Send click with Ctrl modifier to trigger link opening
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_CTRL)
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_CTRL)
        }
        
        /// Handle double-tap for word selection
        @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let surface = surface else { return }
            
            let point = gesture.location(in: self)
            let scale = contentScaleFactor
            
            // Position the mouse
            ghostty_surface_mouse_pos(surface, point.x * scale, point.y * scale, GHOSTTY_MODS_NONE)
            
            // Double-click to select word
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
            
            // Provide haptic feedback
            hapticLight.impactOccurred()
            
            // Show selection overlay (handles + context menu)
            markJustFinishedSelecting()
            selectionOverlay?.showSelection(menuSourcePoint: point)
        }
        
        /// Handle triple-tap for line selection
        @objc private func handleTripleTap(_ gesture: UITapGestureRecognizer) {
            guard let surface = surface else { return }
            
            let point = gesture.location(in: self)
            let scale = contentScaleFactor
            
            // Position the mouse
            ghostty_surface_mouse_pos(surface, point.x * scale, point.y * scale, GHOSTTY_MODS_NONE)
            
            // Triple-click to select line
            for _ in 0..<3 {
                _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
                _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
            }
            
            // Provide haptic feedback
            hapticMedium.impactOccurred()
            
            // Show selection overlay (handles + context menu)
            markJustFinishedSelecting()
            selectionOverlay?.showSelection(menuSourcePoint: point)
        }
        
        /// Handle two-finger double-tap to reset font size
        @objc private func handleTwoFingerDoubleTap(_ gesture: UITapGestureRecognizer) {
            resetFontSize()
            
            // Provide haptic feedback
            hapticNotification.notificationOccurred(.success)
        }
        
        // MARK: - Frame Pacing (CADisplayLink → Ghostty draw_now)
        
        /// CADisplayLink for vsync-aligned frame presentation on iOS.
        /// Mirrors macOS CVDisplayLink → draw_now architecture: each display
        /// link tick calls ghostty_surface_draw_now() which notifies the
        /// renderer thread's draw_now async for immediate, non-coalescing frame
        /// draw. Supports ProMotion (up to 120Hz) via preferredFrameRateRange.
        private var frameDisplayLink: CADisplayLink?
        private var frameDisplayLinkProxy: FrameDisplayLinkProxy?
        
        /// Weak proxy target for CADisplayLink to avoid retain cycles.
        /// Same pattern as DisplayLinkProxy for scroll momentum.
        private class FrameDisplayLinkProxy {
            weak var target: SurfaceView?
            
            init(_ target: SurfaceView) {
                self.target = target
            }
            
            @objc func tick(_ displayLink: CADisplayLink) {
                if let target = target, let surface = target.surface {
                    ghostty_surface_draw_now(surface)
                } else {
                    // Target was deallocated — clean up
                    displayLink.invalidate()
                }
            }
        }
        
        /// Start the frame display link for vsync-aligned rendering.
        /// Called when the surface is added to a window and visible.
        private func startFrameDisplayLink() {
            guard frameDisplayLink == nil, surface != nil else { return }
            
            let proxy = FrameDisplayLinkProxy(self)
            frameDisplayLinkProxy = proxy
            let link = CADisplayLink(target: proxy, selector: #selector(FrameDisplayLinkProxy.tick))
            
            // ProMotion: request up to 120Hz on capable devices, minimum 60Hz
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: 60,
                maximum: 120,
                preferred: 120
            )
            
            link.add(to: .main, forMode: .common)
            frameDisplayLink = link
        }
        
        /// Stop the frame display link. Called on close, dealloc, or when
        /// removed from window.
        private func stopFrameDisplayLink() {
            frameDisplayLink?.invalidate()
            frameDisplayLink = nil
            frameDisplayLinkProxy = nil
        }
        
        // MARK: - UIGestureRecognizerDelegate
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // Allow hover to work simultaneously with other gestures
            if gestureRecognizer is UIHoverGestureRecognizer || otherGestureRecognizer is UIHoverGestureRecognizer {
                return true
            }
            // Allow pan and long press to recognize simultaneously initially
            // Long press will cancel pan if it triggers (via isSelecting flag)
            if gestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer is UILongPressGestureRecognizer {
                return true
            }
            if gestureRecognizer is UILongPressGestureRecognizer && otherGestureRecognizer is UIPanGestureRecognizer {
                return true
            }
            return false
        }
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // Pan should NOT wait for long press to fail - we handle conflicts via isSelecting
            return false
        }
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // Single-finger scroll should NOT receive indirect pointer (mouse/trackpad) touches
            // Mouse click-drag is handled via touchesBegan/Moved/Ended for selection
            if gestureRecognizer is UIPanGestureRecognizer {
                // Allow trackpad scroll gesture (0 touches) to work
                if let pan = gestureRecognizer as? UIPanGestureRecognizer,
                   pan.minimumNumberOfTouches == 0 {
                    return true
                }
                // Block other pan gestures from receiving mouse input
                if touch.type == .indirectPointer {
                    return false
                }
            }
            return true
        }

        /// Track if we're in selection mode (from long press or mouse drag)
        private var isSelecting = false
        
        /// Track when we just finished selecting (to prevent tap from clearing selection)
        private var justFinishedSelecting = false
        
        /// Timer to auto-reset justFinishedSelecting flag if no tap follows
        private var selectionResetTimer: Timer?
        
        /// Set justFinishedSelecting with automatic reset after 0.5s.
        /// This prevents the flag from remaining true indefinitely if no tap follows.
        private func markJustFinishedSelecting() {
            justFinishedSelecting = true
            selectionResetTimer?.invalidate()
            selectionResetTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                self?.justFinishedSelecting = false
            }
        }
        
        /// Track accumulated single-finger scroll
        private var accumulatedSingleFingerScrollY: CGFloat = 0
        
        /// Handle single-finger pan for scrolling - lifelike iOS-style physics
        @objc private func handleSingleFingerScroll(_ gesture: UIPanGestureRecognizer) {
            // Don't scroll if we're selecting text
            if isSelecting {
                return
            }
            guard let surface = surface else { return }
            
            let translation = gesture.translation(in: self)
            let velocity = gesture.velocity(in: self).y
            
            switch gesture.state {
            case .began:
                stopScrollMomentum()
                accumulatedSingleFingerScrollY = 0
                
            case .changed:
                let deltaY = translation.y - accumulatedSingleFingerScrollY
                accumulatedSingleFingerScrollY = translation.y
                
                // Velocity-adaptive sensitivity - faster movement = slightly more responsive
                let velocityFactor = 1.0 + min(abs(velocity) / 3000.0, 0.3)
                let effectiveSensitivity = touchScrollSensitivity * velocityFactor
                
                let scrollY = -deltaY * effectiveSensitivity
                let mods = makeScrollMods(precision: true, momentum: 3)
                ghostty_surface_mouse_scroll(surface, 0, Double(scrollY), mods)
                
                if scrollY < 0 {
                    isScrolledUp = true
                }
                
            case .ended, .cancelled:
                // Natural momentum - directly proportional to release velocity
                let momentumVelocity = -velocity * touchMomentumMultiplier
                if abs(momentumVelocity) > scrollMinVelocity {
                    startScrollMomentum(velocity: momentumVelocity)
                }
                accumulatedSingleFingerScrollY = 0
                
            default:
                break
            }
        }
        
        @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let surface = surface else { return }
            
            let point = gesture.location(in: self)
            let scale = contentScaleFactor
            let ghosttyX = point.x * scale
            let ghosttyY = point.y * scale
            
            switch gesture.state {
            case .began:
                isSelecting = true
                
                // Haptic feedback for selection start
                hapticMedium.impactOccurred()
                
                // Start selection (mouse button press)
                ghostty_surface_mouse_pos(surface, ghosttyX, ghosttyY, GHOSTTY_MODS_NONE)
                _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
                
            case .changed:
                if isSelecting {
                    // Update selection (drag with button held)
                    ghostty_surface_mouse_pos(surface, ghosttyX, ghosttyY, GHOSTTY_MODS_NONE)
                }
                
            case .ended:
                if isSelecting {
                    // End selection (release mouse button)
                    ghostty_surface_mouse_pos(surface, ghosttyX, ghosttyY, GHOSTTY_MODS_NONE)
                    _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
                    isSelecting = false
                    markJustFinishedSelecting()
                    
                    // Show selection overlay (handles + context menu)
                    selectionOverlay?.showSelection(menuSourcePoint: point)
                }
                
            case .cancelled, .failed:
                if isSelecting {
                    ghostty_surface_mouse_pos(surface, ghosttyX, ghosttyY, GHOSTTY_MODS_NONE)
                    _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
                    isSelecting = false
                }
                
            default:
                break
            }
        }
        
        /// Track if we're doing mouse-based selection (indirect pointer)
        private var isMouseSelecting = false
        
        /// Key repeat timer and state
        private var keyRepeatTimer: Timer?
        private var keyRepeatInitialDelayTimer: Timer?
        private var heldKeyEvent: Input.KeyEvent?
        private static let keyRepeatInitialDelay: TimeInterval = 0.4
        private static let keyRepeatInterval: TimeInterval = 0.05
        
        // MARK: - Edit Actions
        
        /// Override canPerformAction to enable copy/paste.
        /// Matches upstream macOS pattern: copy is always enabled (the binding
        /// action itself returns false if there's no selection), paste checks
        /// for clipboard content.
        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            // Prevent system "cut" action from intercepting Ctrl+X
            if action == #selector(UIResponderStandardEditActions.cut(_:)) {
                return false
            }
            if action == #selector(UIResponderStandardEditActions.copy(_:)) {
                // Always allow — matches macOS validateMenuItem default.
                // The binding action handles no-selection gracefully.
                return surface != nil
            }
            if action == #selector(UIResponderStandardEditActions.paste(_:)) {
                return UIPasteboard.general.hasStrings
            }
            return super.canPerformAction(action, withSender: sender)
        }
        
        /// Handle copy action — delegates to Ghostty's copy_to_clipboard binding
        /// action, which reads the selection, formats it, and calls the
        /// writeClipboard callback (which writes to UIPasteboard.general).
        /// This matches the upstream macOS pattern exactly.
        @objc override func copy(_ sender: Any?) {
            guard let surface = surface else {
                logger.warning("copy: surface is nil")
                return
            }
            let action = "copy_to_clipboard"
            if !ghostty_surface_binding_action(surface, action, UInt(action.utf8.count)) {
                logger.warning("copy: copy_to_clipboard action returned false (no selection?)")
            }
        }
        
        /// Handle paste action using Ghostty's paste_from_clipboard action
        /// This properly handles bracketed paste mode for tmux/vim
        @objc override func paste(_ sender: Any?) {
            guard let surface = surface else {
                logger.warning("paste: surface is nil, cannot paste")
                return
            }
            let action = "paste_from_clipboard"
            if !ghostty_surface_binding_action(surface, action, UInt(action.utf8.count)) {
                // Fallback to direct insertion if action fails
                if let text = UIPasteboard.general.string {
                    insertText(text)
                }
                logger.warning("paste_from_clipboard action failed, falling back to direct insert")
            } else {
                logger.debug("paste: via Ghostty (bracketed paste mode aware)")
            }
        }
        
        /// Select all text in the terminal scrollback
        func selectAll() {
            guard let surface = surface else { return }
            let action = "select_all"
            if !ghostty_surface_binding_action(surface, action, UInt(action.utf8.count)) {
                logger.warning("select_all action failed")
            }
        }
        
        // MARK: - Hardware Keyboard Support (UIResponder presses)
        
        /// Track current modifier state for Ctrl toggle button
        private var ctrlToggleActive = false
        /// #65: Track which presses had Ctrl injected so pressesEnded
        /// can emit matching release events with the Ctrl modifier.
        private var ctrlInjectedPresses = Set<ObjectIdentifier>()
        
        /// Set Ctrl toggle state (from toolbar button)
        func setCtrlToggle(_ active: Bool) {
            ctrlToggleActive = active
            
            // Haptic feedback when Ctrl toggle changes
            (active ? hapticMedium : hapticLight).impactOccurred()
        }
        
        /// Handle hardware keyboard key presses (Magic Keyboard, etc.)
        /// Uses proper Ghostty keyboard API for correct terminal encoding
        /// Implements Ghostty macOS keybindings for splits/tabs/windows
        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var handledPresses = Set<UIPress>()
            
            for press in presses {
                guard let uiKey = press.key else { continue }
                
                let hasCmd = uiKey.modifierFlags.contains(.command)
                let hasShift = uiKey.modifierFlags.contains(.shift)
                let hasOption = uiKey.modifierFlags.contains(.alternate)
                let hasCtrl = uiKey.modifierFlags.contains(.control)
                let char = uiKey.charactersIgnoringModifiers.lowercased()
                let keyCode = uiKey.keyCode
                
                // MARK: - Ghostty macOS Keybindings (via shortcutDelegate)
                
                if hasCmd, let delegate = shortcutDelegate {
                    var action: ShortcutAction? = nil
                    
                    // Split management
                    if char == "d" && !hasShift && !hasOption {
                        // Cmd+D - Split Right
                        action = .newSplitRight
                    } else if char == "d" && hasShift && !hasOption {
                        // Cmd+Shift+D - Split Down
                        action = .newSplitDown
                    } else if char == "[" && !hasShift && !hasOption {
                        // Cmd+[ - Previous Split
                        action = .gotoSplitPrevious
                    } else if char == "]" && !hasShift && !hasOption {
                        // Cmd+] - Next Split
                        action = .gotoSplitNext
                    } else if hasOption && !hasShift {
                        // Cmd+Option+Arrow - Navigate splits
                        if keyCode == .keyboardUpArrow {
                            action = .gotoSplitUp
                        } else if keyCode == .keyboardDownArrow {
                            action = .gotoSplitDown
                        } else if keyCode == .keyboardLeftArrow {
                            action = .gotoSplitLeft
                        } else if keyCode == .keyboardRightArrow {
                            action = .gotoSplitRight
                        }
                    } else if hasCtrl && char == "=" {
                        // Cmd+Ctrl+= - Equalize Splits
                        action = .equalizeSplits
                    } else if hasShift && keyCode == .keyboardReturnOrEnter {
                        // Cmd+Shift+Enter - Toggle Split Zoom
                        action = .toggleSplitZoom
                    }
                    
                    // Tab management
                    else if char == "[" && hasShift {
                        // Cmd+Shift+[ - Previous Tab
                        action = .previousTab
                    } else if char == "]" && hasShift {
                        // Cmd+Shift+] - Next Tab
                        action = .nextTab
                    } else if char == "t" && !hasShift {
                        // Cmd+T - New Tab (tmux window)
                        action = .newTab
                    } else if char == "9" {
                        // Cmd+9 - Last Tab
                        action = .lastTab
                    } else if let digit = Int(char), digit >= 1 && digit <= 8 {
                        // Cmd+1-8 - Go to tab N
                        action = .gotoTab(digit)
                    }
                    
                    // Window management (close)
                    // Note: Cmd+Option+W conflicts with iPadOS system shortcut (quits app)
                    // Note: Cmd+W (closeSurface) is handled by SwiftUI menu for disconnect
                    // Using Cmd+Shift+W for close window/tab instead
                    else if char == "w" && hasShift && !hasOption {
                        // Cmd+Shift+W - Close current tmux window
                        action = .closeWindow
                    }
                    
                    // Connection management
                    else if char == "r" && !hasShift && !hasOption {
                        // Cmd+R - Reconnect to SSH/tmux
                        action = .reconnect
                    }
                    
                    // Window rename
                    else if char == "r" && hasShift && !hasOption {
                        // Cmd+Shift+R - Rename tmux window
                        action = .renameWindow
                    }
                    
                    // Session management
                    else if char == "s" && hasShift && !hasOption {
                        // Cmd+Shift+S - Show tmux session picker
                        action = .showSessions
                    }
                    
                    // If we have an action, try to handle it
                    if let action = action {
                        if delegate.handleShortcut(action) {
                            // Action was handled, don't process further
                            handledPresses.insert(press)
                            continue
                        }
                    }
                }
                
                // MARK: - Local Ghostty Shortcuts (font size, clear screen, jump to prompt)
                
                // Cmd+Shift+Up/Down or Cmd+Up/Down — Jump to Prompt
                // Requires shell integration (OSC 133) on the remote host.
                // Matches upstream Ghostty defaults for jump_to_prompt.
                if hasCmd && !hasOption && !hasCtrl {
                    if keyCode == .keyboardUpArrow {
                        if let surface = surface {
                            let action = "jump_to_prompt:-1"
                            _ = action.withCString { cstr in
                                ghostty_surface_binding_action(surface, cstr, UInt(action.utf8.count))
                            }
                        }
                        handledPresses.insert(press)
                        continue
                    } else if keyCode == .keyboardDownArrow {
                        if let surface = surface {
                            let action = "jump_to_prompt:1"
                            _ = action.withCString { cstr in
                                ghostty_surface_binding_action(surface, cstr, UInt(action.utf8.count))
                            }
                        }
                        handledPresses.insert(press)
                        continue
                    }
                }
                
                if hasCmd {
                    switch char {
                    case "k":
                        // Cmd+K - Clear Screen (via Ghostty binding action)
                        if let surface = surface {
                            let action = "clear_screen"
                            _ = action.withCString { cstr in
                                ghostty_surface_binding_action(surface, cstr, UInt(action.utf8.count))
                            }
                        }
                        handledPresses.insert(press)
                        continue
                    case "0":
                        // Cmd+0 - Reset Font Size
                        resetFontSize()
                        handledPresses.insert(press)
                        continue
                    case "+", "=":
                        // Cmd++ - Increase Font Size
                        if !hasShift {
                            increaseFontSize()
                            handledPresses.insert(press)
                            continue
                        }
                    case "-":
                        // Cmd+- - Decrease Font Size
                        decreaseFontSize()
                        handledPresses.insert(press)
                        continue
                    case "p":
                        // Cmd+Shift+P - Toggle Command Palette
                        if hasShift {
                            NotificationCenter.default.post(name: .toggleCommandPalette, object: nil)
                            handledPresses.insert(press)
                            continue
                        }
                    case "c", "v", "a", "f", "g", "w", "n", ",":
                        // These are handled by SwiftUI menu system / UIKeyCommand - let them pass through
                        // Copy, Paste, Select All, Find, Find Next, Disconnect, New Connection, Preferences
                        // Don't mark as handled — will be passed to super below
                        continue
                    default:
                        break
                    }
                }
                
                // MARK: - Terminal Input (via Ghostty API)
                
                guard let surface = surface else { continue }
                
                // Add Ctrl toggle state to modifiers if active
                var modFlags = uiKey.modifierFlags
                if ctrlToggleActive {
                    modFlags.insert(.control)
                    ctrlToggleActive = false  // Clear after use
                    terminalAccessoryView?.resetCtrlState()
                    // #65: Track this press so pressesEnded can emit a matching
                    // release event with the Ctrl modifier included.
                    ctrlInjectedPresses.insert(ObjectIdentifier(press))
                }
                
                // Create the key event using Ghostty Input types
                if let keyEvent = Input.KeyEvent(press: press, action: .press) {
                    // If Ctrl toggle was active, we need to add it to the mods
                    var mods = keyEvent.mods
                    if modFlags.contains(.control) && !uiKey.modifierFlags.contains(.control) {
                        mods.insert(.ctrl)
                    }
                    
                    let finalEvent = Input.KeyEvent(
                        key: keyEvent.key,
                        action: .press,
                        text: keyEvent.text,
                        composing: keyEvent.composing,
                        mods: mods,
                        consumedMods: keyEvent.consumedMods,
                        unshiftedCodepoint: keyEvent.unshiftedCodepoint
                    )
                    
                    // Send via Ghostty API - Ghostty handles all escape sequence encoding
                    finalEvent.withCValue { cEvent in
                        _ = ghostty_surface_key(surface, cEvent)
                    }
                    
                    // Start key repeat timer
                    startKeyRepeat(for: finalEvent)
                    handledPresses.insert(press)
                    continue
                }
            }
            
            // Pass unhandled keys to super (system shortcuts, etc.)
            let unhandled = presses.subtracting(handledPresses)
            if !unhandled.isEmpty {
                super.pressesBegan(unhandled, with: event)
            }
        }
        
        /// Start key repeat after initial delay
        private func startKeyRepeat(for keyEvent: Input.KeyEvent) {
            stopKeyRepeat()
            
            heldKeyEvent = Input.KeyEvent(
                key: keyEvent.key,
                action: .repeat,
                text: keyEvent.text,
                composing: keyEvent.composing,
                mods: keyEvent.mods,
                consumedMods: keyEvent.consumedMods,
                unshiftedCodepoint: keyEvent.unshiftedCodepoint
            )
            
            keyRepeatInitialDelayTimer = Timer.scheduledTimer(withTimeInterval: Self.keyRepeatInitialDelay, repeats: false) { [weak self] _ in
                self?.keyRepeatTimer = Timer.scheduledTimer(withTimeInterval: Self.keyRepeatInterval, repeats: true) { [weak self] _ in
                    guard let self = self, let surface = self.surface, let event = self.heldKeyEvent else { return }
                    event.withCValue { cEvent in
                        _ = ghostty_surface_key(surface, cEvent)
                    }
                }
            }
        }
        
        /// Stop key repeat
        private func stopKeyRepeat() {
            keyRepeatInitialDelayTimer?.invalidate()
            keyRepeatInitialDelayTimer = nil
            keyRepeatTimer?.invalidate()
            keyRepeatTimer = nil
            heldKeyEvent = nil
        }
        
        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            stopKeyRepeat()
            
            for press in presses {
                guard let surface = surface else { continue }
                if var keyEvent = Input.KeyEvent(press: press, action: .release) {
                    // #65: If this press had Ctrl injected in pressesBegan,
                    // add Ctrl to the release event so modifiers match.
                    let pressId = ObjectIdentifier(press)
                    if ctrlInjectedPresses.remove(pressId) != nil {
                        keyEvent = Input.KeyEvent(
                            key: keyEvent.key,
                            action: .release,
                            text: keyEvent.text,
                            composing: keyEvent.composing,
                            mods: keyEvent.mods.union(.ctrl),
                            consumedMods: keyEvent.consumedMods,
                            unshiftedCodepoint: keyEvent.unshiftedCodepoint
                        )
                    }
                    keyEvent.withCValue { cEvent in
                        _ = ghostty_surface_key(surface, cEvent)
                    }
                }
            }
            super.pressesEnded(presses, with: event)
        }
        
        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            stopKeyRepeat()
            super.pressesCancelled(presses, with: event)
        }
        
        /// C callback for external backend write operations
        /// This is called when the terminal wants to send data (user keyboard input)
        private static let externalWriteCallback: ghostty_write_callback_fn = { surface, data, len in
            // Get the SurfaceView from userdata
            guard let surface = surface,
                  let userdata = ghostty_surface_userdata(surface) else {
                Ghostty.logger.warning("⚠️ externalWriteCallback: surface or userdata is nil")
                return
            }
            
            let surfaceView = Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
            
            // Copy data immediately — it may be freed after this callback returns
            guard let data = data, len > 0 else { return }
            let swiftData = Data(bytes: data, count: Int(len))
            
            // Dispatch to main thread where we can safely check surface liveness
            // The surface nil check must be inside the main dispatch block (C2 fix):
            // checking on the IO thread is a TOCTOU race — surface can be freed between
            // the check here and the actual use on main.
            DispatchQueue.main.async {
                guard surfaceView.surface != nil else { return }
                surfaceView.onWrite?(swiftData)
            }
        }
        
        /// C callback for external backend resize operations.
        /// This is called from the IO thread when the terminal grid size changes.
        /// The External backend invokes this during its resize() method, making
        /// the backend self-contained (same pattern as Exec backend's PTY ioctl).
        private static let externalResizeCallback: ghostty_resize_callback_fn = { surface, cols, rows, widthPx, heightPx in
            _ = widthPx
            _ = heightPx
            
            guard let surface = surface,
                  let userdata = ghostty_surface_userdata(surface) else {
                Ghostty.logger.warning("externalResizeCallback: surface or userdata is nil")
                return
            }
            
            let surfaceView = Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
            let colsInt = Int(cols)
            let rowsInt = Int(rows)
            
            // Dispatch to main thread where we can safely check surface liveness
            // (C2 fix: surface nil check must be inside main dispatch to avoid TOCTOU race)
            DispatchQueue.main.async {
                guard surfaceView.surface != nil else { return }
                surfaceView.onResize?(colsInt, rowsInt)
            }
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }
        
        deinit {
            // Assert that close() was called before deinit — surface should already
            // be freed synchronously on the main thread. If this fires, we have a
            // code path that drops SurfaceView without calling close() first.
            assert(surface == nil, "SurfaceView.deinit reached with live surface — close() was not called")
            
            // Remove notification observers
            NotificationCenter.default.removeObserver(self)
            
            // Stop all timers and subscriptions (safety net if close() wasn't called)
            stopKeyRepeat()
            stopFrameDisplayLink()
            scrollIndicatorHideTimer?.invalidate()
            searchNeedleCancellable = nil
            
            // Clear callbacks to prevent invocations during/after free
            onWrite = nil
            onResize = nil
            
            // deinit is not guaranteed to happen on the main actor and our API
            // calls into libghostty must happen there. Capture the surface handle
            // so we don't capture `self`, then dispatch the free to main actor.
            // This matches upstream Ghostty's Ghostty.Surface.deinit pattern.
            guard let surface = surface else { return }
            self.surface = nil
            Task.detached { @MainActor in
                ghostty_surface_free(surface)
            }
        }
        
        /// Explicitly close and release the surface.
        /// Must be called on the main thread.
        func close() {
            assert(Thread.isMainThread, "close() must be called on the main thread")
            guard let surface = surface else { return }
            
            // Invalidate the display link to break the retain cycle
            // (CADisplayLink strongly retains its target via proxy)
            stopScrollMomentum()
            stopFrameDisplayLink()
            selectionResetTimer?.invalidate()
            selectionResetTimer = nil
            
            // Stop key repeat timers (repeating timer would fire indefinitely)
            stopKeyRepeat()
            
            // Invalidate scroll indicator hide timer
            scrollIndicatorHideTimer?.invalidate()
            scrollIndicatorHideTimer = nil
            
            // Cancel search subscription to break Combine pipeline references
            searchNeedleCancellable = nil
            
            // Clear callbacks to prevent invocations during/after free
            onWrite = nil
            onResize = nil
            
            // Free the surface — this must happen on main thread
            ghostty_surface_free(surface)
            self.surface = nil
        }
        
        // MARK: - Surface API
        
        /// Feed data to the terminal for display (e.g., from SSH)
        /// This uses ghostty_surface_write_output which feeds data directly to the
        /// terminal emulator as if it came from a subprocess/PTY output.
        func feedData(_ data: Data) {
            guard let surface = surface else { return }
            
            data.withUnsafeBytes { buffer in
                guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
                ghostty_surface_write_output(surface, ptr, UInt(data.count))
            }
        }
        
        /// Feed a string to the terminal for display
        func feedText(_ text: String) {
            guard let data = text.data(using: .utf8) else { return }
            feedData(data)
        }
        
        /// Set preedit (composition preview) text at cursor position
        /// This shows temporary text that renders inverted (fg/bg swapped)
        /// Pass empty string or nil to clear the preedit
        func setPreedit(_ text: String?) {
            guard let surface = surface else { return }
            
            if let text = text, !text.isEmpty {
                text.withCString { ptr in
                    ghostty_surface_preedit(surface, ptr, UInt(text.utf8.count))
                }
            } else {
                // Clear preedit by passing empty
                ghostty_surface_preedit(surface, nil, 0)
            }
        }
        
        /// Virtual key codes for toolbar buttons (macOS-style keycodes)
        enum VirtualKey: UInt32 {
            case escape = 0x35
            case tab = 0x30
            case enter = 0x24
            case delete = 0x33  // Backspace
            case upArrow = 0x7E
            case downArrow = 0x7D
            case leftArrow = 0x7B
            case rightArrow = 0x7C
            case home = 0x73
            case end = 0x77
            case pageUp = 0x74
            case pageDown = 0x79
        }
        
        /// Send a virtual key through Ghostty's key encoding
        /// This ensures proper handling of application cursor mode for tmux, etc.
        func sendVirtualKey(_ key: VirtualKey, mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE) {
            guard let surface = surface else { return }
            
            // Map VirtualKey to Input.Key
            let ghosttyKey: Input.Key
            switch key {
            case .escape: ghosttyKey = .escape
            case .tab: ghosttyKey = .tab
            case .enter: ghosttyKey = .enter
            case .delete: ghosttyKey = .backspace
            case .upArrow: ghosttyKey = .arrowUp
            case .downArrow: ghosttyKey = .arrowDown
            case .leftArrow: ghosttyKey = .arrowLeft
            case .rightArrow: ghosttyKey = .arrowRight
            case .home: ghosttyKey = .home
            case .end: ghosttyKey = .end
            case .pageUp: ghosttyKey = .pageUp
            case .pageDown: ghosttyKey = .pageDown
            }
            
            // Send press event using proper Input.KeyEvent
            let pressEvent = Input.KeyEvent(
                key: ghosttyKey,
                action: .press,
                mods: Input.Mods(cMods: mods)
            )
            pressEvent.withCValue { cEvent in
                _ = ghostty_surface_key(surface, cEvent)
            }
            
            // Send release event
            let releaseEvent = Input.KeyEvent(
                key: ghosttyKey,
                action: .release,
                mods: Input.Mods(cMods: mods)
            )
            releaseEvent.withCValue { cEvent in
                _ = ghostty_surface_key(surface, cEvent)
            }
        }
        
        /// Send text input to the terminal (user typing)
        func sendText(_ text: String) {
            guard let surface = surface else { return }
            
            let len = text.utf8CString.count
            guard len > 0 else { return }
            
            text.withCString { ptr in
                // len includes null terminator, so use len - 1
                ghostty_surface_text(surface, ptr, UInt(len - 1))
            }
        }
        
        /// Notify focus change
        func focusDidChange(_ focused: Bool) {
            guard let surface = surface else { return }
            self.hasFocusState = focused
            
            ghostty_surface_set_focus(surface, focused)
            
            if focused {
                focusInstant = ContinuousClock.now
            }
        }
        
        // MARK: - First Responder & Keyboard
        
        override var canBecomeFirstResponder: Bool { !isMultiPaneObserver }
        
        override var keyCommands: [UIKeyCommand]? {
            [
                UIKeyCommand(action: #selector(copy(_:)), input: "c", modifierFlags: .command),
                UIKeyCommand(action: #selector(paste(_:)), input: "v", modifierFlags: .command),
            ]
        }
        
        /// Symbols bar displayed above the software keyboard.
        /// Returns `nil` when no software keyboard is visible so the
        /// accessory bar doesn't float at the screen bottom on iPad with
        /// a hardware keyboard. (#44 Bug 2 regression fix)
        override var inputAccessoryView: UIView? {
            softwareKeyboardVisible ? terminalAccessoryView : nil
        }
        
        /// Map accessory view button tags to VirtualKey values.
        private static func virtualKeyForTag(_ tag: Int) -> VirtualKey? {
            switch tag {
            case TerminalAccessoryView.vkEscape: return .escape
            case TerminalAccessoryView.vkTab:    return .tab
            case TerminalAccessoryView.vkUp:     return .upArrow
            case TerminalAccessoryView.vkDown:   return .downArrow
            case TerminalAccessoryView.vkLeft:   return .leftArrow
            case TerminalAccessoryView.vkRight:  return .rightArrow
            default: return nil
            }
        }
        
        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            if result {
                focusDidChange(true)
            }
            return result
        }
        
        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            if result {
                focusDidChange(false)
                // Reset software keyboard tracking — keyboard hides on resign.
                softwareKeyboardVisible = false
                // #65: Clear Ctrl toggle when keyboard dismisses so it doesn't
                // persist and unexpectedly modify the next keypress.
                ctrlToggleActive = false
                ctrlInjectedPresses.removeAll()
                terminalAccessoryView?.resetCtrlState()
            }
            return result
        }
        
        // MARK: - Visibility/Occlusion
        
        /// Set surface visibility for performance optimization
        func setVisible(_ visible: Bool) {
            guard let surface = surface else { return }
            ghostty_surface_set_occlusion(surface, !visible)
        }
        
        // MARK: - tmux Control Mode API
        
        /// Check if the surface is in tmux control mode (has any panes)
        var isTmuxActive: Bool {
            guard let surface = surface else { return false }
            return ghostty_surface_tmux_pane_count(surface) > 0
        }
        
        /// Get the number of tmux panes (0 if not in tmux mode)
        var tmuxPaneCount: Int {
            guard let surface = surface else { return 0 }
            return Int(ghostty_surface_tmux_pane_count(surface))
        }
        
        /// Get the IDs of all tmux panes
        func getTmuxPaneIds() -> [Int] {
            guard let surface = surface else { return [] }
            
            let count = ghostty_surface_tmux_pane_count(surface)
            guard count > 0 else { return [] }
            
            var paneIds = [UInt](repeating: 0, count: Int(count))
            let written = ghostty_surface_tmux_pane_ids(surface, &paneIds, count)
            
            return paneIds.prefix(Int(written)).map { Int($0) }
        }
        
        /// Set which tmux pane this surface renders AND routes input to.
        /// Swaps renderer_state.terminal to the pane's terminal.
        /// Returns true if successful, false if pane_id not found or not in tmux mode
        @discardableResult
        func setActiveTmuxPane(_ paneId: Int) -> Bool {
            guard let surface = surface else {
                logger.warning("setActiveTmuxPane: surface is nil")
                return false
            }
            let result = ghostty_surface_tmux_set_active_pane(surface, paneId)
            logger.debug("setActiveTmuxPane(\(paneId)): result=\(result)")
            return result
        }
        
        /// Set which tmux pane receives input (send-keys) WITHOUT swapping the renderer.
        /// Used in multi-surface mode where each pane has its own observer surface.
        /// Returns true if successful, false if pane_id not found or not in tmux mode
        @discardableResult
        func setActiveTmuxPaneInputOnly(_ paneId: Int) -> Bool {
            guard let surface = surface else {
                logger.warning("setActiveTmuxPaneInputOnly: surface is nil")
                return false
            }
            let result = ghostty_surface_tmux_set_active_pane_input_only(surface, paneId)
            logger.debug("setActiveTmuxPaneInputOnly(\(paneId)): result=\(result)")
            return result
        }
        
        /// Reset to render the main terminal (exit pane-specific view)
        func resetActiveTmuxPane() {
            guard let surface = surface else { return }
            ghostty_surface_tmux_reset_active_pane(surface)
        }
        
        // MARK: - tmux Multi-Pane Binding
        
        /// Bind this surface's renderer to a tmux pane terminal owned by
        /// a source surface's tmux viewer. After attachment, this surface
        /// renders the pane's content using the source's shared mutex.
        ///
        /// - Parameters:
        ///   - source: The primary surface whose tmux viewer owns the pane.
        ///   - paneId: The numeric tmux pane ID to bind to.
        /// - Returns: `true` if binding succeeded.
        @discardableResult
        func attachToTmuxPane(source: SurfaceView, paneId: Int) -> Bool {
            guard let targetSurface = surface,
                  let sourceSurface = source.surface else {
                logger.warning("attachToTmuxPane: surface(s) nil")
                return false
            }
            let result = ghostty_surface_tmux_attach_to_pane(targetSurface, sourceSurface, paneId)
            if result {
                isMultiPaneObserver = true
                
                // If this surface was firstResponder (e.g., it was the direct
                // surface before multi-pane mode activated), resign now.
                // canBecomeFirstResponder returning false prevents future focus
                // acquisition, but doesn't auto-resign an existing responder.
                if isFirstResponder {
                    _ = resignFirstResponder()
                }
                
                // Strip observer down to minimal gestures. Observers are
                // display-only mirrors — they don't need selection, scrolling,
                // or text editing gestures. They keep:
                //   1. Single-tap for pane switching (handleTap → onPaneTap)
                //   2. Pinch for per-pane font size zoom (handlePinch)
                //   3. Two-finger double-tap for font size reset (handleTwoFingerDoubleTap)
                //
                // Pinch and font-reset gestures call ghostty_surface_binding_action
                // directly on self.surface — they don't need keyboard focus and
                // don't interfere with the input routing system.
                //
                // NOTE: If we later implement pane promotion (swapping which
                // surface is primary), the promotion logic should restore the
                // full gesture suite.
                gestureRecognizers?.forEach { removeGestureRecognizer($0) }
                
                let paneTapGesture = UITapGestureRecognizer(
                    target: self, action: #selector(handleTap(_:)))
                addGestureRecognizer(paneTapGesture)
                
                // Pinch-to-zoom: per-pane font size adjustment. Each observer
                // surface has independent font_size state in Ghostty's Surface
                // struct — SharedGridSet is ref-counted, not shared mutable.
                let pinchGesture = UIPinchGestureRecognizer(
                    target: self, action: #selector(handlePinch(_:)))
                addGestureRecognizer(pinchGesture)
                
                // Two-finger double-tap: reset font size to config default.
                let twoFingerDoubleTapGesture = UITapGestureRecognizer(
                    target: self, action: #selector(handleTwoFingerDoubleTap(_:)))
                twoFingerDoubleTapGesture.numberOfTouchesRequired = 2
                twoFingerDoubleTapGesture.numberOfTapsRequired = 2
                addGestureRecognizer(twoFingerDoubleTapGesture)
            }
            logger.debug("attachToTmuxPane(pane=\(paneId)): result=\(result)")
            return result
        }
        
        /// Detach this surface from its tmux pane binding. Restores the
        /// original mutex and terminal pointer. No-op if not attached.
        func detachTmuxPane() {
            guard let surface = surface else { return }
            ghostty_surface_tmux_detach_pane(surface)
            isMultiPaneObserver = false
            onPaneTap = nil
            logger.debug("detachTmuxPane: complete")
        }
        
        /// Promote this observer surface to primary status.
        ///
        /// Reverses the Swift-level effects of attachToTmuxPane() WITHOUT calling
        /// ghostty_surface_tmux_detach_pane(). The Zig-level tmux_pane_binding must
        /// stay intact — the promoted surface still renders via the shared mutex
        /// and pane terminal pointer. Only the Swift flags and gesture suite change.
        ///
        /// Call this when the primary surface's pane closes and an observer is
        /// elected as the new primarySurface.
        func promoteFromObserver() {
            guard isMultiPaneObserver else {
                logger.warning("promoteFromObserver: surface is not an observer, skipping")
                return
            }
            
            // 1. Clear observer flag so canBecomeFirstResponder returns true
            isMultiPaneObserver = false
            
            // 2. Restore the full gesture suite (mirrors init gesture setup)
            gestureRecognizers?.forEach { removeGestureRecognizer($0) }
            
            let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            addGestureRecognizer(tapGesture)
            
            let doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            doubleTapGesture.numberOfTapsRequired = 2
            addGestureRecognizer(doubleTapGesture)
            tapGesture.require(toFail: doubleTapGesture)
            
            let tripleTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTripleTap(_:)))
            tripleTapGesture.numberOfTapsRequired = 3
            addGestureRecognizer(tripleTapGesture)
            doubleTapGesture.require(toFail: tripleTapGesture)
            
            let twoFingerTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
            twoFingerTapGesture.numberOfTouchesRequired = 2
            addGestureRecognizer(twoFingerTapGesture)
            
            let twoFingerDoubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerDoubleTap(_:)))
            twoFingerDoubleTapGesture.numberOfTouchesRequired = 2
            twoFingerDoubleTapGesture.numberOfTapsRequired = 2
            addGestureRecognizer(twoFingerDoubleTapGesture)
            twoFingerTapGesture.require(toFail: twoFingerDoubleTapGesture)
            
            let longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            longPressGesture.minimumPressDuration = 0.3
            longPressGesture.delegate = self
            addGestureRecognizer(longPressGesture)
            
            let singleFingerScrollGesture = UIPanGestureRecognizer(target: self, action: #selector(handleSingleFingerScroll(_:)))
            singleFingerScrollGesture.minimumNumberOfTouches = 1
            singleFingerScrollGesture.maximumNumberOfTouches = 1
            singleFingerScrollGesture.delegate = self
            addGestureRecognizer(singleFingerScrollGesture)
            
            let twoFingerScrollGesture = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
            twoFingerScrollGesture.minimumNumberOfTouches = 2
            twoFingerScrollGesture.maximumNumberOfTouches = 2
            addGestureRecognizer(twoFingerScrollGesture)
            
            let trackpadScrollGesture = UIPanGestureRecognizer(target: self, action: #selector(handleTrackpadScroll(_:)))
            trackpadScrollGesture.allowedScrollTypesMask = [.continuous, .discrete]
            trackpadScrollGesture.minimumNumberOfTouches = 0
            trackpadScrollGesture.maximumNumberOfTouches = 0
            addGestureRecognizer(trackpadScrollGesture)
            
            let hoverGesture = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
            addGestureRecognizer(hoverGesture)
            
            let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            addGestureRecognizer(pinchGesture)
            
            let pointerInteraction = UIPointerInteraction(delegate: self)
            addInteraction(pointerInteraction)
            
            logger.info("promoteFromObserver: observer promoted to primary (gestures restored, canBecomeFirstResponder=true)")
        }
        
        // MARK: - tmux Window API
        
        /// Get the number of tmux windows (0 if not in tmux mode)
        var tmuxWindowCount: Int {
            guard let surface = surface else { return 0 }
            return Int(ghostty_surface_tmux_window_count(surface))
        }
        
        /// Info about a tmux window returned from the C API.
        /// Uses the top-level TmuxWindowInfo struct (defined in TmuxSurfaceProtocol.swift)
        /// to decouple data from the UIView class and enable protocol conformance.
        
        /// Get info about a tmux window by index.
        /// Returns nil only if index is out of bounds or not in tmux mode.
        /// Note: window @0 is valid — we distinguish "no window" by checking
        /// that ALL fields are zero (which can't happen for a real window since
        /// width/height are always > 0 in tmux).
        func getTmuxWindowInfo(at index: Int) -> TmuxWindowInfo? {
            guard let surface = surface else { return nil }
            
            // 256 bytes is plenty for a window name
            var nameBuf = [UInt8](repeating: 0, count: 256)
            let info = ghostty_surface_tmux_window_info(
                surface,
                index,
                &nameBuf,
                nameBuf.count
            )
            
            // Zeroed struct means out of bounds or not in tmux mode.
            // A real window always has width > 0 and height > 0.
            guard info.width > 0 || info.height > 0 else {
                return nil
            }
            
            let copyLen = min(Int(info.name_len), nameBuf.count)
            let name = String(bytes: nameBuf.prefix(copyLen), encoding: .utf8) ?? ""
            
            return TmuxWindowInfo(
                id: Int(info.id),
                width: Int(info.width),
                height: Int(info.height),
                name: name
            )
        }
        
        /// Get all tmux window infos
        func getAllTmuxWindows() -> [TmuxWindowInfo] {
            let count = tmuxWindowCount
            guard count > 0 else { return [] }
            
            var windows: [TmuxWindowInfo] = []
            for i in 0..<count {
                if let info = getTmuxWindowInfo(at: i) {
                    windows.append(info)
                }
            }
            return windows
        }
        
        /// Get the raw tmux layout string for a window by index
        func getTmuxWindowLayout(at index: Int) -> String? {
            guard let surface = surface else { return nil }
            
            // Layout strings are typically under 1KB even for complex layouts
            var buf = [UInt8](repeating: 0, count: 4096)
            let actualLen = ghostty_surface_tmux_window_layout(
                surface,
                index,
                &buf,
                buf.count
            )
            
            guard actualLen > 0 else { return nil }
            
            let copyLen = min(Int(actualLen), buf.count)
            return String(bytes: buf.prefix(copyLen), encoding: .utf8)
        }
        
        /// Get the active tmux window ID (-1 if none)
        var tmuxActiveWindowId: Int {
            guard let surface = surface else { return -1 }
            return Int(ghostty_surface_tmux_active_window_id(surface))
        }
        
        /// Get the focused pane ID for a tmux window by index.
        /// This is the pane tmux considers focused (from %window-pane-changed),
        /// not the apprt-set active pane used for input routing.
        /// Returns -1 if index out of bounds or no focus known.
        func tmuxWindowFocusedPaneId(at index: Int) -> Int {
            guard let surface = surface else { return -1 }
            return Int(ghostty_surface_tmux_window_focused_pane_id(surface, index))
        }
        
        /// Send a tmux command through the viewer's command queue.
        /// The response arrives asynchronously via GHOSTTY_ACTION_TMUX_COMMAND_RESPONSE.
        /// Returns true if the command was queued successfully.
        @discardableResult
        func sendTmuxCommand(_ command: String) -> Bool {
            guard let surface = surface else { return false }
            return command.withCString { ptr in
                ghostty_surface_tmux_send_command(surface, ptr, command.utf8.count)
            }
        }
        
        // MARK: - Search
        
        /// Start a search (opens UI, Ghostty will callback with START_SEARCH action)
        func startSearch() {
            guard let surface = surface else { return }
            let action = "start_search"
            ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
        }
        
        /// Navigate to next search result (iOS ScreenSearch-based sync API with autoscroll)
        func searchNext() {
            assert(Thread.isMainThread, "searchNext must run on main thread")
            guard let surface = surface else { return }
            guard searchState != nil else { return }
            
            let result = ghostty_surface_search_next(surface)
            if result.success {
                self.searchState?.selected = result.selected >= 0 ? UInt(result.selected) : nil
            }
        }
        
        /// Navigate to previous search result (iOS ScreenSearch-based sync API with autoscroll)
        func searchPrevious() {
            assert(Thread.isMainThread, "searchPrevious must run on main thread")
            guard let surface = surface else { return }
            guard searchState != nil else { return }
            
            let result = ghostty_surface_search_prev(surface)
            if result.success {
                self.searchState?.selected = result.selected >= 0 ? UInt(result.selected) : nil
            }
        }
        
        // MARK: - Font Size / Zoom
        
        /// Increase font size by delta points
        func increaseFontSize(_ delta: Float = 1.0) {
            guard let surface = surface else { return }
            let action = "increase_font_size:\(delta)"
            if ghostty_surface_binding_action(surface, action, UInt(action.utf8.count)) {
                currentFontSize = min(currentFontSize + delta, Self.maxFontSize)
                logger.info("🔍 Font size increased to \(currentFontSize)")
            }
        }
        
        /// Decrease font size by delta points
        func decreaseFontSize(_ delta: Float = 1.0) {
            guard let surface = surface else { return }
            let action = "decrease_font_size:\(delta)"
            if ghostty_surface_binding_action(surface, action, UInt(action.utf8.count)) {
                currentFontSize = max(currentFontSize - delta, Self.minFontSize)
                logger.info("🔍 Font size decreased to \(currentFontSize)")
            }
        }
        
        /// Reset font size to default
        func resetFontSize() {
            guard let surface = surface else { return }
            let action = "reset_font_size"
            if ghostty_surface_binding_action(surface, action, UInt(action.utf8.count)) {
                currentFontSize = Self.defaultFontSize
                logger.info("🔍 Font size reset to \(currentFontSize)")
            }
        }
        
        /// Set font size to a specific value
        func setFontSize(_ newSize: Float) {
            guard let surface = surface else { return }
            let clampedSize = min(max(newSize, Self.minFontSize), Self.maxFontSize)
            let delta = clampedSize - currentFontSize
            
            if delta > 0 {
                let action = "increase_font_size:\(delta)"
                if ghostty_surface_binding_action(surface, action, UInt(action.utf8.count)) {
                    currentFontSize = clampedSize
                    logger.info("🔍 Font size set to \(currentFontSize)")
                }
            } else if delta < 0 {
                let action = "decrease_font_size:\(abs(delta))"
                if ghostty_surface_binding_action(surface, action, UInt(action.utf8.count)) {
                    currentFontSize = clampedSize
                    logger.info("🔍 Font size set to \(currentFontSize)")
                }
            }
        }
        
        /// Reload configuration from file and apply to surface
        /// File is the source of truth - just read and apply
        func updateConfig() {
            guard let surface = surface else {
                logger.warning("Cannot update config: surface is nil")
                return
            }
            
            logger.info("🔧 Reloading config from file...")
            
            // Read config directly from file and apply
            guard let newConfig = Config.createConfigWithCurrentSettings() else {
                logger.error("Failed to create config from file")
                return
            }
            
            // Apply the new config to the surface
            ghostty_surface_update_config(surface, newConfig)
            logger.info("✅ Config reloaded from file")
            
            // Free the config after applying (Ghostty makes a copy)
            ghostty_config_free(newConfig)
        }
        
        /// Handle pinch gesture for zooming font size
        @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began:
                pinchStartFontSize = currentFontSize
                
            case .changed:
                let newSize = pinchStartFontSize * Float(gesture.scale)
                let clampedSize = max(Self.minFontSize, min(Self.maxFontSize, newSize))
                let delta = clampedSize - currentFontSize
                
                if abs(delta) >= 0.5 {
                    if delta > 0 {
                        increaseFontSize(abs(delta))
                    } else {
                        decreaseFontSize(abs(delta))
                    }
                }
                
            case .ended, .cancelled:
                // Provide haptic feedback at end of gesture
                hapticLight.impactOccurred()
                
            default:
                break
            }
        }

        /// Notify size change
        func sizeDidChange(_ size: CGSize) {
            guard let surface = surface else { return }
            
            // Guard against invalid sizes during view transitions
            // Negative or very small sizes can cause integer overflow in Ghostty
            guard size.width > 0, size.height > 0 else { return }
            
            let scale = contentScaleFactor
            let scaledWidth = size.width * scale
            let scaledHeight = size.height * scale
            
            // Additional guard: ensure scaled values fit in UInt32
            guard scaledWidth > 0, scaledWidth < Double(UInt32.max),
                  scaledHeight > 0, scaledHeight < Double(UInt32.max) else {
                return
            }
            
            ghostty_surface_set_content_scale(surface, scale, scale)
            ghostty_surface_set_size(surface, UInt32(scaledWidth), UInt32(scaledHeight))
            
            // IMPORTANT: On iOS, the IOSurfaceLayer is added as a sublayer (not the view's layer).
            // We must manually resize it to match the view's bounds, otherwise it stays at (0,0,0,0).
            // On macOS, the IOSurfaceLayer IS the view's layer, so it auto-sizes.
            // Skip the scroll indicator's layer — it's positioned separately in layoutSubviews.
            if let sublayers = layer.sublayers {
                let scrollLayer = scrollIndicator?.layer
                for sublayer in sublayers where sublayer !== scrollLayer {
                    // Disable implicit animations for immediate resize
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    sublayer.frame = bounds
                    sublayer.contentsScale = scale
                    CATransaction.commit()
                }
            }
            
            // Get the updated grid size and notify the resize callback
            // This is crucial for SSH PTY sizing
            if let gridSize = surfaceSize {
                let cols = Int(gridSize.columns)
                let rows = Int(gridSize.rows)
                onResize?(cols, rows)
            }
        }
        
        /// Get the current surface size info
        var surfaceSize: ghostty_surface_size_s? {
            guard let surface = surface else { return nil }
            return ghostty_surface_size(surface)
        }
        
        /// Force the surface to use an exact grid size.
        ///
        /// This calculates the exact pixel dimensions needed for the given
        /// character grid and updates the surface size. Use this when you
        /// need the terminal grid to match an external constraint (like tmux).
        ///
        /// - Parameters:
        ///   - cols: Target column count
        ///   - rows: Target row count
        /// - Returns: true if the size was set, false if cell size is not yet available
        @discardableResult
        func setExactGridSize(cols: Int, rows: Int) -> Bool {
            guard let surface = surface,
                  let size = surfaceSize,
                  size.cell_width_px > 0,
                  size.cell_height_px > 0 else {
                logger.info("📐 setExactGridSize(\(cols)x\(rows)) FAILED - no valid surface/cell size")
                return false
            }
            
            // Calculate exact pixel dimensions for the target grid
            let scale = contentScaleFactor
            let exactWidthPx = UInt32(cols) * size.cell_width_px
            let exactHeightPx = UInt32(rows) * size.cell_height_px
            
            logger.info("📐 setExactGridSize: \(cols)x\(rows) = \(exactWidthPx)x\(exactHeightPx)px (cell: \(size.cell_width_px)x\(size.cell_height_px))")
            
            // Mark that we're using explicit grid sizing - prevents layoutSubviews from overriding
            usesExactGridSize = true
            
            // Update content scale and surface size
            ghostty_surface_set_content_scale(surface, scale, scale)
            ghostty_surface_set_size(surface, exactWidthPx, exactHeightPx)
            
            return true
        }
        
        /// Clear exact grid size mode, allowing normal auto-resize behavior
        func clearExactGridSize() {
            usesExactGridSize = false
            // Trigger a resize to current bounds
            sizeDidChange(bounds.size)
        }
        
        // MARK: - UIView Overrides
        
        override func didMoveToWindow() {
            super.didMoveToWindow()
            // Only auto-resize if not using explicit grid sizing (tmux multi-pane mode).
            // In exact grid mode, the container controls sizing via setExactGridSize().
            // Without this guard, re-parenting the surface (e.g. SwiftUI view identity
            // change) triggers sizeDidChange → ghostty_surface_set_size → Zig Termio.resize
            // → "refresh-client -C" with pane dimensions, creating a resize oscillation.
            if !usesExactGridSize {
                sizeDidChange(frame.size)
            } else {
                updateSublayerFrames()
            }
            
            // Focus management: request keyboard focus when added to window.
            // canBecomeFirstResponder returns false for observers, so
            // becomeFirstResponder() is a no-op — no guard needed.
            if window != nil {
                // Start vsync-aligned frame pacing
                startFrameDisplayLink()
                
                RunLoop.main.perform { [weak self] in
                    guard let self = self, self.window != nil else { return }
                    if !self.isFirstResponder {
                        _ = self.becomeFirstResponder()
                    }
                }
            } else {
                // Stop frame pacing when removed from window
                stopFrameDisplayLink()
                
                // Resign when removed from window to clean up keyboard
                if self.isFirstResponder {
                    _ = self.resignFirstResponder()
                }
            }
        }
        
        override func layoutSubviews() {
            super.layoutSubviews()
            
            // Only auto-resize if not using explicit grid sizing (tmux multi-pane mode)
            // In exact grid mode, the container controls sizing via setExactGridSize()
            if !usesExactGridSize {
                sizeDidChange(bounds.size)
            } else {
                // Still need to update sublayer frames to match our bounds
                updateSublayerFrames()
            }
            
            // Keep scroll indicator on right edge (without animation)
            if let indicator = scrollIndicator {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                indicator.frame.origin.x = bounds.width - 6
                CATransaction.commit()
            }
        }
        
        /// Update sublayer frames to match current bounds (without changing surface size)
        private func updateSublayerFrames() {
            let scale = contentScaleFactor
            let scrollLayer = scrollIndicator?.layer
            if let sublayers = layer.sublayers {
                for sublayer in sublayers where sublayer !== scrollLayer {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    sublayer.frame = bounds
                    sublayer.contentsScale = scale
                    CATransaction.commit()
                }
            }
        }
    }
}

// MARK: - UITextInputTraits Conformance

extension Ghostty.SurfaceView: UITextInputTraits {
    // These properties are required to be settable by the protocol
    // but we use backing stored properties with computed accessors
    
    var autocorrectionType: UITextAutocorrectionType {
        get { _autocorrectionType }
        set { _autocorrectionType = newValue }
    }
    
    var autocapitalizationType: UITextAutocapitalizationType {
        get { _autocapitalizationType }
        set { _autocapitalizationType = newValue }
    }
    
    var spellCheckingType: UITextSpellCheckingType {
        get { _spellCheckingType }
        set { _spellCheckingType = newValue }
    }
    
    var keyboardType: UIKeyboardType {
        get { _keyboardType }
        set { _keyboardType = newValue }
    }
    
    var returnKeyType: UIReturnKeyType {
        get { _returnKeyType }
        set { _returnKeyType = newValue }
    }
    
    var smartQuotesType: UITextSmartQuotesType {
        get { _smartQuotesType }
        set { _smartQuotesType = newValue }
    }
    
    var smartDashesType: UITextSmartDashesType {
        get { _smartDashesType }
        set { _smartDashesType = newValue }
    }
    
    var smartInsertDeleteType: UITextSmartInsertDeleteType {
        get { _smartInsertDeleteType }
        set { _smartInsertDeleteType = newValue }
    }
}

// MARK: - TmuxSurfaceProtocol Conformance

/// SurfaceView already implements all required methods — this declares the conformance.
/// See TmuxSurfaceProtocol.swift for the protocol definition.
extension Ghostty.SurfaceView: TmuxSurfaceProtocol {}

// MARK: - Errors & SearchState → Ghostty.SearchState.swift
