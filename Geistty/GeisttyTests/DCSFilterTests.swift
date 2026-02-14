import XCTest
@testable import Geistty

// MARK: - DCS Filter Tests

/// Comprehensive tests for the DCSFilter struct.
///
/// DCSFilter handles the critical task of detecting tmux DCS 1000p sequences
/// in the SSH data stream, stripping them, and routing data correctly between
/// the terminal (Ghostty) and the tmux gateway.
///
/// Key scenarios tested:
///   - DCS detection in single and split packets
///   - ST (String Terminator) stripping
///   - Partial DCS buffering across packet boundaries
///   - The isHooked latch behavior (once hooked, always routes to gateway)
///   - Bare % control message detection (fallback for split packets)
///   - Data.findSubsequence extension

final class DCSFilterTests: XCTestCase {

    // MARK: - Helpers

    /// DCS 1000p: ESC P 1 0 0 0 p
    private let dcs = Data([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
    /// ST: ESC backslash
    private let st = Data([0x1B, 0x5C])

    private func makeData(_ string: String) -> Data {
        Data(string.utf8)
    }

    private func makeBeginEnd(timestamp: Int = 1700000000) -> Data {
        makeData("%begin \(timestamp) 1 0\r\n%end \(timestamp) 1 0\r\n")
    }

    /// Assert result is .forwardToTerminal with expected data
    private func assertForward(_ result: DCSFilterResult, _ expected: Data, file: StaticString = #filePath, line: UInt = #line) {
        guard case .forwardToTerminal(let data) = result else {
            XCTFail("Expected .forwardToTerminal, got \(result)", file: file, line: line)
            return
        }
        XCTAssertEqual(data, expected, file: file, line: line)
    }

    /// Assert result is .forwardToTerminal with expected string
    private func assertForwardString(_ result: DCSFilterResult, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        assertForward(result, makeData(expected), file: file, line: line)
    }

    /// Assert result is .routeToGateway with expected data
    private func assertGateway(_ result: DCSFilterResult, _ expected: Data, file: StaticString = #filePath, line: UInt = #line) {
        guard case .routeToGateway(let data) = result else {
            XCTFail("Expected .routeToGateway, got \(result)", file: file, line: line)
            return
        }
        XCTAssertEqual(data, expected, file: file, line: line)
    }

    /// Assert result is .routeToGateway with expected string
    private func assertGatewayString(_ result: DCSFilterResult, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        assertGateway(result, makeData(expected), file: file, line: line)
    }

    /// Assert result is .consumed
    private func assertConsumed(_ result: DCSFilterResult, file: StaticString = #filePath, line: UInt = #line) {
        guard case .consumed = result else {
            XCTFail("Expected .consumed, got \(result)", file: file, line: line)
            return
        }
    }

    // MARK: - Basic DCS Detection

    /// Normal case: DCS + control messages all in one packet
    func testDCSWithControlMessagesInOnePacket() {
        var filter = DCSFilter()
        let payload = makeBeginEnd()
        var packet = dcs
        packet.append(payload)

        let result = filter.process(packet)
        assertGateway(result, payload)
        XCTAssertTrue(filter.isHooked)
    }

    /// DCS + ST + control messages in one packet
    func testDCSWithSTAndControlMessages() {
        var filter = DCSFilter()
        let payload = makeBeginEnd()
        var packet = dcs
        packet.append(st)
        packet.append(payload)

        let result = filter.process(packet)
        assertGateway(result, payload)
        XCTAssertTrue(filter.isHooked)
    }

    /// DCS alone at end of packet — next packet has control messages
    func testDCSAloneInPacket1_ControlMessagesInPacket2() {
        var filter = DCSFilter()

        let result1 = filter.process(dcs)
        assertConsumed(result1)
        XCTAssertTrue(filter.isHooked)

        let payload = makeBeginEnd()
        let result2 = filter.process(payload)
        assertGateway(result2, payload)
    }

    /// DCS + ST alone in packet 1, control messages in packet 2
    func testDCSWithSTAloneInPacket1_ControlMessagesInPacket2() {
        var filter = DCSFilter()
        var packet1 = dcs
        packet1.append(st)

        let result1 = filter.process(packet1)
        // DCS detected and stripped, ST stripped, nothing left
        assertConsumed(result1)
        XCTAssertTrue(filter.isHooked)

        let payload = makeBeginEnd()
        let result2 = filter.process(payload)
        assertGateway(result2, payload)
    }

    /// DCS with data after it but no ST
    func testDCSWithoutST() {
        var filter = DCSFilter()
        let payload = makeData("%session-changed $1 main\r\n")
        var packet = dcs
        packet.append(payload)

        let result = filter.process(packet)
        assertGateway(result, payload)
        XCTAssertTrue(filter.isHooked)
    }

    // MARK: - Shell Echo Before DCS

    /// Shell echo before DCS in same packet — echo is dropped, gateway data returned
    func testShellEchoBeforeDCSInSamePacket() {
        var filter = DCSFilter()
        let echo = makeData("exec tmux -CC new-session -A -s geistty-1\r\n")
        let payload = makeBeginEnd()
        var packet = echo
        packet.append(dcs)
        packet.append(payload)

        let result = filter.process(packet)
        // The echo before DCS is dropped (logged), gateway data after DCS is returned
        assertGateway(result, payload)
        XCTAssertTrue(filter.isHooked)
    }

    /// Shell echo in packet 1, DCS in packet 2
    func testShellEchoInPacket1_DCSInPacket2() {
        var filter = DCSFilter()
        let echo = makeData("exec tmux -CC new-session -A -s geistty-1\r\n")
        let payload = makeBeginEnd()

        let result1 = filter.process(echo)
        assertForward(result1, echo)
        XCTAssertFalse(filter.isHooked)

        var packet2 = dcs
        packet2.append(payload)
        let result2 = filter.process(packet2)
        assertGateway(result2, payload)
        XCTAssertTrue(filter.isHooked)
    }

    /// Shell echo before DCS, DCS at very end (no data after)
    func testShellEchoBeforeDCS_DCSAtEnd() {
        var filter = DCSFilter()
        let echo = makeData("Welcome to Dionysus\r\n")
        var packet = echo
        packet.append(dcs)

        let result = filter.process(packet)
        // DCS detected at end, echo before it is returned as terminal data
        assertForward(result, echo)
        XCTAssertTrue(filter.isHooked)
    }

    // MARK: - Partial DCS Across Packet Boundaries

    /// Packet 1 ends with ESC, packet 2 starts with P1000p + data
    func testPartialDCS_ESCAtEnd() {
        var filter = DCSFilter()
        let packet1 = Data([0x1B]) // just ESC
        let result1 = filter.process(packet1)
        assertConsumed(result1)
        XCTAssertFalse(filter.isHooked) // not yet hooked, just buffered

        let payload = makeBeginEnd()
        var packet2 = Data([0x50, 0x31, 0x30, 0x30, 0x30, 0x70]) // P1000p
        packet2.append(payload)
        let result2 = filter.process(packet2)
        assertGateway(result2, payload)
        XCTAssertTrue(filter.isHooked)
    }

    /// Packet 1 ends with ESC P, packet 2 starts with 1000p + data
    func testPartialDCS_ESCPAtEnd() {
        var filter = DCSFilter()
        let packet1 = Data([0x1B, 0x50]) // ESC P
        let result1 = filter.process(packet1)
        assertConsumed(result1)
        XCTAssertFalse(filter.isHooked)

        let payload = makeBeginEnd()
        var packet2 = Data([0x31, 0x30, 0x30, 0x30, 0x70]) // 1000p
        packet2.append(payload)
        let result2 = filter.process(packet2)
        assertGateway(result2, payload)
        XCTAssertTrue(filter.isHooked)
    }

    /// Packet 1: data + ESC P 1 0 0, packet 2: 0 p + data (split mid-sequence)
    func testPartialDCS_MidSequenceSplit() {
        var filter = DCSFilter()
        var packet1 = makeData("hello")
        packet1.append(Data([0x1B, 0x50, 0x31, 0x30, 0x30])) // ESC P 1 0 0

        let result1 = filter.process(packet1)
        // "hello" forwarded, trailing partial DCS buffered
        assertForwardString(result1, "hello")
        XCTAssertFalse(filter.isHooked)

        let payload = makeBeginEnd()
        var packet2 = Data([0x30, 0x70]) // 0 p
        packet2.append(payload)
        let result2 = filter.process(packet2)
        assertGateway(result2, payload)
        XCTAssertTrue(filter.isHooked)
    }

    /// False partial: packet ends with ESC but next packet is not DCS
    func testFalsePartial_ESCNotFollowedByP() {
        var filter = DCSFilter()
        var packet1 = makeData("hello")
        packet1.append(Data([0x1B])) // ESC at end

        let result1 = filter.process(packet1)
        assertForwardString(result1, "hello")
        XCTAssertFalse(filter.isHooked)

        // Next packet starts with [, not P — this is a CSI sequence, not DCS
        let packet2 = makeData("[31mred text\u{1B}[0m\r\n")
        let result2 = filter.process(packet2)
        // Buffered ESC + new data combined: ESC [31mred text ESC [0m \r\n
        // This should forward to terminal (no DCS found)
        if case .forwardToTerminal(let data) = result2 {
            // The data should be the buffered ESC + packet2
            var expected = Data([0x1B])
            expected.append(makeData("[31mred text\u{1B}[0m\r\n"))
            XCTAssertEqual(data, expected)
        } else {
            XCTFail("Expected .forwardToTerminal, got \(result2)")
        }
        XCTAssertFalse(filter.isHooked)
    }

    /// Partial DCS at end of packet 1, but packet 1 also has terminal data before it
    func testPartialDCS_WithPriorTerminalData() {
        var filter = DCSFilter()
        // "MOTD here\r\n" followed by ESC P 1 (partial DCS)
        var packet1 = makeData("MOTD here\r\n")
        packet1.append(Data([0x1B, 0x50, 0x31])) // ESC P 1

        let result1 = filter.process(packet1)
        assertForwardString(result1, "MOTD here\r\n")
        XCTAssertFalse(filter.isHooked)

        // Complete the DCS: 000p + payload
        let payload = makeBeginEnd()
        var packet2 = Data([0x30, 0x30, 0x30, 0x70]) // 000p
        packet2.append(payload)
        let result2 = filter.process(packet2)
        assertGateway(result2, payload)
        XCTAssertTrue(filter.isHooked)
    }

    // MARK: - isHooked Latch Behavior

    /// Once hooked, all subsequent data routes to gateway
    func testIsHookedLatch_AllSubsequentDataRoutesToGateway() {
        var filter = DCSFilter()
        var packet = dcs
        packet.append(makeBeginEnd())
        _ = filter.process(packet)
        XCTAssertTrue(filter.isHooked)

        // All subsequent data goes to gateway, even if it doesn't contain %
        let randomData = makeData("some random data\r\n")
        let result2 = filter.process(randomData)
        assertGateway(result2, randomData)

        // Even binary data
        let binaryData = Data([0x00, 0xFF, 0x42, 0x13])
        let result3 = filter.process(binaryData)
        assertGateway(result3, binaryData)
    }

    /// Multiple calls after hook all return .routeToGateway
    func testIsHookedLatch_MultipleCallsAfterHook() {
        var filter = DCSFilter()
        var packet = dcs
        packet.append(makeData("%begin 123 1 0\r\n"))
        _ = filter.process(packet)
        XCTAssertTrue(filter.isHooked)

        for i in 0..<10 {
            let data = makeData("%output %\(i) line \(i)\r\n")
            let result = filter.process(data)
            assertGateway(result, data)
        }
    }

    // MARK: - Bare % Control Messages (No DCS)

    /// % at start of data without preceding DCS (split packet scenario)
    func testBareControlMessages_PercentAtStart() {
        var filter = DCSFilter()
        let data = makeData("%begin 1700000000 1 0\r\n%end 1700000000 1 0\r\n")
        let result = filter.process(data)
        assertGateway(result, data)
        XCTAssertTrue(filter.isHooked)
    }

    /// % after newline in data
    func testBareControlMessages_PercentAfterNewline() {
        var filter = DCSFilter()
        let data = makeData("some text\n%session-changed $1 main\r\n")
        let result = filter.process(data)
        assertGateway(result, data)
        XCTAssertTrue(filter.isHooked)
    }

    /// % after carriage return
    func testBareControlMessages_PercentAfterCR() {
        var filter = DCSFilter()
        let data = makeData("some text\r%output %0 hello\r\n")
        let result = filter.process(data)
        assertGateway(result, data)
        XCTAssertTrue(filter.isHooked)
    }

    /// No %, no DCS — plain terminal data
    func testNoControlMessages_PlainTerminalData() {
        var filter = DCSFilter()
        let data = makeData("Welcome to Ubuntu 22.04\r\nLast login: Mon Jan 1 00:00:00\r\n")
        let result = filter.process(data)
        assertForward(result, data)
        XCTAssertFalse(filter.isHooked)
    }

    /// % in middle of word (not a control message)
    func testPercentInMiddleOfWord_NotControlMessage() {
        var filter = DCSFilter()
        let data = makeData("CPU usage: 50% used\r\n")
        let result = filter.process(data)
        assertForward(result, data)
        XCTAssertFalse(filter.isHooked)
    }

    // MARK: - ST Stripping Edge Cases

    /// ST immediately after DCS, no other data
    func testSTAfterDCS_NothingElse() {
        var filter = DCSFilter()
        var packet = dcs
        packet.append(st)

        let result = filter.process(packet)
        assertConsumed(result)
        XCTAssertTrue(filter.isHooked)
    }

    /// Double ST after DCS (only first should be stripped)
    func testDoubleST_OnlyFirstStripped() {
        var filter = DCSFilter()
        let payload = makeBeginEnd()
        var packet = dcs
        packet.append(st)
        packet.append(st) // second ST — should NOT be stripped
        packet.append(payload)

        let result = filter.process(packet)
        // After stripping DCS and first ST, remaining is: second ST + payload
        if case .routeToGateway(let data) = result {
            var expected = st
            expected.append(payload)
            XCTAssertEqual(data, expected)
        } else {
            XCTFail("Expected .routeToGateway, got \(result)")
        }
        XCTAssertTrue(filter.isHooked)
    }

    /// Bare backslash after DCS (not a full ST — needs ESC before backslash)
    func testBareBackslashAfterDCS_NotST() {
        var filter = DCSFilter()
        let payload = makeData("\\%begin 123 1 0\r\n")
        var packet = dcs
        packet.append(payload)

        let result = filter.process(packet)
        // Bare backslash is NOT an ST (needs ESC prefix), so payload is returned as-is
        assertGateway(result, payload)
        XCTAssertTrue(filter.isHooked)
    }

    // MARK: - Alternate DCS Form (\x1bP1000;)

    /// DCS 1000; variant
    func testDCS1000Semicolon() {
        var filter = DCSFilter()
        let altDcs = Data([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x3B]) // ESC P 1 0 0 0 ;
        let payload = makeBeginEnd()
        var packet = altDcs
        packet.append(payload)

        let result = filter.process(packet)
        assertGateway(result, payload)
        XCTAssertTrue(filter.isHooked)
    }

    // MARK: - Empty and Edge Cases

    /// Empty data
    func testEmptyData() {
        var filter = DCSFilter()
        let result = filter.process(Data())
        assertForward(result, Data())
        XCTAssertFalse(filter.isHooked)
    }

    /// Single byte that's not ESC
    func testSingleNonESCByte() {
        var filter = DCSFilter()
        let data = Data([0x41]) // 'A'
        let result = filter.process(data)
        assertForward(result, data)
        XCTAssertFalse(filter.isHooked)
    }

    /// Single ESC byte — should be buffered
    func testSingleESCByte_Buffered() {
        var filter = DCSFilter()
        let result = filter.process(Data([0x1B]))
        assertConsumed(result)
        XCTAssertFalse(filter.isHooked)
    }

    /// DCS sequence that's too short (ESC P 1 0 0 — missing trailing bytes)
    func testIncompleteDCS_NotEnoughBytes() {
        var filter = DCSFilter()
        // ESC P 1 0 0 (5 bytes, need 7 for full DCS)
        // This is a prefix of DCS, so it should be buffered
        let data = Data([0x1B, 0x50, 0x31, 0x30, 0x30])
        let result = filter.process(data)
        assertConsumed(result)
        XCTAssertFalse(filter.isHooked) // not yet detected, just buffered
    }

    /// Non-UTF8 binary data before DCS
    func testBinaryDataBeforeDCS() {
        var filter = DCSFilter()
        let binary = Data([0xFF, 0xFE, 0x00, 0x80])
        let payload = makeBeginEnd()
        var packet = binary
        packet.append(dcs)
        packet.append(payload)

        let result = filter.process(packet)
        // Binary data before DCS is dropped (logged), gateway data returned
        assertGateway(result, payload)
        XCTAssertTrue(filter.isHooked)
    }

    // MARK: - Reset Behavior

    /// New DCSFilter starts with isHooked = false
    func testNewFilterNotHooked() {
        let filter = DCSFilter()
        XCTAssertFalse(filter.isHooked)
    }

    /// Re-creating filter resets state
    func testResetByRecreation() {
        var filter = DCSFilter()
        var packet = dcs
        packet.append(makeBeginEnd())
        _ = filter.process(packet)
        XCTAssertTrue(filter.isHooked)

        // Re-create
        filter = DCSFilter()
        XCTAssertFalse(filter.isHooked)

        // Should forward terminal data again
        let data = makeData("shell output\r\n")
        let result = filter.process(data)
        assertForward(result, data)
    }

    // MARK: - Real-World Scenarios

    /// Simulate the exact sequence seen on device: shell echo → DCS → session-changed → begin/end
    func testRealWorldSequence_DeviceObserved() {
        var filter = DCSFilter()

        // Packet 1: shell echo of the command
        let echo = makeData("exec tmux -CC new-session -A -s geistty-1\r\n")
        let result1 = filter.process(echo)
        assertForward(result1, echo)
        XCTAssertFalse(filter.isHooked)

        // Packet 2: DCS + session-changed (no ST — matches real tmux behavior)
        let sessionChanged = makeData("%session-changed $1 geistty-1\r\n")
        var packet2 = dcs
        packet2.append(sessionChanged)
        let result2 = filter.process(packet2)
        assertGateway(result2, sessionChanged)
        XCTAssertTrue(filter.isHooked)

        // Packet 3: begin/end (pure gateway data)
        let beginEnd = makeBeginEnd()
        let result3 = filter.process(beginEnd)
        assertGateway(result3, beginEnd)
    }

    /// Simulate the exact iTerm2 pattern: DCS directly before %begin, no ST
    func testRealWorldSequence_iTerm2Pattern() {
        var filter = DCSFilter()

        // tmux sends: \x1bP1000p%begin 1700000000 1 0\r\n%end 1700000000 1 0\r\n
        // all in one packet, no ST
        let beginEnd = makeBeginEnd()
        var packet = dcs
        packet.append(beginEnd)

        let result = filter.process(packet)
        assertGateway(result, beginEnd)
        XCTAssertTrue(filter.isHooked)
    }

    /// Simulate worst case: DCS split 1 byte at a time across 7 packets
    func testDCSSplitOneByteAtATime() {
        var filter = DCSFilter()
        let dcsBytes: [UInt8] = [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]

        // Send bytes 0-5 one at a time, each should be consumed (buffered)
        for i in 0..<(dcsBytes.count - 1) {
            let result = filter.process(Data([dcsBytes[i]]))
            assertConsumed(result)
            XCTAssertFalse(filter.isHooked, "Should not be hooked after byte \(i)")
        }

        // Send final byte 'p' followed by gateway data
        let payload = makeBeginEnd()
        var finalPacket = Data([dcsBytes[dcsBytes.count - 1]])
        finalPacket.append(payload)
        let result = filter.process(finalPacket)
        assertGateway(result, payload)
        XCTAssertTrue(filter.isHooked)
    }

    /// Multi-packet flow with interleaved terminal and gateway data
    func testMultiPacketFlow_MixedData() {
        var filter = DCSFilter()

        // Packet 1: MOTD / banner
        let motd = makeData("Welcome to Dionysus\r\nLast login: Mon Jan 1 00:00:00\r\n")
        let r1 = filter.process(motd)
        assertForward(r1, motd)
        XCTAssertFalse(filter.isHooked)

        // Packet 2: More shell output
        let prompt = makeData("user@dionysus:~$ ")
        let r2 = filter.process(prompt)
        assertForward(r2, prompt)
        XCTAssertFalse(filter.isHooked)

        // Packet 3: DCS arrives (tmux starts control mode)
        var packet3 = dcs
        packet3.append(makeData("%begin 100 1 0\r\n"))
        let r3 = filter.process(packet3)
        assertGatewayString(r3, "%begin 100 1 0\r\n")
        XCTAssertTrue(filter.isHooked)

        // Packet 4+: All gateway data
        let output = makeData("%output %2 hello world\r\n")
        let r4 = filter.process(output)
        assertGateway(r4, output)
    }

    /// Test that the DCS at exact start of data works
    func testDCSAtExactStart() {
        var filter = DCSFilter()
        let payload = makeData("%session-changed $1 test\r\n")
        var packet = dcs
        packet.append(payload)

        let result = filter.process(packet)
        assertGateway(result, payload)
        XCTAssertTrue(filter.isHooked)
    }

    /// Session discovery interleaved — list-sessions output, then DCS
    func testSessionDiscoveryThenDCS() {
        var filter = DCSFilter()

        // Packet 1: output from `tmux list-sessions` (forwarded to terminal / discovery parser)
        let listOutput = makeData("geistty-1: 1 windows (created Mon Jan 1 00:00:00 2026) (attached)\r\nshellfish-1: 1 windows (created Mon Jan 1 00:00:00 2026) (attached)\r\n---END---\r\n")
        let r1 = filter.process(listOutput)
        assertForward(r1, listOutput)
        XCTAssertFalse(filter.isHooked)

        // Packet 2: exec tmux -CC echo
        let echo = makeData("exec tmux -CC new-session -A -s geistty-2\r\n")
        let r2 = filter.process(echo)
        assertForward(r2, echo)
        XCTAssertFalse(filter.isHooked)

        // Packet 3: DCS + session-changed
        let sessionChanged = makeData("%session-changed $2 geistty-2\r\n")
        var packet3 = dcs
        packet3.append(sessionChanged)
        let r3 = filter.process(packet3)
        assertGateway(r3, sessionChanged)
        XCTAssertTrue(filter.isHooked)
    }

    // MARK: - Data.findSubsequence Tests

    /// Pattern at start of data
    func testFindSubsequence_AtStart() {
        let data = Data([0x1B, 0x50, 0x31, 0x30, 0x41, 0x42])
        let pattern: [UInt8] = [0x1B, 0x50, 0x31]
        XCTAssertEqual(data.findSubsequence(pattern), 0)
    }

    /// Pattern in middle of data
    func testFindSubsequence_InMiddle() {
        let data = Data([0x41, 0x42, 0x1B, 0x50, 0x31, 0x30])
        let pattern: [UInt8] = [0x1B, 0x50, 0x31]
        XCTAssertEqual(data.findSubsequence(pattern), 2)
    }

    /// Pattern at end of data
    func testFindSubsequence_AtEnd() {
        let data = Data([0x41, 0x42, 0x43, 0x1B, 0x50])
        let pattern: [UInt8] = [0x1B, 0x50]
        XCTAssertEqual(data.findSubsequence(pattern), 3)
    }

    /// Pattern not found
    func testFindSubsequence_NotFound() {
        let data = Data([0x41, 0x42, 0x43])
        let pattern: [UInt8] = [0x1B, 0x50]
        XCTAssertNil(data.findSubsequence(pattern))
    }

    /// Pattern equals entire data
    func testFindSubsequence_ExactMatch() {
        let data = Data([0x1B, 0x50, 0x31])
        let pattern: [UInt8] = [0x1B, 0x50, 0x31]
        XCTAssertEqual(data.findSubsequence(pattern), 0)
    }

    /// Pattern longer than data
    func testFindSubsequence_PatternTooLong() {
        let data = Data([0x1B])
        let pattern: [UInt8] = [0x1B, 0x50, 0x31, 0x30]
        XCTAssertNil(data.findSubsequence(pattern))
    }

    /// Empty pattern
    func testFindSubsequence_EmptyPattern() {
        let data = Data([0x41, 0x42])
        let pattern: [UInt8] = []
        // Empty pattern should match at position 0
        XCTAssertEqual(data.findSubsequence(pattern), 0)
    }

    /// Empty data with non-empty pattern
    func testFindSubsequence_EmptyData() {
        let data = Data()
        let pattern: [UInt8] = [0x1B]
        XCTAssertNil(data.findSubsequence(pattern))
    }

    /// First occurrence when pattern appears multiple times
    func testFindSubsequence_MultipleOccurrences() {
        let data = Data([0x1B, 0x50, 0x41, 0x1B, 0x50, 0x42])
        let pattern: [UInt8] = [0x1B, 0x50]
        XCTAssertEqual(data.findSubsequence(pattern), 0)
    }

    /// Single byte pattern
    func testFindSubsequence_SingleByte() {
        let data = Data([0x41, 0x42, 0x43])
        XCTAssertEqual(data.findSubsequence([0x42]), 1)
    }

    // MARK: - Equatable Conformance

    /// DCSFilterResult equality — forwardToTerminal
    func testResultEquality_ForwardToTerminal() {
        let a = DCSFilterResult.forwardToTerminal(Data([0x41]))
        let b = DCSFilterResult.forwardToTerminal(Data([0x41]))
        let c = DCSFilterResult.forwardToTerminal(Data([0x42]))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    /// DCSFilterResult equality — routeToGateway
    func testResultEquality_RouteToGateway() {
        let a = DCSFilterResult.routeToGateway(Data([0x41]))
        let b = DCSFilterResult.routeToGateway(Data([0x41]))
        XCTAssertEqual(a, b)
    }

    /// DCSFilterResult equality — consumed
    func testResultEquality_Consumed() {
        XCTAssertEqual(DCSFilterResult.consumed, DCSFilterResult.consumed)
    }

    /// DCSFilterResult inequality across cases
    func testResultInequality_DifferentCases() {
        let data = Data([0x41])
        XCTAssertNotEqual(DCSFilterResult.forwardToTerminal(data), DCSFilterResult.routeToGateway(data))
        XCTAssertNotEqual(DCSFilterResult.forwardToTerminal(data), DCSFilterResult.consumed)
        XCTAssertNotEqual(DCSFilterResult.routeToGateway(data), DCSFilterResult.consumed)
    }

    // MARK: - Stress / Boundary Tests

    /// Large data with DCS buried in the middle
    func testLargDataWithDCSInMiddle() {
        var filter = DCSFilter()
        let before = Data(repeating: 0x41, count: 4096) // 4KB of 'A'
        let payload = makeBeginEnd()
        var packet = before
        packet.append(dcs)
        packet.append(payload)

        let result = filter.process(packet)
        assertGateway(result, payload)
        XCTAssertTrue(filter.isHooked)
    }

    /// DCS followed by large gateway payload
    func testDCSFollowedByLargePayload() {
        var filter = DCSFilter()
        var payload = Data()
        for i in 0..<100 {
            payload.append(makeData("%output %2 line \(i) of output data\r\n"))
        }
        var packet = dcs
        packet.append(payload)

        let result = filter.process(packet)
        assertGateway(result, payload)
        XCTAssertTrue(filter.isHooked)
    }

    /// Packet that looks like DCS but has wrong intermediate bytes
    func testFalseDCS_WrongBytes() {
        var filter = DCSFilter()
        // ESC P 2 0 0 0 p — not 1000p
        let falseDcs = Data([0x1B, 0x50, 0x32, 0x30, 0x30, 0x30, 0x70])
        let result = filter.process(falseDcs)
        assertForward(result, falseDcs)
        XCTAssertFalse(filter.isHooked)
    }

    /// ESC P 1 0 0 0 followed by wrong final byte
    func testFalseDCS_WrongFinalByte() {
        var filter = DCSFilter()
        // ESC P 1 0 0 0 q — 'q' instead of 'p'
        let falseDcs = Data([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x71])
        let result = filter.process(falseDcs)
        assertForward(result, falseDcs)
        XCTAssertFalse(filter.isHooked)
    }

    /// Multiple DCS in same packet (shouldn't happen, but test robustness)
    func testMultipleDCSInSamePacket() {
        var filter = DCSFilter()
        let payload1 = makeData("%begin 100 1 0\r\n%end 100 1 0\r\n")
        let payload2 = makeData("%begin 200 1 0\r\n%end 200 1 0\r\n")
        var packet = dcs
        packet.append(payload1)
        packet.append(dcs) // second DCS embedded
        packet.append(payload2)

        let result = filter.process(packet)
        // First DCS is found, everything after it is gateway data
        // (including the second DCS bytes, which the gateway will just see as data)
        if case .routeToGateway(let data) = result {
            var expected = payload1
            expected.append(dcs)
            expected.append(payload2)
            XCTAssertEqual(data, expected)
        } else {
            XCTFail("Expected .routeToGateway")
        }
        XCTAssertTrue(filter.isHooked)
    }
}
