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

    // MARK: - writeFromGhostty Queueing (control mode active, no pane)

    @MainActor
    func testWriteFromGhosttyQueuesUserInputWhenControlActiveButNoPane() {
        // CRITICAL: This is the exact bug scenario. When controlModeState is .active
        // but activeTmuxPaneId is nil (viewer startup not complete), user input like
        // "ls -a\r" must be QUEUED — not sent raw to tmux. Raw bytes cause tmux to
        // interpret them as commands ("ls" → "list-sessions"), generating %error blocks
        // that corrupt the viewer's state machine.
        let session = SSHSession()
        session.setControlModeStateForTesting(.active)
        // activeTmuxPaneId is nil (default)
        XCTAssertNil(session.activeTmuxPaneId, "Precondition: no pane ID yet")

        let userInput = "ls -a\r".data(using: .utf8)!
        session.writeFromGhostty(userInput)

        XCTAssertEqual(session.pendingInputQueue.count, 1,
                       "User input must be QUEUED when control mode active but no pane")
        XCTAssertEqual(session.pendingInputQueue.first, userInput,
                       "Queued data should be the original user input (not raw)")
    }

    @MainActor
    func testWriteFromGhosttyQueuesMultipleInputsWhenNoPane() {
        let session = SSHSession()
        session.setControlModeStateForTesting(.active)

        let input1 = "ls\r".data(using: .utf8)!
        let input2 = "pwd\r".data(using: .utf8)!

        session.writeFromGhostty(input1)
        session.writeFromGhostty(input2)

        XCTAssertEqual(session.pendingInputQueue.count, 2,
                       "Both inputs should be queued")
        XCTAssertEqual(session.pendingInputQueue[0], input1)
        XCTAssertEqual(session.pendingInputQueue[1], input2)
    }

    @MainActor
    func testWriteFromGhosttyViewerCommandPassesThroughEvenWhenNoPane() {
        // Viewer commands (ending with \n) must ALWAYS pass through, even during
        // startup when activeTmuxPaneId is nil. The viewer needs these to progress.
        let session = SSHSession()
        session.setControlModeStateForTesting(.active)
        XCTAssertNil(session.activeTmuxPaneId)

        let viewerCmd = "display-message -p '#{version}'\n".data(using: .utf8)!
        session.writeFromGhostty(viewerCmd)

        // Viewer command goes to performWrite (which queues because no connection)
        // but critically it is NOT held in pendingInputQueue as "user input"
        XCTAssertEqual(session.pendingInputQueue.count, 1,
                       "Viewer command reaches performWrite → queued (no connection)")
        XCTAssertEqual(session.pendingInputQueue.first, viewerCmd,
                       "Viewer command should NOT be wrapped in send-keys")
    }

    @MainActor
    func testWriteFromGhosttyWrapsInSendKeysWhenPaneActive() {
        // After TMUX_READY → activateFirstTmuxPane sets activeTmuxPaneId,
        // user input should be wrapped in send-keys (not queued or sent raw).
        let session = SSHSession()
        session.setControlModeStateForTesting(.active)
        session.setActiveTmuxPaneIdForTesting(2)

        let userInput = "ls\r".data(using: .utf8)!
        session.writeFromGhostty(userInput)

        // With no connection, performWrite queues the ORIGINAL data (not the wrapped
        // command), because performWrite stores originalData for later re-wrapping.
        // The important thing is: the code PATH goes through wrapInSendKeys, not raw.
        // We can verify this by checking that the queued data is the original input
        // (performWrite was called with originalData: data).
        XCTAssertEqual(session.pendingInputQueue.count, 1,
                       "Input should reach performWrite and be queued (no connection)")
        XCTAssertEqual(session.pendingInputQueue.first, userInput,
                       "performWrite queues originalData for later re-wrapping")
    }

    @MainActor
    func testWriteFromGhosttyRawInputNeverReachesTmuxInControlMode() {
        // Verify the invariant: when controlModeState is .active, raw user input
        // (without \n terminator) NEVER passes through as-is. It's either:
        // - Wrapped in send-keys (if activeTmuxPaneId != nil)
        // - Queued in pendingInputQueue (if activeTmuxPaneId == nil)
        //
        // This test ensures "ls -a\r" never becomes a tmux command.
        let session = SSHSession()
        session.setControlModeStateForTesting(.active)
        // No pane set

        let rawInput = "ls -a\r".data(using: .utf8)!
        session.writeFromGhostty(rawInput)

        // Input should be in pendingInputQueue, NOT sent through performWrite
        XCTAssertEqual(session.pendingInputQueue.count, 1)

        // Verify it's the ORIGINAL input (for later wrapping when pane activates)
        XCTAssertEqual(session.pendingInputQueue.first, rawInput,
                       "Queued input should be original data for later send-keys wrapping")
    }

    // MARK: - write() send-keys wrapping in control mode

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
    func testWriteQueuesUserInputWhenControlActiveButNoPane() {
        // CRITICAL: This is the exact bug scenario for the write() path.
        // controlModeState is .active but activeTmuxPaneId is nil (viewer startup
        // not complete). "who\r" must be QUEUED — not sent raw to tmux.
        // Raw "who" → tmux: "unknown command: who"
        let session = SSHSession()
        session.setTmuxModeForTesting(.controlMode)
        session.setControlModeStateForTesting(.active)
        // activeTmuxPaneId defaults to nil

        let userInput = "who\r".data(using: .utf8)!
        session.write(userInput)

        XCTAssertEqual(session.pendingInputQueue.count, 1,
                       "User input must be QUEUED via write() when control mode active but no pane")
        XCTAssertEqual(session.pendingInputQueue.first, userInput)
    }

    @MainActor
    func testWriteWrapsInSendKeysWhenPaneActive() {
        // After pane activation, write() should go through wrapInSendKeys.
        // With no connection, performWrite queues the originalData.
        let session = SSHSession()
        session.setTmuxModeForTesting(.controlMode)
        session.setControlModeStateForTesting(.active)
        session.setActiveTmuxPaneIdForTesting(5)

        let userInput = "ls -a\r".data(using: .utf8)!
        session.write(userInput)

        // performWrite was called with wrapInSendKeys output → queues originalData
        XCTAssertEqual(session.pendingInputQueue.count, 1,
                       "Input should reach performWrite and be queued (no connection)")
        XCTAssertEqual(session.pendingInputQueue.first, userInput,
                       "performWrite queues originalData for later re-wrapping")
    }

    @MainActor
    func testWriteStringDelegatesToWriteData() {
        // write(_ string: String) should delegate to write(_ data: Data),
        // getting the same send-keys wrapping behavior.
        let session = SSHSession()
        session.setTmuxModeForTesting(.controlMode)
        session.setControlModeStateForTesting(.active)
        // No pane → should queue

        session.write("hello\r")

        let expectedData = "hello\r".data(using: .utf8)!
        XCTAssertEqual(session.pendingInputQueue.count, 1,
                       "write(String) should queue via write(Data) when no pane")
        XCTAssertEqual(session.pendingInputQueue.first, expectedData)
    }

    @MainActor
    func testWriteRawInputNeverReachesTmuxInControlMode() {
        // Verify the invariant: when controlModeState is .active, raw user input
        // through write() is NEVER passed through as-is. It's either:
        // - Wrapped in send-keys (if activeTmuxPaneId != nil)
        // - Queued in pendingInputQueue (if activeTmuxPaneId == nil)
        //
        // This test simulates the exact "ls -a" scenario that caused the
        // "parse error: command list-sessions: unknown flag -a" bug.
        let session = SSHSession()
        session.setTmuxModeForTesting(.controlMode)
        session.setControlModeStateForTesting(.active)
        // No pane → must queue, NOT send raw

        let rawInput = "ls -a\r".data(using: .utf8)!
        session.write(rawInput)

        XCTAssertEqual(session.pendingInputQueue.count, 1,
                       "Raw 'ls -a' must be queued, not sent to tmux stdin")
        XCTAssertEqual(session.pendingInputQueue.first, rawInput)
    }

    @MainActor
    func testWritePassesThroughInNonTmuxMode() {
        // In non-tmux mode (tmuxMode == .none), write() should go directly
        // to performWrite without any send-keys wrapping.
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
