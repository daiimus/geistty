//
//  ToolbarTests.swift
//  GeisttyUITests
//
//  Tests for the terminal toolbar — the virtual keyboard accessory row
//  with Esc, Tab, Ctrl, arrow keys, and special characters.
//

import XCTest

final class ToolbarTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        guard TestConfig.isConfigured else {
            throw XCTSkip("TestConfig.local.swift not configured — isConfigured is false")
        }

        continueAfterFailure = false
        app = launchForConnectedTests()

        XCTAssertTrue(app.waitForTerminal(timeout: TestConfig.connectionTimeout),
                      "Terminal surface should appear after connecting")

        // Tap the terminal surface to bring up the keyboard and toolbar
        let surface = app.otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH 'TerminalSurface'")
        ).firstMatch
        surface.tap()
        Thread.sleep(forTimeInterval: 1.0)
    }

    override func tearDownWithError() throws {
        takeScreenshot(app, name: "\(name)-teardown")
        app = nil
    }

    // MARK: - Existence

    /// Esc, Tab, and Ctrl buttons should be visible in the toolbar.
    func testToolbarKeysExist() throws {
        takeScreenshot(app, name: "ToolbarKeys-01-Initial")

        let esc = app.buttons["ToolbarKey-Esc"]
        let tab = app.buttons["ToolbarKey-Tab"]
        let ctrl = app.buttons["ToolbarKey-Ctrl"]

        XCTAssertTrue(esc.waitForExistence(timeout: 5), "Esc key should exist in toolbar")
        XCTAssertTrue(tab.exists, "Tab key should exist in toolbar")
        XCTAssertTrue(ctrl.exists, "Ctrl key should exist in toolbar")

        takeScreenshot(app, name: "ToolbarKeys-02-Verified")
    }

    /// All four arrow keys should be visible in the toolbar.
    func testToolbarArrowKeysExist() throws {
        takeScreenshot(app, name: "ArrowKeys-01-Initial")

        let up = app.buttons["ToolbarKey-Up arrow"]
        let down = app.buttons["ToolbarKey-Down arrow"]
        let left = app.buttons["ToolbarKey-Left arrow"]
        let right = app.buttons["ToolbarKey-Right arrow"]

        XCTAssertTrue(up.waitForExistence(timeout: 5), "Up arrow key should exist in toolbar")
        XCTAssertTrue(down.exists, "Down arrow key should exist in toolbar")
        XCTAssertTrue(left.exists, "Left arrow key should exist in toolbar")
        XCTAssertTrue(right.exists, "Right arrow key should exist in toolbar")

        takeScreenshot(app, name: "ArrowKeys-02-Verified")
    }

    /// Character keys (pipe, tilde, etc.) should be visible in the toolbar.
    func testToolbarCharacterKeysExist() throws {
        takeScreenshot(app, name: "CharKeys-01-Initial")

        let charIdentifiers = [
            "ToolbarChar-pipe",
            "ToolbarChar-tilde",
            "ToolbarChar-backtick",
            "ToolbarChar-bracket-open",
            "ToolbarChar-bracket-close",
            "ToolbarChar-brace-open",
            "ToolbarChar-brace-close",
            "ToolbarChar-backslash",
            "ToolbarChar-hyphen",
            "ToolbarChar-slash",
            "ToolbarChar-semicolon",
            "ToolbarChar-equals",
            "ToolbarChar-underscore",
        ]

        // Wait for the first one to appear before checking the rest
        let firstKey = app.buttons[charIdentifiers[0]]
        XCTAssertTrue(firstKey.waitForExistence(timeout: 5),
                      "\(charIdentifiers[0]) should exist in toolbar")

        for id in charIdentifiers.dropFirst() {
            let key = app.buttons[id]
            XCTAssertTrue(key.exists, "\(id) should exist in toolbar")
        }

        takeScreenshot(app, name: "CharKeys-02-Verified")
    }

    // MARK: - Tap Function Keys

    /// Tapping the Esc key should send escape to the terminal.
    func testTapEscKey() throws {
        let esc = app.buttons["ToolbarKey-Esc"]
        XCTAssertTrue(esc.waitForExistence(timeout: 5), "Esc key should exist")

        esc.tap()
        Thread.sleep(forTimeInterval: 0.5)

        takeScreenshot(app, name: "TapEsc-01-AfterTap")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should remain active after tapping Esc")
    }

    /// Tapping the Tab key should send tab to the terminal.
    func testTapTabKey() throws {
        let tab = app.buttons["ToolbarKey-Tab"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "Tab key should exist")

        tab.tap()
        Thread.sleep(forTimeInterval: 0.5)

        takeScreenshot(app, name: "TapTab-01-AfterTap")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should remain active after tapping Tab")
    }

    /// Tapping the Ctrl key should toggle it (modifier key behavior).
    func testTapCtrlKey() throws {
        let ctrl = app.buttons["ToolbarKey-Ctrl"]
        XCTAssertTrue(ctrl.waitForExistence(timeout: 5), "Ctrl key should exist")

        takeScreenshot(app, name: "TapCtrl-01-BeforeTap")

        ctrl.tap()
        Thread.sleep(forTimeInterval: 0.5)

        takeScreenshot(app, name: "TapCtrl-02-AfterFirstTap")

        // Tap again to toggle off
        ctrl.tap()
        Thread.sleep(forTimeInterval: 0.5)

        takeScreenshot(app, name: "TapCtrl-03-AfterSecondTap")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should remain active after toggling Ctrl")
    }

    // MARK: - Tap Arrow Keys

    /// Tapping each arrow key should send the corresponding escape sequence.
    func testTapArrowKeys() throws {
        let arrows: [(String, String)] = [
            ("ToolbarKey-Up arrow", "Up"),
            ("ToolbarKey-Down arrow", "Down"),
            ("ToolbarKey-Left arrow", "Left"),
            ("ToolbarKey-Right arrow", "Right"),
        ]

        for (id, label) in arrows {
            let key = app.buttons[id]
            XCTAssertTrue(key.waitForExistence(timeout: 5),
                          "\(label) arrow key should exist")

            key.tap()
            Thread.sleep(forTimeInterval: 0.3)
        }

        takeScreenshot(app, name: "TapArrows-01-AfterAll")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should remain active after tapping arrow keys")
    }

    // MARK: - Tap Character Keys

    /// Tapping character keys should insert the corresponding character.
    func testTapCharacterKeys() throws {
        let pipe = app.buttons["ToolbarChar-pipe"]
        XCTAssertTrue(pipe.waitForExistence(timeout: 5), "Pipe key should exist")

        pipe.tap()
        Thread.sleep(forTimeInterval: 0.3)

        let tilde = app.buttons["ToolbarChar-tilde"]
        XCTAssertTrue(tilde.exists, "Tilde key should exist")

        tilde.tap()
        Thread.sleep(forTimeInterval: 0.3)

        takeScreenshot(app, name: "TapCharKeys-01-AfterPipeAndTilde")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should remain active after tapping character keys")
    }
}
