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
}
