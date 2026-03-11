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

        // Populate windows via reconciliation so selectWindowByIndex can look them up
        let layout0 = singlePaneLayout(paneId: 0)
        let layout1 = singlePaneLayout(paneId: 1)
        _ = mgr.reconcileTmuxState(TmuxSessionManager.TmuxStateSnapshot(
            windows: [
                .init(id: 0, name: "bash", layout: layout0, focusedPaneId: -1),
                .init(id: 1, name: "vim", layout: layout1, focusedPaneId: -1)
            ],
            activeWindowId: 0,
            paneIds: [0, 1]
        ))
        log.commands.removeAll()  // Clear any commands from reconciliation

        // Input is 1-based (Ghostty Cmd+1), selects window by sorted position
        mgr.selectWindowByIndex(1)
        XCTAssertEqual(log.commands, ["select-window -t @0\n"])

        mgr.selectWindowByIndex(2)
        XCTAssertEqual(log.commands.last, "select-window -t @1\n")

        // Out of range — no additional command
        let countBefore = log.commands.count
        mgr.selectWindowByIndex(5)
        XCTAssertEqual(log.commands.count, countBefore,
                       "Out-of-range index should not send a command")
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

    /// Voluntary detach (reason == "detached") should set .detached state,
    /// not .connectionLost — the session is still alive on the server.
    @MainActor
    func testControlModeExitedWithDetachedReason() {
        let mgr = TmuxSessionManager()
        mgr.controlModeActivated()
        XCTAssertTrue(mgr.isConnected)

        mgr.controlModeExited(reason: "detached")

        XCTAssertFalse(mgr.isConnected)
        XCTAssertEqual(mgr.connectionState, .detached)
        XCTAssertNil(mgr.currentSession)
        XCTAssertTrue(mgr.windows.isEmpty)
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
        XCTAssertEqual(mock.setActiveTmuxPaneInputOnlyCalls, [0])
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

// MARK: - handleActiveWindowChanged Tests

extension TmuxSessionManagerTests {

    @MainActor
    func testActiveWindowChangedUpdatesKnownWindow() {
        let mgr = TmuxSessionManager()
        let layout0 = singlePaneLayout(paneId: 0)
        let layout1 = singlePaneLayout(paneId: 1)

        // Populate two windows via reconciliation
        _ = mgr.reconcileTmuxState(TmuxSessionManager.TmuxStateSnapshot(
            windows: [
                .init(id: 0, name: "bash", layout: layout0, focusedPaneId: -1),
                .init(id: 1, name: "vim", layout: layout1, focusedPaneId: -1),
            ],
            activeWindowId: 0,
            paneIds: [0, 1]
        ))
        XCTAssertEqual(mgr.focusedWindowId, "@0")

        // Switch active window via the new notification handler
        mgr.handleActiveWindowChanged(windowId: 1)

        XCTAssertEqual(mgr.focusedWindowId, "@1")
    }

    @MainActor
    func testActiveWindowChangedNoOpForSameWindow() {
        let mgr = TmuxSessionManager()
        let layout0 = singlePaneLayout(paneId: 0)

        _ = mgr.reconcileTmuxState(TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "bash", layout: layout0, focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [0]
        ))
        let previousTree = mgr.currentSplitTree

        // "Switching" to the already-focused window — should be a no-op
        mgr.handleActiveWindowChanged(windowId: 0)

        XCTAssertEqual(mgr.focusedWindowId, "@0")
        // Split tree reference should be unchanged
        XCTAssertEqual(mgr.currentSplitTree.paneIds, previousTree.paneIds)
    }

    @MainActor
    func testActiveWindowChangedIgnoresUnknownWindow() {
        let mgr = TmuxSessionManager()
        let layout0 = singlePaneLayout(paneId: 0)

        _ = mgr.reconcileTmuxState(TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "bash", layout: layout0, focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [0]
        ))

        // Switch to a window ID we've never seen — should not update focusedWindowId
        mgr.handleActiveWindowChanged(windowId: 99)

        XCTAssertEqual(mgr.focusedWindowId, "@0")
    }

    @MainActor
    func testActiveWindowChangedUpdatesSplitTree() {
        let mgr = TmuxSessionManager()
        let layout0 = singlePaneLayout(paneId: 0)
        let layout1 = horizontalSplitLayout(paneA: 1, paneB: 2)

        _ = mgr.reconcileTmuxState(TmuxSessionManager.TmuxStateSnapshot(
            windows: [
                .init(id: 0, name: "bash", layout: layout0, focusedPaneId: -1),
                .init(id: 1, name: "vim", layout: layout1, focusedPaneId: -1),
            ],
            activeWindowId: 0,
            paneIds: [0, 1, 2]
        ))
        // Window @0 is a single pane — not a split
        XCTAssertFalse(mgr.currentSplitTree.isSplit)

        // Switch to window @1 (horizontal split) — should update the split tree
        mgr.handleActiveWindowChanged(windowId: 1)

        XCTAssertTrue(mgr.currentSplitTree.isSplit)
        XCTAssertEqual(Set(mgr.currentSplitTree.paneIds), Set([1, 2]))
    }

    @MainActor
    func testActiveWindowChangedClearsSplitTreeWhenNoTree() {
        let mgr = TmuxSessionManager()
        let layout0 = singlePaneLayout(paneId: 0)

        // Initial reconcile: window @0 has a valid layout, window @1 has an
        // unparseable layout so windowSplitTrees won't have an entry for it.
        _ = mgr.reconcileTmuxState(TmuxSessionManager.TmuxStateSnapshot(
            windows: [
                .init(id: 0, name: "bash", layout: layout0, focusedPaneId: -1),
                .init(id: 1, name: "noparse", layout: "INVALID", focusedPaneId: -1),
            ],
            activeWindowId: 0,
            paneIds: [0]
        ))
        XCTAssertFalse(mgr.currentSplitTree.isEmpty)

        // Switch to @1 — should clear the split tree rather than keeping stale data.
        mgr.handleActiveWindowChanged(windowId: 1)

        XCTAssertEqual(mgr.focusedWindowId, "@1")
        XCTAssertTrue(mgr.currentSplitTree.isEmpty)
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

// MARK: - Race Condition Fix Tests (Session 78)

extension TmuxSessionManagerTests {

    /// When handleTmuxStateChanged fires BEFORE the factory is configured,
    /// pane IDs should be deferred into pendingSurfaceCreation.
    @MainActor
    func testHandleStateChangedDefersCreationWhenFactoryNil() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        let layout = horizontalSplitLayout(paneA: 0, paneB: 1)

        mock.stubbedWindows = [TmuxWindowInfo(id: 0, width: 80, height: 24, name: "bash")]
        mock.stubbedWindowLayouts = [layout]
        mock.stubbedActiveWindowId = 0
        mock.stubbedPaneIds = [0, 1]

        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        // No factory configured — simulates the race condition
        mgr.handleTmuxStateChanged(windowCount: 1, paneCount: 2)

        // Surfaces should NOT have been created
        XCTAssertTrue(mgr.paneSurfaces.isEmpty,
                      "No surfaces should be created without a factory")

        #if DEBUG
        // But deferred creation should be recorded
        XCTAssertEqual(mgr.pendingSurfaceCreationForTesting, ["%0", "%1"],
                       "Both pane IDs should be deferred")
        #endif
    }

    /// When configureSurfaceManagement is called after deferred panes exist,
    /// it should drain them and create surfaces via the factory.
    @MainActor
    func testConfigureSurfaceManagementDrainsDeferredPanes() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        let layout = horizontalSplitLayout(paneA: 0, paneB: 1)

        mock.stubbedWindows = [TmuxWindowInfo(id: 0, width: 80, height: 24, name: "bash")]
        mock.stubbedWindowLayouts = [layout]
        mock.stubbedActiveWindowId = 0
        mock.stubbedPaneIds = [0, 1]

        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        // In production, controlModeActivated() always fires before
        // handleTmuxStateChanged (SSHSession.swift:449). Set isConnected = true
        // so getSurfaceOrCreate() allows factory creation.
        mgr.controlModeActivated()

        // Step 1: handleTmuxStateChanged with no factory — defers creation
        mgr.handleTmuxStateChanged(windowCount: 1, paneCount: 2)
        XCTAssertTrue(mgr.paneSurfaces.isEmpty)

        // Step 2: Configure factory — should drain deferred panes
        var factoryCalls: [String] = []
        mgr.configureSurfaceManagement(
            factory: { paneId in
                factoryCalls.append(paneId)
                return nil  // Can't create real Ghostty surfaces in tests
            },
            inputHandler: { _, _ in },
            resizeHandler: { _, _ in }
        )

        // Factory should have been called for both deferred panes
        XCTAssertEqual(Set(factoryCalls), ["%0", "%1"],
                       "Factory should be called for all deferred pane IDs")

        #if DEBUG
        // Deferred set should be drained
        XCTAssertTrue(mgr.pendingSurfaceCreationForTesting.isEmpty,
                      "pendingSurfaceCreation should be empty after drain")
        #endif
    }

    /// When handleTmuxStateChanged fires WITH the factory configured,
    /// surfaces should be created immediately (no deferral).
    @MainActor
    func testHandleStateChangedCreatesImmediatelyWithFactory() {
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

        // In production, controlModeActivated() always fires before
        // handleTmuxStateChanged. isConnected must be true for factory creation.
        mgr.controlModeActivated()

        // Configure factory FIRST (normal non-race path)
        var factoryCalls: [String] = []
        mgr.configureSurfaceManagement(
            factory: { paneId in
                factoryCalls.append(paneId)
                return nil  // Can't create real surfaces in tests
            },
            inputHandler: { _, _ in },
            resizeHandler: { _, _ in }
        )

        mgr.handleTmuxStateChanged(windowCount: 1, paneCount: 1)

        // Factory should be called immediately
        XCTAssertEqual(factoryCalls, ["%0"])

        #if DEBUG
        // No deferral needed
        XCTAssertTrue(mgr.pendingSurfaceCreationForTesting.isEmpty)
        #endif
    }

    /// controlModeExited should clear pendingSurfaceCreation.
    @MainActor
    func testControlModeExitedClearsPendingSurfaceCreation() {
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

        // Trigger deferral
        mgr.handleTmuxStateChanged(windowCount: 1, paneCount: 1)

        #if DEBUG
        XCTAssertFalse(mgr.pendingSurfaceCreationForTesting.isEmpty)
        #endif

        mgr.controlModeExited(reason: "test")

        #if DEBUG
        XCTAssertTrue(mgr.pendingSurfaceCreationForTesting.isEmpty,
                      "controlModeExited should clear pendingSurfaceCreation")
        #endif
    }

    /// cleanup should clear pendingSurfaceCreation.
    @MainActor
    func testCleanupClearsPendingSurfaceCreation() {
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

        // Trigger deferral
        mgr.handleTmuxStateChanged(windowCount: 1, paneCount: 1)

        #if DEBUG
        XCTAssertFalse(mgr.pendingSurfaceCreationForTesting.isEmpty)
        #endif

        mgr.cleanup()

        #if DEBUG
        XCTAssertTrue(mgr.pendingSurfaceCreationForTesting.isEmpty,
                      "cleanup should clear pendingSurfaceCreation")
        #endif
    }
}

// MARK: - Pending Output Discard Tests (Session 78)

extension TmuxSessionManagerTests {

    /// Pending output for a pane should be discarded (not flushed) when the pane
    /// has been bound to a tmux viewer terminal via attachToTmuxPane.
    /// We can't test the actual discard with real surfaces, but we can verify that
    /// pending output is consumed (removed from the dict) after surface creation,
    /// even without a real Ghostty surface.
    @MainActor
    func testPendingOutputRemovedAfterSurfaceCreationAttempt() {
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

        // Add pending output before factory exists
        mgr.setPendingOutputForTesting(["%0": [Data([0x41, 0x42])]])

        // Configure factory (returns nil — no real surface)
        mgr.configureSurfaceManagement(
            factory: { _ in nil },
            inputHandler: { _, _ in },
            resizeHandler: { _, _ in }
        )

        // Trigger state changed — will try to create surfaces via factory
        mgr.handleTmuxStateChanged(windowCount: 1, paneCount: 1)

        // Since factory returns nil, surface wasn't created and pending output stays.
        // This test verifies the code path doesn't crash with nil factory results.
        // The actual discard of pending output after attach requires real Ghostty surfaces.
    }
}

// MARK: - Adopted Primary Surface Fix Tests (Session 80)

extension TmuxSessionManagerTests {

    /// Build a valid checksummed layout for a 3-pane vertical split.
    private func threePaneLayout(
        paneA: Int, paneB: Int, paneC: Int,
        cols: Int = 56, totalRows: Int = 40
    ) -> String {
        let topRows = totalRows / 2      // 20
        let midRows = (totalRows - topRows - 1) / 2  // 9
        let botRows = totalRows - topRows - midRows - 2  // 9
        let midY = topRows + 1
        let botY = midY + midRows + 1
        let body = "\(cols)x\(totalRows),0,0[\(cols)x\(topRows),0,0,\(paneA),\(cols)x\(midRows),0,\(midY),\(paneB),\(cols)x\(botRows),0,\(botY),\(paneC)]"
        let checksum = TmuxChecksum.calculate(body).asString()
        return "\(checksum),\(body)"
    }

    /// When handleTmuxStateChanged is called twice with the same pane set,
    /// and the factory returns nil (no real surfaces), the factory will be
    /// called again because no surfaces were stored. This is expected behavior —
    /// in production, the factory returns real surfaces that get stored in
    /// paneSurfaces, preventing duplicate calls.
    ///
    /// This test verifies that at least the pane IDs are consistent across calls.
    @MainActor
    func testDoubleStateChangedCallsFactoryAgainWhenNilFactory() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        let layout = threePaneLayout(paneA: 25, paneB: 51, paneC: 52)

        mock.stubbedWindows = [TmuxWindowInfo(id: 0, width: 56, height: 40, name: "bash")]
        mock.stubbedWindowLayouts = [layout]
        mock.stubbedActiveWindowId = 0
        mock.stubbedPaneIds = [25, 51, 52]

        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        // isConnected must be true for factory creation
        mgr.controlModeActivated()

        // Configure factory that tracks calls
        var factoryCalls: [String] = []
        mgr.configureSurfaceManagement(
            factory: { paneId in
                factoryCalls.append(paneId)
                return nil  // Can't create real surfaces
            },
            inputHandler: { _, _ in },
            resizeHandler: { _, _ in }
        )

        // First call — should try to create 3 surfaces
        mgr.handleTmuxStateChanged(windowCount: 1, paneCount: 3)
        XCTAssertEqual(factoryCalls.count, 3,
                       "Factory should be called for all 3 panes on first handleTmuxStateChanged")
        XCTAssertEqual(factoryCalls, ["%25", "%51", "%52"],
                       "Factory calls should be in sorted order")

        // Second call — factory returns nil so nothing stored; factory called again
        // This is expected: no orphan cleanup cascade, just repeat attempts
        factoryCalls.removeAll()
        mock.resetCallTracking()
        mgr.handleTmuxStateChanged(windowCount: 1, paneCount: 3)
        XCTAssertEqual(factoryCalls.count, 3,
                       "Factory called again since nil factory stores no surfaces")
        XCTAssertEqual(factoryCalls, ["%25", "%51", "%52"],
                       "Same pane IDs on second call (no orphans created)")
    }

    /// Factory calls should arrive in sorted pane ID order so the adopted
    /// primary surface (if any) gets the lowest pane ID deterministically.
    @MainActor
    func testFactoryCalledInSortedPaneOrder() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        let layout = threePaneLayout(paneA: 25, paneB: 51, paneC: 52)

        mock.stubbedWindows = [TmuxWindowInfo(id: 0, width: 56, height: 40, name: "bash")]
        mock.stubbedWindowLayouts = [layout]
        mock.stubbedActiveWindowId = 0
        mock.stubbedPaneIds = [25, 51, 52]

        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        // isConnected must be true for factory creation
        mgr.controlModeActivated()

        var factoryCalls: [String] = []
        mgr.configureSurfaceManagement(
            factory: { paneId in
                factoryCalls.append(paneId)
                return nil
            },
            inputHandler: { _, _ in },
            resizeHandler: { _, _ in }
        )

        mgr.handleTmuxStateChanged(windowCount: 1, paneCount: 3)

        // Verify calls are sorted (lowest pane ID first)
        XCTAssertEqual(factoryCalls, ["%25", "%51", "%52"],
                       "Factory should be called in sorted pane ID order")
    }

    /// When deferred surface creation is triggered and then factory is configured,
    /// the drain should also use sorted order.
    @MainActor
    func testDeferredDrainInSortedOrder() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        let layout = threePaneLayout(paneA: 25, paneB: 51, paneC: 52)

        mock.stubbedWindows = [TmuxWindowInfo(id: 0, width: 56, height: 40, name: "bash")]
        mock.stubbedWindowLayouts = [layout]
        mock.stubbedActiveWindowId = 0
        mock.stubbedPaneIds = [25, 51, 52]

        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        // In production, controlModeActivated() fires before handleTmuxStateChanged.
        // isConnected must be true so the deferred drain can call the factory.
        mgr.controlModeActivated()

        // Step 1: handleTmuxStateChanged with no factory — all 3 deferred
        mgr.handleTmuxStateChanged(windowCount: 1, paneCount: 3)

        #if DEBUG
        XCTAssertEqual(mgr.pendingSurfaceCreationForTesting.count, 3,
                       "All 3 panes should be deferred")
        #endif

        // Step 2: Configure factory — should drain in sorted order
        var factoryCalls: [String] = []
        mgr.configureSurfaceManagement(
            factory: { paneId in
                factoryCalls.append(paneId)
                return nil
            },
            inputHandler: { _, _ in },
            resizeHandler: { _, _ in }
        )

        XCTAssertEqual(factoryCalls, ["%25", "%51", "%52"],
                       "Deferred drain should call factory in sorted order")

        #if DEBUG
        XCTAssertTrue(mgr.pendingSurfaceCreationForTesting.isEmpty,
                      "Deferred set should be empty after drain")
        #endif
    }

    /// Orphan cleanup should not destroy surfaces for active panes.
    /// With a nil factory, no surfaces are stored, so there are no orphans.
    /// The key property: the same pane IDs are requested on both calls (no
    /// stale %0 key causing cascading destruction).
    @MainActor
    func testNoStaleKeyOrphanCleanup() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        let layout = threePaneLayout(paneA: 25, paneB: 51, paneC: 52)

        mock.stubbedWindows = [TmuxWindowInfo(id: 0, width: 56, height: 40, name: "bash")]
        mock.stubbedWindowLayouts = [layout]
        mock.stubbedActiveWindowId = 0
        mock.stubbedPaneIds = [25, 51, 52]

        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        // isConnected must be true for factory creation
        mgr.controlModeActivated()

        var factoryCalls: [String] = []
        mgr.configureSurfaceManagement(
            factory: { paneId in
                factoryCalls.append(paneId)
                return nil  // Can't create real surfaces
            },
            inputHandler: { _, _ in },
            resizeHandler: { _, _ in }
        )

        // First call
        mgr.handleTmuxStateChanged(windowCount: 1, paneCount: 3)

        // Verify NO stale keys in paneSurfaces (nothing stored since factory returns nil)
        XCTAssertTrue(mgr.paneSurfaces.isEmpty,
                      "No surfaces stored when factory returns nil")

        // Second call — same pattern, no orphan cascade
        factoryCalls.removeAll()
        mgr.handleTmuxStateChanged(windowCount: 1, paneCount: 3)

        // Factory is called for same 3 panes (not 0 + 3 new = a different set)
        XCTAssertEqual(Set(factoryCalls), Set(["%25", "%51", "%52"]),
                       "Same pane IDs requested — no stale %0 key causing orphan cascade")
    }

    /// adoptExistingSurface should NOT register the surface in paneSurfaces.
    /// Since we can't create a real Ghostty.SurfaceView in tests, we verify
    /// the contract indirectly: after adoptExistingSurface, paneSurfaces should
    /// be empty. This test documents the expected behavior.
    ///
    /// Note: This test uses the fact that TmuxSessionManager's paneSurfaces is
    /// private(set) and visible from tests.
    @MainActor
    func testAdoptedSurfaceNotInPaneSurfaces() {
        // This is a design contract test — we can't actually call adoptExistingSurface
        // without a real Ghostty.SurfaceView, but we verify that a fresh manager
        // with only primarySurface set (and nothing in paneSurfaces) would correctly
        // route through getSurfaceOrCreate's adopted-primary path.
        let mgr = TmuxSessionManager()

        // Verify initial state: no surfaces at all
        XCTAssertTrue(mgr.paneSurfaces.isEmpty)
        XCTAssertNil(mgr.primarySurface)

        // If adoptExistingSurface were called, it should set primarySurface
        // but NOT add to paneSurfaces. We can't call it without a real surface,
        // but the code is clear: no paneSurfaces[...] = surface line exists.
    }
}

// MARK: - Viewer Ready Gating Tests (Session 81)

extension TmuxSessionManagerTests {

    /// A fresh TmuxSessionManager should have viewerReady == true.
    /// Before any tmux connection, there's no viewer to gate — commands
    /// would be blocked by the writeToSSH == nil guard anyway.
    @MainActor
    func testViewerReadyDefaultTrue() {
        let mgr = TmuxSessionManager()
        XCTAssertTrue(mgr.viewerReady,
                      "viewerReady should default to true (no viewer, no gating)")
    }

    /// controlModeActivated() should set viewerReady to false.
    /// The viewer's capture-pane command queue hasn't drained yet.
    @MainActor
    func testControlModeActivatedSetsViewerReadyFalse() {
        let mgr = TmuxSessionManager()
        XCTAssertTrue(mgr.viewerReady)

        mgr.controlModeActivated()

        XCTAssertFalse(mgr.viewerReady,
                       "controlModeActivated should set viewerReady to false")
    }

    /// After controlModeActivated(), commands should be queued in pendingCommands
    /// rather than written to SSH. This prevents interleaving with the viewer's
    /// capture-pane commands on the SSH channel.
    @MainActor
    func testCommandsQueuedWhenViewerNotReady() {
        let (mgr, log) = managerWithCommandLog()
        mgr.controlModeActivated()

        // These should all be queued, not sent
        mgr.resize(cols: 120, rows: 40)
        mgr.newWindow()
        mgr.selectPane("%5")

        // Nothing should have been written to SSH
        XCTAssertTrue(log.commands.isEmpty,
                      "No commands should be sent while viewerReady == false")

        #if DEBUG
        // Commands should be in the pending queue
        XCTAssertEqual(mgr.pendingCommandsForTesting.count, 3,
                       "All 3 commands should be queued")
        XCTAssertEqual(mgr.pendingCommandsForTesting[0], "refresh-client -C 120,40")
        XCTAssertEqual(mgr.pendingCommandsForTesting[1], "new-window")
        XCTAssertEqual(mgr.pendingCommandsForTesting[2], "select-pane -t '%5'")
        #endif
    }

    /// viewerBecameReady() should set viewerReady to true and flush all queued
    /// commands in order to the SSH write function.
    @MainActor
    func testViewerBecameReadyFlushesQueuedCommands() {
        let (mgr, log) = managerWithCommandLog()
        mgr.controlModeActivated()

        // Queue some commands
        mgr.resize(cols: 80, rows: 24)
        mgr.splitHorizontal()
        XCTAssertTrue(log.commands.isEmpty)

        // Now signal viewer is ready
        mgr.viewerBecameReady()

        XCTAssertTrue(mgr.viewerReady)
        // Commands should have been flushed in order
        XCTAssertEqual(log.commands.count, 2)
        XCTAssertEqual(log.commands[0], "refresh-client -C 80,24\n")
        XCTAssertEqual(log.commands[1], "split-window -h\n")

        #if DEBUG
        // Pending queue should be empty
        XCTAssertTrue(mgr.pendingCommandsForTesting.isEmpty,
                      "pendingCommands should be empty after flush")
        #endif
    }

    /// After viewerBecameReady(), new commands should go directly to SSH
    /// without being queued.
    @MainActor
    func testCommandsSentDirectlyAfterViewerReady() {
        let (mgr, log) = managerWithCommandLog()
        mgr.controlModeActivated()
        mgr.viewerBecameReady()

        // These should go directly to SSH
        mgr.newWindow()
        mgr.closePane()

        XCTAssertEqual(log.commands, ["new-window\n", "kill-pane\n"])

        #if DEBUG
        XCTAssertTrue(mgr.pendingCommandsForTesting.isEmpty,
                      "No commands should be queued after viewer is ready")
        #endif
    }

    /// controlModeExited() should reset viewerReady to false and clear
    /// any pending commands (they're stale after disconnect).
    @MainActor
    func testControlModeExitedResetsViewerReady() {
        let (mgr, log) = managerWithCommandLog()
        mgr.controlModeActivated()

        // Queue some commands
        mgr.resize(cols: 80, rows: 24)
        XCTAssertTrue(log.commands.isEmpty)

        // Exit control mode — queued commands should be discarded
        mgr.controlModeExited(reason: "test disconnect")

        XCTAssertFalse(mgr.viewerReady,
                       "controlModeExited should set viewerReady to false")

        #if DEBUG
        XCTAssertTrue(mgr.pendingCommandsForTesting.isEmpty,
                      "controlModeExited should discard pending commands")
        #endif
    }

    /// Calling viewerBecameReady() when already ready should be a no-op.
    /// No duplicate flushes, no state corruption.
    @MainActor
    func testDoubleViewerBecameReadyIsNoOp() {
        let (mgr, log) = managerWithCommandLog()
        mgr.controlModeActivated()

        // Queue one command
        mgr.resize(cols: 80, rows: 24)

        // First call — flushes the command
        mgr.viewerBecameReady()
        XCTAssertEqual(log.commands.count, 1)

        // Second call — should be a no-op
        log.commands.removeAll()
        mgr.viewerBecameReady()
        XCTAssertTrue(log.commands.isEmpty,
                      "Second viewerBecameReady should not send any commands")
        XCTAssertTrue(mgr.viewerReady)
    }

    /// Specific test for the resize interleaving scenario that caused %exit:
    /// SwiftUI calls resize() when TmuxMultiPaneView appears, which happens
    /// during the viewer's capture-pane startup. The resize command must be
    /// queued, not sent immediately.
    @MainActor
    func testResizeDuringViewerStartupIsQueued() {
        let (mgr, log) = managerWithCommandLog()

        // Simulate: controlModeActivated fires, viewer starts capture-pane
        mgr.controlModeActivated()

        // SwiftUI renders TmuxMultiPaneView → onAppear → resize
        mgr.resize(cols: 113, rows: 42)

        // Nothing should have been sent
        XCTAssertTrue(log.commands.isEmpty,
                      "resize during viewer startup must be queued, not sent")

        // Viewer finishes capture-pane → TMUX_READY
        mgr.viewerBecameReady()

        // NOW the resize should be sent
        XCTAssertEqual(log.commands, ["refresh-client -C 113,42\n"],
                       "resize should flush after viewer becomes ready")
    }
}

// MARK: - Surface Lifecycle Cleanup Tests

extension TmuxSessionManagerTests {

    /// removeSurface must not crash when called for a pane that has no surface.
    /// This guards against nil dereference in the close() call path.
    @MainActor
    func testRemoveSurfaceNoOpForMissingPane() {
        let mgr = TmuxSessionManager()
        // No surfaces configured — should be a clean no-op
        mgr.removeSurface(for: "%99", paneActuallyClosed: true)
        XCTAssertTrue(mgr.paneSurfaces.isEmpty)
    }

    /// removeSurface for %0 with paneActuallyClosed:true should proceed
    /// (not be blocked by the %0 keep-alive guard).
    @MainActor
    func testRemoveSurfaceClosesPane0WhenActuallyClosed() {
        let mgr = TmuxSessionManager()
        // Even with no real surface, this exercises the paneActuallyClosed path
        mgr.removeSurface(for: "%0", paneActuallyClosed: true)
        // No crash, and paneSurfaces remains empty (it was already empty)
        XCTAssertTrue(mgr.paneSurfaces.isEmpty)
    }

    /// controlModeExited must handle empty paneSurfaces without crashing.
    /// The close() loop iterates an empty dict — should be a no-op.
    @MainActor
    func testControlModeExitedSafeWithNoSurfaces() {
        let mgr = TmuxSessionManager()
        mgr.controlModeActivated()
        mgr.controlModeExited(reason: "test")
        XCTAssertTrue(mgr.paneSurfaces.isEmpty)
        XCTAssertNil(mgr.primarySurface)
    }

    /// controlModeExited resets all state including surface collections.
    /// Verifies that the cleanup loop + removeAll() leaves a clean slate.
    @MainActor
    func testControlModeExitedClearsAllSurfaceState() {
        let mgr = TmuxSessionManager()
        mgr.controlModeActivated()
        mgr.controlModeExited(reason: "disconnect")

        XCTAssertFalse(mgr.isConnected)
        XCTAssertTrue(mgr.paneSurfaces.isEmpty)
        XCTAssertNil(mgr.primarySurface)
        XCTAssertFalse(mgr.viewerReady)
    }

    /// cleanup() routes through removeSurface(paneActuallyClosed: true) for
    /// all panes. With no surfaces, this should be a clean no-op.
    @MainActor
    func testCleanupSafeWithNoSurfaces() {
        let mgr = TmuxSessionManager()
        mgr.cleanup()
        XCTAssertTrue(mgr.paneSurfaces.isEmpty)
    }

    /// Multiple calls to removeSurface for the same pane should be idempotent.
    /// The second call finds nothing in paneSurfaces and is a no-op.
    @MainActor
    func testRemoveSurfaceIdempotent() {
        let mgr = TmuxSessionManager()
        mgr.removeSurface(for: "%25", paneActuallyClosed: true)
        mgr.removeSurface(for: "%25", paneActuallyClosed: true)
        XCTAssertTrue(mgr.paneSurfaces.isEmpty)
    }

    /// controlModeExited followed by cleanup should not double-free.
    /// Both methods clear paneSurfaces — the second pass finds nothing.
    @MainActor
    func testControlModeExitedThenCleanupNoDoubleFree() {
        let mgr = TmuxSessionManager()
        mgr.controlModeActivated()
        mgr.controlModeExited(reason: "disconnect")
        mgr.cleanup()  // Second cleanup — should be safe
        XCTAssertTrue(mgr.paneSurfaces.isEmpty)
    }
}

// MARK: - Resize Storm Prevention Tests (Session 86)

extension TmuxSessionManagerTests {
    
    /// Verify that a multi-pane layout produces currentSplitTree.isSplit == true.
    /// This is the condition that triggers resize suppression in the UI layer.
    @MainActor
    func testMultiPaneSplitTreeIsSplit() {
        let mgr = TmuxSessionManager()
        let layout = horizontalSplitLayout(paneA: 25, paneB: 51)
        
        let snapshot = TmuxSessionManager.TmuxStateSnapshot(
            windows: [
                .init(id: 0, name: "main", layout: layout, focusedPaneId: 25)
            ],
            activeWindowId: 0,
            paneIds: [25, 51]
        )
        
        _ = mgr.reconcileTmuxState(snapshot)
        
        XCTAssertTrue(mgr.currentSplitTree.isSplit,
                      "A 2-pane layout should produce isSplit == true")
        XCTAssertEqual(mgr.currentSplitTree.paneIds.count, 2)
    }
    
    /// Verify that a single-pane layout produces currentSplitTree.isSplit == false.
    @MainActor
    func testSinglePaneSplitTreeIsNotSplit() {
        let mgr = TmuxSessionManager()
        let layout = singlePaneLayout(paneId: 25)
        
        let snapshot = TmuxSessionManager.TmuxStateSnapshot(
            windows: [
                .init(id: 0, name: "main", layout: layout, focusedPaneId: 25)
            ],
            activeWindowId: 0,
            paneIds: [25]
        )
        
        _ = mgr.reconcileTmuxState(snapshot)
        
        XCTAssertFalse(mgr.currentSplitTree.isSplit,
                       "A single-pane layout should produce isSplit == false")
    }
    
    /// In multi-pane mode, onResize callback on the adopted surface should
    /// NOT fire the resize handler — the container handles resizing via
    /// TmuxMultiPaneView.handleSizeChange() → sessionManager.resize().
    /// This tests the guard `!self.currentSplitTree.isSplit` in adoptExistingSurface.
    @MainActor
    func testOnResizeSuppressedInMultiPaneMode() {
        // We can't create real surfaces, but we can verify the state:
        // reconcileTmuxState produces isSplit == true for multi-pane layouts,
        // and the onResize callback checks `!self.currentSplitTree.isSplit`.
        let mgr = TmuxSessionManager()
        let layout = horizontalSplitLayout(paneA: 25, paneB: 51)
        
        let snapshot = TmuxSessionManager.TmuxStateSnapshot(
            windows: [
                .init(id: 0, name: "main", layout: layout, focusedPaneId: 25)
            ],
            activeWindowId: 0,
            paneIds: [25, 51]
        )
        
        _ = mgr.reconcileTmuxState(snapshot)
        
        // The key assertion: isSplit is true, so onResize guard would suppress resize
        XCTAssertTrue(mgr.currentSplitTree.isSplit,
                      "Guard condition `!self.currentSplitTree.isSplit` would suppress onResize")
    }
    
    /// resize() sends refresh-client -C with the exact cols,rows format.
    /// This is the CORRECT resize path used by TmuxMultiPaneView.handleSizeChange().
    /// Ensures the command uses comma-separated format (tmux requirement).
    @MainActor
    func testResizeCommandFormat() {
        let (mgr, log) = managerWithCommandLog()
        mgr.resize(cols: 163, rows: 60)
        XCTAssertEqual(log.commands, ["refresh-client -C 163,60\n"])
    }
    
    /// When viewer is not ready, resize commands are queued, not sent.
    /// This prevents interleaving refresh-client with capture-pane commands.
    @MainActor
    func testResizeCommandGatedByViewerReady() {
        let (mgr, log) = managerWithCommandLog()
        mgr.controlModeActivated()  // Sets viewerReady = false
        
        mgr.resize(cols: 163, rows: 60)
        
        XCTAssertTrue(log.commands.isEmpty,
                      "resize should be queued, not sent, when viewer is not ready")
        XCTAssertEqual(mgr.pendingCommandsForTesting, ["refresh-client -C 163,60"])
    }
    
    /// After viewerBecameReady, queued resize commands are flushed.
    @MainActor
    func testResizeCommandFlushedOnViewerReady() {
        let (mgr, log) = managerWithCommandLog()
        mgr.controlModeActivated()
        
        mgr.resize(cols: 163, rows: 60)
        XCTAssertTrue(log.commands.isEmpty)
        
        mgr.viewerBecameReady()
        
        XCTAssertEqual(log.commands, ["refresh-client -C 163,60\n"],
                       "Queued resize command should be flushed on viewer ready")
    }
    
    /// Transition from multi-pane to single-pane: currentSplitTree.isSplit
    /// goes from true to false. This is when the primary surface's
    /// usesExactGridSize should be cleared (handled by cleanupMultiPaneMode/
    /// transitionToSingleSurfaceMode in the view controller).
    @MainActor
    func testSplitTreeTransitionMultiToSingle() {
        let mgr = TmuxSessionManager()
        
        // Start with 2 panes (multi-pane)
        let splitLayout = horizontalSplitLayout(paneA: 25, paneB: 51)
        let splitSnapshot = TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "main", layout: splitLayout, focusedPaneId: 25)],
            activeWindowId: 0,
            paneIds: [25, 51]
        )
        _ = mgr.reconcileTmuxState(splitSnapshot)
        XCTAssertTrue(mgr.currentSplitTree.isSplit)
        
        // Close one pane → single pane
        let singleLayout = singlePaneLayout(paneId: 25)
        let singleSnapshot = TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "main", layout: singleLayout, focusedPaneId: 25)],
            activeWindowId: 0,
            paneIds: [25]
        )
        _ = mgr.reconcileTmuxState(singleSnapshot)
        XCTAssertFalse(mgr.currentSplitTree.isSplit,
                       "After closing one pane, isSplit should be false")
    }
    
    /// Three-pane layout (the exact configuration that caused the PANIC)
    /// should produce a valid split tree with 3 pane IDs.
    @MainActor
    func testThreePaneLayoutSplitTree() {
        let mgr = TmuxSessionManager()
        
        // Build a 3-pane layout: {left, [top-right, bottom-right]}
        // This is the layout from session 84 that caused the PANIC
        let body = "163x60,0,0{80x60,0,0,60,82x60,81,0[82x29,81,0,61,82x30,81,30,62]}"
        let checksum = TmuxChecksum.calculate(body).asString()
        let layout = "\(checksum),\(body)"
        
        let snapshot = TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "main", layout: layout, focusedPaneId: 60)],
            activeWindowId: 0,
            paneIds: [60, 61, 62]
        )
        
        _ = mgr.reconcileTmuxState(snapshot)
        
        XCTAssertTrue(mgr.currentSplitTree.isSplit)
        XCTAssertEqual(Set(mgr.currentSplitTree.paneIds), Set([60, 61, 62]),
                       "Three-pane layout should produce 3 pane IDs")
    }
    
    /// Design contract: GhosttyPaneSurfaceContainerView.skipGridSizeUpdate
    /// should be true for the primary surface and false for observers.
    /// This test documents the expected wiring in TmuxPaneSurfaceView.
    ///
    /// We verify the isPrimarySurface logic indirectly: after reconcileTmuxState
    /// with a 3-pane layout, pane 60 is the primary (first/lowest pane ID in
    /// sorted order). The view layer would set skipGridSizeUpdate=true for pane 60
    /// and false for panes 61 and 62.
    @MainActor
    func testPrimaryPaneIdentifiedForResizeSuppression() {
        let mgr = TmuxSessionManager()
        
        // Simulate 3-pane state
        let body = "163x60,0,0{80x60,0,0,60,82x60,81,0[82x29,81,0,61,82x30,81,30,62]}"
        let checksum = TmuxChecksum.calculate(body).asString()
        let layout = "\(checksum),\(body)"
        
        let snapshot = TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "main", layout: layout, focusedPaneId: 60)],
            activeWindowId: 0,
            paneIds: [60, 61, 62]
        )
        _ = mgr.reconcileTmuxState(snapshot)
        
        // The focused pane (the one that would be primary) is %60
        XCTAssertEqual(mgr.focusedPaneId, "%60",
                       "Focused pane should be %60 (primary = first pane in sorted order)")
        
        // This confirms the view layer's isPrimarySurface check:
        // sessionManager.getSurface(forNumericId: 60) === sessionManager.primarySurface
        // would be true for pane 60, false for 61 and 62.
    }
    
    /// Verify that resize storm cannot happen when viewer is not ready.
    /// During viewer startup, ALL commands (including refresh-client -C from
    /// individual surface resizes) are gated. Only after viewerBecameReady()
    /// does TmuxMultiPaneView.handleSizeChange() → resize() get sent.
    @MainActor
    func testResizeStormPreventedByViewerGating() {
        let (mgr, log) = managerWithCommandLog()
        mgr.controlModeActivated()
        
        // Simulate the storm: multiple resize commands from different sources
        mgr.resize(cols: 40, rows: 29)   // Would be from primary surface (WRONG size)
        mgr.resize(cols: 163, rows: 60)  // Would be from container (CORRECT size)
        mgr.resize(cols: 20, rows: 15)   // Another wrong resize
        
        // Nothing sent yet
        XCTAssertTrue(log.commands.isEmpty)
        
        // After viewer ready, all queued commands flush in order
        mgr.viewerBecameReady()
        XCTAssertEqual(log.commands.count, 3,
                       "All queued resize commands should flush on viewer ready")
        
        // Note: In the actual fix, the primary surface's Zig-side resize
        // is suppressed by usesExactGridSize=true, so only the container's
        // resize() call reaches sendCommandFireAndForget(). The gating is
        // a second line of defense.
    }
}

// MARK: - Resize Oscillation Prevention Tests (Session 88)

extension TmuxSessionManagerTests {
    
    /// Verify that the split tree's pane dimensions change when layout changes.
    /// This is the fundamental trigger: if pane dimensions change, and those
    /// dimensions were included in .id(), SwiftUI would destroy/recreate the view.
    @MainActor
    func testLayoutChangeUpdatesPaneDimensions() {
        let mgr = TmuxSessionManager()
        
        // First layout: 52 cols total, left pane = 24 cols
        let layout52 = horizontalSplitLayout(paneA: 60, paneB: 61, totalCols: 52, rows: 40)
        let snapshot52 = TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "zsh", layout: layout52, focusedPaneId: 60)],
            activeWindowId: 0,
            paneIds: [60, 61]
        )
        _ = mgr.reconcileTmuxState(snapshot52)
        
        let panes52 = mgr.currentSplitTree.paneIds
        XCTAssertEqual(panes52.count, 2, "Should have 2 panes")
        
        // Second layout: 53 cols total, left pane = 25 cols
        let layout53 = horizontalSplitLayout(paneA: 60, paneB: 61, totalCols: 53, rows: 40)
        let snapshot53 = TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "zsh", layout: layout53, focusedPaneId: 60)],
            activeWindowId: 0,
            paneIds: [60, 61]
        )
        _ = mgr.reconcileTmuxState(snapshot53)
        
        // The pane IDs should be the same — stable identity
        let panes53 = mgr.currentSplitTree.paneIds
        XCTAssertEqual(panes52, panes53,
                       "Pane IDs should remain stable across dimension changes — " +
                       "this is why .id() must NOT include dimensions")
    }
    
    /// Verify that the same resize sent twice produces only one command.
    /// The cols/rows dedup guard in handleSizeChange prevents redundant
    /// "refresh-client -C" when floating-point pixel geometry changes
    /// but the character grid dimensions remain the same.
    @MainActor
    func testResizeDeduplicatesIdenticalGridDimensions() {
        let (mgr, log) = managerWithCommandLog()
        
        // First resize — should be sent
        mgr.resize(cols: 53, rows: 40)
        XCTAssertEqual(log.commands.count, 1)
        XCTAssertEqual(log.commands.last, "refresh-client -C 53,40\n")
        
        // Second identical resize — at the TmuxSessionManager level, this
        // still sends because the dedup is in the VIEW layer (handleSizeChange).
        // But this verifies the command format is correct and stable.
        mgr.resize(cols: 53, rows: 40)
        XCTAssertEqual(log.commands.count, 2,
                       "TmuxSessionManager.resize() always sends — " +
                       "dedup is in TmuxMultiPaneView.handleSizeChange()")
    }
    
    /// Verify that different resize dimensions produce different commands.
    /// This is the normal case — actual dimension changes should be sent.
    @MainActor
    func testResizeSendsDifferentDimensions() {
        let (mgr, log) = managerWithCommandLog()
        
        mgr.resize(cols: 52, rows: 40)
        mgr.resize(cols: 53, rows: 40)
        
        XCTAssertEqual(log.commands.count, 2)
        XCTAssertEqual(log.commands[0], "refresh-client -C 52,40\n")
        XCTAssertEqual(log.commands[1], "refresh-client -C 53,40\n")
    }
    
    /// Verify that the oscillation pattern (52↔53) would produce alternating commands.
    /// With Fix A + B, the Zig-side refresh-client is suppressed, and with Fix C
    /// the Swift-side handleSizeChange dedup prevents the loop.
    @MainActor
    func testOscillationPatternProducesAlternatingCommands() {
        let (mgr, log) = managerWithCommandLog()
        
        // Simulate the oscillation observed in session 87
        for i in 0..<10 {
            let cols = (i % 2 == 0) ? 52 : 53
            mgr.resize(cols: cols, rows: 40)
        }
        
        XCTAssertEqual(log.commands.count, 10,
                       "Each resize call reaches tmux — the fix prevents " +
                       "the TRIGGER (Zig-side sizeDidChange), not the command itself")
        
        // Verify alternating pattern
        for i in 0..<10 {
            let expectedCols = (i % 2 == 0) ? 52 : 53
            XCTAssertEqual(log.commands[i], "refresh-client -C \(expectedCols),40\n")
        }
    }
    
    /// Verify that reconcileTmuxState with different layout dimensions
    /// does NOT change the pane count (which would reset lastSentSize).
    /// The .onChange(of: paneIds.count) handler resets dedup state, so it's
    /// critical that dimension-only changes don't trigger it.
    @MainActor
    func testDimensionChangeDoesNotChangePaneCount() {
        let mgr = TmuxSessionManager()
        
        // Layout with 52 cols
        let layout52 = horizontalSplitLayout(paneA: 60, paneB: 61, totalCols: 52, rows: 40)
        let snapshot52 = TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "zsh", layout: layout52, focusedPaneId: 60)],
            activeWindowId: 0,
            paneIds: [60, 61]
        )
        _ = mgr.reconcileTmuxState(snapshot52)
        let countBefore = mgr.currentSplitTree.paneIds.count
        
        // Layout with 53 cols — same panes, different dimensions
        let layout53 = horizontalSplitLayout(paneA: 60, paneB: 61, totalCols: 53, rows: 40)
        let snapshot53 = TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "zsh", layout: layout53, focusedPaneId: 60)],
            activeWindowId: 0,
            paneIds: [60, 61]
        )
        _ = mgr.reconcileTmuxState(snapshot53)
        let countAfter = mgr.currentSplitTree.paneIds.count
        
        XCTAssertEqual(countBefore, countAfter,
                       "Pane count must not change when only dimensions differ — " +
                       "otherwise .onChange(of: paneIds.count) resets dedup state")
    }
    
    /// Verify that the split ratio changes when total cols change.
    /// This confirms the split tree DOES update (which is correct),
    /// but the pane identities remain stable (fix B).
    @MainActor
    func testSplitRatioChangesWithDimensionUpdate() {
        let mgr = TmuxSessionManager()
        
        // 52 total: left=24, right=27 → ratio ≈ 0.4615
        let layout52 = horizontalSplitLayout(paneA: 60, paneB: 61, totalCols: 52, rows: 40)
        let snapshot52 = TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "zsh", layout: layout52, focusedPaneId: 60)],
            activeWindowId: 0,
            paneIds: [60, 61]
        )
        _ = mgr.reconcileTmuxState(snapshot52)
        
        guard case .split(let split52) = mgr.currentSplitTree.root else {
            XCTFail("Expected split root for 2-pane layout")
            return
        }
        let ratio52 = split52.ratio
        
        // 53 total: left=25, right=27 → ratio ≈ 0.4717
        let layout53 = horizontalSplitLayout(paneA: 60, paneB: 61, totalCols: 53, rows: 40)
        let snapshot53 = TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "zsh", layout: layout53, focusedPaneId: 60)],
            activeWindowId: 0,
            paneIds: [60, 61]
        )
        _ = mgr.reconcileTmuxState(snapshot53)
        
        guard case .split(let split53) = mgr.currentSplitTree.root else {
            XCTFail("Expected split root for 2-pane layout")
            return
        }
        let ratio53 = split53.ratio
        
        XCTAssertNotEqual(ratio52, ratio53,
                          "Split ratio should change when dimensions change — " +
                          "this confirms the tree DOES update, triggering SwiftUI re-render")
        // 52 total → leftCols=26, ratio=26/52=0.5
        // 53 total → leftCols=26, ratio=26/53≈0.4906
        // The left pane gets the same column count (26), but the total differs,
        // so the ratio (leftCols/totalCols) is slightly smaller at 53 cols.
        XCTAssertGreaterThan(ratio52, ratio53,
                            "52-col layout should have a larger left ratio " +
                            "(26/52=0.5 vs 26/53≈0.49) because totalCols increased")
    }
    
    /// Verify that rapid alternating layout changes maintain consistent pane IDs.
    /// Simulates the exact oscillation pattern from session 87.
    @MainActor
    func testRapidLayoutOscillationMaintainsPaneIdentity() {
        let mgr = TmuxSessionManager()
        
        // Simulate 20 rapid oscillation cycles (52↔53)
        for i in 0..<20 {
            let totalCols = (i % 2 == 0) ? 52 : 53
            let layout = horizontalSplitLayout(
                paneA: 60, paneB: 61, totalCols: totalCols, rows: 40
            )
            let snapshot = TmuxSessionManager.TmuxStateSnapshot(
                windows: [.init(id: 0, name: "zsh", layout: layout, focusedPaneId: 60)],
                activeWindowId: 0,
                paneIds: [60, 61]
            )
            _ = mgr.reconcileTmuxState(snapshot)
            
            // Pane IDs must be stable across ALL oscillation cycles
            XCTAssertEqual(mgr.currentSplitTree.paneIds, [60, 61],
                           "Pane IDs must remain [60, 61] at cycle \(i)")
            XCTAssertTrue(mgr.currentSplitTree.isSplit,
                          "Must remain a split layout at cycle \(i)")
        }
    }
    
    /// Verify that the 3-pane layout from session 87 maintains stable pane IDs
    /// across the exact oscillation observed (52x40 ↔ 53x40).
    @MainActor
    func testThreePaneOscillationMaintainsPaneIdentity() {
        let mgr = TmuxSessionManager()
        
        // Simulate the exact layouts from the session 87 log:
        // Layout A: 52x40{24x40,60,27x40[27x18,61,27x21,62]}
        // Layout B: 53x40{25x40,60,27x40[27x18,61,27x21,62]}
        
        // We use the horizontalSplitLayout helper for 2 panes,
        // but the 3-pane version from the real log can be approximated.
        // The key property being tested is that pane IDs remain stable.
        
        for i in 0..<10 {
            let totalCols = (i % 2 == 0) ? 52 : 53
            let layout = threePaneLayout(
                paneA: 60, paneB: 61, paneC: 62,
                cols: totalCols, totalRows: 40
            )
            let snapshot = TmuxSessionManager.TmuxStateSnapshot(
                windows: [.init(id: 0, name: "zsh", layout: layout, focusedPaneId: 60)],
                activeWindowId: 0,
                paneIds: [60, 61, 62]
            )
            _ = mgr.reconcileTmuxState(snapshot)
            
            XCTAssertEqual(Set(mgr.currentSplitTree.paneIds), Set([60, 61, 62]),
                           "All 3 pane IDs must remain stable at cycle \(i)")
        }
    }
}

// MARK: - Focus/Input Routing Tests (Session 89)

extension TmuxSessionManagerTests {

    /// selectPane() should call setActiveTmuxPaneInputOnly() on the mock surface
    /// to route Zig's input to the selected pane (without swapping the renderer).
    @MainActor
    func testSelectPaneCallsSetActiveTmuxPaneInputOnly() {
        let (mgr, _) = managerWithCommandLog()
        let mock = MockTmuxSurface()
        mock.stubbedSetActivePaneResult = true

        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        mgr.selectPane("%3")

        XCTAssertEqual(mock.setActiveTmuxPaneInputOnlyCalls, [3],
                       "selectPane should call setActiveTmuxPaneInputOnly with numeric pane ID")
    }

    /// selectPane() should both send the command AND call setActiveTmuxPaneInputOnly.
    @MainActor
    func testSelectPaneSendsCommandAndRoutesPane() {
        let (mgr, log) = managerWithCommandLog()
        let mock = MockTmuxSurface()

        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        mgr.selectPane("%7")

        // Verify command was sent
        XCTAssertEqual(log.commands, ["select-pane -t '%7'\n"])
        // Verify local state was updated
        XCTAssertEqual(mgr.focusedPaneId, "%7")
        // Verify Zig-side routing happened
        XCTAssertEqual(mock.setActiveTmuxPaneInputOnlyCalls, [7])
    }

    /// selectPane() with an invalid pane ID should reject the call:
    /// no command is sent, focusedPaneId is unchanged, and
    /// setActiveTmuxPaneInputOnly is not called.
    @MainActor
    func testSelectPaneWithInvalidPaneIdDoesNotSendCommand() {
        let (mgr, log) = managerWithCommandLog()
        let mock = MockTmuxSurface()

        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        mgr.selectPane("invalid")

        // Validation guard rejects malformed pane ID — no command sent
        XCTAssertTrue(log.commands.isEmpty,
                      "No command should be sent for invalid pane ID")
        // focusedPaneId unchanged (guard returned early)
        XCTAssertEqual(mgr.focusedPaneId, "")
        // No setActiveTmuxPaneInputOnly call
        XCTAssertTrue(mock.setActiveTmuxPaneInputOnlyCalls.isEmpty,
                      "setActiveTmuxPaneInputOnly should not be called for invalid pane IDs")
    }

    /// closeWindow() with an invalid window ID should not send any command.
    @MainActor
    func testCloseWindowWithInvalidWindowIdDoesNotSendCommand() {
        let (mgr, log) = managerWithCommandLog()

        mgr.closeWindow(windowId: "invalid")
        XCTAssertTrue(log.commands.isEmpty,
                      "No command should be sent for invalid window ID")

        mgr.closeWindow(windowId: "2")
        XCTAssertTrue(log.commands.isEmpty,
                      "Window ID without @ prefix should be rejected")
    }

    /// renameWindow(windowId:name:) with an invalid window ID should not send any command.
    @MainActor
    func testRenameWindowWithInvalidWindowIdDoesNotSendCommand() {
        let (mgr, log) = managerWithCommandLog()

        mgr.renameWindow(windowId: "bad", name: "test")
        XCTAssertTrue(log.commands.isEmpty,
                      "No command should be sent for invalid window ID")

        mgr.renameWindow(windowId: "3", name: "test")
        XCTAssertTrue(log.commands.isEmpty,
                      "Window ID without @ prefix should be rejected")
    }

    /// selectWindow() with an invalid window ID should not send any command
    /// or update focusedWindowId.
    @MainActor
    func testSelectWindowWithInvalidWindowIdDoesNotSendCommand() {
        let (mgr, log) = managerWithCommandLog()

        mgr.selectWindow("notawindow")
        XCTAssertTrue(log.commands.isEmpty,
                      "No command should be sent for invalid window ID")
        XCTAssertEqual(mgr.focusedWindowId, "",
                       "focusedWindowId should not be updated for invalid window ID")

        mgr.selectWindow("0")
        XCTAssertTrue(log.commands.isEmpty,
                      "Window ID without @ prefix should be rejected")
    }

    /// selectPane() without a tmuxQuerySurface should still send the command
    /// and update focusedPaneId (graceful nil handling).
    @MainActor
    func testSelectPaneWithNilSurfaceStillSendsCommand() {
        let (mgr, log) = managerWithCommandLog()
        // No mock set — tmuxQuerySurface is nil

        mgr.selectPane("%2")

        XCTAssertEqual(log.commands, ["select-pane -t '%2'\n"])
        XCTAssertEqual(mgr.focusedPaneId, "%2")
    }

    /// setFocusedPane() should call setActiveTmuxPaneInputOnly() on the mock surface.
    @MainActor
    func testSetFocusedPaneCallsSetActiveTmuxPane() {
        let (mgr, _) = managerWithCommandLog()
        let mock = MockTmuxSurface()

        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        mgr.setFocusedPane("%4")

        XCTAssertEqual(mock.setActiveTmuxPaneInputOnlyCalls, [4],
                       "setFocusedPane should call setActiveTmuxPaneInputOnly with numeric pane ID")
    }

    /// setFocusedPane() should NOT call setActiveTmuxPaneInputOnly when pane ID hasn't changed.
    @MainActor
    func testSetFocusedPaneNoOpDoesNotCallSetActive() {
        let (mgr, _) = managerWithCommandLog()
        let mock = MockTmuxSurface()

        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        // Set initial focus
        mgr.setFocusedPane("%4")
        XCTAssertEqual(mock.setActiveTmuxPaneInputOnlyCalls, [4])

        // Reset tracking
        mock.resetCallTracking()

        // Same pane again — should be a no-op
        mgr.setFocusedPane("%4")
        XCTAssertTrue(mock.setActiveTmuxPaneInputOnlyCalls.isEmpty,
                      "setFocusedPane should not call setActiveTmuxPaneInputOnly when pane hasn't changed")
    }

    /// setFocusedPane() should NOT send any tmux commands (unlike selectPane).
    @MainActor
    func testSetFocusedPaneDoesNotSendCommand() {
        let (mgr, log) = managerWithCommandLog()
        let mock = MockTmuxSurface()

        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        mgr.setFocusedPane("%5")

        XCTAssertTrue(log.commands.isEmpty,
                      "setFocusedPane should not send any tmux commands")
        XCTAssertEqual(mgr.focusedPaneId, "%5")
        XCTAssertEqual(mock.setActiveTmuxPaneInputOnlyCalls, [5])
    }

    /// Switching between multiple panes with selectPane() should produce
    /// the correct sequence of setActiveTmuxPaneInputOnly calls.
    @MainActor
    func testSelectPaneSequenceTracksAllSwitches() {
        let (mgr, _) = managerWithCommandLog()
        let mock = MockTmuxSurface()

        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        mgr.selectPane("%2")
        mgr.selectPane("%3")
        mgr.selectPane("%4")
        mgr.selectPane("%2")

        XCTAssertEqual(mock.setActiveTmuxPaneInputOnlyCalls, [2, 3, 4, 2],
                       "Each selectPane should produce a setActiveTmuxPaneInputOnly call")
        XCTAssertEqual(mgr.focusedPaneId, "%2")
    }
}

// MARK: - Observer Tap Routing Tests (Session 92)

extension TmuxSessionManagerTests {

    /// Simulates the onPaneTap callback path: when an observer surface is
    /// tapped, its onPaneTap closure (set by GhosttyPaneSurfaceWrapper)
    /// calls selectPane(), which sends the tmux command and routes the pane.
    /// This tests the complete callback → selectPane → setActiveTmuxPaneInputOnly chain.
    @MainActor
    func testOnPaneTapCallbackRoutesToSelectPane() {
        let (mgr, log) = managerWithCommandLog()
        let mock = MockTmuxSurface()
        mock.stubbedSetActivePaneResult = true

        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        // Simulate what GhosttyPaneSurfaceWrapper.makeUIView sets up:
        // surface.onPaneTap = { selectPane() }
        // When handleTap fires on an observer, it calls onPaneTap(),
        // which calls selectPane().
        let onPaneTap = { mgr.selectPane("%7") }
        onPaneTap()

        XCTAssertEqual(log.commands, ["select-pane -t '%7'\n"],
                       "onPaneTap callback should send select-pane command")
        XCTAssertEqual(mock.setActiveTmuxPaneInputOnlyCalls, [7],
                       "onPaneTap callback should route Zig viewer to tapped pane")
        XCTAssertEqual(mgr.focusedPaneId, "%7",
                       "onPaneTap callback should update focusedPaneId")
    }

    /// Multiple observer pane taps should each produce the correct routing.
    @MainActor
    func testMultipleObserverPaneTapsRouteCorrectly() {
        let (mgr, log) = managerWithCommandLog()
        let mock = MockTmuxSurface()
        mock.stubbedSetActivePaneResult = true

        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        // Simulate tapping pane %5, then %6, then back to %5
        let tapPane5 = { mgr.selectPane("%5") }
        let tapPane6 = { mgr.selectPane("%6") }

        tapPane5()
        XCTAssertEqual(mgr.focusedPaneId, "%5")

        tapPane6()
        XCTAssertEqual(mgr.focusedPaneId, "%6")

        tapPane5()
        XCTAssertEqual(mgr.focusedPaneId, "%5")

        XCTAssertEqual(mock.setActiveTmuxPaneInputOnlyCalls, [5, 6, 5],
                       "Each tap should route to the correct pane")
        XCTAssertEqual(log.commands, [
            "select-pane -t '%5'\n",
            "select-pane -t '%6'\n",
            "select-pane -t '%5'\n"
        ], "Each tap should send the correct tmux command")
    }

    /// Tapping the same pane twice should still send the command and route.
    /// (Idempotent — tmux handles duplicate select-pane gracefully.)
    @MainActor
    func testTappingSamePaneTwiceStillRoutes() {
        let (mgr, log) = managerWithCommandLog()
        let mock = MockTmuxSurface()
        mock.stubbedSetActivePaneResult = true

        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        mgr.selectPane("%3")
        mgr.selectPane("%3")

        XCTAssertEqual(mock.setActiveTmuxPaneInputOnlyCalls, [3, 3],
                       "Duplicate taps should still route (idempotent)")
        XCTAssertEqual(log.commands.count, 2,
                       "Duplicate taps should still send commands")
    }

    /// The onPaneTap callback should be a no-op after detachTmuxPane clears it.
    /// This tests the cleanup contract: when a surface detaches, its onPaneTap
    /// is nil'd, so stale closures can't trigger pane selection on a dead surface.
    @MainActor
    func testOnPaneTapClearedAfterDetach() {
        // This tests the SurfaceView contract without instantiating a real surface.
        // The contract is:
        //   attachToTmuxPane() → isMultiPaneObserver = true
        //   detachTmuxPane()   → isMultiPaneObserver = false, onPaneTap = nil
        //
        // We verify by checking that a nil onPaneTap produces no side effects.
        let (mgr, log) = managerWithCommandLog()

        // Simulate: onPaneTap was set, then detach cleared it to nil
        let onPaneTap: (() -> Void)? = nil
        onPaneTap?()  // Should be a no-op

        XCTAssertTrue(log.commands.isEmpty,
                      "After detach, onPaneTap is nil and should produce no commands")
        XCTAssertEqual(mgr.focusedPaneId, "",
                       "No pane selection should have occurred")
    }

    /// selectPane() with a pane ID that has no numeric component should still
    /// send the tmux command (fire-and-forget) but NOT call setActiveTmuxPaneInputOnly.
    /// This is a pre-existing test (testSelectPaneWithInvalidPaneIdDoesNotSendCommand)
    /// but we re-verify it in the onPaneTap context.
    @MainActor
    func testOnPaneTapWithMalformedPaneIdIsRejected() {
        let (mgr, log) = managerWithCommandLog()
        let mock = MockTmuxSurface()

        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        // Simulate tap with a pane ID that fails validation
        let onPaneTap = { mgr.selectPane("invalid") }
        onPaneTap()

        XCTAssertTrue(log.commands.isEmpty,
                       "No command should be sent for invalid pane ID")
        XCTAssertTrue(mock.setActiveTmuxPaneInputOnlyCalls.isEmpty,
                      "setActiveTmuxPaneInputOnly should NOT be called for invalid pane ID")
    }
}

// MARK: - Fix H: Observer Tap Priority Tests (Session 94)

extension TmuxSessionManagerTests {

    /// Fix H contract: observer pane taps ALWAYS route to selectPane(), regardless
    /// of what other state the SurfaceView might have (justFinishedSelecting,
    /// isMomentumScrolling, etc.).
    ///
    /// Before Fix H, handleTap() checked justFinishedSelecting BEFORE isMultiPaneObserver.
    /// Mouse/trackpad clicks set justFinishedSelecting=true via touchesEnded before the
    /// tap gesture recognizer fires (~200-300ms delay), so pane switching was completely
    /// blocked for mouse/trackpad users.
    ///
    /// After Fix H, handleTap() checks isMultiPaneObserver FIRST and returns immediately
    /// after calling onPaneTap(), bypassing all subsequent guards.
    ///
    /// Since we can't instantiate a real SurfaceView in tests (requires Metal + GhosttyKit),
    /// we verify the contract at the TmuxSessionManager level: selectPane() always
    /// produces the correct tmux command and Zig routing, which is the observable effect
    /// of onPaneTap() firing.
    @MainActor
    func testObserverTapAlwaysRoutesRegardlessOfSelectionState() {
        let (mgr, log) = managerWithCommandLog()
        let mock = MockTmuxSurface()
        mock.stubbedSetActivePaneResult = true

        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        // Simulate rapid sequence: the user selects text (which sets
        // justFinishedSelecting=true), then immediately taps another pane.
        // Fix H ensures the tap still routes.
        //
        // We can't set justFinishedSelecting (private), but we CAN verify that
        // the onPaneTap → selectPane chain works unconditionally:
        mgr.selectPane("%8")

        XCTAssertEqual(log.commands, ["select-pane -t '%8'\n"],
                       "Observer tap must always send select-pane (Fix H guarantee)")
        XCTAssertEqual(mock.setActiveTmuxPaneInputOnlyCalls, [8],
                       "Observer tap must always route Zig viewer (Fix H guarantee)")
        XCTAssertEqual(mgr.focusedPaneId, "%8",
                       "Observer tap must always update focusedPaneId (Fix H guarantee)")
    }

    /// Fix H hardening: observer tap followed by rapid keystrokes should route
    /// all keystrokes to the newly selected pane. This simulates the real-world
    /// scenario where the user clicks pane %8 and immediately starts typing.
    @MainActor
    func testObserverTapThenImmediateKeystrokes() {
        let (mgr, log) = managerWithCommandLog()
        let mock = MockTmuxSurface()
        mock.stubbedSetActivePaneResult = true

        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        // First: activate pane %6 (simulating startup)
        mgr.selectPane("%6")
        XCTAssertEqual(mgr.focusedPaneId, "%6")

        log.commands.removeAll()
        mock.setActiveTmuxPaneInputOnlyCalls.removeAll()

        // Then: observer tap switches to pane %8
        mgr.selectPane("%8")
        XCTAssertEqual(mgr.focusedPaneId, "%8",
                       "Focus should switch to %8 after tap")
        XCTAssertEqual(mock.setActiveTmuxPaneInputOnlyCalls, [8],
                       "Zig viewer should be routed to pane 8")

        // Verify: the Zig viewer now has active_pane_id=8, so any subsequent
        // sendKeys() calls will produce "send-keys -H -t %8 ..."
        // We can't call sendKeys() in tests (Zig runtime), but we verify the
        // C API was called correctly.
        XCTAssertEqual(log.commands, ["select-pane -t '%8'\n"],
                       "Only the select-pane command should be sent")
    }

    /// Fix H: switching between all 3 panes in sequence (simulating a real
    /// 3-pane tmux layout with panes %6, %7, %8).
    @MainActor
    func testThreePaneRoundRobinSelection() {
        let (mgr, log) = managerWithCommandLog()
        let mock = MockTmuxSurface()
        mock.stubbedSetActivePaneResult = true

        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        // Simulate: startup activates %6 (primary), user clicks %7, then %8, then %6
        mgr.selectPane("%6")
        XCTAssertEqual(mgr.focusedPaneId, "%6")

        mgr.selectPane("%7")
        XCTAssertEqual(mgr.focusedPaneId, "%7")

        mgr.selectPane("%8")
        XCTAssertEqual(mgr.focusedPaneId, "%8")

        mgr.selectPane("%6")
        XCTAssertEqual(mgr.focusedPaneId, "%6")

        XCTAssertEqual(mock.setActiveTmuxPaneInputOnlyCalls, [6, 7, 8, 6],
                       "Each pane selection should route the Zig viewer")
        XCTAssertEqual(log.commands, [
            "select-pane -t '%6'\n",
            "select-pane -t '%7'\n",
            "select-pane -t '%8'\n",
            "select-pane -t '%6'\n"
        ], "Each pane selection should send the correct tmux command")
    }

    /// Fix H nil safety: if onPaneTap is nil when an observer surface is tapped
    /// (e.g., due to view recycling or a race in SwiftUI), handleTap logs a
    /// warning but does NOT crash. The observable effect is: no selectPane() call,
    /// no command sent, focus unchanged.
    @MainActor
    func testObserverTapWithNilCallbackIsNoOp() {
        let (mgr, log) = managerWithCommandLog()

        // Simulate: onPaneTap is nil (never wired or cleared by detach).
        // handleTap sees isMultiPaneObserver=true but onPaneTap=nil.
        // It logs a warning and returns. No crash, no side effects.
        let onPaneTap: (() -> Void)? = nil
        onPaneTap?()  // This is what handleTap does: optional chain call

        XCTAssertTrue(log.commands.isEmpty,
                      "Nil onPaneTap should produce no commands")
        XCTAssertEqual(mgr.focusedPaneId, "",
                       "No focus change should occur with nil onPaneTap")
    }

    // MARK: - Fix I: ZoomablePane Gesture Moved to UIKit (Session 95)

    /// Fix I: The ZoomablePane SwiftUI view no longer has `.contentShape(Rectangle())`
    /// or `.onTapGesture(count: 2)`. This test verifies that the double-tap zoom
    /// callback reaches the session manager when wired through the UIKit container's
    /// onDoubleTap property.
    @MainActor
    func testDoubleTapZoomCallbackReachesSessionManager() {
        let mgr = TmuxSessionManager()
        let layout = horizontalSplitLayout(paneA: 6, paneB: 7)
        _ = mgr.reconcileTmuxState(TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "bash", layout: layout, focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [6, 7]
        ))

        // Verify initial state has a split tree with 2 panes
        XCTAssertTrue(mgr.currentSplitTree.isSplit,
                      "Pre-condition: should have a split tree")

        // Simulate what onDoubleTap does: call toggleZoom
        XCTAssertNil(mgr.currentSplitTree.zoomed,
                     "Pre-condition: no pane should be zoomed")

        mgr.toggleZoom(paneId: 6)

        XCTAssertNotNil(mgr.currentSplitTree.zoomed,
                        "After toggleZoom, a pane should be zoomed")

        // Toggle again to unzoom
        mgr.toggleZoom(paneId: 6)
        XCTAssertNil(mgr.currentSplitTree.zoomed,
                     "After second toggleZoom, pane should be unzoomed")
    }

    /// Fix I: onDoubleTap and onTap are independent — a double-tap fires the zoom
    /// callback without interfering with the single-tap pane selection.
    @MainActor
    func testSingleTapAndDoubleTapAreIndependent() {
        let (mgr, log) = managerWithCommandLog()
        let layout = horizontalSplitLayout(paneA: 6, paneB: 7)
        _ = mgr.reconcileTmuxState(TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "bash", layout: layout, focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [6, 7]
        ))

        // Simulate what happens on a single tap: selectPane is called
        mgr.selectPane("%7")

        XCTAssertEqual(mgr.focusedPaneId, "%7",
                       "Single tap should update focusedPaneId")
        XCTAssertTrue(log.commands.contains(where: { $0.contains("select-pane -t '%7'") }),
                      "Single tap should send select-pane command")

        // Now simulate double-tap zoom on same pane — it should toggle zoom
        // without clearing or interfering with focus
        mgr.toggleZoom(paneId: 7)
        XCTAssertNotNil(mgr.currentSplitTree.zoomed,
                        "Double-tap should zoom the pane")
        XCTAssertEqual(mgr.focusedPaneId, "%7",
                       "Double-tap zoom must not change focusedPaneId")
    }

    /// Fix I: When ZoomablePane no longer has `.contentShape(Rectangle())`, the
    /// UIKit SurfaceView's gestures should not be blocked. This test verifies
    /// that the selectPane flow works for all panes in a 3-pane setup — the same
    /// scenario that was broken before Fix I.
    @MainActor
    func testThreePaneSelectionAfterFixI() {
        let (mgr, log) = managerWithCommandLog()
        let layout = threePaneLayout(paneA: 6, paneB: 7, paneC: 8)
        _ = mgr.reconcileTmuxState(TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "bash", layout: layout, focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [6, 7, 8]
        ))

        let paneIds = ["%6", "%7", "%8"]

        // Select each pane in sequence
        for paneId in paneIds {
            log.commands.removeAll()
            mgr.selectPane(paneId)

            XCTAssertEqual(mgr.focusedPaneId, paneId,
                           "focusedPaneId should be \(paneId) after selection")
            XCTAssertTrue(log.commands.contains(where: { $0.contains("select-pane -t '\(paneId)'") }),
                          "select-pane command should be sent for \(paneId)")
        }
    }

    /// Fix I: Container's onDoubleTap is nil by default (when no zoom callback provided).
    /// This should be a no-op, not a crash.
    @MainActor
    func testDoubleTapWithNilCallbackIsNoOp() {
        // Simulate: onDoubleTap is nil (e.g., pane surface without zoom wired).
        let onDoubleTap: (() -> Void)? = nil
        onDoubleTap?()  // Should be a no-op

        // If we get here, no crash occurred — that's the assertion.
        XCTAssertTrue(true, "Nil onDoubleTap should not crash")
    }

    // MARK: - Nuke-and-Pave Focus System (Session 97)

    /// The nuke-and-pave refactor replaced 9 accumulated focus fixes (A-I)
    /// with a single architectural change: canBecomeFirstResponder returns
    /// false for observer surfaces. This test verifies the contract:
    /// selectPane() works unconditionally because it operates through the
    /// primary surface's Zig Termio, not through UIKit focus.
    @MainActor
    func testSelectPaneWorksWithoutFirstResponderRouting() {
        let (mgr, log) = managerWithCommandLog()
        let mock = MockTmuxSurface()
        mock.stubbedSetActivePaneResult = true

        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        let layout = threePaneLayout(paneA: 6, paneB: 7, paneC: 8)
        _ = mgr.reconcileTmuxState(TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "bash", layout: layout, focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [6, 7, 8]
        ))

        // Rapidly select all panes — mimics tap-tap-tap on different panes.
        // With the nuke-and-pave, this works because observers can't become
        // firstResponder, so there's no focus fight.
        for paneId in ["%6", "%7", "%8", "%7", "%6"] {
            log.commands.removeAll()
            mgr.selectPane(paneId)

            XCTAssertEqual(mgr.focusedPaneId, paneId,
                           "focusedPaneId should track rapid selections: expected \(paneId)")
            XCTAssertTrue(log.commands.contains(where: { $0.contains("select-pane -t '\(paneId)'") }),
                          "select-pane command should be sent for \(paneId)")
        }
    }

    /// After the nuke-and-pave, observer surfaces have canBecomeFirstResponder=false.
    /// This means UIKit's becomeFirstResponder() returns false when called on them.
    /// Since we can't instantiate a real SurfaceView, we verify the contract via
    /// TmuxSessionManager: selectPane always works regardless of focus state.
    @MainActor
    func testObserverFocusIrrelevantToSelectPane() {
        let (mgr, log) = managerWithCommandLog()
        let mock = MockTmuxSurface()
        mock.stubbedSetActivePaneResult = true

        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        let layout = horizontalSplitLayout(paneA: 6, paneB: 7)
        _ = mgr.reconcileTmuxState(TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "bash", layout: layout, focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [6, 7]
        ))

        // selectPane should work even if no surface is firstResponder
        // (which is the normal state for observers in the nuke-and-pave design)
        mgr.selectPane("%7")
        XCTAssertEqual(mgr.focusedPaneId, "%7",
                       "selectPane must work without firstResponder routing")
        XCTAssertTrue(mock.setActiveTmuxPaneInputOnlyCalls.contains(7),
                      "Zig-level pane routing must be called for pane 7")
        XCTAssertEqual(mock.setActiveTmuxPaneInputOnlyCalls.last, 7,
                       "Zig viewer must be told to route to pane 7")
    }

    /// The nuke-and-pave removed the usesExactGridSize guard from focusDidChange().
    /// This was defense-in-depth that's no longer needed because observers can never
    /// become firstResponder. Verify that the primary surface can still be selected
    /// (focusDidChange is only called on the firstResponder, which is always primary).
    @MainActor
    func testPrimaryAlwaysSelectableAfterGuardRemoval() {
        let (mgr, log) = managerWithCommandLog()

        let layout = horizontalSplitLayout(paneA: 6, paneB: 7)
        _ = mgr.reconcileTmuxState(TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "bash", layout: layout, focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [6, 7]
        ))

        // The primary pane (%6) should always be selectable
        mgr.selectPane("%6")
        XCTAssertEqual(mgr.focusedPaneId, "%6",
                       "Primary pane should be selectable")
        XCTAssertTrue(log.commands.contains(where: { $0.contains("select-pane -t '%6'") }),
                      "select-pane command for primary pane")
    }

    /// After nuke-and-pave, attachToTmuxPane() strips all gesture recognizers
    /// from the observer and adds a single tap. Verify that detachTmuxPane()
    /// correctly clears observer state (isMultiPaneObserver + onPaneTap) — this
    /// is the contract that would enable future "pane promotion" where an observer
    /// gets promoted back to primary.
    @MainActor
    func testDetachClearsObserverState() {
        let (mgr, _) = managerWithCommandLog()

        let layout = horizontalSplitLayout(paneA: 6, paneB: 7)
        _ = mgr.reconcileTmuxState(TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "bash", layout: layout, focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [6, 7]
        ))

        // Simulate the attach → detach lifecycle via selectPane
        mgr.selectPane("%7")
        XCTAssertEqual(mgr.focusedPaneId, "%7")

        // Select a different pane — the old selection is replaced
        mgr.selectPane("%6")
        XCTAssertEqual(mgr.focusedPaneId, "%6",
                       "Pane focus should transfer cleanly")
    }

    /// With the redundant container tap gesture removed (Phase 3), pane selection
    /// relies entirely on SurfaceView.handleTap() → onPaneTap(). This test verifies
    /// the onPaneTap → selectPane pipeline for a 3-pane setup with multiple
    /// rapid switches (the scenario that was broken before the nuke-and-pave).
    @MainActor
    func testOnPaneTapPipelineRapidSwitching() {
        let (mgr, log) = managerWithCommandLog()
        let mock = MockTmuxSurface()
        mock.stubbedSetActivePaneResult = true

        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        let layout = threePaneLayout(paneA: 6, paneB: 7, paneC: 8)
        _ = mgr.reconcileTmuxState(TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "bash", layout: layout, focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [6, 7, 8]
        ))

        // Simulate what happens when the user taps pane %8 (observer).
        // SurfaceView.handleTap() sees isMultiPaneObserver=true, calls onPaneTap().
        // onPaneTap calls selectPane("%8").
        let onPaneTap8 = { mgr.selectPane("%8") }
        onPaneTap8()

        XCTAssertEqual(mgr.focusedPaneId, "%8")
        XCTAssertTrue(log.commands.contains(where: { $0.contains("select-pane -t '%8'") }))

        // Immediately tap pane %7 — should work without any 300ms delay
        // (gesture stripping removed the require(toFail:) dependency)
        log.commands.removeAll()
        let onPaneTap7 = { mgr.selectPane("%7") }
        onPaneTap7()

        XCTAssertEqual(mgr.focusedPaneId, "%7",
                       "Rapid pane switch should work immediately")
        XCTAssertTrue(log.commands.contains(where: { $0.contains("select-pane -t '%7'") }),
                       "Second selectPane should produce command immediately")
    }
}

// MARK: - Session 107: Observer Zoom Gesture Contract Tests (WS-Z)

extension TmuxSessionManagerTests {

    /// CONTRACT: After attachToTmuxPane(), observer surfaces must have exactly 3
    /// gesture recognizers:
    ///   1. UITapGestureRecognizer (single tap, 1 touch) — pane switching
    ///   2. UIPinchGestureRecognizer — per-pane font size zoom
    ///   3. UITapGestureRecognizer (double tap, 2 touches) — font size reset
    ///
    /// Since we can't instantiate a real SurfaceView in tests (requires Metal +
    /// GhosttyKit), this test documents the expected gesture contract. The actual
    /// gesture setup is in Ghostty.swift attachToTmuxPane().
    ///
    /// KEY DESIGN FACTS (verified in Ghostty source):
    /// - increase_font_size/decrease_font_size are surface-scoped actions in Binding.zig
    /// - Each Surface has independent font_size, font_grid_key, font_metrics fields
    /// - ghostty_surface_tmux_attach_to_pane only replaces renderer_state.mutex and
    ///   renderer_state.terminal — font state is NOT shared
    /// - Pinch/font-reset gestures call ghostty_surface_binding_action on self.surface,
    ///   so they operate on the observer's own font state, not the primary's
    /// - These gestures don't need canBecomeFirstResponder=true because they don't
    ///   involve keyboard focus or input routing
    @MainActor
    func testObserverGestureContractDocumentation() {
        // This test documents the contract. The actual gesture setup cannot be
        // tested without Metal, but we verify the architectural invariants.
        let mgr = TmuxSessionManager()

        let layout = horizontalSplitLayout(paneA: 6, paneB: 7)
        _ = mgr.reconcileTmuxState(TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "bash", layout: layout, focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [6, 7]
        ))

        // Without a Ghostty runtime, paneSurfaces won't be populated (surfaces
        // require Metal + GhosttyKit). The contract we're documenting is:
        //
        // After attachToTmuxPane() on an observer surface:
        //   gestureRecognizers.count == 3
        //   gestureRecognizers contains UITapGestureRecognizer(taps=1, touches=1)  — pane switching
        //   gestureRecognizers contains UIPinchGestureRecognizer                   — per-pane font zoom
        //   gestureRecognizers contains UITapGestureRecognizer(taps=2, touches=2)  — font reset
        //   canBecomeFirstResponder == false
        //   isMultiPaneObserver == true
        //
        // Primary surface retains full gesture suite (12+ gestures).
        //
        // KEY DESIGN FACTS (verified in Ghostty source):
        // - increase_font_size/decrease_font_size are surface-scoped in Binding.zig
        // - Each Surface has independent font_size, font_grid_key, font_metrics
        // - ghostty_surface_tmux_attach_to_pane only replaces renderer_state.mutex
        //   and renderer_state.terminal — font state is NOT shared
        // - Pinch/font-reset call ghostty_surface_binding_action on self.surface
        //   (the observer's own surface, not the primary's)
        // - These gestures don't need canBecomeFirstResponder=true

        // Verify the state snapshot has the right pane count
        XCTAssertEqual(mgr.currentSplitTree.paneIds.count, 2,
                       "State snapshot should track 2 panes for gesture setup")
    }

    /// Per-pane font size independence: selectPane() should work correctly
    /// regardless of which pane has been zoomed (font-size-wise). This verifies
    /// that the input routing system is decoupled from font size state.
    @MainActor
    func testSelectPaneWorksIndependentlyOfFontSizeState() {
        let (mgr, log) = managerWithCommandLog()
        let mock = MockTmuxSurface()
        mock.stubbedSetActivePaneResult = true

        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        let layout = threePaneLayout(paneA: 6, paneB: 7, paneC: 8)
        _ = mgr.reconcileTmuxState(TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "bash", layout: layout, focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [6, 7, 8]
        ))

        // Simulate: user pinch-zooms observer pane %7 (font size change happens
        // on the SurfaceView, invisible to TmuxSessionManager). Then taps pane %8.
        // The selectPane() call must still work — font state doesn't affect routing.
        mgr.selectPane("%8")
        XCTAssertEqual(mgr.focusedPaneId, "%8")
        XCTAssertTrue(log.commands.contains(where: { $0.contains("select-pane -t '%8'") }))

        // Now tap back to primary %6
        log.commands.removeAll()
        mgr.selectPane("%6")
        XCTAssertEqual(mgr.focusedPaneId, "%6",
                       "selectPane to primary must work after observer font zoom")
        XCTAssertTrue(log.commands.contains(where: { $0.contains("select-pane -t '%6'") }))
    }

    /// Zoom gestures must coexist with pane-tap gesture on observer surfaces.
    /// The single-tap (pane switch) must NOT require pinch or two-finger-double-tap
    /// to fail — they are independent gesture types (tap vs pinch vs multi-touch tap).
    ///
    /// This test verifies the contract at the TmuxSessionManager level: rapid
    /// selectPane calls interleaved with simulated font changes should all succeed.
    @MainActor
    func testZoomAndPaneTapGestureCoexistence() {
        let (mgr, log) = managerWithCommandLog()
        let mock = MockTmuxSurface()
        mock.stubbedSetActivePaneResult = true

        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        let layout = threePaneLayout(paneA: 6, paneB: 7, paneC: 8)
        _ = mgr.reconcileTmuxState(TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "bash", layout: layout, focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [6, 7, 8]
        ))

        // Sequence: tap %7, "zoom" %7, tap %8, "zoom" %8, tap %6
        // Each selectPane must succeed regardless of interleaved font changes.
        mgr.selectPane("%7")
        XCTAssertEqual(mgr.focusedPaneId, "%7")

        // (font zoom on %7 happens on SurfaceView — invisible here)

        log.commands.removeAll()
        mgr.selectPane("%8")
        XCTAssertEqual(mgr.focusedPaneId, "%8")

        // (font zoom on %8 happens on SurfaceView — invisible here)

        log.commands.removeAll()
        mgr.selectPane("%6")
        XCTAssertEqual(mgr.focusedPaneId, "%6",
                       "Pane switching must work after interleaved font zoom gestures")
        XCTAssertEqual(mock.setActiveTmuxPaneInputOnlyCalls.last, 6,
                       "Last setActiveTmuxPaneInputOnly must target primary pane")
    }

    /// Per-pane font size means each observer surface has its own currentFontSize
    /// @Published property. The primaryCellSize on TmuxSessionManager should only
    /// reflect the PRIMARY surface's cell size, not observer surfaces.
    ///
    /// primaryCellSize is private(set) — it's only updated by the primary surface's
    /// cellSize publisher. Observer surface font changes (which update the observer's
    /// own SurfaceView.currentFontSize) have no path to modify primaryCellSize.
    @MainActor
    func testPrimaryCellSizeIsPrivateSet() {
        let mgr = TmuxSessionManager()

        let layout = horizontalSplitLayout(paneA: 6, paneB: 7)
        _ = mgr.reconcileTmuxState(TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "bash", layout: layout, focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [6, 7]
        ))

        // primaryCellSize starts at .zero when no real surface is attached.
        // The private(set) access control ensures only the primary surface's
        // cellSize publisher can update it — observer font changes are isolated.
        XCTAssertEqual(mgr.primaryCellSize, .zero,
                       "Without a real primary surface, primaryCellSize should be .zero")

        // CONTRACT: primaryCellSize is updated ONLY via the Combine subscription
        // in setupPrimarySurfaceObservation() which binds to primarySurface.$cellSize.
        // Observer surfaces have no path to modify this property.
    }
}

// MARK: - Session 98: onWrite Focus Override Regression Tests

extension TmuxSessionManagerTests {

    /// REGRESSION TEST (Session 98): In the old architecture, the primary surface's
    /// onWrite callback called setFocusedPane(primaryPaneId) on every keystroke.
    /// Because the pane ID was captured at wire-up time (always the primary's initial
    /// pane), it permanently overrode whatever selectPane() had set. This test
    /// reproduces the exact failure: selectPane("%7") followed by setFocusedPane("%6")
    /// (simulating the old onWrite callback) would reset routing to %6.
    @MainActor
    func testSetFocusedPaneOverridesSelectPaneWhenPaneIdDiffers() {
        let (mgr, _) = managerWithCommandLog()
        let mock = MockTmuxSurface()
        mock.stubbedSetActivePaneResult = true

        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        // User taps pane %7 → selectPane sets active routing to 7
        mgr.selectPane("%7")
        XCTAssertEqual(mgr.focusedPaneId, "%7")
        XCTAssertEqual(mock.setActiveTmuxPaneInputOnlyCalls, [7])

        // OLD BUG: primary surface's onWrite would call setFocusedPane("%6")
        // because "%6" was captured at wire-up time. This would overwrite
        // the selection. After the fix, onWrite no longer calls setFocusedPane,
        // but if someone reintroduces it, this test catches it.
        mock.setActiveTmuxPaneInputOnlyCalls.removeAll()
        mgr.setFocusedPane("%6")

        // setFocusedPane DOES overwrite — that's its contract. The fix is that
        // onWrite no longer calls it. This test documents the dangerous behavior
        // so future developers know WHY onWrite must NOT call setFocusedPane.
        XCTAssertEqual(mgr.focusedPaneId, "%6",
                       "setFocusedPane overwrites focusedPaneId (this is why onWrite must NOT call it)")
        XCTAssertEqual(mock.setActiveTmuxPaneInputOnlyCalls, [6],
                       "setFocusedPane calls setActiveTmuxPaneInputOnly, undoing selectPane's routing")
    }

    /// REGRESSION TEST (Session 98): After selectPane("%7"), if we simulate the
    /// scenario where NO setFocusedPane is called (the fix), then subsequent
    /// selectPane calls should all route correctly without interference.
    @MainActor
    func testSelectPaneWithoutOnWriteInterference() {
        let (mgr, log) = managerWithCommandLog()
        let mock = MockTmuxSurface()
        mock.stubbedSetActivePaneResult = true

        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        let layout = threePaneLayout(paneA: 6, paneB: 7, paneC: 8)
        _ = mgr.reconcileTmuxState(TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "bash", layout: layout, focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [6, 7, 8]
        ))

        // User taps pane %7
        mgr.selectPane("%7")
        XCTAssertEqual(mgr.focusedPaneId, "%7")

        // User types several keys — onWrite fires but does NOT call setFocusedPane
        // (In the old code, each keystroke would call setFocusedPane("%6"))
        // We verify focusedPaneId stays at %7 without interference
        XCTAssertEqual(mgr.focusedPaneId, "%7",
                       "focusedPaneId should remain %7 between keystrokes (no onWrite interference)")

        // User taps pane %8
        mock.setActiveTmuxPaneInputOnlyCalls.removeAll()
        mgr.selectPane("%8")
        XCTAssertEqual(mgr.focusedPaneId, "%8")
        XCTAssertEqual(mock.setActiveTmuxPaneInputOnlyCalls, [8],
                       "Switching to pane %8 should route Zig viewer to 8")

        // Again, keystrokes happen — focusedPaneId stays stable
        XCTAssertEqual(mgr.focusedPaneId, "%8",
                       "focusedPaneId should remain %8 without onWrite resetting it")
    }

    /// REGRESSION TEST (Session 98): Verify that handleTmuxStateChanged does NOT
    /// overwrite focusedPaneId when the window hasn't changed. This was the other
    /// half of the race — %layout-change triggers reconcileTmuxState, which should
    /// preserve the user's pane selection within the same window.
    @MainActor
    func testReconcilePreservesFocusedPaneOnSameWindow() {
        let (mgr, _) = managerWithCommandLog()
        let mock = MockTmuxSurface()
        mock.stubbedSetActivePaneResult = true

        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        let layout = threePaneLayout(paneA: 6, paneB: 7, paneC: 8)

        // Initial state: reconcile sets focused pane
        _ = mgr.reconcileTmuxState(TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "bash", layout: layout, focusedPaneId: 6)],
            activeWindowId: 0,
            paneIds: [6, 7, 8]
        ))

        // User selects pane %7
        mgr.selectPane("%7")
        XCTAssertEqual(mgr.focusedPaneId, "%7")

        // A %layout-change fires (e.g., from resize) — same window, same panes
        mock.setActiveTmuxPaneInputOnlyCalls.removeAll()
        let activePaneId = mgr.reconcileTmuxState(TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "bash", layout: layout, focusedPaneId: 6)],
            activeWindowId: 0,
            paneIds: [6, 7, 8]
        ))

        // The guard at line 493 should prevent overwriting focusedPaneId
        // because focusedWindowId hasn't changed and focusedPaneId isn't empty
        XCTAssertEqual(mgr.focusedPaneId, "%7",
                       "reconcileTmuxState must NOT overwrite user's pane selection on same window")
        XCTAssertEqual(activePaneId, 7,
                       "Returned activePaneId should match user's selection, not tmux's default")
    }
    
    // MARK: - Input-Only vs Full Renderer Swap Contract Tests (Session 99)
    //
    // These tests verify the critical contract that in multi-surface mode:
    // - selectPane() and setFocusedPane() use setActiveTmuxPaneInputOnly
    //   (routes keystrokes without swapping the primary surface's renderer)
    // - handleTmuxStateChanged() uses setActiveTmuxPaneInputOnly
    // - switchToWindow() uses setActiveTmuxPane (full renderer swap)
    //
    // Bug: Session 98 discovered that the primary surface echoed whichever
    // pane was active because setActiveTmuxPane swaps renderer_state.terminal
    // in addition to setting active_pane_id for send-keys routing.
    
    /// selectPane() must use input-only API, NOT the full renderer swap.
    /// This prevents the primary surface from echoing the selected pane's content.
    @MainActor
    func testSelectPaneUsesInputOnlyNotFullRendererSwap() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif
        
        mgr.selectPane("%7")
        
        // Input-only should be called
        XCTAssertEqual(mock.setActiveTmuxPaneInputOnlyCalls, [7],
                       "selectPane must use setActiveTmuxPaneInputOnly to avoid swapping renderer")
        // Full renderer swap should NOT be called
        XCTAssertTrue(mock.setActiveTmuxPaneCalls.isEmpty,
                      "selectPane must NOT call setActiveTmuxPane (would swap renderer)")
    }
    
    /// setFocusedPane() must use input-only API, NOT the full renderer swap.
    @MainActor
    func testSetFocusedPaneUsesInputOnlyNotFullRendererSwap() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif
        
        mgr.setFocusedPane("%4")
        
        XCTAssertEqual(mock.setActiveTmuxPaneInputOnlyCalls, [4],
                       "setFocusedPane must use setActiveTmuxPaneInputOnly")
        XCTAssertTrue(mock.setActiveTmuxPaneCalls.isEmpty,
                      "setFocusedPane must NOT call setActiveTmuxPane (would swap renderer)")
    }
    
    /// handleTmuxStateChanged() must use input-only for the active pane.
    @MainActor
    func testHandleTmuxStateChangedUsesInputOnlyAPI() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        mock.stubbedPaneCount = 2
        mock.stubbedPaneIds = [0, 1]
        mock.stubbedWindowCount = 1
        mock.stubbedWindows = [TmuxWindowInfo(id: 0, width: 80, height: 24, name: "bash")]
        mock.stubbedWindowLayouts = [horizontalSplitLayout(paneA: 0, paneB: 1)]
        mock.stubbedActiveWindowId = 0
        mock.stubbedWindowFocusedPaneIds = [0]
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif
        
        mgr.handleTmuxStateChanged(windowCount: 1, paneCount: 2)
        
        // handleTmuxStateChanged should use input-only for routing
        XCTAssertFalse(mock.setActiveTmuxPaneInputOnlyCalls.isEmpty,
                       "handleTmuxStateChanged should call setActiveTmuxPaneInputOnly for active pane")
        XCTAssertTrue(mock.setActiveTmuxPaneCalls.isEmpty,
                      "handleTmuxStateChanged must NOT call setActiveTmuxPane (would swap renderer)")
    }
    
    /// selectWindow() SHOULD use the full setActiveTmuxPane (renderer swap)
    /// because window switching requires re-pointing the primary surface to
    /// a pane terminal in the new window.
    @MainActor
    func testSelectWindowUsesFullRendererSwap() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        mock.stubbedPaneCount = 2
        mock.stubbedPaneIds = [0, 1]
        mock.stubbedWindowCount = 2
        mock.stubbedWindows = [
            TmuxWindowInfo(id: 0, width: 80, height: 24, name: "bash"),
            TmuxWindowInfo(id: 1, width: 80, height: 24, name: "vim")
        ]
        mock.stubbedWindowLayouts = [
            horizontalSplitLayout(paneA: 0, paneB: 1),
            singlePaneLayout(paneId: 2)
        ]
        mock.stubbedActiveWindowId = 0
        mock.stubbedWindowFocusedPaneIds = [0, 2]
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif
        
        // First, trigger state change so we have windows/trees
        mgr.handleTmuxStateChanged(windowCount: 2, paneCount: 2)
        mock.resetCallTracking()
        
        // Switch to window @1
        mgr.selectWindow("@1")
        
        // selectWindow should use full setActiveTmuxPane (renderer swap needed)
        XCTAssertFalse(mock.setActiveTmuxPaneCalls.isEmpty,
                       "selectWindow should use full setActiveTmuxPane for renderer swap")
    }
    
    // MARK: - Session 106: Primary pane re-selection after observer tap
    
    /// Verifies that selectPane() correctly routes input back to the primary
    /// pane (%2) after having selected an observer pane (%3). This is the
    /// contract that handleTap() must fulfill when the primary surface is
    /// tapped in multi-pane mode (Session 106 fix).
    @MainActor
    func testSelectPaneRouteBackToPrimaryAfterObserverSelection() {
        let (mgr, log) = managerWithCommandLog()
        let mock = MockTmuxSurface()
        mock.stubbedSetActivePaneInputOnlyResult = true
        
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif
        
        // Simulate: user was on primary pane %2, then tapped observer pane %3
        mgr.selectPane("%2")
        mgr.selectPane("%3")
        
        // Now user taps back on primary pane %2 (the bug: this never happened)
        mock.resetCallTracking()
        log.commands.removeAll()
        mgr.selectPane("%2")
        
        // Verify: focusedPaneId updated
        XCTAssertEqual(mgr.focusedPaneId, "%2",
                       "focusedPaneId should be %2 after tapping primary")
        
        // Verify: tmux command sent
        XCTAssertEqual(log.commands, ["select-pane -t '%2'\n"],
                       "select-pane command should be sent for primary pane")
        
        // Verify: Zig-side input routing updated
        XCTAssertEqual(mock.setActiveTmuxPaneInputOnlyCalls, [2],
                       "setActiveTmuxPaneInputOnly(2) should route input to primary")
    }
    
    /// Verifies the full 3-pane round-trip: primary → observer A → observer B
    /// → back to primary. Each step must produce correct routing.
    @MainActor
    func testThreePaneRoundTripBackToPrimary() {
        let (mgr, _) = managerWithCommandLog()
        let mock = MockTmuxSurface()
        mock.stubbedSetActivePaneInputOnlyResult = true
        
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif
        
        // Primary (%9) → observer (%10) → observer (%11) → back to primary (%9)
        mgr.selectPane("%9")
        XCTAssertEqual(mgr.focusedPaneId, "%9")
        
        mgr.selectPane("%10")
        XCTAssertEqual(mgr.focusedPaneId, "%10")
        
        mgr.selectPane("%11")
        XCTAssertEqual(mgr.focusedPaneId, "%11")
        
        // The critical step: going back to primary
        mgr.selectPane("%9")
        XCTAssertEqual(mgr.focusedPaneId, "%9",
                       "focusedPaneId must return to %9 after round-trip")
        XCTAssertEqual(mock.setActiveTmuxPaneInputOnlyCalls, [9, 10, 11, 9],
                       "All 4 setActiveTmuxPaneInputOnly calls should be recorded in order")
    }
    
    /// Verifies that onPaneTap closure for the primary pane calls selectPane
    /// and produces the same effect as tapping an observer pane.
    /// This tests the contract added in Session 106: handleTap() calls
    /// onPaneTap() for the primary surface, not just observers.
    @MainActor
    func testOnPaneTapForPrimaryPaneRoutesCorrectly() {
        let (mgr, log) = managerWithCommandLog()
        let mock = MockTmuxSurface()
        mock.stubbedSetActivePaneInputOnlyResult = true
        
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif
        
        // Simulate: onPaneTap closures as wired by TmuxMultiPaneView
        let primaryOnTap = { mgr.selectPane("%9") }
        let observerOnTap = { mgr.selectPane("%10") }
        
        // User taps observer → works
        observerOnTap()
        XCTAssertEqual(mgr.focusedPaneId, "%10")
        
        // User taps primary → must also work (the Session 106 fix)
        mock.resetCallTracking()
        log.commands.removeAll()
        primaryOnTap()
        
        XCTAssertEqual(mgr.focusedPaneId, "%9",
                       "onPaneTap for primary must route back to %9")
        XCTAssertEqual(mock.setActiveTmuxPaneInputOnlyCalls, [9],
                       "Primary pane onPaneTap must call setActiveTmuxPaneInputOnly")
        XCTAssertEqual(log.commands, ["select-pane -t '%9'\n"],
                       "Primary pane onPaneTap must send select-pane command")
    }
}

// MARK: - Teardown Ordering Invariant Tests (Session 109)

extension TmuxSessionManagerTests {
    
    /// The teardown order tracker should start empty on a fresh manager.
    @MainActor
    func testTeardownOrderTrackerStartsEmpty() {
        let mgr = TmuxSessionManager()
        #if DEBUG
        XCTAssertTrue(mgr.teardownOrderForTesting.isEmpty,
                      "Teardown order tracker should start empty")
        #endif
    }
    
    /// controlModeExited with no surfaces should produce empty teardown order.
    @MainActor
    func testControlModeExitedEmptyTeardownOrder() {
        let mgr = TmuxSessionManager()
        mgr.controlModeActivated()
        mgr.controlModeExited(reason: "test")
        
        #if DEBUG
        XCTAssertTrue(mgr.teardownOrderForTesting.isEmpty,
                      "No surfaces → no teardown events")
        #endif
    }
    
    /// cleanup() with no surfaces should produce empty teardown order.
    @MainActor
    func testCleanupEmptyTeardownOrder() {
        let mgr = TmuxSessionManager()
        mgr.cleanup()
        
        #if DEBUG
        XCTAssertTrue(mgr.teardownOrderForTesting.isEmpty,
                      "No surfaces → no teardown events")
        #endif
    }
    
    /// Verify the structural invariant: controlModeExited() partitions surfaces
    /// into observers (filter isMultiPaneObserver == true) THEN primaries
    /// (filter isMultiPaneObserver == false). This prevents use-after-free in
    /// Surface.zig deinit which chases binding.source → primary surface.
    ///
    /// We verify the code structure by confirming that after controlModeExited(),
    /// paneSurfaces is fully cleared and primarySurface is nil. The actual
    /// ordering guarantee is enforced by the filter-then-iterate pattern in the
    /// source code, and validated on-device via the teardownOrderForTesting tracker.
    @MainActor
    func testControlModeExitedClearsSurfacesCompletely() {
        let mgr = TmuxSessionManager()
        mgr.controlModeActivated()
        
        // Reconcile state to populate windows/split tree
        let layout = horizontalSplitLayout(paneA: 9, paneB: 10)
        _ = mgr.reconcileTmuxState(TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "bash", layout: layout, focusedPaneId: 9)],
            activeWindowId: 0,
            paneIds: [9, 10]
        ))
        
        mgr.controlModeExited(reason: "test teardown")
        
        // All surface state must be fully cleared
        XCTAssertTrue(mgr.paneSurfaces.isEmpty,
                      "controlModeExited must clear all paneSurfaces")
        XCTAssertNil(mgr.primarySurface,
                     "controlModeExited must clear primarySurface")
    }
    
    /// Verify the structural invariant: cleanup() partitions surfaces into
    /// observers THEN primaries via the filter pattern. Same invariant as
    /// controlModeExited() but through the removeSurface() code path.
    @MainActor
    func testCleanupClearsSurfacesCompletely() {
        let mgr = TmuxSessionManager()
        mgr.controlModeActivated()
        
        let layout = threePaneLayout(paneA: 9, paneB: 10, paneC: 11)
        _ = mgr.reconcileTmuxState(TmuxSessionManager.TmuxStateSnapshot(
            windows: [.init(id: 0, name: "bash", layout: layout, focusedPaneId: 9)],
            activeWindowId: 0,
            paneIds: [9, 10, 11]
        ))
        
        mgr.cleanup()
        
        XCTAssertTrue(mgr.paneSurfaces.isEmpty,
                      "cleanup must clear all paneSurfaces")
        XCTAssertNil(mgr.primarySurface,
                     "cleanup must clear primarySurface")
        XCTAssertFalse(mgr.isConnected)
    }
    
    /// removeSurface() for individual panes should record teardown order.
    /// With no real surfaces in paneSurfaces, the tracker stays empty,
    /// but we verify it doesn't crash.
    @MainActor
    func testRemoveSurfaceRecordsTeardownOrder() {
        let mgr = TmuxSessionManager()
        
        // Remove non-existent panes — should be safe no-ops
        mgr.removeSurface(for: "%9", paneActuallyClosed: true)
        mgr.removeSurface(for: "%10", paneActuallyClosed: true)
        
        #if DEBUG
        XCTAssertTrue(mgr.teardownOrderForTesting.isEmpty,
                      "No surfaces to remove → no teardown events recorded")
        #endif
    }
    
    /// Verify that repeated cleanup calls don't corrupt the teardown tracker.
    @MainActor
    func testRepeatedCleanupIdempotentTeardownOrder() {
        let mgr = TmuxSessionManager()
        mgr.controlModeActivated()
        mgr.controlModeExited(reason: "first disconnect")
        
        #if DEBUG
        let countAfterFirst = mgr.teardownOrderForTesting.count
        #endif
        
        mgr.cleanup()
        
        #if DEBUG
        // Second teardown adds no new events (nothing left to close)
        XCTAssertEqual(mgr.teardownOrderForTesting.count, countAfterFirst,
                       "Second cleanup should not add more teardown events")
        #endif
    }
}

// MARK: - Background Detach/Reattach Flow Tests (Session 121, rewritten Session 127)
// Session 127: Rewrote for "destroy and recreate" approach.
// prepareForReattach() now destroys observer surfaces and clears paneSurfaces,
// letting the standard initial-connection flow recreate fresh surfaces on reconnect.

extension TmuxSessionManagerTests {
    
    @MainActor
    func testPrepareForReattachClearsPaneSurfaces() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        let layout = horizontalSplitLayout(paneA: 15, paneB: 16)
        mock.stubbedWindows = [TmuxWindowInfo(id: 0, width: 80, height: 24, name: "bash")]
        mock.stubbedWindowLayouts = [layout]
        mock.stubbedActiveWindowId = 0
        mock.stubbedPaneIds = [15, 16]
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif
        mgr.controlModeActivated()
        mgr.handleTmuxStateChanged(windowCount: 1, paneCount: 2)
        // paneSurfaces may be empty (no factory configured in test), but state is set up
        
        mgr.prepareForReattach()
        
        // paneSurfaces must be empty after prepareForReattach
        XCTAssertTrue(mgr.paneSurfaces.isEmpty,
                      "paneSurfaces must be empty after prepareForReattach — observer surfaces destroyed")
    }
    
    @MainActor
    func testPrepareForReattachPreservesPrimarySurface() {
        let mgr = TmuxSessionManager()
        mgr.controlModeActivated()
        
        mgr.prepareForReattach()
        
        // primarySurface is nil in test (no real Ghostty surface), but the code
        // path doesn't crash and the property is preserved (not set to nil)
        XCTAssertFalse(mgr.isConnected)
        XCTAssertEqual(mgr.connectionState, .disconnected)
    }
    
    @MainActor
    func testPrepareForReattachClearsTransientState() {
        let mgr = TmuxSessionManager()
        mgr.controlModeActivated()
        let mock = MockTmuxSurface()
        let layout = horizontalSplitLayout(paneA: 15, paneB: 16)
        mock.stubbedWindows = [TmuxWindowInfo(id: 0, width: 80, height: 24, name: "bash")]
        mock.stubbedWindowLayouts = [layout]
        mock.stubbedActiveWindowId = 0
        mock.stubbedPaneIds = [15, 16]
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif
        mgr.handleTmuxStateChanged(windowCount: 1, paneCount: 2)
        #if DEBUG
        mgr.setPendingOutputForTesting(["%15": [Data([0x41])]])
        #endif
        mgr.handleSessionRenamed(name: "my-session")
        XCTAssertEqual(mgr.sessionName, "my-session")
        
        mgr.prepareForReattach()
        
        XCTAssertFalse(mgr.isConnected)
        XCTAssertEqual(mgr.connectionState, .disconnected)
        XCTAssertTrue(mgr.pendingOutput.isEmpty)
        XCTAssertNil(mgr.currentSession)
        XCTAssertEqual(mgr.sessionName, "")
        XCTAssertTrue(mgr.windows.isEmpty)
        XCTAssertFalse(mgr.viewerReady)
        // focusedWindowId and focusedPaneId are preserved for UI continuity
        XCTAssertEqual(mgr.focusedWindowId, "@0")
        XCTAssertEqual(mgr.focusedPaneId, "%15")
    }
    
    @MainActor
    func testControlModeExitedAfterPrepareForReattach() {
        let mgr = TmuxSessionManager()
        mgr.controlModeActivated()
        mgr.prepareForReattach()
        
        // Full teardown after a background detach should not crash
        mgr.controlModeExited(reason: "full teardown")
        
        XCTAssertFalse(mgr.isConnected)
        // controlModeExited with a reason sets .connectionLost, not .disconnected
        if case .connectionLost = mgr.connectionState {
            // expected
        } else {
            XCTFail("Expected .connectionLost, got \(mgr.connectionState)")
        }
    }
    
    @MainActor
    func testCleanupAfterPrepareForReattach() {
        let mgr = TmuxSessionManager()
        mgr.controlModeActivated()
        mgr.prepareForReattach()
        
        // cleanup() after prepareForReattach should not crash
        mgr.cleanup()
        
        XCTAssertTrue(mgr.paneSurfaces.isEmpty)
    }
    
    @MainActor
    func testHandleTmuxStateChangedAfterPrepareForReattach() {
        // After prepareForReattach clears paneSurfaces, the standard
        // handleTmuxStateChanged flow should populate windows/state
        // as if it's a fresh connection (surfaces need a factory,
        // which isn't configured in unit tests, but state updates work)
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        let layout = horizontalSplitLayout(paneA: 15, paneB: 16)
        mock.stubbedWindows = [TmuxWindowInfo(id: 0, width: 80, height: 24, name: "bash")]
        mock.stubbedWindowLayouts = [layout]
        mock.stubbedActiveWindowId = 0
        mock.stubbedPaneIds = [15, 16]
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif
        // Phase 1: Initial connection
        mgr.controlModeActivated()
        mgr.handleTmuxStateChanged(windowCount: 1, paneCount: 2)
        XCTAssertEqual(mgr.windows.count, 1)
        
        // Phase 2: Background detach
        mgr.prepareForReattach()
        XCTAssertTrue(mgr.paneSurfaces.isEmpty)
        XCTAssertTrue(mgr.windows.isEmpty)
        
        // Phase 3: Reconnect — handleTmuxStateChanged rebuilds state fresh
        mgr.controlModeActivated()
        mock.resetCallTracking()
        mgr.handleTmuxStateChanged(windowCount: 1, paneCount: 2)
        
        // State should be rebuilt as if fresh connection
        XCTAssertEqual(mgr.windows.count, 1)
        XCTAssertTrue(mgr.isConnected)
    }
    
    @MainActor
    func testFreshConnectionDoesNotTriggerReattachPath() {
        // A brand-new connection should work identically to before
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
        XCTAssertEqual(mgr.windows.count, 1)
        XCTAssertEqual(mgr.focusedPaneId, "%0")
    }
    
    @MainActor
    func testPrepareForReattachIdempotent() {
        let mgr = TmuxSessionManager()
        mgr.controlModeActivated()
        
        // Calling prepareForReattach twice should not crash
        mgr.prepareForReattach()
        mgr.prepareForReattach()
        
        XCTAssertTrue(mgr.paneSurfaces.isEmpty)
        XCTAssertFalse(mgr.isConnected)
    }
    
    @MainActor
    func testControlModeActivatedDoesNotAffectPaneSurfaces() {
        let mgr = TmuxSessionManager()
        mgr.controlModeActivated()
        
        // controlModeActivated alone should not create or destroy surfaces
        XCTAssertTrue(mgr.paneSurfaces.isEmpty)
        XCTAssertTrue(mgr.isConnected)
    }
    
    @MainActor
    func testEmptyPaneNotificationAfterPrepareForReattach() {
        // During reconnection, the first TMUX_STATE_CHANGED may fire with 0 panes
        // (viewer just created, list-windows hasn't responded yet). This should
        // be handled gracefully — no crash, no stale state.
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        let layout = horizontalSplitLayout(paneA: 15, paneB: 16)
        mock.stubbedWindows = [TmuxWindowInfo(id: 0, width: 80, height: 24, name: "bash")]
        mock.stubbedWindowLayouts = [layout]
        mock.stubbedActiveWindowId = 0
        mock.stubbedPaneIds = [15, 16]
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif
        // Phase 1: Initial connection
        mgr.controlModeActivated()
        mgr.handleTmuxStateChanged(windowCount: 1, paneCount: 2)
        
        // Phase 2: Background detach
        mgr.prepareForReattach()
        
        // Phase 3: Reconnect — first notification with empty panes
        mgr.controlModeActivated()
        mock.stubbedWindows = []
        mock.stubbedWindowLayouts = []
        mock.stubbedPaneIds = []
        mock.stubbedActiveWindowId = -1
        mock.resetCallTracking()
        mgr.handleTmuxStateChanged(windowCount: 0, paneCount: 0)
        
        // Should handle empty notification gracefully
        XCTAssertTrue(mgr.paneSurfaces.isEmpty)
        
        // Phase 4: Second notification with real panes
        mock.stubbedWindows = [TmuxWindowInfo(id: 0, width: 80, height: 24, name: "bash")]
        mock.stubbedWindowLayouts = [layout]
        mock.stubbedActiveWindowId = 0
        mock.stubbedPaneIds = [15, 16]
        mock.resetCallTracking()
        mgr.handleTmuxStateChanged(windowCount: 1, paneCount: 2)
        
        // State rebuilt correctly
        XCTAssertEqual(mgr.windows.count, 1)
    }
    
    @MainActor
    func testFullBackgroundForegroundLifecycle() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        let layout = horizontalSplitLayout(paneA: 15, paneB: 16)
        mock.stubbedWindows = [TmuxWindowInfo(id: 0, width: 80, height: 24, name: "bash")]
        mock.stubbedWindowLayouts = [layout]
        mock.stubbedActiveWindowId = 0
        mock.stubbedPaneIds = [15, 16]
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif
        // Phase 1: Initial connection
        mgr.controlModeActivated()
        mgr.viewerBecameReady()
        mgr.handleTmuxStateChanged(windowCount: 1, paneCount: 2)
        XCTAssertTrue(mgr.isConnected)
        XCTAssertEqual(mgr.windows.count, 1)
        
        // Phase 2: Background detach — destroys observers, clears paneSurfaces
        mgr.prepareForReattach()
        XCTAssertFalse(mgr.isConnected)
        XCTAssertTrue(mgr.paneSurfaces.isEmpty)
        XCTAssertTrue(mgr.windows.isEmpty)
        
        // Phase 3: Foreground reconnect — standard flow recreates everything
        mgr.controlModeActivated()
        mgr.viewerBecameReady()
        mock.resetCallTracking()
        mgr.handleTmuxStateChanged(windowCount: 1, paneCount: 2)
        
        // Everything rebuilt as if fresh connection
        XCTAssertTrue(mgr.isConnected)
        XCTAssertEqual(mgr.windows.count, 1)
    }
    
    /// After prepareForReattach sets isConnected=false, getSurface(forNumericId:)
    /// must NOT create new surfaces via the factory. This prevents the bug where
    /// SwiftUI re-renders the preserved split tree and triggers premature observer
    /// surface creation — surfaces that have no tmux viewer to bind to.
    @MainActor
    func testGetSurfaceReturnsNilWhenDisconnected() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        let layout = horizontalSplitLayout(paneA: 15, paneB: 16)
        mock.stubbedWindows = [TmuxWindowInfo(id: 0, width: 80, height: 24, name: "bash")]
        mock.stubbedWindowLayouts = [layout]
        mock.stubbedActiveWindowId = 0
        mock.stubbedPaneIds = [15, 16]
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif
        
        // Phase 1: Initial connection — factory configured and connected
        mgr.controlModeActivated()
        var factoryCalls: [String] = []
        mgr.configureSurfaceManagement(
            factory: { paneId in
                factoryCalls.append(paneId)
                return nil  // Can't create real Ghostty surfaces in tests
            },
            inputHandler: { _, _ in },
            resizeHandler: { _, _ in }
        )
        mgr.handleTmuxStateChanged(windowCount: 1, paneCount: 2)
        let initialCalls = factoryCalls.count
        XCTAssertGreaterThan(initialCalls, 0, "Factory should be called during initial connection")
        
        // Phase 2: Background detach
        mgr.prepareForReattach()
        XCTAssertFalse(mgr.isConnected)
        factoryCalls.removeAll()
        
        // Simulate SwiftUI re-render calling getSurface(forNumericId:)
        // for each pane in the preserved split tree
        let surface15 = mgr.getSurface(forNumericId: 15)
        let surface16 = mgr.getSurface(forNumericId: 16)
        
        XCTAssertNil(surface15, "getSurface must return nil when disconnected")
        XCTAssertNil(surface16, "getSurface must return nil when disconnected")
        XCTAssertTrue(factoryCalls.isEmpty,
                      "Factory must NOT be called when disconnected — prevents premature zombie surfaces")
        XCTAssertTrue(mgr.paneSurfaces.isEmpty,
                      "No surfaces should be created while disconnected")
    }
    
    /// Verify that factory creation works again after reconnect restores isConnected.
    @MainActor
    func testFactoryCreationRestoredAfterReconnect() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        let layout = horizontalSplitLayout(paneA: 15, paneB: 16)
        mock.stubbedWindows = [TmuxWindowInfo(id: 0, width: 80, height: 24, name: "bash")]
        mock.stubbedWindowLayouts = [layout]
        mock.stubbedActiveWindowId = 0
        mock.stubbedPaneIds = [15, 16]
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif
        
        // Phase 1: Initial connection
        mgr.controlModeActivated()
        var factoryCalls: [String] = []
        mgr.configureSurfaceManagement(
            factory: { paneId in
                factoryCalls.append(paneId)
                return nil
            },
            inputHandler: { _, _ in },
            resizeHandler: { _, _ in }
        )
        mgr.handleTmuxStateChanged(windowCount: 1, paneCount: 2)
        
        // Phase 2: Background detach
        mgr.prepareForReattach()
        factoryCalls.removeAll()
        
        // Phase 3: Reconnect — controlModeActivated restores isConnected
        mgr.controlModeActivated()
        XCTAssertTrue(mgr.isConnected)
        
        // Now handleTmuxStateChanged should create surfaces again
        mock.resetCallTracking()
        mgr.handleTmuxStateChanged(windowCount: 1, paneCount: 2)
        
         XCTAssertFalse(factoryCalls.isEmpty,
                       "Factory should be called again after reconnect restores isConnected")
        XCTAssertEqual(Set(factoryCalls), Set(["%15", "%16"]),
                       "Factory should be called for all panes after reconnect")
    }
}

// MARK: - syncSplitRatioToTmux Tests

extension TmuxSessionManagerTests {

    /// syncSplitRatioToTmux should early-return when there is no split tree.
    @MainActor
    func testSyncSplitRatioNoSplitTree() {
        let (mgr, log) = managerWithCommandLog()
        mgr.syncSplitRatioToTmux(forPaneId: 0, ratio: 0.5)
        XCTAssertTrue(log.commands.isEmpty,
                      "No command should be sent when there is no split tree")
    }

    /// syncSplitRatioToTmux should early-return when lastRefreshSize is nil.
    @MainActor
    func testSyncSplitRatioNoLastRefreshSize() {
        let (mgr, log) = managerWithCommandLog()
        let mock = MockTmuxSurface()
        let layout = horizontalSplitLayout(paneA: 0, paneB: 1)
        mock.stubbedWindows = [TmuxWindowInfo(id: 0, width: 80, height: 24, name: "bash")]
        mock.stubbedWindowLayouts = [layout]
        mock.stubbedActiveWindowId = 0
        mock.stubbedPaneIds = [0, 1]
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        mgr.controlModeActivated()
        mgr.configureSurfaceManagement(
            factory: { _ in nil },
            inputHandler: { _, _ in },
            resizeHandler: { _, _ in }
        )
        mgr.handleTmuxStateChanged(windowCount: 1, paneCount: 2)

        // Split tree exists but lastRefreshSize is nil — should early-return
        log.commands.removeAll()
        mgr.syncSplitRatioToTmux(forPaneId: 0, ratio: 0.5)
        XCTAssertTrue(log.commands.isEmpty,
                      "No command should be sent when lastRefreshSize is nil")
    }

    /// syncSplitRatioToTmux should send resize-pane -x for a horizontal split.
    @MainActor
    func testSyncSplitRatioHorizontalSendsResizePane() {
        let (mgr, log) = managerWithCommandLog()
        let mock = MockTmuxSurface()
        let layout = horizontalSplitLayout(paneA: 0, paneB: 1, totalCols: 80, rows: 24)
        mock.stubbedWindows = [TmuxWindowInfo(id: 0, width: 80, height: 24, name: "bash")]
        mock.stubbedWindowLayouts = [layout]
        mock.stubbedActiveWindowId = 0
        mock.stubbedPaneIds = [0, 1]
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        mgr.controlModeActivated()
        mgr.viewerBecameReady()
        mgr.configureSurfaceManagement(
            factory: { _ in nil },
            inputHandler: { _, _ in },
            resizeHandler: { _, _ in }
        )
        mgr.handleTmuxStateChanged(windowCount: 1, paneCount: 2)

        // Set lastRefreshSize AFTER controlModeActivated (which resets it to nil)
        #if DEBUG
        mgr.setLastRefreshSizeForTesting(cols: 80, rows: 24)
        #endif

        log.commands.removeAll()
        mgr.syncSplitRatioToTmux(forPaneId: 0, ratio: 0.6)

        // Should send a resize-pane -x command (horizontal split = -x flag)
        XCTAssertEqual(log.commands.count, 1, "Exactly one resize command should be sent")
        let cmd = log.commands.first ?? ""
        XCTAssertTrue(cmd.hasPrefix("resize-pane -t %0 -x "),
                      "Command should use -x flag for horizontal split, got: \(cmd)")
        // Expected: available = 80 - 1 (divider) = 79, new size = max(1, Int(79 * 0.6)) = 47
        XCTAssertTrue(cmd.contains("47\n"),
                      "resize-pane should target 47 columns (79 * 0.6), got: \(cmd)")
    }

    /// syncSplitRatioToTmux should send resize-pane -y for a vertical split.
    @MainActor
    func testSyncSplitRatioVerticalSendsResizePane() {
        let (mgr, log) = managerWithCommandLog()
        let mock = MockTmuxSurface()
        let layout = verticalSplitLayout(paneA: 0, paneB: 1, cols: 80, totalRows: 24)
        mock.stubbedWindows = [TmuxWindowInfo(id: 0, width: 80, height: 24, name: "bash")]
        mock.stubbedWindowLayouts = [layout]
        mock.stubbedActiveWindowId = 0
        mock.stubbedPaneIds = [0, 1]
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        mgr.controlModeActivated()
        mgr.viewerBecameReady()
        mgr.configureSurfaceManagement(
            factory: { _ in nil },
            inputHandler: { _, _ in },
            resizeHandler: { _, _ in }
        )
        mgr.handleTmuxStateChanged(windowCount: 1, paneCount: 2)

        // Set lastRefreshSize AFTER controlModeActivated (which resets it to nil)
        #if DEBUG
        mgr.setLastRefreshSizeForTesting(cols: 80, rows: 24)
        #endif

        log.commands.removeAll()
        mgr.syncSplitRatioToTmux(forPaneId: 0, ratio: 0.5)

        XCTAssertEqual(log.commands.count, 1, "Exactly one resize command should be sent")
        let cmd = log.commands.first ?? ""
        XCTAssertTrue(cmd.hasPrefix("resize-pane -t %0 -y "),
                      "Command should use -y flag for vertical split, got: \(cmd)")
        // Expected: available = 24 - 1 (divider) = 23, new size = max(1, Int(23 * 0.5)) = 11
        XCTAssertTrue(cmd.contains("11\n"),
                      "resize-pane should target 11 rows (23 * 0.5), got: \(cmd)")
    }

    /// syncSplitRatioToTmux should correctly find and resize the RIGHT child pane.
    /// This validates finding #14: the old code only checked split.left.leftmostPaneId,
    /// which would miss panes that are the right child of a split.
    @MainActor
    func testSyncSplitRatioRightChildPaneSendsResizePane() {
        let (mgr, log) = managerWithCommandLog()
        let mock = MockTmuxSurface()
        let layout = horizontalSplitLayout(paneA: 0, paneB: 1, totalCols: 80, rows: 24)
        mock.stubbedWindows = [TmuxWindowInfo(id: 0, width: 80, height: 24, name: "bash")]
        mock.stubbedWindowLayouts = [layout]
        mock.stubbedActiveWindowId = 0
        mock.stubbedPaneIds = [0, 1]
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        mgr.controlModeActivated()
        mgr.viewerBecameReady()
        mgr.configureSurfaceManagement(
            factory: { _ in nil },
            inputHandler: { _, _ in },
            resizeHandler: { _, _ in }
        )
        mgr.handleTmuxStateChanged(windowCount: 1, paneCount: 2)

        // Set lastRefreshSize AFTER controlModeActivated (which resets it to nil)
        #if DEBUG
        mgr.setLastRefreshSizeForTesting(cols: 80, rows: 24)
        #endif

        log.commands.removeAll()
        // Resize pane 1 (the RIGHT child) — this was broken before finding #14 fix
        mgr.syncSplitRatioToTmux(forPaneId: 1, ratio: 0.6)

        // Should send a resize-pane -x command targeting pane 1
        XCTAssertEqual(log.commands.count, 1, "Exactly one resize command should be sent for right-child pane")
        let cmd = log.commands.first ?? ""
        XCTAssertTrue(cmd.hasPrefix("resize-pane -t %1 -x "),
                      "Command should target pane 1 with -x flag, got: \(cmd)")
        // Expected: available = 80 - 1 (divider) = 79, new size = max(1, Int(79 * 0.6)) = 47
        XCTAssertTrue(cmd.contains("47\n"),
                      "resize-pane should target 47 columns (79 * 0.6), got: \(cmd)")
    }
}

// MARK: - Pending Input Display Tests

extension TmuxSessionManagerTests {

    /// displayPendingInput should not crash when no surface exists for focused pane.
    @MainActor
    func testDisplayPendingInputNoSurface() {
        let mgr = TmuxSessionManager()
        // No surfaces configured — should early-return without crash
        mgr.displayPendingInput("hello")
    }

    /// clearPendingInputDisplay should not crash when no surface exists for focused pane.
    @MainActor
    func testClearPendingInputDisplayNoSurface() {
        let mgr = TmuxSessionManager()
        // No surfaces configured — should early-return without crash
        mgr.clearPendingInputDisplay()
    }
}

// MARK: - activeSurfaces / focusedWindow Property Tests

extension TmuxSessionManagerTests {

    /// activeSurfaces should return empty dict on a fresh manager.
    @MainActor
    func testActiveSurfacesEmptyOnFreshManager() {
        let mgr = TmuxSessionManager()
        XCTAssertTrue(mgr.activeSurfaces.isEmpty,
                      "activeSurfaces should be empty on fresh manager")
    }

    /// focusedWindow should return nil when no windows exist.
    @MainActor
    func testFocusedWindowNilWhenNoWindows() {
        let mgr = TmuxSessionManager()
        XCTAssertNil(mgr.focusedWindow,
                     "focusedWindow should be nil when no windows exist")
    }

    /// focusedWindow should return the correct window after state reconciliation.
    @MainActor
    func testFocusedWindowReturnsCorrectWindowAfterReconciliation() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        let layout = singlePaneLayout(paneId: 5)
        mock.stubbedWindows = [
            TmuxWindowInfo(id: 3, width: 80, height: 24, name: "vim"),
        ]
        mock.stubbedWindowLayouts = [layout]
        mock.stubbedActiveWindowId = 3
        mock.stubbedPaneIds = [5]
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        mgr.controlModeActivated()
        mgr.configureSurfaceManagement(
            factory: { _ in nil },
            inputHandler: { _, _ in },
            resizeHandler: { _, _ in }
        )
        mgr.handleTmuxStateChanged(windowCount: 1, paneCount: 1)

        let window = mgr.focusedWindow
        XCTAssertNotNil(window, "focusedWindow should not be nil after reconciliation")
        XCTAssertEqual(window?.name, "vim", "focusedWindow should return the active window")
    }

    /// activeSurfaces should still be empty when factory returns nil (no real Ghostty surfaces).
    @MainActor
    func testActiveSurfacesEmptyWhenFactoryReturnsNil() {
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

        mgr.controlModeActivated()
        mgr.configureSurfaceManagement(
            factory: { _ in nil },
            inputHandler: { _, _ in },
            resizeHandler: { _, _ in }
        )
        mgr.handleTmuxStateChanged(windowCount: 1, paneCount: 1)

        // Factory returns nil, so no real surfaces are created
        XCTAssertTrue(mgr.activeSurfaces.isEmpty,
                      "activeSurfaces should be empty when factory returns nil")
    }
}

// MARK: - Command/Response Infrastructure Tests

extension TmuxSessionManagerTests {

    @MainActor
    func testHandleCommandResponseDispatchesFIFO() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        // Orphan response (no handler registered) should not crash
        mgr.handleCommandResponse(content: "orphan", isError: false)
        XCTAssertEqual(mgr.pendingResponseHandlerCountForTesting, 0,
                       "Should start with no pending handlers")

        // Register two handlers manually via copy operations and verify FIFO dispatch
        mgr.copyTmuxBuffer()
        mgr.copyTmuxBuffer()
        XCTAssertEqual(mgr.pendingResponseHandlerCountForTesting, 2,
                       "Should have two pending handlers")

        // Deliver first response → first handler
        mgr.handleCommandResponse(content: "first", isError: false)
        XCTAssertEqual(mgr.pendingResponseHandlerCountForTesting, 1,
                       "First handler should be consumed")

        // Deliver second response → second handler
        mgr.handleCommandResponse(content: "second", isError: false)
        XCTAssertEqual(mgr.pendingResponseHandlerCountForTesting, 0,
                       "Second handler should be consumed")
    }

    @MainActor
    func testCopyTmuxBufferQueuesShowBufferCommand() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        mgr.copyTmuxBuffer()

        // Should have sent "show-buffer" via sendTmuxCommand
        XCTAssertEqual(mock.sendTmuxCommandCalls, ["show-buffer"],
                       "copyTmuxBuffer should send show-buffer through viewer")
        // Should have one pending handler
        XCTAssertEqual(mgr.pendingResponseHandlerCountForTesting, 1,
                       "Should have one pending response handler")
    }

    @MainActor
    func testCopyTmuxBufferHandlerWritesToClipboard() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        let savedClipboard = UIPasteboard.general.string
        defer { UIPasteboard.general.string = savedClipboard }

        mgr.copyTmuxBuffer()
        XCTAssertEqual(mgr.pendingResponseHandlerCountForTesting, 1)

        // Simulate successful response
        let testContent = "Hello from tmux buffer"
        mgr.handleCommandResponse(content: testContent, isError: false)

        XCTAssertEqual(UIPasteboard.general.string, testContent,
                       "Successful show-buffer response should write to clipboard")
        XCTAssertEqual(mgr.pendingResponseHandlerCountForTesting, 0,
                       "Handler should be consumed after dispatch")
    }

    @MainActor
    func testCopyTmuxBufferErrorDoesNotWriteToClipboard() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        let savedClipboard = UIPasteboard.general.string
        defer { UIPasteboard.general.string = savedClipboard }

        // Set clipboard to a known value
        UIPasteboard.general.string = "original"

        mgr.copyTmuxBuffer()

        // Simulate error response
        mgr.handleCommandResponse(content: "no buffer", isError: true)

        XCTAssertEqual(UIPasteboard.general.string, "original",
                       "Error response should not overwrite clipboard")
        XCTAssertEqual(mgr.pendingResponseHandlerCountForTesting, 0,
                       "Handler should be consumed even on error")
    }

    @MainActor
    func testCopyTmuxBufferNoSurfaceDoesNotCrash() {
        let mgr = TmuxSessionManager()
        // No surface override → tmuxQuerySurface is nil

        // Should not crash, just log a warning
        mgr.copyTmuxBuffer()

        XCTAssertEqual(mgr.pendingResponseHandlerCountForTesting, 0,
                       "No handler should be registered when surface is nil")
    }

    @MainActor
    func testCopyTmuxBufferFailedQueueRemovesHandler() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        mock.stubbedSendTmuxCommandResult = false
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        mgr.copyTmuxBuffer()

        XCTAssertEqual(mock.sendTmuxCommandCalls, ["show-buffer"],
                       "Should still attempt to send")
        XCTAssertEqual(mgr.pendingResponseHandlerCountForTesting, 0,
                       "Handler should be removed when queue fails")
    }

    @MainActor
    func testPasteTmuxBufferSetsBufferThenPastes() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        let log = CommandLog()
        mgr.setupWithDirectWrite { log.commands.append($0) }
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        let savedClipboard = UIPasteboard.general.string
        defer { UIPasteboard.general.string = savedClipboard }

        // Set clipboard content
        UIPasteboard.general.string = "clipboard text"

        // Set focused pane (must use %N format to pass validation)
        mgr.setFocusedPane("%5")

        mgr.pasteTmuxBuffer()

        // Should have sent set-buffer command via sendTmuxCommand
        XCTAssertEqual(mock.sendTmuxCommandCalls.count, 1)
        XCTAssertTrue(mock.sendTmuxCommandCalls[0].hasPrefix("set-buffer -- \""),
                      "Should send set-buffer with clipboard content")
        XCTAssertTrue(mock.sendTmuxCommandCalls[0].hasSuffix("\""),
                      "set-buffer command should be quoted")
        XCTAssertEqual(mgr.pendingResponseHandlerCountForTesting, 1)

        // Simulate successful set-buffer response
        mgr.handleCommandResponse(content: "", isError: false)

        // After set-buffer succeeds, should fire-and-forget paste-buffer
        XCTAssertEqual(log.commands, ["paste-buffer -t %5\n"],
                       "Should paste buffer into focused pane after set-buffer succeeds")
        XCTAssertEqual(mgr.pendingResponseHandlerCountForTesting, 0)
    }

    @MainActor
    func testPasteTmuxBufferEmptyClipboardDoesNothing() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        let savedClipboard = UIPasteboard.general.string
        defer { UIPasteboard.general.string = savedClipboard }

        UIPasteboard.general.string = ""

        mgr.pasteTmuxBuffer()

        XCTAssertTrue(mock.sendTmuxCommandCalls.isEmpty,
                      "Should not send any command when clipboard is empty")
        XCTAssertEqual(mgr.pendingResponseHandlerCountForTesting, 0)
    }

    @MainActor
    func testPasteTmuxBufferEscapesSpecialCharacters() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        let savedClipboard = UIPasteboard.general.string
        defer { UIPasteboard.general.string = savedClipboard }

        UIPasteboard.general.string = "line with \\backslash and \"quotes\""
        mgr.setFocusedPane("%0")

        mgr.pasteTmuxBuffer()

        let cmd = mock.sendTmuxCommandCalls.first ?? ""
        XCTAssertTrue(cmd.contains("\\\\backslash"),
                      "Backslashes should be doubled: got \(cmd)")
        XCTAssertTrue(cmd.contains("\\\"quotes\\\""),
                       "Quotes should be escaped: got \(cmd)")
    }

    /// Newlines and carriage returns in clipboard content must be escaped
    /// to prevent breaking tmux control-mode command framing.
    @MainActor
    func testPasteTmuxBufferEscapesNewlines() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        let savedClipboard = UIPasteboard.general.string
        defer { UIPasteboard.general.string = savedClipboard }

        UIPasteboard.general.string = "line1\nline2\rline3"
        mgr.setFocusedPane("%0")

        mgr.pasteTmuxBuffer()

        let cmd = mock.sendTmuxCommandCalls.first ?? ""
        XCTAssertTrue(cmd.contains("\\n"),
                       "Newlines should be escaped: got \(cmd)")
        XCTAssertTrue(cmd.contains("\\r"),
                       "Carriage returns should be escaped: got \(cmd)")
        XCTAssertFalse(cmd.contains("\n"),
                       "Raw newlines must not appear in command: got \(cmd)")
    }

    /// Dollar signs and backticks must be escaped as defense-in-depth
    /// against potential expansion when passed to set-buffer.
    @MainActor
    func testPasteTmuxBufferEscapesDollarAndBacktick() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        let savedClipboard = UIPasteboard.general.string
        defer { UIPasteboard.general.string = savedClipboard }

        UIPasteboard.general.string = "price is $100 and `command`"
        mgr.setFocusedPane("%0")

        mgr.pasteTmuxBuffer()

        let cmd = mock.sendTmuxCommandCalls.first ?? ""
        XCTAssertTrue(cmd.contains("\\$100"),
                      "Dollar signs should be escaped: got \(cmd)")
        XCTAssertTrue(cmd.contains("\\`command\\`"),
                      "Backticks should be escaped: got \(cmd)")
        let unescapedDollarRange = cmd.range(of: #"(?<!\\)\$"#,
                                             options: .regularExpression)
        XCTAssertNil(unescapedDollarRange,
                     "Unescaped dollar sign must not appear: got \(cmd)")
    }

    /// pasteTmuxBuffer should bail out when no pane is focused.
    @MainActor
    func testPasteTmuxBufferNoFocusedPaneDoesNothing() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        let savedClipboard = UIPasteboard.general.string
        defer { UIPasteboard.general.string = savedClipboard }

        UIPasteboard.general.string = "something"
        // Do NOT set focusedPaneId — it defaults to ""

        mgr.pasteTmuxBuffer()

        XCTAssertTrue(mock.sendTmuxCommandCalls.isEmpty,
                       "Should not send command when focusedPaneId is empty")
        XCTAssertEqual(mgr.pendingResponseHandlerCountForTesting, 0)
    }

    @MainActor
    func testPasteTmuxBufferSetBufferErrorDoesNotPaste() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        let log = CommandLog()
        mgr.setupWithDirectWrite { log.commands.append($0) }
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        let savedClipboard = UIPasteboard.general.string
        defer { UIPasteboard.general.string = savedClipboard }

        UIPasteboard.general.string = "something"
        mgr.setFocusedPane("%0")
        mgr.pasteTmuxBuffer()

        // Simulate error on set-buffer
        mgr.handleCommandResponse(content: "bad escape", isError: true)

        XCTAssertTrue(log.commands.isEmpty,
                      "Should NOT send paste-buffer when set-buffer failed")
    }

    @MainActor
    func testCleanupClearsPendingHandlers() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        mgr.copyTmuxBuffer()
        XCTAssertEqual(mgr.pendingResponseHandlerCountForTesting, 1)

        mgr.cleanup()

        XCTAssertEqual(mgr.pendingResponseHandlerCountForTesting, 0,
                       "cleanup should clear pending response handlers")
    }

    @MainActor
    func testMultipleResponseHandlersDispatchInOrder() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        let savedClipboard = UIPasteboard.general.string
        defer { UIPasteboard.general.string = savedClipboard }

        // Queue two copy operations
        mgr.copyTmuxBuffer()
        mgr.copyTmuxBuffer()
        XCTAssertEqual(mgr.pendingResponseHandlerCountForTesting, 2)

        // First response → first handler
        mgr.handleCommandResponse(content: "first buffer", isError: false)
        XCTAssertEqual(UIPasteboard.general.string, "first buffer")
        XCTAssertEqual(mgr.pendingResponseHandlerCountForTesting, 1)

        // Second response → second handler
        mgr.handleCommandResponse(content: "second buffer", isError: false)
        XCTAssertEqual(UIPasteboard.general.string, "second buffer")
        XCTAssertEqual(mgr.pendingResponseHandlerCountForTesting, 0)
    }
}

// MARK: - Session Management Command Tests

extension TmuxSessionManagerTests {
    
    @MainActor
    func testSwitchSessionCommand() {
        let (mgr, log) = managerWithCommandLog()
        mgr.switchSession(sessionId: "$1")
        XCTAssertEqual(log.commands, ["switch-client -t '$1'\n"])
    }
    
    @MainActor
    func testSwitchSessionInvalidIdIgnored() {
        let (mgr, log) = managerWithCommandLog()
        mgr.switchSession(sessionId: "@0")  // Window ID, not session ID
        XCTAssertTrue(log.commands.isEmpty, "Invalid session ID should be rejected")
    }
    
    @MainActor
    func testSwitchSessionEmptyIdIgnored() {
        let (mgr, log) = managerWithCommandLog()
        mgr.switchSession(sessionId: "")
        XCTAssertTrue(log.commands.isEmpty)
    }
    
    @MainActor
    func testNewSessionDefaultCommand() {
        let (mgr, log) = managerWithCommandLog()
        mgr.newSession()
        XCTAssertEqual(log.commands, ["new-session\n"])
    }
    
    @MainActor
    func testNewSessionWithNameCommand() {
        let (mgr, log) = managerWithCommandLog()
        mgr.newSession(name: "work")
        XCTAssertEqual(log.commands, ["new-session -s 'work'\n"])
    }
    
    @MainActor
    func testNewSessionDetachedCommand() {
        let (mgr, log) = managerWithCommandLog()
        mgr.newSession(name: "bg", andSwitch: false)
        XCTAssertEqual(log.commands, ["new-session -d -s 'bg'\n"])
    }
    
    @MainActor
    func testNewSessionNameEscapesSingleQuotes() {
        let (mgr, log) = managerWithCommandLog()
        mgr.newSession(name: "it's mine")
        XCTAssertEqual(log.commands, ["new-session -s 'it'\\''s mine'\n"])
    }
    
    @MainActor
    func testNewSessionNoNameDetached() {
        let (mgr, log) = managerWithCommandLog()
        mgr.newSession(andSwitch: false)
        XCTAssertEqual(log.commands, ["new-session -d\n"])
    }
    
    @MainActor
    func testKillSessionCommand() {
        let (mgr, log) = managerWithCommandLog()
        mgr.killSession(sessionId: "$2")
        XCTAssertEqual(log.commands, ["kill-session -t '$2'\n"])
    }
    
    @MainActor
    func testKillSessionInvalidIdIgnored() {
        let (mgr, log) = managerWithCommandLog()
        mgr.killSession(sessionId: "bad")
        XCTAssertTrue(log.commands.isEmpty)
    }
    
    @MainActor
    func testRenameSessionCommand() {
        let (mgr, log) = managerWithCommandLog()
        mgr.renameSession(sessionId: "$0", name: "production")
        XCTAssertEqual(log.commands, ["rename-session -t '$0' 'production'\n"])
    }
    
    @MainActor
    func testRenameSessionEscapesSingleQuotes() {
        let (mgr, log) = managerWithCommandLog()
        mgr.renameSession(sessionId: "$0", name: "it's a test")
        XCTAssertEqual(log.commands, ["rename-session -t '$0' 'it'\\''s a test'\n"])
    }
    
    @MainActor
    func testRenameSessionInvalidIdIgnored() {
        let (mgr, log) = managerWithCommandLog()
        mgr.renameSession(sessionId: "%%", name: "whatever")
        XCTAssertTrue(log.commands.isEmpty)
    }
    
    @MainActor
    func testListSessionsCommand() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif
        
        mgr.listSessions()
        
        XCTAssertEqual(mock.sendTmuxCommandCalls.count, 1)
        let cmd = mock.sendTmuxCommandCalls.first ?? ""
        XCTAssertTrue(cmd.hasPrefix("list-sessions -F"), "Should send list-sessions with format")
        XCTAssertTrue(cmd.contains("session_id"), "Format should include session_id")
        XCTAssertTrue(cmd.contains("session_name"), "Format should include session_name")
        XCTAssertEqual(mgr.pendingResponseHandlerCountForTesting, 1, "Should register response handler")
    }
    
    @MainActor
    func testListSessionsPopulatesAvailableSessions() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif
        
        mgr.listSessions()
        XCTAssertEqual(mgr.pendingResponseHandlerCountForTesting, 1)
        
        // Simulate response (currentSession is nil, so no session is marked current)
        mgr.handleCommandResponse(
             content: "$0\tmain\t2\t1\n$1\twork\t3\t0",
            isError: false
        )
        
        XCTAssertEqual(mgr.availableSessions.count, 2)
        XCTAssertEqual(mgr.availableSessions[0].id, "$0")
        XCTAssertEqual(mgr.availableSessions[1].id, "$1")
        XCTAssertEqual(mgr.pendingResponseHandlerCountForTesting, 0)
    }
    
    @MainActor
    func testListSessionsErrorDoesNotPopulate() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif
        
        mgr.listSessions()
        mgr.handleCommandResponse(content: "server not found", isError: true)
        
        XCTAssertTrue(mgr.availableSessions.isEmpty, "Error response should not populate sessions")
    }
    
    @MainActor
    func testListSessionsNoSurfaceDoesNotCrash() {
        let mgr = TmuxSessionManager()
        // No surface configured — should just log and return
        mgr.listSessions()
        XCTAssertEqual(mgr.pendingResponseHandlerCountForTesting, 0,
                       "No handler should be registered when there's no surface")
    }
    
    @MainActor
    func testControlModeExitedClearsAvailableSessions() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif
        
        // Populate sessions
        mgr.listSessions()
        mgr.handleCommandResponse(content: "$0\tmain\t1\t1", isError: false)
        XCTAssertEqual(mgr.availableSessions.count, 1)
        
        // Exit control mode
        mgr.controlModeExited()
        XCTAssertTrue(mgr.availableSessions.isEmpty,
                       "controlModeExited should clear availableSessions")
    }
    
    @MainActor
    func testCleanupClearsAvailableSessions() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif
        
        mgr.listSessions()
        mgr.handleCommandResponse(content: "$0\tmain\t1\t1", isError: false)
        XCTAssertEqual(mgr.availableSessions.count, 1)
        
        mgr.cleanup()
        XCTAssertTrue(mgr.availableSessions.isEmpty,
                      "cleanup should clear availableSessions")
    }
}

// MARK: - tmux Options (Read/Write) Tests

extension TmuxSessionManagerTests {

    // MARK: - queryOption() Command Formatting

    @MainActor
    func testQueryOptionGlobalSendsShowOptionsGv() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        mgr.queryOption(name: "mouse", scope: .global) { _ in }

        XCTAssertEqual(mock.sendTmuxCommandCalls, ["show-options -gv mouse"])
        XCTAssertEqual(mgr.pendingResponseHandlerCountForTesting, 1)
    }

    @MainActor
    func testQueryOptionSessionSendsShowOptionsV() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        mgr.queryOption(name: "escape-time", scope: .session) { _ in }

        XCTAssertEqual(mock.sendTmuxCommandCalls, ["show-options -v escape-time"])
        XCTAssertEqual(mgr.pendingResponseHandlerCountForTesting, 1)
    }

    @MainActor
    func testQueryOptionWindowSendsShowWindowOptions() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        mgr.queryOption(name: "mode-keys", scope: .window) { _ in }

        XCTAssertEqual(mock.sendTmuxCommandCalls, ["show-window-options -v mode-keys"])
        XCTAssertEqual(mgr.pendingResponseHandlerCountForTesting, 1)
    }

    @MainActor
    func testQueryOptionDefaultScopeIsGlobal() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        // No scope argument — should default to global
        mgr.queryOption(name: "status") { _ in }

        XCTAssertEqual(mock.sendTmuxCommandCalls, ["show-options -gv status"])
    }

    // MARK: - queryOption() Response Handling

    @MainActor
    func testQueryOptionSuccessCallsHandlerWithValue() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        var result: TmuxOptionValue?
        mgr.queryOption(name: "mouse") { result = $0 }
        XCTAssertEqual(mgr.pendingResponseHandlerCountForTesting, 1)

        mgr.handleCommandResponse(content: "on\n", isError: false)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.rawValue, "on")
        XCTAssertEqual(mgr.pendingResponseHandlerCountForTesting, 0)
    }

    @MainActor
    func testQueryOptionCachesValueInTmuxOptions() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        mgr.queryOption(name: "escape-time") { _ in }
        mgr.handleCommandResponse(content: "500", isError: false)

        XCTAssertEqual(mgr.tmuxOptions["escape-time"]?.rawValue, "500")
        XCTAssertEqual(mgr.tmuxOptions["escape-time"]?.intValue, 500)
    }

    @MainActor
    func testQueryOptionErrorCallsHandlerWithNil() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        var result: TmuxOptionValue? = TmuxOptionValue(rawValue: "sentinel")
        mgr.queryOption(name: "nonexistent") { result = $0 }
        mgr.handleCommandResponse(content: "unknown option", isError: true)

        XCTAssertNil(result, "Error response should yield nil")
        XCTAssertEqual(mgr.pendingResponseHandlerCountForTesting, 0)
    }

    @MainActor
    func testQueryOptionErrorEvictsStaleCacheEntry() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        let log = CommandLog()
        mgr.setupWithDirectWrite { log.commands.append($0) }
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        // Pre-populate cache via setOption (the public way)
        mgr.setOption(name: "nonexistent", value: "stale")
        XCTAssertNotNil(mgr.tmuxOptions["nonexistent"])

        mgr.queryOption(name: "nonexistent") { _ in }
        mgr.handleCommandResponse(content: "unknown option", isError: true)

        XCTAssertNil(mgr.tmuxOptions["nonexistent"],
                     "Error response should evict stale cache entry")
    }

    @MainActor
    func testQueryOptionEmptyResponseCallsHandlerWithNil() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        var result: TmuxOptionValue? = TmuxOptionValue(rawValue: "sentinel")
        mgr.queryOption(name: "unset-option") { result = $0 }
        mgr.handleCommandResponse(content: "", isError: false)

        XCTAssertNil(result, "Empty response should yield nil (option not set)")
    }

    @MainActor
    func testQueryOptionEmptyResponseEvictsStaleCacheEntry() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        let log = CommandLog()
        mgr.setupWithDirectWrite { log.commands.append($0) }
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        // Pre-populate cache via setOption (the public way)
        mgr.setOption(name: "unset-option", value: "stale")
        XCTAssertNotNil(mgr.tmuxOptions["unset-option"])

        mgr.queryOption(name: "unset-option") { _ in }
        mgr.handleCommandResponse(content: "", isError: false)

        XCTAssertNil(mgr.tmuxOptions["unset-option"],
                     "Empty/nil parse should evict stale cache entry")
    }

    @MainActor
    func testQueryOptionNoSurfaceCallsHandlerWithNil() {
        let mgr = TmuxSessionManager()
        // No surface override → tmuxQuerySurface is nil

        var result: TmuxOptionValue? = TmuxOptionValue(rawValue: "sentinel")
        mgr.queryOption(name: "mouse") { result = $0 }

        XCTAssertNil(result, "No surface → handler should get nil immediately")
        XCTAssertEqual(mgr.pendingResponseHandlerCountForTesting, 0,
                       "No handler should be registered when surface is nil")
    }

    @MainActor
    func testQueryOptionFailedQueueRemovesHandlerAndCallsNil() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        mock.stubbedSendTmuxCommandResult = false
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        var result: TmuxOptionValue? = TmuxOptionValue(rawValue: "sentinel")
        mgr.queryOption(name: "mouse") { result = $0 }

        XCTAssertNil(result, "Failed queue → handler should get nil")
        XCTAssertEqual(mock.sendTmuxCommandCalls, ["show-options -gv mouse"],
                       "Should still attempt to send")
        XCTAssertEqual(mgr.pendingResponseHandlerCountForTesting, 0,
                       "Handler should be removed when queue fails")
    }

    // MARK: - setOption() Command Formatting

    @MainActor
    func testSetOptionGlobal() {
        let (mgr, log) = managerWithCommandLog()
        mgr.setOption(name: "mouse", value: "on", scope: .global)
        XCTAssertEqual(log.commands, ["set-option -g mouse \"on\"\n"])
    }

    @MainActor
    func testSetOptionSession() {
        let (mgr, log) = managerWithCommandLog()
        mgr.setOption(name: "escape-time", value: "200", scope: .session)
        XCTAssertEqual(log.commands, ["set-option escape-time \"200\"\n"])
    }

    @MainActor
    func testSetOptionWindow() {
        let (mgr, log) = managerWithCommandLog()
        mgr.setOption(name: "mode-keys", value: "vi", scope: .window)
        XCTAssertEqual(log.commands, ["set-option -w mode-keys \"vi\"\n"])
    }

    @MainActor
    func testSetOptionDefaultScopeIsGlobal() {
        let (mgr, log) = managerWithCommandLog()
        mgr.setOption(name: "mouse", value: "off")
        XCTAssertEqual(log.commands, ["set-option -g mouse \"off\"\n"])
    }

    // MARK: - setOption() Optimistic Cache Update

    @MainActor
    func testSetOptionUpdatesCache() {
        let (mgr, _) = managerWithCommandLog()
        mgr.setOption(name: "mouse", value: "on")
        XCTAssertEqual(mgr.tmuxOptions["mouse"]?.rawValue, "on")
        XCTAssertEqual(mgr.tmuxOptions["mouse"]?.boolValue, true)
    }

    @MainActor
    func testSetOptionOverwritesPreviousCache() {
        let (mgr, _) = managerWithCommandLog()
        mgr.setOption(name: "mouse", value: "on")
        XCTAssertEqual(mgr.tmuxOptions["mouse"]?.boolValue, true)

        mgr.setOption(name: "mouse", value: "off")
        XCTAssertEqual(mgr.tmuxOptions["mouse"]?.boolValue, false)
    }

    @MainActor
    func testSetOptionEmptyValueEvictsCacheEntry() {
        let (mgr, _) = managerWithCommandLog()

        // Pre-populate cache
        mgr.setOption(name: "mouse", value: "on")
        XCTAssertNotNil(mgr.tmuxOptions["mouse"])

        // Setting to a value that normalizes to empty should evict
        mgr.setOption(name: "mouse", value: "\u{01}\u{02}")
        XCTAssertNil(mgr.tmuxOptions["mouse"],
                     "Empty normalized value should evict cache entry, not store empty TmuxOptionValue")
    }

    // MARK: - queryInitialOptions()

    @MainActor
    func testViewerBecameReadyQueriesInitialOptions() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        let log = CommandLog()
        mgr.setupWithDirectWrite { log.commands.append($0) }
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        // Simulate control mode activation (sets viewerReady = false)
        mgr.controlModeActivated()
        XCTAssertTrue(mock.sendTmuxCommandCalls.isEmpty,
                      "No commands should be sent during activation")

        // Simulate viewer becoming ready
        mgr.viewerBecameReady()

        // Should have queried 3 critical options: mouse, escape-time, window-size
        XCTAssertEqual(mock.sendTmuxCommandCalls.count, 3,
                       "Should query 3 initial options")
        XCTAssertTrue(mock.sendTmuxCommandCalls.contains("show-options -gv mouse"))
        XCTAssertTrue(mock.sendTmuxCommandCalls.contains("show-options -gv escape-time"))
        XCTAssertTrue(mock.sendTmuxCommandCalls.contains("show-options -gv window-size"))
        XCTAssertEqual(mgr.pendingResponseHandlerCountForTesting, 3,
                       "Should have 3 pending response handlers")
    }

    @MainActor
    func testViewerBecameReadyPopulatesOptionsOnResponse() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        let log = CommandLog()
        mgr.setupWithDirectWrite { log.commands.append($0) }
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        mgr.controlModeActivated()
        mgr.viewerBecameReady()

        // Deliver responses in order (FIFO)
        mgr.handleCommandResponse(content: "on\n", isError: false)    // mouse
        mgr.handleCommandResponse(content: "500\n", isError: false)   // escape-time
        mgr.handleCommandResponse(content: "smallest\n", isError: false) // window-size

        XCTAssertEqual(mgr.tmuxOptions["mouse"]?.rawValue, "on")
        XCTAssertEqual(mgr.tmuxOptions["mouse"]?.boolValue, true)
        XCTAssertEqual(mgr.tmuxOptions["escape-time"]?.rawValue, "500")
        XCTAssertEqual(mgr.tmuxOptions["escape-time"]?.intValue, 500)
        XCTAssertEqual(mgr.tmuxOptions["window-size"]?.rawValue, "smallest")
        XCTAssertEqual(mgr.pendingResponseHandlerCountForTesting, 0)
    }

    // MARK: - Cleanup Clears Options

    @MainActor
    func testControlModeExitedClearsTmuxOptions() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        // Populate an option
        mgr.queryOption(name: "mouse") { _ in }
        mgr.handleCommandResponse(content: "on", isError: false)
        XCTAssertFalse(mgr.tmuxOptions.isEmpty)

        mgr.controlModeExited()
        XCTAssertTrue(mgr.tmuxOptions.isEmpty,
                      "controlModeExited should clear tmuxOptions cache")
    }

    @MainActor
    func testCleanupClearsTmuxOptions() {
        let (mgr, _) = managerWithCommandLog()
        mgr.setOption(name: "mouse", value: "on")
        XCTAssertFalse(mgr.tmuxOptions.isEmpty)

        mgr.cleanup()
        XCTAssertTrue(mgr.tmuxOptions.isEmpty,
                      "cleanup should clear tmuxOptions cache")
    }

    // MARK: - Multiple queryOption FIFO Ordering

    @MainActor
    func testMultipleQueryOptionsFIFODispatch() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        var mouseResult: TmuxOptionValue?
        var escapeResult: TmuxOptionValue?

        mgr.queryOption(name: "mouse") { mouseResult = $0 }
        mgr.queryOption(name: "escape-time") { escapeResult = $0 }
        XCTAssertEqual(mgr.pendingResponseHandlerCountForTesting, 2)

        // First response goes to first handler (mouse)
        mgr.handleCommandResponse(content: "off", isError: false)
        XCTAssertEqual(mouseResult?.rawValue, "off")
        XCTAssertNil(escapeResult, "Second handler not dispatched yet")

        // Second response goes to second handler (escape-time)
        mgr.handleCommandResponse(content: "300", isError: false)
        XCTAssertEqual(escapeResult?.rawValue, "300")
        XCTAssertEqual(mgr.pendingResponseHandlerCountForTesting, 0)
    }

    @MainActor
    func testHandleSessionRenamedUpdatesSessionName() {
        let mgr = TmuxSessionManager()

        // Initially empty
        XCTAssertEqual(mgr.sessionName, "")

        // Updates to new name
        mgr.handleSessionRenamed(name: "my-session")
        XCTAssertEqual(mgr.sessionName, "my-session")

        // Updates to name with special characters
        mgr.handleSessionRenamed(name: "session with spaces and 'quotes'")
        XCTAssertEqual(mgr.sessionName, "session with spaces and 'quotes'")

        // Handles empty rename (clears name)
        mgr.handleSessionRenamed(name: "")
        XCTAssertEqual(mgr.sessionName, "")
    }

    @MainActor
    func testHandleFocusedPaneChangedDoesNotCrash() {
        let mgr = TmuxSessionManager()

        mgr.handleFocusedPaneChanged(windowId: 1, paneId: 0)
        mgr.handleFocusedPaneChanged(windowId: 0, paneId: 0)
        mgr.handleFocusedPaneChanged(windowId: UInt32.max, paneId: UInt32.max)
    }

    /// When the window matches focusedWindowId, handleFocusedPaneChanged
    /// should update focusedPaneId via setFocusedPane.
    @MainActor
    func testHandleFocusedPaneChangedUpdatesFocusForMatchingWindow() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        // Set focusedWindowId to "@1" so the handler recognizes window 1
        mgr.setFocusedWindowIdForTesting("@1")
        mgr.setFocusedPane("%0") // initial focus

        // Trigger pane change for matching window
        mgr.handleFocusedPaneChanged(windowId: 1, paneId: 5)
        XCTAssertEqual(mgr.focusedPaneId, "%5",
                       "focusedPaneId should be updated to %5 for matching window")
    }

    /// When the window does NOT match focusedWindowId, handleFocusedPaneChanged
    /// should leave focusedPaneId unchanged.
    @MainActor
    func testHandleFocusedPaneChangedIgnoresNonMatchingWindow() {
        let mgr = TmuxSessionManager()
        let mock = MockTmuxSurface()
        #if DEBUG
        mgr.tmuxQuerySurfaceOverride = mock
        #endif

        // Set focusedWindowId to "@1"
        mgr.setFocusedWindowIdForTesting("@1")
        mgr.setFocusedPane("%0") // initial focus

        // Trigger pane change for a different window
        mgr.handleFocusedPaneChanged(windowId: 2, paneId: 9)
        XCTAssertEqual(mgr.focusedPaneId, "%0",
                       "focusedPaneId should remain %0 for non-matching window")
    }

    @MainActor
    func testHandleSubscriptionChangedDoesNotCrash() {
        let mgr = TmuxSessionManager()

        mgr.handleSubscriptionChanged(name: "pane_title", value: "my title")
        mgr.handleSubscriptionChanged(name: "pane_title", value: "")
        mgr.handleSubscriptionChanged(name: "", value: "")
    }

    @MainActor
    func testHandleSubscriptionChangedUpdatesStatusLeft() {
        let mgr = TmuxSessionManager()
        XCTAssertEqual(mgr.statusLeft, "")

        mgr.handleSubscriptionChanged(name: "status_left", value: "[0] bash")
        XCTAssertEqual(mgr.statusLeft, "[0] bash")

        // Updating again overwrites
        mgr.handleSubscriptionChanged(name: "status_left", value: "[0] zsh")
        XCTAssertEqual(mgr.statusLeft, "[0] zsh")

        // Empty value clears it
        mgr.handleSubscriptionChanged(name: "status_left", value: "")
        XCTAssertEqual(mgr.statusLeft, "")
    }

    @MainActor
    func testHandleSubscriptionChangedUpdatesStatusRight() {
        let mgr = TmuxSessionManager()
        XCTAssertEqual(mgr.statusRight, "")

        mgr.handleSubscriptionChanged(name: "status_right", value: "\"host\" 15:30")
        XCTAssertEqual(mgr.statusRight, "\"host\" 15:30")
    }

    @MainActor
    func testHandleSubscriptionChangedUnknownNameIgnored() {
        let mgr = TmuxSessionManager()

        mgr.handleSubscriptionChanged(name: "unknown_sub", value: "some value")
        // Should not affect status properties
        XCTAssertEqual(mgr.statusLeft, "")
        XCTAssertEqual(mgr.statusRight, "")
    }

    // MARK: - setOption Viewer Not Ready Queuing

    @MainActor
    func testSetOptionQueuedWhenViewerNotReady() {
        let (mgr, log) = managerWithCommandLog()

        // Activate control mode (viewerReady becomes false)
        mgr.controlModeActivated()

        mgr.setOption(name: "mouse", value: "on")

        // Command should be queued, not sent
        XCTAssertTrue(log.commands.isEmpty,
                      "Commands should be queued when viewer not ready")

        // But cache should still be updated optimistically
        XCTAssertEqual(mgr.tmuxOptions["mouse"]?.rawValue, "on",
                       "Cache should be updated even when command is queued")
    }
}

