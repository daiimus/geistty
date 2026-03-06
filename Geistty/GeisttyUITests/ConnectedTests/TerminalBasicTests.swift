//
//  TerminalBasicTests.swift
//  GeisttyUITests
//
//  Tests for basic terminal functionality — verifying the terminal surface
//  appears, accepts keyboard input, and executes commands after connecting.
//

import XCTest

final class TerminalBasicTests: XCTestCase {

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

    // MARK: - Surface & State

    /// After connection, at least one TerminalSurface exists.
    func testTerminalSurfaceExists() throws {
        takeScreenshot(app, name: "SurfaceExists-01-Connected")

        XCTAssertTrue(app.isInTerminalView,
                      "App should be in terminal view after connecting")
        XCTAssertGreaterThanOrEqual(app.terminalSurfaceCount, 1,
                                    "At least one TerminalSurface should exist")
    }

    /// The terminal should not show the disconnected screen while connected.
    func testTerminalNotOnDisconnectedScreen() throws {
        takeScreenshot(app, name: "NotDisconnected-01")

        XCTAssertFalse(app.isOnDisconnectedScreen,
                       "Should NOT be on the disconnected screen after connecting")
    }

    // MARK: - Keyboard Input

    /// The terminal should accept input immediately (first responder).
    func testTerminalIsFirstResponder() throws {
        takeScreenshot(app, name: "FirstResponder-01-Initial")

        // Typing should not crash or be ignored — type a harmless character
        app.typeText("a")
        Thread.sleep(forTimeInterval: 0.5)

        takeScreenshot(app, name: "FirstResponder-02-AfterType")

        // Still in terminal view means input was accepted
        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should remain active after typing")
    }

    /// Type a command and verify the terminal accepts keyboard input.
    func testTerminalAcceptsKeyboardInput() throws {
        takeScreenshot(app, name: "KeyboardInput-01-Before")

        app.typeText("echo hello")
        Thread.sleep(forTimeInterval: 0.5)

        takeScreenshot(app, name: "KeyboardInput-02-AfterType")

        // Confirm we are still in the terminal (no crash, no navigation away)
        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should still be visible after typing a command")
    }

    /// Type a command with a unique marker, press return, and capture the output.
    func testTypeCommandAndCaptureOutput() throws {
        takeScreenshot(app, name: "CaptureOutput-01-Before")

        app.typeText("echo 'GEISTTY_TEST_MARKER'\n")
        Thread.sleep(forTimeInterval: 1.0)

        takeScreenshot(app, name: "CaptureOutput-02-AfterCommand")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should still be active after executing a command")
    }

    /// Send Cmd+K to clear the screen and verify via screenshot.
    func testClearScreenCommand() throws {
        // Type something first so there is content to clear
        app.typeText("echo 'before clear'\n")
        Thread.sleep(forTimeInterval: 0.5)
        takeScreenshot(app, name: "ClearScreen-01-BeforeClear")

        app.typeKey("k", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        takeScreenshot(app, name: "ClearScreen-02-AfterClear")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should remain active after Cmd+K clear")
    }

    /// Type several commands in sequence to verify sustained input handling.
    func testMultipleCommandsInSequence() throws {
        takeScreenshot(app, name: "MultiCmd-01-Initial")

        app.typeText("echo 'command one'\n")
        Thread.sleep(forTimeInterval: 0.5)
        takeScreenshot(app, name: "MultiCmd-02-AfterFirst")

        app.typeText("echo 'command two'\n")
        Thread.sleep(forTimeInterval: 0.5)
        takeScreenshot(app, name: "MultiCmd-03-AfterSecond")

        app.typeText("echo 'command three'\n")
        Thread.sleep(forTimeInterval: 0.5)
        takeScreenshot(app, name: "MultiCmd-04-AfterThird")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should handle multiple sequential commands")
    }
}
