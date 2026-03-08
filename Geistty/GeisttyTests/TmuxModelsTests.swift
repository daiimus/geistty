import XCTest
@testable import Geistty

// MARK: - TmuxModels Tests

final class TmuxModelsTests: XCTestCase {

    // MARK: - TmuxId Validation

    func testValidSessionId() {
        XCTAssertTrue(TmuxId.isValidSessionId("$0"))
        XCTAssertTrue(TmuxId.isValidSessionId("$123"))
        XCTAssertTrue(TmuxId.isValidSessionId("$999999"))
    }

    func testInvalidSessionId() {
        XCTAssertFalse(TmuxId.isValidSessionId(""))
        XCTAssertFalse(TmuxId.isValidSessionId("$"))
        XCTAssertFalse(TmuxId.isValidSessionId("0"))
        XCTAssertFalse(TmuxId.isValidSessionId("@0"))
        XCTAssertFalse(TmuxId.isValidSessionId("%0"))
        XCTAssertFalse(TmuxId.isValidSessionId("$abc"))
        XCTAssertFalse(TmuxId.isValidSessionId("session"))
    }

    func testValidWindowId() {
        XCTAssertTrue(TmuxId.isValidWindowId("@0"))
        XCTAssertTrue(TmuxId.isValidWindowId("@42"))
        XCTAssertTrue(TmuxId.isValidWindowId("@100"))
    }

    func testInvalidWindowId() {
        XCTAssertFalse(TmuxId.isValidWindowId(""))
        XCTAssertFalse(TmuxId.isValidWindowId("@"))
        XCTAssertFalse(TmuxId.isValidWindowId("0"))
        XCTAssertFalse(TmuxId.isValidWindowId("$0"))
        XCTAssertFalse(TmuxId.isValidWindowId("%0"))
        XCTAssertFalse(TmuxId.isValidWindowId("@abc"))
    }

    func testValidPaneId() {
        XCTAssertTrue(TmuxId.isValidPaneId("%0"))
        XCTAssertTrue(TmuxId.isValidPaneId("%5"))
        XCTAssertTrue(TmuxId.isValidPaneId("%99"))
    }

    func testInvalidPaneId() {
        XCTAssertFalse(TmuxId.isValidPaneId(""))
        XCTAssertFalse(TmuxId.isValidPaneId("%"))
        XCTAssertFalse(TmuxId.isValidPaneId("0"))
        XCTAssertFalse(TmuxId.isValidPaneId("$0"))
        XCTAssertFalse(TmuxId.isValidPaneId("@0"))
        XCTAssertFalse(TmuxId.isValidPaneId("%abc"))
    }

    // MARK: - TmuxId Numeric Extraction

    func testNumericPaneId() {
        XCTAssertEqual(TmuxId.numericPaneId("%0"), 0)
        XCTAssertEqual(TmuxId.numericPaneId("%5"), 5)
        XCTAssertEqual(TmuxId.numericPaneId("%42"), 42)
        XCTAssertNil(TmuxId.numericPaneId("invalid"))
        XCTAssertNil(TmuxId.numericPaneId("%"))
        XCTAssertNil(TmuxId.numericPaneId(""))
    }

    func testNumericWindowId() {
        XCTAssertEqual(TmuxId.numericWindowId("@0"), 0)
        XCTAssertEqual(TmuxId.numericWindowId("@3"), 3)
        XCTAssertEqual(TmuxId.numericWindowId("@100"), 100)
        XCTAssertNil(TmuxId.numericWindowId("invalid"))
        XCTAssertNil(TmuxId.numericWindowId("@"))
    }

    func testNumericSessionId() {
        XCTAssertEqual(TmuxId.numericSessionId("$0"), 0)
        XCTAssertEqual(TmuxId.numericSessionId("$7"), 7)
        XCTAssertEqual(TmuxId.numericSessionId("$256"), 256)
        XCTAssertNil(TmuxId.numericSessionId("invalid"))
        XCTAssertNil(TmuxId.numericSessionId("$"))
    }

    func testPaneIdString() {
        XCTAssertEqual(TmuxId.paneIdString(0), "%0")
        XCTAssertEqual(TmuxId.paneIdString(5), "%5")
        XCTAssertEqual(TmuxId.paneIdString(42), "%42")
    }

    // MARK: - Model Initialization & Equatable

    func testSessionEquatable() {
        let a = TmuxSession(id: "$0", name: "main")
        let b = TmuxSession(id: "$0", name: "main")
        XCTAssertEqual(a, b)
    }

    func testSessionNotEqual() {
        let a = TmuxSession(id: "$0", name: "main")
        let b = TmuxSession(id: "$1", name: "work")
        XCTAssertNotEqual(a, b)
    }

    func testWindowEquatable() {
        let a = TmuxWindow(id: "@0", index: 0, name: "bash", sessionId: "$0")
        let b = TmuxWindow(id: "@0", index: 0, name: "bash", sessionId: "$0")
        XCTAssertEqual(a, b)
    }

    // MARK: - TmuxId Round-trip

    func testPaneIdRoundTrip() {
        for id in [0, 1, 5, 42, 999] {
            let str = TmuxId.paneIdString(id)
            XCTAssertEqual(TmuxId.numericPaneId(str), id, "Round-trip failed for pane ID \(id)")
        }
    }
    
    // MARK: - TmuxId Numeric Sort
    
    func testSortedNumericallyBasic() {
        // Lexicographic sort: ["%10", "%11", "%9"]
        // Numeric sort: ["%9", "%10", "%11"]
        let ids = ["%9", "%10", "%11"]
        let sorted = TmuxId.sortedNumerically(ids)
        XCTAssertEqual(sorted, ["%9", "%10", "%11"])
    }
    
    func testSortedNumericallyAlreadySorted() {
        let ids = ["%0", "%1", "%2"]
        let sorted = TmuxId.sortedNumerically(ids)
        XCTAssertEqual(sorted, ["%0", "%1", "%2"])
    }
    
    func testSortedNumericallyReversed() {
        let ids = ["%100", "%20", "%3"]
        let sorted = TmuxId.sortedNumerically(ids)
        XCTAssertEqual(sorted, ["%3", "%20", "%100"])
    }
    
    func testSortedNumericallyFromSet() {
        // Sets have no guaranteed order — numeric sort should still work
        let ids: Set<String> = ["%9", "%10", "%11"]
        let sorted = TmuxId.sortedNumerically(ids)
        XCTAssertEqual(sorted, ["%9", "%10", "%11"])
    }
    
    func testSortedNumericallyWindowIds() {
        // Also works with @ prefix (window IDs)
        let ids = ["@9", "@10", "@2"]
        let sorted = TmuxId.sortedNumerically(ids)
        XCTAssertEqual(sorted, ["@2", "@9", "@10"])
    }
    
    func testSortedNumericallyEmpty() {
        let sorted = TmuxId.sortedNumerically([String]())
        XCTAssertEqual(sorted, [])
    }
    
    func testSortedNumericalySingle() {
        let sorted = TmuxId.sortedNumerically(["%42"])
        XCTAssertEqual(sorted, ["%42"])
    }
    
    // MARK: - TmuxSessionInfo Parsing
    
    func testParseBasicSessionList() {
        let response = "$0\tmain\t3\t1\n$1\twork\t2\t0"
        let sessions = TmuxSessionInfo.parse(response: response, currentSessionId: "$0")
        
        XCTAssertEqual(sessions.count, 2)
        
        XCTAssertEqual(sessions[0].id, "$0")
        XCTAssertEqual(sessions[0].name, "main")
        XCTAssertEqual(sessions[0].windowCount, 3)
        XCTAssertTrue(sessions[0].isAttached)
        XCTAssertTrue(sessions[0].isCurrent)
        
        XCTAssertEqual(sessions[1].id, "$1")
        XCTAssertEqual(sessions[1].name, "work")
        XCTAssertEqual(sessions[1].windowCount, 2)
        XCTAssertFalse(sessions[1].isAttached)
        XCTAssertFalse(sessions[1].isCurrent)
    }
    
    func testParseSingleSession() {
        let response = "$5\tdev\t1\t1"
        let sessions = TmuxSessionInfo.parse(response: response, currentSessionId: "$5")
        
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].id, "$5")
        XCTAssertEqual(sessions[0].name, "dev")
        XCTAssertTrue(sessions[0].isCurrent)
    }
    
    func testParseEmptyResponse() {
        let sessions = TmuxSessionInfo.parse(response: "")
        XCTAssertTrue(sessions.isEmpty)
    }
    
    func testParseWhitespaceOnlyResponse() {
        let sessions = TmuxSessionInfo.parse(response: "\n\n")
        XCTAssertTrue(sessions.isEmpty)
    }
    
    func testParseSessionNameWithColons() {
        // Session names can contain colons — tab delimiter handles this correctly
        let response = "$0\tmy:server:app\t2\t1"
        let sessions = TmuxSessionInfo.parse(response: response, currentSessionId: nil)
        
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].id, "$0")
        XCTAssertEqual(sessions[0].name, "my:server:app",
                       "Colons in session name must be preserved")
        XCTAssertEqual(sessions[0].windowCount, 2)
        XCTAssertTrue(sessions[0].isAttached)
    }
    
    func testParseNoCurrentSession() {
        let response = "$0\tmain\t2\t1\n$1\tbg\t1\t0"
        let sessions = TmuxSessionInfo.parse(response: response, currentSessionId: nil)
        
        XCTAssertEqual(sessions.count, 2)
        XCTAssertFalse(sessions[0].isCurrent)
        XCTAssertFalse(sessions[1].isCurrent)
    }
    
    func testParseSortsByNumericId() {
        // Feed in reverse order — should come back sorted
        let response = "$10\tten\t1\t0\n$2\ttwo\t1\t0\n$0\tzero\t1\t0"
        let sessions = TmuxSessionInfo.parse(response: response)
        
        XCTAssertEqual(sessions.count, 3)
        XCTAssertEqual(sessions[0].id, "$0")
        XCTAssertEqual(sessions[1].id, "$2")
        XCTAssertEqual(sessions[2].id, "$10")
    }
    
    func testParseMalformedLineSkipped() {
        let response = "$0\tmain\t2\t1\nbadline\n$1\twork\t3\t0"
        let sessions = TmuxSessionInfo.parse(response: response)
        
        XCTAssertEqual(sessions.count, 2, "Malformed line should be skipped")
        XCTAssertEqual(sessions[0].id, "$0")
        XCTAssertEqual(sessions[1].id, "$1")
    }
    
    func testParseInvalidSessionIdSkipped() {
        // "@0" is a window ID, not a session ID
        let response = "@0\tbogus\t1\t0\n$0\treal\t2\t1"
        let sessions = TmuxSessionInfo.parse(response: response)
        
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].id, "$0")
    }
    
    func testParseMultipleAttachedClients() {
        // session_attached > 1 means multiple clients attached
        let response = "$0\tshared\t4\t3"
        let sessions = TmuxSessionInfo.parse(response: response)
        
        XCTAssertEqual(sessions.count, 1)
        XCTAssertTrue(sessions[0].isAttached, "attached count 3 should be true")
        XCTAssertEqual(sessions[0].windowCount, 4)
    }
    
    func testParseZeroWindows() {
        let response = "$0\tempty\t0\t0"
        let sessions = TmuxSessionInfo.parse(response: response)
        
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].windowCount, 0)
        XCTAssertFalse(sessions[0].isAttached)
    }
    
    func testSessionInfoEquatable() {
        let a = TmuxSessionInfo(id: "$0", name: "main", windowCount: 2, isAttached: true, isCurrent: false)
        let b = TmuxSessionInfo(id: "$0", name: "main", windowCount: 2, isAttached: true, isCurrent: false)
        XCTAssertEqual(a, b)
    }
    
    func testSessionInfoNotEqual() {
        let a = TmuxSessionInfo(id: "$0", name: "main", windowCount: 2, isAttached: true, isCurrent: true)
        let b = TmuxSessionInfo(id: "$0", name: "main", windowCount: 2, isAttached: true, isCurrent: false)
        XCTAssertNotEqual(a, b, "isCurrent differs")
    }
    
    func testParseTrailingNewline() {
        // Response from tmux often has a trailing newline
        let response = "$0\tmain\t2\t1\n$1\tbg\t1\t0\n"
        let sessions = TmuxSessionInfo.parse(response: response, currentSessionId: "$0")
        
        XCTAssertEqual(sessions.count, 2, "Trailing newline should not create extra entry")
    }
    
    // MARK: - TmuxOptionScope Command Building
    
    func testShowCommandGlobal() {
        let cmd = TmuxOptionScope.global.showCommand(for: "mouse")
        XCTAssertEqual(cmd, "show-options -gv mouse")
    }
    
    func testShowCommandSession() {
        let cmd = TmuxOptionScope.session.showCommand(for: "escape-time")
        XCTAssertEqual(cmd, "show-options -v escape-time")
    }
    
    func testShowCommandWindow() {
        let cmd = TmuxOptionScope.window.showCommand(for: "mode-keys")
        XCTAssertEqual(cmd, "show-window-options -v mode-keys")
    }
    
    func testSetCommandGlobal() {
        let cmd = TmuxOptionScope.global.setCommand(for: "mouse", value: "on")
        XCTAssertEqual(cmd, "set-option -g mouse \"on\"")
    }
    
    func testSetCommandSession() {
        let cmd = TmuxOptionScope.session.setCommand(for: "escape-time", value: "500")
        XCTAssertEqual(cmd, "set-option escape-time \"500\"")
    }
    
    func testSetCommandWindow() {
        let cmd = TmuxOptionScope.window.setCommand(for: "mode-keys", value: "vi")
        XCTAssertEqual(cmd, "set-option -w mode-keys \"vi\"")
    }
    
    func testSetCommandEscapesQuotesAndBackslashes() {
        let cmd = TmuxOptionScope.global.setCommand(for: "status-left", value: "\"hello\\world\"")
        XCTAssertEqual(cmd, "set-option -g status-left \"\\\"hello\\\\world\\\"\"")
    }
    
    func testSetCommandNormalizesNewlines() {
        let cmd = TmuxOptionScope.global.setCommand(for: "status-left", value: "line1\nline2\rline3")
        XCTAssertEqual(cmd, "set-option -g status-left \"line1 line2 line3\"")
    }
    
    func testShowCommandSanitizesOptionName() {
        // sanitizeOptionName is called by the caller (queryOption/setOption),
        // not by showCommand itself. Verify the full flow:
        guard let safeName = TmuxOptionScope.sanitizeOptionName("mouse\n; kill-server") else {
            XCTFail("Expected sanitized name, got nil")
            return
        }
        let cmd = TmuxOptionScope.global.showCommand(for: safeName)
        XCTAssertEqual(cmd, "show-options -gv mousekill-server")
    }
    
    func testSanitizeOptionNameAllowsValidCharacters() {
        // @user-option, dotted.option, normal-option — all should pass through
        let result = TmuxOptionScope.sanitizeOptionName("@my_user-opt.v2")
        XCTAssertEqual(result, "@my_user-opt.v2")
    }
    
    func testSanitizeOptionNameStripsCommandSeparators() {
        // Semicolons, quotes, backslashes, pipes — all stripped
        let result = TmuxOptionScope.sanitizeOptionName("mouse; kill-server | rm -rf")
        XCTAssertEqual(result, "mousekill-serverrm-rf")
    }
    
    func testSanitizeOptionNameReturnsNilForEmpty() {
        // All characters stripped → empty → nil
        let result = TmuxOptionScope.sanitizeOptionName("; | \" \\")
        XCTAssertNil(result)
    }
    
    func testSanitizeOptionNameReturnsNilForFlagLike() {
        // Starts with "-" after sanitization → would be parsed as tmux flag
        let result = TmuxOptionScope.sanitizeOptionName("-g")
        XCTAssertNil(result)
    }
    
    func testNormalizeOptionValuePassthroughSimple() {
        let result = TmuxOptionScope.normalizeOptionValue("on")
        XCTAssertEqual(result, "on")
    }
    
    func testNormalizeOptionValuePreservesQuotesAndBackslashes() {
        // normalizeOptionValue cleans control chars but does NOT escape —
        // the value should match what tmux stores after unescaping
        let result = TmuxOptionScope.normalizeOptionValue("\"hello\\world\"")
        XCTAssertEqual(result, "\"hello\\world\"")
    }
    
    func testNormalizeOptionValueNormalizesNewlines() {
        let result = TmuxOptionScope.normalizeOptionValue("line1\nline2\rline3")
        XCTAssertEqual(result, "line1 line2 line3")
    }
    
    func testNormalizeOptionValueDropsControlChars() {
        let result = TmuxOptionScope.normalizeOptionValue("hello\u{01}world")
        XCTAssertEqual(result, "helloworld")
    }
    
    // MARK: - TmuxOptionValue Parsing
    
    func testParseOptionValueSimpleString() {
        let value = TmuxOptionValue.parse(response: "on")
        XCTAssertNotNil(value)
        XCTAssertEqual(value?.rawValue, "on")
    }
    
    func testParseOptionValueWithTrailingNewline() {
        let value = TmuxOptionValue.parse(response: "off\n")
        XCTAssertNotNil(value)
        XCTAssertEqual(value?.rawValue, "off")
    }
    
    func testParseOptionValueWithLeadingWhitespace() {
        // Spaces are preserved (meaningful for status formats etc.)
        // Only trailing \n/\r are stripped.
        let value = TmuxOptionValue.parse(response: "  500  \n")
        XCTAssertNotNil(value)
        XCTAssertEqual(value?.rawValue, "  500  ")
    }
    
    func testParseOptionValueEmptyReturnsNil() {
        XCTAssertNil(TmuxOptionValue.parse(response: ""))
    }
    
    func testParseOptionValueWhitespaceOnlyReturnsNil() {
        // Pure newlines/CR return nil (no meaningful content)
        XCTAssertNil(TmuxOptionValue.parse(response: "\n\n"))
    }
    
    func testParseOptionValueComplexString() {
        // window-size has values like "smallest", "largest", "latest", "manual"
        let value = TmuxOptionValue.parse(response: "smallest")
        XCTAssertNotNil(value)
        XCTAssertEqual(value?.rawValue, "smallest")
    }
    
    // MARK: - TmuxOptionValue Bool Accessor
    
    func testBoolValueOn() {
        let value = TmuxOptionValue(rawValue: "on")
        XCTAssertEqual(value.boolValue, true)
    }
    
    func testBoolValueOff() {
        let value = TmuxOptionValue(rawValue: "off")
        XCTAssertEqual(value.boolValue, false)
    }
    
    func testBoolValueCaseInsensitive() {
        XCTAssertEqual(TmuxOptionValue(rawValue: "ON").boolValue, true)
        XCTAssertEqual(TmuxOptionValue(rawValue: "Off").boolValue, false)
        XCTAssertEqual(TmuxOptionValue(rawValue: "oN").boolValue, true)
    }
    
    func testBoolValueNonBoolReturnsNil() {
        XCTAssertNil(TmuxOptionValue(rawValue: "500").boolValue)
        XCTAssertNil(TmuxOptionValue(rawValue: "smallest").boolValue)
        XCTAssertNil(TmuxOptionValue(rawValue: "yes").boolValue)
        XCTAssertNil(TmuxOptionValue(rawValue: "true").boolValue)
    }
    
    // MARK: - TmuxOptionValue Int Accessor
    
    func testIntValueValid() {
        XCTAssertEqual(TmuxOptionValue(rawValue: "500").intValue, 500)
        XCTAssertEqual(TmuxOptionValue(rawValue: "0").intValue, 0)
        XCTAssertEqual(TmuxOptionValue(rawValue: "10000").intValue, 10000)
    }
    
    func testIntValueNonIntReturnsNil() {
        XCTAssertNil(TmuxOptionValue(rawValue: "on").intValue)
        XCTAssertNil(TmuxOptionValue(rawValue: "smallest").intValue)
        XCTAssertNil(TmuxOptionValue(rawValue: "3.14").intValue)
    }
    
    // MARK: - TmuxOptionValue Equatable
    
    func testOptionValueEquatable() {
        let a = TmuxOptionValue(rawValue: "on")
        let b = TmuxOptionValue(rawValue: "on")
        XCTAssertEqual(a, b)
    }
    
    func testOptionValueNotEqual() {
        let a = TmuxOptionValue(rawValue: "on")
        let b = TmuxOptionValue(rawValue: "off")
        XCTAssertNotEqual(a, b)
    }
    
    // MARK: - TmuxOptionScope Equatable
    
    func testOptionScopeEquatable() {
        XCTAssertEqual(TmuxOptionScope.global, TmuxOptionScope.global)
        XCTAssertEqual(TmuxOptionScope.session, TmuxOptionScope.session)
        XCTAssertEqual(TmuxOptionScope.window, TmuxOptionScope.window)
        XCTAssertNotEqual(TmuxOptionScope.global, TmuxOptionScope.session)
        XCTAssertNotEqual(TmuxOptionScope.session, TmuxOptionScope.window)
    }
}
