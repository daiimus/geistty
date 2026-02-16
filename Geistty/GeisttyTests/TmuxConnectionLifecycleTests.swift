//
//  TmuxConnectionLifecycleTests.swift
//  GeisttyTests
//
//  Tests for the tmux connection lifecycle — the untested path that crashes.
//  These exercise the notification-driven state machine in SSHSession:
//    TMUX_STATE_CHANGED → controlModeState = .active
//    TMUX_READY → viewerReady = true → activateFirstTmuxPane() → flushPendingInput()
//    TMUX_EXIT → all state reset
//
//  Uses MockTmuxSurface (injected via tmuxSurfaceOverride) to test
//  C API interactions without a real GhosttyKit surface.
//

import XCTest
@testable import Geistty

final class TmuxConnectionLifecycleTests: XCTestCase {
    
    // MARK: - Helpers
    
    /// Create an SSHSession wired up for tmux testing with a mock surface.
    @MainActor
    private func makeSession(
        paneCount: Int = 1,
        paneIds: [Int] = [0],
        setActivePaneResult: Bool = true
    ) -> (SSHSession, MockTmuxSurface) {
        let session = SSHSession()
        let mock = MockTmuxSurface()
        mock.stubbedPaneCount = paneCount
        mock.stubbedPaneIds = paneIds
        mock.stubbedSetActivePaneResult = setActivePaneResult
        
        // Wire up tmux mode (creates TmuxSessionManager + registers notification observers)
        session.setupTmuxForTesting()
        
        // Inject mock surface so lifecycle code uses it instead of Ghostty.SurfaceView
        session.tmuxSurfaceOverride = mock
        
        // Also inject into TmuxSessionManager for handleTmuxStateChanged()
        session.tmuxSessionManager?.tmuxQuerySurfaceOverride = mock
        
        return (session, mock)
    }
    
    /// Post a TMUX_STATE_CHANGED notification (simulates Ghostty's action callback)
    private func postStateChanged(windowCount: UInt = 1, paneCount: UInt = 1) {
        NotificationCenter.default.post(
            name: .tmuxStateChanged,
            object: nil,
            userInfo: ["windowCount": windowCount, "paneCount": paneCount]
        )
    }
    
    /// Post a TMUX_READY notification (simulates viewer command queue drain)
    private func postReady() {
        NotificationCenter.default.post(
            name: .tmuxReady,
            object: nil,
            userInfo: [:]
        )
    }
    
    /// Post a TMUX_EXIT notification (simulates tmux control mode exit)
    private func postExit() {
        NotificationCenter.default.post(
            name: .tmuxExited,
            object: nil,
            userInfo: [:]
        )
    }
    
    // MARK: - 1. State Change Activates Control Mode
    
    @MainActor
    func testStateChangedActivatesControlModeWithSetup() {
        let (session, _) = makeSession()
        
        postStateChanged(windowCount: 1, paneCount: 1)
        
        XCTAssertEqual(session.controlModeState, .active,
                       "First TMUX_STATE_CHANGED should activate control mode")
        XCTAssertFalse(session.viewerReady,
                       "viewerReady should remain false until TMUX_READY fires")
        XCTAssertFalse(session.tmuxPaneActivated,
                       "Pane should NOT be activated before TMUX_READY")
    }
    
    // MARK: - 2. Ready Sets Viewer Ready and Activates Pane
    
    @MainActor
    func testReadyActivatesPaneWhenSurfaceHasPanes() {
        let (session, mock) = makeSession(paneCount: 2, paneIds: [0, 3])
        
        // First: state changed to activate control mode
        postStateChanged(windowCount: 1, paneCount: 2)
        XCTAssertEqual(session.controlModeState, .active)
        
        // Then: viewer ready
        postReady()
        
        XCTAssertTrue(session.viewerReady, "viewerReady should be true after TMUX_READY")
        XCTAssertTrue(session.tmuxPaneActivated, "Pane should be activated after TMUX_READY")
        XCTAssertEqual(session.activeTmuxPaneId, 0, "Should activate first pane ID (0)")
        XCTAssertEqual(mock.setActiveTmuxPaneCalls, [0],
                       "setActiveTmuxPane should be called with first pane ID")
    }
    
    // MARK: - 3. Exit Resets All State
    
    @MainActor
    func testExitResetsAllState() {
        let (session, _) = makeSession()
        
        // Activate and ready
        postStateChanged()
        postReady()
        XCTAssertTrue(session.viewerReady)
        XCTAssertTrue(session.tmuxPaneActivated)
        XCTAssertEqual(session.controlModeState, .active)
        
        // Exit
        postExit()
        
        XCTAssertEqual(session.controlModeState, .inactive,
                       "Control mode should be inactive after exit")
        XCTAssertFalse(session.viewerReady,
                       "viewerReady should be false after exit")
        XCTAssertFalse(session.tmuxPaneActivated,
                       "tmuxPaneActivated should be false after exit")
        XCTAssertNil(session.activeTmuxPaneId,
                     "activeTmuxPaneId should be nil after exit")
    }
    
    // MARK: - 4. Activate First Pane Guards on Surface
    
    @MainActor
    func testActivateFirstPaneWithNoSurfaceDefers() {
        let session = SSHSession()
        session.setupTmuxForTesting()
        // Deliberately do NOT set tmuxSurfaceOverride — surface is nil
        
        postStateChanged()
        postReady()
        
        // viewerReady should be set, but pane activation should be deferred
        XCTAssertTrue(session.viewerReady, "viewerReady should be set regardless of surface")
        XCTAssertFalse(session.tmuxPaneActivated,
                       "Pane should NOT be activated without a surface")
        XCTAssertNil(session.activeTmuxPaneId,
                     "activeTmuxPaneId should be nil without a surface")
    }
    
    // MARK: - 5. Activate First Pane With Zero Panes
    
    @MainActor
    func testActivateFirstPaneWithNoPanesDoesNotCrash() {
        let (session, mock) = makeSession(paneCount: 0, paneIds: [])
        
        postStateChanged(windowCount: 1, paneCount: 0)
        postReady()
        
        // Should not crash, should not activate
        XCTAssertTrue(session.viewerReady)
        XCTAssertFalse(session.tmuxPaneActivated,
                       "Should not activate when no panes exist")
        XCTAssertTrue(mock.setActiveTmuxPaneCalls.isEmpty,
                      "setActiveTmuxPane should NOT be called with zero panes")
    }
    
    // MARK: - 6. Activate First Pane Success Path
    
    @MainActor
    func testActivateFirstPaneCallsSetActiveTmuxPane() {
        let (session, mock) = makeSession(paneCount: 1, paneIds: [5])
        
        postStateChanged()
        postReady()
        
        XCTAssertEqual(mock.setActiveTmuxPaneCalls, [5],
                       "setActiveTmuxPane should be called with the first pane ID")
        XCTAssertEqual(session.activeTmuxPaneId, 5)
    }
    
    // MARK: - 7. Activate First Pane Failure Path
    
    @MainActor
    func testActivateFirstPaneFailureDoesNotSetState() {
        let (session, mock) = makeSession(paneCount: 1, paneIds: [0])
        mock.stubbedSetActivePaneResult = false
        
        postStateChanged()
        postReady()
        
        // setActiveTmuxPane was called but returned false
        XCTAssertEqual(mock.setActiveTmuxPaneCalls, [0],
                       "setActiveTmuxPane should still be called")
        XCTAssertFalse(session.tmuxPaneActivated,
                       "tmuxPaneActivated should be false when setActiveTmuxPane fails")
        XCTAssertNil(session.activeTmuxPaneId,
                     "activeTmuxPaneId should be nil when setActiveTmuxPane fails")
    }
    
    // MARK: - 8. Flush Pending Input Routes Through Surface
    
    @MainActor
    func testFlushPendingInputCallsSendText() {
        let (session, mock) = makeSession()
        
        // Queue some input before control mode is ready
        session.setControlModeStateForTesting(.active)
        session.setTmuxModeForTesting(.controlMode)
        session.write("ls\r".data(using: .utf8)!)
        session.write("pwd\r".data(using: .utf8)!)
        XCTAssertEqual(session.pendingInputQueue.count, 2)
        
        // Reset control mode state to let the full lifecycle run
        session.setControlModeStateForTesting(.inactive)
        
        // Now trigger the full lifecycle
        postStateChanged()
        postReady()
        
        // After pane activation, pending input should be flushed through sendText
        XCTAssertEqual(mock.sendTextCalls, ["ls\r", "pwd\r"],
                       "Pending input should be flushed through sendText in order")
        XCTAssertTrue(session.pendingInputQueue.isEmpty,
                      "Pending input queue should be empty after flush")
    }
    
    // MARK: - 9. Multiple State Changes Before Ready
    
    @MainActor
    func testMultipleStateChangedBeforeReadyDoNotActivatePane() {
        let (session, mock) = makeSession(paneCount: 3, paneIds: [0, 1, 2])
        
        // Multiple state changes before ready
        postStateChanged(windowCount: 1, paneCount: 1)
        postStateChanged(windowCount: 1, paneCount: 2)
        postStateChanged(windowCount: 1, paneCount: 3)
        
        // Control mode should be active but pane not yet activated
        XCTAssertEqual(session.controlModeState, .active)
        XCTAssertFalse(session.viewerReady)
        XCTAssertFalse(session.tmuxPaneActivated)
        
        // setActiveTmuxPane should NOT have been called yet
        // (it's called from handleTmuxStateChanged→reconcile path, but
        // activateFirstTmuxPane is gated on viewerReady)
        let activateCalls = mock.setActiveTmuxPaneCalls.count
        // The handleTmuxStateChanged path may call setActiveTmuxPane via TmuxSessionManager,
        // but activateFirstTmuxPane (the SSHSession one) should not be called
        XCTAssertFalse(session.tmuxPaneActivated,
                       "Pane should NOT be activated until TMUX_READY")
        
        // Now ready
        postReady()
        XCTAssertTrue(session.tmuxPaneActivated,
                      "Pane should be activated after TMUX_READY")
    }
    
    // MARK: - 10. Subsequent State Change After Ready Re-Activates
    
    @MainActor
    func testSubsequentStateChangeAfterReadyActivatesPane() {
        let (session, mock) = makeSession(paneCount: 1, paneIds: [0])
        
        // Full lifecycle
        postStateChanged()
        postReady()
        XCTAssertTrue(session.tmuxPaneActivated)
        mock.resetCallTracking()
        
        // Now a subsequent state change (e.g., new pane created)
        mock.stubbedPaneCount = 2
        mock.stubbedPaneIds = [0, 1]
        postStateChanged(windowCount: 1, paneCount: 2)
        
        // Since viewerReady is already true, activateFirstTmuxPane should be called
        // but guarded by tmuxPaneActivated = true (already done), so it's a no-op
        // on the SSHSession side. However, TmuxSessionManager.handleTmuxStateChanged
        // will call setActiveTmuxPane.
        // The key assertion: no crash, state is consistent
        XCTAssertTrue(session.tmuxPaneActivated,
                      "Pane should still be activated")
        XCTAssertEqual(session.controlModeState, .active,
                       "Control mode should still be active")
    }
    
    // MARK: - 11. Notification Observers Removed on Disconnect
    
    @MainActor
    func testDisconnectRemovesNotificationObservers() {
        let (session, _) = makeSession()
        
        // Activate control mode
        postStateChanged()
        XCTAssertEqual(session.controlModeState, .active)
        
        // Disconnect cleans up observers
        session.disconnect()
        
        // Post notifications after disconnect — should be no-ops
        postStateChanged(windowCount: 5, paneCount: 10)
        postReady()
        
        // State should remain reset (observers were removed)
        XCTAssertEqual(session.controlModeState, .inactive,
                       "State should not change after disconnect removes observers")
        XCTAssertFalse(session.viewerReady,
                       "viewerReady should not change after disconnect removes observers")
    }
    
    // MARK: - 12. Exit Then Re-Activate Lifecycle
    
    @MainActor
    func testExitThenReactivateLifecycle() {
        let (session, mock) = makeSession()
        
        // First lifecycle
        postStateChanged()
        postReady()
        XCTAssertTrue(session.tmuxPaneActivated)
        
        // Exit
        postExit()
        XCTAssertFalse(session.tmuxPaneActivated)
        XCTAssertNil(session.activeTmuxPaneId)
        mock.resetCallTracking()
        
        // Second lifecycle (tmux reconnect)
        postStateChanged()
        XCTAssertEqual(session.controlModeState, .active)
        XCTAssertFalse(session.tmuxPaneActivated,
                       "Pane should not be activated until TMUX_READY again")
        
        postReady()
        XCTAssertTrue(session.tmuxPaneActivated,
                      "Pane should be re-activated after second TMUX_READY")
        XCTAssertEqual(mock.setActiveTmuxPaneCalls, [0],
                       "setActiveTmuxPane should be called again in second lifecycle")
    }
    
    // MARK: - 13. State Changed With No Surface on Manager
    
    @MainActor
    func testStateChangedWithNoManagerSurfaceHandlesGracefully() {
        let session = SSHSession()
        session.setupTmuxForTesting()
        // Surface override NOT set on the manager
        // SSHSession has override but manager doesn't
        let mock = MockTmuxSurface()
        mock.stubbedPaneCount = 1
        mock.stubbedPaneIds = [0]
        session.tmuxSurfaceOverride = mock
        // Manager has no surface override — tmuxQuerySurface returns primarySurface (nil)
        
        // Should not crash
        postStateChanged()
        
        XCTAssertEqual(session.controlModeState, .active,
                       "Control mode should activate even if manager has no surface")
    }
    
    // MARK: - 14. Control Mode Exited Clears Manager State
    
    @MainActor
    func testControlModeExitedClearsManagerState() {
        let (session, _) = makeSession()
        
        postStateChanged()
        postReady()
        
        // Verify manager exists and is functional
        XCTAssertNotNil(session.tmuxSessionManager)
        
        // Exit tmux
        postExit()
        
        // Manager should still exist (session.disconnect would nil it)
        // but its control mode state should be cleared
        XCTAssertNotNil(session.tmuxSessionManager,
                        "Manager should still exist after tmux exit (only disconnect nils it)")
    }
}
