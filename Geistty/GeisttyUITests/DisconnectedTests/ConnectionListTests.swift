//
//  ConnectionListTests.swift
//  GeisttyUITests
//
//  Tests for the ConnectionListView modal: sections, search, quick connect,
//  SSH keys link, and the add-connection button.
//

import XCTest

final class ConnectionListTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = launchForDisconnectedTests()

        // Open Saved Connections from the disconnected screen
        let savedBtn = app.buttons["DisconnectedSavedConnectionsButton"]
        XCTAssertTrue(savedBtn.waitForExistence(timeout: 5),
                      "Saved Connections button must exist")
        savedBtn.tap()

        // Wait for connection list to appear
        let navBar = app.navigationBars["Connections"]
        XCTAssertTrue(navBar.waitForExistence(timeout: 3),
                      "ConnectionListView should present with 'Connections' title")
    }

    override func tearDownWithError() throws {
        takeScreenshot(app, name: "\(name)-teardown")
        app = nil
    }

    // MARK: - Structure

    /// The connection list has the expected nav bar title.
    func testConnectionListTitle() throws {
        let navBar = app.navigationBars["Connections"]
        XCTAssertTrue(navBar.exists)

        takeScreenshot(app, name: "ConnList-01-Title")
    }

    /// Quick Connect button exists in the list.
    func testQuickConnectButtonExists() throws {
        let qcButton = app.buttons["QuickConnectButton"]
        XCTAssertTrue(qcButton.waitForExistence(timeout: 3),
                      "QuickConnectButton should exist in connection list")

        takeScreenshot(app, name: "ConnList-02-QuickConnect")
    }

    /// Add Connection ("+") button exists in the toolbar.
    func testAddConnectionButtonExists() throws {
        let addButton = app.buttons["AddConnectionButton"]
        XCTAssertTrue(addButton.exists, "AddConnectionButton should exist in toolbar")

        takeScreenshot(app, name: "ConnList-03-AddButton")
    }

    /// SSH Keys link exists.
    func testSSHKeysLinkExists() throws {
        // May need to scroll down to find it
        let sshLink = app.buttons["SSHKeysLink"]
        if !sshLink.exists {
            // Try scrolling down in the list
            app.swipeUp()
        }
        XCTAssertTrue(sshLink.waitForExistence(timeout: 3),
                      "SSHKeysLink should exist in connection list")

        takeScreenshot(app, name: "ConnList-04-SSHKeysLink")
    }

    // MARK: - Quick Connect Flow

    /// Tapping Quick Connect opens the QuickConnectView sheet.
    func testQuickConnectOpensSheet() throws {
        let qcButton = app.buttons["QuickConnectButton"]
        qcButton.tap()

        // QuickConnectView should appear with host/username fields
        let hostField = app.textFields["HostField"]
        XCTAssertTrue(hostField.waitForExistence(timeout: 3),
                      "QuickConnectView should show HostField")

        let usernameField = app.textFields["UsernameField"]
        XCTAssertTrue(usernameField.exists, "QuickConnectView should show UsernameField")

        let connectButton = app.buttons["ConnectButton"]
        XCTAssertTrue(connectButton.exists, "QuickConnectView should show ConnectButton")

        takeScreenshot(app, name: "ConnList-05-QuickConnectSheet")
    }

    // MARK: - Add Connection Flow

    /// Tapping "+" opens the ConnectionEditorView.
    func testAddConnectionOpensEditor() throws {
        let addButton = app.buttons["AddConnectionButton"]
        addButton.tap()

        // ConnectionEditorView should appear
        let editorNav = app.navigationBars["New Connection"]
        XCTAssertTrue(editorNav.waitForExistence(timeout: 3),
                      "Connection editor should present with 'New Connection' title")

        // Check for editor fields
        let nameField = app.textFields["EditorNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 2),
                      "Editor should show name field")

        takeScreenshot(app, name: "ConnList-06-EditorOpened")
    }

    // MARK: - SSH Keys Navigation

    /// Tapping SSH Keys link navigates to SSHKeyListView.
    func testSSHKeysLinkNavigation() throws {
        let sshLink = app.buttons["SSHKeysLink"]
        if !sshLink.exists {
            app.swipeUp()
        }
        XCTAssertTrue(sshLink.waitForExistence(timeout: 3))
        sshLink.tap()

        // Should navigate to SSH Keys view
        let sshTitle = app.navigationBars["SSH Keys"]
        XCTAssertTrue(sshTitle.waitForExistence(timeout: 3),
                      "Should navigate to SSH Keys view")

        takeScreenshot(app, name: "ConnList-07-SSHKeysView")
    }

    // MARK: - All Connections Section

    /// The "All Connections" section exists (may be empty or populated).
    func testAllConnectionsSectionExists() throws {
        // Look for either connection rows or the empty state
        let emptyState = app.staticTexts["No Connections"]
        let anyRow = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'ConnectionRow-'")
        ).firstMatch

        let hasContent = emptyState.exists || anyRow.exists
        XCTAssertTrue(hasContent,
                      "Should show either connection rows or empty state")

        takeScreenshot(app, name: "ConnList-08-AllConnections")
    }
}
