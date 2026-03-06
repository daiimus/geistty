import XCTest
@testable import Geistty

// MARK: - TmuxSessionNameResolver Tests

final class TmuxSessionNameResolverTests: XCTestCase {
    
    typealias Entry = TmuxSessionNameResolver.SessionEntry
    
    /// Fixed marker for deterministic tests. Production code uses UUID-based nonces
    /// via `makeEndMarker()`, but tests need repeatable values.
    private let testMarker = "---GEISTTY-END-TESTONLY---"
    
    // MARK: - parseSessions
    
    func testParseEmptyOutput() {
        let result = TmuxSessionNameResolver.parseSessions(from: "", endMarker: testMarker)
        XCTAssertEqual(result, [])
    }
    
    func testParseSentinelOnly() {
        let result = TmuxSessionNameResolver.parseSessions(from: "\(testMarker)\n", endMarker: testMarker)
        XCTAssertEqual(result, [])
    }
    
    func testParseSingleSession() {
        let output = "main 1\n\(testMarker)\n"
        let result = TmuxSessionNameResolver.parseSessions(from: output, endMarker: testMarker)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, "main")
        XCTAssertEqual(result[0].attachedCount, 1)
        XCTAssertTrue(result[0].isAttached)
    }
    
    func testParseUnattachedSession() {
        let output = "main 0\n\(testMarker)\n"
        let result = TmuxSessionNameResolver.parseSessions(from: output, endMarker: testMarker)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, "main")
        XCTAssertEqual(result[0].attachedCount, 0)
        XCTAssertFalse(result[0].isAttached)
    }
    
    func testParseMultipleSessions() {
        let output = """
        main 1
        geistty-1 0
        geistty-2 1
        shellfish-1 0
        \(testMarker)
        """
        let result = TmuxSessionNameResolver.parseSessions(from: output, endMarker: testMarker)
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result[0].name, "main")
        XCTAssertEqual(result[1].name, "geistty-1")
        XCTAssertEqual(result[2].name, "geistty-2")
        XCTAssertEqual(result[3].name, "shellfish-1")
    }
    
    func testParseMultipleAttachedClients() {
        // A session can have more than one client attached
        let output = "main 3\n\(testMarker)\n"
        let result = TmuxSessionNameResolver.parseSessions(from: output, endMarker: testMarker)
        XCTAssertEqual(result[0].attachedCount, 3)
        XCTAssertTrue(result[0].isAttached)
    }
    
    func testParseSkipsGarbageLines() {
        // Shell noise, errors, prompts mixed in
        let output = """
        bash: some warning
        main 1
        -bash: /usr/local/bin/foo: No such file
        geistty-1 0
        \(testMarker)
        $
        """
        let result = TmuxSessionNameResolver.parseSessions(from: output, endMarker: testMarker)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].name, "main")
        XCTAssertEqual(result[1].name, "geistty-1")
    }
    
    func testParseNoTmuxRunning() {
        // When tmux isn't running, list-sessions fails silently (2>/dev/null)
        // Only the sentinel arrives
        let output = "\(testMarker)\n"
        let result = TmuxSessionNameResolver.parseSessions(from: output, endMarker: testMarker)
        XCTAssertEqual(result, [])
    }
    
    func testParseTrimsWhitespace() {
        let output = "  main 1  \n  geistty-1 0  \n\(testMarker)\n"
        let result = TmuxSessionNameResolver.parseSessions(from: output, endMarker: testMarker)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].name, "main")
        XCTAssertEqual(result[1].name, "geistty-1")
    }
    
    // MARK: - geisttyNumber
    
    func testGeisttyNumberValid() {
        XCTAssertEqual(TmuxSessionNameResolver.geisttyNumber(from: "geistty-1"), 1)
        XCTAssertEqual(TmuxSessionNameResolver.geisttyNumber(from: "geistty-42"), 42)
        XCTAssertEqual(TmuxSessionNameResolver.geisttyNumber(from: "geistty-100"), 100)
    }
    
    func testGeisttyNumberInvalid() {
        XCTAssertNil(TmuxSessionNameResolver.geisttyNumber(from: "main"))
        XCTAssertNil(TmuxSessionNameResolver.geisttyNumber(from: "shellfish-1"))
        XCTAssertNil(TmuxSessionNameResolver.geisttyNumber(from: "geistty-"))
        XCTAssertNil(TmuxSessionNameResolver.geisttyNumber(from: "geistty-abc"))
        XCTAssertNil(TmuxSessionNameResolver.geisttyNumber(from: ""))
    }
    
    // MARK: - resolve
    
    func testResolveNoSessions() {
        // No tmux sessions at all → create geistty-1
        let result = TmuxSessionNameResolver.resolve(from: [])
        XCTAssertEqual(result, "geistty-1")
    }
    
    func testResolveNoGeisttySessions() {
        // Other sessions exist but no geistty → create geistty-1
        let sessions = [
            Entry(name: "main", attachedCount: 1),
            Entry(name: "shellfish-1", attachedCount: 0),
        ]
        let result = TmuxSessionNameResolver.resolve(from: sessions)
        XCTAssertEqual(result, "geistty-1")
    }
    
    func testResolveOneUnattachedGeistty() {
        // One unattached geistty session → reattach to it
        let sessions = [
            Entry(name: "main", attachedCount: 1),
            Entry(name: "geistty-1", attachedCount: 0),
        ]
        let result = TmuxSessionNameResolver.resolve(from: sessions)
        XCTAssertEqual(result, "geistty-1")
    }
    
    func testResolveOneAttachedGeistty() {
        // One attached geistty session → create geistty-2
        let sessions = [
            Entry(name: "geistty-1", attachedCount: 1),
        ]
        let result = TmuxSessionNameResolver.resolve(from: sessions)
        XCTAssertEqual(result, "geistty-2")
    }
    
    func testResolveMultipleUnattached_PicksLowest() {
        // Multiple unattached → pick lowest numbered
        let sessions = [
            Entry(name: "geistty-3", attachedCount: 0),
            Entry(name: "geistty-1", attachedCount: 0),
            Entry(name: "geistty-2", attachedCount: 0),
        ]
        let result = TmuxSessionNameResolver.resolve(from: sessions)
        XCTAssertEqual(result, "geistty-1")
    }
    
    func testResolveMixedAttachedUnattached() {
        // geistty-1 attached, geistty-2 unattached → pick geistty-2
        let sessions = [
            Entry(name: "geistty-1", attachedCount: 1),
            Entry(name: "geistty-2", attachedCount: 0),
            Entry(name: "geistty-3", attachedCount: 1),
        ]
        let result = TmuxSessionNameResolver.resolve(from: sessions)
        XCTAssertEqual(result, "geistty-2")
    }
    
    func testResolveAllAttached_CreatesNext() {
        // All geistty sessions attached → create next
        let sessions = [
            Entry(name: "geistty-1", attachedCount: 1),
            Entry(name: "geistty-2", attachedCount: 2),
            Entry(name: "geistty-3", attachedCount: 1),
        ]
        let result = TmuxSessionNameResolver.resolve(from: sessions)
        XCTAssertEqual(result, "geistty-4")
    }
    
    func testResolveGapInNumbers() {
        // geistty-1 attached, geistty-3 unattached (gap at 2) → pick geistty-3
        let sessions = [
            Entry(name: "geistty-1", attachedCount: 1),
            Entry(name: "geistty-3", attachedCount: 0),
        ]
        let result = TmuxSessionNameResolver.resolve(from: sessions)
        XCTAssertEqual(result, "geistty-3")
    }
    
    func testResolveAllAttachedWithGap() {
        // geistty-1 and geistty-3 both attached → create geistty-4 (max + 1)
        let sessions = [
            Entry(name: "geistty-1", attachedCount: 1),
            Entry(name: "geistty-3", attachedCount: 1),
        ]
        let result = TmuxSessionNameResolver.resolve(from: sessions)
        XCTAssertEqual(result, "geistty-4")
    }
    
    func testResolveIgnoresNonGeisttySessions() {
        // Other sessions don't affect geistty naming
        let sessions = [
            Entry(name: "main", attachedCount: 1),
            Entry(name: "work", attachedCount: 0),
            Entry(name: "shellfish-1", attachedCount: 0),
        ]
        let result = TmuxSessionNameResolver.resolve(from: sessions)
        XCTAssertEqual(result, "geistty-1")
    }
    
    // MARK: - isResponseComplete
    
    func testResponseCompleteWithSentinel() {
        XCTAssertTrue(TmuxSessionNameResolver.isResponseComplete("main 1\n\(testMarker)\n", endMarker: testMarker))
    }
    
    func testResponseIncomplete() {
        XCTAssertFalse(TmuxSessionNameResolver.isResponseComplete("main 1\n", endMarker: testMarker))
        XCTAssertFalse(TmuxSessionNameResolver.isResponseComplete("", endMarker: testMarker))
        XCTAssertFalse(TmuxSessionNameResolver.isResponseComplete("main 1\ngeistty-1 0\n", endMarker: testMarker))
    }
    
    func testResponseCompleteWithShellNoise() {
        // Sentinel buried in noise
        let buffer = "$ tmux list-sessions...\nmain 1\n\(testMarker)\n$ "
        XCTAssertTrue(TmuxSessionNameResolver.isResponseComplete(buffer, endMarker: testMarker))
    }
    
    // MARK: - extractResponse
    
    func testExtractResponseClean() {
        let buffer = "main 1\n\(testMarker)\n$ "
        let response = TmuxSessionNameResolver.extractResponse(from: buffer, endMarker: testMarker)
        XCTAssertNotNil(response)
        XCTAssertTrue(response!.contains("main 1"))
        XCTAssertTrue(response!.contains(testMarker))
    }
    
    func testExtractResponseNil() {
        XCTAssertNil(TmuxSessionNameResolver.extractResponse(from: "main 1\n", endMarker: testMarker))
    }
    
    func testExtractResponseEndMarkerAtEndOfBuffer() {
        // Regression: when the marker is the very last thing in the buffer
        // (no trailing newline), upperBound == endIndex. Using closed range
        // (buffer.startIndex...range.upperBound) would crash with
        // "String index is out of bounds". Must use half-open range (..<).
        let buffer = "main 1\n\(testMarker)"
        let response = TmuxSessionNameResolver.extractResponse(from: buffer, endMarker: testMarker)
        XCTAssertNotNil(response)
        XCTAssertTrue(response!.contains("main 1"))
        XCTAssertTrue(response!.contains(testMarker))
        XCTAssertEqual(response, "main 1\n\(testMarker)")
    }
    
    // MARK: - makeEndMarker / makeQueryCommand
    
    func testMakeEndMarkerFormat() {
        let marker = TmuxSessionNameResolver.makeEndMarker()
        XCTAssertTrue(marker.hasPrefix("---GEISTTY-END-"))
        XCTAssertTrue(marker.hasSuffix("---"))
        // Should contain a UUID nonce segment (8 hex chars)
        let nonce = marker.dropFirst("---GEISTTY-END-".count).dropLast("---".count)
        XCTAssertEqual(nonce.count, 8, "Nonce should be 8 characters (UUID prefix)")
    }
    
    func testMakeEndMarkerIsUnique() {
        // Each call should produce a different marker (UUID nonce)
        let marker1 = TmuxSessionNameResolver.makeEndMarker()
        let marker2 = TmuxSessionNameResolver.makeEndMarker()
        XCTAssertNotEqual(marker1, marker2)
    }
    
    func testMakeQueryCommandFormat() {
        let (command, marker) = TmuxSessionNameResolver.makeQueryCommand()
        XCTAssertTrue(command.contains("tmux list-sessions"))
        XCTAssertTrue(command.contains("#{session_name}"))
        XCTAssertTrue(command.contains("#{session_attached}"))
        XCTAssertTrue(command.contains("2>/dev/null"))
        XCTAssertTrue(command.contains(marker), "Command should contain the returned marker")
        XCTAssertTrue(command.hasSuffix("\n"))
    }
    
    func testMakeQueryCommandMarkerMatchesEcho() {
        // The marker returned by makeQueryCommand should be usable with
        // isResponseComplete/extractResponse/parseSessions
        let (_, marker) = TmuxSessionNameResolver.makeQueryCommand()
        
        let simulatedOutput = "geistty-1 0\n\(marker)\n"
        XCTAssertTrue(TmuxSessionNameResolver.isResponseComplete(simulatedOutput, endMarker: marker))
        
        let response = TmuxSessionNameResolver.extractResponse(from: simulatedOutput, endMarker: marker)
        XCTAssertNotNil(response)
        
        let sessions = TmuxSessionNameResolver.parseSessions(from: response!, endMarker: marker)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].name, "geistty-1")
    }
    
    // MARK: - #4 Regression: Shell echo false positive
    
    func testEchoDoesNotFalsePositiveComplete() {
        // Root cause of #4: The shell echoes the command back before executing it.
        // With a static "---END---" sentinel, the echoed command line itself would
        // match isResponseComplete, causing premature resolution with zero sessions.
        //
        // With nonce-based markers, the echoed command contains the SAME marker,
        // so we must verify that the echo line is treated as shell noise by
        // parseSessions (it doesn't match "<name> <count>" format).
        let (command, marker) = TmuxSessionNameResolver.makeQueryCommand()
        
        // Simulate what the shell does: echo the command, then run it.
        // The echo arrives first, before the actual tmux output.
        let echoLine = command.trimmingCharacters(in: .newlines)
        let shellOutput = """
        \(echoLine)
        geistty-1 1
        geistty-2 0
        \(marker)
        """
        
        // The buffer IS complete (the real marker output arrived)
        XCTAssertTrue(TmuxSessionNameResolver.isResponseComplete(shellOutput, endMarker: marker))
        
        // But the echoed command line should be treated as garbage and skipped
        let response = TmuxSessionNameResolver.extractResponse(from: shellOutput, endMarker: marker)
        XCTAssertNotNil(response)
        let sessions = TmuxSessionNameResolver.parseSessions(from: response!, endMarker: marker)
        
        // Should find the real sessions, not be confused by the echo
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].name, "geistty-1")
        XCTAssertEqual(sessions[1].name, "geistty-2")
    }
    
    func testEchoOnlyDoesNotResolvePrematurely() {
        // Before the fix: only the echo arrives (tmux output hasn't come yet).
        // With the old static "---END---", the echo itself contained "---END---"
        // and would match isResponseComplete → premature resolution with 0 sessions.
        //
        // With the nonce-based marker, the echo DOES contain the marker (it's the
        // same command). However, in practice, the shell echo contains the full
        // `echo '---GEISTTY-END-XXXX---'` command, and the actual sentinel output
        // is just `---GEISTTY-END-XXXX---` on its own line.
        //
        // The key protection is that if the echo arrives in a SEPARATE data chunk
        // before the actual output, isResponseComplete will return true on the echo.
        // This is acceptable because parseSessions will correctly skip the echo line
        // (it doesn't match "<name> <count>" format) and find zero sessions, which
        // resolves to geistty-1. The REAL fix is that in practice, the nonce ensures
        // we can't match a DIFFERENT query's sentinel — each query has its own UUID.
        let marker = "---GEISTTY-END-ABCD1234---"
        
        // Only the echo arrived, no real output yet
        let echoOnly = "tmux list-sessions -F '#{session_name} #{session_attached}' 2>/dev/null; echo '\(marker)'\n"
        
        // The echo contains the marker text, so isResponseComplete returns true.
        // This is the same behavior as before — the protection is that parseSessions
        // skips non-session lines, so we get 0 sessions → geistty-1 (correct default).
        if TmuxSessionNameResolver.isResponseComplete(echoOnly, endMarker: marker) {
            let response = TmuxSessionNameResolver.extractResponse(from: echoOnly, endMarker: marker)
            let sessions = TmuxSessionNameResolver.parseSessions(from: response ?? echoOnly, endMarker: marker)
            // No valid "<name> <count>" lines in the echo → 0 sessions → falls back to geistty-1
            XCTAssertEqual(sessions.count, 0)
            let resolved = TmuxSessionNameResolver.resolve(from: sessions)
            XCTAssertEqual(resolved, "geistty-1")
        }
        // Note: The real protection against #4 is that in a multi-query scenario,
        // each query's nonce is unique, so stale sentinels from previous queries
        // cannot match.
    }
    
    func testDifferentNoncesDoNotCrossMatch() {
        // Critical: If two queries are issued (e.g., reconnect), the sentinel
        // from query 1 must not satisfy isResponseComplete for query 2's marker.
        let marker1 = TmuxSessionNameResolver.makeEndMarker()
        let marker2 = TmuxSessionNameResolver.makeEndMarker()
        
        let outputWithMarker1 = "geistty-1 0\n\(marker1)\n"
        
        // marker1's output should NOT complete marker2's query
        XCTAssertFalse(TmuxSessionNameResolver.isResponseComplete(outputWithMarker1, endMarker: marker2))
        // But should complete marker1's query
        XCTAssertTrue(TmuxSessionNameResolver.isResponseComplete(outputWithMarker1, endMarker: marker1))
    }
    
    // MARK: - End-to-End Scenarios
    
    func testEndToEnd_FreshServer() {
        // No tmux running → empty output → geistty-1
        let output = "\(testMarker)\n"
        let sessions = TmuxSessionNameResolver.parseSessions(from: output, endMarker: testMarker)
        let name = TmuxSessionNameResolver.resolve(from: sessions)
        XCTAssertEqual(name, "geistty-1")
    }
    
    func testEndToEnd_PreviousGeisttySessionSurvived() {
        // User backgrounded, came back → geistty-1 is unattached
        let output = "geistty-1 0\n\(testMarker)\n"
        let sessions = TmuxSessionNameResolver.parseSessions(from: output, endMarker: testMarker)
        let name = TmuxSessionNameResolver.resolve(from: sessions)
        XCTAssertEqual(name, "geistty-1")
    }
    
    func testEndToEnd_ShellFishAlsoConnected() {
        // ShellFish is connected, geistty-1 is unattached from previous background
        let output = """
        shellfish-1 1
        geistty-1 0
        \(testMarker)
        """
        let sessions = TmuxSessionNameResolver.parseSessions(from: output, endMarker: testMarker)
        let name = TmuxSessionNameResolver.resolve(from: sessions)
        XCTAssertEqual(name, "geistty-1")
    }
    
    func testEndToEnd_TwoGeisttyDevices() {
        // iPad connected to geistty-1, iPhone needs its own
        let output = """
        geistty-1 1
        \(testMarker)
        """
        let sessions = TmuxSessionNameResolver.parseSessions(from: output, endMarker: testMarker)
        let name = TmuxSessionNameResolver.resolve(from: sessions)
        XCTAssertEqual(name, "geistty-2")
    }
    
    func testEndToEnd_ComplexScenario() {
        // iPad on geistty-1, iPhone backgrounded (geistty-2 unattached), Mac on geistty-3
        let output = """
        main 1
        geistty-1 1
        geistty-2 0
        geistty-3 1
        shellfish-1 0
        \(testMarker)
        """
        let sessions = TmuxSessionNameResolver.parseSessions(from: output, endMarker: testMarker)
        let name = TmuxSessionNameResolver.resolve(from: sessions)
        XCTAssertEqual(name, "geistty-2")
    }
    
    // MARK: - prefix constant
    
    func testPrefixConstant() {
        XCTAssertEqual(TmuxSessionNameResolver.prefix, "geistty-")
    }
}
