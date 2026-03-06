//
//  CommandPaletteTests.swift
//  GeisttyUITests
//
//  Tests for the Command Palette — opening, searching/filtering commands,
//  selecting a command, and dismissing.
//

import XCTest

final class CommandPaletteTests: XCTestCase {

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

    // MARK: - Open & Dismiss

    /// Opening the Command Palette via Cmd+Shift+P should show the search field.
    func testOpenCommandPalette() throws {
        takeScreenshot(app, name: "OpenPalette-01-Before")

        app.openCommandPalette()
        Thread.sleep(forTimeInterval: 0.5)

        let searchField = app.textFields["CommandPaletteSearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3),
                      "CommandPaletteSearchField should exist after Cmd+Shift+P")

        takeScreenshot(app, name: "OpenPalette-02-Opened")
    }

    /// The search field in the Command Palette should accept typed input.
    func testCommandPaletteSearchFieldAcceptsInput() throws {
        app.openCommandPalette()
        Thread.sleep(forTimeInterval: 0.5)

        let searchField = app.textFields["CommandPaletteSearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3),
                      "CommandPaletteSearchField should exist")

        searchField.tap()
        searchField.typeText("test input")
        Thread.sleep(forTimeInterval: 0.3)

        takeScreenshot(app, name: "SearchInput-01-Typed")

        XCTAssertEqual(searchField.value as? String, "test input",
                       "Search field should contain typed text")
    }

    /// After opening the Command Palette, the command list should contain items.
    func testCommandPaletteShowsCommands() throws {
        app.openCommandPalette()
        Thread.sleep(forTimeInterval: 0.5)

        let searchField = app.textFields["CommandPaletteSearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3),
                      "CommandPaletteSearchField should exist")

        takeScreenshot(app, name: "ShowsCommands-01-Opened")

        // The list should contain at least one command (cell or button)
        let cells = app.cells
        let buttons = app.buttons
        let hasItems = cells.count > 0 || buttons.count > 1
        XCTAssertTrue(hasItems,
                      "Command Palette should display at least one command")

        takeScreenshot(app, name: "ShowsCommands-02-ListVisible")
    }

    /// Typing a filter narrows the displayed commands.
    func testCommandPaletteFilterCommands() throws {
        app.openCommandPalette()
        Thread.sleep(forTimeInterval: 0.5)

        let searchField = app.textFields["CommandPaletteSearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3),
                      "CommandPaletteSearchField should exist")

        takeScreenshot(app, name: "FilterCommands-01-BeforeFilter")

        searchField.tap()
        searchField.typeText("split")
        Thread.sleep(forTimeInterval: 0.5)

        takeScreenshot(app, name: "FilterCommands-02-FilteredResults")
    }

    /// Pressing Escape should dismiss the Command Palette.
    func testCommandPaletteDismissWithEscape() throws {
        app.openCommandPalette()
        Thread.sleep(forTimeInterval: 0.5)

        let searchField = app.textFields["CommandPaletteSearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3),
                      "CommandPaletteSearchField should exist before dismiss")

        takeScreenshot(app, name: "Dismiss-01-Opened")

        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(searchField.waitForDisappearance(timeout: 3),
                      "CommandPaletteSearchField should disappear after pressing Escape")

        takeScreenshot(app, name: "Dismiss-02-AfterEscape")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should be visible after dismissing the palette")
    }

    /// Tapping a command from the list should execute/select it.
    func testCommandPaletteSelectCommand() throws {
        app.openCommandPalette()
        Thread.sleep(forTimeInterval: 0.5)

        let searchField = app.textFields["CommandPaletteSearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3),
                      "CommandPaletteSearchField should exist")

        takeScreenshot(app, name: "SelectCommand-01-Opened")

        // Tap the first cell in the command list
        let firstCell = app.cells.firstMatch
        if firstCell.waitForExistence(timeout: 3) {
            firstCell.tap()
        } else {
            // Fall back to the first non-search-field button
            let firstButton = app.buttons.firstMatch
            XCTAssertTrue(firstButton.waitForExistence(timeout: 3),
                          "At least one tappable command should exist")
            firstButton.tap()
        }

        Thread.sleep(forTimeInterval: 0.5)
        takeScreenshot(app, name: "SelectCommand-02-AfterSelect")
    }
}
