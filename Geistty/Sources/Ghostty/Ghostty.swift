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
            
            // Load config from file (source of truth)
            // getConfigString() creates default file if needed
            let configStr = Self.getConfigString()
            configStr.withCString { cstr in
                ghostty_config_load_string(cfg, cstr, UInt(configStr.utf8.count))
                logger.info("Loaded config from file into Ghostty")
            }
            
            ghostty_config_finalize(config)
        }
        
        /// Get config string - FILE IS SOURCE OF TRUTH
        /// If ghostty.conf exists, read from it; otherwise generate defaults
        static func getConfigString() -> String {
            // Check if config file exists and read from it
            if FileManager.default.fileExists(atPath: configFilePath.path),
               let content = try? String(contentsOf: configFilePath, encoding: .utf8) {
                logger.info("📖 Reading config from file: \(configFilePath.path)")
                return content
            }
            
            // No file exists, generate default config and save it
            logger.info("📝 No config file found, creating with defaults")
            let defaultConfig = generateDefaultConfig()
            
            // Save the default config to file so user can edit it
            do {
                try defaultConfig.write(to: configFilePath, atomically: true, encoding: .utf8)
                logger.info("📝 Created default config file at: \(configFilePath.path)")
            } catch {
                logger.error("Failed to write default config: \(error)")
            }
            
            return defaultConfig
        }
        
        /// Generate a default config string (used when no file exists)
        /// This is a static template - no dependencies on ThemeManager or UserDefaults
        static func generateDefaultConfig() -> String {
            return """
            # Geistty Terminal Configuration
            # This file is the source of truth - edit directly
            # Reload with Cmd+Shift+, or from Settings
            
            # === Font Settings ===
            font-family = "SF Mono"
            font-thicken = true
            
            # Freetype hinting for clarity
            freetype-load-flags = hinting, autohint, light
            
            # Unicode standard for emoji/CJK widths
            grapheme-width-method = unicode
            
            # === Cursor ===
            cursor-style = block
            cursor-style-blink = true
            
            # === Colors ===
            # Using Ghostty default theme (or specify: theme = tokyo-night)
            background-opacity = 0.95
            bold-color = bright
            
            # === Input ===
            # Treat Option key as Alt for vim/emacs/tmux keybindings
            # (Alt+b/f for word nav, Alt+. for last arg, etc.)
            macos-option-as-alt = true
            
            # === Terminal Behavior ===
            window-padding-x = 4
            window-padding-y = 4
            scrollback-limit = 0
            
            # URL detection
            link-url = true
            
            # === Clipboard ===
            clipboard-read = allow
            clipboard-write = allow
            copy-on-select = false
            
            # === Graphics (for TUI apps like Yazi) ===
            image-storage-limit = 500000000
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
                        // Initialize search state with the initial needle from the action
                        let initialNeedle: String
                        if let needlePtr = searchData.needle {
                            initialNeedle = String(cString: needlePtr)
                        } else {
                            initialNeedle = ""
                        }
                        
                        if surfaceView.searchState != nil {
                            // Search already active, just focus it
                            NotificationCenter.default.post(name: .ghosttySearchFocus, object: surfaceView)
                        } else {
                            surfaceView.searchState = SearchState(needle: initialNeedle)
                        }
                        logger.debug("🔍 Search started with query: \(initialNeedle)")
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
                        surfaceView.searchState = nil
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
                    let total: UInt? = totalData.total >= 0 ? UInt(totalData.total) : nil
                    DispatchQueue.main.async {
                        surfaceView.searchState?.total = total
                        logger.debug("🔍 Search total: \(total ?? 0)")
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
                    let selected: UInt? = selectedData.selected >= 0 ? UInt(selectedData.selected) : nil
                    DispatchQueue.main.async {
                        surfaceView.searchState?.selected = selected
                        logger.debug("🔍 Search selected: \(selected ?? 0)")
                    }
                }
                return true
                
            case GHOSTTY_ACTION_KEY_TABLE:
                // Handle key table activation/deactivation (vim-style modal keys)
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let surface = target.target.surface else {
                    return false
                }
                
                let keyTableData = action.action.key_table
                
                if let userdata = ghostty_surface_userdata(surface) {
                    let surfaceView = Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
                    DispatchQueue.main.async {
                        switch keyTableData.tag {
                        case GHOSTTY_KEY_TABLE_ACTIVATE:
                            // Key table activated - show indicator
                            if let namePtr = keyTableData.value.activate.name {
                                let name = String(cString: namePtr)
                                surfaceView.activeKeyTable = name
                                logger.info("⌨️ Key table activated: \(name)")
                            }
                        case GHOSTTY_KEY_TABLE_DEACTIVATE:
                            // Key table deactivated - hide indicator
                            surfaceView.activeKeyTable = nil
                            logger.info("⌨️ Key table deactivated")
                        case GHOSTTY_KEY_TABLE_DEACTIVATE_ALL:
                            // All key tables deactivated
                            surfaceView.activeKeyTable = nil
                            logger.info("⌨️ All key tables deactivated")
                        default:
                            break
                        }
                    }
                }
                return true
                
            case GHOSTTY_ACTION_TOGGLE_BACKGROUND_OPACITY:
                // Handle background opacity toggle
                logger.info("🎨 Toggle background opacity requested")
                // Post notification for UI to handle
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .toggleBackgroundOpacity, object: nil)
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
                    // Search ended - cancel pending search and end search in Ghostty
                    searchNeedleCancellable = nil
                    currentSearchTask?.cancel()
                    currentSearchTask = nil
                    // End search (clears highlights)
                    if let surface = self.surface {
                        Task.detached(priority: .userInitiated) {
                            ghostty_surface_search_end(surface)
                        }
                    }
                }
            }
        }
        
        /// Cancellable for search state needle changes (debounced search)
        private var searchNeedleCancellable: AnyCancellable?
        
        /// Current async search task
        private var currentSearchTask: Task<Void, Never>?
        
        /// Serial queue for search operations to prevent race conditions
        private let searchQueue = DispatchQueue(label: "com.geistty.search", qos: .userInitiated)
        
        /// Perform synchronous search on background queue, update UI on main queue
        /// This uses the new ScreenSearch-based sync API with autoscroll
        private func performSyncSearch(needle: String) {
            logger.debug("🔍 performSyncSearch called with needle: '\(needle)'")
            // Cancel any previous search
            currentSearchTask?.cancel()
            
            guard let surface = self.surface else { return }
            guard !needle.isEmpty else {
                // Empty needle - end search on serial queue
                searchQueue.async {
                    ghostty_surface_search_end(surface)
                }
                Task { @MainActor in
                    self.searchState?.total = nil
                    self.searchState?.selected = nil
                }
                return
            }
            
            // Capture needle for use in closure
            let needleCopy = needle
            
            // Use Swift Task wrapping serial queue for proper cancellation + serialization
            currentSearchTask = Task { [weak self] in
                guard let self = self else { return }
                
                // Run search on serial queue to prevent overlapping operations
                await withCheckedContinuation { continuation in
                    self.searchQueue.async {
                        // Check if cancelled before starting
                        if Task.isCancelled {
                            continuation.resume()
                            return
                        }
                        
                        // Call the search_start API (initializes search and scrolls to first match)
                        logger.debug("🔍 Calling ghostty_surface_search_start with needle: '\(needleCopy)'")
                        let result = needleCopy.withCString { needlePtr in
                            ghostty_surface_search_start(surface, needlePtr, UInt(needleCopy.utf8.count))
                        }
                        
                        // screen_type: 0 = primary (has scrollback), 1 = alternate (e.g. tmux - no scrollback)
                        let isAlternateScreen = result.screen_type == 1
                        if isAlternateScreen {
                            logger.info("🔍 Search on alternate screen (tmux/vim) - limited to visible rows only")
                        }
                        logger.info("🔍 ghostty_surface_search_start returned: success=\(result.success), total=\(result.total), selected=\(result.selected), screen_type=\(result.screen_type), has_scrollback=\(result.has_scrollback)")
                        
                        continuation.resume()
                        
                        // Check if cancelled after search
                        if Task.isCancelled { return }
                        
                        // Update UI on main queue
                        DispatchQueue.main.async { [weak self] in
                            if result.success {
                                self?.searchState?.total = result.total >= 0 ? UInt(result.total) : nil
                                self?.searchState?.selected = result.selected >= 0 ? UInt(result.selected) : nil
                                self?.searchState?.isAlternateScreen = isAlternateScreen
                            }
                        }
                    }
                }
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
            
            let surface = surfaceConfig.withCValue(view: self, writeCallback: writeCallback) { config in
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
                justFinishedSelecting = true
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
            // Don't process tap if we just finished selecting (prevents clearing selection)
            if justFinishedSelecting {
                justFinishedSelecting = false
                return
            }
            
            // Tap to stop momentum scrolling (like hitting a spinning wheel to stop)
            if isMomentumScrolling {
                stopScrollMomentum()
                return
            }
            
            _ = becomeFirstResponder()
            
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
            let feedbackGenerator = UIImpactFeedbackGenerator(style: .light)
            feedbackGenerator.impactOccurred()
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
            let feedbackGenerator = UIImpactFeedbackGenerator(style: .medium)
            feedbackGenerator.impactOccurred()
        }
        
        /// Handle two-finger double-tap to reset font size
        @objc private func handleTwoFingerDoubleTap(_ gesture: UITapGestureRecognizer) {
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
                    justFinishedSelecting = true
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
        
        // MARK: - Edit Actions
        
        /// Override canPerformAction to enable copy/paste
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
        /// Uses proper Ghostty keyboard API for correct terminal encoding
        /// Implements Ghostty macOS keybindings for splits/tabs/windows
        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
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
                    
                    // If we have an action, try to handle it
                    if let action = action {
                        if delegate.handleShortcut(action) {
                            // Action was handled, don't process further
                            return
                        }
                    }
                }
                
                // MARK: - Local Ghostty Shortcuts (font size, clear screen)
                
                if hasCmd {
                    switch char {
                    case "k":
                        // Cmd+K - Clear Screen (via Ghostty binding action)
                        if let surface = surface {
                            _ = "clear_screen".withCString { cstr in
                                ghostty_surface_binding_action(surface, cstr, 12)
                            }
                        }
                        return
                    case "0":
                        // Cmd+0 - Reset Font Size
                        resetFontSize()
                        return
                    case "+", "=":
                        // Cmd++ - Increase Font Size
                        if !hasShift {
                            increaseFontSize()
                            return
                        }
                    case "-":
                        // Cmd+- - Decrease Font Size
                        decreaseFontSize()
                        return
                    case "c", "v", "a", "f", "g", "w", "n", ",":
                        // These are handled by SwiftUI menu system - let them pass through
                        // Copy, Paste, Select All, Find, Find Next, Disconnect, New Connection, Preferences
                        super.pressesBegan(presses, with: event)
                        return
                    default:
                        break
                    }
                }
                
                // MARK: - Terminal Input (via Ghostty API)
                
                guard let surface = surface else { continue }
                
                // Debug: Log Ctrl key presses
                if hasCtrl {
                    NSLog("🎹 Hardware key with Ctrl: char='\(char)' keyCode=\(keyCode)")
                }
                
                // Add Ctrl toggle state to modifiers if active
                var modFlags = uiKey.modifierFlags
                if ctrlToggleActive {
                    modFlags.insert(.control)
                    ctrlToggleActive = false  // Clear after use
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
                    return
                }
            }
            
            // Pass unhandled keys to super (system shortcuts, etc.)
            super.pressesBegan(presses, with: event)
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
        
        override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            super.pressesChanged(presses, with: event)
        }
        
        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            stopKeyRepeat()
            
            for press in presses {
                guard let surface = surface else { continue }
                if let keyEvent = Input.KeyEvent(press: press, action: .release) {
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
                // Debug: log what Ghostty is sending
                let hexStr = swiftData.map { String(format: "%02x", $0) }.joined(separator: " ")
                NSLog("📤 externalWriteCallback: \(len) bytes: \(hexStr)")
                DispatchQueue.main.async {
                    surfaceView.onWrite?(swiftData)
                }
            }
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }
        
        deinit {
            // Remove notification observers
            NotificationCenter.default.removeObserver(self)
            // Close the surface if it hasn't been closed already
            close()
        }
        
        /// Explicitly close and release the surface.
        /// Call this before the view is deallocated to ensure clean shutdown.
        func close() {
            guard let surface = surface else { return }
            
            // Clear the onWrite callback to prevent callbacks during/after free
            onWrite = nil
            
            // Free the surface
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
        
        /// Send a key event to the terminal using the new Input types
        func sendKeyEvent(_ event: Input.KeyEvent) {
            guard let surface = surface else { return }
            
            event.withCValue { cEvent in
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
        
        override var canBecomeFirstResponder: Bool { true }
        
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
        
        /// Start a search (opens UI, Ghostty will callback with START_SEARCH action)
        func startSearch() {
            guard let surface = surface else { return }
            let action = "start_search"
            ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
        }
        
        /// Navigate to next search result (iOS ScreenSearch-based sync API with autoscroll)
        func searchNext() {
            guard let surface = surface else { return }
            guard searchState != nil else { return }
            
            // Use new sync API on background thread - handles autoscroll internally
            Task.detached(priority: .userInitiated) {
                let result = ghostty_surface_search_next(surface)
                
                if result.success {
                    await MainActor.run { [weak self] in
                        self?.searchState?.selected = result.selected >= 0 ? UInt(result.selected) : nil
                    }
                }
            }
        }
        
        /// Navigate to previous search result (iOS ScreenSearch-based sync API with autoscroll)
        func searchPrevious() {
            guard let surface = surface else { return }
            guard searchState != nil else { return }
            
            // Use new sync API on background thread - handles autoscroll internally
            Task.detached(priority: .userInitiated) {
                let result = ghostty_surface_search_prev(surface)
                
                if result.success {
                    await MainActor.run { [weak self] in
                        self?.searchState?.selected = result.selected >= 0 ? UInt(result.selected) : nil
                    }
                }
            }
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
                let feedbackGenerator = UIImpactFeedbackGenerator(style: .light)
                feedbackGenerator.impactOccurred()
                
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
            if let sublayers = layer.sublayers {
                for sublayer in sublayers {
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
                return false
            }
            
            // Calculate exact pixel dimensions for the target grid
            let scale = contentScaleFactor
            let exactWidthPx = UInt32(cols) * size.cell_width_px
            let exactHeightPx = UInt32(rows) * size.cell_height_px
            
            logger.debug("📐 Setting exact grid size: \(cols)x\(rows) = \(exactWidthPx)x\(exactHeightPx)px (cell: \(size.cell_width_px)x\(size.cell_height_px))")
            
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
                if let view = self_ as? UIView {
                    if let caLayer = sublayer as? CALayer {
                        view.layer.addSublayer(caLayer)
                    } else {
                        // Try to cast through AnyObject to id and use ObjC runtime
                        let obj = sublayer as AnyObject
                        if obj.isKind(of: CALayer.self) {
                            view.layer.addSublayer(obj as! CALayer)
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
            
            if !success {
                // Method already exists - try to replace it
                let method = class_getInstanceMethod(SurfaceView.self, selector)
                if let method = method {
                    method_setImplementation(method, unsafeBitCast(imp, to: IMP.self))
                }
            }
            
            // Also add "addSublayer:" (with colon) just in case
            let selectorWithColon = sel_registerName("addSublayer:")
            _ = class_addMethod(
                SurfaceView.self,
                selectorWithColon,
                unsafeBitCast(imp, to: IMP.self),
                typeEncoding
            )
        }
        
        /// Override to forward unrecognized selectors to self.layer
        /// This catches any CALayer methods that Ghostty might call on the view
        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            // Check if the layer responds to this selector
            if layer.responds(to: aSelector) {
                return layer
            }
            return super.forwardingTarget(for: aSelector)
        }
        
        /// Override method resolution to catch unhandled methods
        override class func resolveInstanceMethod(_ sel: Selector!) -> Bool {
            let selectorName = NSStringFromSelector(sel)
            
            // If it's addSublayer (with or without colon), register our handler
            if selectorName == "addSublayer" || selectorName == "addSublayer:" {
                registerGhosttyMethods()
                return true
            }
            
            return super.resolveInstanceMethod(sel)
        }
        
        override func didMoveToWindow() {
            super.didMoveToWindow()
            sizeDidChange(frame.size)
            
            // Focus management: request keyboard focus when added to window
            // Use RunLoop to ensure view is fully laid out first
            if window != nil {
                RunLoop.main.perform { [weak self] in
                    guard let self = self, self.window != nil else { return }
                    // Only become first responder if we're visible and in the window
                    if !self.isFirstResponder {
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
            if let sublayers = layer.sublayers {
                for sublayer in sublayers {
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
    
    // MARK: - Search State
    
    /// Search mode - determines which buffer to search
    enum SearchMode {
        case ghostty  // Normal Ghostty scrollback search
        case tmux     // Search tmux's internal scrollback via capture-pane
    }
    
    /// Observable search state for the terminal, matching macOS Ghostty implementation
    class SearchState: ObservableObject {
        /// The current search query (needle)
        @Published var needle: String = ""
        
        /// Total number of search matches (nil if unknown/not searched yet)
        @Published var total: UInt? = nil
        
        /// Currently selected match index (nil if no selection)
        @Published var selected: UInt? = nil
        
        /// Whether the terminal is on alternate screen (e.g., tmux, vim)
        /// When true, search only sees visible rows (no scrollback)
        @Published var isAlternateScreen: Bool = false
        
        /// The search mode (ghostty vs tmux)
        @Published var searchMode: SearchMode = .ghostty
        
        /// Captured tmux pane content (for tmux search mode)
        @Published var tmuxContent: String? = nil
        
        /// Positions of matches in tmux content (line numbers)
        @Published var tmuxMatchLines: [Int] = []
        
        /// Whether a tmux capture is in progress
        @Published var isCapturing: Bool = false
        
        /// Error message if capture failed
        @Published var captureError: String? = nil
        
        /// Initialize with optional starting query
        init(needle: String = "") {
            self.needle = needle
        }
        
        /// Reset search state
        func reset() {
            needle = ""
            total = nil
            selected = nil
            isAlternateScreen = false
            searchMode = .ghostty
            tmuxContent = nil
            tmuxMatchLines = []
            isCapturing = false
            captureError = nil
        }
    }
}
