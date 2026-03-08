import XCTest
@testable import Geistty

// MARK: - SelectionHandleView Tests

final class SelectionHandleViewTests: XCTestCase {

    // MARK: - Handle Size

    func testHandleSizeMatchesExpected() {
        let expected = CGSize(
            width: SelectionHandleView.circleDiameter,
            height: SelectionHandleView.circleDiameter + SelectionHandleView.stemHeight
        )
        XCTAssertEqual(SelectionHandleView.handleSize, expected)
    }

    func testCircleDiameterIsReasonable() {
        // Handle circle should be large enough to see but small enough to not occlude text
        XCTAssertGreaterThanOrEqual(SelectionHandleView.circleDiameter, 8)
        XCTAssertLessThanOrEqual(SelectionHandleView.circleDiameter, 20)
    }

    func testStemHeightIsReasonable() {
        XCTAssertGreaterThan(SelectionHandleView.stemHeight, 0)
        XCTAssertLessThanOrEqual(SelectionHandleView.stemHeight, 16)
    }

    // MARK: - Handle Position Types

    func testStartHandleInitializes() {
        let handle = SelectionHandleView(position: .start)
        XCTAssertEqual(handle.position, .start)
        XCTAssertTrue(handle.isUserInteractionEnabled)
        XCTAssertEqual(handle.backgroundColor, .clear)
    }

    func testEndHandleInitializes() {
        let handle = SelectionHandleView(position: .end)
        XCTAssertEqual(handle.position, .end)
        XCTAssertTrue(handle.isUserInteractionEnabled)
        XCTAssertEqual(handle.backgroundColor, .clear)
    }

    func testHandleFrameMatchesExpectedSize() {
        let handle = SelectionHandleView(position: .start)
        XCTAssertEqual(handle.frame.size, SelectionHandleView.handleSize)
    }

    // MARK: - Touch Target

    func testExpandedTouchTarget() {
        let handle = SelectionHandleView(position: .start)
        let insets = SelectionHandleView.touchInsets

        // Touch at center should hit
        let center = CGPoint(x: handle.bounds.midX, y: handle.bounds.midY)
        XCTAssertTrue(handle.point(inside: center, with: nil))

        // Touch well outside expanded area should miss
        let far = CGPoint(x: handle.bounds.midX + 100, y: handle.bounds.midY + 100)
        XCTAssertFalse(handle.point(inside: far, with: nil))

        // Touch within expanded insets should hit
        // insets are negative (expanding), so the expanded rect extends outward
        let nearEdge = CGPoint(x: -insets.left / 2, y: -insets.top / 2)
        XCTAssertTrue(handle.point(inside: nearEdge, with: nil))
    }
}

// MARK: - SelectionOverlay Tests

final class SelectionOverlayTests: XCTestCase {

    // MARK: - Initialization

    func testOverlayInitialState() {
        let overlay = SelectionOverlay(frame: CGRect(x: 0, y: 0, width: 400, height: 300))

        // Overlay should be transparent and non-opaque
        XCTAssertEqual(overlay.backgroundColor, .clear)
        XCTAssertFalse(overlay.isOpaque)
        XCTAssertTrue(overlay.isUserInteractionEnabled)
    }

    func testOverlayHasNoSurfaceViewByDefault() {
        let overlay = SelectionOverlay(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertNil(overlay.surfaceView)
    }

    // MARK: - Hit Testing (Pass-Through)

    func testHitTestPassesThroughWhenNoSelection() {
        let overlay = SelectionOverlay(frame: CGRect(x: 0, y: 0, width: 400, height: 300))

        // When handles are hidden (default), touches should pass through
        let result = overlay.hitTest(CGPoint(x: 200, y: 150), with: nil)
        XCTAssertNil(result, "Overlay should pass through touches when handles are hidden")
    }

    // MARK: - hideSelection Without Surface

    func testHideSelectionWithoutSurfaceDoesNotCrash() {
        let overlay = SelectionOverlay(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        // Should not crash when surfaceView is nil
        overlay.hideSelection()
    }

    func testShowSelectionWithoutSurfaceDoesNotCrash() {
        let overlay = SelectionOverlay(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        // Should not crash when surfaceView is nil — just returns early
        overlay.showSelection()
    }

    func testUpdateHandlePositionsIfVisibleWithoutSurfaceDoesNotCrash() {
        let overlay = SelectionOverlay(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        overlay.updateHandlePositionsIfVisible()
    }
}
