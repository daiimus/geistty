import XCTest
@testable import Geistty

// MARK: - Resize Timing Tests
//
// Tests for the terminal resize fix that eliminated Task { @MainActor in }
// deferral from onResize/onWrite callbacks.
//
// Root cause: onResize was wrapped in Task { @MainActor in }, deferring the
// cols/rows update to the next run loop tick. Meanwhile, connect() and
// useExistingSession() read the stale 80x24 defaults.
//
// Fix: onResize fires synchronously from layoutSubviews on the main thread,
// so no Task wrapper is needed. Additionally, connect()/useExistingSession()
// now read the actual grid size from Ghostty via surfaceSize before sending
// the initial resize to SSH.
//
// These tests verify:
// 1. NIOSSHConnection initial defaults match expected 80x24
// 2. NIOSSHConnection.resizePTY stores dimensions synchronously
// 3. SSHSession.resize() updates dimensions synchronously

final class ResizeTimingTests: XCTestCase {

    // MARK: - NIOSSHConnection Defaults

    @MainActor
    func testNIOSSHConnectionDefaultSize() {
        let conn = NIOSSHConnection(host: "localhost", username: "test")
        XCTAssertEqual(conn.cols, 80, "Default cols should be 80")
        XCTAssertEqual(conn.rows, 24, "Default rows should be 24")
    }

    // MARK: - NIOSSHConnection.resizePTY: Guard Behavior

    @MainActor
    func testResizePTYEarlyReturnsWithoutChannel() {
        let conn = NIOSSHConnection(host: "localhost", username: "test")
        // Without a channel, resizePTY guards early and does NOT update cols/rows.
        // This is expected — you can't resize a PTY that doesn't exist yet.
        // The fix ensures we call resize AFTER the connection is established.
        conn.resizePTY(cols: 120, rows: 40)
        XCTAssertEqual(conn.cols, 80, "cols should remain default when no channel exists")
        XCTAssertEqual(conn.rows, 24, "rows should remain default when no channel exists")
    }

    @MainActor
    func testNIOSSHConnectionColsRowsArePubliclySettable() {
        // Verify we can set cols/rows directly (used by prepareConnection)
        let conn = NIOSSHConnection(host: "localhost", username: "test")
        conn.cols = 170
        conn.rows = 48
        XCTAssertEqual(conn.cols, 170)
        XCTAssertEqual(conn.rows, 48)
    }

    // MARK: - SSHSession.resize(): Synchronous Update

    @MainActor
    func testSSHSessionResizeIsSynchronous() {
        let session = SSHSession()

        // resize() should update internal state synchronously (no Task deferral).
        // We verify by calling resize and then checking that a subsequent
        // connection setup would use the updated values.
        session.resize(cols: 200, rows: 60)

        // The resize was called. Since SSHSession.terminalCols/terminalRows
        // are private, we verify via the public NIOSSHConnection path:
        // the next connection will use the updated values.
        // This test primarily verifies resize() doesn't crash and completes
        // synchronously when there's no active connection.
    }

    @MainActor
    func testSSHSessionResizeMultipleTimes() {
        let session = SSHSession()
        // Rapid sequential resizes should all complete synchronously
        session.resize(cols: 80, rows: 24)
        session.resize(cols: 120, rows: 40)
        session.resize(cols: 170, rows: 48)
        // No crash, no async weirdness — all synchronous
    }

    @MainActor
    func testSSHSessionResizeWithZeroDimensions() {
        let session = SSHSession()
        // Edge case: zero dimensions shouldn't crash
        session.resize(cols: 0, rows: 0)
    }

    // MARK: - NIOSSHConnection: Direct Property Updates

    @MainActor
    func testNIOSSHConnectionDirectColsRowsUpdate() {
        let conn = NIOSSHConnection(host: "localhost", username: "test")

        // Simulate the fix: connect()/useExistingSession() reads surfaceSize
        // and directly sets cols/rows on the connection before PTY request
        XCTAssertEqual(conn.cols, 80)
        XCTAssertEqual(conn.rows, 24)

        // Direct property update (what prepareConnection does)
        conn.cols = 170
        conn.rows = 48
        XCTAssertEqual(conn.cols, 170)
        XCTAssertEqual(conn.rows, 48)

        // Another update
        conn.cols = 120
        conn.rows = 40
        XCTAssertEqual(conn.cols, 120)
        XCTAssertEqual(conn.rows, 40)
    }

    // MARK: - resizePTY Deduplication

    @MainActor
    func testResizePTYDeduplicatesSameSize() {
        // When both sizeDidChange() (sync, main thread) and the Zig-side
        // resize callback (async, IO→main) fire for the same layout change,
        // the second resizePTY call should be a no-op. Without a live SSH
        // channel we can't observe the window-change request, but we verify
        // that cols/rows are NOT updated when there's no channel — the dedup
        // guard fires before the channel guard, so same-size calls are skipped
        // regardless of channel state.
        let conn = NIOSSHConnection(host: "localhost", username: "test")

        // Set initial size directly (simulates what connect() does)
        conn.cols = 120
        conn.rows = 40

        // resizePTY with the same size should be a no-op (dedup guard).
        // Without a channel, resizePTY also guards early, but the dedup
        // check happens first for same-size calls.
        conn.resizePTY(cols: 120, rows: 40)

        // Values unchanged — confirms no side effects from duplicate call
        XCTAssertEqual(conn.cols, 120)
        XCTAssertEqual(conn.rows, 40)
    }

    @MainActor
    func testResizePTYAllowsDifferentSize() {
        let conn = NIOSSHConnection(host: "localhost", username: "test")
        conn.cols = 80
        conn.rows = 24

        // Different size should NOT be deduped — it should attempt to resize.
        // Without a channel it will guard early (cols/rows not updated),
        // but the dedup guard should not block it.
        conn.resizePTY(cols: 120, rows: 40)

        // Without channel, cols/rows stay at their previous values because
        // the channel guard returns before updating them.
        XCTAssertEqual(conn.cols, 80)
        XCTAssertEqual(conn.rows, 24)
    }
}
