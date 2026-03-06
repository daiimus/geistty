//
//  SearchTests.swift
//  GeisttyUITests
//
//  Tests for the terminal search overlay — opening, typing queries,
//  navigating matches, and dismissing the search bar.
//

import XCTest

final class SearchTests: XCTestCase {

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

    // MARK: - Open / Close

    /// Cmd+F opens the search overlay with the search text field visible.
    func testOpenSearchOverlay() throws {
        takeScreenshot(app, name: "OpenSearch-01-Before")

        app.openSearch()
        Thread.sleep(forTimeInterval: 0.5)

        let searchField = app.textFields["SearchTextField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3),
                      "SearchTextField should appear after Cmd+F")

        takeScreenshot(app, name: "OpenSearch-02-Opened")
    }

    /// Typing into the search text field enters text.
    func testSearchTextFieldAcceptsInput() throws {
        app.openSearch()
        Thread.sleep(forTimeInterval: 0.5)

        let searchField = app.textFields["SearchTextField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3),
                      "SearchTextField should exist")

        searchField.tap()
        searchField.typeText("hello")
        Thread.sleep(forTimeInterval: 0.3)

        takeScreenshot(app, name: "SearchInput-01-Typed")

        let fieldValue = searchField.value as? String ?? ""
        XCTAssertFalse(fieldValue.isEmpty,
                       "Search field should contain typed text")
    }

    /// Previous and Next navigation buttons exist when search is open.
    func testSearchNavigationButtonsExist() throws {
        app.openSearch()
        Thread.sleep(forTimeInterval: 0.5)

        let searchField = app.textFields["SearchTextField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))

        let previousButton = app.buttons["SearchPreviousButton"]
        let nextButton = app.buttons["SearchNextButton"]

        XCTAssertTrue(previousButton.waitForExistence(timeout: 2),
                      "SearchPreviousButton should exist")
        XCTAssertTrue(nextButton.waitForExistence(timeout: 2),
                      "SearchNextButton should exist")

        takeScreenshot(app, name: "SearchNav-01-Buttons")
    }

    /// Close button exists and tapping it dismisses the search overlay.
    func testSearchCloseButton() throws {
        app.openSearch()
        Thread.sleep(forTimeInterval: 0.5)

        let searchField = app.textFields["SearchTextField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))

        let closeButton = app.buttons["SearchCloseButton"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 2),
                      "SearchCloseButton should exist")

        takeScreenshot(app, name: "SearchClose-01-BeforeClose")

        closeButton.tap()
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(searchField.waitForDisappearance(timeout: 3),
                      "SearchTextField should disappear after tapping close")

        takeScreenshot(app, name: "SearchClose-02-AfterClose")
    }

    /// Open search, type a query, close, and verify the overlay is dismissed.
    func testSearchAndClose() throws {
        app.openSearch()
        Thread.sleep(forTimeInterval: 0.5)

        let searchField = app.textFields["SearchTextField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))

        searchField.tap()
        searchField.typeText("test query")
        Thread.sleep(forTimeInterval: 0.3)

        takeScreenshot(app, name: "SearchAndClose-01-WithQuery")

        let closeButton = app.buttons["SearchCloseButton"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 2))
        closeButton.tap()
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(searchField.waitForDisappearance(timeout: 3),
                      "Search overlay should be dismissed after close")

        takeScreenshot(app, name: "SearchAndClose-02-Dismissed")
    }

    // MARK: - Search Content

    /// Echo a known string, then search for it.
    func testSearchForExistingText() throws {
        // Type a command that produces searchable output
        app.typeText("echo SEARCHABLE_TEXT\n")
        Thread.sleep(forTimeInterval: 1.0)

        takeScreenshot(app, name: "SearchExisting-01-EchoOutput")

        app.openSearch()
        Thread.sleep(forTimeInterval: 0.5)

        let searchField = app.textFields["SearchTextField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))

        searchField.tap()
        searchField.typeText("SEARCHABLE")
        Thread.sleep(forTimeInterval: 0.5)

        takeScreenshot(app, name: "SearchExisting-02-SearchQuery")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should remain active while searching")
    }

    // MARK: - Navigation

    /// Open search, type text, and tap the Previous button.
    func testSearchPreviousButton() throws {
        app.openSearch()
        Thread.sleep(forTimeInterval: 0.5)

        let searchField = app.textFields["SearchTextField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))

        searchField.tap()
        searchField.typeText("search term")
        Thread.sleep(forTimeInterval: 0.3)

        let previousButton = app.buttons["SearchPreviousButton"]
        XCTAssertTrue(previousButton.waitForExistence(timeout: 2),
                      "SearchPreviousButton should exist")

        previousButton.tap()
        Thread.sleep(forTimeInterval: 0.3)

        takeScreenshot(app, name: "SearchPrev-01-AfterTap")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should remain active after tapping previous")
    }

    /// Open search, type text, and tap the Next button.
    func testSearchNextButton() throws {
        app.openSearch()
        Thread.sleep(forTimeInterval: 0.5)

        let searchField = app.textFields["SearchTextField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))

        searchField.tap()
        searchField.typeText("search term")
        Thread.sleep(forTimeInterval: 0.3)

        let nextButton = app.buttons["SearchNextButton"]
        XCTAssertTrue(nextButton.waitForExistence(timeout: 2),
                      "SearchNextButton should exist")

        nextButton.tap()
        Thread.sleep(forTimeInterval: 0.3)

        takeScreenshot(app, name: "SearchNext-01-AfterTap")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should remain active after tapping next")
    }

    // MARK: - Dismiss via Escape

    /// Pressing Escape dismisses the search overlay.
    func testEscDismissesSearch() throws {
        app.openSearch()
        Thread.sleep(forTimeInterval: 0.5)

        let searchField = app.textFields["SearchTextField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3),
                      "SearchTextField should appear after Cmd+F")

        takeScreenshot(app, name: "EscDismiss-01-SearchOpen")

        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(searchField.waitForDisappearance(timeout: 3),
                      "Search overlay should dismiss after pressing Escape")

        takeScreenshot(app, name: "EscDismiss-02-Dismissed")
    }
}
