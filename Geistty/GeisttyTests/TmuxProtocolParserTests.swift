import XCTest
@testable import Geistty

// MARK: - TmuxProtocolParser Tests

final class TmuxProtocolParserTests: XCTestCase {

    private var parser: TmuxProtocolParser!

    override func setUp() {
        super.setUp()
        parser = TmuxProtocolParser()
    }

    // MARK: - Helpers

    /// Create Data from a string for feeding into parse()
    private func data(_ string: String) -> Data {
        Data(string.utf8)
    }

    /// Parse a single complete line (adds newline, no prior buffer/block state)
    private func parseSingle(_ line: String) -> [TmuxMessage] {
        let (messages, _, _) = parser.parse(data(line + "\n"), buffer: Data(), blockState: nil)
        return messages
    }

    // MARK: - parseControlMessage: %begin / %end / %error

    func testBlockBegin() {
        let msg = parser.parseControlMessage("%begin 1700000000 42 0")
        XCTAssertEqual(msg, .blockBegin(timestamp: "1700000000", commandNumber: "42", flags: "0"))
    }

    func testBlockBeginMinimalFields() {
        let msg = parser.parseControlMessage("%begin 1700000000")
        XCTAssertEqual(msg, .blockBegin(timestamp: "1700000000", commandNumber: "0", flags: "0"))
    }

    func testBlockEnd() {
        // %end is only meaningful inside a block — parseControlMessage returns .unknown
        // Test through parseLine with an active block state instead
        let block = TmuxBlockState(commandNumber: "42", timestamp: "1700000000")
        let (messages, newBlockState) = parser.parseLine("%end 1700000000 42", blockState: block)
        XCTAssertEqual(messages, [.blockEnd(timestamp: "1700000000", commandNumber: "42")])
        XCTAssertNil(newBlockState, "Block state should be cleared after %end")
    }

    func testBlockError() {
        // %error is only meaningful inside a block — parseControlMessage returns .unknown
        // Test through parseLine with an active block state instead
        let block = TmuxBlockState(commandNumber: "42", timestamp: "1700000000")
        let (messages, newBlockState) = parser.parseLine("%error 1700000000 42", blockState: block)
        XCTAssertEqual(messages, [.blockError(timestamp: "1700000000", commandNumber: "42")])
        XCTAssertNil(newBlockState, "Block state should be cleared after %error")
    }

    // MARK: - parseControlMessage: %output

    func testOutputSimpleASCII() {
        let msg = parser.parseControlMessage("%output %0 hello world")
        if case .output(let paneId, let data) = msg {
            XCTAssertEqual(paneId, "%0")
            XCTAssertEqual(String(data: data, encoding: .utf8), "hello world")
        } else {
            XCTFail("Expected .output, got \(msg)")
        }
    }

    func testOutputWithOctalEscape() {
        // \033 = ESC (0x1B), \134 = backslash
        let msg = parser.parseControlMessage("%output %5 \\033[31mred\\033[0m")
        if case .output(let paneId, let data) = msg {
            XCTAssertEqual(paneId, "%5")
            XCTAssertEqual(data, Data([0x1B, 0x5B, 0x33, 0x31, 0x6D,
                                       0x72, 0x65, 0x64,
                                       0x1B, 0x5B, 0x30, 0x6D]))
        } else {
            XCTFail("Expected .output, got \(msg)")
        }
    }

    func testOutputMissingData() {
        // Only pane ID, no data portion → falls through to .unknown
        let msg = parser.parseControlMessage("%output %0")
        XCTAssertEqual(msg, .unknown(line: "%output %0"))
    }

    // MARK: - parseControlMessage: %extended-output

    func testExtendedOutput() {
        let msg = parser.parseControlMessage("%extended-output %3 42 : hello")
        if case .extendedOutput(let paneId, let latency, let data) = msg {
            XCTAssertEqual(paneId, "%3")
            XCTAssertEqual(latency, "42")
            XCTAssertEqual(String(data: data, encoding: .utf8), "hello")
        } else {
            XCTFail("Expected .extendedOutput, got \(msg)")
        }
    }

    func testExtendedOutputWithOctalEscapes() {
        let msg = parser.parseControlMessage("%extended-output %1 100 : \\033[H")
        if case .extendedOutput(let paneId, let latency, let data) = msg {
            XCTAssertEqual(paneId, "%1")
            XCTAssertEqual(latency, "100")
            XCTAssertEqual(data, Data([0x1B, 0x5B, 0x48])) // ESC [ H
        } else {
            XCTFail("Expected .extendedOutput, got \(msg)")
        }
    }

    func testExtendedOutputMissingColon() {
        let msg = parser.parseControlMessage("%extended-output %1 100 hello")
        XCTAssertEqual(msg, .unknown(line: "%extended-output %1 100 hello"))
    }

    // MARK: - parseControlMessage: Session Notifications

    func testSessionChanged() {
        let msg = parser.parseControlMessage("%session-changed $1 my-session")
        XCTAssertEqual(msg, .sessionChanged(sessionId: "$1", sessionName: "my-session"))
    }

    func testSessionChangedWithSpacesInName() {
        let msg = parser.parseControlMessage("%session-changed $2 my cool session")
        XCTAssertEqual(msg, .sessionChanged(sessionId: "$2", sessionName: "my cool session"))
    }

    func testSessionRenamed() {
        let msg = parser.parseControlMessage("%session-renamed $1 new-name")
        XCTAssertEqual(msg, .sessionRenamed(sessionId: "$1", newName: "new-name"))
    }

    func testSessionsChanged() {
        let msg = parser.parseControlMessage("%sessions-changed")
        XCTAssertEqual(msg, .sessionsChanged)
    }

    func testSessionWindowChanged() {
        let msg = parser.parseControlMessage("%session-window-changed $1 @3")
        XCTAssertEqual(msg, .sessionWindowChanged(sessionId: "$1", windowId: "@3"))
    }

    // MARK: - parseControlMessage: Window Notifications

    func testWindowAdd() {
        let msg = parser.parseControlMessage("%window-add @5")
        XCTAssertEqual(msg, .windowAdd(windowId: "@5"))
    }

    func testWindowClose() {
        let msg = parser.parseControlMessage("%window-close @5")
        XCTAssertEqual(msg, .windowClose(windowId: "@5"))
    }

    func testWindowRenamed() {
        let msg = parser.parseControlMessage("%window-renamed @2 bash")
        XCTAssertEqual(msg, .windowRenamed(windowId: "@2", name: "bash"))
    }

    func testWindowRenamedWithSpaces() {
        let msg = parser.parseControlMessage("%window-renamed @2 my window name")
        XCTAssertEqual(msg, .windowRenamed(windowId: "@2", name: "my window name"))
    }

    func testWindowPaneChanged() {
        let msg = parser.parseControlMessage("%window-pane-changed @1 %3")
        XCTAssertEqual(msg, .windowPaneChanged(windowId: "@1", paneId: "%3"))
    }

    // MARK: - parseControlMessage: Layout Change

    func testLayoutChange() {
        let layout = "d2e0,159x44,0,0[159x22,0,0,0,159x21,0,23,2]"
        let msg = parser.parseControlMessage("%layout-change @1 0 \(layout)")
        XCTAssertEqual(msg, .layoutChanged(windowId: "@1", windowIndex: 0, layout: layout))
    }

    func testLayoutChangeMissingFields() {
        let msg = parser.parseControlMessage("%layout-change @1")
        XCTAssertEqual(msg, .unknown(line: "%layout-change @1"))
    }

    // MARK: - parseControlMessage: Unlinked Window Notifications

    func testUnlinkedWindowAdd() {
        let msg = parser.parseControlMessage("%unlinked-window-add @7")
        XCTAssertEqual(msg, .unlinkedWindowAdd(windowId: "@7"))
    }

    func testUnlinkedWindowClose() {
        let msg = parser.parseControlMessage("%unlinked-window-close @7")
        XCTAssertEqual(msg, .unlinkedWindowClose(windowId: "@7"))
    }

    func testUnlinkedWindowRenamed() {
        let msg = parser.parseControlMessage("%unlinked-window-renamed @7 zsh")
        XCTAssertEqual(msg, .unlinkedWindowRenamed(windowId: "@7", name: "zsh"))
    }

    // MARK: - parseControlMessage: Client Notifications

    func testClientSessionChanged() {
        let msg = parser.parseControlMessage("%client-session-changed /dev/ttyp0 $2")
        XCTAssertEqual(msg, .clientSessionChanged(clientName: "/dev/ttyp0", sessionId: "$2"))
    }

    func testClientDetached() {
        let msg = parser.parseControlMessage("%client-detached /dev/ttyp0")
        XCTAssertEqual(msg, .clientDetached(clientName: "/dev/ttyp0"))
    }

    // MARK: - parseControlMessage: Pane Notifications

    func testPaneModeChanged() {
        let msg = parser.parseControlMessage("%pane-mode-changed %2")
        XCTAssertEqual(msg, .paneModeChanged(paneId: "%2"))
    }

    func testPausePaneChanged() {
        let msg = parser.parseControlMessage("%pause-pane-changed %0")
        XCTAssertEqual(msg, .pausePaneChanged(paneId: "%0"))
    }

    func testPause() {
        let msg = parser.parseControlMessage("%pause %0")
        XCTAssertEqual(msg, .pause(paneId: "%0"))
    }

    func testContinue() {
        let msg = parser.parseControlMessage("%continue %0")
        XCTAssertEqual(msg, .continue(paneId: "%0"))
    }

    // MARK: - parseControlMessage: Subscription

    func testSubscriptionChangedAllIds() {
        let msg = parser.parseControlMessage("%subscription-changed my-sub $1 @2 %3 some-value")
        XCTAssertEqual(msg, .subscriptionChanged(
            name: "my-sub", sessionId: "$1", windowId: "@2", paneId: "%3", value: "some-value"
        ))
    }

    func testSubscriptionChangedWithDashForNil() {
        let msg = parser.parseControlMessage("%subscription-changed my-sub - - - changed")
        XCTAssertEqual(msg, .subscriptionChanged(
            name: "my-sub", sessionId: nil, windowId: nil, paneId: nil, value: "changed"
        ))
    }

    func testSubscriptionChangedMixedIds() {
        let msg = parser.parseControlMessage("%subscription-changed alert $5 - %2 warning")
        XCTAssertEqual(msg, .subscriptionChanged(
            name: "alert", sessionId: "$5", windowId: nil, paneId: "%2", value: "warning"
        ))
    }

    func testSubscriptionChangedMissingFields() {
        let msg = parser.parseControlMessage("%subscription-changed alert $5")
        XCTAssertEqual(msg, .unknown(line: "%subscription-changed alert $5"))
    }

    // MARK: - parseControlMessage: %exit

    func testExitWithReason() {
        let msg = parser.parseControlMessage("%exit server exited unexpectedly")
        XCTAssertEqual(msg, .exit(reason: "server exited unexpectedly"))
    }

    func testExitWithoutReason() {
        let msg = parser.parseControlMessage("%exit")
        XCTAssertEqual(msg, .exit(reason: nil))
    }

    // MARK: - parseControlMessage: Unknown

    func testUnknownNonPercentLine() {
        let msg = parser.parseControlMessage("just some regular text")
        XCTAssertEqual(msg, .unknown(line: "just some regular text"))
    }

    func testUnknownEmptyPercentCommand() {
        // "%" alone with no split result should go to unknown
        let msg = parser.parseControlMessage("% ")
        // split(separator: " ", maxSplits: 1) on "% " → ["%", ""]
        // "%" doesn't match any case → default → .unknown
        XCTAssertEqual(msg, .unknown(line: "% "))
    }

    func testUnknownPercentWithUnrecognizedType() {
        let msg = parser.parseControlMessage("%future-notification foo bar")
        XCTAssertEqual(msg, .unknown(line: "%future-notification foo bar"))
    }

    // MARK: - decodeOctalEscapes

    func testDecodeOctalESC() {
        let result = parser.decodeOctalEscapes("\\033")
        XCTAssertEqual(result, Data([0x1B]))
    }

    func testDecodeOctalBackslash() {
        let result = parser.decodeOctalEscapes("\\134")
        XCTAssertEqual(result, Data([0x5C])) // '\'
    }

    func testDecodeOctalNewline() {
        let result = parser.decodeOctalEscapes("\\012")
        XCTAssertEqual(result, Data([0x0A])) // '\n'
    }

    func testDecodeOctalMixedWithASCII() {
        let result = parser.decodeOctalEscapes("hello\\033[31mworld")
        let expected = Data("hello".utf8) + Data([0x1B]) + Data("[31mworld".utf8)
        XCTAssertEqual(result, expected)
    }

    func testDecodeOctalMultipleEscapes() {
        let result = parser.decodeOctalEscapes("\\033[0;32m$\\033[0m")
        let expected = Data([0x1B, 0x5B, 0x30, 0x3B, 0x33, 0x32, 0x6D,  // ESC[0;32m
                             0x24,                                          // $
                             0x1B, 0x5B, 0x30, 0x6D])                      // ESC[0m
        XCTAssertEqual(result, expected)
    }

    func testDecodeOctalEmptyString() {
        let result = parser.decodeOctalEscapes("")
        XCTAssertEqual(result, Data())
    }

    func testDecodeOctalPureASCII() {
        let result = parser.decodeOctalEscapes("just ascii")
        XCTAssertEqual(result, Data("just ascii".utf8))
    }

    func testDecodeOctalInvalidAfterBackslash() {
        // '\' followed by non-octal chars → literal backslash
        let result = parser.decodeOctalEscapes("\\abc")
        // 'a' is not octal, so backslash is literal, then 'abc'
        XCTAssertEqual(result, Data("\\abc".utf8))
    }

    func testDecodeOctalBackslashAtEnd() {
        // Trailing backslash with nothing after → literal
        let result = parser.decodeOctalEscapes("hello\\")
        // Backslash at end: afterBackslash == string.endIndex? No, it's at endIndex.
        // Actually index(after: index) == endIndex if backslash is last char.
        // The code checks afterBackslash < string.endIndex → false if backslash is last.
        // So it falls through to literal backslash.
        XCTAssertEqual(result, Data("hello\\".utf8))
    }

    func testDecodeOctalMultiByteUTF8() {
        // Multi-byte characters should pass through
        let result = parser.decodeOctalEscapes("café")
        XCTAssertEqual(result, Data("café".utf8))
    }

    func testDecodeOctalEmojiPassthrough() {
        let result = parser.decodeOctalEscapes("test🎉done")
        XCTAssertEqual(result, Data("test🎉done".utf8))
    }

    // MARK: - parse() End-to-End

    func testParseSimpleLine() {
        let messages = parseSingle("%window-add @1")
        XCTAssertEqual(messages, [.windowAdd(windowId: "@1")])
    }

    func testParseMultipleLines() {
        let input = "%window-add @1\n%window-add @2\n%sessions-changed\n"
        let (messages, remaining, blockState) = parser.parse(data(input), buffer: Data(), blockState: nil)
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0], .windowAdd(windowId: "@1"))
        XCTAssertEqual(messages[1], .windowAdd(windowId: "@2"))
        XCTAssertEqual(messages[2], .sessionsChanged)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertNil(blockState)
    }

    func testParseCRLFLineEndings() {
        let input = "%window-add @1\r\n%sessions-changed\r\n"
        let (messages, remaining, _) = parser.parse(data(input), buffer: Data(), blockState: nil)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0], .windowAdd(windowId: "@1"))
        XCTAssertEqual(messages[1], .sessionsChanged)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testParsePartialLine() {
        // First chunk: incomplete line
        let (msgs1, buffer1, state1) = parser.parse(data("%window-add"), buffer: Data(), blockState: nil)
        XCTAssertEqual(msgs1.count, 0)
        XCTAssertFalse(buffer1.isEmpty)
        XCTAssertNil(state1)

        // Second chunk: completes the line
        let (msgs2, buffer2, _) = parser.parse(data(" @1\n"), buffer: buffer1, blockState: nil)
        XCTAssertEqual(msgs2.count, 1)
        XCTAssertEqual(msgs2[0], .windowAdd(windowId: "@1"))
        XCTAssertTrue(buffer2.isEmpty)
    }

    func testParsePartialLineSplitMidUTF8() {
        // Split a line across calls where the first call ends mid-token
        let (msgs1, buf1, _) = parser.parse(data("%session-renamed $1 new"), buffer: Data(), blockState: nil)
        XCTAssertEqual(msgs1.count, 0)
        let (msgs2, buf2, _) = parser.parse(data("-name\n"), buffer: buf1, blockState: nil)
        XCTAssertEqual(msgs2.count, 1)
        XCTAssertEqual(msgs2[0], .sessionRenamed(sessionId: "$1", newName: "new-name"))
        XCTAssertTrue(buf2.isEmpty)
    }

    // MARK: - Block State Management

    func testBlockLifecycleBeginContentEnd() {
        let input = "%begin 1700000000 1 0\nline one\nline two\n%end 1700000000 1\n"
        let (messages, remaining, blockState) = parser.parse(data(input), buffer: Data(), blockState: nil)

        XCTAssertEqual(messages.count, 4)
        XCTAssertEqual(messages[0], .blockBegin(timestamp: "1700000000", commandNumber: "1", flags: "0"))
        XCTAssertEqual(messages[1], .blockContent(line: "line one"))
        XCTAssertEqual(messages[2], .blockContent(line: "line two"))
        XCTAssertEqual(messages[3], .blockEnd(timestamp: "1700000000", commandNumber: "1"))
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertNil(blockState, "Block should be closed after %end")
    }

    func testBlockLifecycleBeginContentError() {
        let input = "%begin 1700000000 2 0\nsome output\n%error 1700000000 2\n"
        let (messages, _, blockState) = parser.parse(data(input), buffer: Data(), blockState: nil)

        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0], .blockBegin(timestamp: "1700000000", commandNumber: "2", flags: "0"))
        XCTAssertEqual(messages[1], .blockContent(line: "some output"))
        XCTAssertEqual(messages[2], .blockError(timestamp: "1700000000", commandNumber: "2"))
        XCTAssertNil(blockState, "Block should be closed after %error")
    }

    func testBlockOpenAcrossParseCalls() {
        // First call: %begin opens block
        let (msgs1, buf1, state1) = parser.parse(data("%begin 100 5 0\n"), buffer: Data(), blockState: nil)
        XCTAssertEqual(msgs1.count, 1)
        XCTAssertEqual(msgs1[0], .blockBegin(timestamp: "100", commandNumber: "5", flags: "0"))
        XCTAssertNotNil(state1)
        XCTAssertEqual(state1?.commandNumber, "5")

        // Second call: content inside block
        let (msgs2, buf2, state2) = parser.parse(data("response line\n"), buffer: buf1, blockState: state1)
        XCTAssertEqual(msgs2.count, 1)
        XCTAssertEqual(msgs2[0], .blockContent(line: "response line"))
        XCTAssertNotNil(state2)
        XCTAssertEqual(state2?.lines, ["response line"])

        // Third call: %end closes block
        let (msgs3, _, state3) = parser.parse(data("%end 100 5\n"), buffer: buf2, blockState: state2)
        XCTAssertEqual(msgs3.count, 1)
        XCTAssertEqual(msgs3[0], .blockEnd(timestamp: "100", commandNumber: "5"))
        XCTAssertNil(state3)
    }

    func testBlockEmptyContent() {
        let input = "%begin 100 1 0\n%end 100 1\n"
        let (messages, _, blockState) = parser.parse(data(input), buffer: Data(), blockState: nil)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0], .blockBegin(timestamp: "100", commandNumber: "1", flags: "0"))
        XCTAssertEqual(messages[1], .blockEnd(timestamp: "100", commandNumber: "1"))
        XCTAssertNil(blockState)
    }

    func testInterleavedNotificationInsideBlock() {
        let input = "%begin 100 1 0\ncontent\n%window-add @5\nmore content\n%end 100 1\n"
        let (messages, _, blockState) = parser.parse(data(input), buffer: Data(), blockState: nil)

        XCTAssertEqual(messages.count, 5)
        XCTAssertEqual(messages[0], .blockBegin(timestamp: "100", commandNumber: "1", flags: "0"))
        XCTAssertEqual(messages[1], .blockContent(line: "content"))
        XCTAssertEqual(messages[2], .windowAdd(windowId: "@5")) // interleaved notification
        XCTAssertEqual(messages[3], .blockContent(line: "more content"))
        XCTAssertEqual(messages[4], .blockEnd(timestamp: "100", commandNumber: "1"))
        XCTAssertNil(blockState)
    }

    // MARK: - TmuxBlockState.content

    func testBlockStateContentHelper() {
        var block = TmuxBlockState(commandNumber: "1", timestamp: "100")
        block.lines = ["line 1", "line 2", "line 3"]
        XCTAssertEqual(block.content, "line 1\nline 2\nline 3")
    }

    func testBlockStateContentEmpty() {
        let block = TmuxBlockState(commandNumber: "1", timestamp: "100")
        XCTAssertEqual(block.content, "")
    }

    func testBlockStateContentSingleLine() {
        var block = TmuxBlockState(commandNumber: "1", timestamp: "100")
        block.lines = ["only line"]
        XCTAssertEqual(block.content, "only line")
    }

    // MARK: - parseLine: Direct Tests

    func testParseLineOutsideBlock() {
        let (messages, blockState) = parser.parseLine("%sessions-changed", blockState: nil)
        XCTAssertEqual(messages, [.sessionsChanged])
        XCTAssertNil(blockState)
    }

    func testParseLineBeginOpensBlock() {
        let (messages, blockState) = parser.parseLine("%begin 100 7 0", blockState: nil)
        XCTAssertEqual(messages, [.blockBegin(timestamp: "100", commandNumber: "7", flags: "0")])
        XCTAssertNotNil(blockState)
        XCTAssertEqual(blockState?.commandNumber, "7")
        XCTAssertEqual(blockState?.timestamp, "100")
    }

    func testParseLineContentInsideBlock() {
        let block = TmuxBlockState(commandNumber: "1", timestamp: "100")
        let (messages, newBlock) = parser.parseLine("some content", blockState: block)
        XCTAssertEqual(messages, [.blockContent(line: "some content")])
        XCTAssertNotNil(newBlock)
        XCTAssertEqual(newBlock?.lines, ["some content"])
    }

    func testParseLineEndClosesBlock() {
        let block = TmuxBlockState(commandNumber: "1", timestamp: "100", lines: ["data"])
        let (messages, newBlock) = parser.parseLine("%end 100 1", blockState: block)
        XCTAssertEqual(messages, [.blockEnd(timestamp: "100", commandNumber: "1")])
        XCTAssertNil(newBlock)
    }

    func testParseLineErrorClosesBlock() {
        let block = TmuxBlockState(commandNumber: "1", timestamp: "100", lines: ["data"])
        let (messages, newBlock) = parser.parseLine("%error 100 1", blockState: block)
        XCTAssertEqual(messages, [.blockError(timestamp: "100", commandNumber: "1")])
        XCTAssertNil(newBlock)
    }

    func testParseLineNotificationInsideBlockKeepsBlockOpen() {
        let block = TmuxBlockState(commandNumber: "1", timestamp: "100", lines: ["existing"])
        let (messages, newBlock) = parser.parseLine("%window-add @9", blockState: block)
        XCTAssertEqual(messages, [.windowAdd(windowId: "@9")])
        XCTAssertNotNil(newBlock, "Block should remain open for interleaved notifications")
        XCTAssertEqual(newBlock?.commandNumber, "1")
    }

    // MARK: - Realistic Protocol Sequences

    func testRealisticListWindowsResponse() {
        // Simulates: `list-windows` command response
        let input = [
            "%begin 1700000000 1 0",
            "0: bash* (1 panes) [159x44] [layout d2e0,159x44,0,0,0] @0 (active)",
            "1: vim- (1 panes) [159x44] [layout d2e0,159x44,0,0,1] @1",
            "%end 1700000000 1",
            ""
        ].joined(separator: "\n")

        let (messages, _, _) = parser.parse(data(input), buffer: Data(), blockState: nil)
        XCTAssertEqual(messages.count, 4)
        XCTAssertEqual(messages[0], .blockBegin(timestamp: "1700000000", commandNumber: "1", flags: "0"))
        if case .blockContent(let line) = messages[1] {
            XCTAssertTrue(line.contains("bash"))
        } else {
            XCTFail("Expected blockContent")
        }
        if case .blockContent(let line) = messages[2] {
            XCTAssertTrue(line.contains("vim"))
        } else {
            XCTFail("Expected blockContent")
        }
        XCTAssertEqual(messages[3], .blockEnd(timestamp: "1700000000", commandNumber: "1"))
    }

    func testRealisticOutputInterleaved() {
        // Output arrives while a command response block is open
        let input = [
            "%begin 100 1 0",
            "response data",
            "%output %0 shell\\033[32mprompt\\033[0m",
            "more response",
            "%end 100 1",
            ""
        ].joined(separator: "\n")

        let (messages, _, blockState) = parser.parse(data(input), buffer: Data(), blockState: nil)
        XCTAssertEqual(messages.count, 5)
        XCTAssertEqual(messages[0], .blockBegin(timestamp: "100", commandNumber: "1", flags: "0"))
        XCTAssertEqual(messages[1], .blockContent(line: "response data"))
        // The %output is a notification interleaved inside the block
        if case .output(let paneId, _) = messages[2] {
            XCTAssertEqual(paneId, "%0")
        } else {
            XCTFail("Expected .output, got \(messages[2])")
        }
        XCTAssertEqual(messages[3], .blockContent(line: "more response"))
        XCTAssertEqual(messages[4], .blockEnd(timestamp: "100", commandNumber: "1"))
        XCTAssertNil(blockState)
    }

    func testRealisticSessionStartup() {
        // Typical startup sequence from `tmux -CC attach`
        let input = [
            "%begin 1700000000 0 0",
            "%end 1700000000 0",
            "%session-changed $0 main",
            "%layout-change @0 0 d2e0,159x44,0,0[159x22,0,0,0,159x21,0,23,2]",
            "%output %0 \\033[?1049h",
            ""
        ].joined(separator: "\n")

        let (messages, _, _) = parser.parse(data(input), buffer: Data(), blockState: nil)
        XCTAssertEqual(messages.count, 5)
        XCTAssertEqual(messages[0], .blockBegin(timestamp: "1700000000", commandNumber: "0", flags: "0"))
        XCTAssertEqual(messages[1], .blockEnd(timestamp: "1700000000", commandNumber: "0"))
        XCTAssertEqual(messages[2], .sessionChanged(sessionId: "$0", sessionName: "main"))
        if case .layoutChanged(let wid, let widx, _) = messages[3] {
            XCTAssertEqual(wid, "@0")
            XCTAssertEqual(widx, 0)
        } else {
            XCTFail("Expected .layoutChanged")
        }
        if case .output(let paneId, let data) = messages[4] {
            XCTAssertEqual(paneId, "%0")
            // \033[?1049h = ESC [ ? 1 0 4 9 h (alternate screen)
            XCTAssertEqual(data, Data([0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x34, 0x39, 0x68]))
        } else {
            XCTFail("Expected .output")
        }
    }

    // MARK: - Edge Cases

    func testEmptyInput() {
        let (messages, remaining, blockState) = parser.parse(Data(), buffer: Data(), blockState: nil)
        XCTAssertTrue(messages.isEmpty)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertNil(blockState)
    }

    func testOnlyNewlines() {
        let (messages, remaining, _) = parser.parse(data("\n\n\n"), buffer: Data(), blockState: nil)
        // Each empty line parses as unknown("")
        XCTAssertEqual(messages.count, 3)
        for msg in messages {
            XCTAssertEqual(msg, .unknown(line: ""))
        }
        XCTAssertTrue(remaining.isEmpty)
    }

    func testExitEndsSession() {
        let (messages, _, _) = parser.parse(data("%exit\n"), buffer: Data(), blockState: nil)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0], .exit(reason: nil))
    }

    func testExitWithReasonEndsSession() {
        let (messages, _, _) = parser.parse(data("%exit server exited\n"), buffer: Data(), blockState: nil)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0], .exit(reason: "server exited"))
    }

    func testSessionChangedMissingName() {
        let msg = parser.parseControlMessage("%session-changed $1")
        XCTAssertEqual(msg, .unknown(line: "%session-changed $1"))
    }

    func testWindowRenamedMissingName() {
        let msg = parser.parseControlMessage("%window-renamed @1")
        XCTAssertEqual(msg, .unknown(line: "%window-renamed @1"))
    }

    func testBlockEndFallbackTimestamp() {
        // %end inside block with fewer fields than expected → uses block's values
        let block = TmuxBlockState(commandNumber: "3", timestamp: "999")
        let (messages, newBlock) = parser.parseLine("%end 888", blockState: block)
        // Only one part after "%end ": "888" → timestamp=888, cmdNum=block.commandNumber
        XCTAssertEqual(messages, [.blockEnd(timestamp: "888", commandNumber: "3")])
        XCTAssertNil(newBlock)
    }
}
