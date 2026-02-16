import XCTest
@testable import Geistty

// MARK: - TmuxSessionManager Tests

/// Tests for TmuxSessionManager methods NOT covered by TmuxStateReconciliationTests:
/// - Command formatting (all fire-and-forget user actions)
/// - Connection state transitions (controlModeActivated / controlModeExited)
/// - handleTmuxStateChanged() with MockTmuxSurface (full C API → reconcile → surface path)
/// - Surface management helpers (resolveInitialPaneId, removeSurface, cleanup)
/// - Local UI operations (toggleZoom, clearZoom, equalizeSplits, updateSplitRatio)
///
/// TmuxStateReconciliationTests covers reconcileTmuxState() pure logic,
/// selectWindow() state, and setFocusedPane() — those are NOT duplicated here.
final class TmuxSessionManagerTests: XCTestCase {

    // MARK: - Helpers

    /// Build a valid checksummed layout string for a single pane.
    private func singlePaneLayout(paneId: Int, cols: Int = 80, rows: Int = 24) -> String {
        let body = "\(cols)x\(rows),0,0,\(paneId)"
        let checksum = TmuxChecksum.calculate(body).asString()
        return "\(checksum),\(body)"
    }

    /// Build a valid checksummed layout for a horizontal split (2 panes).
    private func horizontalSplitLayout(
        paneA: Int, paneB: Int,
        totalCols: Int = 80, rows: Int = 24
    ) -> String {
        let leftCols = totalCols / 2
        let rightCols = totalCols - leftCols - 1
        let rightX = leftCols + 1
        let body = "\(totalCols)x\(rows),0,0{\(leftCols)x\(rows),0,0,\(paneA),\(rightCols)x\(rows),\(rightX),0,\(paneB)}"
        let checksum = TmuxChecksum.calculate(body).asString()
        return "\(checksum),\(body)"
    }

    /// Build a valid checksummed layout for a vertical split (2 panes).
    private func verticalSplitLayout(
        paneA: Int, paneB: Int,
        cols: Int = 80, totalRows: Int = 24
    ) -> String {
        let topRows = totalRows / 2
        let bottomRows = totalRows - topRows - 1
        let bottomY = topRows + 1
        let body = "\(cols)x\(totalRows),0,0[\(cols)x\(topRows),0,0,\(paneA),\(cols)x\(bottomRows),0,\(bottomY),\(paneB)]"
        let checksum = TmuxChecksum.calculate(body).asString()
        return "\(checksum),\(body)"
    }

    /// Set up a TmuxSessionManager with a captured command log.
    @MainActor
    private func managerWithCommandLog() -> (TmuxSessionManager, CommandLog) {
        let mgr = TmuxSessionManager()
        let log = CommandLog()
        mgr.setupWithDirectWrite { command in
            log.commands.append(command)
        }
        return (mgr, log)
    }

    /// Mutable reference type for capturing commands.
    final class CommandLog {
        var commands: [String] = []
    }
}

// MARK: - Command Formatting Tests

extension TmuxSessionManagerTests {

    @MainActor
    func testNewWindowCommand() {
        let (mgr, log) = managerWithCommandLog()
        mgr.newWindow()
        XCTAssertEqual(log.commands, ["new-window\n"])
    }

    @MainActor
    func testNewWindowWithNameCommand() {
        let (mgr, log) = managerWithCommandLog()
        mgr.newWindow(name: "my-shell")
        XCTAssertEqual(log.commands, ["new-window -n 'my-shell'\n"])
    }

    @MainActor
    func testNewWindowNameEscapesSingleQuotes() {
        let (mgr, log) = managerWithCommandLog()
        mgr.newWindow(name: "it's a test")
        XCTAssertEqual(log.commands, ["new-window -n 'it'\\''s a test'\n"])
    }

    @MainActor
    func testCloseWindowCommand() {
        let (mgr, log) = managerWithCommandLog()
        mgr.closeWindow()
        XCTAssertEqual(log.commands, ["kill-window\n"])
    }

    @MainActor
    func testCloseWindowByIdCommand() {
        let (mgr, log) = managerWithCommandLog()
        mgr.closeWindow(windowId: "@2")
        XCTAssertEqual(log.commands, ["kill-window -t '@2'\n"])
    }

    @MainActor
    func testRenameWindowCommand() {
        let (mgr, log) = managerWithCommandLog()
        mgr.renameWindow("editors")
        XCTAssertEqual(log.commands, ["rename-window 'editors'\n"])
    }

    @MainActor
    func testRenameWindowEscapesSingleQuotes() {
        let (mgr, log) = managerWithCommandLog()
        mgr.renameWindow("vim's window")
        XCTAssertEqual(log.commands, ["rename-window 'vim'\\''s window'\n"])
    }

    @MainActor
    func testRenameWindowByIdCommand() {
        let (mgr, log) = managerWithCommandLog()
        mgr.renameWindow(windowId: "@1", name: "logs")
        XCTAssertEqual(log.commands, ["rename-window -t '@1' 'logs'\n"])
    }

    @MainActor
    func testSelectWindowCommand() {
        let (mgr, log) = managerWithCommandLog()
        mgr.selectWindow("@3")
        XCTAssertEqual(log.commands, ["select-window -t '@3'\n"])
    }

    @MainActor
    func testNextWindowCommand() {
        let (mgr, log) = managerWithCommandLog()
        mgr.nextWindow()
        XCTAssertEqual(log.commands, ["next-window\n"])
    }

    @MainActor
    func testPreviousWindowCommand() {
        let (mgr, log) = managerWithCommandLog()
        mgr.previousWindow()
        XCTAssertEqual(log.commands, ["previous-window\n"])
    }

    @MainActor
    func testLastWindowCommand() {
        let (mgr, log) = managerWithCommandLog()
        mgr.lastWindow()
        XCTAssertEqual(log.commands, ["last-window\n"])
    }

    @MainActor
    func testSelectWindowByIndexCommand() {
        let (mgr, log) = managerWithCommandLog()
        // Input is 1-based (Ghostty Cmd+1), output is 0-based for tmux
        mgr.selectWindowByIndex(1)
        XCTAssertEqual(log.commands, ["select-window -t :0\n"])

        mgr.selectWindowByIndex(5)
        XCTAssertEqual(log.commands.last, "select-window -t :4\n")
    }

    @MainActor
    func testNextPaneCommand() {
        let (mgr, log) = managerWithCommandLog()
        mgr.nextPane()
        XCTAssertEqual(log.commands, ["select-pane -t :.+\n"])
    }

    @MainActor
    func testPreviousPaneCommand() {
        let (mgr, log) = managerWithCommandLog()
        mgr.previousPane()
        XCTAssertEqual(log.commands, ["select-pane -t :.-\n"])
    }

    @MainActor
    func testToggleTmuxZoomCommand() {
        let (mgr, log) = managerWithCommandLog()
        mgr.toggleTmuxZoom()
        XCTAssertEqual(log.commands, ["resize-pane -Z\n"])
    }

    @MainActor
    func testSplitHorizontalCommand() {
        let (mgr, log) = managerWithCommandLog()
        mgr.splitHorizontal()
        XCTAssertEqual(log.commands, ["split-window -h\n"])
    }

    @MainActor
    func testSplitVerticalCommand() {
        let (mgr, log) = managerWithCommandLog()
        mgr.splitVertical()
        XCTAssertEqual(log.commands, ["split-window -v\n"])
    }

    @MainActor
    func testClosePaneCommand() {
        let (mgr, log) = managerWithCommandLog()
        mgr.closePane()
        XCTAssertEqual(log.commands, ["kill-pane\n"])
    }

    @MainActor
    func testSelectPaneCommand() {
        let (mgr, log) = managerWithCommandLog()
        mgr.selectPane("%5")
        XCTAssertEqual(log.commands, ["select-pane -t '%5'\n"])
        XCTAssertEqual(mgr.focusedPaneId, "%5", "selectPane should update focusedPaneId")
    }

    @MainActor
    func testNavigatePaneCommands() {
        let (mgr, log) = managerWithCommandLog()
        mgr.navigatePane(.up)
        mgr.navigatePane(.down)
        mgr.navigatePane(.left)
        mgr.navigatePane(.right)
        XCTAssertEqual(log.commands, [
            "select-pane -U\n",
            "select-pane -D\n",
            "select-pane -L\n",
            "select-pane -R\n",
        ])
    }

    @MainActor
    func testResizeCommand() {
        let (mgr, log) = managerWithCommandLog()
        mgr.resize(cols: 120, rows: 40)
        XCTAssertEqual(log.commands, ["refresh-client -C 120,40\n"])
    }

    @MainActor
    func testDetachCommand() {
        let (mgr, log) = managerWithCommandLog()
        mgr.detach()
        XCTAssertEqual(log.commands, ["detach-client\n"])
    }

    @MainActor
    func testNoCommandSentWithoutWriteFunction() {
        let mgr = TmuxSessionManager()
        // No setupWithDirectWrite called — should not crash, just log warning
        mgr.newWindow()
        mgr.closePane()
        mgr.detach()
        // No assertion needed — just verifying no crash
    }
}

// MARK: - Connection State Transition Tests

extension TmuxSessionManagerTests {

    @MainActor
    func testControlModeActivated() {
        let mgr = TmuxSessionManager()
        XCTAssertFalse(mgr.isConnected)
        XCTAssertEqual(mgr.connectionState, .disconnected)

        mgr.controlModeActivated()

        XCTAssertTrue(mgr.isConnected)
        XCTAssertEqual(mgr.connectionState, .connected)
    }

    @MainActor
    func testControlModeExitedWithReason() {
        let mgr = TmuxSessionManager()
        mgr.controlModeActivated()
        XCTAssertTrue(mgr.isConnected)

        mgr.controlModeExited(reason: "server disconnected")

        XCTAssertFalse(mgr.isConnected)
        XCTAssertEqual(mgr.connectionState, .connectionLost(reason: "server disconnected"))
        XCTAssertNil(mgr.currentSession)
        XCTAssertTrue(mgr.windows.isEmpty)
        XCTAssertTrue(mgr.currentSplitTree.isEmpty)
        XCTAssertTrue(mgr.paneSurfaces.isEmpty)
        XCTAssertNil(mgr.primarySurface)
    }

    @MainActor
    func testControlModeExitedWithoutReason() {
        let mgr = TmuxSessionManager()
        mgr.controlModeActivated()

        mgr.controlModeExited()

        XCTAssertFalse(mgr.isConnected)
        XCTAssertEqual(mgr.connectionState, .disconnected)
    }

    @MainActor
    func testControlModeExitedClearsPendingOutput() {
        let mgr = TmuxSessionManager()
        mgr.controlModeActivated()

        // Simulate pending output via test helper
        mgr.setPendingOutputForTesting(["%0": [Data([0x41])]])
        XCTAssertFalse(mgr.pendingOutput.isEmpty)

        mgr.controlModeExited()

        XCTAssertTrue(mgr.pendingOutput.isEmpty)
    }
}

// MARK: - handleTmuxStateChanged() with Mock Surface

extension TmuxSessionManagerTests {

    @MainActor
    func testHandleTmuxStateChangedQueriesMockSurface() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        let layout = singlePaneLayout(paneId: 0)

        mock.stubbedWindows = [TmuxWindowInfo(id: 0, width: 80, height: 24, name: "bash")]
        mock.stubbedWindowLayouts = [layout]
        mock.stubbedActiveWindowId = 0
        mock.stubbedPaneIds = [0]

        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        mgr.handleTmuxStateChanged(windowCount: 1, paneCount: 1)

        // Verify C API was queried
        XCTAssertEqual(mock.getAllTmuxWindowsCallCount, 1)
        XCTAssertEqual(mock.getTmuxPaneIdsCallCount, 1)
        XCTAssertEqual(mock.getTmuxWindowLayoutCalls, [0])

        // Verify state was reconciled
        XCTAssertEqual(mgr.windows.count, 1)
        XCTAssertEqual(mgr.focusedWindowId, "@0")
        XCTAssertEqual(mgr.focusedPaneId, "%0")

        // Verify active pane was set on the surface
        XCTAssertEqual(mock.setActiveTmuxPaneCalls, [0])
    }

    @MainActor
    func testHandleTmuxStateChangedWithMultipleWindows() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        let layout0 = singlePaneLayout(paneId: 0)
        let layout1 = horizontalSplitLayout(paneA: 1, paneB: 2)

        mock.stubbedWindows = [
            TmuxWindowInfo(id: 0, width: 80, height: 24, name: "bash"),
            TmuxWindowInfo(id: 1, width: 80, height: 24, name: "vim"),
        ]
        mock.stubbedWindowLayouts = [layout0, layout1]
        mock.stubbedActiveWindowId = 1
        mock.stubbedPaneIds = [0, 1, 2]

        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        mgr.handleTmuxStateChanged(windowCount: 2, paneCount: 3)

        XCTAssertEqual(mgr.windows.count, 2)
        XCTAssertEqual(mgr.focusedWindowId, "@1")
        XCTAssertTrue(mgr.currentSplitTree.isSplit)
    }

    @MainActor
    func testHandleTmuxStateChangedWithNoSurface() {
        let mgr = TmuxSessionManager()
        // No surface set — should early return without crash
        mgr.handleTmuxStateChanged(windowCount: 1, paneCount: 1)
        XCTAssertTrue(mgr.windows.isEmpty)
    }
}

// MARK: - Cleanup Tests

extension TmuxSessionManagerTests {

    @MainActor
    func testCleanupResetsAllState() {
        let mgr = TmuxSessionManager()
        mgr.controlModeActivated()

        // Set up some state via reconciliation
        let layout = singlePaneLayout(paneId: 0)
        _ = mgr.reconcileTmuxState(TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "bash", layout: layout, focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [0]
        ))

        // Verify state exists
        XCTAssertTrue(mgr.isConnected)
        XCTAssertFalse(mgr.windows.isEmpty)
        XCTAssertFalse(mgr.currentSplitTree.isEmpty)

        mgr.cleanup()

        XCTAssertFalse(mgr.isConnected)
        XCTAssertEqual(mgr.connectionState, .disconnected)
        XCTAssertTrue(mgr.windows.isEmpty)
        XCTAssertTrue(mgr.currentSplitTree.isEmpty)
        XCTAssertNil(mgr.currentSession)
        XCTAssertNil(mgr.primarySurface)
        XCTAssertTrue(mgr.paneSurfaces.isEmpty)
        XCTAssertTrue(mgr.pendingOutput.isEmpty)
        XCTAssertEqual(mgr.focusedPaneId, "")
        XCTAssertEqual(mgr.focusedWindowId, "")
    }
}

// MARK: - Local UI Operations (toggleZoom, clearZoom, equalizeSplits)

extension TmuxSessionManagerTests {

    @MainActor
    func testToggleZoomUpdatesCurrentSplitTree() {
        let mgr = TmuxSessionManager()
        let layout = horizontalSplitLayout(paneA: 0, paneB: 1)
        _ = mgr.reconcileTmuxState(TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "bash", layout: layout, focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [0, 1]
        ))

        XCTAssertNil(mgr.currentSplitTree.zoomed?.paneId)

        mgr.toggleZoom(paneId: 0)
        XCTAssertEqual(mgr.currentSplitTree.zoomed?.paneId, 0)

        mgr.toggleZoom(paneId: 0)
        XCTAssertNil(mgr.currentSplitTree.zoomed?.paneId,
                     "Toggling same pane again should unzoom")
    }

    @MainActor
    func testClearZoomResetsZoomState() {
        let mgr = TmuxSessionManager()
        let layout = horizontalSplitLayout(paneA: 0, paneB: 1)
        _ = mgr.reconcileTmuxState(TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "bash", layout: layout, focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [0, 1]
        ))

        mgr.toggleZoom(paneId: 0)
        XCTAssertNotNil(mgr.currentSplitTree.zoomed?.paneId)

        mgr.clearZoom()
        XCTAssertNil(mgr.currentSplitTree.zoomed?.paneId)
    }

    @MainActor
    func testUpdateSplitRatio() {
        let mgr = TmuxSessionManager()
        let layout = horizontalSplitLayout(paneA: 0, paneB: 1)
        _ = mgr.reconcileTmuxState(TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "bash", layout: layout, focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [0, 1]
        ))

        // Update ratio for pane 0
        mgr.updateSplitRatio(forPaneId: 0, ratio: 0.7)

        // Verify the split tree was updated
        if case .split(let split) = mgr.currentSplitTree.root {
            XCTAssertEqual(split.ratio, 0.7, accuracy: 0.01)
        } else {
            XCTFail("Expected split root after updateSplitRatio")
        }
    }

    @MainActor
    func testEqualizeSplitsSimpleTwoPaneHorizontal() {
        let (mgr, log) = managerWithCommandLog()
        let layout = horizontalSplitLayout(paneA: 0, paneB: 1)
        _ = mgr.reconcileTmuxState(TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "bash", layout: layout, focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [0, 1]
        ))

        mgr.equalizeSplits()

        XCTAssertEqual(log.commands, ["select-layout even-horizontal\n"])
    }

    @MainActor
    func testEqualizeSplitsSimpleTwoPaneVertical() {
        let (mgr, log) = managerWithCommandLog()
        let layout = verticalSplitLayout(paneA: 0, paneB: 1)
        _ = mgr.reconcileTmuxState(TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "bash", layout: layout, focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [0, 1]
        ))

        mgr.equalizeSplits()

        XCTAssertEqual(log.commands, ["select-layout even-vertical\n"])
    }

    @MainActor
    func testEqualizeSplitsSinglePaneFallsToTiled() {
        let (mgr, log) = managerWithCommandLog()
        let layout = singlePaneLayout(paneId: 0)
        _ = mgr.reconcileTmuxState(TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "bash", layout: layout, focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [0]
        ))

        mgr.equalizeSplits()

        XCTAssertEqual(log.commands, ["select-layout tiled\n"])
    }
}

// MARK: - removeSurface Behavior

extension TmuxSessionManagerTests {

    @MainActor
    func testRemoveSurfaceKeepsPane0OnDisconnect() {
        let mgr = TmuxSessionManager()
        // We can't create a real Ghostty surface, but we can verify the guard logic
        // by checking that removeSurface with paneActuallyClosed:false for %0 is a no-op
        // (no crash, no surface creation needed since paneSurfaces is empty)
        mgr.removeSurface(for: "%0", paneActuallyClosed: false)
        // Just verifying no crash — %0 protection is a guard return
    }

    @MainActor
    func testRemoveSurfaceAllowsPane0WhenActuallyClosed() {
        let mgr = TmuxSessionManager()
        // When paneActuallyClosed is true, %0 should be removable
        mgr.removeSurface(for: "%0", paneActuallyClosed: true)
        // No crash — and if a surface existed, it would be removed
    }
}

// MARK: - resolveInitialPaneId Tests

extension TmuxSessionManagerTests {

    @MainActor
    func testResolveInitialPaneIdFromSplitTree() {
        let mgr = TmuxSessionManager()
        let layout = singlePaneLayout(paneId: 5)
        _ = mgr.reconcileTmuxState(TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "bash", layout: layout, focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [5]
        ))

        // createPrimarySurface calls resolveInitialPaneId internally.
        // Without a factory, it returns nil — but we can verify indirectly
        // by checking that focusedPaneId was set from the tree.
        XCTAssertEqual(mgr.focusedPaneId, "%5")
    }

    @MainActor
    func testResolveInitialPaneIdFromPendingOutput() {
        let mgr = TmuxSessionManager()
        // No split tree, but pending output exists
        mgr.setPendingOutputForTesting(["%3": [Data([0x41])]])

        // createPrimarySurface with no factory returns nil, but
        // verifying the pending output path is exercised
        let surface = mgr.createPrimarySurface()
        XCTAssertNil(surface, "No factory configured — should return nil")
    }

    @MainActor
    func testResolveInitialPaneIdFallback() {
        let mgr = TmuxSessionManager()
        // No tree, no pending output, no focusedPaneId — falls back to %0
        let surface = mgr.createPrimarySurface()
        XCTAssertNil(surface, "No factory configured — should return nil")
    }
}

// MARK: - TmuxConnectionState Tests

extension TmuxSessionManagerTests {

    @MainActor
    func testConnectionStateEquatable() {
        XCTAssertEqual(TmuxConnectionState.disconnected, TmuxConnectionState.disconnected)
        XCTAssertEqual(TmuxConnectionState.connecting, TmuxConnectionState.connecting)
        XCTAssertEqual(TmuxConnectionState.connected, TmuxConnectionState.connected)
        XCTAssertEqual(
            TmuxConnectionState.connectionLost(reason: "timeout"),
            TmuxConnectionState.connectionLost(reason: "timeout")
        )
        XCTAssertNotEqual(TmuxConnectionState.connected, TmuxConnectionState.disconnected)
        XCTAssertNotEqual(
            TmuxConnectionState.connectionLost(reason: "a"),
            TmuxConnectionState.connectionLost(reason: "b")
        )
        XCTAssertNotEqual(
            TmuxConnectionState.connectionLost(reason: nil),
            TmuxConnectionState.connectionLost(reason: "something")
        )
    }
}

// MARK: - configureSurfaceManagement Tests

extension TmuxSessionManagerTests {

    @MainActor
    func testConfigureSurfaceManagementEnablesCreatePrimary() {
        let mgr = TmuxSessionManager()

        // Without configuration, createPrimarySurface returns nil
        XCTAssertNil(mgr.createPrimarySurface())

        // With a factory that returns nil (simulating deallocation), still returns nil
        mgr.configureSurfaceManagement(
            factory: { _ in nil },
            inputHandler: { _, _ in },
            resizeHandler: { _, _ in }
        )

        let surface = mgr.createPrimarySurface()
        XCTAssertNil(surface, "Factory returns nil — should propagate")
    }
}
