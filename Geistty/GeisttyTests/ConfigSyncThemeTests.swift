import XCTest
@testable import Geistty

// MARK: - ConfigSyncManager Theme Tests

@MainActor
final class ConfigSyncThemeTests: XCTestCase {
    
    // MARK: - applyTheme: Basic theme application
    
    func testApplyThemeToEmptyConfig() {
        let result = ConfigSyncManager.applyTheme("Dracula+", to: "")
        XCTAssertTrue(result.contains("theme = Dracula+"))
    }
    
    func testApplyThemeAppendsWhenNoThemeLine() {
        let config = """
        font-family = "Menlo"
        cursor-style = block
        """
        let result = ConfigSyncManager.applyTheme("Nord", to: config)
        XCTAssertTrue(result.contains("theme = Nord"))
        XCTAssertTrue(result.contains("font-family = \"Menlo\""))
        XCTAssertTrue(result.contains("cursor-style = block"))
    }
    
    func testApplyThemeReplacesExistingThemeLine() {
        let config = """
        font-family = "Menlo"
        theme = Dracula+
        cursor-style = block
        """
        let result = ConfigSyncManager.applyTheme("Nord", to: config)
        XCTAssertTrue(result.contains("theme = Nord"))
        XCTAssertFalse(result.contains("Dracula+"))
    }
    
    // MARK: - applyTheme: Default theme removes theme line
    
    func testApplyDefaultRemovesThemeLine() {
        let config = """
        font-family = "Menlo"
        theme = Dracula+
        cursor-style = block
        """
        let result = ConfigSyncManager.applyTheme("Default", to: config)
        XCTAssertFalse(result.contains("theme ="))
        XCTAssertFalse(result.contains("Dracula+"))
        XCTAssertTrue(result.contains("font-family = \"Menlo\""))
        XCTAssertTrue(result.contains("cursor-style = block"))
    }
    
    func testApplyDefaultToConfigWithNoTheme() {
        let config = """
        font-family = "Menlo"
        cursor-style = block
        """
        let result = ConfigSyncManager.applyTheme("Default", to: config)
        XCTAssertFalse(result.contains("theme ="))
        // Config should be unchanged (no theme line to remove, none to add)
        XCTAssertTrue(result.contains("font-family = \"Menlo\""))
        XCTAssertTrue(result.contains("cursor-style = block"))
    }
    
    // MARK: - applyTheme: Strips old inline color entries
    
    func testStripsOldInlinePaletteEntries() {
        let config = """
        font-family = "Menlo"
        palette = 0=#000000
        palette = 1=#cc0000
        palette = 15=#eeeeec
        cursor-style = block
        """
        let result = ConfigSyncManager.applyTheme("Tokyo Night", to: config)
        XCTAssertFalse(result.contains("palette ="))
        XCTAssertTrue(result.contains("font-family = \"Menlo\""))
        XCTAssertTrue(result.contains("cursor-style = block"))
        XCTAssertTrue(result.contains("theme = Tokyo Night"))
    }
    
    func testStripsOldInlineColorKeys() {
        let config = """
        font-family = "Menlo"
        background = #282c34
        foreground = #ffffff
        cursor-color = #ffffff
        cursor-text = #000000
        selection-background = #3e4451
        selection-foreground = #abb2bf
        cursor-style = block
        """
        let result = ConfigSyncManager.applyTheme("Solarized Dark", to: config)
        XCTAssertFalse(result.contains("background ="))
        XCTAssertFalse(result.contains("foreground ="))
        XCTAssertFalse(result.contains("cursor-color ="))
        XCTAssertFalse(result.contains("cursor-text ="))
        XCTAssertFalse(result.contains("selection-background ="))
        XCTAssertFalse(result.contains("selection-foreground ="))
        XCTAssertTrue(result.contains("font-family = \"Menlo\""))
        XCTAssertTrue(result.contains("cursor-style = block"))
        XCTAssertTrue(result.contains("theme = Solarized Dark"))
    }
    
    func testStripsOldThemeCommentLine() {
        let config = """
        font-family = "Menlo"
        # Theme: Dracula+
        palette = 0=#282a36
        background = #282a36
        foreground = #f8f8f2
        """
        let result = ConfigSyncManager.applyTheme("Nord", to: config)
        XCTAssertFalse(result.contains("# Theme:"))
        XCTAssertFalse(result.contains("palette ="))
        XCTAssertFalse(result.contains("background ="))
        XCTAssertFalse(result.contains("foreground ="))
        XCTAssertTrue(result.contains("theme = Nord"))
    }
    
    // MARK: - applyTheme: Preserves non-color config
    
    func testPreservesBackgroundOpacity() {
        let config = """
        font-family = "Menlo"
        background-opacity = 0.95
        background = #282c34
        cursor-style = block
        """
        let result = ConfigSyncManager.applyTheme("Nord", to: config)
        XCTAssertTrue(result.contains("background-opacity = 0.95"),
                      "background-opacity must be preserved (not stripped with 'background')")
        XCTAssertFalse(result.contains("background = #"))
    }
    
    func testPreservesComments() {
        let config = """
        # My custom config
        font-family = "Menlo"
        
        # Cursor settings
        cursor-style = block
        """
        let result = ConfigSyncManager.applyTheme("Nord", to: config)
        XCTAssertTrue(result.contains("# My custom config"))
        XCTAssertTrue(result.contains("# Cursor settings"))
    }
    
    func testPreservesEmptyLines() {
        let config = "font-family = \"Menlo\"\n\ncursor-style = block"
        let result = ConfigSyncManager.applyTheme("Nord", to: config)
        let lines = result.components(separatedBy: "\n")
        // Should have: font-family, empty line, cursor-style, theme
        XCTAssertTrue(lines.contains(""))
    }
    
    func testPreservesFontThicken() {
        let config = """
        font-thicken = true
        background = #000000
        """
        let result = ConfigSyncManager.applyTheme("Nord", to: config)
        XCTAssertTrue(result.contains("font-thicken = true"))
        XCTAssertFalse(result.contains("background = #"))
    }
    
    func testPreservesScrollbackLimit() {
        let config = """
        scrollback-limit = 50000000
        palette = 0=#000000
        """
        let result = ConfigSyncManager.applyTheme("Nord", to: config)
        XCTAssertTrue(result.contains("scrollback-limit = 50000000"))
        XCTAssertFalse(result.contains("palette ="))
    }
    
    // MARK: - applyTheme: Full migration scenario
    
    /// Simulates upgrading from old inline color system to new theme system.
    /// A config with inline colors and a "# Theme:" comment should be cleaned
    /// up to just "theme = <name>" with all non-color settings preserved.
    func testFullMigrationFromOldSystem() {
        let oldConfig = """
        # Geistty Terminal Configuration
        font-family = "Menlo"
        font-thicken = true
        cursor-style = block
        background-opacity = 0.95
        scrollback-limit = 50000000
        
        # Theme: Dracula+
        palette = 0=#282a36
        palette = 1=#ff5555
        palette = 2=#50fa7b
        palette = 3=#f1fa8c
        palette = 4=#bd93f9
        palette = 5=#ff79c6
        palette = 6=#8be9fd
        palette = 7=#f8f8f2
        palette = 8=#6272a4
        palette = 9=#ff6e6e
        palette = 10=#69ff94
        palette = 11=#ffffa5
        palette = 12=#d6acff
        palette = 13=#ff92df
        palette = 14=#a4ffff
        palette = 15=#ffffff
        background = #282a36
        foreground = #f8f8f2
        cursor-color = #f8f8f2
        selection-background = #44475a
        selection-foreground = #f8f8f2
        """
        
        let result = ConfigSyncManager.applyTheme("Dracula+", to: oldConfig)
        
        // All old inline colors removed
        XCTAssertFalse(result.contains("palette ="), "All palette entries should be stripped")
        XCTAssertFalse(result.contains("background = #"), "Inline background should be stripped")
        XCTAssertFalse(result.contains("foreground ="), "Inline foreground should be stripped")
        XCTAssertFalse(result.contains("cursor-color ="), "Inline cursor-color should be stripped")
        XCTAssertFalse(result.contains("selection-background ="), "Inline selection-bg should be stripped")
        XCTAssertFalse(result.contains("selection-foreground ="), "Inline selection-fg should be stripped")
        XCTAssertFalse(result.contains("# Theme:"), "Old theme comment should be stripped")
        
        // Non-color settings preserved
        XCTAssertTrue(result.contains("font-family = \"Menlo\""))
        XCTAssertTrue(result.contains("font-thicken = true"))
        XCTAssertTrue(result.contains("cursor-style = block"))
        XCTAssertTrue(result.contains("background-opacity = 0.95"))
        XCTAssertTrue(result.contains("scrollback-limit = 50000000"))
        XCTAssertTrue(result.contains("# Geistty Terminal Configuration"))
        
        // New theme line present
        XCTAssertTrue(result.contains("theme = Dracula+"))
        
        // Only one "theme =" line
        let themeLines = result.components(separatedBy: "\n").filter { $0.hasPrefix("theme =") }
        XCTAssertEqual(themeLines.count, 1, "Should have exactly one theme line")
    }
    
    // MARK: - applyTheme: Edge cases
    
    func testDoesNotStripNonExactKeyMatches() {
        // "background-opacity" should NOT match "background"
        // "foreground-bold" (hypothetical) should NOT match "foreground"
        let config = """
        background-opacity = 0.95
        bold-color = bright
        """
        let result = ConfigSyncManager.applyTheme("Nord", to: config)
        XCTAssertTrue(result.contains("background-opacity = 0.95"))
        XCTAssertTrue(result.contains("bold-color = bright"))
    }
    
    func testHandlesConfigWithOnlyInlineColors() {
        let config = """
        background = #000000
        foreground = #ffffff
        palette = 0=#000000
        """
        let result = ConfigSyncManager.applyTheme("Nord", to: config)
        // All inline colors stripped, only theme line remains
        let nonEmptyLines = result.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(nonEmptyLines.count, 1)
        XCTAssertEqual(nonEmptyLines.first, "theme = Nord")
    }
    
    func testHandlesWhitespaceAroundKeys() {
        let config = "  background  =  #000000\n  theme  =  OldTheme"
        let result = ConfigSyncManager.applyTheme("Nord", to: config)
        XCTAssertFalse(result.contains("#000000"))
        XCTAssertTrue(result.contains("theme = Nord"))
        XCTAssertFalse(result.contains("OldTheme"))
    }
    
    // MARK: - inlineColorKeys set coverage
    
    func testInlineColorKeysContainsAllExpected() {
        let expected = Set(["background", "foreground", "cursor-color", "cursor-text",
                            "selection-background", "selection-foreground", "palette"])
        XCTAssertEqual(ConfigSyncManager.inlineColorKeys, expected)
    }
    
    func testInlineColorKeysDoesNotContainNonColorKeys() {
        XCTAssertFalse(ConfigSyncManager.inlineColorKeys.contains("background-opacity"))
        XCTAssertFalse(ConfigSyncManager.inlineColorKeys.contains("font-family"))
        XCTAssertFalse(ConfigSyncManager.inlineColorKeys.contains("cursor-style"))
        XCTAssertFalse(ConfigSyncManager.inlineColorKeys.contains("theme"))
        XCTAssertFalse(ConfigSyncManager.inlineColorKeys.contains("bold-color"))
    }
    
    // MARK: - Line ending preservation (#39)
    
    func testApplyThemePreservesCRLFLineEndings() {
        let config = "font-family = Hack\r\ntheme = OldTheme\r\ncursor-style = block\r\n"
        let result = ConfigSyncManager.applyTheme("Nord", to: config)
        // Must preserve CRLF throughout
        XCTAssertTrue(result.contains("\r\n"), "CRLF line endings should be preserved")
        XCTAssertTrue(result.contains("theme = Nord"))
        XCTAssertTrue(result.contains("font-family = Hack"))
    }
    
    func testApplyThemePreservesLFLineEndings() {
        let config = "font-family = Hack\ntheme = OldTheme\ncursor-style = block\n"
        let result = ConfigSyncManager.applyTheme("Nord", to: config)
        // Must NOT introduce CRLF
        XCTAssertFalse(result.contains("\r\n"), "LF-only endings should not gain CR")
        XCTAssertTrue(result.contains("theme = Nord"))
    }
    
    func testApplyThemeCRLFWithInlineColorStripping() {
        let config = "background = #000000\r\nforeground = #ffffff\r\nfont-family = Hack\r\n"
        let result = ConfigSyncManager.applyTheme("Dracula+", to: config)
        // Inline colors stripped, CRLF preserved
        XCTAssertFalse(result.contains("#000000"))
        XCTAssertFalse(result.contains("#ffffff"))
        XCTAssertTrue(result.contains("theme = Dracula+"))
        // All remaining line breaks should be CRLF
        let withoutCRLF = result.replacingOccurrences(of: "\r\n", with: "CRLF")
        XCTAssertFalse(withoutCRLF.contains("\n"), "No bare LF should exist when source uses CRLF")
    }
}
