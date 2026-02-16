import XCTest
@testable import Geistty

// MARK: - TmuxStateReconciliation Tests

/// Tests for TmuxSessionManager.reconcileTmuxState() — the pure state
/// reconciliation logic extracted from handleTmuxStateChanged().
///
/// These tests verify:
/// - Window dict population from snapshot data
/// - Layout parsing into split trees
/// - Focused window selection (active window, fallback logic)
/// - Focused pane selection (first pane of focused window)
/// - Return value (numeric pane ID to activate)
///
/// Surface reconciliation (create/remove Ghostty surfaces) is NOT tested here
/// because it requires a real Ghostty surface. That path is covered by
/// integration testing on-device.
final class TmuxStateReconciliationTests: XCTestCase {

    // MARK: - Helpers

    /// Build a valid checksummed layout string for a single pane.
    /// Format: "checksum,WxH,X,Y,paneId"
    private func singlePaneLayout(paneId: Int, cols: Int = 80, rows: Int = 24) -> String {
        let body = "\(cols)x\(rows),0,0,\(paneId)"
        let checksum = TmuxChecksum.calculate(body).asString()
        return "\(checksum),\(body)"
    }

    /// Build a valid checksummed layout string for a horizontal split (2 panes).
    /// Format: "checksum,WxH,X,Y{leftCxH,0,0,paneA,rightCxH,X,0,paneB}"
    private func horizontalSplitLayout(
        paneA: Int, paneB: Int,
        totalCols: Int = 80, rows: Int = 24
    ) -> String {
        let leftCols = totalCols / 2
        let rightCols = totalCols - leftCols - 1  // -1 for separator
        let rightX = leftCols + 1
        let body = "\(totalCols)x\(rows),0,0{\(leftCols)x\(rows),0,0,\(paneA),\(rightCols)x\(rows),\(rightX),0,\(paneB)}"
        let checksum = TmuxChecksum.calculate(body).asString()
        return "\(checksum),\(body)"
    }

    /// Build a TmuxStateSnapshot with the given windows and pane IDs.
    private func makeSnapshot(
        windows: [(id: Int, name: String, layout: String?, focusedPaneId: Int)],
        activeWindowId: Int = -1,
        paneIds: [Int] = []
    ) -> TmuxSessionManager.TmuxStateSnapshot {
        return TmuxSessionManager.TmuxStateSnapshot(
            windows: windows.map { .init(id: $0.id, name: $0.name, layout: $0.layout, focusedPaneId: $0.focusedPaneId) },
            activeWindowId: activeWindowId,
            paneIds: paneIds
        )
    }

    // MARK: - Single Window, Single Pane

    @MainActor
    func testSingleWindowSinglePane() {
        let mgr = TmuxSessionManager()
        let layout = singlePaneLayout(paneId: 0)
        let snapshot = makeSnapshot(
            windows: [(id: 0, name: "bash", layout: layout, focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [0]
        )

        let activePaneId = mgr.reconcileTmuxState(snapshot)

        // Window populated
        XCTAssertEqual(mgr.windows.count, 1)
        XCTAssertEqual(mgr.windows["@0"]?.name, "bash")
        XCTAssertEqual(mgr.windows["@0"]?.index, 0)

        // Focused window set from activeWindowId
        XCTAssertEqual(mgr.focusedWindowId, "@0")

        // Split tree set for focused window
        XCTAssertFalse(mgr.currentSplitTree.isEmpty)
        XCTAssertEqual(mgr.currentSplitTree.paneIds, [0])

        // Focused pane set to first pane of focused window
        XCTAssertEqual(mgr.focusedPaneId, "%0")

        // Returns numeric pane ID to activate
        XCTAssertEqual(activePaneId, 0)
    }

    // MARK: - Single Window, Two Panes (Split)

    @MainActor
    func testSingleWindowTwoPanes() {
        let mgr = TmuxSessionManager()
        let layout = horizontalSplitLayout(paneA: 0, paneB: 1)
        let snapshot = makeSnapshot(
            windows: [(id: 0, name: "vim", layout: layout, focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [0, 1]
        )

        let activePaneId = mgr.reconcileTmuxState(snapshot)

        XCTAssertEqual(mgr.windows.count, 1)
        XCTAssertTrue(mgr.currentSplitTree.isSplit)
        XCTAssertEqual(Set(mgr.currentSplitTree.paneIds), Set([0, 1]))

        // Focused pane is first pane from split tree
        XCTAssertEqual(mgr.focusedPaneId, "%0")
        XCTAssertEqual(activePaneId, 0)

        // Window model has pane IDs back-filled from layout
        XCTAssertEqual(Set(mgr.windows["@0"]?.paneIds ?? []), Set(["%0", "%1"]))
    }

    // MARK: - Multiple Windows

    @MainActor
    func testMultipleWindows() {
        let mgr = TmuxSessionManager()
        let layout0 = singlePaneLayout(paneId: 0)
        let layout1 = singlePaneLayout(paneId: 1)
        let snapshot = makeSnapshot(
            windows: [
                (id: 0, name: "bash", layout: layout0, focusedPaneId: -1),
                (id: 1, name: "vim", layout: layout1, focusedPaneId: -1),
            ],
            activeWindowId: 1,
            paneIds: [0, 1]
        )

        let activePaneId = mgr.reconcileTmuxState(snapshot)

        XCTAssertEqual(mgr.windows.count, 2)
        XCTAssertEqual(mgr.windows["@0"]?.name, "bash")
        XCTAssertEqual(mgr.windows["@1"]?.name, "vim")

        // Active window is @1
        XCTAssertEqual(mgr.focusedWindowId, "@1")

        // Split tree is for window @1 (single pane 1)
        XCTAssertEqual(mgr.currentSplitTree.paneIds, [1])

        // Focused pane is %1 (first pane of window @1)
        XCTAssertEqual(mgr.focusedPaneId, "%1")
        XCTAssertEqual(activePaneId, 1)
    }

    // MARK: - Active Window Fallback

    @MainActor
    func testActiveWindowFallbackToFirst() {
        let mgr = TmuxSessionManager()
        let layout = singlePaneLayout(paneId: 5)
        let snapshot = makeSnapshot(
            windows: [(id: 3, name: "zsh", layout: layout, focusedPaneId: -1)],
            activeWindowId: -1,  // No active window
            paneIds: [5]
        )

        let activePaneId = mgr.reconcileTmuxState(snapshot)

        // Should fall back to first window
        XCTAssertEqual(mgr.focusedWindowId, "@3")
        XCTAssertEqual(mgr.focusedPaneId, "%5")
        XCTAssertEqual(activePaneId, 5)
    }

    @MainActor
    func testActiveWindowIdNotInWindows() {
        let mgr = TmuxSessionManager()
        let layout = singlePaneLayout(paneId: 0)
        let snapshot = makeSnapshot(
            windows: [(id: 0, name: "bash", layout: layout, focusedPaneId: -1)],
            activeWindowId: 99,  // Non-existent window
            paneIds: [0]
        )

        let activePaneId = mgr.reconcileTmuxState(snapshot)

        // Should fall back to first window since @99 doesn't exist
        XCTAssertEqual(mgr.focusedWindowId, "@0")
        XCTAssertEqual(activePaneId, 0)
    }

    // MARK: - Empty State

    @MainActor
    func testEmptySnapshot() {
        let mgr = TmuxSessionManager()
        let snapshot = makeSnapshot(windows: [], activeWindowId: -1, paneIds: [])

        let activePaneId = mgr.reconcileTmuxState(snapshot)

        XCTAssertEqual(mgr.windows.count, 0)
        XCTAssertTrue(mgr.currentSplitTree.isEmpty)
        XCTAssertEqual(mgr.focusedWindowId, "")
        XCTAssertEqual(mgr.focusedPaneId, "")
        XCTAssertNil(activePaneId)
    }

    // MARK: - Window Without Layout

    @MainActor
    func testWindowWithNoLayout() {
        let mgr = TmuxSessionManager()
        let snapshot = makeSnapshot(
            windows: [(id: 0, name: "bash", layout: nil, focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [0]
        )

        let activePaneId = mgr.reconcileTmuxState(snapshot)

        // Window should exist but no split tree
        XCTAssertEqual(mgr.windows.count, 1)
        XCTAssertTrue(mgr.currentSplitTree.isEmpty,
                      "No layout means no split tree — cleared to avoid stale data")

        // Focused window still set, but no pane from tree
        XCTAssertEqual(mgr.focusedWindowId, "@0")
        // focusedPaneId stays empty (no tree to derive from)
        XCTAssertEqual(mgr.focusedPaneId, "")
        XCTAssertNil(activePaneId)
    }

    // MARK: - State Transitions (Sequential Reconciliations)

    @MainActor
    func testWindowFocusChange() {
        let mgr = TmuxSessionManager()

        // First reconciliation: two windows, active = @0
        let layout0 = singlePaneLayout(paneId: 0)
        let layout1 = singlePaneLayout(paneId: 1)
        _ = mgr.reconcileTmuxState(makeSnapshot(
            windows: [
                (id: 0, name: "bash", layout: layout0, focusedPaneId: -1),
                (id: 1, name: "vim", layout: layout1, focusedPaneId: -1),
            ],
            activeWindowId: 0,
            paneIds: [0, 1]
        ))

        XCTAssertEqual(mgr.focusedWindowId, "@0")
        XCTAssertEqual(mgr.focusedPaneId, "%0")

        // Second reconciliation: active window changes to @1
        let activePaneId = mgr.reconcileTmuxState(makeSnapshot(
            windows: [
                (id: 0, name: "bash", layout: layout0, focusedPaneId: -1),
                (id: 1, name: "vim", layout: layout1, focusedPaneId: -1),
            ],
            activeWindowId: 1,
            paneIds: [0, 1]
        ))

        XCTAssertEqual(mgr.focusedWindowId, "@1")
        XCTAssertEqual(mgr.focusedPaneId, "%1")
        XCTAssertEqual(mgr.currentSplitTree.paneIds, [1])
        XCTAssertEqual(activePaneId, 1)
    }

    @MainActor
    func testFocusedPaneStaysWhenWindowUnchanged() {
        let mgr = TmuxSessionManager()
        let layout = horizontalSplitLayout(paneA: 0, paneB: 1)

        // First reconciliation
        _ = mgr.reconcileTmuxState(makeSnapshot(
            windows: [(id: 0, name: "bash", layout: layout, focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [0, 1]
        ))

        XCTAssertEqual(mgr.focusedPaneId, "%0")

        // Manually change focused pane (simulating user click)
        mgr.setFocusedPane("%1")
        XCTAssertEqual(mgr.focusedPaneId, "%1")

        // Second reconciliation: same window still active
        let activePaneId = mgr.reconcileTmuxState(makeSnapshot(
            windows: [(id: 0, name: "bash", layout: layout, focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [0, 1]
        ))

        // focusedPaneId should NOT change because window didn't change
        XCTAssertEqual(mgr.focusedPaneId, "%1",
                      "Focused pane should be preserved when window doesn't change")
        XCTAssertEqual(activePaneId, 1)
    }

    @MainActor
    func testWindowAdded() {
        let mgr = TmuxSessionManager()
        let layout0 = singlePaneLayout(paneId: 0)

        // Start with one window
        _ = mgr.reconcileTmuxState(makeSnapshot(
            windows: [(id: 0, name: "bash", layout: layout0, focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [0]
        ))

        XCTAssertEqual(mgr.windows.count, 1)

        // New window added, focus stays on @0
        let layout1 = singlePaneLayout(paneId: 1)
        _ = mgr.reconcileTmuxState(makeSnapshot(
            windows: [
                (id: 0, name: "bash", layout: layout0, focusedPaneId: -1),
                (id: 1, name: "vim", layout: layout1, focusedPaneId: -1),
            ],
            activeWindowId: 0,
            paneIds: [0, 1]
        ))

        XCTAssertEqual(mgr.windows.count, 2)
        XCTAssertEqual(mgr.focusedWindowId, "@0",
                      "Focus should stay on original window")
    }

    @MainActor
    func testWindowRemoved() {
        let mgr = TmuxSessionManager()
        let layout0 = singlePaneLayout(paneId: 0)
        let layout1 = singlePaneLayout(paneId: 1)

        // Start with two windows
        _ = mgr.reconcileTmuxState(makeSnapshot(
            windows: [
                (id: 0, name: "bash", layout: layout0, focusedPaneId: -1),
                (id: 1, name: "vim", layout: layout1, focusedPaneId: -1),
            ],
            activeWindowId: 1,
            paneIds: [0, 1]
        ))

        XCTAssertEqual(mgr.focusedWindowId, "@1")

        // Window @1 removed, active becomes @0
        _ = mgr.reconcileTmuxState(makeSnapshot(
            windows: [(id: 0, name: "bash", layout: layout0, focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [0]
        ))

        XCTAssertEqual(mgr.windows.count, 1)
        XCTAssertEqual(mgr.focusedWindowId, "@0")
        XCTAssertEqual(mgr.focusedPaneId, "%0")
    }

    // MARK: - Invalid Layout

    @MainActor
    func testInvalidLayoutStringDropsStaleTree() {
        let mgr = TmuxSessionManager()
        let goodLayout = singlePaneLayout(paneId: 0)

        // First: valid layout
        _ = mgr.reconcileTmuxState(makeSnapshot(
            windows: [(id: 0, name: "bash", layout: goodLayout, focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [0]
        ))

        XCTAssertFalse(mgr.currentSplitTree.isEmpty)

        // Second: invalid layout string
        _ = mgr.reconcileTmuxState(makeSnapshot(
            windows: [(id: 0, name: "bash", layout: "garbage", focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [0]
        ))

        // M15: stale trees are dropped on parse failure to avoid inconsistency
        // with the freshly-built windows dict. UI falls back to single-pane view.
        XCTAssertTrue(mgr.currentSplitTree.isEmpty,
                      "Invalid layout should drop stale tree, not preserve it")
    }

    // MARK: - selectWindow() State Logic

    @MainActor
    func testSelectWindowUpdatesFocusedWindowAndPane() {
        let mgr = TmuxSessionManager()

        // Set up two windows via reconciliation
        let layout0 = singlePaneLayout(paneId: 0)
        let layout1 = singlePaneLayout(paneId: 1)
        _ = mgr.reconcileTmuxState(makeSnapshot(
            windows: [
                (id: 0, name: "bash", layout: layout0, focusedPaneId: -1),
                (id: 1, name: "vim", layout: layout1, focusedPaneId: -1),
            ],
            activeWindowId: 0,
            paneIds: [0, 1]
        ))

        XCTAssertEqual(mgr.focusedWindowId, "@0")
        XCTAssertEqual(mgr.focusedPaneId, "%0")

        // selectWindow switches to @1
        mgr.selectWindow("@1")

        XCTAssertEqual(mgr.focusedWindowId, "@1")
        XCTAssertEqual(mgr.focusedPaneId, "%1")
        XCTAssertEqual(mgr.currentSplitTree.paneIds, [1])
    }

    @MainActor
    func testSelectWindowUnknownWindowClearsSplitTree() {
        let mgr = TmuxSessionManager()
        let layout = singlePaneLayout(paneId: 0)

        _ = mgr.reconcileTmuxState(makeSnapshot(
            windows: [(id: 0, name: "bash", layout: layout, focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [0]
        ))

        XCTAssertFalse(mgr.currentSplitTree.isEmpty)

        // Select a window that doesn't exist in our state
        mgr.selectWindow("@99")

        XCTAssertTrue(mgr.currentSplitTree.isEmpty,
                     "Selecting unknown window should clear split tree")
    }

    // MARK: - setFocusedPane() State Logic

    @MainActor
    func testSetFocusedPaneUpdatesState() {
        let mgr = TmuxSessionManager()
        let layout = horizontalSplitLayout(paneA: 0, paneB: 1)

        _ = mgr.reconcileTmuxState(makeSnapshot(
            windows: [(id: 0, name: "bash", layout: layout, focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [0, 1]
        ))

        XCTAssertEqual(mgr.focusedPaneId, "%0")

        mgr.setFocusedPane("%1")
        XCTAssertEqual(mgr.focusedPaneId, "%1")
    }

    @MainActor
    func testSetFocusedPaneNoOpWhenSame() {
        let mgr = TmuxSessionManager()
        let layout = singlePaneLayout(paneId: 0)

        _ = mgr.reconcileTmuxState(makeSnapshot(
            windows: [(id: 0, name: "bash", layout: layout, focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [0]
        ))

        XCTAssertEqual(mgr.focusedPaneId, "%0")

        // Setting same pane should be a no-op
        mgr.setFocusedPane("%0")
        XCTAssertEqual(mgr.focusedPaneId, "%0")
    }

    // MARK: - Window Index Assignment

    @MainActor
    func testWindowIndicesMatchSnapshotOrder() {
        let mgr = TmuxSessionManager()
        let layout0 = singlePaneLayout(paneId: 0)
        let layout1 = singlePaneLayout(paneId: 1)
        let layout2 = singlePaneLayout(paneId: 2)

        _ = mgr.reconcileTmuxState(makeSnapshot(
            windows: [
                (id: 5, name: "first", layout: layout0, focusedPaneId: -1),
                (id: 3, name: "second", layout: layout1, focusedPaneId: -1),
                (id: 7, name: "third", layout: layout2, focusedPaneId: -1),
            ],
            activeWindowId: 3,
            paneIds: [0, 1, 2]
        ))

        // Indices should match position in the snapshot array
        XCTAssertEqual(mgr.windows["@5"]?.index, 0)
        XCTAssertEqual(mgr.windows["@3"]?.index, 1)
        XCTAssertEqual(mgr.windows["@7"]?.index, 2)
    }

    // MARK: - Pane IDs Back-fill from Layout

    @MainActor
    func testPaneIdsBackfilledFromLayout() {
        let mgr = TmuxSessionManager()
        let layout = horizontalSplitLayout(paneA: 3, paneB: 7)

        _ = mgr.reconcileTmuxState(makeSnapshot(
            windows: [(id: 0, name: "bash", layout: layout, focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [3, 7]
        ))

        // Window model should have pane IDs derived from layout parsing
        let paneIds = mgr.windows["@0"]?.paneIds ?? []
        XCTAssertEqual(Set(paneIds), Set(["%3", "%7"]),
                      "Pane IDs should be back-filled from layout tree")
    }

    // MARK: - Focused Pane from tmux (%window-pane-changed)

    @MainActor
    func testFocusedPaneFromTmuxUsedInsteadOfFirst() {
        let mgr = TmuxSessionManager()
        let layout = horizontalSplitLayout(paneA: 0, paneB: 1)
        // tmux reports pane 1 is focused (via %window-pane-changed)
        let snapshot = makeSnapshot(
            windows: [(id: 0, name: "bash", layout: layout, focusedPaneId: 1)],
            activeWindowId: 0,
            paneIds: [0, 1]
        )

        let activePaneId = mgr.reconcileTmuxState(snapshot)

        // Should use tmux's reported focused pane (1), not first pane (0)
        XCTAssertEqual(mgr.focusedPaneId, "%1",
                      "Should use tmux-reported focused pane, not first pane")
        XCTAssertEqual(activePaneId, 1)
    }

    @MainActor
    func testFocusedPaneUnknownFallsBackToFirstPane() {
        let mgr = TmuxSessionManager()
        let layout = horizontalSplitLayout(paneA: 0, paneB: 1)
        // tmux hasn't sent %window-pane-changed yet (-1 = unknown)
        let snapshot = makeSnapshot(
            windows: [(id: 0, name: "bash", layout: layout, focusedPaneId: -1)],
            activeWindowId: 0,
            paneIds: [0, 1]
        )

        let activePaneId = mgr.reconcileTmuxState(snapshot)

        // Should fall back to first pane since no focus info
        XCTAssertEqual(mgr.focusedPaneId, "%0",
                      "Should fall back to first pane when tmux focus unknown")
        XCTAssertEqual(activePaneId, 0)
    }

    @MainActor
    func testFocusedPaneFromTmuxOnWindowSwitch() {
        let mgr = TmuxSessionManager()
        let layout0 = horizontalSplitLayout(paneA: 0, paneB: 1)
        let layout1 = horizontalSplitLayout(paneA: 2, paneB: 3)

        // First reconciliation: window @0 active, tmux focus on pane 1
        _ = mgr.reconcileTmuxState(makeSnapshot(
            windows: [
                (id: 0, name: "bash", layout: layout0, focusedPaneId: 1),
                (id: 1, name: "vim", layout: layout1, focusedPaneId: 3),
            ],
            activeWindowId: 0,
            paneIds: [0, 1, 2, 3]
        ))

        XCTAssertEqual(mgr.focusedPaneId, "%1")

        // Second reconciliation: window @1 becomes active, tmux reports pane 3 focused
        let activePaneId = mgr.reconcileTmuxState(makeSnapshot(
            windows: [
                (id: 0, name: "bash", layout: layout0, focusedPaneId: 1),
                (id: 1, name: "vim", layout: layout1, focusedPaneId: 3),
            ],
            activeWindowId: 1,
            paneIds: [0, 1, 2, 3]
        ))

        // Should use tmux's reported focused pane for window @1 (pane 3)
        XCTAssertEqual(mgr.focusedPaneId, "%3",
                      "On window switch, should use tmux-reported focused pane for new window")
        XCTAssertEqual(activePaneId, 3)
    }

    @MainActor
    func testFocusedPanePreservedWhenWindowUnchangedWithTmuxFocus() {
        let mgr = TmuxSessionManager()
        let layout = horizontalSplitLayout(paneA: 0, paneB: 1)

        // First reconciliation: tmux says pane 1 is focused
        _ = mgr.reconcileTmuxState(makeSnapshot(
            windows: [(id: 0, name: "bash", layout: layout, focusedPaneId: 1)],
            activeWindowId: 0,
            paneIds: [0, 1]
        ))

        XCTAssertEqual(mgr.focusedPaneId, "%1")

        // User clicks on pane 0 (local focus change, not via tmux)
        mgr.setFocusedPane("%0")
        XCTAssertEqual(mgr.focusedPaneId, "%0")

        // Second reconciliation: same window, tmux still reports pane 1
        let activePaneId = mgr.reconcileTmuxState(makeSnapshot(
            windows: [(id: 0, name: "bash", layout: layout, focusedPaneId: 1)],
            activeWindowId: 0,
            paneIds: [0, 1]
        ))

        // focusedPaneId should NOT change because window didn't change
        XCTAssertEqual(mgr.focusedPaneId, "%0",
                      "User's local focus should be preserved when window doesn't change")
        XCTAssertEqual(activePaneId, 0)
    }
}
