import XCTest
@testable import Geistty

// MARK: - Resize Timing Tests
//
// Tests for the terminal resize data flow from UIKit layout through to SSH.
//
// The resize path is:
//   layoutSubviews → sizeDidChange → onResize → TerminalViewModel.resize()
//     → SSHSession.resize() → NIOSSHConnection.resizePTY() → SSH window-change
//
// Problem: layoutSubviews fires BEFORE viewDidAppear sets sshSession, so the
// first real resize is dropped. The fix has two parts:
//
//   1. TerminalViewModel stores a pendingResize when sshSession is nil, and
//      flushes it in useExistingSession() once the session is wired up.
//
//   2. NIOSSHConnection.resizePTY() always updates stored cols/rows (even
//      without a channel), following Ghostty's External.zig pattern where
//      internal state is updated unconditionally before invoking the callback.
//      The old dedup guard was removed because it could block the initial
//      resize (80x24 → 80x24 after channel guard stored stale values).

final class ResizeTimingTests: XCTestCase {

    // MARK: - NIOSSHConnection Defaults

    @MainActor
    func testNIOSSHConnectionDefaultSize() {
        let conn = NIOSSHConnection(host: "localhost", username: "test")
        XCTAssertEqual(conn.cols, 80, "Default cols should be 80")
        XCTAssertEqual(conn.rows, 24, "Default rows should be 24")
    }

    // MARK: - NIOSSHConnection.resizePTY: Always Updates State

    @MainActor
    func testResizePTYUpdatesStateWithoutChannel() {
        // Following External.zig pattern: internal state is always updated,
        // even when there's no channel to send the window-change to.
        // This ensures cols/rows are correct for when the channel appears.
        let conn = NIOSSHConnection(host: "localhost", username: "test")
        conn.resizePTY(cols: 120, rows: 40)
        XCTAssertEqual(conn.cols, 120, "cols should be updated even without channel")
        XCTAssertEqual(conn.rows, 40, "rows should be updated even without channel")
    }

    @MainActor
    func testResizePTYUpdatesStateWithSameValues() {
        // No dedup guard — calling with same values still updates state.
        // This is safe because a redundant SSH window-change is harmless,
        // but a missed one causes the 80x24 bug.
        let conn = NIOSSHConnection(host: "localhost", username: "test")
        conn.cols = 120
        conn.rows = 40
        conn.resizePTY(cols: 120, rows: 40)
        XCTAssertEqual(conn.cols, 120)
        XCTAssertEqual(conn.rows, 40)
    }

    @MainActor
    func testResizePTYSequentialUpdates() {
        // Multiple resizes should each update stored state
        let conn = NIOSSHConnection(host: "localhost", username: "test")
        conn.resizePTY(cols: 80, rows: 24)
        XCTAssertEqual(conn.cols, 80)
        XCTAssertEqual(conn.rows, 24)

        conn.resizePTY(cols: 120, rows: 40)
        XCTAssertEqual(conn.cols, 120)
        XCTAssertEqual(conn.rows, 40)

        conn.resizePTY(cols: 170, rows: 48)
        XCTAssertEqual(conn.cols, 170)
        XCTAssertEqual(conn.rows, 48)
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
        session.resize(cols: 200, rows: 60)
        // Primarily verifies resize() doesn't crash and completes
        // synchronously when there's no active connection.
    }

    @MainActor
    func testSSHSessionResizeMultipleTimes() {
        let session = SSHSession()
        // Rapid sequential resizes should all complete synchronously
        session.resize(cols: 80, rows: 24)
        session.resize(cols: 120, rows: 40)
        session.resize(cols: 170, rows: 48)
    }

    @MainActor
    func testSSHSessionResizeWithZeroDimensions() {
        let session = SSHSession()
        // Edge case: zero dimensions shouldn't crash
        session.resize(cols: 0, rows: 0)
    }

    // MARK: - TerminalViewModel: Pending Resize Mechanism

    @MainActor
    func testResizeWithNoSessionStoresPending() {
        // When resize() is called before sshSession is set (the normal case
        // during UIKit layout), the resize should be stored as pending.
        let vm = TerminalViewModel()
        XCTAssertNil(vm.pendingResize, "No pending resize initially")

        vm.resize(cols: 122, rows: 68)
        XCTAssertNotNil(vm.pendingResize, "Pending resize should be stored")
        XCTAssertEqual(vm.pendingResize?.cols, 122)
        XCTAssertEqual(vm.pendingResize?.rows, 68)
    }

    @MainActor
    func testResizeWithNoSessionUpdatesOnSubsequentCalls() {
        // Multiple resizes before session is set should keep the latest
        let vm = TerminalViewModel()

        vm.resize(cols: 80, rows: 24)
        XCTAssertEqual(vm.pendingResize?.cols, 80)
        XCTAssertEqual(vm.pendingResize?.rows, 24)

        vm.resize(cols: 122, rows: 68)
        XCTAssertEqual(vm.pendingResize?.cols, 122)
        XCTAssertEqual(vm.pendingResize?.rows, 68)
    }

    @MainActor
    func testUseExistingSessionFlushesPendingResize() {
        // This is the core test for the fix:
        // 1. Layout fires resize(122, 68) → stored as pending (sshSession nil)
        // 2. useExistingSession() wires the session → flushes pending
        // 3. SSHSession receives resize(122, 68)
        let vm = TerminalViewModel()
        let session = SSHSession()

        // Step 1: simulate layout resize before session
        vm.resize(cols: 122, rows: 68)
        XCTAssertNotNil(vm.pendingResize)

        // Step 2: wire up session (simulates viewDidAppear → setupConnection)
        vm.useExistingSession(session)

        // Step 3: pending should be flushed
        XCTAssertNil(vm.pendingResize, "Pending resize should be cleared after flush")
    }

    @MainActor
    func testResizeAfterSessionIsSetDoesNotStorePending() {
        // Once sshSession is set, resize() should forward directly, not store
        let vm = TerminalViewModel()
        let session = SSHSession()
        vm.useExistingSession(session)

        vm.resize(cols: 150, rows: 50)
        XCTAssertNil(vm.pendingResize, "Should not store pending when session exists")
    }

    @MainActor
    func testUseExistingSessionWithNoPendingUsesDefaults() {
        // If no layout resize fired before session (unlikely but possible),
        // useExistingSession should still call resize with current dims
        let vm = TerminalViewModel()
        let session = SSHSession()

        XCTAssertNil(vm.pendingResize)
        vm.useExistingSession(session)
        // No crash, session gets default 80x24 or surfaceSize fallback
    }

    // MARK: - NIOSSHConnection: Direct Property Updates

    @MainActor
    func testNIOSSHConnectionDirectColsRowsUpdate() {
        let conn = NIOSSHConnection(host: "localhost", username: "test")

        XCTAssertEqual(conn.cols, 80)
        XCTAssertEqual(conn.rows, 24)

        conn.cols = 170
        conn.rows = 48
        XCTAssertEqual(conn.cols, 170)
        XCTAssertEqual(conn.rows, 48)

        conn.cols = 120
        conn.rows = 40
        XCTAssertEqual(conn.cols, 120)
        XCTAssertEqual(conn.rows, 40)
    }
}
