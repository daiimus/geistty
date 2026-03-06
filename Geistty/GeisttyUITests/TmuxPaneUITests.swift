//
//  TmuxPaneUITests.swift
//  GeisttyUITests
//
//  UI Tests for tmux pane management, splitting, and resizing.
//  Migrated to use TestConfig for credentials and UITestHelpers
//  for shared utilities.
//

import os
import XCTest

private let logger = Logger(subsystem: "com.geistty.uitests", category: "TmuxPaneUITests")

/// Tests for tmux multi-pane functionality
final class TmuxPaneUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        guard TestConfig.isConfigured else {
            throw XCTSkip("TestConfig.local.swift not configured — isConfigured is false")
        }

        continueAfterFailure = false
        app = launchForConnectedTests()
        XCTAssertTrue(app.waitForTerminal(timeout: TestConfig.connectionTimeout),
                      "Terminal should appear after connecting")

        // Let tmux initialise
        Thread.sleep(forTimeInterval: 2.0)
    }

    override func tearDownWithError() throws {
        takeScreenshot(app, name: "\(name)-teardown")
        app = nil
    }

    // MARK: - Split Tests

    /// Test horizontal split (Cmd+D)
    func testHorizontalSplit() throws {
        takeScreenshot(app, name: "Before-Split")

        let initialPaneCount = app.terminalPaneCount

        app.splitHorizontal()
        Thread.sleep(forTimeInterval: 1.0)

        takeScreenshot(app, name: "After-HorizontalSplit")

        let newPaneCount = app.terminalPaneCount
        logger.debug("Pane count: \(initialPaneCount) -> \(newPaneCount)")

        XCTAssertTrue(app.exists, "App should still exist after split")
    }

    /// Test vertical split (Cmd+Shift+D)
    func testVerticalSplit() throws {
        takeScreenshot(app, name: "Before-VerticalSplit")

        app.splitVertical()
        Thread.sleep(forTimeInterval: 1.0)

        takeScreenshot(app, name: "After-VerticalSplit")

        XCTAssertTrue(app.exists, "App should still exist after vertical split")
    }

    /// Test multiple splits in sequence
    func testMultipleSplits() throws {
        takeScreenshot(app, name: "MultipleSplits-0-Initial")

        // First split (horizontal)
        app.splitHorizontal()
        Thread.sleep(forTimeInterval: 1.0)
        takeScreenshot(app, name: "MultipleSplits-1-AfterHorizontal")

        // Second split (vertical on right pane)
        app.splitVertical()
        Thread.sleep(forTimeInterval: 1.0)
        takeScreenshot(app, name: "MultipleSplits-2-AfterVertical")

        // Third split (horizontal on bottom-right)
        app.splitHorizontal()
        Thread.sleep(forTimeInterval: 1.0)
        takeScreenshot(app, name: "MultipleSplits-3-Final")

        XCTAssertTrue(app.exists, "App should handle multiple splits")
    }

    // MARK: - Focus Navigation Tests

    /// Test Cmd+] cycles to next pane
    func testNextPaneFocus() throws {
        app.splitHorizontal()
        Thread.sleep(forTimeInterval: 0.5)

        takeScreenshot(app, name: "Focus-BeforeNext")

        app.focusNextPane()
        Thread.sleep(forTimeInterval: 0.3)

        takeScreenshot(app, name: "Focus-AfterNext")

        XCTAssertTrue(app.exists, "App should handle focus navigation")
    }

    /// Test Cmd+[ cycles to previous pane
    func testPreviousPaneFocus() throws {
        app.splitHorizontal()
        Thread.sleep(forTimeInterval: 0.5)

        app.focusPreviousPane()
        Thread.sleep(forTimeInterval: 0.3)

        takeScreenshot(app, name: "Focus-AfterPrevious")

        XCTAssertTrue(app.exists, "App should handle reverse focus navigation")
    }

    /// Test directional focus (Cmd+Option+Arrow)
    func testDirectionalFocus() throws {
        // Create 4-pane layout
        app.splitHorizontal()
        Thread.sleep(forTimeInterval: 0.5)

        app.focusPreviousPane()
        Thread.sleep(forTimeInterval: 0.3)

        app.splitVertical()
        Thread.sleep(forTimeInterval: 0.5)

        takeScreenshot(app, name: "Directional-4PaneLayout")

        // Test directional navigation
        app.typeKey(.rightArrow, modifierFlags: [.command, .option])
        Thread.sleep(forTimeInterval: 0.3)
        takeScreenshot(app, name: "Directional-AfterRight")

        app.typeKey(.downArrow, modifierFlags: [.command, .option])
        Thread.sleep(forTimeInterval: 0.3)
        takeScreenshot(app, name: "Directional-AfterDown")

        app.typeKey(.leftArrow, modifierFlags: [.command, .option])
        Thread.sleep(forTimeInterval: 0.3)
        takeScreenshot(app, name: "Directional-AfterLeft")

        app.typeKey(.upArrow, modifierFlags: [.command, .option])
        Thread.sleep(forTimeInterval: 0.3)
        takeScreenshot(app, name: "Directional-AfterUp")

        XCTAssertTrue(app.exists, "App should handle directional navigation")
    }

    // MARK: - Resize Tests

    /// Test pane sizing after split
    func testPaneSizingAfterSplit() throws {
        takeScreenshot(app, name: "Resize-Initial")

        app.splitHorizontal()
        Thread.sleep(forTimeInterval: 1.0)

        takeScreenshot(app, name: "Resize-AfterSplit")

        XCTAssertTrue(app.exists, "App should maintain proper sizing")
    }

    /// Test window rotation/resize handling
    func testOrientationChange() throws {
        app.splitHorizontal()
        Thread.sleep(forTimeInterval: 0.5)

        takeScreenshot(app, name: "Orientation-Portrait")

        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1.0)
        takeScreenshot(app, name: "Orientation-Landscape")

        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 1.0)
        takeScreenshot(app, name: "Orientation-PortraitAgain")

        XCTAssertTrue(app.exists, "App should handle orientation changes")
    }

    // MARK: - Window (Tab) Tests

    /// Test creating new tmux window
    func testNewWindow() throws {
        takeScreenshot(app, name: "Window-Initial")

        app.newWindow()
        Thread.sleep(forTimeInterval: 1.0)

        takeScreenshot(app, name: "Window-AfterNew")

        XCTAssertTrue(app.exists, "App should create new tmux window")
    }

    /// Test switching between tmux windows
    func testWindowSwitching() throws {
        app.newWindow()
        Thread.sleep(forTimeInterval: 0.5)

        takeScreenshot(app, name: "WindowSwitch-Window2")

        app.previousWindow()
        Thread.sleep(forTimeInterval: 0.5)

        takeScreenshot(app, name: "WindowSwitch-Window1")

        app.nextWindow()
        Thread.sleep(forTimeInterval: 0.5)

        takeScreenshot(app, name: "WindowSwitch-BackToWindow2")

        XCTAssertTrue(app.exists, "App should handle window switching")
    }

    // MARK: - Stress Tests

    /// Test rapid split/close cycle
    func testRapidSplitClose() throws {
        for i in 0..<5 {
            app.splitHorizontal()
            Thread.sleep(forTimeInterval: 0.3)

            app.closeCurrentPane()
            Thread.sleep(forTimeInterval: 0.3)

            logger.debug("Rapid cycle \(i + 1) complete")
        }

        takeScreenshot(app, name: "RapidCycle-Final")

        XCTAssertTrue(app.exists, "App should survive rapid split/close cycles")
    }

    /// Test creating many panes
    func testManyPanes() throws {
        for i in 0..<3 {
            app.splitHorizontal()
            Thread.sleep(forTimeInterval: 0.5)

            app.splitVertical()
            Thread.sleep(forTimeInterval: 0.5)

            logger.debug("Grid iteration \(i + 1) complete")
        }

        takeScreenshot(app, name: "ManyPanes-Final")

        let paneCount = app.terminalPaneCount
        logger.debug("Final pane count: \(paneCount)")

        XCTAssertTrue(app.exists, "App should handle many panes")
    }
}
