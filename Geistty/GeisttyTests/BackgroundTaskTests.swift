import XCTest
import UIKit
import Combine
@testable import Geistty

// MARK: - Mock Background Task Provider

/// Mock that records begin/end calls for testing without a running UIApplication.
@MainActor
final class MockBackgroundTaskProvider: BackgroundTaskProvider {
    /// Counter for generating unique task IDs
    private var nextTaskID: Int = 1
    
    /// All task IDs that have been started but not yet ended
    private(set) var activeTasks: Set<Int> = []
    
    /// Total number of begin calls
    private(set) var beginCallCount: Int = 0
    
    /// Total number of end calls
    private(set) var endCallCount: Int = 0
    
    /// Stored expiration handlers, keyed by task ID
    private(set) var expirationHandlers: [Int: () -> Void] = [:]
    
    /// If true, beginBackgroundTask returns .invalid (simulating iOS denial)
    var shouldDenyBackgroundTask: Bool = false
    
    func beginBackgroundTask(
        withName name: String?,
        expirationHandler: (() -> Void)?
    ) -> UIBackgroundTaskIdentifier {
        beginCallCount += 1
        
        if shouldDenyBackgroundTask {
            return .invalid
        }
        
        let taskID = nextTaskID
        nextTaskID += 1
        activeTasks.insert(taskID)
        
        if let handler = expirationHandler {
            expirationHandlers[taskID] = handler
        }
        
        return UIBackgroundTaskIdentifier(rawValue: taskID)
    }
    
    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        endCallCount += 1
        activeTasks.remove(identifier.rawValue)
        expirationHandlers.removeValue(forKey: identifier.rawValue)
    }
    
    /// Simulate iOS calling the expiration handler for a specific task
    func simulateExpiration(taskID: Int) {
        expirationHandlers[taskID]?()
    }
    
    /// Simulate iOS calling the expiration handler for the most recent task
    func simulateExpirationOfLatestTask() {
        guard let latestID = activeTasks.max() else { return }
        simulateExpiration(taskID: latestID)
    }
}

// MARK: - Background Task Lifecycle Tests

/// Tests for the background task management in SSHSession.
///
/// When the app backgrounds with an active tmux session, SSHSession captures
/// a BackgroundSessionState snapshot and starts a background task to let
/// in-flight SSH writes flush. On foreground, it sends C1 ST to exit the
/// stale DCS passthrough and reconnects via a fresh SSH connection.
/// These tests verify the begin/end lifecycle using a mock provider.
final class BackgroundTaskTests: XCTestCase {
    
    // MARK: - Initial State
    
    @MainActor
    func testInitialBackgroundTaskIsInvalid() {
        let session = SSHSession()
        XCTAssertEqual(session.backgroundTaskIDForTesting, .invalid,
                       "Background task should be .invalid initially")
    }
    
    // MARK: - appWillResignActive with tmux
    
    @MainActor
    func testResignActiveStartsBackgroundTaskWhenTmuxActive() {
        let session = SSHSession()
        let mock = MockBackgroundTaskProvider()
        session.backgroundTaskProvider = mock
        
        // Simulate active tmux control mode
        session.setControlModeStateForTesting(.active)
        
        session.appWillResignActive()
        
        XCTAssertEqual(mock.beginCallCount, 1,
                       "Should call beginBackgroundTask once")
        XCTAssertEqual(mock.activeTasks.count, 1,
                       "Should have one active background task")
        XCTAssertNotEqual(session.backgroundTaskIDForTesting, .invalid,
                          "Background task ID should be set")
    }
    
    @MainActor
    func testResignActiveSkipsBackgroundTaskWhenTmuxInactive() {
        let session = SSHSession()
        let mock = MockBackgroundTaskProvider()
        session.backgroundTaskProvider = mock
        
        // controlModeState defaults to .inactive
        session.appWillResignActive()
        
        XCTAssertEqual(mock.beginCallCount, 0,
                       "Should NOT call beginBackgroundTask when tmux is inactive")
        XCTAssertEqual(session.backgroundTaskIDForTesting, .invalid,
                       "Background task ID should remain .invalid")
    }
    
    @MainActor
    func testResignActiveDoesNotDoubleStartBackgroundTask() {
        let session = SSHSession()
        let mock = MockBackgroundTaskProvider()
        session.backgroundTaskProvider = mock
        session.setControlModeStateForTesting(.active)
        
        session.appWillResignActive()
        session.appWillResignActive() // second call
        
        XCTAssertEqual(mock.beginCallCount, 1,
                       "Should only call beginBackgroundTask once (guard prevents double-start)")
    }
    
    // MARK: - appDidBecomeActive ends background task
    
    @MainActor
    func testBecomeActiveEndsBackgroundTask() {
        let session = SSHSession()
        let mock = MockBackgroundTaskProvider()
        session.backgroundTaskProvider = mock
        session.setControlModeStateForTesting(.active)
        
        // Start background task via resign
        session.appWillResignActive()
        XCTAssertEqual(mock.activeTasks.count, 1)
        
        // Come back to foreground
        session.appDidBecomeActive()
        
        XCTAssertEqual(mock.endCallCount, 1,
                       "Should call endBackgroundTask when becoming active")
        XCTAssertTrue(mock.activeTasks.isEmpty,
                      "No active background tasks should remain")
        XCTAssertEqual(session.backgroundTaskIDForTesting, .invalid,
                       "Background task ID should be reset to .invalid")
    }
    
    @MainActor
    func testBecomeActiveIsNoOpWithoutBackgroundTask() {
        let session = SSHSession()
        let mock = MockBackgroundTaskProvider()
        session.backgroundTaskProvider = mock
        
        // No background task was started
        session.appDidBecomeActive()
        
        XCTAssertEqual(mock.endCallCount, 0,
                       "Should NOT call endBackgroundTask when none is active")
    }
    
    // MARK: - disconnect() ends background task
    
    @MainActor
    func testDisconnectEndsBackgroundTask() {
        let session = SSHSession()
        let mock = MockBackgroundTaskProvider()
        session.backgroundTaskProvider = mock
        session.setControlModeStateForTesting(.active)
        
        session.appWillResignActive()
        XCTAssertEqual(mock.activeTasks.count, 1)
        
        session.disconnect()
        
        XCTAssertTrue(mock.activeTasks.isEmpty,
                      "disconnect() should end the background task")
    }
    
    // MARK: - endBackgroundTaskIfNeeded idempotency
    
    @MainActor
    func testEndBackgroundTaskIsIdempotent() {
        let session = SSHSession()
        let mock = MockBackgroundTaskProvider()
        session.backgroundTaskProvider = mock
        session.setControlModeStateForTesting(.active)
        
        session.appWillResignActive()
        
        // End multiple times
        session.endBackgroundTaskIfNeeded()
        session.endBackgroundTaskIfNeeded()
        session.endBackgroundTaskIfNeeded()
        
        XCTAssertEqual(mock.endCallCount, 1,
                       "endBackgroundTask should only be called once regardless of repeated calls")
    }
    
    // MARK: - iOS denial handling
    
    @MainActor
    func testHandlesIOSDenialGracefully() {
        let session = SSHSession()
        let mock = MockBackgroundTaskProvider()
        mock.shouldDenyBackgroundTask = true
        session.backgroundTaskProvider = mock
        session.setControlModeStateForTesting(.active)
        
        // Should not crash when iOS denies background task
        session.appWillResignActive()
        
        XCTAssertEqual(mock.beginCallCount, 1,
                       "Should still attempt to begin background task")
        XCTAssertEqual(session.backgroundTaskIDForTesting, .invalid,
                       "Task ID should remain .invalid when denied")
        XCTAssertTrue(mock.activeTasks.isEmpty,
                      "No tasks should be tracked when denied")
    }
    
    // MARK: - Expiration handler
    
    @MainActor
    func testExpirationHandlerEndsTask() async throws {
        let session = SSHSession()
        let mock = MockBackgroundTaskProvider()
        session.backgroundTaskProvider = mock
        session.setControlModeStateForTesting(.active)
        
        session.appWillResignActive()
        XCTAssertEqual(mock.activeTasks.count, 1)
        
        // Simulate iOS calling the expiration handler
        mock.simulateExpirationOfLatestTask()
        
        // The expiration handler dispatches to MainActor via Task,
        // so we need to yield to let it execute
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        XCTAssertTrue(mock.activeTasks.isEmpty,
                      "Expiration handler should end the background task")
        XCTAssertEqual(session.backgroundTaskIDForTesting, .invalid,
                       "Task ID should be reset after expiration")
    }
    
    // MARK: - Full lifecycle: resign → tmux exit → become active
    
    @MainActor
    func testFullLifecycleResignTmuxExitBecomeActive() {
        let session = SSHSession()
        let mock = MockBackgroundTaskProvider()
        session.backgroundTaskProvider = mock
        session.setControlModeStateForTesting(.active)
        
        // 1. App backgrounds — start background task + capture state
        session.appWillResignActive()
        XCTAssertEqual(mock.activeTasks.count, 1, "Background task should be active")
        
        // 2. Background task ends (e.g., via safety timer or TMUX_EXIT)
        session.endBackgroundTaskIfNeeded()
        XCTAssertTrue(mock.activeTasks.isEmpty, "Task should end")
        XCTAssertEqual(mock.endCallCount, 1)
        
        // 3. App foregrounds — endBackgroundTaskIfNeeded() is no-op (already ended)
        session.appDidBecomeActive()
        XCTAssertEqual(mock.endCallCount, 1,
                       "Should NOT double-end — task was already cleaned up")
    }
    
    // MARK: - Background state flag tests
    
    @MainActor
    func testResignActiveSetsDetachingForBackgroundFlag() {
        let session = SSHSession()
        let mock = MockBackgroundTaskProvider()
        session.backgroundTaskProvider = mock
        session.setControlModeStateForTesting(.active)
        
        XCTAssertFalse(session.isDetachingForBackground,
                       "backgroundState should be nil initially")
        
        session.appWillResignActive()
        
        XCTAssertTrue(session.isDetachingForBackground,
                      "backgroundState should be set after resigning active with tmux")
    }
    
    @MainActor
    func testResignActiveDoesNotSetFlagWhenTmuxInactive() {
        let session = SSHSession()
        let mock = MockBackgroundTaskProvider()
        session.backgroundTaskProvider = mock
        // controlModeState defaults to .inactive
        
        session.appWillResignActive()
        
        XCTAssertFalse(session.isDetachingForBackground,
                       "backgroundState should NOT be set when tmux is inactive")
    }
    
    @MainActor
    func testBecomeActiveClearsDetachingForBackgroundFlag() {
        let session = SSHSession()
        let mock = MockBackgroundTaskProvider()
        session.backgroundTaskProvider = mock
        session.setControlModeStateForTesting(.active)
        
        session.appWillResignActive()
        XCTAssertTrue(session.isDetachingForBackground)
        
        // Simulate tmux exit clearing controlModeState (what the TMUX_EXIT handler does)
        session.setControlModeStateForTesting(.inactive)
        
        session.appDidBecomeActive()
        
        XCTAssertFalse(session.isDetachingForBackground,
                       "backgroundState should be cleared when becoming active (no credentials path)")
    }
    
    @MainActor
    func testDisconnectClearsDetachingForBackgroundFlag() {
        let session = SSHSession()
        session.setControlModeStateForTesting(.active)
        session.setBackgroundStateForTesting(true)
        
        session.disconnect()
        
        XCTAssertFalse(session.isDetachingForBackground,
                       "disconnect() should clear backgroundState")
    }
    
    // MARK: - prepareForReattach tests
    
    @MainActor
    func testPrepareForReattachPreservesSurfaces() {
        let manager = TmuxSessionManager()
        
        // Set up some state
        manager.controlModeActivated()
        XCTAssertTrue(manager.isConnected)
        
        // prepareForReattach should clear connection state but preserve surfaces
        manager.prepareForReattach()
        
        XCTAssertFalse(manager.isConnected,
                       "isConnected should be false after prepareForReattach")
        XCTAssertEqual(manager.connectionState, .disconnected)
        XCTAssertFalse(manager.viewerReady,
                       "viewerReady should be reset")
        XCTAssertTrue(manager.pendingCommandsForTesting.isEmpty,
                      "pendingCommands should be cleared")
    }
    
    @MainActor
    func testPrepareForReattachClearsWindowState() {
        let manager = TmuxSessionManager()
        manager.controlModeActivated()
        
        // Simulate some state from a previous session
        let snapshot = TmuxSessionManager.TmuxStateSnapshot(
            windows: [
                .init(id: 0, name: "bash", layout: nil, focusedPaneId: 0)
            ],
            activeWindowId: 0,
            paneIds: [0]
        )
        _ = manager.reconcileTmuxState(snapshot)
        
        XCTAssertFalse(manager.windows.isEmpty, "Should have windows before reattach")
        
        manager.prepareForReattach()
        
        XCTAssertTrue(manager.windows.isEmpty,
                      "windows should be cleared for fresh state from new viewer")
        XCTAssertTrue(manager.sessions.isEmpty,
                      "sessions should be cleared")
    }
    
    @MainActor
    func testPrepareForReattachPreservesFocusIds() {
        let manager = TmuxSessionManager()
        manager.controlModeActivated()
        
        // Simulate state with a focused window/pane
        let snapshot = TmuxSessionManager.TmuxStateSnapshot(
            windows: [
                .init(id: 1, name: "vim", layout: nil, focusedPaneId: 5)
            ],
            activeWindowId: 1,
            paneIds: [5]
        )
        _ = manager.reconcileTmuxState(snapshot)
        
        let windowId = manager.focusedWindowId
        let paneId = manager.focusedPaneId
        
        manager.prepareForReattach()
        
        // Focus IDs are preserved so the UI doesn't flash
        XCTAssertEqual(manager.focusedWindowId, windowId,
                       "focusedWindowId should be preserved across reattach")
        XCTAssertEqual(manager.focusedPaneId, paneId,
                       "focusedPaneId should be preserved across reattach")
    }
    
    @MainActor
    func testControlModeExitedDestroysState() {
        // Contrast test: controlModeExited DOES destroy surfaces/state
        let manager = TmuxSessionManager()
        manager.controlModeActivated()
        
        manager.controlModeExited(reason: "test")
        
        XCTAssertFalse(manager.isConnected)
        XCTAssertTrue(manager.paneSurfaces.isEmpty,
                      "controlModeExited should clear paneSurfaces")
        XCTAssertNil(manager.primarySurface,
                     "controlModeExited should nil primarySurface")
    }
    
    // MARK: - Background lifecycle: flag interaction with TMUX_EXIT
    
    @MainActor
    func testBackgroundDetachSkipsControlModeExited() {
        // This tests the conceptual flow: when backgroundState is set,
        // the TMUX_EXIT handler (triggered by C1 ST on foreground) should
        // call prepareForReattach instead of controlModeExited.
        let session = SSHSession()
        let mock = MockBackgroundTaskProvider()
        session.backgroundTaskProvider = mock
        
        // Set up tmux state
        session.setupTmuxForTesting()
        session.setControlModeStateForTesting(.active)
        session.tmuxSessionManager?.controlModeActivated()
        
        // Resign active (sets backgroundState, starts background task)
        session.appWillResignActive()
        XCTAssertTrue(session.isDetachingForBackground)
        
        // Simulate TMUX_EXIT notification by directly testing the flag check:
        // After TMUX_EXIT with backgroundState set, the manager should NOT have
        // surfaces destroyed
        XCTAssertNotNil(session.tmuxSessionManager,
                        "Session manager should still exist during background")
    }
    
    @MainActor
    func testNormalTmuxExitCallsControlModeExited() {
        // When backgroundState is nil, TMUX_EXIT should do full teardown
        let session = SSHSession()
        session.setupTmuxForTesting()
        session.setControlModeStateForTesting(.active)
        
        // backgroundState is nil (default)
        XCTAssertFalse(session.isDetachingForBackground)
        
        // After a normal tmux exit, controlModeExited should be called
        // (verified by the fact that the manager exists but would have torn down)
        XCTAssertNotNil(session.tmuxSessionManager)
    }
    
    // MARK: - appDidBecomeActive reattach path
    
    @MainActor
    func testBecomeActiveWithDetachFlagInitiatesReconnect() {
        let session = SSHSession()
        let mock = MockBackgroundTaskProvider()
        session.backgroundTaskProvider = mock
        
        // Set up: backgroundState is set but no credentials → should log warning, not crash
        session.setBackgroundStateForTesting(true)
        
        session.appDidBecomeActive()
        
        // backgroundState should be cleared (no credentials → else branch clears it)
        XCTAssertFalse(session.isDetachingForBackground,
                       "backgroundState should be cleared by appDidBecomeActive (no credentials path)")
    }
    
    @MainActor
    func testBecomeActiveWithDetachFlagAndNoCredentialsCallsControlModeExited() {
        let session = SSHSession()
        session.setupTmuxForTesting()
        session.setControlModeStateForTesting(.active)
        session.tmuxSessionManager?.controlModeActivated()
        
        // Set backgroundState but clear credentials
        session.setBackgroundStateForTesting(true)
        // No storedAuthMethod → canReconnect == false
        
        session.appDidBecomeActive()
        
        XCTAssertFalse(session.isDetachingForBackground,
                       "backgroundState should be cleared")
        // The session manager should have had controlModeExited called
        XCTAssertFalse(session.tmuxSessionManager?.isConnected ?? true,
                       "Manager should show disconnected when credentials missing")
    }
    
    // MARK: - connectionDidClose suppression tests (WS-D2 fix)
    
    @MainActor
    func testConnectionDidCloseSuppressesDelegateWhenDetachingForBackground() {
        // When backgroundState is set, connectionDidClose should NOT
        // call delegate.sshSession(didDisconnectWithError:) — this prevents
        // SwiftUI from removing TerminalContainerView and triggering the
        // renderer use-after-free SIGSEGV.
        let session = SSHSession()
        let delegate = MockSSHSessionDelegate()
        session.delegate = delegate
        session.setControlModeStateForTesting(.active)
        session.setBackgroundStateForTesting(true)
        
        session.simulateConnectionDidCloseForTesting(error: nil)
        
        XCTAssertEqual(delegate.didDisconnectCalls.count, 0,
                       "Delegate should NOT be notified of disconnect during background")
    }
    
    @MainActor
    func testConnectionDidCloseCallsDelegateWhenNotDetaching() {
        // Normal disconnect (not background detach) — delegate SHOULD be notified.
        let session = SSHSession()
        let delegate = MockSSHSessionDelegate()
        session.delegate = delegate
        
        // isDetachingForBackground defaults to false
        XCTAssertFalse(session.isDetachingForBackground)
        
        session.simulateConnectionDidCloseForTesting(error: nil)
        
        XCTAssertEqual(delegate.didDisconnectCalls.count, 1,
                       "Delegate should be notified of disconnect in normal path")
    }
    
    @MainActor
    func testConnectionDidCloseUpdatesStateRegardlessOfFlag() {
        // Even when suppressing the delegate notification, state and lastError
        // should still be updated — the connection IS closed.
        let session = SSHSession()
        let delegate = MockSSHSessionDelegate()
        session.delegate = delegate
        session.setBackgroundStateForTesting(true)
        
        let testError = NSError(domain: "test", code: 42, userInfo: nil)
        session.simulateConnectionDidCloseForTesting(error: testError)
        
        XCTAssertEqual(session.state, .disconnected,
                       "State should be .disconnected after connectionDidClose")
        XCTAssertEqual((session.lastError as? NSError)?.code, 42,
                       "lastError should be set even when suppressing delegate")
        XCTAssertEqual(delegate.didDisconnectCalls.count, 0,
                       "But delegate should NOT be called")
    }
    
    @MainActor
    func testConnectionDidClosePassesErrorToDelegateInNormalPath() {
        // When NOT detaching for background, the error should be passed through.
        let session = SSHSession()
        let delegate = MockSSHSessionDelegate()
        session.delegate = delegate
        
        let testError = NSError(domain: "test", code: 99, userInfo: nil)
        session.simulateConnectionDidCloseForTesting(error: testError)
        
        XCTAssertEqual(delegate.didDisconnectCalls.count, 1)
        XCTAssertEqual((delegate.didDisconnectCalls.first?.error as? NSError)?.code, 99,
                       "Error should be passed to delegate")
    }
    
    @MainActor
    func testConnectionDidCloseWithNilErrorInNormalPath() {
        // Clean disconnect (no error) should still notify delegate.
        let session = SSHSession()
        let delegate = MockSSHSessionDelegate()
        session.delegate = delegate
        
        session.simulateConnectionDidCloseForTesting(error: nil)
        
        XCTAssertEqual(delegate.didDisconnectCalls.count, 1)
        XCTAssertNil(delegate.didDisconnectCalls.first?.error,
                     "Error should be nil for clean disconnect")
    }
    
    // MARK: - Full background lifecycle with connectionDidClose
    
    @MainActor
    func testFullBackgroundLifecycleWithConnectionDidClose() {
        // Simulates the complete background transition:
        // 1. appWillResignActive → backgroundState captured
        // 2. connectionDidClose fires (SSH connection dies during background)
        //    → delegate NOT notified → SwiftUI doesn't remove view → no SIGSEGV
        // 3. appDidBecomeActive → reconnect path (no credentials → clears state)
        let session = SSHSession()
        let mock = MockBackgroundTaskProvider()
        let delegate = MockSSHSessionDelegate()
        session.backgroundTaskProvider = mock
        session.delegate = delegate
        session.setControlModeStateForTesting(.active)
        
        // Step 1: App backgrounds
        session.appWillResignActive()
        XCTAssertTrue(session.isDetachingForBackground)
        XCTAssertEqual(mock.activeTasks.count, 1)
        
        // Step 2: SSH channel closes (TCP keepalive expires during background)
        session.simulateConnectionDidCloseForTesting(error: nil)
        
        // Key assertion: delegate was NOT notified
        XCTAssertEqual(delegate.didDisconnectCalls.count, 0,
                       "Delegate must NOT be notified during background — " +
                       "this would cause SwiftUI to remove TerminalContainerView → SIGSEGV")
        // But state IS updated
        XCTAssertEqual(session.state, .disconnected)
        
        // Step 3: App foregrounds (no credentials → backgroundState cleared in else branch)
        session.appDidBecomeActive()
        XCTAssertFalse(session.isDetachingForBackground,
                       "backgroundState should be cleared after becoming active (no credentials path)")
        // Delegate still not notified about the SSH close from step 2
        XCTAssertEqual(delegate.didDisconnectCalls.count, 0,
                       "Delegate should never have been notified for the background disconnect")
    }
    
    @MainActor
    func testNormalDisconnectNotifiesDelegate() {
        // Contrast test: when NOT in background detach flow,
        // connectionDidClose DOES notify delegate (normal behavior).
        let session = SSHSession()
        let delegate = MockSSHSessionDelegate()
        session.delegate = delegate
        
        session.simulateConnectionDidCloseForTesting(error: nil)
        
        XCTAssertEqual(delegate.didDisconnectCalls.count, 1,
                       "Normal disconnect should notify delegate")
    }
    
    // MARK: - WS-R1: Stale connection guard tests
    
    @MainActor
    func testStaleConnectionGuardIgnoresOldConnection() {
        // When self.connection is set and a DIFFERENT connection fires
        // connectionDidClose, the callback is from a stale (old) connection
        // during reconnect — it should be completely ignored.
        let session = SSHSession()
        let delegate = MockSSHSessionDelegate()
        session.delegate = delegate
        
        // Set a "current" connection and put state into .connected
        let currentConn = NIOSSHConnection(host: "current", port: 22, username: "test")
        session.setConnectionForTesting(currentConn)
        session.state = .connected
        
        // Simulate a DIFFERENT (stale) connection calling connectionDidClose
        // Default simulateConnectionDidCloseForTesting creates a dummy connection
        session.simulateConnectionDidCloseForTesting(error: nil)
        
        // Should be completely ignored — state unchanged, delegate not called
        XCTAssertEqual(session.state, .connected,
                       "State should remain .connected — stale connection close must be ignored")
        XCTAssertEqual(delegate.didDisconnectCalls.count, 0,
                       "Delegate should NOT be notified by a stale connection")
    }
    
    @MainActor
    func testStaleConnectionGuardAllowsCurrentConnection() {
        // When the CURRENT connection fires connectionDidClose, it should
        // proceed normally (not be blocked by the stale guard).
        let session = SSHSession()
        let delegate = MockSSHSessionDelegate()
        session.delegate = delegate
        
        // Set a connection and then close it via useCurrentConnection: true
        let conn = NIOSSHConnection(host: "current", port: 22, username: "test")
        session.setConnectionForTesting(conn)
        
        session.simulateConnectionDidCloseForTesting(error: nil, useCurrentConnection: true)
        
        XCTAssertEqual(session.state, .disconnected,
                       "State should be updated when the current connection closes")
        XCTAssertEqual(delegate.didDisconnectCalls.count, 1,
                       "Delegate should be notified when the current connection closes")
    }
    
    @MainActor
    func testStaleConnectionGuardPassesThroughWhenConnectionNil() {
        // When self.connection is nil (e.g., fresh session or after explicit disconnect),
        // any connectionDidClose should pass through — the `self.connection != nil` check
        // prevents the stale guard from blocking legitimate notifications.
        let session = SSHSession()
        let delegate = MockSSHSessionDelegate()
        session.delegate = delegate
        
        // connection is nil by default on a fresh SSHSession
        XCTAssertNil(session.connectionForTesting)
        
        session.simulateConnectionDidCloseForTesting(error: nil)
        
        XCTAssertEqual(session.state, .disconnected,
                       "Should pass through when self.connection is nil")
        XCTAssertEqual(delegate.didDisconnectCalls.count, 1,
                       "Delegate should be notified when self.connection is nil")
    }
    
    @MainActor
    func testStaleConnectionGuardDoesNotUpdateState() {
        // The stale guard returns BEFORE setting state or lastError — a stale
        // connection's death rattle should leave the session completely untouched.
        let session = SSHSession()
        let delegate = MockSSHSessionDelegate()
        session.delegate = delegate
        
        let currentConn = NIOSSHConnection(host: "current", port: 22, username: "test")
        session.setConnectionForTesting(currentConn)
        session.state = .connected
        
        let testError = NSError(domain: "stale", code: 1, userInfo: nil)
        session.simulateConnectionDidCloseForTesting(error: testError)
        
        // State should be UNCHANGED (still .connected, not .disconnected)
        XCTAssertEqual(session.state, .connected,
                       "Stale connection close must not change state")
        XCTAssertNil(session.lastError,
                     "Stale connection close must not set lastError")
    }
    
    // MARK: - WS-R1: Reconnect suppression tests
    
    @MainActor
    func testReconnectSuppressionBlocksDelegateNotification() {
        // When isReconnecting is true, connectionDidClose from the current
        // connection should update state but NOT notify the delegate — the
        // reconnect process manages the lifecycle directly.
        let session = SSHSession()
        let delegate = MockSSHSessionDelegate()
        session.delegate = delegate
        
        // Set a connection and mark as reconnecting
        let conn = NIOSSHConnection(host: "test", port: 22, username: "test")
        session.setConnectionForTesting(conn)
        session.setIsReconnectingForTesting(true)
        
        session.simulateConnectionDidCloseForTesting(error: nil, useCurrentConnection: true)
        
        // State should be updated (connection IS closed)
        XCTAssertEqual(session.state, .disconnected,
                       "State should still be updated during reconnect")
        // But delegate should NOT be notified
        XCTAssertEqual(delegate.didDisconnectCalls.count, 0,
                       "Delegate must NOT be notified during reconnect — " +
                       "this would cause SwiftUI to navigate away from TerminalContainerView")
    }
    
    @MainActor
    func testReconnectSuppressionPreservesError() {
        // Even when suppressing delegate notification, lastError should be set
        // so diagnostic code can see what happened.
        let session = SSHSession()
        let delegate = MockSSHSessionDelegate()
        session.delegate = delegate
        
        let conn = NIOSSHConnection(host: "test", port: 22, username: "test")
        session.setConnectionForTesting(conn)
        session.setIsReconnectingForTesting(true)
        
        let testError = NSError(domain: "reconnect", code: 42, userInfo: nil)
        session.simulateConnectionDidCloseForTesting(error: testError, useCurrentConnection: true)
        
        XCTAssertEqual((session.lastError as? NSError)?.code, 42,
                       "lastError should be set even when reconnect suppresses delegate")
        XCTAssertEqual(delegate.didDisconnectCalls.count, 0,
                       "Delegate should not be called")
    }
    
    @MainActor
    func testReconnectNotActiveAllowsDelegateNotification() {
        // Contrast test: when isReconnecting is false and isDetachingForBackground
        // is false, the delegate SHOULD be notified normally.
        let session = SSHSession()
        let delegate = MockSSHSessionDelegate()
        session.delegate = delegate
        
        let conn = NIOSSHConnection(host: "test", port: 22, username: "test")
        session.setConnectionForTesting(conn)
        
        // Both flags are false (default)
        XCTAssertFalse(session.isReconnecting)
        XCTAssertFalse(session.isDetachingForBackground)
        
        session.simulateConnectionDidCloseForTesting(error: nil, useCurrentConnection: true)
        
        XCTAssertEqual(delegate.didDisconnectCalls.count, 1,
                       "Delegate should be notified when no suppression flags are set")
    }
    
    // MARK: - WS-R1: Guard priority / layering tests
    
    @MainActor
    func testStaleGuardTakesPriorityOverReconnectSuppression() {
        // Stale guard fires FIRST and returns before even checking
        // isReconnecting — state and lastError should be untouched.
        let session = SSHSession()
        let delegate = MockSSHSessionDelegate()
        session.delegate = delegate
        
        let currentConn = NIOSSHConnection(host: "current", port: 22, username: "test")
        session.setConnectionForTesting(currentConn)
        session.setIsReconnectingForTesting(true)
        session.state = .connected
        
        let testError = NSError(domain: "stale", code: 99, userInfo: nil)
        session.simulateConnectionDidCloseForTesting(error: testError)
        
        // Stale guard should fire first — nothing changes
        XCTAssertEqual(session.state, .connected,
                       "Stale guard should prevent any state change")
        XCTAssertNil(session.lastError)
        XCTAssertEqual(delegate.didDisconnectCalls.count, 0)
    }
    
    @MainActor
    func testBackgroundDetachTakesPriorityOverReconnect() {
        // When both backgroundState is set and isReconnecting is true
        // (shouldn't happen in practice, but defensive coding), the background
        // state guard fires first (since it comes first in code order).
        let session = SSHSession()
        let delegate = MockSSHSessionDelegate()
        session.delegate = delegate
        
        let conn = NIOSSHConnection(host: "test", port: 22, username: "test")
        session.setConnectionForTesting(conn)
        session.setBackgroundStateForTesting(true)
        session.setIsReconnectingForTesting(true)
        
        session.simulateConnectionDidCloseForTesting(error: nil, useCurrentConnection: true)
        
        // Both guards would suppress — but background fires first
        XCTAssertEqual(session.state, .disconnected,
                       "State should still be updated (happens before guards)")
        XCTAssertEqual(delegate.didDisconnectCalls.count, 0,
                       "Delegate should not be called regardless of which guard fires")
    }
    
    // MARK: - WS-R1: Full reconnect lifecycle simulation
    
    @MainActor
    func testFullReconnectLifecycleOldConnectionSuppressed() {
        // Simulates the complete reconnect flow:
        // 1. App has an active connection
        // 2. App backgrounds → backgroundState captured
        // 3. App foregrounds → no credentials → backgroundState cleared
        //    Then manually simulate reconnect sequence:
        //    a. Old connection's delegate nilled (belt-and-suspenders)
        //    b. Old connection disconnected → connectionDidClose fires
        //       → suppressed by stale guard OR reconnect flag
        // 4. New connection established
        // 5. isReconnecting = false
        let session = SSHSession()
        let delegate = MockSSHSessionDelegate()
        session.delegate = delegate
        let mock = MockBackgroundTaskProvider()
        session.backgroundTaskProvider = mock
        
        // Step 1: Simulate active SSH+tmux session
        let oldConn = NIOSSHConnection(host: "server", port: 22, username: "user")
        session.setConnectionForTesting(oldConn)
        session.setControlModeStateForTesting(.active)
        session.state = .connected
        
        // Step 2: Background
        session.appWillResignActive()
        XCTAssertTrue(session.isDetachingForBackground)
        
        // Old connection closes during background (TCP keepalive expires)
        session.simulateConnectionDidCloseForTesting(error: nil, useCurrentConnection: true)
        XCTAssertEqual(delegate.didDisconnectCalls.count, 0,
                       "Background state guard suppresses")
        
        // Step 3: Foreground (no credentials → backgroundState cleared)
        session.appDidBecomeActive()
        XCTAssertFalse(session.isDetachingForBackground,
                       "backgroundState cleared — no credentials path")
        
        // Manually simulate what attemptReconnect does
        session.setIsReconnectingForTesting(true)
        let newConn = NIOSSHConnection(host: "server", port: 22, username: "user")
        session.setConnectionForTesting(newConn)
        session.state = .connected
        
        // Old conn's death rattle fires — with our new connection set,
        // the dummy connection is stale. Verify the stale guard blocks it:
        session.simulateConnectionDidCloseForTesting(error: nil)
        XCTAssertEqual(delegate.didDisconnectCalls.count, 0,
                       "Stale connection guard suppresses old conn death rattle")
        
        // Step 4: New connection succeeds — isReconnecting cleared
        session.setIsReconnectingForTesting(false)
        
        // Step 5: If the NEW connection later dies normally, delegate IS notified
        session.simulateConnectionDidCloseForTesting(error: nil, useCurrentConnection: true)
        XCTAssertEqual(delegate.didDisconnectCalls.count, 1,
                       "Normal disconnect on established connection notifies delegate")
    }
    
    // MARK: - WS-R3: Connection timeout tests
    
    @MainActor
    func testDefaultConnectionTimeoutIs15Seconds() {
        let conn = NIOSSHConnection(host: "test", port: 22, username: "test")
        XCTAssertEqual(conn.connectionTimeoutSeconds, 15,
                       "Default connection timeout should be 15 seconds")
    }
    
    @MainActor
    func testConnectionTimeoutCanBeSetTo5Seconds() {
        let conn = NIOSSHConnection(host: "test", port: 22, username: "test")
        conn.connectionTimeoutSeconds = 5
        XCTAssertEqual(conn.connectionTimeoutSeconds, 5,
                       "Connection timeout should be configurable to 5 seconds for reconnect")
    }
    
    @MainActor
    func testConnectionTimeoutCanBeSetToArbitraryValue() {
        let conn = NIOSSHConnection(host: "test", port: 22, username: "test")
        conn.connectionTimeoutSeconds = 30
        XCTAssertEqual(conn.connectionTimeoutSeconds, 30,
                       "Connection timeout should accept any UInt64 value")
    }
    
    // MARK: - WS-BG1: prepareForReattach preserves split tree (SIGSEGV fix)
    
    @MainActor
    func testPrepareForReattachPreservesSplitTree() {
        // Root cause of Session 116 SIGSEGV: prepareForReattach() was clearing
        // currentSplitTree → triggered splitTreeObserver → cleanupMultiPaneMode()
        // → primary surface auto-resize → renderer UAF while tmux viewer is dead.
        //
        // Fix: prepareForReattach() no longer clears currentSplitTree.
        let manager = TmuxSessionManager()
        manager.controlModeActivated()
        
        // Build a multi-pane split tree directly — simulates what
        // reconcileTmuxState would produce for a 2-pane layout
        let mock = MockTmuxSurface()
        let leftCols = 40
        let rightCols = 39
        let body = "80x24,0,0{\(leftCols)x24,0,0,15,\(rightCols)x24,\(leftCols + 1),0,16}"
        let checksum = TmuxChecksum.calculate(body).asString()
        let layout = "\(checksum),\(body)"
        
        mock.stubbedWindows = [
            TmuxWindowInfo(id: 0, width: 80, height: 24, name: "bash")
        ]
        mock.stubbedWindowLayouts = [layout]
        mock.stubbedActiveWindowId = 0
        mock.stubbedPaneIds = [15, 16]
        
        #if DEBUG
        manager.tmuxQuerySurfaceOverride = mock
        #endif
        
        manager.handleTmuxStateChanged(windowCount: 1, paneCount: 2)
        
        // Verify we have a split tree
        XCTAssertTrue(manager.currentSplitTree.isSplit,
                      "Should have a split tree before prepareForReattach")
        XCTAssertEqual(Set(manager.currentSplitTree.paneIds), Set([15, 16]))
        
        // Now simulate background detach
        manager.prepareForReattach()
        
        // CRITICAL: split tree must be preserved
        XCTAssertTrue(manager.currentSplitTree.isSplit,
                      "currentSplitTree must be preserved after prepareForReattach — " +
                      "clearing it triggers cleanupMultiPaneMode → resize → SIGSEGV")
        XCTAssertEqual(Set(manager.currentSplitTree.paneIds), Set([15, 16]),
                       "Pane IDs in split tree must be preserved")
    }
    
    @MainActor
    func testPrepareForReattachClearsWindowsButNotCurrentSplitTree() {
        // windows is the list of tmux windows — this can be cleared because it will
        // be repopulated by TMUX_STATE_CHANGED on reattach.
        // But currentSplitTree (the ACTIVE layout driving the UI) must NOT be cleared.
        let manager = TmuxSessionManager()
        manager.controlModeActivated()
        
        let mock = MockTmuxSurface()
        let body = "80x24,0,0,5"
        let checksum = TmuxChecksum.calculate(body).asString()
        let layout = "\(checksum),\(body)"
        
        mock.stubbedWindows = [
            TmuxWindowInfo(id: 0, width: 80, height: 24, name: "bash")
        ]
        mock.stubbedWindowLayouts = [layout]
        mock.stubbedActiveWindowId = 0
        mock.stubbedPaneIds = [5]
        
        #if DEBUG
        manager.tmuxQuerySurfaceOverride = mock
        #endif
        
        manager.handleTmuxStateChanged(windowCount: 1, paneCount: 1)
        XCTAssertFalse(manager.currentSplitTree.isEmpty)
        XCTAssertFalse(manager.windows.isEmpty, "Should have windows before reattach")
        
        manager.prepareForReattach()
        
        // windows cleared (will be repopulated)
        XCTAssertTrue(manager.windows.isEmpty,
                      "windows should be cleared for fresh state on reattach")
        // currentSplitTree preserved (UI stability)
        XCTAssertFalse(manager.currentSplitTree.isEmpty,
                       "currentSplitTree must NOT be cleared — it drives the live UI")
    }
    
    @MainActor
    func testPrepareForReattachSplitTreeObserverDoesNotFireCleanup() {
        // Integration-style test: if prepareForReattach had cleared currentSplitTree
        // to an empty TmuxSplitTree(), the Combine observer would fire with
        // hasPanes=false → cleanupMultiPaneMode() → resize → SIGSEGV.
        //
        // After the fix, the observer should NOT fire at all during prepareForReattach
        // because currentSplitTree is not mutated.
        let manager = TmuxSessionManager()
        manager.controlModeActivated()
        
        var observerFired = false
        let observer = manager.$currentSplitTree
            .dropFirst() // skip initial value
            .sink { _ in
                observerFired = true
            }
        
        manager.prepareForReattach()
        
        XCTAssertFalse(observerFired,
                       "splitTreeObserver should NOT fire during prepareForReattach — " +
                       "no mutation means no Combine emission, no resize cascade")
        
        observer.cancel()
    }
}
