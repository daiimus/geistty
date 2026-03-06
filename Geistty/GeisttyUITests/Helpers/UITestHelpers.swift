//
//  UITestHelpers.swift
//  GeisttyUITests
//
//  Shared helpers for all UI tests: screenshot capture, element waits,
//  accessibility-identifier queries, and connection utilities.
//

import os
import XCTest

private let logger = Logger(subsystem: "com.geistty.uitests", category: "Helpers")

// MARK: - Screenshot Helpers

extension XCTestCase {

    /// Capture a screenshot and attach it to the test results.
    /// The attachment is kept forever so the agent can inspect xcresult bundles.
    func takeScreenshot(_ app: XCUIApplication, name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        logger.debug("Screenshot: \(name)")
    }

    /// Capture the full device screenshot (not just the app window).
    func takeDeviceScreenshot(name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        logger.debug("Device screenshot: \(name)")
    }
}

// MARK: - Element Wait Helpers

extension XCUIElement {

    /// Wait for the element to exist, then return it. Returns `nil` on timeout.
    @discardableResult
    func waitForExistenceAndReturn(timeout: TimeInterval = 5) -> XCUIElement? {
        guard waitForExistence(timeout: timeout) else { return nil }
        return self
    }

    /// Wait for the element to become hittable (visible and interactable).
    func waitUntilHittable(timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "isHittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        return result == .completed
    }

    /// Wait for the element to disappear.
    func waitForDisappearance(timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        return result == .completed
    }
}

// MARK: - Accessibility-Identifier Queries

extension XCUIApplication {

    /// Find an element by accessibility identifier across common element types.
    /// Checks buttons, text fields, secure text fields, static texts, other elements,
    /// switches, sliders, and links — in that order.
    func element(withIdentifier id: String) -> XCUIElement? {
        let queries: [XCUIElementQuery] = [
            buttons,
            textFields,
            secureTextFields,
            staticTexts,
            otherElements,
            switches,
            sliders,
            links,
            searchFields,
            segmentedControls,
        ]
        for query in queries {
            let el = query[id]
            if el.exists { return el }
        }
        return nil
    }

    /// Find all elements whose accessibility identifier starts with the given prefix.
    /// Searches `otherElements` by default; pass a specific query for narrower scope.
    func elements(withIdentifierPrefix prefix: String,
                  in query: XCUIElementQuery? = nil) -> [XCUIElement] {
        let target = query ?? otherElements
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", prefix)
        let matches = target.matching(predicate)
        return (0..<matches.count).map { matches.element(boundBy: $0) }
    }

    /// Count elements whose identifier matches a prefix (useful for pane/surface counts).
    func countElements(withIdentifierPrefix prefix: String,
                       in query: XCUIElementQuery? = nil) -> Int {
        let target = query ?? otherElements
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", prefix)
        return target.matching(predicate).count
    }
}

// MARK: - Terminal Detection

extension XCUIApplication {

    /// Returns `true` if any `TerminalSurface-*` element exists.
    var isInTerminalView: Bool {
        let surfaces = otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH 'TerminalSurface'")
        )
        return surfaces.count > 0
    }

    /// Returns `true` if we are on the disconnected/connection screen.
    var isOnDisconnectedScreen: Bool {
        // Check for the disconnected title or quick-connect button
        return staticTexts["DisconnectedTitle"].exists
            || buttons["DisconnectedQuickConnectButton"].exists
    }

    /// Returns `true` if we are showing the error view.
    var isOnErrorScreen: Bool {
        return staticTexts["ErrorTitle"].exists
    }

    /// Wait until the terminal surface appears (connection succeeded).
    func waitForTerminal(timeout: TimeInterval = 30) -> Bool {
        let surface = otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH 'TerminalSurface'")
        ).firstMatch
        return surface.waitForExistence(timeout: timeout)
    }

    /// Wait until the disconnected screen appears.
    func waitForDisconnectedScreen(timeout: TimeInterval = 10) -> Bool {
        return staticTexts["DisconnectedTitle"].waitForExistence(timeout: timeout)
            || buttons["DisconnectedQuickConnectButton"].waitForExistence(timeout: timeout)
    }
}

// MARK: - Pane & Surface Helpers

extension XCUIApplication {

    /// Count visible terminal panes (TerminalPane-* identifiers).
    var terminalPaneCount: Int {
        countElements(withIdentifierPrefix: "TerminalPane")
    }

    /// Count visible terminal surfaces (TerminalSurface-* identifiers).
    var terminalSurfaceCount: Int {
        countElements(withIdentifierPrefix: "TerminalSurface")
    }
}

// MARK: - UI Hierarchy Logging

extension XCTestCase {

    /// Dump identifiable UI elements to the log for debugging.
    func logVisibleElements(_ app: XCUIApplication, label: String = "UI Hierarchy") {
        logger.debug("\(label):")
        logger.debug("  Windows: \(app.windows.count)")

        let elementTypes: [(String, XCUIElementQuery)] = [
            ("Buttons", app.buttons),
            ("TextFields", app.textFields),
            ("SecureTextFields", app.secureTextFields),
            ("StaticTexts", app.staticTexts),
            ("Switches", app.switches),
            ("Sliders", app.sliders),
            ("OtherElements", app.otherElements),
        ]

        for (typeName, query) in elementTypes {
            let identified = query.allElementsBoundByIndex.filter { !$0.identifier.isEmpty }
            if !identified.isEmpty {
                logger.debug("  \(typeName):")
                for el in identified {
                    logger.debug("    - \(el.identifier): frame=\(String(describing: el.frame))")
                }
            }
        }
    }
}

// MARK: - Connection Helpers

extension XCTestCase {

    /// Launch the app configured for disconnected-state testing (no auto-connect).
    func launchForDisconnectedTests() -> XCUIApplication {
        let app = XCUIApplication()
        // Do NOT pass --ui-testing so the app stays on the disconnected screen
        app.launch()
        return app
    }

    /// Launch the app configured for connected-state testing using TestConfig.
    /// Passes `--ui-testing` with `--test-host/port/user/key` arguments.
    func launchForConnectedTests() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--test-host", TestConfig.sshHost,
            "--test-port", String(TestConfig.sshPort),
            "--test-user", TestConfig.sshUsername,
            "--test-key", TestConfig.keyFilePath,
        ]
        app.launch()
        return app
    }
}

// MARK: - Keyboard Shortcut Helpers

extension XCUIApplication {

    /// Send Cmd+D (horizontal split).
    func splitHorizontal() {
        typeKey("d", modifierFlags: .command)
    }

    /// Send Cmd+Shift+D (vertical split).
    func splitVertical() {
        typeKey("d", modifierFlags: [.command, .shift])
    }

    /// Send Cmd+] (next pane).
    func focusNextPane() {
        typeKey("]", modifierFlags: .command)
    }

    /// Send Cmd+[ (previous pane).
    func focusPreviousPane() {
        typeKey("[", modifierFlags: .command)
    }

    /// Send Cmd+F (open search).
    func openSearch() {
        typeKey("f", modifierFlags: .command)
    }

    /// Send Cmd+Shift+P (command palette).
    func openCommandPalette() {
        typeKey("p", modifierFlags: [.command, .shift])
    }

    /// Send Cmd+W (close pane/window).
    func closeCurrentPane() {
        typeKey("w", modifierFlags: .command)
    }

    /// Send Cmd+T (new tab/window).
    func newWindow() {
        typeKey("t", modifierFlags: .command)
    }

    /// Send Cmd++ (increase font size).
    func increaseFontSize() {
        typeKey("+", modifierFlags: .command)
    }

    /// Send Cmd+- (decrease font size).
    func decreaseFontSize() {
        typeKey("-", modifierFlags: .command)
    }

    /// Send Cmd+0 (reset font size).
    func resetFontSize() {
        typeKey("0", modifierFlags: .command)
    }

    /// Send Cmd+Shift+[ (previous tab/window).
    func previousWindow() {
        typeKey("[", modifierFlags: [.command, .shift])
    }

    /// Send Cmd+Shift+] (next tab/window).
    func nextWindow() {
        typeKey("]", modifierFlags: [.command, .shift])
    }
}
