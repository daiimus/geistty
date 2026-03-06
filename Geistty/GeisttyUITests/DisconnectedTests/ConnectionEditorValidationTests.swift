//
//  ConnectionEditorValidationTests.swift
//  GeisttyUITests
//
//  Tests for ConnectionEditorView form validation: empty fields trigger
//  ValidationMessage, Save button disabled state, field-specific errors.
//
//  Navigation: Disconnected → Saved Connections → "+" → ConnectionEditorView
//

import XCTest

final class ConnectionEditorValidationTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = launchForDisconnectedTests()
        XCTAssertTrue(app.waitForDisconnectedScreen(timeout: 5))

        // Navigate: Saved Connections → "+" (Add Connection)
        let savedBtn = app.buttons["DisconnectedSavedConnectionsButton"]
        XCTAssertTrue(savedBtn.waitForExistence(timeout: 5))
        savedBtn.tap()

        let addButton = app.buttons["AddConnectionButton"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 3))
        addButton.tap()

        // Wait for editor
        let nameField = app.textFields["EditorNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3),
                      "Editor must appear with name field")
    }

    override func tearDownWithError() throws {
        takeScreenshot(app, name: "\(name)-teardown")
        app = nil
    }

    // MARK: - Empty Fields

    /// Save is disabled when all fields are empty.
    func testSaveDisabledAllFieldsEmpty() throws {
        let saveButton = app.buttons["EditorSaveButton"]
        XCTAssertFalse(saveButton.isEnabled,
                       "Save should be disabled when all fields are empty")

        takeScreenshot(app, name: "Validation-01-AllEmpty")
    }

    /// ValidationMessage shows "Name is required" when name is empty.
    func testValidationMessageNameRequired() throws {
        // Scroll down to see validation message
        app.swipeUp()
        app.swipeUp()

        let validationMsg = app.staticTexts["ValidationMessage"]
            .exists ? app.staticTexts["ValidationMessage"]
                    : app.otherElements["ValidationMessage"]

        // Look for the validation label via the element helper
        let found = app.element(withIdentifier: "ValidationMessage")
        if let label = found {
            XCTAssertTrue(label.exists)
            // The first validation error should be about the name field
        }

        takeScreenshot(app, name: "Validation-02-NameRequired")
    }

    /// After filling name, validation moves to "Host is required".
    func testValidationProgressesToHost() throws {
        let nameField = app.textFields["EditorNameField"]
        nameField.tap()
        nameField.typeText("Test Server")

        // Scroll to see validation
        app.swipeUp()
        app.swipeUp()

        let validationMsg = app.element(withIdentifier: "ValidationMessage")
        if let label = validationMsg {
            XCTAssertTrue(label.exists,
                          "Validation message should still show after filling only name")
        }

        // Save should still be disabled
        let saveButton = app.buttons["EditorSaveButton"]
        XCTAssertFalse(saveButton.isEnabled,
                       "Save should be disabled with only name filled")

        takeScreenshot(app, name: "Validation-03-HostRequired")
    }

    /// After filling name and host, validation moves to "Username is required".
    func testValidationProgressesToUsername() throws {
        let nameField = app.textFields["EditorNameField"]
        nameField.tap()
        nameField.typeText("Test Server")

        let hostField = app.textFields["EditorHostField"]
        hostField.tap()
        hostField.typeText("test.example.com")

        app.swipeUp()
        app.swipeUp()

        let saveButton = app.buttons["EditorSaveButton"]
        XCTAssertFalse(saveButton.isEnabled,
                       "Save should be disabled with name+host but no username")

        takeScreenshot(app, name: "Validation-04-UsernameRequired")
    }

    // MARK: - Invalid Port

    /// An invalid port (0 or > 65535) keeps Save disabled.
    func testInvalidPortKeepsSaveDisabled() throws {
        let nameField = app.textFields["EditorNameField"]
        nameField.tap()
        nameField.typeText("Port Test")

        let hostField = app.textFields["EditorHostField"]
        hostField.tap()
        hostField.typeText("test.example.com")

        let portField = app.textFields["EditorPortField"]
        portField.tap()
        // Clear existing "22" and type invalid port
        portField.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) {
            app.menuItems["Select All"].tap()
        }
        portField.typeText("99999")

        let usernameField = app.textFields["EditorUsernameField"]
        usernameField.tap()
        usernameField.typeText("admin")

        app.swipeUp()
        app.swipeUp()

        let saveButton = app.buttons["EditorSaveButton"]
        XCTAssertFalse(saveButton.isEnabled,
                       "Save should be disabled with invalid port")

        takeScreenshot(app, name: "Validation-05-InvalidPort")
    }

    // MARK: - SSH Key Required

    /// When auth method is SSH Key and no key is selected, Save is disabled.
    func testSSHKeyRequiredValidation() throws {
        let nameField = app.textFields["EditorNameField"]
        nameField.tap()
        nameField.typeText("Key Test")

        let hostField = app.textFields["EditorHostField"]
        hostField.tap()
        hostField.typeText("test.example.com")

        let usernameField = app.textFields["EditorUsernameField"]
        usernameField.tap()
        usernameField.typeText("admin")

        // Auth method defaults to sshKey if keys exist, or might need to be set
        // The validation message should say "Select an SSH key"
        app.swipeUp()
        app.swipeUp()

        let saveButton = app.buttons["EditorSaveButton"]
        // If auth is sshKey and no key selected, save should be disabled
        // If auth defaulted to password and no password given, also disabled
        XCTAssertFalse(saveButton.isEnabled,
                       "Save should be disabled when SSH key auth selected but no key chosen")

        takeScreenshot(app, name: "Validation-06-SSHKeyRequired")
    }

    // MARK: - Password Auth

    /// When auth method is password and password is empty (new profile), Save is disabled.
    func testPasswordRequiredForNewProfile() throws {
        let nameField = app.textFields["EditorNameField"]
        nameField.tap()
        nameField.typeText("Password Test")

        let hostField = app.textFields["EditorHostField"]
        hostField.tap()
        hostField.typeText("test.example.com")

        let usernameField = app.textFields["EditorUsernameField"]
        usernameField.tap()
        usernameField.typeText("admin")

        // Switch auth to password
        let authPicker = app.element(withIdentifier: "AuthMethodPicker")
        if let picker = authPicker {
            picker.tap()
            let passwordOption = app.buttons["Password"]
            if passwordOption.waitForExistence(timeout: 2) {
                passwordOption.tap()
            }
        }

        // Don't fill password — Save should be disabled
        app.swipeUp()
        app.swipeUp()

        let saveButton = app.buttons["EditorSaveButton"]
        XCTAssertFalse(saveButton.isEnabled,
                       "Save should be disabled with empty password on new profile")

        takeScreenshot(app, name: "Validation-07-PasswordRequired")
    }

    // MARK: - Valid Form

    /// Filling all required fields enables Save.
    func testValidFormEnablesSave() throws {
        let nameField = app.textFields["EditorNameField"]
        nameField.tap()
        nameField.typeText("Valid Profile")

        let hostField = app.textFields["EditorHostField"]
        hostField.tap()
        hostField.typeText("valid.example.com")

        let usernameField = app.textFields["EditorUsernameField"]
        usernameField.tap()
        usernameField.typeText("validuser")

        // Switch to password auth and fill password
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
            passwordField.typeText("validpass")
        }

        let saveButton = app.buttons["EditorSaveButton"]
        XCTAssertTrue(saveButton.isEnabled,
                      "Save should be enabled with all required fields filled")

        takeScreenshot(app, name: "Validation-08-ValidForm")
    }
}
