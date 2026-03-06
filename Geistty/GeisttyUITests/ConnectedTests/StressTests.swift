//
//  StressTests.swift
//  GeisttyUITests
//
//  Stress tests and edge cases — rapid input, repeated operations,
//  large output, maximum splits, and combined interactions.
//

import XCTest

final class StressTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        guard TestConfig.isConfigured else {
            throw XCTSkip("TestConfig.local.swift not configured — isConfigured is false")
        }

        continueAfterFailure = true
        app = launchForConnectedTests()

        XCTAssertTrue(app.waitForTerminal(timeout: TestConfig.connectionTimeout),
                      "Terminal surface should appear after connecting")
    }

    override func tearDownWithError() throws {
        takeScreenshot(app, name: "\(name)-teardown")
        app = nil
    }

    // MARK: - Rapid Input

    /// Type a long string rapidly (100+ characters) and verify the terminal survives.
    func testRapidKeyboardInput() throws {
        takeScreenshot(app, name: "RapidInput-01-Before")

        let longString = String(repeating: "abcdefghij", count: 12) // 120 characters
        app.typeText(longString)
        Thread.sleep(forTimeInterval: 1.0)

        takeScreenshot(app, name: "RapidInput-02-AfterType")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should survive rapid keyboard input of 120 characters")
        XCTAssertGreaterThanOrEqual(app.terminalSurfaceCount, 1,
                                    "At least one TerminalSurface should exist after rapid input")
    }

    // MARK: - Repeated Split & Close

    /// Split and close 5 times in a row, verifying the terminal is stable each cycle.
    func testRepeatedSplitAndClose() throws {
        takeScreenshot(app, name: "RepeatedSplit-01-Initial")

        // Let tmux initialize before running split operations
        Thread.sleep(forTimeInterval: 2.0)

        for i in 1...5 {
            app.splitHorizontal()
            Thread.sleep(forTimeInterval: 1.5)

            takeScreenshot(app, name: "RepeatedSplit-02-Split\(i)")

            XCTAssertTrue(app.isInTerminalView,
                          "Terminal should be active after split #\(i)")

            app.closeCurrentPane()
            Thread.sleep(forTimeInterval: 1.5)

            takeScreenshot(app, name: "RepeatedSplit-03-Close\(i)")

            XCTAssertTrue(app.isInTerminalView,
                          "Terminal should be active after close #\(i)")
        }

        takeScreenshot(app, name: "RepeatedSplit-04-Final")

        XCTAssertGreaterThanOrEqual(app.terminalSurfaceCount, 1,
                                    "At least one TerminalSurface should remain after repeated split/close")
    }

    // MARK: - Repeated Font Size Changes

    /// Increase and decrease font size 10 times rapidly.
    func testRepeatedFontSizeChanges() throws {
        takeScreenshot(app, name: "RepeatedFont-01-Initial")

        for i in 1...10 {
            app.increaseFontSize()
            Thread.sleep(forTimeInterval: 0.3)

            if i % 5 == 0 {
                takeScreenshot(app, name: "RepeatedFont-02-Increase\(i)")
            }
        }

        for i in 1...10 {
            app.decreaseFontSize()
            Thread.sleep(forTimeInterval: 0.3)

            if i % 5 == 0 {
                takeScreenshot(app, name: "RepeatedFont-03-Decrease\(i)")
            }
        }

        takeScreenshot(app, name: "RepeatedFont-04-Final")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should survive 20 rapid font size changes")
        XCTAssertGreaterThanOrEqual(app.terminalSurfaceCount, 1,
                                    "At least one TerminalSurface should exist after rapid font changes")
    }

    // MARK: - Repeated Search Open/Close

    /// Open and close the search overlay 5 times rapidly.
    func testOpenAndCloseSearchRepeatedly() throws {
        takeScreenshot(app, name: "RepeatedSearch-01-Initial")

        for i in 1...5 {
            app.openSearch()
            Thread.sleep(forTimeInterval: 0.5)

            let searchField = app.textFields["SearchTextField"]
            XCTAssertTrue(searchField.waitForExistence(timeout: 3),
                          "SearchTextField should appear on open #\(i)")

            takeScreenshot(app, name: "RepeatedSearch-02-Open\(i)")

            app.typeKey(.escape, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.5)

            XCTAssertTrue(searchField.waitForDisappearance(timeout: 3),
                          "SearchTextField should disappear on close #\(i)")
        }

        takeScreenshot(app, name: "RepeatedSearch-03-Final")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should survive repeated search open/close")
    }

    // MARK: - Repeated Command Palette Open/Close

    /// Open and close the command palette 5 times.
    func testOpenAndCloseCommandPaletteRepeatedly() throws {
        takeScreenshot(app, name: "RepeatedPalette-01-Initial")

        for i in 1...5 {
            app.openCommandPalette()
            Thread.sleep(forTimeInterval: 0.5)

            let searchField = app.textFields["CommandPaletteSearchField"]
            XCTAssertTrue(searchField.waitForExistence(timeout: 3),
                          "CommandPaletteSearchField should appear on open #\(i)")

            takeScreenshot(app, name: "RepeatedPalette-02-Open\(i)")

            app.typeKey(.escape, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.5)

            XCTAssertTrue(searchField.waitForDisappearance(timeout: 3),
                          "CommandPaletteSearchField should disappear on close #\(i)")
        }

        takeScreenshot(app, name: "RepeatedPalette-03-Final")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should survive repeated command palette open/close")
    }

    // MARK: - Large Output

    /// Generate large terminal output with `seq 1 500` and verify the terminal handles it.
    func testLargeOutputCommand() throws {
        takeScreenshot(app, name: "LargeOutput-01-Before")

        app.typeText("seq 1 500\n")
        Thread.sleep(forTimeInterval: 2.0)

        takeScreenshot(app, name: "LargeOutput-02-AfterOutput")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should survive large output from seq 1 500")
        XCTAssertGreaterThanOrEqual(app.terminalSurfaceCount, 1,
                                    "At least one TerminalSurface should exist after large output")
    }

    // MARK: - Maximum Splits

    /// Create as many splits as possible (try 6+ splits) and screenshot the result.
    func testMultipleSplitsMaxPanes() throws {
        takeScreenshot(app, name: "MaxSplits-01-Initial")

        // Let tmux initialize before running split operations
        Thread.sleep(forTimeInterval: 2.0)

        let targetSplits = 6

        for i in 1...targetSplits {
            // Alternate between horizontal and vertical splits
            if i % 2 == 1 {
                app.splitHorizontal()
            } else {
                app.splitVertical()
            }
            Thread.sleep(forTimeInterval: 1.5)

            takeScreenshot(app, name: "MaxSplits-02-Split\(i)")

            XCTAssertTrue(app.isInTerminalView,
                          "Terminal should remain active after split #\(i)")
        }

        takeScreenshot(app, name: "MaxSplits-03-Final")

        let finalSurfaceCount = app.terminalSurfaceCount
        XCTAssertGreaterThanOrEqual(finalSurfaceCount, 2,
                                    "Should have multiple surfaces after creating \(targetSplits) splits")
    }

    // MARK: - Combined Stress

    /// Perform a sequence of mixed operations: split, change font, open search,
    /// close search, type command, rotate — all in sequence.
    func testCombinedStress() throws {
        takeScreenshot(app, name: "Combined-01-Initial")

        // Let tmux initialize
        Thread.sleep(forTimeInterval: 2.0)

        // Split
        app.splitHorizontal()
        Thread.sleep(forTimeInterval: 1.5)
        takeScreenshot(app, name: "Combined-02-AfterSplit")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should be active after split")

        // Change font size
        app.increaseFontSize()
        Thread.sleep(forTimeInterval: 0.3)
        app.increaseFontSize()
        Thread.sleep(forTimeInterval: 0.3)
        app.decreaseFontSize()
        Thread.sleep(forTimeInterval: 0.5)
        takeScreenshot(app, name: "Combined-03-AfterFontChange")

        // Open search
        app.openSearch()
        Thread.sleep(forTimeInterval: 0.5)

        let searchField = app.textFields["SearchTextField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3),
                      "SearchTextField should appear during combined stress")

        takeScreenshot(app, name: "Combined-04-SearchOpen")

        // Close search
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        takeScreenshot(app, name: "Combined-05-SearchClosed")

        // Type a command
        app.typeText("echo 'COMBINED_STRESS_TEST'\n")
        Thread.sleep(forTimeInterval: 1.0)
        takeScreenshot(app, name: "Combined-06-AfterCommand")

        // Rotate
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1.5)
        takeScreenshot(app, name: "Combined-07-Landscape")

        // Rotate back
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 1.5)
        takeScreenshot(app, name: "Combined-08-BackToPortrait")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should survive combined stress operations")
        XCTAssertGreaterThanOrEqual(app.terminalSurfaceCount, 1,
                                    "At least one TerminalSurface should exist after combined stress")
    }

    // MARK: - Long Running Command

    /// Execute a long-running command (`sleep 2 && echo done`), wait, and screenshot.
    func testLongRunningCommand() throws {
        takeScreenshot(app, name: "LongRunning-01-Before")

        app.typeText("sleep 2 && echo done\n")
        Thread.sleep(forTimeInterval: 3.0)

        takeScreenshot(app, name: "LongRunning-02-AfterWait")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should survive a long-running command")
        XCTAssertGreaterThanOrEqual(app.terminalSurfaceCount, 1,
                                    "At least one TerminalSurface should exist after long-running command")
    }
}
