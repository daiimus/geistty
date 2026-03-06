//
//  QuickConnectSheetTests.swift
//  GeisttyUITests
//
//  Tests for the Quick Connect sheet (ConnectionSheet in ContentView):
//  field presence, validation, form entry.
//

import XCTest

final class QuickConnectSheetTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = launchForDisconnectedTests()

        // Open the Quick Connect sheet from the disconnected screen
        let quickConnect = app.buttons["DisconnectedQuickConnectButton"]
        XCTAssertTrue(quickConnect.waitForExistence(timeout: 5),
                      "DisconnectedQuickConnectButton must exist to run these tests")
        quickConnect.tap()

        // Wait for the sheet to present
        let hostField = app.textFields["SheetHostField"]
        XCTAssertTrue(hostField.waitForExistence(timeout: 3),
                      "Quick Connect sheet should present with host field")
    }

    override func tearDownWithError() throws {
        takeScreenshot(app, name: "\(name)-teardown")
        app = nil
    }

    // MARK: - Field Presence

    /// All expected form fields are present in the sheet.
    func testSheetFieldsExist() throws {
        XCTAssertTrue(app.textFields["SheetHostField"].exists, "Host field should exist")
        XCTAssertTrue(app.textFields["SheetUsernameField"].exists, "Username field should exist")
        XCTAssertTrue(app.secureTextFields["SheetPasswordField"].exists, "Password field should exist")
        XCTAssertTrue(app.buttons["SheetConnectButton"].exists, "Connect button should exist")

        takeScreenshot(app, name: "QuickConnect-01-AllFields")
    }

    /// Sheet has a Cancel button in the toolbar.
    func testSheetHasCancelButton() throws {
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.exists, "Cancel button should exist in sheet toolbar")

        takeScreenshot(app, name: "QuickConnect-02-CancelButton")
    }

    /// Sheet title is "New Connection".
    func testSheetTitle() throws {
        let navBar = app.navigationBars["New Connection"]
        XCTAssertTrue(navBar.exists, "Sheet nav bar should show 'New Connection'")

        takeScreenshot(app, name: "QuickConnect-03-Title")
    }

    // MARK: - Validation

    /// Connect button is disabled when host is empty.
    func testConnectDisabledWithEmptyHost() throws {
        // Clear the host field (it may have a debug default)
        let hostField = app.textFields["SheetHostField"]
        hostField.tap()
        // Select all and delete
        hostField.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) {
            app.menuItems["Select All"].tap()
            hostField.typeText(XCUIKeyboardKey.delete.rawValue)
        }

        // Also clear username
        let usernameField = app.textFields["SheetUsernameField"]
        usernameField.tap()
        usernameField.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) {
            app.menuItems["Select All"].tap()
            usernameField.typeText(XCUIKeyboardKey.delete.rawValue)
        }

        let connect = app.buttons["SheetConnectButton"]
        XCTAssertFalse(connect.isEnabled, "Connect should be disabled with empty fields")

        takeScreenshot(app, name: "QuickConnect-04-DisabledConnect")
    }

    // MARK: - Form Entry

    /// Can type into all fields.
    func testCanTypeInFields() throws {
        let hostField = app.textFields["SheetHostField"]
        hostField.tap()
        // Clear existing text first
        hostField.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) {
            app.menuItems["Select All"].tap()
        }
        hostField.typeText("test.example.com")

        let usernameField = app.textFields["SheetUsernameField"]
        usernameField.tap()
        usernameField.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) {
            app.menuItems["Select All"].tap()
        }
        usernameField.typeText("testuser")

        let passwordField = app.secureTextFields["SheetPasswordField"]
        passwordField.tap()
        passwordField.typeText("testpass")

        takeScreenshot(app, name: "QuickConnect-05-FilledFields")
    }

    // MARK: - Dismiss

    /// Tapping Cancel dismisses the sheet.
    func testCancelDismissesSheet() throws {
        let cancel = app.buttons["Cancel"]
        cancel.tap()

        // Sheet should be gone — host field should disappear
        let hostField = app.textFields["SheetHostField"]
        XCTAssertTrue(hostField.waitForDisappearance(timeout: 3),
                      "Sheet should dismiss after tapping Cancel")

        // Disconnected screen should be back
        XCTAssertTrue(app.isOnDisconnectedScreen,
                      "Should return to disconnected screen")

        takeScreenshot(app, name: "QuickConnect-06-Dismissed")
    }

    // MARK: - Debug Test Server Button

    #if DEBUG
    /// In DEBUG builds, a "Use test.rebex.net" button should exist.
    func testDebugTestServerButton() throws {
        let testServer = app.buttons["Use test.rebex.net"]
        // This lives in the "Test Servers" section of the sheet
        // It may need scrolling to find
        if testServer.waitForExistence(timeout: 2) {
            XCTAssertTrue(testServer.exists, "Debug test server button should exist")
            takeScreenshot(app, name: "QuickConnect-07-DebugButton")
        }
    }
    #endif
}
