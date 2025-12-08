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
import UserNotifications

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
        
        /// Path to the Ghostty config file in the app's documents directory
        static var configFilePath: URL {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            return documentsPath.appendingPathComponent("ghostty.conf")
        }
        
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
            
            // Write config file with user preferences
            // Note: Loading requires rebuilding the Ghostty static library with the new API
            Self.writeConfigFile()
            
            ghostty_config_finalize(config)
        }
        
        /// Write a Ghostty config file with the user's preferences
        /// This file will be loaded when we have the updated Ghostty library
        static func writeConfigFile() {
            // Get font family from user defaults
            let fontFamily = UserDefaults.standard.string(forKey: "terminal.fontFamily") ?? "SF Mono"
            
            // Map font family names to Ghostty-compatible names
            let ghosttyFontFamily = mapFontFamily(fontFamily)
            
            // Build config file content
            var configContent = """
            # Bodak Terminal Configuration
            # This file is auto-generated from app settings
            
            font-family = "\(ghosttyFontFamily)"
            
            """
            
            // Add any other config options here
            configContent += """
            # Terminal appearance
            background-opacity = 1.0
            window-padding-x = 4
            window-padding-y = 4
            
            """
            
            // Write to file
            do {
                try configContent.write(to: configFilePath, atomically: true, encoding: .utf8)
                logger.info("Wrote Ghostty config to: \(configFilePath.path)")
            } catch {
                logger.error("Failed to write Ghostty config: \(error)")
            }
        }
        
        /// Get the config string for current settings
        static func getConfigString() -> String {
            let fontFamily = UserDefaults.standard.string(forKey: "terminal.fontFamily") ?? "SF Mono"
            let ghosttyFontFamily = mapFontFamily(fontFamily)
            
            logger.info("📝 Creating config string with font: \(fontFamily) -> \(ghosttyFontFamily)")
            
            return """
            font-family = "\(ghosttyFontFamily)"
            background-opacity = 1.0
            window-padding-x = 4
            window-padding-y = 4
            """
        }
        
        /// Map user-friendly font names to Ghostty-compatible names
        static func mapFontFamily(_ fontFamily: String) -> String {
            switch fontFamily {
            case "Departure Mono":
                return "DepartureMono-Regular"
            case "SF Mono":
                return "SF Mono"
            case "Menlo":
                return "Menlo"
            case "Courier New":
                return "Courier New"
            default:
                return fontFamily
            }
        }
        
        /// Create a new config with the current user preferences
        /// Returns nil if config creation fails
        static func createConfigWithCurrentSettings() -> ghostty_config_t? {
            guard let cfg = ghostty_config_new() else {
                logger.error("Failed to create new config")
                return nil
            }
            
            // Get config string and load it directly
            let configStr = getConfigString()
            configStr.withCString { cstr in
                ghostty_config_load_string(cfg, cstr, UInt(configStr.utf8.count))
                logger.info("Loaded config string with font settings")
            }
            
            ghostty_config_finalize(cfg)
            return cfg
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
            
            // Subscribe to app lifecycle notifications for focus tracking
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(appDidBecomeActive),
                name: UIApplication.didBecomeActiveNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(appWillResignActive),
                name: UIApplication.willResignActiveNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(appDidEnterBackground),
                name: UIApplication.didEnterBackgroundNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(appWillEnterForeground),
                name: UIApplication.willEnterForegroundNotification,
                object: nil
            )
        }
        
        @objc private func appDidBecomeActive() {
            guard let app = app else { return }
            ghostty_app_set_focus(app, true)
            logger.debug("🟢 App became active - focus set")
        }
        
        @objc private func appWillResignActive() {
            guard let app = app else { return }
            ghostty_app_set_focus(app, false)
            logger.debug("🟡 App will resign active - focus cleared")
        }
        
        @objc private func appDidEnterBackground() {
            logger.debug("🟠 App entered background")
        }
        
        @objc private func appWillEnterForeground() {
            logger.debug("🟢 App will enter foreground")
        }
        
        deinit {
            NotificationCenter.default.removeObserver(self)
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
                
            case GHOSTTY_ACTION_SCROLLBAR:
                // Handle scrollbar update - extract surface from target
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let surface = target.target.surface else {
                    return false
                }
                
                // Get the scrollbar data
                let scrollbar = action.action.scrollbar
                
                // Find the SurfaceView associated with this surface
                // The surface userdata points to the SurfaceView
                if let userdata = ghostty_surface_userdata(surface) {
                    let surfaceView = Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
                    DispatchQueue.main.async {
                        surfaceView.updateScrollIndicator(
                            total: scrollbar.total,
                            offset: scrollbar.offset,
                            len: scrollbar.len
                        )
                    }
                }
                return true
                
            case GHOSTTY_ACTION_MOUSE_OVER_LINK:
                // Handle hover over link (OSC 8 hyperlinks or detected URLs)
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let surface = target.target.surface else {
                    return false
                }
                
                let linkData = action.action.mouse_over_link
                
                if let userdata = ghostty_surface_userdata(surface) {
                    let surfaceView = Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
                    DispatchQueue.main.async {
                        if linkData.len > 0, let urlPtr = linkData.url {
                            let urlData = Data(bytes: urlPtr, count: linkData.len)
                            surfaceView.hoverUrl = String(data: urlData, encoding: .utf8)
                        } else {
                            surfaceView.hoverUrl = nil
                        }
                    }
                }
                return true
                
            case GHOSTTY_ACTION_OPEN_URL:
                // Handle URL open request (user clicked a link)
                let urlData = action.action.open_url
                
                guard urlData.len > 0, let urlPtr = urlData.url else {
                    return false
                }
                
                let urlStr = String(cString: urlPtr)
                logger.info("🔗 Opening URL: \(urlStr)")
                
                DispatchQueue.main.async {
                    // Try to create URL, handling both full URLs and file paths
                    if let url = URL(string: urlStr), url.scheme != nil {
                        UIApplication.shared.open(url)
                    } else {
                        // Treat as file path - show in Files or alert
                        logger.warning("Cannot open non-URL path on iOS: \(urlStr)")
                    }
                }
                return true
                
            case GHOSTTY_ACTION_PWD:
                // Handle working directory change
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let surface = target.target.surface else {
                    return false
                }
                
                let pwdData = action.action.pwd
                
                if let userdata = ghostty_surface_userdata(surface) {
                    let surfaceView = Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
                    DispatchQueue.main.async {
                        if let pwdPtr = pwdData.pwd {
                            let pwdString = String(cString: pwdPtr)
                            surfaceView.pwd = pwdString
                            logger.debug("📁 PWD changed to: \(pwdString)")
                        }
                    }
                }
                return true
                
            case GHOSTTY_ACTION_CELL_SIZE:
                // Handle cell size change - useful for layout calculations
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let surface = target.target.surface else {
                    return false
                }
                
                let cellSizeData = action.action.cell_size
                
                if let userdata = ghostty_surface_userdata(surface) {
                    let surfaceView = Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
                    DispatchQueue.main.async {
                        surfaceView.cellSize = CGSize(
                            width: CGFloat(cellSizeData.width),
                            height: CGFloat(cellSizeData.height)
                        )
                        logger.debug("📐 Cell size: \(cellSizeData.width)x\(cellSizeData.height)")
                    }
                }
                return true
                
            case GHOSTTY_ACTION_MOUSE_SHAPE:
                // Handle mouse cursor shape change (for trackpad/mouse users)
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let surface = target.target.surface else {
                    return false
                }
                
                let shape = action.action.mouse_shape
                
                if let userdata = ghostty_surface_userdata(surface) {
                    let surfaceView = Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
                    DispatchQueue.main.async {
                        surfaceView.currentMouseShape = shape
                    }
                }
                return true
                
            case GHOSTTY_ACTION_MOUSE_VISIBILITY:
                // Handle mouse cursor visibility (hide while typing)
                // iOS handles this automatically, but we track it for consistency
                return true
                
            case GHOSTTY_ACTION_RENDERER_HEALTH:
                // Handle renderer health status
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let surface = target.target.surface else {
                    return false
                }
                
                let health = action.action.renderer_health
                
                if let userdata = ghostty_surface_userdata(surface) {
                    let surfaceView = Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
                    DispatchQueue.main.async {
                        surfaceView.healthy = (health == GHOSTTY_RENDERER_HEALTH_OK)
                        if health != GHOSTTY_RENDERER_HEALTH_OK {
                            logger.warning("⚠️ Renderer health issue: \(health.rawValue)")
                        }
                    }
                }
                return true
                
            case GHOSTTY_ACTION_COLOR_CHANGE:
                // Handle dynamic color palette change
                // Ghostty handles this internally, but we could update UI chrome if needed
                logger.debug("🎨 Color palette changed")
                return true
                
            case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
                // Handle desktop notification request
                let notification = action.action.desktop_notification
                
                if let bodyPtr = notification.body {
                    let body = String(cString: bodyPtr)
                    let title = notification.title != nil
                        ? String(cString: notification.title!)
                        : "Terminal"
                    
                    logger.info("🔔 Notification: \(title) - \(body)")
                    
                    // Request notification permission and send
                    DispatchQueue.main.async {
                        let content = UNMutableNotificationContent()
                        content.title = title
                        content.body = body
                        content.sound = .default
                        
                        let request = UNNotificationRequest(
                            identifier: UUID().uuidString,
                            content: content,
                            trigger: nil
                        )
                        
                        UNUserNotificationCenter.current().add(request) { error in
                            if let error = error {
                                logger.error("Failed to send notification: \(error)")
                            }
                        }
                    }
                }
                return true
                
            case GHOSTTY_ACTION_START_SEARCH:
                // Handle start search request
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let surface = target.target.surface else {
                    return false
                }
                
                let searchData = action.action.start_search
                
                if let userdata = ghostty_surface_userdata(surface) {
                    let surfaceView = Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
                    DispatchQueue.main.async {
                        surfaceView.isSearching = true
                        if let needlePtr = searchData.needle {
                            surfaceView.searchQuery = String(cString: needlePtr)
                        }
                        logger.debug("🔍 Search started with query: \(surfaceView.searchQuery)")
                    }
                }
                return true
                
            case GHOSTTY_ACTION_END_SEARCH:
                // Handle end search request
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let surface = target.target.surface else {
                    return false
                }
                
                if let userdata = ghostty_surface_userdata(surface) {
                    let surfaceView = Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
                    DispatchQueue.main.async {
                        surfaceView.isSearching = false
                        surfaceView.searchQuery = ""
                        surfaceView.searchTotal = 0
                        surfaceView.searchSelected = 0
                        logger.debug("🔍 Search ended")
                    }
                }
                return true
                
            case GHOSTTY_ACTION_SEARCH_TOTAL:
                // Handle search results count update
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let surface = target.target.surface else {
                    return false
                }
                
                let totalData = action.action.search_total
                
                if let userdata = ghostty_surface_userdata(surface) {
                    let surfaceView = Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
                    DispatchQueue.main.async {
                        surfaceView.searchTotal = Int(totalData.total)
                        logger.debug("🔍 Search total: \(totalData.total)")
                    }
                }
                return true
                
            case GHOSTTY_ACTION_SEARCH_SELECTED:
                // Handle selected search result update
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let surface = target.target.surface else {
                    return false
                }
                
                let selectedData = action.action.search_selected
                
                if let userdata = ghostty_surface_userdata(surface) {
                    let surfaceView = Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
                    DispatchQueue.main.async {
                        surfaceView.searchSelected = Int(selectedData.selected)
                        logger.debug("🔍 Search selected: \(selectedData.selected)")
                    }
                }
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
            // Read from system clipboard and send to Ghostty
            guard let userdata = userdata else { return }
            let surfaceView = Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
            guard let surface = surfaceView.surface else { return }
            
            // Get clipboard contents
            let str = UIPasteboard.general.string ?? ""
            
            // Complete the clipboard request with the content
            str.withCString { ptr in
                ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
            }
            
            logger.debug("📋 Read clipboard: \(str.prefix(50))...")
        }
        
        private static func confirmReadClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            string: UnsafePointer<CChar>?,
            state: UnsafeMutableRawPointer?,
            request: ghostty_clipboard_request_e
        ) {
            // For security confirmation before pasting sensitive content
            // On iOS, we auto-confirm since the system already handles clipboard permissions
            guard let userdata = userdata else { return }
            let surfaceView = Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
            guard let surface = surfaceView.surface else { return }
            
            // Get the string being requested
            let str: String
            if let cStr = string {
                str = String(cString: cStr)
            } else {
                str = ""
            }
            
            // Auto-confirm on iOS (the system already manages clipboard access)
            str.withCString { ptr in
                ghostty_surface_complete_clipboard_request(surface, ptr, state, true)
            }
            
            logger.debug("📋 Confirmed clipboard read")
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
        
        /// Scrollbar state (total rows, offset, visible length)
        @Published var scrollbar: (total: UInt64, offset: UInt64, len: UInt64)? = nil
        
        /// URL being hovered over (OSC 8 hyperlinks or detected URLs)
        @Published var hoverUrl: String? = nil
        
        /// Current mouse cursor shape (for trackpad/mouse users)
        var currentMouseShape: ghostty_action_mouse_shape_e = GHOSTTY_MOUSE_SHAPE_DEFAULT
        
        /// Search state
        @Published var isSearching: Bool = false
        @Published var searchQuery: String = ""
        @Published var searchTotal: Int = 0
        @Published var searchSelected: Int = 0
        
        /// Current font size (starts at config default)
        @Published var currentFontSize: Float = 14.0
        
        /// Font size constraints
        static let minFontSize: Float = 6.0
        static let maxFontSize: Float = 72.0
        static let defaultFontSize: Float = 14.0
        
        /// Pinch gesture state
        private var pinchStartFontSize: Float = 14.0
        
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
            longPressGesture.delegate = self
            addGestureRecognizer(longPressGesture)
            
            // Add single-finger pan gesture for scrolling (primary touch scroll)
            let singleFingerScrollGesture = UIPanGestureRecognizer(target: self, action: #selector(handleSingleFingerScroll(_:)))
            singleFingerScrollGesture.minimumNumberOfTouches = 1
            singleFingerScrollGesture.maximumNumberOfTouches = 1
            singleFingerScrollGesture.delegate = self
            addGestureRecognizer(singleFingerScrollGesture)
            
            // Add two-finger pan gesture for scrolling (alternative)
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
            
            // Add pointer interaction for external mouse/trackpad support
            let pointerInteraction = UIPointerInteraction(delegate: self)
            addInteraction(pointerInteraction)
            
            // Add hover gesture for mouse movement tracking
            let hoverGesture = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
            addGestureRecognizer(hoverGesture)
            
            // Add pinch gesture for font size zoom
            let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            addGestureRecognizer(pinchGesture)
            
            // Setup scroll indicator
            setupScrollIndicator()
            
            // Set initial color scheme based on current trait collection
            updateColorScheme()
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
        
        /// Called when iOS appearance changes (dark/light mode)
        override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)
            
            if traitCollection.userInterfaceStyle != previousTraitCollection?.userInterfaceStyle {
                updateColorScheme()
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
            
            UIView.animate(withDuration: 0.15) {
                self.scrollIndicator?.alpha = 1
            }
            
            // Hide after delay
            scrollIndicatorHideTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                UIView.animate(withDuration: 0.3) {
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
        private var scrollVelocity: CGFloat = 0
        private let scrollDeceleration: CGFloat = 0.95  // Slower deceleration for smoother momentum
        private let scrollMinVelocity: CGFloat = 0.3
        
        /// Track accumulated scroll for gesture
        private var accumulatedScrollY: CGFloat = 0
        
        /// Adaptive scroll settings
        /// Base sensitivity for slow/precise scrolling
        private let baseScrollSensitivity: CGFloat = 0.8
        /// How much velocity amplifies scrolling (higher = faster scrolls go further)  
        private let velocityAmplification: CGFloat = 0.002
        /// Maximum multiplier to prevent runaway scrolling
        private let maxScrollMultiplier: CGFloat = 4.0
        /// Trackpad sensitivity (usually doesn't need velocity scaling)
        private let trackpadScrollSensitivity: CGFloat = 1.0
        
        /// Calculate adaptive scroll amount based on gesture velocity
        /// Slow movements = precise (1:1), fast movements = amplified
        private func adaptiveScrollAmount(delta: CGFloat, velocity: CGFloat) -> CGFloat {
            let absVelocity = abs(velocity)
            // Scale from 1.0 (slow) up to maxScrollMultiplier (fast)
            let velocityMultiplier = min(maxScrollMultiplier, 1.0 + absVelocity * velocityAmplification)
            return delta * baseScrollSensitivity * velocityMultiplier
        }
        
        /// Handle two-finger touch scrolling
        @objc private func handleScroll(_ gesture: UIPanGestureRecognizer) {
            guard let surface = surface else { return }
            
            let translation = gesture.translation(in: self)
            let velocity = gesture.velocity(in: self)
            
            switch gesture.state {
            case .began:
                stopScrollMomentum()
                accumulatedScrollY = 0
                
            case .changed:
                // Convert pan translation to scroll delta
                let deltaY = translation.y - accumulatedScrollY
                accumulatedScrollY = translation.y
                
                // Adaptive: slow swipes are precise, fast swipes cover more ground
                let scrollAmount = adaptiveScrollAmount(delta: deltaY, velocity: velocity.y)
                ghostty_surface_mouse_scroll(surface, 0, Double(scrollAmount), 0)
                
            case .ended:
                accumulatedScrollY = 0
                // Momentum based on release velocity - faster flick = more momentum
                let momentumVelocity = velocity.y * baseScrollSensitivity * 0.15
                startScrollMomentum(velocity: momentumVelocity)
                
            case .cancelled:
                accumulatedScrollY = 0
                stopScrollMomentum()
                
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
                accumulatedTrackpadScrollY = 0
                
            case .changed:
                // Convert trackpad pan to scroll delta
                let deltaY = translation.y - accumulatedTrackpadScrollY
                accumulatedTrackpadScrollY = translation.y
                
                // Trackpad uses natural scrolling (same direction as touch)
                let scrollAmount = deltaY * trackpadScrollSensitivity
                ghostty_surface_mouse_scroll(surface, 0, Double(scrollAmount), 0)
                
            case .ended, .cancelled:
                accumulatedTrackpadScrollY = 0
                
            default:
                break
            }
        }
        
        // MARK: - Momentum Scrolling
        
        private func startScrollMomentum(velocity: CGFloat) {
            guard abs(velocity) > scrollMinVelocity else { return }
            
            scrollVelocity = velocity
            
            scrollDisplayLink?.invalidate()
            scrollDisplayLink = CADisplayLink(target: self, selector: #selector(updateScrollMomentum))
            scrollDisplayLink?.add(to: .main, forMode: .common)
        }
        
        private func stopScrollMomentum() {
            scrollDisplayLink?.invalidate()
            scrollDisplayLink = nil
            scrollVelocity = 0
        }
        
        @objc private func updateScrollMomentum() {
            guard let surface = surface else {
                stopScrollMomentum()
                return
            }
            
            // Apply deceleration
            scrollVelocity *= scrollDeceleration
            
            // Stop if velocity is too low
            if abs(scrollVelocity) < scrollMinVelocity {
                stopScrollMomentum()
                return
            }
            
            // Apply scroll
            ghostty_surface_mouse_scroll(surface, 0, Double(scrollVelocity), 0)
        }
        
        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            NSLog("👆 Terminal tapped, becoming first responder")
            stopScrollMomentum()
            becomeFirstResponder()
            
            // If Ctrl toggle is active, this tap should open a link
            if ctrlToggleActive, let surface = surface {
                let point = gesture.location(in: self)
                let scale = contentScaleFactor
                
                NSLog("👆 Ctrl+tap at \(point) - attempting to open link")
                
                // Send mouse position and click with Ctrl modifier
                ghostty_surface_mouse_pos(surface, point.x * scale, point.y * scale, GHOSTTY_MODS_CTRL)
                _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_CTRL)
                _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_CTRL)
                
                // Reset Ctrl toggle
                ctrlToggleActive = false
            }
        }
        
        /// Handle two-finger tap to open links (equivalent to Cmd+click on macOS)
        @objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
            guard let surface = surface else { return }
            
            // Get the midpoint of the two touches
            let point = gesture.location(in: self)
            let scale = contentScaleFactor
            
            NSLog("👆👆 Two-finger tap at \(point) - attempting to open link")
            
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
            
            NSLog("👆👆 Double-tap at \(point) - selecting word")
            
            // Position the mouse
            ghostty_surface_mouse_pos(surface, point.x * scale, point.y * scale, GHOSTTY_MODS_NONE)
            
            // Double-click to select word
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
            
            // Provide haptic feedback
            let feedbackGenerator = UIImpactFeedbackGenerator(style: .light)
            feedbackGenerator.impactOccurred()
        }
        
        /// Handle triple-tap for line selection
        @objc private func handleTripleTap(_ gesture: UITapGestureRecognizer) {
            guard let surface = surface else { return }
            
            let point = gesture.location(in: self)
            let scale = contentScaleFactor
            
            NSLog("👆👆👆 Triple-tap at \(point) - selecting line")
            
            // Position the mouse
            ghostty_surface_mouse_pos(surface, point.x * scale, point.y * scale, GHOSTTY_MODS_NONE)
            
            // Triple-click to select line
            for _ in 0..<3 {
                _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
                _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
            }
            
            // Provide haptic feedback
            let feedbackGenerator = UIImpactFeedbackGenerator(style: .medium)
            feedbackGenerator.impactOccurred()
        }
        
        /// Handle two-finger double-tap to reset font size
        @objc private func handleTwoFingerDoubleTap(_ gesture: UITapGestureRecognizer) {
            NSLog("👆👆 Two-finger double-tap - resetting font size")
            resetFontSize()
            
            // Provide haptic feedback
            let feedbackGenerator = UINotificationFeedbackGenerator()
            feedbackGenerator.notificationOccurred(.success)
        }
        
        // MARK: - UIGestureRecognizerDelegate
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // Allow hover to work simultaneously with other gestures
            if gestureRecognizer is UIHoverGestureRecognizer || otherGestureRecognizer is UIHoverGestureRecognizer {
                return true
            }
            return false
        }
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // Single finger pan should wait for long press to fail (so long press can trigger selection)
            // But use a very short delay
            if gestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer is UILongPressGestureRecognizer {
                return false  // Don't wait - let pan start immediately, long press will cancel it if held
            }
            return false
        }

        /// Track if we're in selection mode (from long press)
        private var isSelecting = false
        
        /// Track accumulated single-finger scroll
        private var accumulatedSingleFingerScrollY: CGFloat = 0
        
        /// Handle single-finger pan for scrolling
        @objc private func handleSingleFingerScroll(_ gesture: UIPanGestureRecognizer) {
            // Don't scroll if we're selecting
            guard !isSelecting else { return }
            guard let surface = surface else { return }
            
            let translation = gesture.translation(in: self)
            let velocity = gesture.velocity(in: self)
            
            switch gesture.state {
            case .began:
                stopScrollMomentum()
                accumulatedSingleFingerScrollY = 0
                
            case .changed:
                // Convert pan translation to scroll delta
                let deltaY = translation.y - accumulatedSingleFingerScrollY
                accumulatedSingleFingerScrollY = translation.y
                
                // Adaptive: slow = precise review, fast = rapid search
                let scrollAmount = adaptiveScrollAmount(delta: deltaY, velocity: velocity.y)
                ghostty_surface_mouse_scroll(surface, 0, Double(scrollAmount), 0)
                
            case .ended:
                accumulatedSingleFingerScrollY = 0
                // Momentum based on release velocity
                let momentumVelocity = velocity.y * baseScrollSensitivity * 0.15
                startScrollMomentum(velocity: momentumVelocity)
                
            case .cancelled:
                accumulatedSingleFingerScrollY = 0
                stopScrollMomentum()
                
            default:
                break
            }
        }
        
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
            
            // Haptic feedback when Ctrl toggle changes
            let feedbackGenerator = UIImpactFeedbackGenerator(style: active ? .medium : .light)
            feedbackGenerator.impactOccurred()
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
            
            // For Ctrl+key combinations on press, send control character directly
            // This ensures apps like tmux, vim, blightmud receive proper control sequences
            if action == GHOSTTY_ACTION_PRESS,
               mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 {
                let charsIgnoring = key.charactersIgnoringModifiers
                if let char = charsIgnoring.unicodeScalars.first {
                    let ctrlChar = controlCharacter(for: char, mods: mods)
                    if !ctrlChar.isEmpty {
                        NSLog("⌨️ HW Ctrl+\(charsIgnoring) -> \\x\(String(format: "%02X", ctrlChar.utf8.first ?? 0))")
                        ctrlChar.withCString { ptr in
                            ghostty_surface_text(surface, ptr, UInt(ctrlChar.utf8.count))
                        }
                        return true
                    }
                }
            }
            
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
        
        // MARK: - First Responder
        
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
            }
            return result
        }
        
        // MARK: - Visibility/Occlusion
        
        /// Set surface visibility for performance optimization
        func setVisible(_ visible: Bool) {
            guard let surface = surface else { return }
            ghostty_surface_set_occlusion(surface, !visible)
        }
        
        // MARK: - Search
        
        /// Start a search in the terminal
        func startSearch(_ query: String = "") {
            guard let surface = surface else { return }
            let action = query.isEmpty ? "start_search" : "search:\(query)"
            ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
        }
        
        /// Update the search query
        func updateSearch(_ query: String) {
            guard let surface = surface else { return }
            let action = "search:\(query)"
            ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
        }
        
        /// Navigate to next search result
        func searchNext() {
            guard let surface = surface else { return }
            let action = "search_next"
            ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
        }
        
        /// Navigate to previous search result
        func searchPrevious() {
            guard let surface = surface else { return }
            let action = "search_previous"
            ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
        }
        
        /// End the current search
        func endSearch() {
            guard let surface = surface else { return }
            let action = "end_search"
            ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
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
        
        /// Update the terminal configuration (e.g., font family)
        /// This creates a new config with current settings and applies it to the surface
        func updateConfig() {
            guard let surface = surface else {
                logger.warning("Cannot update config: surface is nil")
                return
            }
            
            // Log current state before update
            let fontFamily = UserDefaults.standard.string(forKey: "terminal.fontFamily") ?? "SF Mono"
            logger.info("🔧 updateConfig called - current font preference: \(fontFamily)")
            
            // Create a new config with current user preferences
            guard let newConfig = Config.createConfigWithCurrentSettings() else {
                logger.error("Failed to create new config for update")
                return
            }
            
            logger.info("🔧 Applying new config to surface...")
            
            // Apply the new config to the surface
            ghostty_surface_update_config(surface, newConfig)
            logger.info("✅ Updated surface config with font: \(fontFamily)")
            
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
                let feedbackGenerator = UIImpactFeedbackGenerator(style: .light)
                feedbackGenerator.impactOccurred()
                
            default:
                break
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
            
            // Keep scroll indicator on right edge (without animation)
            if let indicator = scrollIndicator {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                indicator.frame.origin.x = bounds.width - 6
                CATransaction.commit()
            }
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
