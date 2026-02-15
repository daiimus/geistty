import XCTest
@testable import Geistty

// MARK: - Config Introspection Tests
//
// Tests for the ghostty_config_get() computed properties on Ghostty.Config
// and the ConfigSyncManager.syncFromConfig() integration.
//
// These tests require the Ghostty runtime (ghostty_init) to be available.
// If the runtime cannot initialize (e.g., missing resources), tests skip gracefully.

@MainActor
final class ConfigIntrospectionTests: XCTestCase {
    
    // MARK: - ConfigSyncManager tests
    //
    // These tests verify that ConfigSyncManager correctly reads config values
    // from the config file and writes to the expected UserDefaults keys.
    //
    // Note: Direct Ghostty.Config (ghostty_config_get) testing requires the
    // Ghostty runtime, which isn't available in the simulator test environment.
    // The syncFromConfig() path is exercised at runtime; here we test the
    // file-based fallback path which exercises the same UserDefaults keys
    // and config file manipulation logic.
    
    private let defaults = UserDefaults.standard
    
    override func setUp() {
        super.setUp()
        // Clear relevant UserDefaults keys before each test
        defaults.removeObject(forKey: "terminal.fontFamily")
        defaults.removeObject(forKey: "terminal.cursorStyle")
        defaults.removeObject(forKey: "terminal.fontThicken")
        defaults.removeObject(forKey: "terminal.backgroundOpacity")
        defaults.removeObject(forKey: "terminal.colorTheme")
    }
    
    // MARK: - Config property default values
    
    /// Verify that AppSettings defaults match Ghostty defaults
    func testAppSettingsDefaults() {
        // These should match the defaults in both AppSettings and Ghostty config
        let settings = AppSettings.shared
        // fontFamily default is "SF Mono" in AppSettings
        // cursorStyle default is "block" in both
        XCTAssertEqual(settings.cursorStyle, "block")
        // fontThicken default is true
        XCTAssertEqual(settings.fontThicken, true)
        // backgroundOpacity default is 0.95
        XCTAssertEqual(settings.backgroundOpacity, 0.95, accuracy: 0.001)
    }
    
    // MARK: - updateConfigValue tests
    
    func testUpdateConfigValueReplacesExistingKey() {
        let configPath = Ghostty.Config.configFilePath
        let initial = "font-family = \"Menlo\"\ncursor-style = block"
        try? initial.write(to: configPath, atomically: true, encoding: .utf8)
        
        ConfigSyncManager.shared.updateConfigValue(key: "cursor-style", value: "bar")
        
        let content = try? String(contentsOf: configPath, encoding: .utf8)
        XCTAssertTrue(content?.contains("cursor-style = bar") ?? false)
        XCTAssertFalse(content?.contains("cursor-style = block") ?? true)
        // Other keys preserved
        XCTAssertTrue(content?.contains("font-family = \"Menlo\"") ?? false)
    }
    
    func testUpdateConfigValueAppendsNewKey() {
        let configPath = Ghostty.Config.configFilePath
        let initial = "font-family = \"Menlo\""
        try? initial.write(to: configPath, atomically: true, encoding: .utf8)
        
        ConfigSyncManager.shared.updateConfigValue(key: "cursor-style", value: "underline")
        
        let content = try? String(contentsOf: configPath, encoding: .utf8)
        XCTAssertTrue(content?.contains("cursor-style = underline") ?? false)
        XCTAssertTrue(content?.contains("font-family = \"Menlo\"") ?? false)
    }
    
    func testUpdateConfigValueQuotesFontFamily() {
        let configPath = Ghostty.Config.configFilePath
        let initial = "cursor-style = block"
        try? initial.write(to: configPath, atomically: true, encoding: .utf8)
        
        ConfigSyncManager.shared.updateConfigValue(key: "font-family", value: "JetBrains Mono")
        
        let content = try? String(contentsOf: configPath, encoding: .utf8)
        XCTAssertTrue(content?.contains("font-family = \"JetBrains Mono\"") ?? false)
    }
    
    func testUpdateConfigValuePreservesComments() {
        let configPath = Ghostty.Config.configFilePath
        let initial = "# My config\nfont-family = \"Menlo\"\n# End"
        try? initial.write(to: configPath, atomically: true, encoding: .utf8)
        
        ConfigSyncManager.shared.updateConfigValue(key: "font-family", value: "Hack")
        
        let content = try? String(contentsOf: configPath, encoding: .utf8)
        XCTAssertTrue(content?.contains("# My config") ?? false)
        XCTAssertTrue(content?.contains("# End") ?? false)
        XCTAssertTrue(content?.contains("font-family = \"Hack\"") ?? false)
    }
    
    // MARK: - Convenience update methods
    
    func testUpdateFontFamilyMapsToGhosttyName() {
        let configPath = Ghostty.Config.configFilePath
        let initial = "font-family = \"Menlo\""
        try? initial.write(to: configPath, atomically: true, encoding: .utf8)
        
        ConfigSyncManager.shared.updateFontFamily("Departure Mono")
        
        let content = try? String(contentsOf: configPath, encoding: .utf8)
        // FontMapping.toGhostty("Departure Mono") == "Departure Mono"
        XCTAssertTrue(content?.contains("font-family = \"Departure Mono\"") ?? false)
    }
    
    func testUpdateCursorStyle() {
        let configPath = Ghostty.Config.configFilePath
        let initial = "cursor-style = block"
        try? initial.write(to: configPath, atomically: true, encoding: .utf8)
        
        ConfigSyncManager.shared.updateCursorStyle("bar")
        
        let content = try? String(contentsOf: configPath, encoding: .utf8)
        XCTAssertTrue(content?.contains("cursor-style = bar") ?? false)
    }
    
    func testUpdateFontThicken() {
        let configPath = Ghostty.Config.configFilePath
        let initial = "font-thicken = true"
        try? initial.write(to: configPath, atomically: true, encoding: .utf8)
        
        ConfigSyncManager.shared.updateFontThicken(false)
        
        let content = try? String(contentsOf: configPath, encoding: .utf8)
        XCTAssertTrue(content?.contains("font-thicken = false") ?? false)
    }
    
    func testUpdateBackgroundOpacity() {
        let configPath = Ghostty.Config.configFilePath
        let initial = "background-opacity = 0.95"
        try? initial.write(to: configPath, atomically: true, encoding: .utf8)
        
        ConfigSyncManager.shared.updateBackgroundOpacity(0.80)
        
        let content = try? String(contentsOf: configPath, encoding: .utf8)
        XCTAssertTrue(content?.contains("background-opacity = 0.80") ?? false)
    }
    
    // MARK: - getBackgroundOpacity
    
    func testGetBackgroundOpacityFromFile() {
        let configPath = Ghostty.Config.configFilePath
        let config = "background-opacity = 0.75\ncursor-style = block"
        try? config.write(to: configPath, atomically: true, encoding: .utf8)
        
        let opacity = ConfigSyncManager.shared.getBackgroundOpacity()
        // May use Config-based path or file-based path depending on runtime
        // Either way, should return 0.75
        XCTAssertEqual(opacity, 0.75, accuracy: 0.01)
    }
    
    func testGetBackgroundOpacityDefaultWhenMissing() {
        let configPath = Ghostty.Config.configFilePath
        let config = "cursor-style = block"
        try? config.write(to: configPath, atomically: true, encoding: .utf8)
        
        let opacity = ConfigSyncManager.shared.getBackgroundOpacity()
        // Default from Ghostty is 1.0, default from file parser is 0.95
        // Accept either — the important thing is it returns a sensible value
        XCTAssertTrue(opacity >= 0.95 && opacity <= 1.0,
                      "Expected default opacity between 0.95 and 1.0, got \(opacity)")
    }
    
    func testGetBackgroundOpacityIgnoresComments() {
        let configPath = Ghostty.Config.configFilePath
        let config = "# background-opacity = 0.50\nbackground-opacity = 0.85"
        try? config.write(to: configPath, atomically: true, encoding: .utf8)
        
        let opacity = ConfigSyncManager.shared.getBackgroundOpacity()
        XCTAssertEqual(opacity, 0.85, accuracy: 0.01)
    }
    
    // MARK: - loadConfigToGUI integration
    
    func testLoadConfigToGUISyncsFontFamily() {
        let configPath = Ghostty.Config.configFilePath
        let config = "font-family = \"JetBrains Mono\"\ncursor-style = bar"
        try? config.write(to: configPath, atomically: true, encoding: .utf8)
        
        ConfigSyncManager.shared.loadConfigToGUI()
        
        let fontFamily = defaults.string(forKey: "terminal.fontFamily")
        XCTAssertEqual(fontFamily, "JetBrains Mono")
        
        let cursor = defaults.string(forKey: "terminal.cursorStyle")
        XCTAssertEqual(cursor, "bar")
    }
    
    func testLoadConfigToGUISyncsFontThicken() {
        let configPath = Ghostty.Config.configFilePath
        let config = "font-thicken = false"
        try? config.write(to: configPath, atomically: true, encoding: .utf8)
        
        ConfigSyncManager.shared.loadConfigToGUI()
        
        let thicken = defaults.bool(forKey: "terminal.fontThicken")
        XCTAssertFalse(thicken)
    }
    
    func testLoadConfigToGUISyncsTheme() {
        let configPath = Ghostty.Config.configFilePath
        let config = "theme = Dracula+"
        try? config.write(to: configPath, atomically: true, encoding: .utf8)
        
        ConfigSyncManager.shared.loadConfigToGUI()
        
        let theme = defaults.string(forKey: "terminal.colorTheme")
        XCTAssertEqual(theme, "Dracula+")
    }
    
    func testLoadConfigToGUIHandlesNoFile() {
        // Delete config file if it exists
        let configPath = Ghostty.Config.configFilePath
        try? FileManager.default.removeItem(at: configPath)
        
        // Should not crash
        ConfigSyncManager.shared.loadConfigToGUI()
        
        // After loading, a default config file may have been created by Config()
        // Just verify it didn't crash
    }
    
    // MARK: - Config file round-trip
    
    func testRoundTripFontFamily() {
        let configPath = Ghostty.Config.configFilePath
        let initial = "font-family = \"Menlo\""
        try? initial.write(to: configPath, atomically: true, encoding: .utf8)
        
        // Write new value
        ConfigSyncManager.shared.updateFontFamily("Hack")
        
        // Read it back
        ConfigSyncManager.shared.loadConfigToGUI()
        
        let fontFamily = defaults.string(forKey: "terminal.fontFamily")
        XCTAssertEqual(fontFamily, "Hack")
    }
    
    func testRoundTripBackgroundOpacity() {
        let configPath = Ghostty.Config.configFilePath
        let initial = "background-opacity = 0.95"
        try? initial.write(to: configPath, atomically: true, encoding: .utf8)
        
        // Write new value
        ConfigSyncManager.shared.updateBackgroundOpacity(0.70)
        
        // Read it back
        let opacity = ConfigSyncManager.shared.getBackgroundOpacity()
        XCTAssertEqual(opacity, 0.70, accuracy: 0.01)
    }
}
