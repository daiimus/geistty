//
//  Ghostty.swift
//  Bodak
//
//  Swift wrappers for the GhosttyKit C API
//

import Foundation
import UIKit
import Metal
import QuartzCore
import GhosttyKit
import ObjectiveC

/// Ghostty namespace containing all Ghostty-related types
enum Ghostty {
    /// Logger for Ghostty-related operations
    static let logger = Logger(subsystem: "com.bodak", category: "Ghostty")
}

// MARK: - Simple Logger (since os.Logger requires iOS 14+)

struct Logger {
    let subsystem: String
    let category: String
    
    func info(_ message: String) {
        print("[\(category)] INFO: \(message)")
    }
    
    func warning(_ message: String) {
        print("[\(category)] WARNING: \(message)")
    }
    
    func error(_ message: String) {
        print("[\(category)] ERROR: \(message)")
    }
    
    func debug(_ message: String) {
        #if DEBUG
        print("[\(category)] DEBUG: \(message)")
        #endif
    }
}

// MARK: - Ghostty.Config

extension Ghostty {
    /// Configuration wrapper for ghostty_config_t
    class Config {
        private(set) var config: ghostty_config_t
        
        /// Background color from config (default to dark)
        var backgroundColor: UIColor {
            // TODO: Read from actual config once we parse it
            return UIColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0)
        }
        
        init?() {
            guard let cfg = ghostty_config_new() else {
                logger.error("ghostty_config_new returned nil")
                return nil
            }
            config = cfg
            ghostty_config_finalize(config)
        }
        
        deinit {
            ghostty_config_free(config)
        }
    }
}

// MARK: - Ghostty.App

extension Ghostty {
    /// Represents the readiness state of the Ghostty app
    enum Readiness: String {
        case loading
        case error
        case ready
    }
    
    /// Main Ghostty application wrapper
    /// Manages the ghostty_app_t instance and runtime callbacks
    class App: ObservableObject {
        /// The readiness state of the app
        @Published var readiness: Readiness = .loading
        
        /// The app configuration
        @Published private(set) var config: Config?
        
        /// The underlying ghostty_app_t handle
        private(set) var app: ghostty_app_t?
        
        /// Static flag to track if ghostty_init has been called
        private static var isInitialized = false
        
        /// Initialize the Ghostty runtime (must be called before any other Ghostty API)
        private static func initializeRuntime() -> Bool {
            guard !isInitialized else { return true }
            
            let argc: UInt = 0
            var argv: UnsafeMutablePointer<CChar>? = nil
            let result = ghostty_init(argc, &argv)
            
            if result == GHOSTTY_SUCCESS {
                isInitialized = true
                logger.info("Ghostty runtime initialized")
                return true
            } else {
                logger.error("ghostty_init failed with code: \(result)")
                return false
            }
        }
        
        init() {
            // First, initialize the Ghostty runtime BEFORE creating any configs
            guard Self.initializeRuntime() else {
                logger.error("Failed to initialize Ghostty runtime")
                readiness = .error
                return
            }
            
            // Now we can safely create the config
            guard let config = Config() else {
                logger.error("Failed to create Ghostty config")
                readiness = .error
                return
            }
            self.config = config
            
            // Setup runtime configuration with callbacks
            var runtimeConfig = ghostty_runtime_config_s(
                userdata: Unmanaged.passUnretained(self).toOpaque(),
                supports_selection_clipboard: false,
                wakeup_cb: { userdata in
                    App.wakeup(userdata)
                },
                action_cb: { app, target, action in
                    App.action(app!, target: target, action: action)
                },
                read_clipboard_cb: { userdata, location, state in
                    App.readClipboard(userdata, location: location, state: state)
                },
                confirm_read_clipboard_cb: { userdata, str, state, request in
                    App.confirmReadClipboard(userdata, string: str, state: state, request: request)
                },
                write_clipboard_cb: { userdata, location, content, len, confirm in
                    App.writeClipboard(userdata, location: location, content: content, len: len, confirm: confirm)
                },
                close_surface_cb: { userdata, processAlive in
                    App.closeSurface(userdata, processAlive: processAlive)
                }
            )
            
            // Create the app
            guard let ghosttyApp = ghostty_app_new(&runtimeConfig, config.config) else {
                logger.error("ghostty_app_new failed")
                readiness = .error
                return
            }
            
            self.app = ghosttyApp
            readiness = .ready
            logger.info("Ghostty app initialized successfully")
        }
        
        deinit {
            if let app = app {
                ghostty_app_free(app)
            }
        }
        
        /// Tick the app (process pending events)
        func tick() {
            guard let app = app else { return }
            ghostty_app_tick(app)
        }
        
        // MARK: - Runtime Callbacks
        
        private static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
            guard let userdata = userdata else { return }
            let app = Unmanaged<App>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async {
                app.tick()
            }
        }
        
        private static func action(_ ghosttyApp: ghostty_app_t, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
            // Handle actions from Ghostty core
            logger.debug("Ghostty action: \(action.tag.rawValue)")
            
            switch action.tag {
            case GHOSTTY_ACTION_SET_TITLE:
                // Handle title change
                return true
                
            case GHOSTTY_ACTION_RING_BELL:
                // Handle bell
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.warning)
                return true
                
            default:
                return false
            }
        }
        
        private static func readClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            location: ghostty_clipboard_e,
            state: UnsafeMutableRawPointer?
        ) {
            // Read from clipboard and send to Ghostty
            guard let userdata = userdata else { return }
            // TODO: Implement clipboard read
        }
        
        private static func confirmReadClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            string: UnsafePointer<CChar>?,
            state: UnsafeMutableRawPointer?,
            request: ghostty_clipboard_request_e
        ) {
            // Confirm clipboard read (for security)
            // TODO: Implement confirmation dialog
        }
        
        private static func writeClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            location: ghostty_clipboard_e,
            content: UnsafePointer<ghostty_clipboard_content_s>?,
            len: Int,
            confirm: Bool
        ) {
            guard let content = content, len > 0 else { return }
            
            // Write to system clipboard
            if let data = content.pointee.data {
                let str = String(cString: data)
                UIPasteboard.general.string = str
            }
        }
        
        private static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
            // Handle surface close request
            logger.debug("Close surface requested, processAlive: \(processAlive)")
        }
    }
}

// MARK: - Ghostty.SurfaceConfiguration

extension Ghostty {
    /// Backend type for terminal I/O
    enum BackendType: Int32 {
        case exec = 0      // Execute subprocess with PTY (default)
        case external = 1  // External data source (SSH, serial)
    }
    
    /// Configuration for creating a new surface
    struct SurfaceConfiguration {
        var fontSize: Float = 14.0
        var workingDirectory: String? = nil
        var command: String? = nil
        var backendType: BackendType = .exec
        
        init() {}
        
        /// Convert to C struct for passing to ghostty_surface_new
        func withCValue<T>(view: UIView, writeCallback: ghostty_write_callback_fn? = nil, _ body: (inout ghostty_surface_config_s) -> T) -> T {
            var config = ghostty_surface_config_new()
            
            // Set platform info
            config.platform_tag = GHOSTTY_PLATFORM_IOS
            config.platform.ios.uiview = Unmanaged.passUnretained(view).toOpaque()
            
            // Set scale factor
            config.scale_factor = Double(view.contentScaleFactor)
            
            // Set font size
            config.font_size = fontSize
            
            // Set userdata to the view
            config.userdata = Unmanaged.passUnretained(view).toOpaque()
            
            // Set backend type
            config.backend_type = ghostty_backend_type_e(UInt32(backendType.rawValue))
            
            // Set write callback for external backend
            config.write_callback = writeCallback
            
            // Set command if provided (only relevant for exec backend)
            if let cmd = command {
                return cmd.withCString { cstr in
                    config.command = cstr
                    return body(&config)
                }
            }
            
            return body(&config)
        }
    }
}

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
        @Published var cellSize: CGSize = .zero
        
        /// Whether the surface is healthy
        @Published var healthy: Bool = true
        
        /// Any initialization error
        @Published var error: Error? = nil
        
        /// The underlying ghostty_surface_t handle
        private(set) var surface: ghostty_surface_t?
        
        /// Callback for when the surface wants to write data (user input)
        var onWrite: ((Data) -> Void)?
        
        /// Focus state tracking
        private var hasFocusState: Bool = false
        private var focusInstant: ContinuousClock.Instant? = nil
        
        // MARK: - UIKeyInput conformance
        
        /// Required: Can this view become first responder?
        override var canBecomeFirstResponder: Bool { true }
        
        /// Required: Does the view have text? (Always yes for terminal)
        var hasText: Bool { true }
        
        /// Required: Insert text from keyboard (software keyboard)
        func insertText(_ text: String) {
            NSLog("⌨️ insertText: '\(text.debugDescription)' ctrlToggle=\(ctrlToggleActive)")
            guard let surface = surface else {
                NSLog("⌨️ insertText: surface is nil")
                return
            }
            
            // Check if Ctrl toggle is active
            if ctrlToggleActive {
                ctrlToggleActive = false  // Reset after use
                
                // Convert to control character if single character
                if text.count == 1, let scalar = text.unicodeScalars.first {
                    let ctrlChar = controlCharacter(for: scalar, mods: GHOSTTY_MODS_CTRL)
                    if !ctrlChar.isEmpty {
                        NSLog("⌨️ Sending Ctrl character: \\x\(String(format: "%02X", ctrlChar.utf8.first ?? 0))")
                        ctrlChar.withCString { ptr in
                            ghostty_surface_text(surface, ptr, UInt(ctrlChar.utf8.count))
                        }
                        return
                    }
                }
            }
            
            // Send text to Ghostty which will trigger the write callback
            text.withCString { ptr in
                let len = text.utf8.count
                ghostty_surface_text(surface, ptr, UInt(len))
            }
        }
        
        /// Required: Handle backspace/delete
        func deleteBackward() {
            NSLog("⌨️ deleteBackward")
            guard let surface = surface else { return }
            
            // Send backspace character (ASCII 127 or 0x08)
            let backspace = "\u{7f}"  // DEL character (more common for terminals)
            backspace.withCString { ptr in
                ghostty_surface_text(surface, ptr, 1)
            }
        }
        
        /// Convenience accessor for the Metal layer
        var metalLayer: CAMetalLayer {
            return layer as! CAMetalLayer
        }
        
        /// Initialize with a Ghostty app
        init(_ app: ghostty_app_t, baseConfig: SurfaceConfiguration? = nil, uuid: UUID? = nil) {
            self.uuid = uuid ?? UUID()
            
            // CRITICAL: Register Ghostty-compatible methods BEFORE creating the view
            // This must happen before super.init() because ghostty_surface_new()
            // might be called before init() completes on some code paths.
            Self.registerGhosttyMethods()
            
            // Initialize with a reasonable default frame (non-zero so layer bounds are non-zero)
            super.init(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
            
            print("[Bodak] 🏗️ SurfaceView initialized, frame: \(frame)")
            print("[Bodak] 🏗️ Layer class: \(type(of: layer))")
            print("[Bodak] 🏗️ contentScaleFactor: \(contentScaleFactor)")
            
            // NOTE: We do NOT configure the metal layer here.
            // Ghostty's Metal renderer creates its own IOSurfaceLayer and adds it as a sublayer.
            // The renderer handles all Metal configuration internally.
            
            // Setup the surface - this is where Ghostty's Metal renderer is initialized
            // and where addSublayer will be called on this view
            print("[Bodak] 🏗️ About to call ghostty_surface_new...")
            let surfaceConfig = baseConfig ?? SurfaceConfiguration()
            
            // For external backend, we need to set up a write callback
            // The callback will be invoked when the terminal wants to send data (user input)
            let writeCallback: ghostty_write_callback_fn? = surfaceConfig.backendType == .external
                ? Self.externalWriteCallback
                : nil
            
            let surface = surfaceConfig.withCValue(view: self, writeCallback: writeCallback) { config in
                ghostty_surface_new(app, &config)
            }
            print("[Bodak] 🏗️ ghostty_surface_new returned: \(surface != nil ? "success" : "nil")")
            
            guard let surface = surface else {
                self.error = GhosttyError.surfaceCreationFailed
                logger.error("Failed to create Ghostty surface")
                return
            }
            
            self.surface = surface
            print("[Bodak] 🏗️ Sublayers after ghostty_surface_new: \(layer.sublayers?.count ?? 0)")
            layer.sublayers?.forEach { sublayer in
                print("[Bodak] 🏗️   Sublayer: \(type(of: sublayer)), frame: \(sublayer.frame)")
            }
            logger.info("Ghostty surface created successfully with backend: \(surfaceConfig.backendType)")
            
            // Enable user interaction and add tap gesture to become first responder
            isUserInteractionEnabled = true
            let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            addGestureRecognizer(tapGesture)
            
            // Add long press + pan gesture for text selection
            let longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            longPressGesture.minimumPressDuration = 0.3
            addGestureRecognizer(longPressGesture)
            
            // Add two-finger pan gesture for touch scrolling
            let scrollGesture = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
            scrollGesture.minimumNumberOfTouches = 2
            scrollGesture.maximumNumberOfTouches = 2
            addGestureRecognizer(scrollGesture)
            
            // Add trackpad/mouse scroll gesture (indirect input like Magic Keyboard trackpad)
            let trackpadScrollGesture = UIPanGestureRecognizer(target: self, action: #selector(handleTrackpadScroll(_:)))
            trackpadScrollGesture.allowedScrollTypesMask = [.continuous, .discrete]
            trackpadScrollGesture.minimumNumberOfTouches = 0  // Trackpad scrolls don't register as touches
            trackpadScrollGesture.maximumNumberOfTouches = 0
            addGestureRecognizer(trackpadScrollGesture)
            
            // Add pointer interaction for external mouse/trackpad support
            let pointerInteraction = UIPointerInteraction(delegate: self)
            addInteraction(pointerInteraction)
            
            // Add hover gesture for mouse movement tracking
            let hoverGesture = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
            addGestureRecognizer(hoverGesture)
        }
        
        // MARK: - UIPointerInteractionDelegate
        
        func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
            // Use the default text cursor for terminal
            return UIPointerStyle(shape: .verticalBeam(length: 20))
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
        private var scrollVelocity: CGFloat = 0
        private let scrollDeceleration: CGFloat = 0.95
        private let scrollMinVelocity: CGFloat = 0.1
        
        /// Track accumulated scroll for gesture
        private var accumulatedScrollY: CGFloat = 0
        private let scrollSensitivity: CGFloat = 0.5
        
        /// Handle two-finger touch scrolling
        @objc private func handleScroll(_ gesture: UIPanGestureRecognizer) {
            guard let surface = surface else { return }
            
            let translation = gesture.translation(in: self)
            
            switch gesture.state {
            case .began:
                accumulatedScrollY = 0
                
            case .changed:
                // Convert pan translation to scroll delta
                let deltaY = translation.y - accumulatedScrollY
                accumulatedScrollY = translation.y
                
                // Send scroll to Ghostty (negative because pan down = scroll up in content)
                let scrollY = -deltaY * scrollSensitivity
                ghostty_surface_mouse_scroll(surface, 0, Double(scrollY), 0)
                
            case .ended, .cancelled:
                accumulatedScrollY = 0
                
            default:
                break
            }
        }
        
        /// Track accumulated trackpad scroll
        private var accumulatedTrackpadScrollY: CGFloat = 0
        
        /// Handle trackpad/mouse wheel scrolling (Magic Keyboard, external mouse)
        @objc private func handleTrackpadScroll(_ gesture: UIPanGestureRecognizer) {
            guard let surface = surface else { return }
            
            let translation = gesture.translation(in: self)
            
            switch gesture.state {
            case .began:
                NSLog("🖲️ Trackpad scroll began")
                accumulatedTrackpadScrollY = 0
                
            case .changed:
                // Convert trackpad pan to scroll delta
                let deltaY = translation.y - accumulatedTrackpadScrollY
                accumulatedTrackpadScrollY = translation.y
                
                // Trackpad scrolling - natural scrolling direction
                // (pan down = content moves down = scroll down in terminal)
                let scrollY = deltaY * scrollSensitivity
                ghostty_surface_mouse_scroll(surface, 0, Double(scrollY), 0)
                
            case .ended, .cancelled:
                NSLog("🖲️ Trackpad scroll ended")
                accumulatedTrackpadScrollY = 0
                
            default:
                break
            }
        }
        
        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            NSLog("👆 Terminal tapped, becoming first responder")
            becomeFirstResponder()
        }
        
        // MARK: - UIGestureRecognizerDelegate
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // Allow hover to work simultaneously with other gestures
            if gestureRecognizer is UIHoverGestureRecognizer || otherGestureRecognizer is UIHoverGestureRecognizer {
                return true
            }
            return false
        }

        /// Track if we're in selection mode (from long press)
        private var isSelecting = false
        
        @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let surface = surface else { return }
            
            let point = gesture.location(in: self)
            let scale = contentScaleFactor
            
            switch gesture.state {
            case .began:
                NSLog("🎯 Long press began at \(point)")
                isSelecting = true
                // Start selection (simulate left mouse button press)
                ghostty_surface_mouse_pos(surface, point.x * scale, point.y * scale, GHOSTTY_MODS_NONE)
                _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
                
            case .changed:
                if isSelecting {
                    // Update selection (move mouse with button held)
                    ghostty_surface_mouse_pos(surface, point.x * scale, point.y * scale, GHOSTTY_MODS_NONE)
                }
                
            case .ended, .cancelled:
                if isSelecting {
                    NSLog("🎯 Long press ended at \(point)")
                    // End selection (release mouse button)
                    ghostty_surface_mouse_pos(surface, point.x * scale, point.y * scale, GHOSTTY_MODS_NONE)
                    _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
                    isSelecting = false
                    
                    // Check if we have a selection and show copy menu
                    if ghostty_surface_has_selection(surface) {
                        showCopyMenu(at: point)
                    }
                }
                
            default:
                break
            }
        }
        
        /// Show a copy menu at the given point
        private func showCopyMenu(at point: CGPoint) {
            let menuController = UIMenuController.shared
            let rect = CGRect(origin: point, size: CGSize(width: 1, height: 1))
            menuController.showMenu(from: self, rect: rect)
        }
        
        /// Override canPerformAction to enable copy
        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            if action == #selector(UIResponderStandardEditActions.copy(_:)) {
                guard let surface = surface else { return false }
                return ghostty_surface_has_selection(surface)
            }
            if action == #selector(UIResponderStandardEditActions.paste(_:)) {
                return UIPasteboard.general.hasStrings
            }
            return super.canPerformAction(action, withSender: sender)
        }
        
        /// Handle copy action
        @objc override func copy(_ sender: Any?) {
            guard let surface = surface else { return }
            
            var textStruct = ghostty_text_s()
            if ghostty_surface_read_selection(surface, &textStruct) {
                if let textPtr = textStruct.text, textStruct.text_len > 0 {
                    let selectedText = String(cString: textPtr)
                    UIPasteboard.general.string = selectedText
                    NSLog("📋 Copied \(textStruct.text_len) characters to clipboard")
                }
                ghostty_surface_free_text(surface, &textStruct)
            }
        }
        
        /// Handle paste action
        @objc override func paste(_ sender: Any?) {
            if let text = UIPasteboard.general.string {
                insertText(text)
            }
        }
        
        // MARK: - Hardware Keyboard Support (UIResponder presses)
        
        /// Track current modifier state for Ctrl toggle button
        private var ctrlToggleActive = false
        
        /// Set Ctrl toggle state (from toolbar button)
        func setCtrlToggle(_ active: Bool) {
            ctrlToggleActive = active
        }
        
        /// Handle hardware keyboard key presses and mouse button events
        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var handled = false
            
            for press in presses {
                // Handle mouse button presses (Mac Catalyst only)
                #if targetEnvironment(macCatalyst)
                if let surface = surface {
                    switch press.type {
                    case .primaryButton:  // Left click
                        NSLog("🖱️ Primary button pressed")
                        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
                        handled = true
                        continue
                        
                    case .secondaryButton:  // Right click
                        NSLog("🖱️ Secondary button pressed")
                        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, GHOSTTY_MODS_NONE)
                        handled = true
                        continue
                        
                    default:
                        break
                    }
                }
                #endif
                
                // Handle keyboard key presses
                if let key = press.key {
                    NSLog("⌨️ pressesBegan: keyCode=\(key.keyCode.rawValue) chars='\(key.characters ?? "")'")
                    
                    // Get modifiers from the press event
                    var mods = ghosttyMods(from: key.modifierFlags)
                    
                    // Add Ctrl if toggle is active (for toolbar Ctrl button)
                    if ctrlToggleActive {
                        mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_CTRL.rawValue)
                        // Reset toggle after use
                        ctrlToggleActive = false
                    }
                    
                    // Handle the key through Ghostty or as escape sequence
                    if sendHardwareKey(key, action: GHOSTTY_ACTION_PRESS, mods: mods) {
                        handled = true
                    }
                }
            }
            
            if !handled {
                super.pressesBegan(presses, with: event)
            }
        }
        
        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            // Handle mouse button releases (Mac Catalyst only)
            for press in presses {
                #if targetEnvironment(macCatalyst)
                if let surface = surface {
                    switch press.type {
                    case .primaryButton:
                        NSLog("🖱️ Primary button released")
                        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
                        continue
                        
                    case .secondaryButton:
                        NSLog("🖱️ Secondary button released")
                        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, GHOSTTY_MODS_NONE)
                        continue
                        
                    default:
                        break
                    }
                }
                #endif
                
                // Handle keyboard key releases
                if let key = press.key {
                    let mods = ghosttyMods(from: key.modifierFlags)
                    _ = sendHardwareKey(key, action: GHOSTTY_ACTION_RELEASE, mods: mods)
                }
            }
            super.pressesEnded(presses, with: event)
        }
        
        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            // Treat cancelled as released
            pressesEnded(presses, with: event)
        }
        
        /// Convert UIKeyModifierFlags to Ghostty modifier flags
        private func ghosttyMods(from flags: UIKeyModifierFlags) -> ghostty_input_mods_e {
            var mods: UInt32 = 0
            
            if flags.contains(.shift) {
                mods |= GHOSTTY_MODS_SHIFT.rawValue
            }
            if flags.contains(.control) {
                mods |= GHOSTTY_MODS_CTRL.rawValue
            }
            if flags.contains(.alternate) {  // Option/Alt
                mods |= GHOSTTY_MODS_ALT.rawValue
            }
            if flags.contains(.command) {
                mods |= GHOSTTY_MODS_SUPER.rawValue
            }
            if flags.contains(.alphaShift) {  // Caps Lock
                mods |= GHOSTTY_MODS_CAPS.rawValue
            }
            
            return ghostty_input_mods_e(rawValue: mods)
        }
        
        /// Send a hardware key event to Ghostty
        private func sendHardwareKey(_ key: UIKey, action: ghostty_input_action_e, mods: ghostty_input_mods_e) -> Bool {
            guard let surface = surface else { return false }
            
            // Map UIKey to macOS-style keycode for Ghostty
            guard let keycode = uikeyToKeycode(key) else {
                // If no keycode mapping, try sending as text (for regular characters)
                let chars = key.characters
                if action == GHOSTTY_ACTION_PRESS, !chars.isEmpty {
                    // Apply Ctrl modifier if needed
                    if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0,
                       chars.count == 1,
                       let char = chars.unicodeScalars.first {
                        // Convert to control character
                        let ctrlChar = controlCharacter(for: char, mods: mods)
                        if !ctrlChar.isEmpty {
                            NSLog("⌨️ Sending Ctrl character: \\x\(String(format: "%02X", ctrlChar.utf8.first ?? 0))")
                            ctrlChar.withCString { ptr in
                                ghostty_surface_text(surface, ptr, UInt(ctrlChar.utf8.count))
                            }
                            return true
                        }
                    }
                    
                    // Regular text input
                    chars.withCString { ptr in
                        ghostty_surface_text(surface, ptr, UInt(chars.utf8.count))
                    }
                    return true
                }
                return false
            }
            
            // Create key event for Ghostty
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = action
            keyEvent.keycode = keycode
            keyEvent.mods = mods
            keyEvent.consumed_mods = GHOSTTY_MODS_NONE
            keyEvent.composing = false
            
            // Set unshifted codepoint if available
            let charsIgnoring = key.charactersIgnoringModifiers
            if let scalar = charsIgnoring.unicodeScalars.first {
                keyEvent.unshifted_codepoint = scalar.value
            }
            
            // For press events with text, include the text
            let chars = key.characters
            if action == GHOSTTY_ACTION_PRESS, !chars.isEmpty {
                return chars.withCString { ptr in
                    keyEvent.text = ptr
                    return ghostty_surface_key(surface, keyEvent)
                }
            } else {
                keyEvent.text = nil
                return ghostty_surface_key(surface, keyEvent)
            }
        }
        
        /// Generate control character for Ctrl+key combinations
        private func controlCharacter(for scalar: UnicodeScalar, mods: ghostty_input_mods_e) -> String {
            let value = scalar.value
            
            // Ctrl+A through Ctrl+Z → 0x01-0x1A
            if value >= UInt32(Character("a").asciiValue!), value <= UInt32(Character("z").asciiValue!) {
                let ctrlValue = value - UInt32(Character("a").asciiValue!) + 1
                return String(UnicodeScalar(ctrlValue)!)
            }
            if value >= UInt32(Character("A").asciiValue!), value <= UInt32(Character("Z").asciiValue!) {
                let ctrlValue = value - UInt32(Character("A").asciiValue!) + 1
                return String(UnicodeScalar(ctrlValue)!)
            }
            
            // Special cases
            switch scalar {
            case "[", "{":  // Ctrl+[ = ESC
                return "\u{1B}"
            case "]", "}":  // Ctrl+]
                return "\u{1D}"
            case "\\":      // Ctrl+\ 
                return "\u{1C}"
            case "^", "6":  // Ctrl+^
                return "\u{1E}"
            case "_", "-":  // Ctrl+_
                return "\u{1F}"
            case "@", "`", "2":  // Ctrl+@ = NUL
                return "\u{00}"
            default:
                return ""
            }
        }
        
        /// Map UIKey keyCode to macOS-style keycode for Ghostty
        /// These keycodes match the macOS virtual key codes that Ghostty expects
        private func uikeyToKeycode(_ key: UIKey) -> UInt32? {
            // UIKeyboardHIDUsage values - map to macOS virtual keycodes
            switch key.keyCode {
            // Letters (macOS keycodes for QWERTY layout)
            case .keyboardA: return 0x00
            case .keyboardB: return 0x0B
            case .keyboardC: return 0x08
            case .keyboardD: return 0x02
            case .keyboardE: return 0x0E
            case .keyboardF: return 0x03
            case .keyboardG: return 0x05
            case .keyboardH: return 0x04
            case .keyboardI: return 0x22
            case .keyboardJ: return 0x26
            case .keyboardK: return 0x28
            case .keyboardL: return 0x25
            case .keyboardM: return 0x2E
            case .keyboardN: return 0x2D
            case .keyboardO: return 0x1F
            case .keyboardP: return 0x23
            case .keyboardQ: return 0x0C
            case .keyboardR: return 0x0F
            case .keyboardS: return 0x01
            case .keyboardT: return 0x11
            case .keyboardU: return 0x20
            case .keyboardV: return 0x09
            case .keyboardW: return 0x0D
            case .keyboardX: return 0x07
            case .keyboardY: return 0x10
            case .keyboardZ: return 0x06
            
            // Numbers (top row)
            case .keyboard1: return 0x12
            case .keyboard2: return 0x13
            case .keyboard3: return 0x14
            case .keyboard4: return 0x15
            case .keyboard5: return 0x17
            case .keyboard6: return 0x16
            case .keyboard7: return 0x1A
            case .keyboard8: return 0x1C
            case .keyboard9: return 0x19
            case .keyboard0: return 0x1D
            
            // Special keys
            case .keyboardReturnOrEnter: return 0x24
            case .keyboardEscape: return 0x35
            case .keyboardDeleteOrBackspace: return 0x33
            case .keyboardTab: return 0x30
            case .keyboardSpacebar: return 0x31
            case .keyboardHyphen: return 0x1B  // -
            case .keyboardEqualSign: return 0x18  // =
            case .keyboardOpenBracket: return 0x21  // [
            case .keyboardCloseBracket: return 0x1E  // ]
            case .keyboardBackslash: return 0x2A  // \
            case .keyboardSemicolon: return 0x29  // ;
            case .keyboardQuote: return 0x27  // '
            case .keyboardGraveAccentAndTilde: return 0x32  // `
            case .keyboardComma: return 0x2B  // ,
            case .keyboardPeriod: return 0x2F  // .
            case .keyboardSlash: return 0x2C  // /
            
            // Arrow keys
            case .keyboardUpArrow: return 0x7E
            case .keyboardDownArrow: return 0x7D
            case .keyboardLeftArrow: return 0x7B
            case .keyboardRightArrow: return 0x7C
            
            // Function keys
            case .keyboardF1: return 0x7A
            case .keyboardF2: return 0x78
            case .keyboardF3: return 0x63
            case .keyboardF4: return 0x76
            case .keyboardF5: return 0x60
            case .keyboardF6: return 0x61
            case .keyboardF7: return 0x62
            case .keyboardF8: return 0x64
            case .keyboardF9: return 0x65
            case .keyboardF10: return 0x6D
            case .keyboardF11: return 0x67
            case .keyboardF12: return 0x6F
            
            // Navigation keys
            case .keyboardHome: return 0x73
            case .keyboardEnd: return 0x77
            case .keyboardPageUp: return 0x74
            case .keyboardPageDown: return 0x79
            case .keyboardDeleteForward: return 0x75
            case .keyboardInsert: return 0x72
            
            // Modifiers (we handle these but return nil to not send them as key events)
            case .keyboardLeftShift, .keyboardRightShift: return nil
            case .keyboardLeftControl, .keyboardRightControl: return nil
            case .keyboardLeftAlt, .keyboardRightAlt: return nil
            case .keyboardLeftGUI, .keyboardRightGUI: return nil  // Command
            case .keyboardCapsLock: return nil
            
            default:
                NSLog("⌨️ Unknown keyCode: \(key.keyCode.rawValue)")
                return nil
            }
        }
        
        /// C callback for external backend write operations
        /// This is called when the terminal wants to send data (user keyboard input)
        private static let externalWriteCallback: ghostty_write_callback_fn = { surface, data, len in
            // Get the SurfaceView from userdata
            guard let surface = surface,
                  let userdata = ghostty_surface_userdata(surface) else {
                NSLog("⚠️ externalWriteCallback: surface or userdata is nil")
                return
            }
            
            let surfaceView = Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
            
            // Check if surface is still valid (not closed)
            guard surfaceView.surface != nil else {
                NSLog("⚠️ externalWriteCallback: surfaceView.surface is nil (closed)")
                return
            }
            
            // Convert to Data and call the onWrite callback
            if let data = data, len > 0 {
                let swiftData = Data(bytes: data, count: Int(len))
                NSLog("⌨️ externalWriteCallback: \(len) bytes from terminal to SSH")
                DispatchQueue.main.async {
                    surfaceView.onWrite?(swiftData)
                }
            }
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }
        
        deinit {
            // Close the surface if it hasn't been closed already
            close()
        }
        
        /// Explicitly close and release the surface.
        /// Call this before the view is deallocated to ensure clean shutdown.
        func close() {
            guard let surface = surface else { return }
            
            NSLog("🔒 SurfaceView.close() - freeing surface")
            
            // Clear the onWrite callback to prevent callbacks during/after free
            onWrite = nil
            
            // Free the surface
            ghostty_surface_free(surface)
            self.surface = nil
            
            NSLog("🔒 SurfaceView.close() - surface freed")
        }
        
        // MARK: - Surface API
        
        /// Feed data to the terminal for display (e.g., from SSH)
        /// This uses ghostty_surface_write_output which feeds data directly to the
        /// terminal emulator as if it came from a subprocess/PTY output.
        func feedData(_ data: Data) {
            guard let surface = surface else {
                NSLog("⚠️ feedData called but surface is nil!")
                return
            }
            
            NSLog("🖥️ feedData: sending %d bytes to ghostty_surface_write_output", data.count)
            data.withUnsafeBytes { buffer in
                guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
                // Use write_output to feed terminal output data (SSH -> terminal display)
                // This is different from ghostty_surface_text which sends INPUT to subprocess
                ghostty_surface_write_output(surface, ptr, UInt(data.count))
            }
            NSLog("🖥️ feedData: ghostty_surface_write_output returned")
        }
        
        /// Feed a string to the terminal for display
        func feedText(_ text: String) {
            guard let data = text.data(using: .utf8) else { return }
            feedData(data)
        }
        
        /// Send text input to the terminal (user typing -> SSH)
        /// This uses ghostty_surface_text which sends input TO the subprocess/external source
        func sendInput(_ text: String) {
            guard let surface = surface else { return }
            
            let len = text.utf8CString.count
            guard len > 0 else { return }
            
            text.withCString { ptr in
                // len includes null terminator, so use len - 1
                // This sends user input TO the terminal (which should go to SSH)
                ghostty_surface_text(surface, ptr, UInt(len - 1))
            }
        }
        
        /// Send a key event to the terminal
        func sendKey(_ key: ghostty_input_key_e, action: ghostty_input_action_e, mods: ghostty_input_mods_e) {
            guard let surface = surface else { return }
            
            var keyEvent = ghostty_input_key_s(
                action: action,
                mods: mods,
                consumed_mods: GHOSTTY_MODS_NONE,
                keycode: 0,
                text: nil,
                unshifted_codepoint: 0,
                composing: false
            )
            
            _ = ghostty_surface_key(surface, keyEvent)
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
        
        /// Notify size change
        func sizeDidChange(_ size: CGSize) {
            guard let surface = surface else {
                print("[Bodak] ⚠️ sizeDidChange called but surface is nil")
                return
            }
            
            let scale = contentScaleFactor
            let scaledWidth = UInt32(size.width * scale)
            let scaledHeight = UInt32(size.height * scale)
            
            print("[Bodak] 📐 sizeDidChange: size=\(size), scale=\(scale), scaled=\(scaledWidth)x\(scaledHeight)")
            
            ghostty_surface_set_content_scale(surface, scale, scale)
            ghostty_surface_set_size(surface, scaledWidth, scaledHeight)
            
            // IMPORTANT: On iOS, the IOSurfaceLayer is added as a sublayer (not the view's layer).
            // We must manually resize it to match the view's bounds, otherwise it stays at (0,0,0,0).
            // On macOS, the IOSurfaceLayer IS the view's layer, so it auto-sizes.
            if let sublayers = layer.sublayers {
                print("[Bodak] 📐 Resizing \(sublayers.count) sublayers to match bounds: \(bounds)")
                for sublayer in sublayers {
                    // Disable implicit animations for immediate resize
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    sublayer.frame = bounds
                    sublayer.contentsScale = scale
                    CATransaction.commit()
                    print("[Bodak] 📐   Sublayer \(type(of: sublayer)) new frame: \(sublayer.frame)")
                }
            }
        }
        
        /// Get the current surface size info
        var surfaceSize: ghostty_surface_size_s? {
            guard let surface = surface else { return nil }
            return ghostty_surface_size(surface)
        }
        
        // MARK: - UIView Overrides
        
        override class var layerClass: AnyClass {
            return CAMetalLayer.self
        }
        
        // MARK: - Ghostty Metal Renderer Compatibility
        //
        // Ghostty's Metal.zig has this iOS code (line 117):
        //   info.view.msgSend(void, objc.sel("addSublayer"), .{layer.layer.value});
        //
        // The issue: objc.sel("addSublayer") creates selector "addSublayer" (NO colon),
        // but it passes an argument. In ObjC, method names include colons for parameters:
        //   - "addSublayer" = no arguments
        //   - "addSublayer:" = one argument
        //
        // This is a bug in Ghostty's iOS code path. We work around it by adding
        // a method at class initialization that handles "addSublayer" selector
        // but accepts the argument anyway.
        //
        // Note: Swift's @objc(addSublayer:) would create the selector WITH a colon,
        // which won't match what Ghostty is looking for.
        
        /// Runtime-registered flag to avoid double registration
        private static var methodsRegistered = false
        
        /// Register custom methods that Ghostty expects.
        /// This MUST be called before any SurfaceView is created.
        static func registerGhosttyMethods() {
            guard !methodsRegistered else { return }
            methodsRegistered = true
            
            // Ghostty calls "addSublayer" (no colon) but passes one argument.
            // We need to add this method at runtime since Swift can't express this.
            let selector = sel_registerName("addSublayer")
            
            // The IMP signature: void function(id self, SEL _cmd, id sublayer)
            let imp: @convention(c) (AnyObject, Selector, AnyObject) -> Void = { (self_, sel_, sublayer) in
                print("[Bodak] ⚡ addSublayer called from Ghostty - forwarding to layer")
                print("[Bodak] ⚡ self: \(type(of: self_)), sublayer: \(type(of: sublayer))")
                if let view = self_ as? UIView {
                    if let caLayer = sublayer as? CALayer {
                        view.layer.addSublayer(caLayer)
                        print("[Bodak] ✅ Successfully added sublayer to view.layer")
                    } else {
                        // Try to cast through AnyObject to id and use ObjC runtime
                        print("[Bodak] ⚠️ sublayer is not CALayer, attempting ObjC cast")
                        let obj = sublayer as AnyObject
                        if obj.isKind(of: CALayer.self) {
                            view.layer.addSublayer(obj as! CALayer)
                            print("[Bodak] ✅ Successfully added sublayer via ObjC cast")
                        } else {
                            print("[Bodak] ❌ Failed to cast sublayer to CALayer")
                        }
                    }
                }
            }
            
            // Type encoding: v = void return, @ = id (self), : = SEL, @ = id (argument)
            let typeEncoding = "v@:@"
            
            let success = class_addMethod(
                SurfaceView.self,
                selector,
                unsafeBitCast(imp, to: IMP.self),
                typeEncoding
            )
            
            if success {
                print("[Bodak] ✅ Registered 'addSublayer' (no colon) method for SurfaceView")
            } else {
                // Method already exists - try to replace it
                print("[Bodak] ⚠️ Method already exists, attempting to replace")
                let method = class_getInstanceMethod(SurfaceView.self, selector)
                if let method = method {
                    method_setImplementation(method, unsafeBitCast(imp, to: IMP.self))
                    print("[Bodak] ✅ Replaced 'addSublayer' method implementation")
                }
            }
            
            // Also add "addSublayer:" (with colon) just in case
            let selectorWithColon = sel_registerName("addSublayer:")
            let successColon = class_addMethod(
                SurfaceView.self,
                selectorWithColon,
                unsafeBitCast(imp, to: IMP.self),
                typeEncoding
            )
            if successColon {
                print("[Bodak] ✅ Registered 'addSublayer:' (with colon) method for SurfaceView")
            }
        }
        
        /// Override to forward unrecognized selectors to self.layer
        /// This catches any CALayer methods that Ghostty might call on the view
        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            let selectorName = NSStringFromSelector(aSelector)
            print("[Bodak] 🔀 forwardingTarget called for: \(selectorName)")
            
            // Check if the layer responds to this selector
            if layer.responds(to: aSelector) {
                print("[Bodak] 🔀 Forwarding \(selectorName) to layer")
                return layer
            }
            return super.forwardingTarget(for: aSelector)
        }
        
        /// Override method resolution to catch unhandled methods
        override class func resolveInstanceMethod(_ sel: Selector!) -> Bool {
            let selectorName = NSStringFromSelector(sel)
            print("[Bodak] 🔍 resolveInstanceMethod for: \(selectorName)")
            
            // If it's addSublayer (with or without colon), register our handler
            if selectorName == "addSublayer" || selectorName == "addSublayer:" {
                registerGhosttyMethods()
                return true
            }
            
            return super.resolveInstanceMethod(sel)
        }
        
        override func didMoveToWindow() {
            super.didMoveToWindow()
            print("[Bodak] 📐 didMoveToWindow: window=\(window != nil ? "present" : "nil"), frame=\(frame)")
            sizeDidChange(frame.size)
            
            // Automatically become first responder when added to a window
            if window != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    NSLog("⌨️ Auto-focusing terminal")
                    self?.becomeFirstResponder()
                }
            }
        }
        
        override func layoutSubviews() {
            super.layoutSubviews()
            print("[Bodak] 📐 layoutSubviews: bounds=\(bounds)")
            sizeDidChange(bounds.size)
        }
    }
}

// MARK: - Errors

extension Ghostty {
    enum GhosttyError: LocalizedError {
        case initFailed
        case surfaceCreationFailed
        case notReady
        
        var errorDescription: String? {
            switch self {
            case .initFailed:
                return "Failed to initialize Ghostty"
            case .surfaceCreationFailed:
                return "Failed to create terminal surface"
            case .notReady:
                return "Ghostty app is not ready"
            }
        }
    }
}
