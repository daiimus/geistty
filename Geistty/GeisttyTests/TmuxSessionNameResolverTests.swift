import XCTest
@testable import Geistty

// MARK: - TmuxSessionNameResolver Tests

final class TmuxSessionNameResolverTests: XCTestCase {
    
    typealias Entry = TmuxSessionNameResolver.SessionEntry
    
    // MARK: - parseSessions
    
    func testParseEmptyOutput() {
        let result = TmuxSessionNameResolver.parseSessions(from: "")
        XCTAssertEqual(result, [])
    }
    
    func testParseSentinelOnly() {
        let result = TmuxSessionNameResolver.parseSessions(from: "---END---\n")
        XCTAssertEqual(result, [])
    }
    
    func testParseSingleSession() {
        let output = "main 1\n---END---\n"
        let result = TmuxSessionNameResolver.parseSessions(from: output)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, "main")
        XCTAssertEqual(result[0].attachedCount, 1)
        XCTAssertTrue(result[0].isAttached)
    }
    
    func testParseUnattachedSession() {
        let output = "main 0\n---END---\n"
        let result = TmuxSessionNameResolver.parseSessions(from: output)
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
        ---END---
        """
        let result = TmuxSessionNameResolver.parseSessions(from: output)
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result[0].name, "main")
        XCTAssertEqual(result[1].name, "geistty-1")
        XCTAssertEqual(result[2].name, "geistty-2")
        XCTAssertEqual(result[3].name, "shellfish-1")
    }
    
    func testParseMultipleAttachedClients() {
        // A session can have more than one client attached
        let output = "main 3\n---END---\n"
        let result = TmuxSessionNameResolver.parseSessions(from: output)
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
        ---END---
        $
        """
        let result = TmuxSessionNameResolver.parseSessions(from: output)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].name, "main")
        XCTAssertEqual(result[1].name, "geistty-1")
    }
    
    func testParseNoTmuxRunning() {
        // When tmux isn't running, list-sessions fails silently (2>/dev/null)
        // Only the sentinel arrives
        let output = "---END---\n"
        let result = TmuxSessionNameResolver.parseSessions(from: output)
        XCTAssertEqual(result, [])
    }
    
    func testParseTrimsWhitespace() {
        let output = "  main 1  \n  geistty-1 0  \n---END---\n"
        let result = TmuxSessionNameResolver.parseSessions(from: output)
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
        XCTAssertTrue(TmuxSessionNameResolver.isResponseComplete("main 1\n---END---\n"))
    }
    
    func testResponseIncomplete() {
        XCTAssertFalse(TmuxSessionNameResolver.isResponseComplete("main 1\n"))
        XCTAssertFalse(TmuxSessionNameResolver.isResponseComplete(""))
        XCTAssertFalse(TmuxSessionNameResolver.isResponseComplete("main 1\ngeistty-1 0\n"))
    }
    
    func testResponseCompleteWithShellNoise() {
        // Sentinel buried in noise
        let buffer = "$ tmux list-sessions...\nmain 1\n---END---\n$ "
        XCTAssertTrue(TmuxSessionNameResolver.isResponseComplete(buffer))
    }
    
    // MARK: - extractResponse
    
    func testExtractResponseClean() {
        let buffer = "main 1\n---END---\n$ "
        let response = TmuxSessionNameResolver.extractResponse(from: buffer)
        XCTAssertNotNil(response)
        XCTAssertTrue(response!.contains("main 1"))
        XCTAssertTrue(response!.contains("---END---"))
    }
    
    func testExtractResponseNil() {
        XCTAssertNil(TmuxSessionNameResolver.extractResponse(from: "main 1\n"))
    }
    
    // MARK: - queryCommand
    
    func testQueryCommandFormat() {
        let cmd = TmuxSessionNameResolver.queryCommand
        XCTAssertTrue(cmd.contains("tmux list-sessions"))
        XCTAssertTrue(cmd.contains("#{session_name}"))
        XCTAssertTrue(cmd.contains("#{session_attached}"))
        XCTAssertTrue(cmd.contains("2>/dev/null"))
        XCTAssertTrue(cmd.contains("---END---"))
        XCTAssertTrue(cmd.hasSuffix("\n"))
    }
    
    // MARK: - End-to-End Scenarios
    
    func testEndToEnd_FreshServer() {
        // No tmux running → empty output → geistty-1
        let output = "---END---\n"
        let sessions = TmuxSessionNameResolver.parseSessions(from: output)
        let name = TmuxSessionNameResolver.resolve(from: sessions)
        XCTAssertEqual(name, "geistty-1")
    }
    
    func testEndToEnd_PreviousGeisttySessionSurvived() {
        // User backgrounded, came back → geistty-1 is unattached
        let output = "geistty-1 0\n---END---\n"
        let sessions = TmuxSessionNameResolver.parseSessions(from: output)
        let name = TmuxSessionNameResolver.resolve(from: sessions)
        XCTAssertEqual(name, "geistty-1")
    }
    
    func testEndToEnd_ShellFishAlsoConnected() {
        // ShellFish is connected, geistty-1 is unattached from previous background
        let output = """
        shellfish-1 1
        geistty-1 0
        ---END---
        """
        let sessions = TmuxSessionNameResolver.parseSessions(from: output)
        let name = TmuxSessionNameResolver.resolve(from: sessions)
        XCTAssertEqual(name, "geistty-1")
    }
    
    func testEndToEnd_TwoGeisttyDevices() {
        // iPad connected to geistty-1, iPhone needs its own
        let output = """
        geistty-1 1
        ---END---
        """
        let sessions = TmuxSessionNameResolver.parseSessions(from: output)
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
        ---END---
        """
        let sessions = TmuxSessionNameResolver.parseSessions(from: output)
        let name = TmuxSessionNameResolver.resolve(from: sessions)
        XCTAssertEqual(name, "geistty-2")
    }
    
    // MARK: - prefix constant
    
    func testPrefixConstant() {
        XCTAssertEqual(TmuxSessionNameResolver.prefix, "geistty-")
    }
    
    func testEndMarkerConstant() {
        XCTAssertEqual(TmuxSessionNameResolver.endMarker, "---END---")
    }
}
