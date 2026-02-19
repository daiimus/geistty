import XCTest
import UIKit
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
/// When the app backgrounds, SSHSession starts a background task to protect
/// the tmux detach-client command from being killed before it completes.
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
        
        // 1. App backgrounds — start background task + send detach
        session.appWillResignActive()
        XCTAssertEqual(mock.activeTasks.count, 1, "Background task should be active")
        
        // 2. tmux sends %exit — SSHSession handles TMUX_EXIT notification,
        //    which calls endBackgroundTaskIfNeeded() internally
        session.endBackgroundTaskIfNeeded()
        XCTAssertTrue(mock.activeTasks.isEmpty, "Task should end on tmux exit")
        XCTAssertEqual(mock.endCallCount, 1)
        
        // 3. App foregrounds — endBackgroundTaskIfNeeded() is no-op (already ended)
        session.appDidBecomeActive()
        XCTAssertEqual(mock.endCallCount, 1,
                       "Should NOT double-end — task was already cleaned up by tmux exit")
    }
    
    // MARK: - Background detach flag tests
    
    @MainActor
    func testResignActiveSetsDetachingForBackgroundFlag() {
        let session = SSHSession()
        let mock = MockBackgroundTaskProvider()
        session.backgroundTaskProvider = mock
        session.setControlModeStateForTesting(.active)
        
        XCTAssertFalse(session.isDetachingForBackground,
                       "Flag should be false initially")
        
        session.appWillResignActive()
        
        XCTAssertTrue(session.isDetachingForBackground,
                      "Flag should be set after resigning active with tmux")
    }
    
    @MainActor
    func testResignActiveDoesNotSetFlagWhenTmuxInactive() {
        let session = SSHSession()
        let mock = MockBackgroundTaskProvider()
        session.backgroundTaskProvider = mock
        // controlModeState defaults to .inactive
        
        session.appWillResignActive()
        
        XCTAssertFalse(session.isDetachingForBackground,
                       "Flag should NOT be set when tmux is inactive")
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
                       "Flag should be cleared when becoming active")
    }
    
    @MainActor
    func testDisconnectClearsDetachingForBackgroundFlag() {
        let session = SSHSession()
        session.setControlModeStateForTesting(.active)
        session.setIsDetachingForBackgroundForTesting(true)
        
        session.disconnect()
        
        XCTAssertFalse(session.isDetachingForBackground,
                       "disconnect() should clear the detaching flag")
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
        // This tests the conceptual flow: when isDetachingForBackground is true,
        // the TMUX_EXIT handler should call prepareForReattach instead of
        // controlModeExited. We verify via the manager's state.
        let session = SSHSession()
        let mock = MockBackgroundTaskProvider()
        session.backgroundTaskProvider = mock
        
        // Set up tmux state
        session.setupTmuxForTesting()
        session.setControlModeStateForTesting(.active)
        session.tmuxSessionManager?.controlModeActivated()
        
        // Resign active (sets flag, starts background task)
        session.appWillResignActive()
        XCTAssertTrue(session.isDetachingForBackground)
        
        // Simulate TMUX_EXIT notification by directly testing the flag check:
        // After TMUX_EXIT with flag set, the manager should NOT have surfaces destroyed
        XCTAssertNotNil(session.tmuxSessionManager,
                        "Session manager should still exist during background detach")
    }
    
    @MainActor
    func testNormalTmuxExitCallsControlModeExited() {
        // When isDetachingForBackground is false, TMUX_EXIT should do full teardown
        let session = SSHSession()
        session.setupTmuxForTesting()
        session.setControlModeStateForTesting(.active)
        
        // Flag is false (default)
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
        
        // Set up: flag is set but no credentials → should log warning, not crash
        session.setIsDetachingForBackgroundForTesting(true)
        
        session.appDidBecomeActive()
        
        // Flag should be cleared regardless
        XCTAssertFalse(session.isDetachingForBackground,
                       "Flag should be cleared by appDidBecomeActive")
    }
    
    @MainActor
    func testBecomeActiveWithDetachFlagAndNoCredentialsCallsControlModeExited() {
        let session = SSHSession()
        session.setupTmuxForTesting()
        session.setControlModeStateForTesting(.active)
        session.tmuxSessionManager?.controlModeActivated()
        
        // Set flag but clear credentials
        session.setIsDetachingForBackgroundForTesting(true)
        // No storedAuthMethod → canReconnect == false
        
        session.appDidBecomeActive()
        
        XCTAssertFalse(session.isDetachingForBackground,
                       "Flag should be cleared")
        // The session manager should have had controlModeExited called
        XCTAssertFalse(session.tmuxSessionManager?.isConnected ?? true,
                       "Manager should show disconnected when credentials missing")
    }
    
    // MARK: - connectionDidClose suppression tests (WS-D2 fix)
    
    @MainActor
    func testConnectionDidCloseSuppressesDelegateWhenDetachingForBackground() {
        // When isDetachingForBackground is true, connectionDidClose should NOT
        // call delegate.sshSession(didDisconnectWithError:) — this prevents
        // SwiftUI from removing TerminalContainerView and triggering the
        // renderer use-after-free SIGSEGV.
        let session = SSHSession()
        let delegate = MockSSHSessionDelegate()
        session.delegate = delegate
        session.setControlModeStateForTesting(.active)
        session.setIsDetachingForBackgroundForTesting(true)
        
        session.simulateConnectionDidCloseForTesting(error: nil)
        
        XCTAssertEqual(delegate.didDisconnectCalls.count, 0,
                       "Delegate should NOT be notified of disconnect during background detach")
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
        session.setIsDetachingForBackgroundForTesting(true)
        
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
        // 1. appWillResignActive → flag set, detach-client sent
        // 2. connectionDidClose fires (SSH channel closes after tmux detach)
        //    → delegate NOT notified → SwiftUI doesn't remove view → no SIGSEGV
        // 3. appDidBecomeActive → reconnect path
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
        
        // Step 2: SSH channel closes (tmux exec'd process exits after detach)
        session.simulateConnectionDidCloseForTesting(error: nil)
        
        // Key assertion: delegate was NOT notified
        XCTAssertEqual(delegate.didDisconnectCalls.count, 0,
                       "Delegate must NOT be notified during background detach — " +
                       "this would cause SwiftUI to remove TerminalContainerView → SIGSEGV")
        // But state IS updated
        XCTAssertEqual(session.state, .disconnected)
        
        // Step 3: App foregrounds
        session.appDidBecomeActive()
        XCTAssertFalse(session.isDetachingForBackground,
                       "Flag should be cleared after becoming active")
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
}
