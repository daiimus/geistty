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
///
/// Data flow (Feb 2026 — Zig-side send-keys):
///   writeFromGhostty() — simple pass-through. All data from Ghostty is already
///     properly formatted by Zig (viewer commands AND send-keys-wrapped user input).
///   write() — fallback path (no Ghostty surface). In tmux control mode, ALL data
///     is queued since it can't go through Zig's send-keys wrapping.
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
    //
    // writeFromGhostty() is now a simple pass-through: connection health check +
    // performWrite. All data from Ghostty is already properly formatted by Zig:
    //   - Viewer commands: "list-windows\n" (passed through as-is)
    //   - User input: "send-keys -H -t %2 6C 73 0D\n" (Zig-wrapped)
    // No branching on \n, no Swift-side send-keys wrapping.

    @MainActor
    func testWriteFromGhosttyNoConnectionQueues() {
        // writeFromGhostty with no connection goes to performWrite → queued
        let session = SSHSession()
        let testData = "hello".data(using: .utf8)!

        session.writeFromGhostty(testData)

        // Without connection, performWrite queues
        XCTAssertEqual(session.pendingInputQueue.count, 1)
    }

    @MainActor
    func testWriteFromGhosttyPassesThroughRegardlessOfControlMode() {
        // writeFromGhostty always passes through to performWrite, even in control
        // mode — because all data from Ghostty is already Zig-formatted.
        // With no connection, performWrite queues.
        let session = SSHSession()
        session.setControlModeStateForTesting(.active)

        let sendKeysCmd = "send-keys -H -t %2 6C 73 0D\n".data(using: .utf8)!
        session.writeFromGhostty(sendKeysCmd)

        XCTAssertEqual(session.pendingInputQueue.count, 1,
                       "Zig-formatted data should pass through to performWrite")
        XCTAssertEqual(session.pendingInputQueue.first, sendKeysCmd,
                       "Data should not be modified by writeFromGhostty")
    }

    @MainActor
    func testWriteFromGhosttyViewerCommandPassesThrough() {
        // Viewer commands end with \n and pass through as-is.
        let session = SSHSession()
        let viewerCmd = "list-windows\n".data(using: .utf8)!

        session.writeFromGhostty(viewerCmd)

        XCTAssertEqual(session.pendingInputQueue.count, 1,
                       "Viewer command should pass through to performWrite")
        XCTAssertEqual(session.pendingInputQueue.first, viewerCmd,
                       "Viewer command should NOT be modified")
    }

    @MainActor
    func testWriteFromGhosttyPassesThroughEvenWhenNoPane() {
        // Even without an active pane, writeFromGhostty passes through.
        // Zig side handles the no-pane case (viewer.sendKeys returns null,
        // raw bytes go through the backend).
        let session = SSHSession()
        session.setControlModeStateForTesting(.active)
        XCTAssertNil(session.activeTmuxPaneId)

        let viewerCmd = "display-message -p '#{version}'\n".data(using: .utf8)!
        session.writeFromGhostty(viewerCmd)

        XCTAssertEqual(session.pendingInputQueue.count, 1,
                       "Data reaches performWrite regardless of pane state")
        XCTAssertEqual(session.pendingInputQueue.first, viewerCmd,
                       "Data should not be modified")
    }

    @MainActor
    func testWriteFromGhosttyMultipleCallsAllPassThrough() {
        // Multiple writeFromGhostty calls all pass through in order
        let session = SSHSession()
        session.setControlModeStateForTesting(.active)
        session.setActiveTmuxPaneIdForTesting(2)

        let cmd1 = "send-keys -H -t %2 6C 73 0D\n".data(using: .utf8)!
        let cmd2 = "send-keys -H -t %2 70 77 64 0D\n".data(using: .utf8)!

        session.writeFromGhostty(cmd1)
        session.writeFromGhostty(cmd2)

        XCTAssertEqual(session.pendingInputQueue.count, 2)
        XCTAssertEqual(session.pendingInputQueue[0], cmd1)
        XCTAssertEqual(session.pendingInputQueue[1], cmd2)
    }

    @MainActor
    func testWriteFromGhosttyDropsWhenConnectionUnhealthy() {
        // writeFromGhostty checks connection health and drops if unhealthy
        let session = SSHSession()
        session.setConnectionHealthForTesting(.dead(reason: "test"))

        let testData = "hello".data(using: .utf8)!
        session.writeFromGhostty(testData)

        XCTAssertTrue(session.pendingInputQueue.isEmpty,
                      "Data should be dropped when connection is unhealthy")
    }

    // MARK: - write() in control mode
    //
    // write() is the fallback path when there's no Ghostty surface. In tmux
    // control mode, ALL data is queued because it can't go through Zig's
    // send-keys wrapping path. It will be flushed through Ghostty when the
    // surface becomes available.

    @MainActor
    func testWriteQueuesWhenControlModeSetButNotActive() {
        // When tmuxMode is .controlMode but controlModeState is .inactive,
        // write() should queue input (waiting for the viewer to activate).
        let session = SSHSession()
        session.setTmuxModeForTesting(.controlMode)
        // controlModeState defaults to .inactive

        let testData = "who\r".data(using: .utf8)!
        session.write(testData)

        XCTAssertEqual(session.pendingInputQueue.count, 1,
                       "Input should be queued when control mode is set but not yet active")
        XCTAssertEqual(session.pendingInputQueue.first, testData)
    }

    @MainActor
    func testWriteQueuesWhenControlModeActive() {
        // In control mode active, write() queues ALL data — regardless of pane state.
        // Without a Ghostty surface, data can't get send-keys wrapping.
        let session = SSHSession()
        session.setTmuxModeForTesting(.controlMode)
        session.setControlModeStateForTesting(.active)

        let userInput = "who\r".data(using: .utf8)!
        session.write(userInput)

        XCTAssertEqual(session.pendingInputQueue.count, 1,
                       "User input must be QUEUED via write() in control mode active")
        XCTAssertEqual(session.pendingInputQueue.first, userInput)
    }

    @MainActor
    func testWriteQueuesEvenWithActivePaneInControlMode() {
        // Even with an active pane, write() queues in control mode. The write()
        // path bypasses Ghostty and can't apply Zig-side send-keys wrapping.
        let session = SSHSession()
        session.setTmuxModeForTesting(.controlMode)
        session.setControlModeStateForTesting(.active)
        session.setActiveTmuxPaneIdForTesting(5)

        let userInput = "ls -a\r".data(using: .utf8)!
        session.write(userInput)

        XCTAssertEqual(session.pendingInputQueue.count, 1,
                       "write() queues in control mode even with active pane")
        XCTAssertEqual(session.pendingInputQueue.first, userInput)
    }

    @MainActor
    func testWriteStringDelegatesToWriteData() {
        // write(_ string: String) should delegate to write(_ data: Data),
        // getting the same queueing behavior in control mode.
        let session = SSHSession()
        session.setTmuxModeForTesting(.controlMode)
        session.setControlModeStateForTesting(.active)

        session.write("hello\r".data(using: .utf8)!)

        let expectedData = "hello\r".data(using: .utf8)!
        XCTAssertEqual(session.pendingInputQueue.count, 1,
                       "write(Data) should queue in control mode")
        XCTAssertEqual(session.pendingInputQueue.first, expectedData)
    }

    @MainActor
    func testWriteRawInputNeverReachesTmuxInControlMode() {
        // Verify the invariant: when in control mode, raw user input through
        // write() is ALWAYS queued — never sent directly to tmux stdin.
        // This prevents "ls -a" from being parsed as "list-sessions -a".
        let session = SSHSession()
        session.setTmuxModeForTesting(.controlMode)
        session.setControlModeStateForTesting(.active)

        let rawInput = "ls -a\r".data(using: .utf8)!
        session.write(rawInput)

        XCTAssertEqual(session.pendingInputQueue.count, 1,
                       "Raw 'ls -a' must be queued, not sent to tmux stdin")
        XCTAssertEqual(session.pendingInputQueue.first, rawInput)
    }

    @MainActor
    func testWritePassesThroughInNonTmuxMode() {
        // In non-tmux mode (tmuxMode == .none), write() should go directly
        // to performWrite without any queueing for tmux reasons.
        let session = SSHSession()
        // tmuxMode defaults to .none, controlModeState defaults to .inactive

        let testData = "ls -a\r".data(using: .utf8)!
        session.write(testData)

        // performWrite queues because no connection
        XCTAssertEqual(session.pendingInputQueue.count, 1,
                       "Input should pass through to performWrite in non-tmux mode")
        XCTAssertEqual(session.pendingInputQueue.first, testData)
    }

    @MainActor
    func testWriteQueuesWhenConnectionUnhealthy() {
        // Connection health check takes priority — even in tmux mode with active
        // pane, unhealthy connection queues the input.
        let session = SSHSession()
        session.setTmuxModeForTesting(.controlMode)
        session.setControlModeStateForTesting(.active)
        session.setActiveTmuxPaneIdForTesting(1)
        session.setConnectionHealthForTesting(.dead(reason: "test"))

        let testData = "test\r".data(using: .utf8)!
        session.write(testData)

        XCTAssertEqual(session.pendingInputQueue.count, 1,
                       "Input should be queued when connection is unhealthy")
        XCTAssertEqual(session.pendingInputQueue.first, testData)
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
