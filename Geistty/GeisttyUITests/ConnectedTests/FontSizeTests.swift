//
//  FontSizeTests.swift
//  GeisttyUITests
//
//  Tests for font size adjustment — increase, decrease, reset,
//  pinch-to-zoom, and rapid changes.
//

import XCTest

final class FontSizeTests: XCTestCase {

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

    // MARK: - Font Size Tests

    /// Increase font size several times and screenshot after each step.
    func testIncreaseFontSize() throws {
        takeScreenshot(app, name: "IncreaseFontSize-01-Initial")

        for i in 1...5 {
            app.increaseFontSize()
            Thread.sleep(forTimeInterval: 0.5)
            takeScreenshot(app, name: "IncreaseFontSize-02-After\(i)")
        }

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should remain active after increasing font size")
    }

    /// Decrease font size several times and screenshot after each step.
    func testDecreaseFontSize() throws {
        takeScreenshot(app, name: "DecreaseFontSize-01-Initial")

        for i in 1...5 {
            app.decreaseFontSize()
            Thread.sleep(forTimeInterval: 0.5)
            takeScreenshot(app, name: "DecreaseFontSize-02-After\(i)")
        }

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should remain active after decreasing font size")
    }

    /// Change font size then reset back to default.
    func testResetFontSize() throws {
        takeScreenshot(app, name: "ResetFontSize-01-Initial")

        // Increase a few times to move away from the default
        for _ in 1...3 {
            app.increaseFontSize()
            Thread.sleep(forTimeInterval: 0.5)
        }
        takeScreenshot(app, name: "ResetFontSize-02-AfterIncrease")

        // Reset to default
        app.resetFontSize()
        Thread.sleep(forTimeInterval: 0.5)
        takeScreenshot(app, name: "ResetFontSize-03-AfterReset")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should remain active after resetting font size")
    }

    /// Increase 3x then decrease 3x — should return to baseline size.
    func testFontSizeIncreaseAndDecrease() throws {
        takeScreenshot(app, name: "IncreaseDecrease-01-Initial")

        for _ in 1...3 {
            app.increaseFontSize()
            Thread.sleep(forTimeInterval: 0.5)
        }
        takeScreenshot(app, name: "IncreaseDecrease-02-AfterIncrease")

        for _ in 1...3 {
            app.decreaseFontSize()
            Thread.sleep(forTimeInterval: 0.5)
        }
        takeScreenshot(app, name: "IncreaseDecrease-03-AfterDecrease")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should remain active after increase/decrease cycle")
    }

    /// Rapidly increase and decrease font size multiple times to verify no crash.
    func testFontSizeRapidChanges() throws {
        takeScreenshot(app, name: "RapidChanges-01-Initial")

        for _ in 1...10 {
            app.increaseFontSize()
            Thread.sleep(forTimeInterval: 0.5)
        }

        for _ in 1...10 {
            app.decreaseFontSize()
            Thread.sleep(forTimeInterval: 0.5)
        }

        for _ in 1...5 {
            app.increaseFontSize()
            Thread.sleep(forTimeInterval: 0.5)
            app.decreaseFontSize()
            Thread.sleep(forTimeInterval: 0.5)
        }

        takeScreenshot(app, name: "RapidChanges-02-AfterRapid")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should not crash after rapid font size changes")
    }

    /// Use pinch gesture on the terminal surface to zoom, then screenshot.
    func testFontSizeAfterPinchZoom() throws {
        takeScreenshot(app, name: "PinchZoom-01-Initial")

        let surface = app.otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH 'TerminalSurface'")
        ).firstMatch

        surface.pinch(withScale: 1.5, velocity: 1.0)
        Thread.sleep(forTimeInterval: 0.5)
        takeScreenshot(app, name: "PinchZoom-02-AfterPinchOut")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should remain active after pinch-to-zoom")
    }

    /// Change font size, type a command, and verify the terminal still works.
    func testFontSizePersistsAcrossCommands() throws {
        takeScreenshot(app, name: "PersistAcross-01-Initial")

        // Increase font size
        for _ in 1...3 {
            app.increaseFontSize()
            Thread.sleep(forTimeInterval: 0.5)
        }
        takeScreenshot(app, name: "PersistAcross-02-AfterIncrease")

        // Type a command to verify the terminal still accepts input
        app.typeText("echo 'FONT_SIZE_TEST'\n")
        Thread.sleep(forTimeInterval: 1.0)
        takeScreenshot(app, name: "PersistAcross-03-AfterCommand")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should remain active after font change and command execution")
    }
}
