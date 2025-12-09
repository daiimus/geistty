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
            
            // Get font rendering settings (default to true if not set)
            let defaults = UserDefaults.standard
            let fontThicken: Bool
            if defaults.object(forKey: "terminal.fontThicken") != nil {
                fontThicken = defaults.bool(forKey: "terminal.fontThicken")
            } else {
                fontThicken = true  // Default to on for crisp text
            }
            
            // Get cursor style (block, bar, underline)
            let cursorStyle = defaults.string(forKey: "terminal.cursorStyle") ?? "block"
            
            // Get theme config from ThemeManager
            let themeConfig = ThemeManager.shared.getThemeConfigString()
            
            logger.info("📝 Creating config string with font: \(fontFamily) -> \(ghosttyFontFamily)")
            logger.info("📝 Font thicken: \(fontThicken)")
            logger.info("📝 Cursor style: \(cursorStyle)")
            logger.info("📝 Theme: \(ThemeManager.shared.selectedTheme.name)")
            
            return """
            font-family = "\(ghosttyFontFamily)"
            background-opacity = 1.0
            window-padding-x = 4
            window-padding-y = 4
            
            # Font rendering for crisp text on Retina displays
            font-thicken = \(fontThicken)
            
            # Freetype hinting options for optimal clarity
            # light hinting preserves glyph shapes while improving alignment
            freetype-load-flags = hinting, autohint, light
            
            # Fancy text rendering features
            # Use Unicode standard for proper emoji and non-English character widths
            grapheme-width-method = unicode
            
            # Bold text uses bright colors (classic terminal look)
            bold-color = bright
            
            # Blinking cursor for visibility
            cursor-style = \(cursorStyle)
            cursor-style-blink = true
            
            # URL detection and hyperlinks
            link-url = true
            
            # === TUI App Optimizations ===
            # For apps like Yazi, kew, aichat, browsh, mpv
            
            # Kitty graphics protocol - enables image previews in Yazi, ranger, etc.
            # 500MB limit for image-heavy workflows (default is 320MB)
            image-storage-limit = 500000000
            
            # OSC 52 clipboard - allows remote apps to copy to local clipboard
            clipboard-read = allow
            clipboard-write = allow
            
            # Mouse reporting - essential for TUI navigation
            # (enabled by default, but explicit for clarity)
            
            # Scrollback for reviewing output
            scrollback-limit = 10000
            
            \(themeConfig)
            """
        }
        
        /// Map user-friendly font names to Ghostty-compatible names
        /// Ghostty uses CoreText font family names (not PostScript names)
        static func mapFontFamily(_ fontFamily: String) -> String {
            switch fontFamily {
            case "Departure Mono":
                return "Departure Mono"
            case "JetBrains Mono":
                return "JetBrains Mono"
            case "Fira Code":
                return "Fira Code"
            case "Hack":
                return "Hack"
            case "Source Code Pro":
                return "Source Code Pro"
            case "IBM Plex Mono":
                return "IBM Plex Mono"
            case "Inconsolata":
                return "Inconsolata"
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
                        // Track whether we're scrolled up from the bottom
                        // offset + len == total means we're at the bottom
                        surfaceView.isScrolledUp = (scrollbar.offset + scrollbar.len) < scrollbar.total
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
        
        /// Callback for when the terminal grid size changes (cols, rows)
        var onResize: ((Int, Int) -> Void)?
        
        /// Focus state tracking
        private var hasFocusState: Bool = false
        private var focusInstant: ContinuousClock.Instant? = nil
        
        // MARK: - UIKeyInput conformance
        
        /// Required: Can this view become first responder?
        override var canBecomeFirstResponder: Bool { true }
        
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
        func insertText(_ text: String) {
            // Check if Ctrl toggle is active (from on-screen button)
            if ctrlToggleActive {
                ctrlToggleActive = false
                if text.count == 1, let scalar = text.unicodeScalars.first {
                    let bytes = applyControlToCharacter(scalar)
                    if !bytes.isEmpty {
                        sendBytes(bytes)
                        return
                    }
                }
            }
            
            // Send text directly to SSH
            if let data = text.data(using: .utf8) {
                onWrite?(data)
            }
        }
        
        /// Required: Handle backspace/delete
        func deleteBackward() {
            sendBytes([0x7f])  // DEL character
        }
        
        // MARK: - Byte sending helpers
        
        /// Send raw bytes directly to SSH (bypasses terminal emulator)
        private func sendBytes(_ bytes: [UInt8]) {
            guard !bytes.isEmpty else { return }
            let data = Data(bytes)
            onWrite?(data)
        }
        
        /// Convert character to control sequence (Ctrl+A = 0x01, etc.)
        private func applyControlToCharacter(_ scalar: UnicodeScalar) -> [UInt8] {
            let value = scalar.value
            
            // Ctrl+A through Ctrl+Z -> 0x01-0x1A
            if value >= 0x61 && value <= 0x7A {  // a-z
                return [UInt8(value - 0x60)]
            }
            if value >= 0x41 && value <= 0x5A {  // A-Z
                return [UInt8(value - 0x40)]
            }
            
            // Special control characters
            switch scalar {
            case "[":  return [0x1B]  // ESC
            case "\\":  return [0x1C]  // FS
            case "]":  return [0x1D]  // GS
            case "^":  return [0x1E]  // RS
            case "_":  return [0x1F]  // US
            case "@":  return [0x00]  // NUL
            case " ":  return [0x00]  // Ctrl+Space = NUL
            default:   return []
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
            
            // Register for trait changes (dark/light mode)
            registerForTraitChanges()
            
            // Set initial color scheme based on current trait collection
            updateColorScheme()
            
            // Configure accessibility
            setupAccessibility()
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
        
        /// Update accessibility value with current terminal state
        func updateAccessibilityValue() {
            var value = ""
            if let currentPwd = pwd {
                value += "Current directory: \(currentPwd). "
            }
            if !title.isEmpty && title != "Terminal" {
                value += "Title: \(title). "
            }
            if let scrollState = scrollbar, scrollState.total > scrollState.len {
                let scrollPercent = Int(Double(scrollState.offset) / Double(scrollState.total - scrollState.len) * 100)
                value += "Scrolled \(scrollPercent) percent. "
            }
            accessibilityValue = value.isEmpty ? nil : value
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
        
        private func startScrollMomentum(velocity: CGFloat) {
            guard abs(velocity) > scrollMinVelocity else { return }
            
            scrollVelocity = velocity
            initialMomentumVelocity = abs(velocity)
            momentumFrameCount = 0
            
            scrollDisplayLink?.invalidate()
            scrollDisplayLink = CADisplayLink(target: self, selector: #selector(updateScrollMomentum))
            scrollDisplayLink?.add(to: .main, forMode: .common)
        }
        
        private func stopScrollMomentum() {
            scrollDisplayLink?.invalidate()
            scrollDisplayLink = nil
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
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            if isMomentumScrolling {
                stopScrollMomentum()
            }
            super.touchesBegan(touches, with: event)
        }
        
        @objc private func updateScrollMomentum() {
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
            // Tap to stop momentum scrolling (like hitting a spinning wheel to stop)
            if isMomentumScrolling {
                NSLog("👆 Tap to stop momentum scrolling")
                stopScrollMomentum()
                return
            }
            
            NSLog("👆 Terminal tapped, becoming first responder")
            _ = becomeFirstResponder()
            
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

        /// Track if we're in selection mode (from long press)
        private var isSelecting = false
        
        /// Track accumulated single-finger scroll
        private var accumulatedSingleFingerScrollY: CGFloat = 0
        
        /// Handle single-finger pan for scrolling - lifelike iOS-style physics
        @objc private func handleSingleFingerScroll(_ gesture: UIPanGestureRecognizer) {
            // Don't scroll if we're selecting text
            guard !isSelecting else { return }
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
        
        /// Edit menu interaction for copy/paste (iOS 16+)
        private var editMenuInteraction: UIEditMenuInteraction?
        
        /// Show a copy menu at the given point using modern UIEditMenuInteraction
        private func showCopyMenu(at point: CGPoint) {
            // Create edit menu interaction if needed
            if editMenuInteraction == nil {
                editMenuInteraction = UIEditMenuInteraction(delegate: nil)
                addInteraction(editMenuInteraction!)
            }
            
            let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: point)
            editMenuInteraction?.presentEditMenu(with: config)
        }
        
        /// Override canPerformAction to enable copy
        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            // Prevent system "cut" action from intercepting Ctrl+X
            if action == #selector(UIResponderStandardEditActions.cut(_:)) {
                return false
            }
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
        
        /// Handle paste action using Ghostty's paste_from_clipboard action
        /// This properly handles bracketed paste mode for tmux/vim
        @objc override func paste(_ sender: Any?) {
            guard let surface = surface else { return }
            let action = "paste_from_clipboard"
            if !ghostty_surface_binding_action(surface, action, UInt(action.utf8.count)) {
                // Fallback to direct insertion if action fails
                if let text = UIPasteboard.general.string {
                    insertText(text)
                }
                logger.warning("paste_from_clipboard action failed, falling back to direct insert")
            } else {
                logger.debug("📋 Paste via Ghostty (bracketed paste mode aware)")
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
        
        /// Set Ctrl toggle state (from toolbar button)
        func setCtrlToggle(_ active: Bool) {
            ctrlToggleActive = active
            
            // Haptic feedback when Ctrl toggle changes
            let feedbackGenerator = UIImpactFeedbackGenerator(style: active ? .medium : .light)
            feedbackGenerator.impactOccurred()
        }
        
        /// Handle hardware keyboard key presses (Magic Keyboard, etc.)
        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            for press in presses {
                guard let key = press.key else { continue }
                
                // Check for Command (Cmd) modifier for app shortcuts
                let hasCmd = key.modifierFlags.contains(.command)
                if hasCmd {
                    let char = key.charactersIgnoringModifiers.lowercased()
                    switch char {
                    case "c":
                        // Cmd+C - Copy
                        self.copy(nil)
                        return
                    case "v":
                        // Cmd+V - Paste
                        self.paste(nil)
                        return
                    case "a":
                        // Cmd+A - Select All
                        self.selectAll()
                        return
                    case "k":
                        // Cmd+K - Clear Screen
                        if let data = "\u{0C}".data(using: .utf8) {
                            onWrite?(data)
                        }
                        return
                    case "0":
                        // Cmd+0 - Reset Font Size
                        resetFontSize()
                        return
                    case "+", "=":
                        // Cmd++ - Increase Font Size
                        increaseFontSize()
                        return
                    case "-":
                        // Cmd+- - Decrease Font Size
                        decreaseFontSize()
                        return
                    case "w":
                        // Cmd+W - Disconnect (post notification)
                        NotificationCenter.default.post(name: Notification.Name("terminalDisconnect"), object: nil)
                        return
                    default:
                        break
                    }
                }
                
                // Check for Ctrl modifier
                let hasCtrl = key.modifierFlags.contains(.control) || ctrlToggleActive
                if ctrlToggleActive { ctrlToggleActive = false }
                
                // Handle Ctrl+key combinations
                if hasCtrl {
                    if let scalar = key.charactersIgnoringModifiers.unicodeScalars.first {
                        let bytes = applyControlToCharacter(scalar)
                        if !bytes.isEmpty {
                            sendBytes(bytes)
                            return
                        }
                    }
                }
                
                // Handle special keys
                switch key.keyCode {
                case .keyboardEscape:
                    sendBytes([0x1B])
                    return
                case .keyboardTab:
                    sendBytes([0x09])
                    return
                case .keyboardDeleteOrBackspace:
                    sendBytes([0x7F])
                    return
                case .keyboardReturnOrEnter:
                    sendBytes([0x0D])
                    return
                case .keyboardUpArrow:
                    sendBytes([0x1B, 0x5B, 0x41])  // ESC [ A
                    return
                case .keyboardDownArrow:
                    sendBytes([0x1B, 0x5B, 0x42])  // ESC [ B
                    return
                case .keyboardRightArrow:
                    sendBytes([0x1B, 0x5B, 0x43])  // ESC [ C
                    return
                case .keyboardLeftArrow:
                    sendBytes([0x1B, 0x5B, 0x44])  // ESC [ D
                    return
                case .keyboardHome:
                    sendBytes([0x1B, 0x5B, 0x48])  // ESC [ H
                    return
                case .keyboardEnd:
                    sendBytes([0x1B, 0x5B, 0x46])  // ESC [ F
                    return
                case .keyboardPageUp:
                    sendBytes([0x1B, 0x5B, 0x35, 0x7E])  // ESC [ 5 ~
                    return
                case .keyboardPageDown:
                    sendBytes([0x1B, 0x5B, 0x36, 0x7E])  // ESC [ 6 ~
                    return
                case .keyboardDeleteForward:
                    sendBytes([0x1B, 0x5B, 0x33, 0x7E])  // ESC [ 3 ~
                    return
                default:
                    break
                }
                
                // Regular character input
                let chars = key.characters
                if !chars.isEmpty {
                    if let data = chars.data(using: .utf8) {
                        onWrite?(data)
                    }
                    return
                }
            }
            
            super.pressesBegan(presses, with: event)
        }
        
        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            super.pressesEnded(presses, with: event)
        }
        
        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            super.pressesCancelled(presses, with: event)
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
            
            // Send press event
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = GHOSTTY_ACTION_PRESS
            keyEvent.keycode = key.rawValue
            keyEvent.mods = mods
            keyEvent.consumed_mods = GHOSTTY_MODS_NONE
            keyEvent.composing = false
            keyEvent.text = nil
            keyEvent.unshifted_codepoint = 0
            
            _ = ghostty_surface_key(surface, keyEvent)
            
            // Send release event
            keyEvent.action = GHOSTTY_ACTION_RELEASE
            _ = ghostty_surface_key(surface, keyEvent)
        }
        
        /// Send a key event to the terminal (deprecated - use sendVirtualKey instead)
        func sendKey(_ key: ghostty_input_key_e, action: ghostty_input_action_e, mods: ghostty_input_mods_e) {
            guard let surface = surface else { return }
            
            let keyEvent = ghostty_input_key_s(
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
            
            // Get the updated grid size and notify the resize callback
            // This is crucial for SSH PTY sizing
            if let gridSize = surfaceSize {
                let cols = Int(gridSize.columns)
                let rows = Int(gridSize.rows)
                print("[Bodak] 📐 Grid size: \(cols)x\(rows)")
                onResize?(cols, rows)
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
            
            // Focus management: request keyboard focus when added to window
            // Use RunLoop to ensure view is fully laid out first
            if window != nil {
                RunLoop.main.perform { [weak self] in
                    guard let self = self, self.window != nil else { return }
                    // Only become first responder if we're visible and in the window
                    if !self.isFirstResponder {
                        NSLog("⌨️ Requesting keyboard focus")
                        _ = self.becomeFirstResponder()
                    }
                }
            } else {
                // Resign when removed from window to clean up keyboard
                if self.isFirstResponder {
                    _ = self.resignFirstResponder()
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
