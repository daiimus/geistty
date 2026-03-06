//
//  SplitPaneTests.swift
//  GeisttyUITests
//
//  Tests for tmux split pane operations — horizontal/vertical splits,
//  pane focus navigation, closing panes, and multi-pane layouts.
//

import XCTest

final class SplitPaneTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        guard TestConfig.isConfigured else {
            throw XCTSkip("TestConfig.local.swift not configured — isConfigured is false")
        }

        continueAfterFailure = false
        app = launchForConnectedTests()

        XCTAssertTrue(app.waitForTerminal(timeout: TestConfig.connectionTimeout),
                      "Terminal surface should appear after connecting")

        // Let tmux initialize before running split operations
        Thread.sleep(forTimeInterval: 2.0)
    }

    override func tearDownWithError() throws {
        takeScreenshot(app, name: "\(name)-teardown")
        app = nil
    }

    // MARK: - Horizontal & Vertical Splits

    /// Split horizontally (Cmd+D) and verify pane count increases.
    func testHorizontalSplit() throws {
        let initialPaneCount = app.terminalPaneCount
        takeScreenshot(app, name: "HorizontalSplit-01-Before")

        app.splitHorizontal()
        Thread.sleep(forTimeInterval: 1.5)

        takeScreenshot(app, name: "HorizontalSplit-02-After")

        let newPaneCount = app.terminalPaneCount
        XCTAssertGreaterThan(newPaneCount, initialPaneCount,
                             "Pane count should increase after horizontal split")
    }

    /// Split vertically (Cmd+Shift+D) and verify pane count increases.
    func testVerticalSplit() throws {
        let initialPaneCount = app.terminalPaneCount
        takeScreenshot(app, name: "VerticalSplit-01-Before")

        app.splitVertical()
        Thread.sleep(forTimeInterval: 1.5)

        takeScreenshot(app, name: "VerticalSplit-02-After")

        let newPaneCount = app.terminalPaneCount
        XCTAssertGreaterThan(newPaneCount, initialPaneCount,
                             "Pane count should increase after vertical split")
    }

    // MARK: - Pane Focus Navigation

    /// Split, then focus the next pane (Cmd+]) and type text.
    func testFocusNextPane() throws {
        app.splitHorizontal()
        Thread.sleep(forTimeInterval: 1.5)
        takeScreenshot(app, name: "FocusNext-01-AfterSplit")

        app.focusNextPane()
        Thread.sleep(forTimeInterval: 1.0)

        app.typeText("echo 'FOCUS_NEXT_PANE'\n")
        Thread.sleep(forTimeInterval: 1.0)

        takeScreenshot(app, name: "FocusNext-02-AfterType")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should remain active after focusing next pane")
    }

    /// Split, then focus the previous pane (Cmd+[) and type text.
    func testFocusPreviousPane() throws {
        app.splitHorizontal()
        Thread.sleep(forTimeInterval: 1.5)
        takeScreenshot(app, name: "FocusPrevious-01-AfterSplit")

        app.focusPreviousPane()
        Thread.sleep(forTimeInterval: 1.0)

        app.typeText("echo 'FOCUS_PREVIOUS_PANE'\n")
        Thread.sleep(forTimeInterval: 1.0)

        takeScreenshot(app, name: "FocusPrevious-02-AfterType")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should remain active after focusing previous pane")
    }

    // MARK: - Closing Panes

    /// Split, then close one pane (Cmd+W) and verify pane count decreases.
    func testCloseSplitPane() throws {
        app.splitHorizontal()
        Thread.sleep(forTimeInterval: 1.5)

        let paneCountAfterSplit = app.terminalPaneCount
        takeScreenshot(app, name: "ClosePane-01-AfterSplit")

        app.closeCurrentPane()
        Thread.sleep(forTimeInterval: 1.5)

        takeScreenshot(app, name: "ClosePane-02-AfterClose")

        let paneCountAfterClose = app.terminalPaneCount
        XCTAssertLessThan(paneCountAfterClose, paneCountAfterSplit,
                          "Pane count should decrease after closing a pane")
    }

    // MARK: - Multi-Pane Layouts

    /// Create a quad-split layout (4 panes) via horizontal + vertical splits.
    func testQuadSplit() throws {
        takeScreenshot(app, name: "QuadSplit-01-Initial")

        // First horizontal split: 2 panes side by side
        app.splitHorizontal()
        Thread.sleep(forTimeInterval: 1.5)
        takeScreenshot(app, name: "QuadSplit-02-AfterFirstHSplit")

        // Vertical split on the right pane: 3 panes
        app.splitVertical()
        Thread.sleep(forTimeInterval: 1.5)
        takeScreenshot(app, name: "QuadSplit-03-AfterFirstVSplit")

        // Focus back to the left pane and vertical split it: 4 panes
        app.focusPreviousPane()
        Thread.sleep(forTimeInterval: 1.0)
        app.focusPreviousPane()
        Thread.sleep(forTimeInterval: 1.0)

        app.splitVertical()
        Thread.sleep(forTimeInterval: 1.5)
        takeScreenshot(app, name: "QuadSplit-04-FourPanes")

        let paneCount = app.terminalPaneCount
        XCTAssertGreaterThanOrEqual(paneCount, 4,
                                     "Should have at least 4 panes after quad split")

        // Verify the multi-pane container exists
        let container = app.otherElements["TmuxMultiPaneContainer"]
        XCTAssertTrue(container.exists,
                      "TmuxMultiPaneContainer should be visible with multiple panes")
    }

    /// Split into 2 panes, type in each one, and verify via screenshots.
    func testTypeInMultiplePanes() throws {
        app.splitHorizontal()
        Thread.sleep(forTimeInterval: 1.5)
        takeScreenshot(app, name: "TypeMulti-01-AfterSplit")

        // Type in the current (second) pane
        app.typeText("echo 'PANE_TWO'\n")
        Thread.sleep(forTimeInterval: 1.0)
        takeScreenshot(app, name: "TypeMulti-02-PaneTwo")

        // Focus the first pane and type there
        app.focusPreviousPane()
        Thread.sleep(forTimeInterval: 1.0)

        app.typeText("echo 'PANE_ONE'\n")
        Thread.sleep(forTimeInterval: 1.0)
        takeScreenshot(app, name: "TypeMulti-03-PaneOne")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should remain active after typing in multiple panes")
    }

    /// Split into 3 panes and cycle through all of them.
    func testSplitAndNavigateCycle() throws {
        // Create 3 panes: horizontal split, then vertical split
        app.splitHorizontal()
        Thread.sleep(forTimeInterval: 1.5)

        app.splitVertical()
        Thread.sleep(forTimeInterval: 1.5)
        takeScreenshot(app, name: "NavCycle-01-ThreePanes")

        let paneCount = app.terminalPaneCount
        XCTAssertGreaterThanOrEqual(paneCount, 3,
                                     "Should have at least 3 panes")

        // Cycle through all panes using Cmd+]
        app.focusNextPane()
        Thread.sleep(forTimeInterval: 1.0)
        app.typeText("echo 'CYCLE_1'\n")
        Thread.sleep(forTimeInterval: 0.5)
        takeScreenshot(app, name: "NavCycle-02-Pane1")

        app.focusNextPane()
        Thread.sleep(forTimeInterval: 1.0)
        app.typeText("echo 'CYCLE_2'\n")
        Thread.sleep(forTimeInterval: 0.5)
        takeScreenshot(app, name: "NavCycle-03-Pane2")

        app.focusNextPane()
        Thread.sleep(forTimeInterval: 1.0)
        app.typeText("echo 'CYCLE_3'\n")
        Thread.sleep(forTimeInterval: 0.5)
        takeScreenshot(app, name: "NavCycle-04-Pane3")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should remain active after cycling through all panes")
    }
}
