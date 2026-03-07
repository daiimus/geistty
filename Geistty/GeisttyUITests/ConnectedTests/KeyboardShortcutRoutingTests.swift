//
//  KeyboardShortcutRoutingTests.swift
//  GeisttyUITests
//
//  Tests for keyboard shortcut edge cases: cross-shortcut interaction,
//  overlay conflicts, and responder chain routing verification.
//

import XCTest

final class KeyboardShortcutRoutingTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        guard TestConfig.isConfigured else {
            throw XCTSkip("TestConfig.local.swift not configured — isConfigured is false")
        }

        continueAfterFailure = false
        app = launchForConnectedTests()

        XCTAssertTrue(app.waitForTerminal(timeout: TestConfig.connectionTimeout),
                      "Terminal surface should appear after connecting")
    }

    override func tearDownWithError() throws {
        takeScreenshot(app, name: "\(name)-teardown")
        app = nil
    }

    // MARK: - Cross-Overlay Conflicts

    /// Cmd+Shift+P while search is open should dismiss search and show command palette.
    func testCommandPaletteReplacesSearch() throws {
        takeScreenshot(app, name: "PaletteReplacesSearch-01-Before")

        // Open search first
        app.openSearch()
        Thread.sleep(forTimeInterval: 0.5)
        let searchField = app.textFields["SearchTextField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3),
                      "SearchTextField should appear after Cmd+F")
        takeScreenshot(app, name: "PaletteReplacesSearch-02-SearchOpen")

        // Now open command palette — should replace search
        app.openCommandPalette()
        Thread.sleep(forTimeInterval: 0.5)

        let paletteField = app.textFields["CommandPaletteSearchField"]
        XCTAssertTrue(paletteField.waitForExistence(timeout: 3),
                      "CommandPaletteSearchField should appear after Cmd+Shift+P")

        // Search should be dismissed
        XCTAssertTrue(searchField.waitForDisappearance(timeout: 3),
                      "SearchTextField should disappear when command palette opens")

        takeScreenshot(app, name: "PaletteReplacesSearch-03-PaletteOpen")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should remain active")
    }

    /// Cmd+F while command palette is open should dismiss palette and show search.
    func testSearchReplacesCommandPalette() throws {
        takeScreenshot(app, name: "SearchReplacesPalette-01-Before")

        // Open command palette first
        app.openCommandPalette()
        Thread.sleep(forTimeInterval: 0.5)
        let paletteField = app.textFields["CommandPaletteSearchField"]
        XCTAssertTrue(paletteField.waitForExistence(timeout: 3),
                      "CommandPaletteSearchField should appear after Cmd+Shift+P")
        takeScreenshot(app, name: "SearchReplacesPalette-02-PaletteOpen")

        // Now open search — should replace palette
        app.openSearch()
        Thread.sleep(forTimeInterval: 0.5)

        let searchField = app.textFields["SearchTextField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3),
                      "SearchTextField should appear after Cmd+F")

        // Palette should be dismissed
        XCTAssertTrue(paletteField.waitForDisappearance(timeout: 3),
                      "CommandPaletteSearchField should disappear when search opens")

        takeScreenshot(app, name: "SearchReplacesPalette-03-SearchOpen")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should remain active")
    }

    // MARK: - Double-Tap Shortcuts

    /// Pressing Cmd+F twice should toggle search off or re-focus the search field.
    func testDoubleCmdFTogglesBehavior() throws {
        takeScreenshot(app, name: "DoubleCmdF-01-Before")

        // First Cmd+F — open search
        app.openSearch()
        Thread.sleep(forTimeInterval: 0.5)
        let searchField = app.textFields["SearchTextField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3),
                      "SearchTextField should appear after first Cmd+F")
        takeScreenshot(app, name: "DoubleCmdF-02-FirstOpen")

        // Second Cmd+F — should either toggle off or re-focus
        app.openSearch()
        Thread.sleep(forTimeInterval: 0.5)

        // Either the search field is gone (toggle off) or still present (re-focus)
        // Both are valid behaviors — the test ensures no crash
        takeScreenshot(app, name: "DoubleCmdF-03-SecondPress")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should remain active after double Cmd+F")
    }

    /// Pressing Cmd+Shift+P twice rapidly should not crash or duplicate the palette.
    func testDoubleCmdShiftPNoCrash() throws {
        takeScreenshot(app, name: "DoubleCmdShiftP-01-Before")

        // Rapid double-tap Cmd+Shift+P
        app.openCommandPalette()
        Thread.sleep(forTimeInterval: 0.2)
        app.openCommandPalette()
        Thread.sleep(forTimeInterval: 0.5)

        takeScreenshot(app, name: "DoubleCmdShiftP-02-AfterDouble")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should remain active after double Cmd+Shift+P")
    }

    // MARK: - Font Size During Overlays

    /// Cmd+= while search field has focus should increase font size, not type into search.
    func testFontSizeIncreaseWhileSearchOpen() throws {
        takeScreenshot(app, name: "FontInSearch-01-Before")

        app.openSearch()
        Thread.sleep(forTimeInterval: 0.5)
        let searchField = app.textFields["SearchTextField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3),
                      "SearchTextField should appear")

        // Type something first to see if Cmd+= adds to it
        searchField.typeText("test")
        Thread.sleep(forTimeInterval: 0.3)
        takeScreenshot(app, name: "FontInSearch-02-TextTyped")

        let textBefore = searchField.value as? String ?? ""

        // Cmd+= should be intercepted by the terminal, not typed into search
        app.increaseFontSize()
        Thread.sleep(forTimeInterval: 0.3)

        let textAfter = searchField.value as? String ?? ""
        takeScreenshot(app, name: "FontInSearch-03-AfterCmdEquals")

        // The search field text should NOT have changed (= not typed)
        XCTAssertEqual(textBefore, textAfter,
                       "Cmd+= should not add text to the search field")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should remain active")
    }

    // MARK: - Shortcut After Escape

    /// After dismissing search with Escape, Cmd+Shift+P should work normally.
    func testShortcutAfterEscapeDismiss() throws {
        takeScreenshot(app, name: "ShortcutAfterEscape-01-Before")

        // Open and dismiss search
        app.openSearch()
        Thread.sleep(forTimeInterval: 0.5)
        let searchField = app.textFields["SearchTextField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))

        // Dismiss with Escape
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(searchField.waitForDisappearance(timeout: 3),
                      "Search should be dismissed after Escape")
        takeScreenshot(app, name: "ShortcutAfterEscape-02-SearchDismissed")

        // Now Cmd+Shift+P should open the command palette
        app.openCommandPalette()
        Thread.sleep(forTimeInterval: 0.5)
        let paletteField = app.textFields["CommandPaletteSearchField"]
        XCTAssertTrue(paletteField.waitForExistence(timeout: 3),
                      "Command palette should open after Escape dismisses search")

        takeScreenshot(app, name: "ShortcutAfterEscape-03-PaletteOpen")
    }

    /// After dismissing command palette with Escape, Cmd+F should work normally.
    func testSearchAfterPaletteEscapeDismiss() throws {
        takeScreenshot(app, name: "SearchAfterPalette-01-Before")

        // Open and dismiss command palette
        app.openCommandPalette()
        Thread.sleep(forTimeInterval: 0.5)
        let paletteField = app.textFields["CommandPaletteSearchField"]
        XCTAssertTrue(paletteField.waitForExistence(timeout: 3))

        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(paletteField.waitForDisappearance(timeout: 3),
                      "Command palette should be dismissed after Escape")
        takeScreenshot(app, name: "SearchAfterPalette-02-PaletteDismissed")

        // Now Cmd+F should open search
        app.openSearch()
        Thread.sleep(forTimeInterval: 0.5)
        let searchField = app.textFields["SearchTextField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3),
                      "Search should open after Escape dismisses command palette")

        takeScreenshot(app, name: "SearchAfterPalette-03-SearchOpen")
    }

    // MARK: - Copy/Paste in Connected State

    /// Cmd+C in terminal (with no selection) should not crash.
    func testCmdCWithNoSelection() throws {
        takeScreenshot(app, name: "CmdCNoSelect-01-Before")

        app.typeKey("c", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        takeScreenshot(app, name: "CmdCNoSelect-02-After")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should remain active after Cmd+C with no selection")
    }

    /// Cmd+V should not crash the terminal (paste from clipboard).
    func testCmdVPasteNoCrash() throws {
        takeScreenshot(app, name: "CmdVPaste-01-Before")

        app.typeKey("v", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        takeScreenshot(app, name: "CmdVPaste-02-After")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should remain active after Cmd+V")
    }
}
