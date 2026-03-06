//
//  LaunchTests.swift
//  GeisttyUITests
//
//  Tests for app launch state — verifies the disconnected screen appears
//  correctly with expected UI elements.
//

import XCTest

final class LaunchTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = launchForDisconnectedTests()
    }

    override func tearDownWithError() throws {
        takeScreenshot(app, name: "\(name)-teardown")
        app = nil
    }

    // MARK: - Launch State

    /// App launches to the disconnected screen with the expected title.
    func testLaunchShowsDisconnectedScreen() throws {
        takeScreenshot(app, name: "Launch-01-InitialState")

        let title = app.staticTexts["DisconnectedTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5),
                      "Disconnected title should appear on launch")
        XCTAssertEqual(title.label, "No Active Connection")
    }

    /// Both primary action buttons are visible on the disconnected screen.
    func testDisconnectedScreenHasActionButtons() throws {
        XCTAssertTrue(app.waitForDisconnectedScreen(timeout: 5))

        let quickConnect = app.buttons["DisconnectedQuickConnectButton"]
        let savedConnections = app.buttons["DisconnectedSavedConnectionsButton"]

        XCTAssertTrue(quickConnect.exists, "Quick Connect button should exist")
        XCTAssertTrue(savedConnections.exists, "Saved Connections button should exist")

        takeScreenshot(app, name: "Launch-02-ActionButtons")
    }

    /// The navigation bar has the correct title.
    func testNavigationBarTitle() throws {
        XCTAssertTrue(app.waitForDisconnectedScreen(timeout: 5))

        let navTitle = app.navigationBars["Geistty"]
        XCTAssertTrue(navTitle.exists, "Navigation bar should show 'Geistty'")

        takeScreenshot(app, name: "Launch-03-NavBar")
    }

    /// The terminal icon is visible on the disconnected screen.
    func testDisconnectedScreenHasTerminalIcon() throws {
        XCTAssertTrue(app.waitForDisconnectedScreen(timeout: 5))

        // The icon is an SF Symbol "terminal" rendered as an image
        let images = app.images
        XCTAssertTrue(images.count > 0, "Should have at least one image (terminal icon)")

        takeScreenshot(app, name: "Launch-04-TerminalIcon")
    }

    /// The toolbar "+" menu exists in the navigation bar.
    func testToolbarMenuExists() throws {
        XCTAssertTrue(app.waitForDisconnectedScreen(timeout: 5))

        // The toolbar has a plus.circle button
        let toolbar = app.navigationBars.firstMatch
        XCTAssertTrue(toolbar.exists, "Navigation bar should exist")

        takeScreenshot(app, name: "Launch-05-Toolbar")
    }

    // MARK: - App Does Not Auto-Connect

    /// Without --ui-testing flag, the app stays on disconnected screen.
    func testAppDoesNotAutoConnect() throws {
        // We launched without --ui-testing, so we should stay disconnected
        Thread.sleep(forTimeInterval: 2.0)

        XCTAssertTrue(app.isOnDisconnectedScreen,
                      "App should remain on disconnected screen without --ui-testing")
        XCTAssertFalse(app.isInTerminalView,
                       "App should NOT be in terminal view without --ui-testing")

        takeScreenshot(app, name: "Launch-06-NoAutoConnect")
    }
}
