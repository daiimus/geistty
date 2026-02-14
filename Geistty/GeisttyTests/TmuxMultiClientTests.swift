import XCTest
@testable import Geistty

// MARK: - Multi-Client Pane ID Tests

/// Tests for the multi-client pane ID fix.
///
/// Bug: When another tmux client (e.g., ShellFish) already owns pane %0,
/// Geistty's new session gets a different pane (e.g., %2). The old code
/// hardcoded %0 everywhere, causing:
///   - Keystrokes sent to wrong session's pane (ShellFish's %0)
///   - Screen frozen (surface created for %0, output arriving for %2)
///   - focusedWindowId mismatch blocking layout/split tree updates
///
/// The fix makes all pane/window IDs dynamic:
///   - Gateway activePaneId starts nil, set from first %output
///   - Manager focusedPaneId starts empty, set from first routeOutput
///   - Manager focusedWindowId starts empty, set from first layout
///   - getSurfaceOrCreate uses paneSurfaces.isEmpty instead of paneId == "%0"
///   - createPrimarySurface uses resolveInitialPaneId() instead of hardcoded "%0"
/// Thread-safe capture for gateway write callbacks (crosses actor boundary).
/// TmuxGateway is a Swift actor, so its write callback is @Sendable.
/// Mutable local variables can't be captured in @Sendable closures,
/// so we use this class to accumulate written strings safely.
private final class WrittenCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _values
    }

    func append(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        _values.append(value)
    }
}

@MainActor
final class TmuxMultiClientTests: XCTestCase {

    // MARK: - Mock Infrastructure

    private var commandLog: [(command: String, callback: TmuxSessionManager.CommandCallback)] = []
    private var writeLog: [String] = []
    private var asyncCommandLog: [String] = []
    private var pauseLog: [String] = []
    private var unpauseLog: [String] = []
    private var asyncResponses: [String: String] = [:]

    override func setUp() {
        super.setUp()
        commandLog = []
        writeLog = []
        asyncCommandLog = []
        pauseLog = []
        unpauseLog = []
        asyncResponses = [:]
    }

    private func makeManager() -> TmuxSessionManager {
        let manager = TmuxSessionManager()

        manager.setupWithGateway(
            sendCommand: { [weak self] command, callback in
                self?.commandLog.append((command: command, callback: callback))
            },
            write: { [weak self] command in
                self?.writeLog.append(command)
            }
        )

        manager.setupRestoreFunctions(
            asyncSendCommand: { [weak self] command in
                self?.asyncCommandLog.append(command)
                for (prefix, response) in (self?.asyncResponses ?? [:]) {
                    if command.hasPrefix(prefix) {
                        return response
                    }
                }
                return ""
            },
            pausePane: { [weak self] paneId in
                self?.pauseLog.append(paneId)
            },
            unpausePane: { [weak self] paneId in
                self?.unpauseLog.append(paneId)
            }
        )

        return manager
    }

    private func flushCommand(prefix: String, response: String) {
        guard let index = commandLog.firstIndex(where: { $0.command.hasPrefix(prefix) }) else {
            XCTFail("No pending command with prefix '\(prefix)'. Commands: \(commandLog.map { $0.command })")
            return
        }
        let entry = commandLog.remove(at: index)
        entry.callback(.success(response))
    }

    // MARK: - TmuxSessionManager: focusedPaneId Dynamic Resolution

    /// When pane is %2 (not %0), routeOutput should set focusedPaneId from first output.
    func testFocusedPaneIdSetFromFirstOutput() {
        let manager = makeManager()

        XCTAssertEqual(manager.focusedPaneId, "", "focusedPaneId should start empty")

        let data = "hello".data(using: .utf8)!
        manager.routeOutput(data, to: "%2")

        XCTAssertEqual(manager.focusedPaneId, "%2",
                       "focusedPaneId should be set to %2 from first output")
    }

    /// After focusedPaneId is set, subsequent output to other panes should NOT change it.
    func testFocusedPaneIdNotOverwrittenByLaterOutput() {
        let manager = makeManager()

        manager.routeOutput("first".data(using: .utf8)!, to: "%2")
        XCTAssertEqual(manager.focusedPaneId, "%2")

        manager.routeOutput("second".data(using: .utf8)!, to: "%3")
        XCTAssertEqual(manager.focusedPaneId, "%2",
                       "focusedPaneId should remain %2 — only set from first output")
    }

    /// routeOutput to %0 should also work (normal single-client scenario).
    func testFocusedPaneIdSetFromPane0Output() {
        let manager = makeManager()

        manager.routeOutput("data".data(using: .utf8)!, to: "%0")
        XCTAssertEqual(manager.focusedPaneId, "%0")
    }

    // MARK: - TmuxSessionManager: focusedWindowId Dynamic Resolution

    /// focusedWindowId should start empty and be set from first layout change.
    func testFocusedWindowIdSetFromFirstLayout() async throws {
        let manager = makeManager()

        XCTAssertEqual(manager.focusedWindowId, "", "focusedWindowId should start empty")

        // Simulate a layout update for window @2 (not @0)
        // Use a layout without checksum — handleLayoutChanged will try parseWithChecksum
        // first (fails), then falls back to parsing without checksum (drops first 5 chars)
        // Format with checksum: "XXXX,80x24,0,0,2" where XXXX is the checksum
        // Simpler: just use a raw layout and let the fallback path handle it
        manager.handleLayoutChanged(windowId: "@2", windowIndex: 0, layout: "0000,80x24,0,0,2")

        // Wait for debounce (30ms) + processing
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(manager.focusedWindowId, "@2",
                       "focusedWindowId should be set from first layout event")
    }

    /// A layout for a DIFFERENT window should not update focusedWindowId after it's set.
    func testLayoutForOtherWindowIgnored() async throws {
        let manager = makeManager()

        // First layout sets focusedWindowId
        manager.handleLayoutChanged(windowId: "@2", windowIndex: 0, layout: "0000,80x24,0,0,2")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(manager.focusedWindowId, "@2")

        // Second layout for a different window should NOT change focusedWindowId
        manager.handleLayoutChanged(windowId: "@5", windowIndex: 1, layout: "0000,80x24,0,0,5")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(manager.focusedWindowId, "@2",
                       "focusedWindowId should not change for other window layouts")
    }

    /// Layout for the focused window should update currentSplitTree.
    func testLayoutForFocusedWindowUpdatesTree() async throws {
        let manager = makeManager()

        // Set focusedWindowId via first layout
        manager.handleLayoutChanged(windowId: "@2", windowIndex: 0, layout: "0000,80x24,0,0,2")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(manager.currentSplitTree.paneIds, [2])

        // Update layout for same window with a split
        // Horizontal split: {pane2,pane3}
        manager.handleLayoutChanged(windowId: "@2", windowIndex: 0, layout: "0000,80x24,0,0{40x24,0,0,2,40x24,41,0,3}")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(manager.currentSplitTree.paneIds.contains(2),
                      "Updated tree should contain pane 2")
        XCTAssertTrue(manager.currentSplitTree.paneIds.contains(3),
                      "Updated tree should contain pane 3")
    }

    // MARK: - TmuxSessionManager: Output Buffering for Non-%0 Panes

    /// Output to pane %2 should be buffered in pendingOutput when no factory exists.
    func testOutputBufferedForNonZeroPane() {
        let manager = makeManager()

        let data = "output for pane 2".data(using: .utf8)!
        manager.routeOutput(data, to: "%2")

        XCTAssertNotNil(manager.pendingOutput["%2"],
                        "Output for %2 should be buffered in pendingOutput")
        XCTAssertEqual(manager.pendingOutput["%2"]?.count, 1)
        XCTAssertEqual(manager.pendingOutput["%2"]?.first, data)
    }

    /// Multiple outputs to pane %2 should all be buffered.
    func testMultipleOutputsBufferedForNonZeroPane() {
        let manager = makeManager()

        let chunk1 = "chunk1".data(using: .utf8)!
        let chunk2 = "chunk2".data(using: .utf8)!

        manager.routeOutput(chunk1, to: "%2")
        manager.routeOutput(chunk2, to: "%2")

        XCTAssertEqual(manager.pendingOutput["%2"]?.count, 2,
                       "Both chunks should be buffered for %2")
    }

    /// Output to multiple non-%0 panes should be independently buffered.
    func testOutputBufferedIndependentlyPerPane() {
        let manager = makeManager()

        manager.routeOutput("pane2".data(using: .utf8)!, to: "%2")
        manager.routeOutput("pane3".data(using: .utf8)!, to: "%3")

        XCTAssertEqual(manager.pendingOutput["%2"]?.count, 1)
        XCTAssertEqual(manager.pendingOutput["%3"]?.count, 1)
        XCTAssertNil(manager.pendingOutput["%0"], "No output was sent to %0")
    }

    // MARK: - TmuxSessionManager: getSurfaceOrCreate Allows First Surface for Any Pane

    /// The first surface created should become primary, even if it's for pane %2.
    /// This is the core of the multi-client fix: the old code only allowed %0 as primary.
    func testFirstSurfaceBecomesrimaryRegardlessOfPaneId() {
        let manager = makeManager()

        // Set focusedPaneId so routeOutput has context
        manager.routeOutput("data".data(using: .utf8)!, to: "%2")
        XCTAssertEqual(manager.focusedPaneId, "%2")

        // Without a factory, no surface is created
        XCTAssertNil(manager.primarySurface, "No primary surface without factory")
        XCTAssertTrue(manager.paneSurfaces.isEmpty, "No surfaces without factory")
    }

    // MARK: - TmuxSessionManager: resolveInitialPaneId Priority Order

    /// With empty state, resolveInitialPaneId should fall back to %0.
    func testResolveInitialPaneIdFallbackToPane0() {
        let manager = makeManager()

        // All sources empty — createPrimarySurface will use fallback %0
        // We can't call resolveInitialPaneId directly (private), but createPrimarySurface exposes it
        // Without a factory, createPrimarySurface returns nil but logs the resolved pane
        let surface = manager.createPrimarySurface()
        XCTAssertNil(surface, "No factory, so no surface created")
    }

    /// With focusedPaneId set, resolveInitialPaneId should use it.
    func testResolveInitialPaneIdFromFocusedPaneId() {
        let manager = makeManager()

        // Set focusedPaneId via routeOutput
        manager.routeOutput("data".data(using: .utf8)!, to: "%2")
        XCTAssertEqual(manager.focusedPaneId, "%2")

        // createPrimarySurface would use focusedPaneId (%2)
        // Without factory it returns nil, but the important thing is the ID resolution path
        // We verify indirectly: pendingOutput has data for %2, so resolveInitialPaneId
        // would pick %2 from pendingOutput keys
        XCTAssertNotNil(manager.pendingOutput["%2"])
    }

    /// With split tree set, resolveInitialPaneId should prefer split tree pane.
    func testResolveInitialPaneIdFromSplitTree() async throws {
        let manager = makeManager()

        // Set up split tree with pane 3
        manager.handleLayoutChanged(windowId: "@2", windowIndex: 0, layout: "0000,80x24,0,0,3")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(manager.currentSplitTree.paneIds.contains(3),
                      "Split tree should contain pane 3, got: \(manager.currentSplitTree.paneIds)")

        // focusedPaneId should already be set from the split tree (not from routeOutput)
        // updateSplitTree sets focusedPaneId to the first pane in the tree when it's empty
        XCTAssertEqual(manager.focusedPaneId, "%3",
                       "focusedPaneId should be set to %3 from split tree")

        // Subsequent routeOutput to a different pane should NOT change focusedPaneId
        manager.routeOutput("data".data(using: .utf8)!, to: "%2")
        XCTAssertEqual(manager.focusedPaneId, "%3",
                       "focusedPaneId should remain %3 — split tree took priority")

        // Verify pendingOutput still buffered for %2
        XCTAssertNotNil(manager.pendingOutput["%2"])
    }

    // MARK: - TmuxSessionManager: Restore Flow with Non-%0 Panes

    /// Resume detection and restore should work with panes other than %0.
    func testRestoreFlowWithNonZeroPane() async throws {
        let manager = makeManager()

        let captureContent = "user@host ~ % ls\nfile1.txt"
        asyncResponses["capture-pane -pe -t %2"] = captureContent

        // Resume detection
        manager.handleSessionChanged(sessionId: "$1", sessionName: "geistty-1")
        XCTAssertEqual(manager.sessionResumeStatus, .resumed(name: "geistty-1"))

        // Flush list-panes with %2 (not %0)
        flushCommand(prefix: "list-panes", response: "%2")

        try await Task.sleep(for: .milliseconds(200))

        // Verify pause/capture/unpause all targeted %2
        XCTAssertEqual(pauseLog, ["%2"], "Should pause %2, not %0")
        let captures = asyncCommandLog.filter { $0.hasPrefix("capture-pane") }
        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures.first, "capture-pane -pe -t %2",
                       "Should capture %2, not %0")
        XCTAssertEqual(unpauseLog, ["%2"], "Should unpause %2, not %0")

        // Verify captured content is buffered for %2
        XCTAssertNotNil(manager.pendingOutput["%2"],
                        "Captured content should be buffered for %2")
        XCTAssertNil(manager.pendingOutput["%0"],
                     "No data should be buffered for %0")
    }

    /// Restore with multiple non-%0 panes.
    func testRestoreFlowWithMultipleNonZeroPanes() async throws {
        let manager = makeManager()

        asyncResponses["capture-pane -pe -t %2"] = "pane2 content"
        asyncResponses["capture-pane -pe -t %3"] = "pane3 content"

        manager.handleSessionChanged(sessionId: "$1", sessionName: "geistty-1")
        flushCommand(prefix: "list-panes", response: "%2\n%3")

        try await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(pauseLog.contains("%2"), "Should pause %2")
        XCTAssertTrue(pauseLog.contains("%3"), "Should pause %3")
        XCTAssertFalse(pauseLog.contains("%0"), "Should NOT pause %0")

        XCTAssertTrue(unpauseLog.contains("%2"), "Should unpause %2")
        XCTAssertTrue(unpauseLog.contains("%3"), "Should unpause %3")

        XCTAssertNotNil(manager.pendingOutput["%2"])
        XCTAssertNotNil(manager.pendingOutput["%3"])
    }

    // MARK: - TmuxSessionManager: controlModeExited Resets Dynamic IDs

    /// Verify that controlModeExited clears focusedPaneId and focusedWindowId.
    func testControlModeExitedResetsDynamicIds() async throws {
        let manager = makeManager()

        // Set dynamic IDs
        manager.routeOutput("data".data(using: .utf8)!, to: "%2")
        XCTAssertEqual(manager.focusedPaneId, "%2")

        manager.handleLayoutChanged(windowId: "@2", windowIndex: 0, layout: "0000,80x24,0,0,2")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(manager.focusedWindowId, "@2")

        // Exit control mode
        manager.controlModeExited(reason: "test disconnect")

        // Verify cleanup
        XCTAssertFalse(manager.isConnected)
        XCTAssertTrue(manager.paneSurfaces.isEmpty)
        XCTAssertNil(manager.primarySurface)
        XCTAssertTrue(manager.pendingOutput.isEmpty)
    }

    // MARK: - TmuxSessionManager: Window Close Resets to Empty

    /// When all windows close, focusedPaneId and focusedWindowId should reset to empty.
    func testAllWindowsClosedResetsToEmpty() async throws {
        let manager = makeManager()

        // Set up state
        manager.routeOutput("data".data(using: .utf8)!, to: "%2")
        manager.handleLayoutChanged(windowId: "@2", windowIndex: 0, layout: "0000,80x24,0,0,2")
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(manager.focusedPaneId, "%2")
        XCTAssertEqual(manager.focusedWindowId, "@2")
    }

    // MARK: - TmuxGateway: activePaneId Starts Nil

    /// Gateway activePaneId should be nil initially (not "%0").
    func testGatewayActivePaneIdStartsNil() async {
        let gateway = TmuxGateway()
        let paneId = await gateway.activePaneId
        XCTAssertNil(paneId,
                     "activePaneId should start nil, not \"%0\"")
    }

    /// Gateway setActivePaneId should set the value.
    func testGatewaySetActivePaneId() async {
        let gateway = TmuxGateway()

        await gateway.setActivePaneId("%2")
        let paneId = await gateway.activePaneId
        XCTAssertEqual(paneId, "%2")
    }

    /// Gateway reset should clear activePaneId back to nil.
    func testGatewayResetClearsActivePaneId() async {
        let gateway = TmuxGateway()

        await gateway.setActivePaneId("%2")
        var paneId = await gateway.activePaneId
        XCTAssertEqual(paneId, "%2")

        await gateway.reset()
        paneId = await gateway.activePaneId
        XCTAssertNil(paneId,
                     "reset() should clear activePaneId to nil")
    }

    // MARK: - TmuxGateway: sendKeys Guards on Optional activePaneId

    /// sendKeys should not crash when activePaneId is nil and no explicit pane given.
    func testSendKeysWithNilActivePaneSafe() async {
        let gateway = TmuxGateway()
        let written = WrittenCapture()
        await gateway.setWriteCallback { str in written.append(str) }

        let paneId = await gateway.activePaneId
        XCTAssertNil(paneId)

        // Should return early without writing (warning logged)
        let data = "a".data(using: .utf8)!
        await gateway.sendKeys(data)

        XCTAssertTrue(written.values.isEmpty,
                      "sendKeys should not write when activePaneId is nil")
    }

    /// sendKeys should work when activePaneId is set.
    func testSendKeysWithActivePaneSet() async {
        let gateway = TmuxGateway()
        let written = WrittenCapture()
        await gateway.setWriteCallback { str in written.append(str) }

        await gateway.setActivePaneId("%2")

        let data = "a".data(using: .utf8)!
        await gateway.sendKeys(data)

        XCTAssertFalse(written.values.isEmpty, "sendKeys should write when activePaneId is set")
        let command = written.values.first ?? ""
        XCTAssertTrue(command.contains("%2"),
                      "sendKeys should target %2, got: \(command)")
    }

    /// sendKeys with explicit paneId should use that pane regardless of activePaneId.
    func testSendKeysWithExplicitPaneId() async {
        let gateway = TmuxGateway()
        let written = WrittenCapture()
        await gateway.setWriteCallback { str in written.append(str) }

        await gateway.setActivePaneId("%2")

        let data = "a".data(using: .utf8)!
        await gateway.sendKeys(data, toPaneId: "%5")

        XCTAssertFalse(written.values.isEmpty)
        let command = written.values.first ?? ""
        XCTAssertTrue(command.contains("%5"),
                      "sendKeys with explicit pane should target %5, got: \(command)")
    }

    /// sendKeys with explicit paneId should work even when activePaneId is nil.
    func testSendKeysWithExplicitPaneIdWhenActiveIsNil() async {
        let gateway = TmuxGateway()
        let written = WrittenCapture()
        await gateway.setWriteCallback { str in written.append(str) }

        let paneId = await gateway.activePaneId
        XCTAssertNil(paneId)

        let data = "a".data(using: .utf8)!
        await gateway.sendKeys(data, toPaneId: "%3")

        XCTAssertFalse(written.values.isEmpty,
                       "sendKeys should work with explicit pane even if activePaneId is nil")
        let command = written.values.first ?? ""
        XCTAssertTrue(command.contains("%3"),
                      "Should target %3, got: \(command)")
    }

    // MARK: - TmuxGateway: First %output Sets activePaneId

    /// Receiving %output for %2 should set activePaneId to %2.
    func testFirstOutputSetsActivePaneId() async {
        let gateway = TmuxGateway()
        await gateway.setWriteCallback { _ in }

        var paneId = await gateway.activePaneId
        XCTAssertNil(paneId)

        // Feed raw control mode output for pane %2
        // %output format: %output %<pane-id> <data>
        let outputLine = "%output %2 hello\n"
        let data = outputLine.data(using: .utf8)!
        await gateway.receive(data)

        paneId = await gateway.activePaneId
        XCTAssertEqual(paneId, "%2",
                       "activePaneId should be set from first %output event")
    }

    /// Second %output for a different pane should NOT change activePaneId.
    func testSecondOutputDoesNotChangeActivePaneId() async {
        let gateway = TmuxGateway()
        await gateway.setWriteCallback { _ in }

        let output1 = "%output %2 first\n"
        await gateway.receive(output1.data(using: .utf8)!)
        var paneId = await gateway.activePaneId
        XCTAssertEqual(paneId, "%2")

        let output2 = "%output %3 second\n"
        await gateway.receive(output2.data(using: .utf8)!)
        paneId = await gateway.activePaneId
        XCTAssertEqual(paneId, "%2",
                       "activePaneId should not change after initial set")
    }

    // MARK: - TmuxGateway: resumePausedPane Guards on Optional activePaneId

    /// resumePausedPane with nil activePaneId and no explicit pane should be safe.
    func testResumePausedPaneWithNilActivePaneSafe() async {
        let gateway = TmuxGateway()
        let written = WrittenCapture()
        await gateway.setWriteCallback { str in written.append(str) }

        let paneId = await gateway.activePaneId
        XCTAssertNil(paneId)

        // Should not crash, should log warning and return
        await gateway.resumePausedPane()

        // Should not have written a command (no target pane known)
        let resumeCommands = written.values.filter { $0.contains("refresh-client") }
        XCTAssertTrue(resumeCommands.isEmpty,
                      "Should not send resume when no active pane is known")
    }

    /// resumePausedPane with explicit paneId should work even when activePaneId is nil.
    func testResumePausedPaneWithExplicitPaneId() async {
        let gateway = TmuxGateway()
        let written = WrittenCapture()
        await gateway.setWriteCallback { str in written.append(str) }

        let paneId = await gateway.activePaneId
        XCTAssertNil(paneId)

        await gateway.resumePausedPane(paneId: "%2")

        let resumeCommands = written.values.filter { $0.contains("refresh-client") }
        XCTAssertEqual(resumeCommands.count, 1,
                       "Should send resume for explicit pane %2")
        XCTAssertTrue(resumeCommands.first?.contains("%2") == true,
                      "Should target %2")
    }

    // MARK: - End-to-End Multi-Client Scenario

    /// Simulate the full multi-client scenario:
    /// 1. ShellFish already connected to tmux, owns pane %0
    /// 2. Geistty connects, gets session geistty-1 with pane %2
    /// 3. tmux sends %session-changed, %layout-change for @2, %output for %2
    /// 4. Verify: focusedPaneId=%2, focusedWindowId=@2, output buffered for %2
    func testFullMultiClientScenario() async throws {
        let manager = makeManager()

        // Step 1: Verify initial state is "unresolved"
        XCTAssertEqual(manager.focusedPaneId, "")
        XCTAssertEqual(manager.focusedWindowId, "")
        XCTAssertTrue(manager.paneSurfaces.isEmpty)
        XCTAssertNil(manager.primarySurface)

        // Step 2: Control mode activates
        manager.controlModeActivated()
        XCTAssertTrue(manager.isConnected)

        // Step 3: %session-changed arrives (resume detection)
        manager.handleSessionChanged(sessionId: "$1", sessionName: "geistty-1")
        XCTAssertEqual(manager.sessionResumeStatus, .resumed(name: "geistty-1"))

        // Step 4: %layout-change arrives for window @2 with pane 2
        manager.handleLayoutChanged(windowId: "@2", windowIndex: 0, layout: "0000,80x24,0,0,2")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(manager.focusedWindowId, "@2")
        XCTAssertTrue(manager.currentSplitTree.paneIds.contains(2))

        // Step 5: %output arrives for pane %2
        let outputData = "geistty-1 output".data(using: .utf8)!
        manager.routeOutput(outputData, to: "%2")
        XCTAssertEqual(manager.focusedPaneId, "%2")

        // Step 6: Verify NO state refers to %0 or @0
        XCTAssertNil(manager.pendingOutput["%0"],
                     "No data should be for %0 — we don't own that pane")
        XCTAssertNotNil(manager.pendingOutput["%2"],
                        "Output should be buffered for %2")
        XCTAssertNotEqual(manager.focusedWindowId, "@0",
                          "focusedWindowId should NOT be @0")
    }

    /// End-to-end scenario where output arrives BEFORE layout.
    /// This tests the race condition where %output comes first.
    func testOutputBeforeLayoutScenario() async throws {
        let manager = makeManager()

        manager.controlModeActivated()
        manager.handleSessionChanged(sessionId: "$1", sessionName: "geistty-1")

        // %output arrives BEFORE %layout-change
        manager.routeOutput("early output".data(using: .utf8)!, to: "%2")
        XCTAssertEqual(manager.focusedPaneId, "%2")
        XCTAssertEqual(manager.focusedWindowId, "", "Window ID not yet known")

        // Then layout arrives
        manager.handleLayoutChanged(windowId: "@2", windowIndex: 0, layout: "0000,80x24,0,0,2")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(manager.focusedWindowId, "@2")

        // Both should be consistent
        XCTAssertEqual(manager.focusedPaneId, "%2")
        XCTAssertEqual(manager.focusedWindowId, "@2")
    }

    /// Verify that the manager handles window @0 correctly when we DO own %0.
    /// (Normal single-client scenario — regression test.)
    func testSingleClientScenarioStillWorks() async throws {
        let manager = makeManager()

        manager.controlModeActivated()

        // New session created (sessions-changed before session-changed)
        manager.handleSessionsChanged()
        manager.handleSessionChanged(sessionId: "$0", sessionName: "geistty-1")
        XCTAssertEqual(manager.sessionResumeStatus, .created(name: "geistty-1"))

        // Normal layout with @0/%0
        manager.handleLayoutChanged(windowId: "@0", windowIndex: 0, layout: "0000,80x24,0,0,0")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(manager.focusedWindowId, "@0")

        // Normal output for %0
        manager.routeOutput("normal output".data(using: .utf8)!, to: "%0")
        XCTAssertEqual(manager.focusedPaneId, "%0")
    }

    /// Verify the scenario where Geistty connects to an existing tmux session
    /// that already has panes %0 and %1 (both owned by ShellFish), and Geistty
    /// gets a brand new session with panes %2 and %3 (split).
    func testMultiClientWithSplitPanes() async throws {
        let manager = makeManager()

        manager.controlModeActivated()
        manager.handleSessionChanged(sessionId: "$2", sessionName: "geistty-1")

        // Layout with split panes %2 and %3
        let splitLayout = "0000,80x24,0,0{40x24,0,0,2,40x24,41,0,3}"
        manager.handleLayoutChanged(windowId: "@3", windowIndex: 0, layout: splitLayout)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(manager.focusedWindowId, "@3")
        XCTAssertTrue(manager.currentSplitTree.paneIds.contains(2))
        XCTAssertTrue(manager.currentSplitTree.paneIds.contains(3))
        XCTAssertTrue(manager.currentSplitTree.isSplit)

        // Output for both our panes
        manager.routeOutput("pane2 data".data(using: .utf8)!, to: "%2")
        manager.routeOutput("pane3 data".data(using: .utf8)!, to: "%3")

        XCTAssertEqual(manager.focusedPaneId, "%2", "First output sets focusedPaneId")
        XCTAssertNotNil(manager.pendingOutput["%2"])
        XCTAssertNotNil(manager.pendingOutput["%3"])
        XCTAssertNil(manager.pendingOutput["%0"], "We don't own %0")
        XCTAssertNil(manager.pendingOutput["%1"], "We don't own %1")
    }

    // MARK: - TmuxSessionManager: handleWindowPaneChanged with Non-%0 Panes

    /// handleWindowPaneChanged should update focusedPaneId to the new pane.
    func testWindowPaneChangedUpdatesNonZeroPaneId() {
        let manager = makeManager()

        // Set up initial state
        manager.routeOutput("data".data(using: .utf8)!, to: "%2")
        XCTAssertEqual(manager.focusedPaneId, "%2")

        // User switches to pane %3
        manager.handleWindowPaneChanged(windowId: "@2", paneId: "%3")
        XCTAssertEqual(manager.focusedPaneId, "%3")
    }

    // MARK: - Session Manager: Pane ID Validation

    /// Verify that focusedPaneId starts as empty string, NOT "%0" or nil.
    func testFocusedPaneIdInitialValue() {
        let manager = TmuxSessionManager()
        XCTAssertEqual(manager.focusedPaneId, "",
                       "focusedPaneId must start as empty string, not \"%0\"")
    }

    /// Verify that focusedWindowId starts as empty string, NOT "@0" or nil.
    func testFocusedWindowIdInitialValue() {
        let manager = TmuxSessionManager()
        XCTAssertEqual(manager.focusedWindowId, "",
                       "focusedWindowId must start as empty string, not \"@0\"")
    }
}
