//
//  OrientationTests.swift
//  GeisttyUITests
//
//  Tests for device orientation changes — verifying the terminal surface,
//  split panes, and overlays survive rotation transitions.
//

import XCTest

final class OrientationTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        guard TestConfig.isConfigured else {
            throw XCTSkip("TestConfig.local.swift not configured — isConfigured is false")
        }

        continueAfterFailure = false
        app = launchForConnectedTests()

        XCTAssertTrue(app.waitForTerminal(timeout: TestConfig.connectionTimeout),
                      "Terminal surface should appear after connecting")

        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 1.0)
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        takeScreenshot(app, name: "\(name)-teardown")
        app = nil
    }

    // MARK: - Basic Orientations

    /// The terminal should exist in default portrait orientation.
    func testPortraitOrientation() throws {
        takeScreenshot(app, name: "Portrait-01-Initial")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should be visible in portrait orientation")
        XCTAssertGreaterThanOrEqual(app.terminalSurfaceCount, 1,
                                    "At least one TerminalSurface should exist in portrait")

        takeScreenshot(app, name: "Portrait-02-Verified")
    }

    /// Rotating to landscape-left should keep the terminal alive.
    func testLandscapeLeftOrientation() throws {
        takeScreenshot(app, name: "LandscapeLeft-01-Portrait")

        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1.5)

        takeScreenshot(app, name: "LandscapeLeft-02-Rotated")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should still exist after rotating to landscape-left")
        XCTAssertGreaterThanOrEqual(app.terminalSurfaceCount, 1,
                                    "At least one TerminalSurface should exist in landscape-left")
    }

    /// Rotating to landscape-right should keep the terminal alive.
    func testLandscapeRightOrientation() throws {
        takeScreenshot(app, name: "LandscapeRight-01-Portrait")

        XCUIDevice.shared.orientation = .landscapeRight
        Thread.sleep(forTimeInterval: 1.5)

        takeScreenshot(app, name: "LandscapeRight-02-Rotated")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should still exist after rotating to landscape-right")
        XCTAssertGreaterThanOrEqual(app.terminalSurfaceCount, 1,
                                    "At least one TerminalSurface should exist in landscape-right")
    }

    // MARK: - Orientation Transitions

    /// Rotating portrait → landscape → portrait should preserve the terminal.
    func testPortraitToLandscapeAndBack() throws {
        takeScreenshot(app, name: "PortraitLandscapeBack-01-Portrait")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should be visible in initial portrait")

        // Rotate to landscape
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1.5)

        takeScreenshot(app, name: "PortraitLandscapeBack-02-Landscape")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should survive rotation to landscape")
        XCTAssertGreaterThanOrEqual(app.terminalSurfaceCount, 1,
                                    "At least one TerminalSurface should exist in landscape")

        // Rotate back to portrait
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 1.5)

        takeScreenshot(app, name: "PortraitLandscapeBack-03-BackToPortrait")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should survive rotation back to portrait")
        XCTAssertGreaterThanOrEqual(app.terminalSurfaceCount, 1,
                                    "At least one TerminalSurface should exist after returning to portrait")
    }

    // MARK: - Split Panes & Orientation

    /// Split panes should survive an orientation change.
    func testOrientationWithSplitPanes() throws {
        takeScreenshot(app, name: "SplitOrientation-01-BeforeSplit")

        // Create a horizontal split
        app.splitHorizontal()
        Thread.sleep(forTimeInterval: 2.0)

        takeScreenshot(app, name: "SplitOrientation-02-AfterSplit")

        let paneCountBeforeRotation = app.terminalSurfaceCount
        XCTAssertGreaterThanOrEqual(paneCountBeforeRotation, 2,
                                    "Should have at least 2 surfaces after split")

        // Rotate to landscape
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1.5)

        takeScreenshot(app, name: "SplitOrientation-03-Landscape")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should still be visible after rotating with split panes")
        XCTAssertGreaterThanOrEqual(app.terminalSurfaceCount, 2,
                                    "Split panes should survive orientation change")
    }

    // MARK: - Typing in Landscape

    /// Typing a command in landscape orientation should work normally.
    func testTypingInLandscape() throws {
        takeScreenshot(app, name: "TypeLandscape-01-Portrait")

        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1.5)

        takeScreenshot(app, name: "TypeLandscape-02-Landscape")

        app.typeText("echo 'orientation test'\n")
        Thread.sleep(forTimeInterval: 1.0)

        takeScreenshot(app, name: "TypeLandscape-03-AfterType")

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should remain active after typing in landscape")
    }

    // MARK: - Rapid Orientation Changes

    /// Rapidly cycling through all four orientations should not crash.
    func testRapidOrientationChanges() throws {
        takeScreenshot(app, name: "RapidRotation-01-Initial")

        let orientations: [UIDeviceOrientation] = [
            .landscapeLeft,
            .portraitUpsideDown,
            .landscapeRight,
            .portrait,
        ]

        for (index, orientation) in orientations.enumerated() {
            XCUIDevice.shared.orientation = orientation
            Thread.sleep(forTimeInterval: 1.5)
            takeScreenshot(app, name: "RapidRotation-02-Step\(index + 1)")
        }

        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should survive rapid orientation changes")
        XCTAssertGreaterThanOrEqual(app.terminalSurfaceCount, 1,
                                    "At least one TerminalSurface should exist after rapid rotations")
    }

    // MARK: - Overlays & Orientation

    /// The search overlay should survive an orientation change.
    func testOrientationWithSearch() throws {
        takeScreenshot(app, name: "SearchOrientation-01-Portrait")

        // Open search in portrait
        app.openSearch()
        Thread.sleep(forTimeInterval: 1.0)

        takeScreenshot(app, name: "SearchOrientation-02-SearchOpen")

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 3),
                      "Search field should be visible in portrait")

        // Rotate to landscape
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1.5)

        takeScreenshot(app, name: "SearchOrientation-03-Landscape")

        XCTAssertTrue(searchField.exists,
                      "Search field should still be visible after rotating to landscape")
        XCTAssertTrue(app.isInTerminalView,
                      "Terminal should remain visible with search open in landscape")
    }
}
