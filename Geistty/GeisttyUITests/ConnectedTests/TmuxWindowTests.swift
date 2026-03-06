//
//  TmuxWindowTests.swift
//  GeisttyUITests
//
//  Tests for tmux window/tab management — creating, switching between,
//  tapping, and closing windows via the TmuxWindowPickerView.
//

import XCTest

final class TmuxWindowTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        guard TestConfig.isConfigured else {
            throw XCTSkip("TestConfig.local.swift not configured — isConfigured is false")
        }

        continueAfterFailure = false
        app = launchForConnectedTests()

        XCTAssertTrue(app.waitForTerminal(timeout: TestConfig.connectionTimeout),
                      "Terminal surface should appear after connecting")

        // Allow tmux control mode to initialize and populate window state
        Thread.sleep(forTimeInterval: 2.0)
    }

    override func tearDownWithError() throws {
        takeScreenshot(app, name: "\(name)-teardown")
        app = nil
    }

    // MARK: - Window Existence

    /// After connecting, at least one tmux window tab should exist.
    func testInitialWindowExists() throws {
        let tabCount = app.countElements(withIdentifierPrefix: "TmuxWindowTab")
        takeScreenshot(app, name: "InitialWindow-01-Connected")

        XCTAssertGreaterThanOrEqual(tabCount, 1,
                                    "At least one TmuxWindowTab should exist after connecting")
    }

    // MARK: - Creating Windows

    /// Cmd+T should create a new tmux window and increase the tab count.
    func testCreateNewWindow() throws {
        let initialCount = app.countElements(withIdentifierPrefix: "TmuxWindowTab")
        takeScreenshot(app, name: "CreateWindow-01-Before")

        app.newWindow()
        Thread.sleep(forTimeInterval: 1.5)

        let newCount = app.countElements(withIdentifierPrefix: "TmuxWindowTab")
        takeScreenshot(app, name: "CreateWindow-02-After")

        XCTAssertGreaterThan(newCount, initialCount,
                             "Tab count should increase after Cmd+T")
    }

    // MARK: - Switching Windows

    /// Create a second window, then switch to it with Cmd+Shift+].
    func testSwitchToNextWindow() throws {
        takeScreenshot(app, name: "NextWindow-01-Initial")

        app.newWindow()
        Thread.sleep(forTimeInterval: 1.5)
        takeScreenshot(app, name: "NextWindow-02-SecondCreated")

        app.nextWindow()
        Thread.sleep(forTimeInterval: 1.0)
        takeScreenshot(app, name: "NextWindow-03-AfterSwitch")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should remain active after switching to next window")
    }

    /// Create a second window, go next, then go previous with Cmd+Shift+[.
    func testSwitchToPreviousWindow() throws {
        takeScreenshot(app, name: "PrevWindow-01-Initial")

        app.newWindow()
        Thread.sleep(forTimeInterval: 1.5)

        app.nextWindow()
        Thread.sleep(forTimeInterval: 1.0)
        takeScreenshot(app, name: "PrevWindow-02-AtNextWindow")

        app.previousWindow()
        Thread.sleep(forTimeInterval: 1.0)
        takeScreenshot(app, name: "PrevWindow-03-BackToPrevious")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should remain active after switching to previous window")
    }

    // MARK: - Tapping Tabs

    /// Create a second window, then tap the first window tab directly.
    func testTapWindowTab() throws {
        takeScreenshot(app, name: "TapTab-01-Initial")

        app.newWindow()
        Thread.sleep(forTimeInterval: 1.5)
        takeScreenshot(app, name: "TapTab-02-SecondCreated")

        let firstTab = app.otherElements["TmuxWindowTab-0"]
        if firstTab.waitForExistence(timeout: 3) {
            firstTab.tap()
            Thread.sleep(forTimeInterval: 1.0)
        }
        takeScreenshot(app, name: "TapTab-03-AfterTapFirstTab")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should remain active after tapping a window tab")
    }

    // MARK: - New Window Button

    /// Tap the TmuxNewWindowButton and verify a new tab is created.
    func testNewWindowButton() throws {
        let initialCount = app.countElements(withIdentifierPrefix: "TmuxWindowTab")
        takeScreenshot(app, name: "NewWindowButton-01-Before")

        let newWindowButton = app.buttons["TmuxNewWindowButton"]
        XCTAssertTrue(newWindowButton.waitForExistence(timeout: 5),
                      "TmuxNewWindowButton should exist")

        newWindowButton.tap()
        Thread.sleep(forTimeInterval: 1.5)

        let newCount = app.countElements(withIdentifierPrefix: "TmuxWindowTab")
        takeScreenshot(app, name: "NewWindowButton-02-After")

        XCTAssertGreaterThan(newCount, initialCount,
                             "Tab count should increase after tapping new window button")
    }

    // MARK: - Closing Windows

    /// Create a second window, then close it with Cmd+W and verify the count decreases.
    func testCloseWindow() throws {
        let initialCount = app.countElements(withIdentifierPrefix: "TmuxWindowTab")
        takeScreenshot(app, name: "CloseWindow-01-Initial")

        app.newWindow()
        Thread.sleep(forTimeInterval: 1.5)

        let afterCreateCount = app.countElements(withIdentifierPrefix: "TmuxWindowTab")
        takeScreenshot(app, name: "CloseWindow-02-AfterCreate")
        XCTAssertGreaterThan(afterCreateCount, initialCount,
                             "Tab count should increase after creating a window")

        app.closeCurrentPane()
        Thread.sleep(forTimeInterval: 1.5)

        let afterCloseCount = app.countElements(withIdentifierPrefix: "TmuxWindowTab")
        takeScreenshot(app, name: "CloseWindow-03-AfterClose")

        XCTAssertLessThan(afterCloseCount, afterCreateCount,
                          "Tab count should decrease after closing a window")
    }

    // MARK: - Multiple Windows

    /// Create three additional windows and verify all tabs are visible.
    func testMultipleWindows() throws {
        let initialCount = app.countElements(withIdentifierPrefix: "TmuxWindowTab")
        takeScreenshot(app, name: "MultipleWindows-01-Initial")

        app.newWindow()
        Thread.sleep(forTimeInterval: 1.5)

        app.newWindow()
        Thread.sleep(forTimeInterval: 1.5)

        app.newWindow()
        Thread.sleep(forTimeInterval: 1.5)

        let finalCount = app.countElements(withIdentifierPrefix: "TmuxWindowTab")
        takeScreenshot(app, name: "MultipleWindows-02-AllCreated")

        XCTAssertGreaterThanOrEqual(finalCount, initialCount + 3,
                                    "Should have at least 3 more tabs than initially")

        // Verify individual tabs are findable
        let tabs = app.elements(withIdentifierPrefix: "TmuxWindowTab")
        XCTAssertGreaterThanOrEqual(tabs.count, 4,
                                    "At least 4 window tabs should be visible")
    }
}
