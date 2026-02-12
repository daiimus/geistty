import XCTest
@testable import Geistty

// MARK: - TmuxSessionManager Restore Tests

/// Tests for the capture-pane session restore flow.
///
/// When attaching to an existing tmux session via control mode, tmux sends
/// ZERO %output for existing visible content. Only new output (produced after
/// attach) arrives via %output. The restore flow must:
///   1. Detect resume (no %sessions-changed before %session-changed)
///   2. list-panes to find current panes
///   3. Pause each pane (freeze %output delivery)
///   4. capture-pane -pe for each pane (visible screen with ANSI)
///   5. Feed captured content to Ghostty surface
///   6. Unpause each pane (resume live output)
@MainActor
final class TmuxSessionRestoreTests: XCTestCase {

    // MARK: - Mock Tracking

    /// Tracks all commands sent through the sendCommand callback bridge
    private var commandLog: [(command: String, callback: TmuxSessionManager.CommandCallback)] = []
    
    /// Tracks all fire-and-forget writes to SSH
    private var writeLog: [String] = []
    
    /// Tracks calls to the async send command function (for capture-pane)
    private var asyncCommandLog: [String] = []
    
    /// Tracks pause/unpause calls
    private var pauseLog: [String] = []
    private var unpauseLog: [String] = []
    
    /// Mock responses for async commands (keyed by command prefix)
    private var asyncResponses: [String: String] = [:]
    
    /// Data fed to mock surfaces
    private var surfaceFedData: [String: [Data]] = [:]
    
    /// Mock surfaces created by factory
    private var createdSurfaces: [String] = []

    // MARK: - Setup

    private func makeManager() -> TmuxSessionManager {
        let manager = TmuxSessionManager()
        
        // Wire up the callback-based sendCommand (used by refreshState, list-panes, etc.)
        manager.setupWithGateway(
            sendCommand: { [weak self] command, callback in
                self?.commandLog.append((command: command, callback: callback))
            },
            write: { [weak self] command in
                self?.writeLog.append(command)
            }
        )
        
        // Wire up the async restore functions
        manager.setupRestoreFunctions(
            asyncSendCommand: { [weak self] command in
                self?.asyncCommandLog.append(command)
                // Look up mock response by command prefix
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
    
    /// Flush a specific pending command by matching its prefix and supplying a response
    private func flushCommand(prefix: String, response: String) {
        guard let index = commandLog.firstIndex(where: { $0.command.hasPrefix(prefix) }) else {
            XCTFail("No pending command with prefix '\(prefix)'. Commands: \(commandLog.map { $0.command })")
            return
        }
        let entry = commandLog.remove(at: index)
        entry.callback(.success(response))
    }
    
    /// Flush a specific pending command with an error
    private func flushCommandError(prefix: String, error: Error) {
        guard let index = commandLog.firstIndex(where: { $0.command.hasPrefix(prefix) }) else {
            XCTFail("No pending command with prefix '\(prefix)'. Commands: \(commandLog.map { $0.command })")
            return
        }
        let entry = commandLog.remove(at: index)
        entry.callback(.failure(error))
    }

    override func setUp() {
        super.setUp()
        commandLog = []
        writeLog = []
        asyncCommandLog = []
        pauseLog = []
        unpauseLog = []
        asyncResponses = [:]
        surfaceFedData = [:]
        createdSurfaces = []
    }

    // MARK: - Resume Detection Tests

    /// Verify that attaching to an existing session (no %sessions-changed first)
    /// is detected as `.resumed`.
    func testResumeDetectedWhenNoSessionsChanged() {
        let manager = makeManager()
        
        // Simulate: %session-changed WITHOUT prior %sessions-changed
        manager.handleSessionChanged(sessionId: "$0", sessionName: "main")
        
        guard case .resumed(let name) = manager.sessionResumeStatus else {
            XCTFail("Expected .resumed, got \(String(describing: manager.sessionResumeStatus))")
            return
        }
        XCTAssertEqual(name, "main")
    }
    
    /// Verify that creating a new session (%sessions-changed before %session-changed)
    /// is detected as `.created`.
    func testCreatedDetectedWhenSessionsChangedFirst() {
        let manager = makeManager()
        
        // Simulate: %sessions-changed THEN %session-changed
        manager.handleSessionsChanged()
        manager.handleSessionChanged(sessionId: "$0", sessionName: "main")
        
        guard case .created(let name) = manager.sessionResumeStatus else {
            XCTFail("Expected .created, got \(String(describing: manager.sessionResumeStatus))")
            return
        }
        XCTAssertEqual(name, "main")
    }
    
    /// Verify that sawSessionsChanged resets after each handleSessionChanged call.
    func testSawSessionsChangedResets() {
        let manager = makeManager()
        
        // First: new session
        manager.handleSessionsChanged()
        manager.handleSessionChanged(sessionId: "$0", sessionName: "test")
        XCTAssertEqual(manager.sessionResumeStatus, .created(name: "test"))
        
        // Second: resume (no %sessions-changed before this one)
        manager.handleSessionChanged(sessionId: "$0", sessionName: "test")
        XCTAssertEqual(manager.sessionResumeStatus, .resumed(name: "test"))
    }

    // MARK: - Restore Flow Tests

    /// Verify that handleSessionChanged triggers restoreVisibleContent when resumed.
    /// This checks that list-panes is sent as the first step of restore.
    func testResumeTriggersListPanes() {
        let manager = makeManager()
        
        // Simulate resume
        manager.handleSessionChanged(sessionId: "$0", sessionName: "main")
        
        // restoreVisibleContent() should have called sendCommand("list-panes ...")
        let listPanesCommands = commandLog.filter { $0.command.hasPrefix("list-panes") }
        XCTAssertFalse(listPanesCommands.isEmpty,
                       "Expected list-panes command after resume. Commands: \(commandLog.map { $0.command })")
    }
    
    /// Verify that handleSessionChanged does NOT trigger restore when session was created.
    func testCreatedDoesNotTriggerRestore() {
        let manager = makeManager()
        
        manager.handleSessionsChanged()
        manager.handleSessionChanged(sessionId: "$0", sessionName: "main")
        
        // No list-panes should be sent for restore (only refreshState commands)
        // refreshState() sends list-panes for state queries via queryWindows callback chain,
        // but restoreVisibleContent() sends "list-panes -F '#{pane_id}'" specifically
        let restoreListPanes = commandLog.filter { $0.command.contains("#{pane_id}") }
        XCTAssertTrue(restoreListPanes.isEmpty,
                      "Should NOT trigger restore list-panes for new session. Commands: \(commandLog.map { $0.command })")
    }

    /// Verify that restore functions guard fires if functions not configured.
    func testRestoreGuardWithoutFunctions() {
        // Create manager WITHOUT setting up restore functions
        let manager = TmuxSessionManager()
        manager.setupWithGateway(
            sendCommand: { [weak self] command, callback in
                self?.commandLog.append((command: command, callback: callback))
            },
            write: { _ in }
        )
        
        // Simulate resume — should not crash, should log warning
        manager.handleSessionChanged(sessionId: "$0", sessionName: "main")
        
        // No list-panes for restore (guard failed)
        let restoreListPanes = commandLog.filter { $0.command.contains("#{pane_id}") }
        XCTAssertTrue(restoreListPanes.isEmpty,
                      "Should not attempt restore without async functions configured")
    }

    /// Full end-to-end restore flow: resume → list-panes → pause → capture → feed → unpause.
    func testFullRestoreFlow() async throws {
        let manager = makeManager()
        
        // Set up mock capture-pane response
        let captureContent = "daiimus@dionysus ~ % ls\nfile1.txt  file2.txt\ndaiimus@dionysus ~ %"
        asyncResponses["capture-pane"] = captureContent
        
        // Step 1: Simulate resume detection
        manager.handleSessionChanged(sessionId: "$0", sessionName: "main")
        XCTAssertEqual(manager.sessionResumeStatus, .resumed(name: "main"))
        
        // Step 2: Flush the list-panes command with mock response
        flushCommand(prefix: "list-panes", response: "%0")
        
        // Allow the async Task to run (performRestore is launched in a Task)
        try await Task.sleep(for: .milliseconds(200))
        
        // Step 3: Verify pause was called
        XCTAssertEqual(pauseLog, ["%0"], "Expected pane %0 to be paused. Pause log: \(pauseLog)")
        
        // Step 4: Verify capture-pane was called
        let captureCommands = asyncCommandLog.filter { $0.hasPrefix("capture-pane") }
        XCTAssertEqual(captureCommands.count, 1, "Expected exactly one capture-pane command")
        XCTAssertEqual(captureCommands.first, "capture-pane -pe -t %0")
        
        // Step 5: Verify unpause was called
        XCTAssertEqual(unpauseLog, ["%0"], "Expected pane %0 to be unpaused. Unpause log: \(unpauseLog)")
    }
    
    /// Test restore with multiple panes.
    func testMultiPaneRestore() async throws {
        let manager = makeManager()
        
        asyncResponses["capture-pane -pe -t %0"] = "pane0 content"
        asyncResponses["capture-pane -pe -t %1"] = "pane1 content"
        
        manager.handleSessionChanged(sessionId: "$0", sessionName: "main")
        flushCommand(prefix: "list-panes", response: "%0\n%1")
        
        try await Task.sleep(for: .milliseconds(200))
        
        // Both panes should be paused
        XCTAssertTrue(pauseLog.contains("%0"), "Pane %0 should be paused")
        XCTAssertTrue(pauseLog.contains("%1"), "Pane %1 should be paused")
        
        // Both panes should be captured
        let captureCommands = asyncCommandLog.filter { $0.hasPrefix("capture-pane") }
        XCTAssertEqual(captureCommands.count, 2)
        
        // Both panes should be unpaused
        XCTAssertTrue(unpauseLog.contains("%0"), "Pane %0 should be unpaused")
        XCTAssertTrue(unpauseLog.contains("%1"), "Pane %1 should be unpaused")
    }

    /// Test that restore handles empty list-panes response gracefully.
    func testRestoreWithNoPanes() async throws {
        let manager = makeManager()
        
        manager.handleSessionChanged(sessionId: "$0", sessionName: "main")
        flushCommand(prefix: "list-panes", response: "")
        
        try await Task.sleep(for: .milliseconds(200))
        
        XCTAssertTrue(pauseLog.isEmpty, "No panes to pause")
        XCTAssertTrue(asyncCommandLog.isEmpty, "No capture commands")
        XCTAssertTrue(unpauseLog.isEmpty, "No panes to unpause")
    }

    /// Test that restore handles list-panes failure gracefully.
    func testRestoreHandlesListPanesFailure() async throws {
        let manager = makeManager()
        
        manager.handleSessionChanged(sessionId: "$0", sessionName: "main")
        
        // Fail the list-panes command
        flushCommandError(prefix: "list-panes", error: NSError(domain: "test", code: -1))
        
        try await Task.sleep(for: .milliseconds(200))
        
        // Should not crash, no restore attempted
        XCTAssertTrue(pauseLog.isEmpty)
        XCTAssertTrue(asyncCommandLog.isEmpty)
        XCTAssertTrue(unpauseLog.isEmpty)
    }

    /// Test that restore handles capture-pane failure gracefully.
    func testRestoreHandlesCapturePaneFailure() async throws {
        // Create a separate manager with a throwing asyncSendCommand
        let failManager = TmuxSessionManager()
        failManager.setupWithGateway(
            sendCommand: { [weak self] command, callback in
                self?.commandLog.append((command: command, callback: callback))
            },
            write: { _ in }
        )
        failManager.setupRestoreFunctions(
            asyncSendCommand: { command in
                throw NSError(domain: "test", code: -1, userInfo: [NSLocalizedDescriptionKey: "capture failed"])
            },
            pausePane: { [weak self] paneId in
                self?.pauseLog.append(paneId)
            },
            unpausePane: { [weak self] paneId in
                self?.unpauseLog.append(paneId)
            }
        )
        
        failManager.handleSessionChanged(sessionId: "$0", sessionName: "main")
        
        // Flush list-panes
        guard let index = commandLog.firstIndex(where: { $0.command.hasPrefix("list-panes") && $0.command.contains("pane_id") }) else {
            XCTFail("No list-panes command found")
            return
        }
        let entry = commandLog.remove(at: index)
        entry.callback(.success("%0"))
        
        try await Task.sleep(for: .milliseconds(200))
        
        // Pause should still have been called
        XCTAssertEqual(pauseLog, ["%0"])
        // Unpause should still be called even if capture failed
        XCTAssertEqual(unpauseLog, ["%0"])
    }

    /// Test that pause failure doesn't prevent capture and unpause.
    func testPauseFailureDoesNotBlockRestore() async throws {
        let manager = TmuxSessionManager()
        manager.setupWithGateway(
            sendCommand: { [weak self] command, callback in
                self?.commandLog.append((command: command, callback: callback))
            },
            write: { _ in }
        )
        
        var capturedPanes: [String] = []
        manager.setupRestoreFunctions(
            asyncSendCommand: { command in
                capturedPanes.append(command)
                return "some content"
            },
            pausePane: { _ in
                throw NSError(domain: "test", code: -1, userInfo: [NSLocalizedDescriptionKey: "pause failed"])
            },
            unpausePane: { [weak self] paneId in
                self?.unpauseLog.append(paneId)
            }
        )
        
        manager.handleSessionChanged(sessionId: "$0", sessionName: "main")
        
        // Flush list-panes
        guard let index = commandLog.firstIndex(where: { $0.command.contains("pane_id") }) else {
            XCTFail("No list-panes command")
            return
        }
        commandLog[index].callback(.success("%0"))
        commandLog.remove(at: index)
        
        try await Task.sleep(for: .milliseconds(200))
        
        // Capture should still happen even if pause failed
        let captures = capturedPanes.filter { $0.hasPrefix("capture-pane") }
        XCTAssertEqual(captures.count, 1, "Capture should proceed even if pause fails")
        
        // Unpause should still be called
        XCTAssertEqual(unpauseLog, ["%0"])
    }

    // MARK: - Content Conversion Tests
    
    /// Test that \n → \r\n conversion happens correctly.
    /// This is critical because terminal emulators interpret \n as cursor-down-only,
    /// not cursor-down-and-carriage-return. We need \r\n.
    func testNewlineConversion() {
        let input = "line1\nline2\nline3"
        let expected = "line1\r\nline2\r\nline3"
        let result = input.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(result, expected)
    }
    
    /// Test that capture-pane content with ANSI escapes survives conversion.
    func testAnsiEscapesSurviveConversion() {
        // Simulated capture-pane -pe output with ANSI color codes
        let input = "\u{1b}[1m\u{1b}[7m%\u{1b}[27m\u{1b}[1m\u{1b}[0m\nuser@host ~ %"
        let result = input.replacingOccurrences(of: "\n", with: "\r\n")
        // ANSI escapes should be preserved
        XCTAssertTrue(result.contains("\u{1b}[1m"))
        XCTAssertTrue(result.contains("\r\n"))
        XCTAssertFalse(result.contains("\r\r\n"))
    }

    // MARK: - Ordering Tests
    
    /// Verify the command ordering: list-panes is queued after refreshState commands.
    /// refreshState (from controlModeActivated) sends list-sessions and list-windows.
    /// restoreVisibleContent (from handleSessionChanged) sends list-panes.
    /// These must not interfere with each other.
    func testCommandOrderingOnResume() {
        let manager = makeManager()
        
        // Simulate the full activation + resume sequence
        manager.controlModeActivated()  // triggers refreshState()
        manager.handleSessionChanged(sessionId: "$0", sessionName: "main")  // triggers restore
        
        // Collect all commands that were sent
        let commands = commandLog.map { $0.command }
        
        // refreshState sends list-sessions and list-windows
        let hasListSessions = commands.contains { $0.hasPrefix("list-sessions") }
        let hasListWindows = commands.contains { $0.hasPrefix("list-windows") }
        
        // restoreVisibleContent sends list-panes with #{pane_id}
        let hasRestoreListPanes = commands.contains { $0.contains("#{pane_id}") }
        
        XCTAssertTrue(hasListSessions, "refreshState should send list-sessions")
        XCTAssertTrue(hasListWindows, "refreshState should send list-windows")
        XCTAssertTrue(hasRestoreListPanes, "restoreVisibleContent should send list-panes")
    }

    /// Verify that handleSessionChanged also calls queryWindows (for normal state tracking).
    func testHandleSessionChangedQueriesWindows() {
        let manager = makeManager()
        
        manager.handleSessionChanged(sessionId: "$0", sessionName: "main")
        
        let windowCommands = commandLog.filter { $0.command.hasPrefix("list-windows") }
        XCTAssertFalse(windowCommands.isEmpty, 
                       "handleSessionChanged should query windows. Commands: \(commandLog.map { $0.command })")
    }
    
    // MARK: - Surface Integration Tests
    
    /// Test that captured content goes to pendingOutput when surface doesn't exist.
    /// When the surface IS created later (via layout pipeline), pendingOutput is flushed.
    func testCaptureBufferedWhenNoSurface() async throws {
        let manager = makeManager()
        
        // Don't configure surface factory — surfaces won't be created
        asyncResponses["capture-pane"] = "buffered content here"
        
        manager.handleSessionChanged(sessionId: "$0", sessionName: "main")
        flushCommand(prefix: "list-panes", response: "%0")
        
        try await Task.sleep(for: .milliseconds(200))
        
        // Capture should still complete (content goes to pendingOutput internally)
        let captures = asyncCommandLog.filter { $0.hasPrefix("capture-pane") }
        XCTAssertEqual(captures.count, 1, "Capture should still be attempted")
        
        // Pause and unpause should have been called regardless
        XCTAssertEqual(pauseLog, ["%0"])
        XCTAssertEqual(unpauseLog, ["%0"])
    }

    /// Verify that pendingOutput actually accumulates capture data when no factory is set.
    /// This is the critical path: if restore runs before the UI configures the surface factory,
    /// the captured screen content must be buffered in pendingOutput.
    func testPendingOutputAccumulatesCaptureData() async throws {
        let manager = makeManager()
        
        let captureContent = "user@host ~ % ls\nfile1.txt  file2.txt"
        asyncResponses["capture-pane"] = captureContent
        
        // NO factory configured — getSurfaceOrCreate will return nil
        
        manager.handleSessionChanged(sessionId: "$0", sessionName: "main")
        flushCommand(prefix: "list-panes", response: "%0")
        
        try await Task.sleep(for: .milliseconds(200))
        
        // pendingOutput should have data for %0
        let pending = manager.pendingOutput["%0"]
        XCTAssertNotNil(pending, "pendingOutput should have data for %0")
        XCTAssertEqual(pending?.count, 1, "Should have exactly 1 chunk of data buffered")
        
        // Verify the content is \r\n converted
        if let data = pending?.first, let text = String(data: data, encoding: .utf8) {
            let expectedConverted = captureContent.replacingOccurrences(of: "\n", with: "\r\n")
            XCTAssertEqual(text, expectedConverted,
                           "Buffered content should have \\n → \\r\\n conversion applied")
        } else {
            XCTFail("Could not decode pending output data as UTF-8")
        }
    }

    /// Verify that multi-pane restore buffers data for ALL panes in pendingOutput.
    func testMultiPanePendingOutput() async throws {
        let manager = makeManager()
        
        asyncResponses["capture-pane -pe -t %0"] = "pane0 line1\npane0 line2"
        asyncResponses["capture-pane -pe -t %3"] = "pane3 content"
        
        manager.handleSessionChanged(sessionId: "$0", sessionName: "main")
        flushCommand(prefix: "list-panes", response: "%0\n%3")
        
        try await Task.sleep(for: .milliseconds(200))
        
        // Both panes should have pending output
        XCTAssertNotNil(manager.pendingOutput["%0"], "pendingOutput should have %0")
        XCTAssertNotNil(manager.pendingOutput["%3"], "pendingOutput should have %3")
        
        // Verify content
        if let data = manager.pendingOutput["%0"]?.first, let text = String(data: data, encoding: .utf8) {
            XCTAssertTrue(text.contains("\r\n"), "%0 content should have \\r\\n")
            XCTAssertTrue(text.contains("pane0 line1"), "%0 content should contain original text")
        }
        
        if let data = manager.pendingOutput["%3"]?.first, let text = String(data: data, encoding: .utf8) {
            XCTAssertEqual(text, "pane3 content", "%3 content has no newlines to convert")
        }
    }

    /// Verify that empty capture-pane response does NOT buffer anything.
    /// An empty pane (e.g., freshly created) should be skipped.
    func testEmptyCaptureNotBuffered() async throws {
        let manager = makeManager()
        
        asyncResponses["capture-pane"] = ""  // empty response
        
        manager.handleSessionChanged(sessionId: "$0", sessionName: "main")
        flushCommand(prefix: "list-panes", response: "%0")
        
        try await Task.sleep(for: .milliseconds(200))
        
        // pendingOutput should be empty — empty content is explicitly skipped
        XCTAssertNil(manager.pendingOutput["%0"],
                     "Empty capture should not create pendingOutput entry")
    }

    /// Verify that routeOutput also buffers to pendingOutput when no factory exists.
    /// This tests the normal %output path (not restore), ensuring both paths use the same buffer.
    func testRouteOutputBuffersWithoutFactory() {
        let manager = makeManager()
        
        // No factory configured
        let testData = "Hello from %output".data(using: .utf8)!
        manager.routeOutput(testData, to: "%0")
        
        XCTAssertNotNil(manager.pendingOutput["%0"],
                        "routeOutput should buffer when no factory exists")
        XCTAssertEqual(manager.pendingOutput["%0"]?.count, 1)
        XCTAssertEqual(manager.pendingOutput["%0"]?.first, testData)
    }

    /// Verify that multiple routeOutput calls accumulate in pendingOutput.
    func testRouteOutputAccumulates() {
        let manager = makeManager()
        
        let chunk1 = "chunk1".data(using: .utf8)!
        let chunk2 = "chunk2".data(using: .utf8)!
        let chunk3 = "chunk3".data(using: .utf8)!
        
        manager.routeOutput(chunk1, to: "%0")
        manager.routeOutput(chunk2, to: "%0")
        manager.routeOutput(chunk3, to: "%1")
        
        XCTAssertEqual(manager.pendingOutput["%0"]?.count, 2,
                       "%0 should have 2 chunks")
        XCTAssertEqual(manager.pendingOutput["%1"]?.count, 1,
                       "%1 should have 1 chunk")
    }

    /// Verify that controlModeExited clears pendingOutput.
    /// On disconnect, all buffered output is stale and must be discarded.
    func testControlModeExitedClearsPendingOutput() {
        let manager = makeManager()
        
        // Buffer some output
        manager.routeOutput("data".data(using: .utf8)!, to: "%0")
        manager.routeOutput("data".data(using: .utf8)!, to: "%1")
        XCTAssertFalse(manager.pendingOutput.isEmpty, "Precondition: should have pending output")
        
        // Exit control mode
        manager.controlModeExited(reason: "test")
        
        XCTAssertTrue(manager.pendingOutput.isEmpty,
                      "controlModeExited should clear all pending output")
    }

    /// Verify that restore + routeOutput interleave correctly.
    /// Scenario: restore runs, buffers capture data, then %output arrives for the same pane.
    /// Both should accumulate in pendingOutput and be flushed together.
    func testRestoreAndLiveOutputInterleave() async throws {
        let manager = makeManager()
        
        asyncResponses["capture-pane"] = "captured screen"
        
        manager.handleSessionChanged(sessionId: "$0", sessionName: "main")
        flushCommand(prefix: "list-panes", response: "%0")
        
        try await Task.sleep(for: .milliseconds(200))
        
        // Now simulate live %output arriving after restore
        let liveOutput = "new command output".data(using: .utf8)!
        manager.routeOutput(liveOutput, to: "%0")
        
        // Should have both restore capture AND live output
        let pending = manager.pendingOutput["%0"]
        XCTAssertNotNil(pending)
        XCTAssertEqual(pending?.count, 2, "Should have capture data + live output")
        
        // First chunk is from capture (with \r\n conversion)
        if let firstChunk = pending?.first, let text = String(data: firstChunk, encoding: .utf8) {
            XCTAssertEqual(text, "captured screen",
                           "First chunk should be from capture-pane")
        }
        
        // Second chunk is from live %output (no conversion)
        XCTAssertEqual(pending?.last, liveOutput,
                       "Second chunk should be live %output data")
    }
    
    /// Verify that the paneSurfaces dictionary is empty when no factory is configured.
    /// This confirms that restore doesn't accidentally create surfaces without a factory.
    func testNoSurfacesCreatedWithoutFactory() async throws {
        let manager = makeManager()
        
        asyncResponses["capture-pane"] = "content"
        
        manager.handleSessionChanged(sessionId: "$0", sessionName: "main")
        flushCommand(prefix: "list-panes", response: "%0")
        
        try await Task.sleep(for: .milliseconds(200))
        
        XCTAssertTrue(manager.paneSurfaces.isEmpty,
                      "No surfaces should be created without a factory")
    }
}
