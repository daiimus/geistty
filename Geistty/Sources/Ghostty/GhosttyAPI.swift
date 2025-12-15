//
//  GhosttyAPI.swift
//  Geistty
//
//  Complete Swift wrappers for Ghostty C API
//  This file provides full API parity with ghostty.h
//

import Foundation
import GhosttyKit

// MARK: - Ghostty Info

extension Ghostty {
    /// Information about the Ghostty library
    struct Info {
        let buildMode: BuildMode
        let version: String
        
        enum BuildMode: Int32 {
            case debug = 0
            case releaseSafe = 1
            case releaseFast = 2
            case releaseSmall = 3
        }
        
        static func get() -> Info {
            let info = ghostty_info()
            let version: String
            if info.version_len > 0 {
                version = String(cString: info.version)
            } else {
                version = "unknown"
            }
            return Info(
                buildMode: BuildMode(rawValue: info.build_mode.rawValue) ?? .releaseFast,
                version: version
            )
        }
    }
    
    /// Get Ghostty version info
    static func info() -> Info {
        return Info.get()
    }
    
    /// Translate a message using Ghostty's localization
    static func translate(_ message: String) -> String {
        return message.withCString { ptr in
            if let translated = ghostty_translate(ptr) {
                return String(cString: translated)
            }
            return message
        }
    }
    
    /// Free a Ghostty string
    static func freeString(_ string: ghostty_string_s) {
        ghostty_string_free(string)
    }
}

// MARK: - Extended Config API

extension Ghostty.Config {
    /// Clone an existing config
    static func clone(_ config: ghostty_config_t) -> ghostty_config_t? {
        return ghostty_config_clone(config)
    }
    
    /// Load config from a file path
    /// - Parameters:
    ///   - config: The config to load into
    ///   - path: Path to the config file
    /// - Returns: true if successful
    static func loadFile(_ config: ghostty_config_t, path: String) -> Bool {
        return path.withCString { ptr in
            ghostty_config_load_file(config, ptr, UInt(path.utf8.count))
        }
    }
    
    /// Load config from command line arguments
    static func loadCLIArgs(_ config: ghostty_config_t) {
        ghostty_config_load_cli_args(config)
    }
    
    /// Load config from default file locations
    static func loadDefaultFiles(_ config: ghostty_config_t) {
        ghostty_config_load_default_files(config)
    }
    
    /// Load config from recursive file locations
    static func loadRecursiveFiles(_ config: ghostty_config_t) {
        ghostty_config_load_recursive_files(config)
    }
    
    /// Load config from a string
    static func loadString(_ config: ghostty_config_t, content: String) {
        content.withCString { ptr in
            ghostty_config_load_string(config, ptr, UInt(content.utf8.count))
        }
    }
    
    /// Get a config value
    /// - Parameters:
    ///   - config: The config to query
    ///   - key: The config key
    ///   - result: Pointer to store the result
    /// - Returns: true if the key exists
    static func get(_ config: ghostty_config_t, key: String, result: UnsafeMutableRawPointer) -> Bool {
        return key.withCString { ptr in
            ghostty_config_get(config, result, ptr, UInt(key.utf8.count))
        }
    }
    
    /// Get the trigger for a config action
    static func getTrigger(_ config: ghostty_config_t, action: String) -> ghostty_input_trigger_s {
        return action.withCString { ptr in
            ghostty_config_trigger(config, ptr, UInt(action.utf8.count))
        }
    }
    
    /// Get the number of config diagnostics (errors/warnings)
    static func diagnosticsCount(_ config: ghostty_config_t) -> UInt32 {
        return ghostty_config_diagnostics_count(config)
    }
    
    /// Get a specific diagnostic
    static func getDiagnostic(_ config: ghostty_config_t, index: UInt32) -> String? {
        let diag = ghostty_config_get_diagnostic(config, index)
        if let message = diag.message {
            return String(cString: message)
        }
        return nil
    }
    
    /// Get all diagnostics
    static func getAllDiagnostics(_ config: ghostty_config_t) -> [String] {
        let count = diagnosticsCount(config)
        var diagnostics: [String] = []
        for i in 0..<count {
            if let diag = getDiagnostic(config, index: i) {
                diagnostics.append(diag)
            }
        }
        return diagnostics
    }
    
    /// Get the path to open for config editing
    static func openPath() -> String? {
        let path = ghostty_config_open_path()
        defer { ghostty_string_free(path) }
        if path.len > 0, let ptr = path.ptr {
            return String(cString: ptr)
        }
        return nil
    }
}

// MARK: - Extended App API

extension Ghostty.App {
    /// Check if a key is a binding at the app level
    func keyIsBinding(_ key: ghostty_input_key_s) -> Bool {
        guard let app = app else { return false }
        return ghostty_app_key_is_binding(app, key)
    }
    
    /// Send a key event to the app
    func sendKey(_ key: ghostty_input_key_s) -> Bool {
        guard let app = app else { return false }
        return ghostty_app_key(app, key)
    }
    
    /// Notify the app that the keyboard layout changed
    func keyboardChanged() {
        guard let app = app else { return }
        ghostty_app_keyboard_changed(app)
    }
    
    /// Open the config file
    func openConfig() {
        guard let app = app else { return }
        ghostty_app_open_config(app)
    }
    
    /// Update the app config
    func updateConfig(_ config: ghostty_config_t) {
        guard let app = app else { return }
        ghostty_app_update_config(app, config)
    }
    
    /// Check if the app needs confirmation before quitting
    func needsConfirmQuit() -> Bool {
        guard let app = app else { return false }
        return ghostty_app_needs_confirm_quit(app)
    }
    
    /// Check if the app has global keybinds
    func hasGlobalKeybinds() -> Bool {
        guard let app = app else { return false }
        return ghostty_app_has_global_keybinds(app)
    }
    
    /// Set the color scheme for the entire app
    func setColorScheme(_ scheme: ghostty_color_scheme_e) {
        guard let app = app else { return }
        ghostty_app_set_color_scheme(app, scheme)
    }
    
    /// Get the app userdata
    func getUserdata() -> UnsafeMutableRawPointer? {
        guard let app = app else { return nil }
        return ghostty_app_userdata(app)
    }
}

// MARK: - Extended Surface API

extension Ghostty.SurfaceView {
    // MARK: - Surface Info
    
    /// Get the app that owns this surface
    func getApp() -> ghostty_app_t? {
        guard let surface = surface else { return nil }
        return ghostty_surface_app(surface)
    }
    
    /// Get the inherited config for split surfaces
    func getInheritedConfig() -> ghostty_surface_config_s {
        guard let surface = surface else {
            return ghostty_surface_config_new()
        }
        return ghostty_surface_inherited_config(surface)
    }
    
    /// Check if the surface needs confirmation before closing
    func needsConfirmQuit() -> Bool {
        guard let surface = surface else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }
    
    /// Check if the subprocess has exited
    func processExited() -> Bool {
        guard let surface = surface else { return true }
        return ghostty_surface_process_exited(surface)
    }
    
    // MARK: - Rendering
    
    /// Request a refresh/redraw of the surface
    func refresh() {
        guard let surface = surface else { return }
        ghostty_surface_refresh(surface)
    }
    
    /// Draw the surface (called from render callback)
    func draw() {
        guard let surface = surface else { return }
        ghostty_surface_draw(surface)
    }
    
    // MARK: - Input
    
    /// Get the key translation modifiers for the surface
    func keyTranslationMods() -> ghostty_input_mods_e {
        guard let surface = surface else { return GHOSTTY_MODS_NONE }
        return ghostty_surface_key_translation_mods(surface)
    }
    
    /// Check if a key is a binding for this surface
    func keyIsBinding(_ key: ghostty_input_key_s) -> Bool {
        guard let surface = surface else { return false }
        return ghostty_surface_key_is_binding(surface, key)
    }
    
    /// Send preedit text (for IME)
    func preedit(_ text: String) {
        guard let surface = surface else { return }
        text.withCString { ptr in
            ghostty_surface_preedit(surface, ptr, UInt(text.utf8.count))
        }
    }
    
    /// Clear preedit text
    func clearPreedit() {
        guard let surface = surface else { return }
        ghostty_surface_preedit(surface, nil, 0)
    }
    
    /// Check if mouse is captured by the terminal application
    func isMouseCaptured() -> Bool {
        guard let surface = surface else { return false }
        return ghostty_surface_mouse_captured(surface)
    }
    
    /// Send mouse pressure event (for Force Touch)
    func mousePressure(stage: UInt32, pressure: Double) {
        guard let surface = surface else { return }
        ghostty_surface_mouse_pressure(surface, stage, pressure)
    }
    
    // MARK: - IME Point
    
    /// Get the IME candidate window position
    func imePoint() -> (x: Double, y: Double, width: Double, height: Double) {
        guard let surface = surface else { return (0, 0, 0, 0) }
        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        return (x, y, width, height)
    }
    
    // MARK: - Commands and Actions
    
    /// Get available commands for command palette
    func getCommands() -> [GhosttyCommand] {
        guard let surface = surface else { return [] }
        
        var commandsPtr: UnsafeMutablePointer<ghostty_command_s>?
        var count: Int = 0
        
        ghostty_surface_commands(surface, &commandsPtr, &count)
        
        guard let commands = commandsPtr, count > 0 else { return [] }
        
        var result: [GhosttyCommand] = []
        for i in 0..<count {
            let cmd = commands[i]
            result.append(GhosttyCommand(
                actionKey: cmd.action_key != nil ? String(cString: cmd.action_key) : "",
                action: cmd.action != nil ? String(cString: cmd.action) : "",
                title: cmd.title != nil ? String(cString: cmd.title) : "",
                description: cmd.description != nil ? String(cString: cmd.description) : ""
            ))
        }
        
        return result
    }
    
    /// Request to close the surface
    func requestClose() {
        guard let surface = surface else { return }
        ghostty_surface_request_close(surface)
    }
    
    // MARK: - Split Panes (Future Feature)
    
    /// Split the surface in a direction
    func split(direction: ghostty_action_split_direction_e) {
        guard let surface = surface else { return }
        ghostty_surface_split(surface, direction)
    }
    
    /// Equalize all split panes
    func splitEqualize() {
        guard let surface = surface else { return }
        ghostty_surface_split_equalize(surface)
    }
    
    /// Focus a split pane
    func splitFocus(direction: ghostty_action_goto_split_e) {
        guard let surface = surface else { return }
        ghostty_surface_split_focus(surface, direction)
    }
    
    /// Resize a split pane
    func splitResize(direction: ghostty_action_resize_split_direction_e, amount: UInt16) {
        guard let surface = surface else { return }
        var resize = ghostty_action_resize_split_s(amount: amount, direction: direction)
        ghostty_surface_split_resize(surface, resize)
    }
    
    // MARK: - Text Reading
    
    /// Read text from a selection/region
    func readText(selection: ghostty_selection_s) -> String? {
        guard let surface = surface else { return nil }
        
        var text = ghostty_text_s()
        let success = ghostty_surface_read_text(surface, &text, selection)
        
        guard success, text.text_len > 0, let textPtr = text.text else {
            return nil
        }
        
        let result = String(cString: textPtr)
        ghostty_surface_free_text(surface, &text)
        return result
    }
    
    // MARK: - Display
    
    /// Set the display ID for the surface (for multi-monitor)
    func setDisplayId(_ displayId: UInt32) {
        guard let surface = surface else { return }
        ghostty_surface_set_display_id(surface, displayId)
    }
    
    // MARK: - Quick Look (macOS-specific, no-op on iOS)
    
    /// Get the word under cursor for Quick Look
    func quickLookWord() -> String? {
        guard let surface = surface else { return nil }
        
        var text = ghostty_text_s()
        let success = ghostty_surface_quicklook_word(surface, &text)
        
        guard success, text.text_len > 0, let textPtr = text.text else {
            return nil
        }
        
        let result = String(cString: textPtr)
        ghostty_surface_free_text(surface, &text)
        return result
    }
    
    /// Get the font for Quick Look (returns CTFont on iOS)
    func quickLookFont() -> Any? {
        guard let surface = surface else { return nil }
        return ghostty_surface_quicklook_font(surface)
    }
}

// MARK: - Command Structure

extension Ghostty {
    /// Represents a command available in the command palette
    struct GhosttyCommand {
        let actionKey: String
        let action: String
        let title: String
        let description: String
    }
}

// MARK: - Inspector API

extension Ghostty {
    /// Inspector for debugging terminal state
    class Inspector {
        private var inspector: ghostty_inspector_t?
        private weak var surface: SurfaceView?
        
        init?(surface: SurfaceView) {
            guard let surfaceHandle = surface.surface else { return nil }
            self.inspector = ghostty_surface_inspector(surfaceHandle)
            self.surface = surface
            guard inspector != nil else { return nil }
        }
        
        deinit {
            if let surface = surface?.surface {
                ghostty_inspector_free(surface)
            }
        }
        
        /// Initialize Metal rendering for inspector
        func metalInit(device: MTLDevice) -> Bool {
            guard let inspector = inspector else { return false }
            return ghostty_inspector_metal_init(inspector, Unmanaged.passUnretained(device).toOpaque())
        }
        
        /// Shutdown Metal rendering
        func metalShutdown() -> Bool {
            guard let inspector = inspector else { return false }
            return ghostty_inspector_metal_shutdown(inspector)
        }
        
        /// Render the inspector
        func metalRender(commandBuffer: MTLCommandBuffer, drawable: CAMetalDrawable) {
            guard let inspector = inspector else { return }
            ghostty_inspector_metal_render(
                inspector,
                Unmanaged.passUnretained(commandBuffer).toOpaque(),
                Unmanaged.passUnretained(drawable).toOpaque()
            )
        }
        
        /// Set the content scale
        func setContentScale(x: Double, y: Double) {
            guard let inspector = inspector else { return }
            ghostty_inspector_set_content_scale(inspector, x, y)
        }
        
        /// Set the size
        func setSize(width: UInt32, height: UInt32) {
            guard let inspector = inspector else { return }
            ghostty_inspector_set_size(inspector, width, height)
        }
        
        /// Set focus state
        func setFocus(_ focused: Bool) {
            guard let inspector = inspector else { return }
            ghostty_inspector_set_focus(inspector, focused)
        }
        
        /// Send text input
        func text(_ text: String) {
            guard let inspector = inspector else { return }
            text.withCString { ptr in
                ghostty_inspector_text(inspector, ptr)
            }
        }
        
        /// Send key event
        func key(_ key: ghostty_input_key_s) {
            guard let inspector = inspector else { return }
            ghostty_inspector_key(inspector, key)
        }
        
        /// Send mouse button event
        func mouseButton(button: ghostty_input_mouse_button_e, state: ghostty_input_mouse_state_e, mods: ghostty_input_mods_e) {
            guard let inspector = inspector else { return }
            ghostty_inspector_mouse_button(inspector, button, state, mods)
        }
        
        /// Send mouse position
        func mousePos(x: Double, y: Double) {
            guard let inspector = inspector else { return }
            ghostty_inspector_mouse_pos(inspector, x, y)
        }
        
        /// Send mouse scroll
        func mouseScroll(x: Double, y: Double) {
            guard let inspector = inspector else { return }
            ghostty_inspector_mouse_scroll(inspector, x, y)
        }
    }
}

// MARK: - Convenience Extensions

extension Ghostty {
    /// Input modifiers helper
    struct Modifiers: OptionSet {
        let rawValue: Int32
        
        static let shift = Modifiers(rawValue: GHOSTTY_MODS_SHIFT.rawValue)
        static let ctrl = Modifiers(rawValue: GHOSTTY_MODS_CTRL.rawValue)
        static let alt = Modifiers(rawValue: GHOSTTY_MODS_ALT.rawValue)
        static let `super` = Modifiers(rawValue: GHOSTTY_MODS_SUPER.rawValue)
        static let caps = Modifiers(rawValue: GHOSTTY_MODS_CAPS.rawValue)
        static let num = Modifiers(rawValue: GHOSTTY_MODS_NUM.rawValue)
        
        var ghosttyMods: ghostty_input_mods_e {
            return ghostty_input_mods_e(rawValue: UInt32(rawValue))
        }
    }
    
    /// Color scheme helper
    enum ColorScheme {
        case light
        case dark
        
        var ghosttyValue: ghostty_color_scheme_e {
            switch self {
            case .light: return GHOSTTY_COLOR_SCHEME_LIGHT
            case .dark: return GHOSTTY_COLOR_SCHEME_DARK
            }
        }
        
        init(traitCollection: UITraitCollection) {
            self = traitCollection.userInterfaceStyle == .dark ? .dark : .light
        }
    }
    
    /// Split direction helper
    enum SplitDirection {
        case right, down, left, up
        
        var ghosttyValue: ghostty_action_split_direction_e {
            switch self {
            case .right: return GHOSTTY_SPLIT_DIRECTION_RIGHT
            case .down: return GHOSTTY_SPLIT_DIRECTION_DOWN
            case .left: return GHOSTTY_SPLIT_DIRECTION_LEFT
            case .up: return GHOSTTY_SPLIT_DIRECTION_UP
            }
        }
    }
    
    /// Goto split helper
    enum GotoSplit {
        case previous, next, up, left, down, right
        
        var ghosttyValue: ghostty_action_goto_split_e {
            switch self {
            case .previous: return GHOSTTY_GOTO_SPLIT_PREVIOUS
            case .next: return GHOSTTY_GOTO_SPLIT_NEXT
            case .up: return GHOSTTY_GOTO_SPLIT_UP
            case .left: return GHOSTTY_GOTO_SPLIT_LEFT
            case .down: return GHOSTTY_GOTO_SPLIT_DOWN
            case .right: return GHOSTTY_GOTO_SPLIT_RIGHT
            }
        }
    }
    
    /// Resize split direction helper
    enum ResizeSplitDirection {
        case up, down, left, right
        
        var ghosttyValue: ghostty_action_resize_split_direction_e {
            switch self {
            case .up: return GHOSTTY_RESIZE_SPLIT_UP
            case .down: return GHOSTTY_RESIZE_SPLIT_DOWN
            case .left: return GHOSTTY_RESIZE_SPLIT_LEFT
            case .right: return GHOSTTY_RESIZE_SPLIT_RIGHT
            }
        }
    }
}

// MARK: - Point and Selection Helpers

extension Ghostty {
    /// Point in terminal grid
    struct Point {
        let x: UInt32
        let y: UInt32
        let tag: ghostty_point_tag_e
        let coord: ghostty_point_coord_e
        
        func toGhostty() -> ghostty_point_s {
            return ghostty_point_s(tag: tag, coord: coord, x: x, y: y)
        }
        
        static func active(x: UInt32, y: UInt32, coord: ghostty_point_coord_e = GHOSTTY_POINT_COORD_EXACT) -> Point {
            return Point(x: x, y: y, tag: GHOSTTY_POINT_ACTIVE, coord: coord)
        }
        
        static func viewport(x: UInt32, y: UInt32, coord: ghostty_point_coord_e = GHOSTTY_POINT_COORD_EXACT) -> Point {
            return Point(x: x, y: y, tag: GHOSTTY_POINT_VIEWPORT, coord: coord)
        }
        
        static func screen(x: UInt32, y: UInt32, coord: ghostty_point_coord_e = GHOSTTY_POINT_COORD_EXACT) -> Point {
            return Point(x: x, y: y, tag: GHOSTTY_POINT_SCREEN, coord: coord)
        }
        
        static func surface(x: UInt32, y: UInt32, coord: ghostty_point_coord_e = GHOSTTY_POINT_COORD_EXACT) -> Point {
            return Point(x: x, y: y, tag: GHOSTTY_POINT_SURFACE, coord: coord)
        }
    }
    
    /// Selection in terminal
    struct Selection {
        let topLeft: Point
        let bottomRight: Point
        let rectangle: Bool
        
        func toGhostty() -> ghostty_selection_s {
            return ghostty_selection_s(
                top_left: topLeft.toGhostty(),
                bottom_right: bottomRight.toGhostty(),
                rectangle: rectangle
            )
        }
    }
}
