//
//  ProfileCRUDTests.swift
//  GeisttyUITests
//
//  Full CRUD lifecycle tests: Create a connection profile via the editor,
//  verify it appears in the connection list, edit it, duplicate it, delete it.
//
//  Navigation: Disconnected → Saved Connections → ConnectionListView
//

import XCTest

final class ProfileCRUDTests: XCTestCase {

    var app: XCUIApplication!

    /// Unique name per test run to avoid collisions.
    private let testProfileName = "CRUDTest-\(Int.random(in: 1000...9999))"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = launchForDisconnectedTests()
        XCTAssertTrue(app.waitForDisconnectedScreen(timeout: 5))

        // Navigate to Saved Connections
        let savedBtn = app.buttons["DisconnectedSavedConnectionsButton"]
        XCTAssertTrue(savedBtn.waitForExistence(timeout: 5))
        savedBtn.tap()

        let navBar = app.navigationBars["Connections"]
        XCTAssertTrue(navBar.waitForExistence(timeout: 3),
                      "ConnectionListView must appear")
    }

    override func tearDownWithError() throws {
        takeScreenshot(app, name: "\(name)-teardown")
        app = nil
    }

    // MARK: - Create

    /// Creating a profile via the editor makes it appear in the list.
    func testCreateProfile() throws {
        // Tap "+" to open editor
        let addButton = app.buttons["AddConnectionButton"]
        XCTAssertTrue(addButton.exists)
        addButton.tap()

        // Wait for editor
        let nameField = app.textFields["EditorNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3))

        // Fill required fields
        nameField.tap()
        nameField.typeText(testProfileName)

        let hostField = app.textFields["EditorHostField"]
        hostField.tap()
        hostField.typeText("crud-test.example.com")

        let usernameField = app.textFields["EditorUsernameField"]
        usernameField.tap()
        usernameField.typeText("testuser")

        // Switch auth to password so we can fill it (avoids SSH key requirement)
        let authPicker = app.element(withIdentifier: "AuthMethodPicker")
        if let picker = authPicker {
            picker.tap()
            // Select Password from the picker menu
            let passwordOption = app.buttons["Password"]
            if passwordOption.waitForExistence(timeout: 2) {
                passwordOption.tap()
            }
        }

        // Fill password
        let passwordField = app.secureTextFields["EditorPasswordField"]
        if passwordField.waitForExistence(timeout: 2) {
            passwordField.tap()
            passwordField.typeText("testpass123")
        }

        takeScreenshot(app, name: "ProfileCRUD-01-FilledEditor")

        // Save
        let saveButton = app.buttons["EditorSaveButton"]
        XCTAssertTrue(saveButton.isEnabled, "Save should be enabled with valid fields")
        saveButton.tap()

        // Editor should dismiss
        XCTAssertTrue(nameField.waitForDisappearance(timeout: 3),
                      "Editor should dismiss after save")

        // Verify profile appears in list
        let profileRow = app.buttons["ConnectionRow-\(testProfileName)"]
        XCTAssertTrue(profileRow.waitForExistence(timeout: 3),
                      "Created profile should appear in connection list")

        takeScreenshot(app, name: "ProfileCRUD-02-ProfileInList")
    }

    // MARK: - Create and Delete

    /// Creating and then deleting a profile removes it from the list.
    func testCreateAndDeleteProfile() throws {
        let deleteName = "DeleteMe-\(Int.random(in: 1000...9999))"

        // Create a profile
        let addButton = app.buttons["AddConnectionButton"]
        addButton.tap()

        let nameField = app.textFields["EditorNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3))
        nameField.tap()
        nameField.typeText(deleteName)

        let hostField = app.textFields["EditorHostField"]
        hostField.tap()
        hostField.typeText("delete.example.com")

        let usernameField = app.textFields["EditorUsernameField"]
        usernameField.tap()
        usernameField.typeText("deleteuser")

        // Switch to password auth
        let authPicker = app.element(withIdentifier: "AuthMethodPicker")
        if let picker = authPicker {
            picker.tap()
            let passwordOption = app.buttons["Password"]
            if passwordOption.waitForExistence(timeout: 2) {
                passwordOption.tap()
            }
        }

        let passwordField = app.secureTextFields["EditorPasswordField"]
        if passwordField.waitForExistence(timeout: 2) {
            passwordField.tap()
            passwordField.typeText("pass")
        }

        let saveButton = app.buttons["EditorSaveButton"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 2))
        saveButton.tap()

        // Verify it appeared
        let profileRow = app.buttons["ConnectionRow-\(deleteName)"]
        XCTAssertTrue(profileRow.waitForExistence(timeout: 3))

        takeScreenshot(app, name: "ProfileCRUD-03-BeforeDelete")

        // Delete via swipe
        profileRow.swipeLeft()

        let deleteButton = app.buttons["Delete"]
        if deleteButton.waitForExistence(timeout: 2) {
            deleteButton.tap()
        }

        // Profile should be gone
        XCTAssertTrue(profileRow.waitForDisappearance(timeout: 3),
                      "Deleted profile should disappear from list")

        takeScreenshot(app, name: "ProfileCRUD-04-AfterDelete")
    }

    // MARK: - Editor Validation Guard

    /// Save is disabled when only some required fields are filled.
    func testSaveDisabledWithPartialFields() throws {
        let addButton = app.buttons["AddConnectionButton"]
        addButton.tap()

        let nameField = app.textFields["EditorNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3))

        // Fill only name — host and username still empty
        nameField.tap()
        nameField.typeText("PartialProfile")

        let saveButton = app.buttons["EditorSaveButton"]
        XCTAssertFalse(saveButton.isEnabled,
                       "Save should be disabled with only name filled")

        takeScreenshot(app, name: "ProfileCRUD-05-SaveDisabled")
    }
}
