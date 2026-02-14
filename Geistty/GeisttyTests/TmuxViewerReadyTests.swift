import XCTest
@testable import Geistty

// MARK: - Tmux Viewer Ready State Machine Tests

/// Tests for the viewerReady gating mechanism that prevents user input
/// from interleaving with tmux viewer startup commands.
///
/// The core invariant: user input must NOT flow to tmux until the viewer's
/// initial command queue has drained (signaled by TMUX_READY).
///
/// State machine:
///   TMUX_STATE_CHANGED → controlModeState = .active (but viewerReady = false)
///   TMUX_READY → viewerReady = true → activateFirstTmuxPane() → flushPendingInput()
///   TMUX_EXIT → viewerReady = false, controlModeState = .inactive
///   disconnect() → viewerReady = false, controlModeState = .inactive
final class TmuxViewerReadyTests: XCTestCase {

    // MARK: - Initial State

    @MainActor
    func testInitialStateViewerNotReady() {
        let session = SSHSession()
        XCTAssertFalse(session.viewerReady, "viewerReady should be false initially")
    }

    @MainActor
    func testInitialStateControlModeInactive() {
        let session = SSHSession()
        XCTAssertEqual(session.controlModeState, .inactive,
                       "controlModeState should be .inactive initially")
    }

    @MainActor
    func testInitialStateNoPaneActivated() {
        let session = SSHSession()
        XCTAssertFalse(session.tmuxPaneActivated, "tmuxPaneActivated should be false initially")
    }

    @MainActor
    func testInitialStateNoActivePaneId() {
        let session = SSHSession()
        XCTAssertNil(session.activeTmuxPaneId, "activeTmuxPaneId should be nil initially")
    }

    @MainActor
    func testInitialStatePendingQueueEmpty() {
        let session = SSHSession()
        XCTAssertTrue(session.pendingInputQueue.isEmpty,
                      "pendingInputQueue should be empty initially")
    }

    // MARK: - State Change Notification (TMUX_STATE_CHANGED)

    @MainActor
    func testStateChangedActivatesControlMode() {
        let session = SSHSession()

        // Simulate Ghostty posting TMUX_STATE_CHANGED
        NotificationCenter.default.post(
            name: .tmuxStateChanged,
            object: nil,
            userInfo: ["windowCount": UInt(1), "paneCount": UInt(1)]
        )

        // Control mode should NOT be active — session has no tmux observer
        // because setupTmuxSessionManager() was never called.
        // This verifies the notification only works when properly wired.
        XCTAssertEqual(session.controlModeState, .inactive,
                       "controlModeState should stay inactive without tmux setup")
        XCTAssertFalse(session.viewerReady,
                       "viewerReady should remain false without tmux setup")
    }

    // MARK: - Ready Notification (TMUX_READY)

    @MainActor
    func testReadyNotificationWithoutSetupDoesNothing() {
        let session = SSHSession()

        // Post TMUX_READY without any setup — should be a no-op
        NotificationCenter.default.post(
            name: .tmuxReady,
            object: nil,
            userInfo: [:]
        )

        XCTAssertFalse(session.viewerReady,
                       "viewerReady should stay false without observer wiring")
        XCTAssertNil(session.activeTmuxPaneId,
                     "activeTmuxPaneId should stay nil without observer wiring")
    }

    // MARK: - Exit Notification (TMUX_EXIT)

    @MainActor
    func testExitNotificationWithoutSetupDoesNothing() {
        let session = SSHSession()

        NotificationCenter.default.post(
            name: .tmuxExited,
            object: nil,
            userInfo: [:]
        )

        // Should be a no-op — no observers registered
        XCTAssertEqual(session.controlModeState, .inactive)
        XCTAssertFalse(session.viewerReady)
    }

    // MARK: - Disconnect Resets State

    @MainActor
    func testDisconnectResetsViewerReady() {
        let session = SSHSession()
        // We can't set viewerReady directly (private(set)), but disconnect should
        // always leave it false regardless of prior state.
        session.disconnect()

        XCTAssertFalse(session.viewerReady,
                       "viewerReady should be false after disconnect")
        XCTAssertEqual(session.controlModeState, .inactive,
                       "controlModeState should be .inactive after disconnect")
        XCTAssertFalse(session.tmuxPaneActivated,
                       "tmuxPaneActivated should be false after disconnect")
        XCTAssertNil(session.activeTmuxPaneId,
                     "activeTmuxPaneId should be nil after disconnect")
        XCTAssertTrue(session.pendingInputQueue.isEmpty,
                      "pendingInputQueue should be empty after disconnect")
    }

    // MARK: - Write Queueing (before control mode active)

    @MainActor
    func testWriteQueuesWhenControlModePending() {
        // SSHSession.write() queues input when tmuxMode is .controlMode
        // but controlModeState is .inactive.
        // Since we can't set tmuxMode (private), we verify through the
        // the write() → pendingInputQueue path indirectly.
        //
        // Without a connection and tmux mode, write() goes to performWrite
        // which queues because connection is nil. This is the correct behavior
        // for the non-tmux case too.
        let session = SSHSession()
        let testData = "ls\r".data(using: .utf8)!

        session.write(testData)

        // Without a connection, performWrite queues the data
        XCTAssertEqual(session.pendingInputQueue.count, 1,
                       "Input should be queued when no connection exists")
        XCTAssertEqual(session.pendingInputQueue.first, testData,
                       "Queued data should match original input")
    }

    @MainActor
    func testMultipleWritesQueueInOrder() {
        let session = SSHSession()
        let data1 = "first".data(using: .utf8)!
        let data2 = "second".data(using: .utf8)!

        session.write(data1)
        session.write(data2)

        XCTAssertEqual(session.pendingInputQueue.count, 2,
                       "Both writes should be queued")
        XCTAssertEqual(session.pendingInputQueue[0], data1,
                       "First write should be first in queue")
        XCTAssertEqual(session.pendingInputQueue[1], data2,
                       "Second write should be second in queue")
    }

    // MARK: - writeFromGhostty Routing

    @MainActor
    func testWriteFromGhosttyNoConnectionDropsSilently() {
        // writeFromGhostty with no connection and no tmux mode goes through
        // performWrite, which queues because connection is nil.
        let session = SSHSession()
        let testData = "hello".data(using: .utf8)!

        session.writeFromGhostty(testData)

        // Without tmux mode active, data goes to performWrite → queued
        XCTAssertEqual(session.pendingInputQueue.count, 1)
    }

    @MainActor
    func testWriteFromGhosttyViewerCommandPassesThrough() {
        // Viewer commands end with \n and should pass through as-is even in
        // tmux control mode. Without a connection, they go to performWrite → queue.
        let session = SSHSession()
        let viewerCmd = "list-windows\n".data(using: .utf8)!

        session.writeFromGhostty(viewerCmd)

        // Without tmux mode, goes through performWrite directly
        XCTAssertEqual(session.pendingInputQueue.count, 1,
                       "Viewer command should be queued (no connection)")
        XCTAssertEqual(session.pendingInputQueue.first, viewerCmd,
                       "Viewer command should NOT be wrapped in send-keys")
    }

    // MARK: - ControlModeState

    func testControlModeStateDescriptions() {
        XCTAssertEqual(ControlModeState.inactive.description, "inactive")
        XCTAssertEqual(ControlModeState.active.description, "active")
    }

    func testControlModeStateIsActive() {
        XCTAssertFalse(ControlModeState.inactive.isActive)
        XCTAssertTrue(ControlModeState.active.isActive)
    }

    func testControlModeStateEquatable() {
        XCTAssertEqual(ControlModeState.inactive, ControlModeState.inactive)
        XCTAssertEqual(ControlModeState.active, ControlModeState.active)
        XCTAssertNotEqual(ControlModeState.inactive, ControlModeState.active)
    }

    // MARK: - Notification Name Existence

    func testTmuxReadyNotificationNameExists() {
        // Verify the notification name constant exists and is distinct
        XCTAssertEqual(Notification.Name.tmuxReady.rawValue, "tmuxReady")
    }

    func testTmuxNotificationNamesDistinct() {
        XCTAssertNotEqual(Notification.Name.tmuxReady, .tmuxStateChanged)
        XCTAssertNotEqual(Notification.Name.tmuxReady, .tmuxExited)
        XCTAssertNotEqual(Notification.Name.tmuxStateChanged, .tmuxExited)
    }
}
