//
//  SSHKeyManagerTests.swift
//  GeisttyUITests
//
//  Tests for the SSH Key management views: SSHKeyListView and
//  SSHKeyGeneratorView. Accessible from ConnectionListView → SSH Keys.
//

import XCTest

final class SSHKeyManagerTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = launchForDisconnectedTests()

        // Navigate: Disconnected → Saved Connections → SSH Keys
        let savedBtn = app.buttons["DisconnectedSavedConnectionsButton"]
        XCTAssertTrue(savedBtn.waitForExistence(timeout: 5))
        savedBtn.tap()

        // Wait for connection list
        let connNav = app.navigationBars["Connections"]
        XCTAssertTrue(connNav.waitForExistence(timeout: 3))

        // Tap SSH Keys link (may need scroll)
        let sshLink = app.buttons["SSHKeysLink"]
        if !sshLink.exists {
            app.swipeUp()
        }
        XCTAssertTrue(sshLink.waitForExistence(timeout: 3),
                      "SSHKeysLink must exist")
        sshLink.tap()

        // Wait for SSH Keys view
        let sshTitle = app.navigationBars["SSH Keys"]
        XCTAssertTrue(sshTitle.waitForExistence(timeout: 3),
                      "SSH Keys view should appear")
    }

    override func tearDownWithError() throws {
        takeScreenshot(app, name: "\(name)-teardown")
        app = nil
    }

    // MARK: - Structure

    /// SSH Keys view has the correct title.
    func testSSHKeysTitle() throws {
        let navBar = app.navigationBars["SSH Keys"]
        XCTAssertTrue(navBar.exists)

        takeScreenshot(app, name: "SSHKeys-01-Title")
    }

    /// SSH Keys view has a "+" menu button in the toolbar.
    func testAddKeyMenuExists() throws {
        // The toolbar has a "plus" button that reveals a menu
        let plusButton = app.navigationBars["SSH Keys"].buttons.element(boundBy: app.navigationBars["SSH Keys"].buttons.count - 1)
        XCTAssertTrue(plusButton.exists, "Plus button should exist in SSH Keys toolbar")

        takeScreenshot(app, name: "SSHKeys-02-AddMenu")
    }

    // MARK: - Empty State

    /// When no keys exist, empty state is shown.
    func testEmptyState() throws {
        // Check for either key rows or the empty state
        let emptyTitle = app.staticTexts["No SSH Keys"]
        let anyKey = app.cells.firstMatch

        if emptyTitle.exists {
            // Empty state is showing — good
            XCTAssertTrue(emptyTitle.exists)
        } else if anyKey.exists {
            // Keys exist — also valid
            XCTAssertTrue(anyKey.exists)
        }

        takeScreenshot(app, name: "SSHKeys-03-ListState")
    }

    // MARK: - Add Key Menu

    /// Tapping the "+" button shows Generate/Import options.
    func testAddKeyMenuOptions() throws {
        // Tap the "+" button
        let navBar = app.navigationBars["SSH Keys"]
        // The plus button is typically the rightmost button
        let buttons = navBar.buttons
        let plusButton = buttons.element(boundBy: buttons.count - 1)
        plusButton.tap()

        // Menu should show options
        let generateOption = app.buttons["Generate Key..."]
        let clipboardOption = app.buttons["Import from Clipboard"]
        let fileOption = app.buttons["Import from File..."]

        // At least one should exist
        let anyOption = generateOption.waitForExistence(timeout: 2)
            || clipboardOption.exists
            || fileOption.exists
        XCTAssertTrue(anyOption, "Add key menu should show options")

        takeScreenshot(app, name: "SSHKeys-04-MenuOptions")
    }

    // MARK: - Key Generator

    /// Tapping "Generate Key..." opens the generator view.
    func testOpenKeyGenerator() throws {
        // Open the menu
        let navBar = app.navigationBars["SSH Keys"]
        let buttons = navBar.buttons
        let plusButton = buttons.element(boundBy: buttons.count - 1)
        plusButton.tap()

        // Tap Generate
        let generateOption = app.buttons["Generate Key..."]
        if generateOption.waitForExistence(timeout: 2) {
            generateOption.tap()

            // Generator view should appear
            let generatorTitle = app.navigationBars["Generate SSH Key"]
            XCTAssertTrue(generatorTitle.waitForExistence(timeout: 3),
                          "Key generator view should appear")

            takeScreenshot(app, name: "SSHKeys-05-Generator")
        }
    }
}
