//
//  LayoutStabilityTests.swift
//  GeisttyUITests
//
//  Tests that the app's layout remains stable (no shifts or jumps) during
//  user interactions that historically triggered spurious layout changes.
//  Primary regression guard for #44 Bug 2: terminal view shifts down on
//  touch near top of iPad.
//

import XCTest

final class LayoutStabilityTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = launchForDisconnectedTests()
    }

    override func tearDownWithError() throws {
        takeScreenshot(app, name: "\(name)-teardown")
        app = nil
    }

    // MARK: - Layout Stability After Touch Interactions

    /// Verify that tapping near the top of the screen does not cause the UI
    /// to shift down. On iPad, touching near the status bar area used to trigger
    /// safe area inset changes that pushed the terminal content down. (#44 Bug 2)
    func testTapNearTopDoesNotShiftLayout() throws {
        XCTAssertTrue(app.waitForDisconnectedScreen(timeout: 5))

        // Wait for initial layout to settle
        Thread.sleep(forTimeInterval: 0.5)

        // Capture baseline
        let before = app.screenshot()

        // Tap near the top of the screen (within 20pt of the top edge)
        let topCoordinate = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)
        )
        topCoordinate.tap()

        // Wait for any layout animation to complete
        Thread.sleep(forTimeInterval: 1.0)

        // Capture after
        let after = app.screenshot()

        // Layout should be unchanged — tolerance at 0.5% to catch even small shifts
        assertScreenshotsMatch(
            before: before,
            after: after,
            name: "TapNearTop-LayoutStability",
            tolerance: 0.5
        )
    }

    /// Verify that tapping near the bottom of the screen does not cause
    /// unexpected layout shifts (e.g., from spurious keyboard notifications).
    func testTapNearBottomDoesNotShiftLayout() throws {
        XCTAssertTrue(app.waitForDisconnectedScreen(timeout: 5))

        Thread.sleep(forTimeInterval: 0.5)
        let before = app.screenshot()

        // Tap near the bottom of the screen (dy=0.90 avoids the home indicator
        // region at dy>0.95 which triggers system UI animations)
        let bottomCoordinate = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.90)
        )
        bottomCoordinate.tap()

        Thread.sleep(forTimeInterval: 1.0)
        let after = app.screenshot()

        assertScreenshotsMatch(
            before: before,
            after: after,
            name: "TapNearBottom-LayoutStability",
            tolerance: 2.0
        )
    }

    /// Verify that tapping in the center of the screen does not cause layout changes.
    /// This is a baseline sanity check — center taps should never shift layout.
    func testTapCenterDoesNotShiftLayout() throws {
        XCTAssertTrue(app.waitForDisconnectedScreen(timeout: 5))

        Thread.sleep(forTimeInterval: 0.5)
        let before = app.screenshot()

        // Tap center
        let centerCoordinate = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        centerCoordinate.tap()

        Thread.sleep(forTimeInterval: 1.0)
        let after = app.screenshot()

        assertScreenshotsMatch(
            before: before,
            after: after,
            name: "TapCenter-LayoutStability",
            tolerance: 0.5
        )
    }

    /// Verify that multiple rapid taps near the top edge don't cause
    /// cumulative layout drift. Regression guard for the case where
    /// viewDidLayoutSubviews fires redundantly.
    func testRapidTapsNearTopDoNotCauseDrift() throws {
        XCTAssertTrue(app.waitForDisconnectedScreen(timeout: 5))

        Thread.sleep(forTimeInterval: 0.5)
        let before = app.screenshot()

        // Tap near the top 5 times rapidly
        let topCoordinate = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)
        )
        for _ in 0..<5 {
            topCoordinate.tap()
            Thread.sleep(forTimeInterval: 0.1)
        }

        // Wait for all layout passes to complete
        Thread.sleep(forTimeInterval: 1.0)
        let after = app.screenshot()

        assertScreenshotsMatch(
            before: before,
            after: after,
            name: "RapidTapsNearTop-LayoutStability",
            tolerance: 0.5
        )
    }

    /// Verify that tapping in opposite corners of the screen doesn't cause layout shifts.
    /// This exercises the safe area inset handling at all edges.
    func testTapAllCornersDoesNotShiftLayout() throws {
        XCTAssertTrue(app.waitForDisconnectedScreen(timeout: 5))

        Thread.sleep(forTimeInterval: 0.5)
        let before = app.screenshot()

        // Top-left
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.02)).tap()
        Thread.sleep(forTimeInterval: 0.3)

        // Top-right
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.02)).tap()
        Thread.sleep(forTimeInterval: 0.3)

        // Bottom-left
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.98)).tap()
        Thread.sleep(forTimeInterval: 0.3)

        // Bottom-right
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.98)).tap()
        Thread.sleep(forTimeInterval: 0.3)

        Thread.sleep(forTimeInterval: 0.5)
        let after = app.screenshot()

        assertScreenshotsMatch(
            before: before,
            after: after,
            name: "TapAllCorners-LayoutStability",
            tolerance: 0.5
        )
    }
}
