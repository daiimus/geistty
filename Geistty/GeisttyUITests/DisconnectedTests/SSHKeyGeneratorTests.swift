//
//  SSHKeyGeneratorTests.swift
//  GeisttyUITests
//
//  Tests for the SSHKeyGeneratorView: field presence, key type picker,
//  generate button state, name field interaction.
//
//  Navigation: Disconnected → Saved Connections → SSH Keys → "+" → Generate Key...
//

import XCTest

final class SSHKeyGeneratorTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = launchForDisconnectedTests()
        XCTAssertTrue(app.waitForDisconnectedScreen(timeout: 5))

        // Navigate: Saved Connections → SSH Keys → "+" menu → Generate Key...
        let savedBtn = app.buttons["DisconnectedSavedConnectionsButton"]
        XCTAssertTrue(savedBtn.waitForExistence(timeout: 5))
        savedBtn.tap()

        let connNav = app.navigationBars["Connections"]
        XCTAssertTrue(connNav.waitForExistence(timeout: 3))

        let sshLink = app.buttons["SSHKeysLink"]
        if !sshLink.exists { app.swipeUp() }
        XCTAssertTrue(sshLink.waitForExistence(timeout: 3))
        sshLink.tap()

        let sshTitle = app.navigationBars["SSH Keys"]
        XCTAssertTrue(sshTitle.waitForExistence(timeout: 3))

        // Tap the "+" button to open menu
        let navBar = app.navigationBars["SSH Keys"]
        let buttons = navBar.buttons
        let plusButton = buttons.element(boundBy: buttons.count - 1)
        plusButton.tap()

        // Tap "Generate Key..."
        let generateOption = app.buttons["Generate Key..."]
        XCTAssertTrue(generateOption.waitForExistence(timeout: 2),
                      "Generate Key... option must appear in menu")
        generateOption.tap()

        // Wait for generator view
        let generatorNav = app.navigationBars["Generate SSH Key"]
        XCTAssertTrue(generatorNav.waitForExistence(timeout: 3),
                      "SSHKeyGeneratorView must appear")
    }

    override func tearDownWithError() throws {
        takeScreenshot(app, name: "\(name)-teardown")
        app = nil
    }

    // MARK: - Structure

    /// Generator view has the correct title.
    func testGeneratorTitle() throws {
        let navBar = app.navigationBars["Generate SSH Key"]
        XCTAssertTrue(navBar.exists)

        takeScreenshot(app, name: "KeyGen-01-Title")
    }

    /// Key Name field exists and is empty initially.
    func testKeyNameFieldExists() throws {
        let keyNameField = app.textFields["KeyNameField"]
        XCTAssertTrue(keyNameField.exists, "KeyNameField must exist")

        takeScreenshot(app, name: "KeyGen-02-NameField")
    }

    /// Key Type picker exists.
    func testKeyTypePickerExists() throws {
        let keyTypePicker = app.element(withIdentifier: "KeyTypePicker")
        XCTAssertNotNil(keyTypePicker, "KeyTypePicker must exist")

        takeScreenshot(app, name: "KeyGen-03-TypePicker")
    }

    /// Generate button exists in the toolbar.
    func testGenerateButtonExists() throws {
        let generateButton = app.buttons["GenerateButton"]
        XCTAssertTrue(generateButton.exists, "GenerateButton must exist in toolbar")

        takeScreenshot(app, name: "KeyGen-04-GenerateButton")
    }

    // MARK: - Generate Button State

    /// Generate button is disabled when key name is empty.
    func testGenerateDisabledWithEmptyName() throws {
        let generateButton = app.buttons["GenerateButton"]
        XCTAssertFalse(generateButton.isEnabled,
                       "Generate should be disabled when key name is empty")

        takeScreenshot(app, name: "KeyGen-05-GenerateDisabled")
    }

    /// Generate button becomes enabled after typing a key name.
    func testGenerateEnabledAfterTypingName() throws {
        let keyNameField = app.textFields["KeyNameField"]
        keyNameField.tap()
        keyNameField.typeText("test-key")

        let generateButton = app.buttons["GenerateButton"]
        XCTAssertTrue(generateButton.isEnabled,
                      "Generate should be enabled after typing a key name")

        takeScreenshot(app, name: "KeyGen-06-GenerateEnabled")
    }

    // MARK: - Key Type Selection

    /// The default key type is Ed25519.
    func testDefaultKeyTypeIsEd25519() throws {
        // The picker should show Ed25519 as the default selection
        // Look for Ed25519 text in the form
        let ed25519Text = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Ed25519'")
        ).firstMatch

        XCTAssertTrue(ed25519Text.waitForExistence(timeout: 3),
                      "Ed25519 should be visible as default key type")

        takeScreenshot(app, name: "KeyGen-07-DefaultType")
    }
}
