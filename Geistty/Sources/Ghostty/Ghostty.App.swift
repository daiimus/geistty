//
//  Ghostty.App.swift
//  Geistty
//
//  Main Ghostty application wrapper — manages ghostty_app_t and runtime callbacks.
//  Extracted from Ghostty.swift — follows upstream Ghostty macOS naming convention.
//

import Foundation
import UIKit
import GhosttyKit
import UserNotifications
import os

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
        
        /// The underlying ghostty_app_t handle.
        /// Uses didSet to free the old handle, matching upstream Ghostty's pattern.
        /// This ensures the runtime is freed while `self` is still valid (important
        /// because Unmanaged.passUnretained userdata must remain valid during teardown).
        private(set) var app: ghostty_app_t? {
            didSet {
                guard let old = oldValue else { return }
                ghostty_app_free(old)
            }
        }
        
        /// Thread-safe flag to track if ghostty_init has been called (H3 fix).
        /// Uses OSAllocatedUnfairLock for safe concurrent access.
        /// Internal (not fileprivate) so Ghostty.Config can check it from Ghostty.Config.swift
        static let isInitializedLock = OSAllocatedUnfairLock(initialState: false)
        
        /// Convenience accessor for isInitialized state
        static var isInitialized: Bool {
            get { isInitializedLock.withLock { $0 } }
            set { isInitializedLock.withLock { $0 = newValue } }
        }
        
        /// Initialize the Ghostty runtime (must be called before any other Ghostty API)
        private static func initializeRuntime() -> Bool {
            guard !isInitialized else { return true }
            
            // Point Ghostty at our app bundle so it can find bundled themes
            // in <bundle>/themes/. This enables native `theme = <name>` resolution
            // in ghostty.conf without Swift-side theme parsing.
            setenv("GHOSTTY_RESOURCES_DIR", Bundle.main.bundlePath, 1)
            logger.info("Set GHOSTTY_RESOURCES_DIR to \(Bundle.main.bundlePath)")
            
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
            // Setting app to nil triggers the didSet which calls ghostty_app_free.
            // This ensures the runtime is freed while self (and userdata) is still valid.
            self.app = nil
        }
        
        /// Tick the app (process pending events)
        func tick() {
            guard let app = app else { return }
            ghostty_app_tick(app)
        }
        
        // MARK: - Runtime Callbacks
        
        /// Extract the SurfaceView from a ghostty_surface_t's userdata pointer.
        /// Returns nil if the surface has no userdata set.
        private static func surfaceView(from surface: ghostty_surface_t) -> SurfaceView? {
            ghostty_surface_userdata(surface).map {
                Unmanaged<SurfaceView>.fromOpaque($0).takeUnretainedValue()
            }
        }
        
        /// Decode a C data/len pair into a Swift String (UTF-8).
        /// Returns an empty string if data is nil or len is 0.
        private static func decodePayload(data: UnsafePointer<CChar>?, len: Int) -> String {
            guard len > 0, let ptr = data else { return "" }
            return String(
                decoding: UnsafeRawBufferPointer(
                    start: UnsafeRawPointer(ptr),
                    count: len
                ),
                as: UTF8.self
            )
        }
        
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
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let surface = target.target.surface else {
                    return false
                }
                let titleData = action.action.set_title
                guard let titlePtr = titleData.title else { return false }
                let title = String(cString: titlePtr)
                if let surfaceView = surfaceView(from: surface) {
                    DispatchQueue.main.async {
                        surfaceView.title = title
                    }
                }
                return true
                
            case GHOSTTY_ACTION_RING_BELL:
                // Handle bell — UIKit haptics must be on main thread
                DispatchQueue.main.async {
                    let generator = UINotificationFeedbackGenerator()
                    generator.notificationOccurred(.warning)
                }
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
                if let surfaceView = surfaceView(from: surface) {
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
                
                if let surfaceView = surfaceView(from: surface) {
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
                
                // Use length-bounded construction — urlPtr may not be null-terminated
                let urlLen = Int(urlData.len)
                let urlStr = urlPtr.withMemoryRebound(to: UInt8.self, capacity: urlLen) { ptr in
                    String(bytes: UnsafeBufferPointer(start: ptr, count: urlLen), encoding: .utf8)
                } ?? ""
                guard !urlStr.isEmpty else { return false }
                logger.info("🔗 Opening URL: \(urlStr)")
                
                DispatchQueue.main.async {
                    // #56: Whitelist URL schemes to prevent malicious escape sequences
                    // from triggering tel:, facetime:, itms-services:, shortcuts://, etc.
                    let allowedSchemes: Set<String> = ["http", "https", "mailto"]
                    if let url = URL(string: urlStr),
                       let scheme = url.scheme?.lowercased(),
                       allowedSchemes.contains(scheme) {
                        UIApplication.shared.open(url)
                    } else {
                        logger.warning("Blocked URL with disallowed or missing scheme: \(urlStr)")
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
                
                if let surfaceView = surfaceView(from: surface) {
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
                
                if let surfaceView = surfaceView(from: surface) {
                    DispatchQueue.main.async {
                        // IMPORTANT: cellSizeData is in backing pixels (physical pixels on retina).
                        // SwiftUI's GeometryReader returns points (logical units).
                        // We must convert to points for correct layout calculations.
                        // This matches macOS Ghostty's convertFromBacking() behavior.
                        let scale = surfaceView.contentScaleFactor
                        surfaceView.cellSize = CGSize(
                            width: CGFloat(cellSizeData.width) / scale,
                            height: CGFloat(cellSizeData.height) / scale
                        )
                        logger.debug("📐 Cell size: \(cellSizeData.width)x\(cellSizeData.height) px = \(surfaceView.cellSize.width)x\(surfaceView.cellSize.height) pt (scale: \(scale))")
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
                
                if let surfaceView = surfaceView(from: surface) {
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
                
                if let surfaceView = surfaceView(from: surface) {
                    DispatchQueue.main.async {
                        surfaceView.healthy = (health == GHOSTTY_RENDERER_HEALTH_HEALTHY)
                        if health != GHOSTTY_RENDERER_HEALTH_HEALTHY {
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
                    let title = notification.title.map { String(cString: $0) } ?? "Terminal"
                    
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
                
                if let surfaceView = surfaceView(from: surface) {
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
                
                if let surfaceView = surfaceView(from: surface) {
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
                
                if let surfaceView = surfaceView(from: surface) {
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
                
                if let surfaceView = surfaceView(from: surface) {
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
                
                if let surfaceView = surfaceView(from: surface) {
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
                
            case GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE:
                // Toggle command palette overlay
                logger.info("🔍 Toggle command palette requested")
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .toggleCommandPalette, object: nil)
                }
                return true
                
            case GHOSTTY_ACTION_TMUX_STATE_CHANGED:
                // tmux control mode: windows/panes changed
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let surface = target.target.surface else {
                    return false
                }
                
                let tmuxState = action.action.tmux_state_changed
                logger.info("tmux state changed: \(tmuxState.window_count) windows, \(tmuxState.pane_count) panes")
                
                // Extract the SurfaceView from userdata so observers can filter
                // by identity (notification.object as? SurfaceView === self.ghosttySurface).
                // Posting the raw ghostty_surface_t would fail the as? cast, bypassing
                // the multi-surface identity guard.
                let surfaceView = surfaceView(from: surface)
                
                // Post synchronously — we're already on main thread (via tick()),
                // and eliminating the async hop reduces the window between viewer
                // state changes and Swift reacting to them.
                NotificationCenter.default.post(
                    name: .tmuxStateChanged,
                    object: surfaceView,
                    userInfo: [
                        TmuxNotificationKey.windowCount: tmuxState.window_count,
                        TmuxNotificationKey.paneCount: tmuxState.pane_count
                    ]
                )
                return true
                
            case GHOSTTY_ACTION_TMUX_EXIT:
                // tmux control mode: exited
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let surface = target.target.surface else {
                    return false
                }
                
                // Extract the exit reason from the C struct.
                // The reason is a fixed-size C buffer with a length field,
                // matching tmux's known exit reasons ("detached", "server-exited", etc.).
                let exitData = action.action.tmux_exit
                let reason: String = withUnsafePointer(to: exitData.reason) { ptr in
                    let buf = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
                    // Clamp to buffer size to prevent out-of-bounds read if
                    // Zig side ever sets reason_len > sizeof(reason).
                    let len = min(Int(exitData.reason_len), MemoryLayout.size(ofValue: exitData.reason))
                    return String(bytes: UnsafeBufferPointer(start: buf, count: len), encoding: .utf8) ?? ""
                }
                
                logger.info("tmux control mode exited, reason: \(reason.isEmpty ? "(none)" : reason)")
                
                // Extract the SurfaceView from userdata so observers can filter
                // by identity (notification.object as? SurfaceView === self.ghosttySurface).
                let surfaceView = surfaceView(from: surface)
                
                // Post synchronously — already on main thread via tick().
                // Forward the reason so observers can differentiate voluntary
                // detach ("detached") from involuntary exit ("server-exited").
                NotificationCenter.default.post(
                    name: .tmuxExited,
                    object: surfaceView,
                    userInfo: [TmuxNotificationKey.reason: reason]
                )
                return true
                
            case GHOSTTY_ACTION_TMUX_READY:
                // tmux control mode: viewer startup complete, command queue drained.
                // User input is now safe to send — no risk of interleaving with
                // viewer commands (display-message, list-windows, capture-pane, etc.)
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let surface = target.target.surface else {
                    return false
                }
                
                logger.info("tmux viewer startup complete")
                
                // Extract the SurfaceView from userdata so observers can filter
                // by identity (notification.object as? SurfaceView === self.ghosttySurface).
                let surfaceView = surfaceView(from: surface)
                
                // Post synchronously — already on main thread via tick().
                // This ensures activateFirstTmuxPane() runs immediately,
                // minimizing the window where active_pane_id is unset.
                NotificationCenter.default.post(
                    name: .tmuxReady,
                    object: surfaceView,
                    userInfo: [:]
                )
                return true
                
            case GHOSTTY_ACTION_TMUX_COMMAND_RESPONSE:
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let surface = target.target.surface else {
                    return false
                }
                
                let resp = action.action.tmux_command_response
                let content = decodePayload(data: resp.data, len: resp.len)
                
                logger.info("tmux command response: \(resp.is_error ? "ERROR" : "OK") len=\(resp.len)")
                
                // Extract the SurfaceView from userdata so observers can filter
                // by identity (notification.object as? SurfaceView === self.ghosttySurface).
                let surfaceView = surfaceView(from: surface)
                
                NotificationCenter.default.post(
                    name: .tmuxCommandResponse,
                    object: surfaceView,
                    userInfo: [
                        TmuxNotificationKey.content: content,
                        TmuxNotificationKey.isError: resp.is_error
                    ]
                )
                return true
                
            case GHOSTTY_ACTION_TMUX_ACTIVE_WINDOW_CHANGED:
                // tmux control mode: active window changed (e.g., user ran next-window).
                // This fires before TMUX_STATE_CHANGED, giving Swift fast
                // visual feedback to update the window picker.
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let surface = target.target.surface else {
                    return false
                }
                
                let windowId = action.action.tmux_active_window_changed.window_id
                logger.info("🪟 tmux active window changed: @\(windowId)")
                
                // Extract the SurfaceView from userdata so observers can filter
                // by identity (notification.object as? SurfaceView === self.ghosttySurface).
                // Posting the raw ghostty_surface_t would fail the as? cast, bypassing
                // the multi-surface identity guard.
                let surfaceView = surfaceView(from: surface)
                
                // Post synchronously — already on main thread via tick().
                NotificationCenter.default.post(
                    name: .tmuxActiveWindowChanged,
                    object: surfaceView,
                    userInfo: [TmuxNotificationKey.windowId: windowId]
                )
                return true
                
            case GHOSTTY_ACTION_TMUX_SESSION_RENAMED:
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let surface = target.target.surface else {
                    return false
                }
                
                let payload = action.action.tmux_session_renamed
                let name = withUnsafePointer(to: payload.name) { ptr in
                    let rawPtr = UnsafeRawPointer(ptr)
                    let len = Int(payload.name_len)
                    guard len > 0 else { return "" }
                    return String(
                        decoding: UnsafeRawBufferPointer(start: rawPtr, count: len),
                        as: UTF8.self
                    )
                }
                
                logger.info("tmux session renamed: len=\(payload.name_len)")
                
                let surfaceView = surfaceView(from: surface)
                
                NotificationCenter.default.post(
                    name: .tmuxSessionRenamed,
                    object: surfaceView,
                    userInfo: [TmuxNotificationKey.name: name]
                )
                return true
                
            case GHOSTTY_ACTION_TMUX_FOCUSED_PANE_CHANGED:
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let surface = target.target.surface else {
                    return false
                }
                
                let payload = action.action.tmux_focused_pane_changed
                logger.info("tmux focused pane changed: @\(payload.window_id) %\(payload.pane_id)")
                
                let surfaceView = surfaceView(from: surface)
                
                NotificationCenter.default.post(
                    name: .tmuxFocusedPaneChanged,
                    object: surfaceView,
                    userInfo: [TmuxNotificationKey.windowId: payload.window_id, TmuxNotificationKey.paneId: payload.pane_id]
                )
                return true
                
            case GHOSTTY_ACTION_TMUX_SUBSCRIPTION_CHANGED:
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let surface = target.target.surface else {
                    return false
                }
                
                let payload = action.action.tmux_subscription_changed
                guard let namePtr = payload.name else {
                    logger.error("tmux subscription changed: missing name pointer")
                    return false
                }
                let name = String(cString: namePtr)
                // value is NOT null-terminated — must use value_len
                let value: String
                if payload.value_len > 0, let valPtr = payload.value {
                    value = String(
                        decoding: UnsafeRawBufferPointer(
                            start: UnsafeRawPointer(valPtr),
                            count: payload.value_len
                        ),
                        as: UTF8.self
                    )
                } else {
                    value = ""
                }
                
                logger.debug("tmux subscription changed: name=\(name)")
                
                let surfaceView = surfaceView(from: surface)
                
                NotificationCenter.default.post(
                    name: .tmuxSubscriptionChanged,
                    object: surfaceView,
                    userInfo: [TmuxNotificationKey.name: name, TmuxNotificationKey.value: value]
                )
                return true
                
            case GHOSTTY_ACTION_QUIT_TIMER:
                // Ghostty fires quit_timer when all surfaces are gone (e.g., after
                // tmux viewer teardown on background). On macOS this quits the app.
                // On iOS we MUST suppress this — iOS manages app lifecycle, and we
                // need the process alive to reconnect when foregrounded.
                logger.info("Suppressing quit_timer action (iOS manages app lifecycle)")
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
            // Read from system clipboard and send to Ghostty.
            // UIPasteboard.general must be accessed on the main thread.
            // The clipboard request state pointer is heap-allocated by Zig and
            // remains valid until completeClipboardRequest is called, so async
            // completion is safe (GTK backend does the same).
            guard let userdata = userdata else {
                logger.warning("readClipboard: userdata is nil")
                return
            }
            let surfaceView = Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
            
            DispatchQueue.main.async {
                guard let surface = surfaceView.surface else {
                    logger.warning("readClipboard: surface became nil before main queue dispatch")
                    return
                }
                let str = UIPasteboard.general.string ?? ""
                str.withCString { ptr in
                    ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
                }
                logger.debug("readClipboard: sent \(str.count) chars to Ghostty")
            }
        }
        
        private static func confirmReadClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            string: UnsafePointer<CChar>?,
            state: UnsafeMutableRawPointer?,
            request: ghostty_clipboard_request_e
        ) {
            // For security confirmation before pasting sensitive content.
            // On iOS, we auto-confirm since the system already handles clipboard permissions.
            // Must dispatch to main for ghostty_surface_complete_clipboard_request.
            guard let userdata = userdata else { return }
            let surfaceView = Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
            
            // Copy the string now (the pointer may not survive the dispatch)
            let str: String
            if let cStr = string {
                str = String(cString: cStr)
            } else {
                str = ""
            }
            
            DispatchQueue.main.async {
                guard let surface = surfaceView.surface else { return }
                str.withCString { ptr in
                    ghostty_surface_complete_clipboard_request(surface, ptr, state, true)
                }
                logger.debug("Clipboard read confirmed")
            }
        }
        
        private static func writeClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            location: ghostty_clipboard_e,
            content: UnsafePointer<ghostty_clipboard_content_s>?,
            len: Int,
            confirm: Bool
        ) {
            guard let content = content, len > 0 else { return }
            
            // Extract the string now (the pointer may not survive the dispatch)
            guard let data = content.pointee.data else { return }
            let str = String(cString: data)
            
            // UIPasteboard.general must be accessed on the main thread
            DispatchQueue.main.async {
                UIPasteboard.general.string = str
            }
        }
        
        private static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
            // Handle surface close request
            logger.debug("Close surface requested, processAlive: \(processAlive)")
        }
    }
}
