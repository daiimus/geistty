//
//  TmuxWireDiagnosticsTests.swift
//  GeisttyTests
//
//  Tests for the tmux control mode wire diagnostics shadow parser.
//  Validates octal unescaping, %output parsing, escape sequence validation,
//  and anomaly detection using both synthetic data and cmatrix-style output.
//

import XCTest
@testable import Geistty

@MainActor final class TmuxWireDiagnosticsTests: XCTestCase {
    
    var diag: TmuxWireDiagnostics!
    
    override func setUp() {
        super.setUp()
        diag = TmuxWireDiagnostics()
        diag.start()
    }
    
    override func tearDown() {
        diag.stop()
        diag = nil
        super.tearDown()
    }
    
    // MARK: - Octal Unescaping
    
    func testUnescapeOctalPassthrough() {
        let result = TmuxWireDiagnostics.unescapeOctal("hello world")
        XCTAssertEqual(result, Array("hello world".utf8))
    }
    
    func testUnescapeOctalESC() {
        // \033 = ESC (0x1B)
        let result = TmuxWireDiagnostics.unescapeOctal("\\033")
        XCTAssertEqual(result, [0x1B])
    }
    
    func testUnescapeOctalCRLF() {
        // \015\012 = CR LF
        let result = TmuxWireDiagnostics.unescapeOctal("\\015\\012")
        XCTAssertEqual(result, [0x0D, 0x0A])
    }
    
    func testUnescapeOctalBackslash() {
        // \134 = backslash
        let result = TmuxWireDiagnostics.unescapeOctal("\\134")
        XCTAssertEqual(result, [0x5C]) // '\'
    }
    
    func testUnescapeOctalMixed() {
        // "hello\033[31mworld"
        let result = TmuxWireDiagnostics.unescapeOctal("hello\\033[31mworld")
        XCTAssertEqual(result.count, 15)
        XCTAssertEqual(Array(result[0..<5]), Array("hello".utf8))
        XCTAssertEqual(result[5], 0x1B) // ESC
        XCTAssertEqual(Array(result[6...]), Array("[31mworld".utf8))
    }
    
    func testUnescapeOctalMultipleESC() {
        // \033\033 = ESC ESC
        let result = TmuxWireDiagnostics.unescapeOctal("\\033\\033")
        XCTAssertEqual(result, [0x1B, 0x1B])
    }
    
    func testUnescapeOctalTrailingBackslash() {
        let result = TmuxWireDiagnostics.unescapeOctal("abc\\")
        XCTAssertEqual(result, Array("abc\\".utf8))
    }
    
    func testUnescapeOctalNonOctalDigits() {
        // \8 is not octal
        let result = TmuxWireDiagnostics.unescapeOctal("\\899")
        XCTAssertEqual(result, Array("\\899".utf8))
    }
    
    func testUnescapeOctalBackspace() {
        // \010ls = BS + "ls" (seen in device logs)
        let result = TmuxWireDiagnostics.unescapeOctal("\\010ls")
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0], 0x08) // BS
        XCTAssertEqual(Array(result[1...]), Array("ls".utf8))
    }
    
    func testUnescapeOctalMatchesZig() {
        // Comprehensive test matching all the Zig control.zig test cases
        // to ensure our Swift shadow parser produces identical results
        
        // ESC [ 3 2 m (green SGR)
        let green = TmuxWireDiagnostics.unescapeOctal("\\033[32m")
        XCTAssertEqual(green, [0x1B, 0x5B, 0x33, 0x32, 0x6D])
        
        // ESC [ 0 m (reset SGR)
        let reset = TmuxWireDiagnostics.unescapeOctal("\\033[0m")
        XCTAssertEqual(reset, [0x1B, 0x5B, 0x30, 0x6D])
        
        // ESC [ 3 8 ; 2 ; 255 ; 0 ; 128 m (24-bit color)
        let truecolor = TmuxWireDiagnostics.unescapeOctal("\\033[38;2;255;0;128m")
        XCTAssertEqual(truecolor[0], 0x1B)
        XCTAssertEqual(truecolor[1], 0x5B) // [
        // Rest is ASCII params + m
        let paramStr = String(bytes: Array(truecolor[2...]), encoding: .utf8)
        XCTAssertEqual(paramStr, "38;2;255;0;128m")
    }
    
    // MARK: - %output Line Parsing
    
    func testValidOutputLine() {
        let line = "%output %2 hello\\033[31mworld\n"
        diag.analyze(Data(line.utf8))
        
        XCTAssertEqual(diag.totalOutputLines, 1)
        XCTAssertEqual(diag.totalAnomalies, 0)
    }
    
    func testOutputWithMultipleSGR() {
        // Typical cmatrix-style output: lots of SGR color changes
        let line = "%output %0 \\033[32m|\\033[0m \\033[32m/\\033[0m\n"
        diag.analyze(Data(line.utf8))
        
        XCTAssertEqual(diag.totalOutputLines, 1)
        XCTAssertEqual(diag.totalAnomalies, 0)
    }
    
    func testMalformedOutputNoSpace() {
        let line = "%output%2 hello\n"
        diag.analyze(Data(line.utf8))
        
        let malformed = diag.events.filter {
            if case .malformedOutput = $0.kind { return true }
            return false
        }
        XCTAssertEqual(malformed.count, 1)
    }
    
    func testMalformedOutputNoPaneId() {
        let line = "%output % hello\n"
        diag.analyze(Data(line.utf8))
        
        let malformed = diag.events.filter {
            if case .malformedOutput = $0.kind { return true }
            return false
        }
        XCTAssertEqual(malformed.count, 1)
    }
    
    // MARK: - Orphaned SGR Detection
    
    func testOrphanedSGRDetection() {
        // "32m" without preceding ESC[ — this IS the artifact the user sees
        // In the wire format, this would mean the \033 and/or [ got lost
        let line = "%output %0 32mHello\n"
        diag.analyze(Data(line.utf8))
        
        let orphans = diag.events.filter {
            if case .orphanedSGR = $0.kind { return true }
            return false
        }
        XCTAssertEqual(orphans.count, 1)
        if case .orphanedSGR(let paneId, let fragment, _) = orphans.first?.kind {
            XCTAssertEqual(paneId, 0)
            XCTAssertEqual(fragment, "32m")
        }
    }
    
    func testOrphanedSGRWithBracket() {
        // "[32m" — ESC got lost but bracket survived
        // On the wire this would look like data without \033 before the [
        let line = "%output %0 [32mHello\n"
        diag.analyze(Data(line.utf8))
        
        // The [ prevents orphan detection since we check for [ preceding
        // So this is actually a different kind of problem — bare [
        // Let's verify our validator handles this correctly
        XCTAssertEqual(diag.totalOutputLines, 1)
    }
    
    func testValidSGRNotOrphaned() {
        // Properly escaped ESC [ 32 m — should NOT trigger orphaned SGR
        let line = "%output %0 \\033[32mHello\\033[0m\n"
        diag.analyze(Data(line.utf8))
        
        let orphans = diag.events.filter {
            if case .orphanedSGR = $0.kind { return true }
            return false
        }
        XCTAssertEqual(orphans.count, 0)
        XCTAssertEqual(diag.totalAnomalies, 0)
    }
    
    func testMultipleOrphanedSGRFragments() {
        // Multiple fragments as the user reported: "32m", "2m", "9m"
        let line = "%output %0 32mHello 2mWorld 9mFoo\n"
        diag.analyze(Data(line.utf8))
        
        let orphans = diag.events.filter {
            if case .orphanedSGR = $0.kind { return true }
            return false
        }
        XCTAssertEqual(orphans.count, 3)
    }
    
    // MARK: - Incomplete Octal Detection
    
    func testIncompleteOctalTwoDigits() {
        // \03 instead of \033 — only 2 octal digits
        let line = "%output %0 \\03[32m\n"
        diag.analyze(Data(line.utf8))
        
        let incomplete = diag.events.filter {
            if case .incompleteOctal = $0.kind { return true }
            return false
        }
        XCTAssertEqual(incomplete.count, 1)
    }
    
    func testIncompleteOctalOneDigit() {
        // \0 followed by non-octal — only 1 octal digit
        let line = "%output %0 \\0x32m\n"
        diag.analyze(Data(line.utf8))
        
        let incomplete = diag.events.filter {
            if case .incompleteOctal = $0.kind { return true }
            return false
        }
        XCTAssertEqual(incomplete.count, 1)
    }
    
    func testCompleteOctalNotFlagged() {
        let line = "%output %0 \\033[32m\n"
        diag.analyze(Data(line.utf8))
        
        let incomplete = diag.events.filter {
            if case .incompleteOctal = $0.kind { return true }
            return false
        }
        XCTAssertEqual(incomplete.count, 0)
    }
    
    // MARK: - UTF-8 Validation
    
    func testValidUTF8() {
        // Box-drawing character (UTF-8: E2 94 80) — common in tmux borders
        let line = "%output %0 \\033[32m\\342\\224\\200\n"
        diag.analyze(Data(line.utf8))
        
        let utf8Errors = diag.events.filter {
            if case .invalidUTF8 = $0.kind { return true }
            return false
        }
        XCTAssertEqual(utf8Errors.count, 0)
    }
    
    func testInvalidUTF8TruncatedSequence() {
        // Only 2 bytes of a 3-byte sequence (E2 94 without 80)
        // This simulates what blightmud artifacts might look like
        let line = "%output %0 \\342\\224\n"
        diag.analyze(Data(line.utf8))
        
        let utf8Errors = diag.events.filter {
            if case .invalidUTF8 = $0.kind { return true }
            return false
        }
        XCTAssertGreaterThan(utf8Errors.count, 0)
    }
    
    func testInvalidUTF8HighByteAlone() {
        // 0x80 alone is not valid UTF-8
        let line = "%output %0 \\200\n"
        diag.analyze(Data(line.utf8))
        
        let utf8Errors = diag.events.filter {
            if case .invalidUTF8 = $0.kind { return true }
            return false
        }
        XCTAssertGreaterThan(utf8Errors.count, 0)
    }
    
    // MARK: - Block Handling
    
    func testBeginEndBlockIgnored() {
        let data = "%begin 1578922740 269 1\nhello\nworld\n%end 1578922740 269 1\n"
        diag.analyze(Data(data.utf8))
        
        // Block content should not generate anomalies
        XCTAssertEqual(diag.totalAnomalies, 0)
        XCTAssertEqual(diag.totalOutputLines, 0)
    }
    
    func testOutputAfterBlock() {
        let data = "%begin 1578922740 269 1\ndata\n%end 1578922740 269 1\n%output %0 \\033[0mhi\n"
        diag.analyze(Data(data.utf8))
        
        XCTAssertEqual(diag.totalOutputLines, 1)
        XCTAssertEqual(diag.totalAnomalies, 0)
    }
    
    // MARK: - Notification Handling
    
    func testKnownNotifications() {
        let data = [
            "%session-changed $1 default\n",
            "%sessions-changed\n",
            "%layout-change @0 80x24,0,0 80x24,0,0 *\n",
            "%window-add @1\n",
            "%window-renamed @0 bash\n",
            "%window-pane-changed @0 %1\n",
            "%window-close @1\n",
            "%exit\n",
        ].joined()
        
        diag.analyze(Data(data.utf8))
        
        let unknowns = diag.events.filter {
            if case .unknownNotification = $0.kind { return true }
            return false
        }
        XCTAssertEqual(unknowns.count, 0)
    }
    
    func testUnknownNotification() {
        let data = "%some-future-notification data\n"
        diag.analyze(Data(data.utf8))
        
        let unknowns = diag.events.filter {
            if case .unknownNotification = $0.kind { return true }
            return false
        }
        XCTAssertEqual(unknowns.count, 1)
    }
    
    // MARK: - Chunk Boundary Handling
    
    func testOutputSplitAcrossChunks() {
        // A single %output line split across two SSH data chunks
        let chunk1 = Data("%output %0 \\033[32m".utf8)
        let chunk2 = Data("Hello\\033[0m\n".utf8)
        
        diag.analyze(chunk1)
        XCTAssertEqual(diag.totalOutputLines, 0) // Not complete yet
        
        diag.analyze(chunk2)
        XCTAssertEqual(diag.totalOutputLines, 1) // Now complete
        XCTAssertEqual(diag.totalAnomalies, 0)
    }
    
    func testMultipleOutputsInOneChunk() {
        let data = "%output %0 \\033[32mA\\033[0m\n%output %0 \\033[31mB\\033[0m\n"
        diag.analyze(Data(data.utf8))
        
        XCTAssertEqual(diag.totalOutputLines, 2)
        XCTAssertEqual(diag.totalAnomalies, 0)
    }
    
    // MARK: - cmatrix-Style Test Data
    
    func testCmatrixTypicalOutput() {
        // cmatrix uses CSI sequences for cursor positioning and green color
        // Typical output: move cursor + set color + print char + reset
        let lines = [
            // Cursor move + green + char
            "%output %0 \\033[5;12H\\033[32m|\\033[0m\n",
            // Bold green
            "%output %0 \\033[1;32m/\\033[0m\n",
            // Dim green
            "%output %0 \\033[2;32m.\\033[0m\n",
            // Cursor home + clear
            "%output %0 \\033[H\\033[2J\n",
        ]
        
        for line in lines {
            diag.analyze(Data(line.utf8))
        }
        
        XCTAssertEqual(diag.totalOutputLines, 4)
        XCTAssertEqual(diag.totalAnomalies, 0)
    }
    
    func testCmatrixCorruptedOutput() {
        // What the artifacts look like: ESC is missing from SGR sequences
        // Instead of \033[32m, just "32m" appears as literal text
        let lines = [
            // Missing ESC — "32m" is literal text (the artifact!)
            "%output %0 32m|\n",
            // Missing ESC and bracket — "2m" literal
            "%output %0 2mworld\n",
            // Partial: bracket present but no ESC
            "%output %0 [32mhello\n",
        ]
        
        for line in lines {
            diag.analyze(Data(line.utf8))
        }
        
        XCTAssertEqual(diag.totalOutputLines, 3)
        // First two should be detected as orphaned SGR
        let orphans = diag.events.filter {
            if case .orphanedSGR = $0.kind { return true }
            return false
        }
        XCTAssertGreaterThanOrEqual(orphans.count, 2)
    }
    
    func testCmatrixProperlyEscaped() {
        // The CORRECT wire format for cmatrix green output:
        // tmux octal-escapes ESC as \033, so we should see \033 in the wire data
        let line = "%output %0 \\033[32m|\\033[0m \\033[1;32m/\\033[0m \\033[2;32m.\\033[0m\n"
        diag.analyze(Data(line.utf8))
        
        XCTAssertEqual(diag.totalOutputLines, 1)
        XCTAssertEqual(diag.totalAnomalies, 0,
                       "Properly escaped cmatrix output should have zero anomalies")
    }
    
    // MARK: - Wire Data Where ESC Was Not Octal-Escaped
    
    func testRawESCInWireData() {
        // If tmux somehow sent raw ESC (0x1B) instead of \033,
        // it would appear as a literal byte in the SSH stream.
        // Our line buffering would handle this since ESC is not \n.
        // The %output regex in control.zig should still match.
        // But our unescapeOctal would not need to decode it — it's already raw.
        var data = Data("%output %0 ".utf8)
        data.append(0x1B) // raw ESC byte
        data.append(contentsOf: "[32mHello".utf8)
        data.append(0x0A) // newline
        
        diag.analyze(data)
        
        // This should parse fine — the ESC is already a real byte
        // Our validator should see ESC followed by [ and be happy
        XCTAssertEqual(diag.totalOutputLines, 1)
        // Raw ESC in %output data means tmux DIDN'T octal-escape it.
        // This would be a tmux bug. Our shadow parser should notice
        // that the raw wire data has a byte < 0x20 that wasn't escaped.
        // For now we don't flag this — we just validate the unescaped result.
    }
    
    // MARK: - Blightmud-Style Test Data
    
    func testBlightmudBoxDrawing() {
        // Blightmud uses box-drawing characters (UTF-8 multi-byte)
        // ─ = U+2500 = E2 94 80
        // │ = U+2502 = E2 94 82
        // ┌ = U+250C = E2 94 8C
        // In tmux %output, bytes >= 0x20 pass through without escaping,
        // so these appear as raw UTF-8 bytes (not octal-escaped).
        // BUT bytes < 0x20 like ESC are still escaped.
        
        // Wire format: cursor pos + box char (raw UTF-8)
        var line = Data("%output %1 \\033[1;1H".utf8)
        line.append(contentsOf: [0xE2, 0x94, 0x8C]) // ┌
        line.append(contentsOf: [0xE2, 0x94, 0x80]) // ─
        line.append(contentsOf: [0xE2, 0x94, 0x80]) // ─
        line.append(0x0A) // newline
        
        diag.analyze(line)
        
        XCTAssertEqual(diag.totalOutputLines, 1)
        XCTAssertEqual(diag.totalAnomalies, 0,
                       "Valid UTF-8 box drawing should not trigger anomalies")
    }
    
    func testBlightmudCorruptedBoxDrawing() {
        // Corrupted: middle byte of 3-byte sequence is missing
        // E2 80 instead of E2 94 80 — not valid for the expected char
        // Or worse: E2 without continuation bytes
        var line = Data("%output %1 ".utf8)
        line.append(contentsOf: [0xE2]) // Start of 3-byte seq
        // Missing continuation bytes — next is ASCII
        line.append(contentsOf: "hello".utf8)
        line.append(0x0A)
        
        diag.analyze(line)
        
        let utf8Errors = diag.events.filter {
            if case .invalidUTF8 = $0.kind { return true }
            return false
        }
        XCTAssertGreaterThan(utf8Errors.count, 0)
    }
    
    // MARK: - Statistics
    
    func testStatisticsAccumulate() {
        let data = "%output %0 \\033[32mA\n%output %0 \\033[31mB\n%output %0 32mC\n"
        diag.analyze(Data(data.utf8))
        
        XCTAssertEqual(diag.totalOutputLines, 3)
        XCTAssertEqual(diag.totalBytesAnalyzed, UInt64(data.utf8.count))
        XCTAssertGreaterThan(diag.totalAnomalies, 0) // "32mC" is orphaned
    }
    
    func testSummaryString() {
        let data = "%output %0 \\033[32mA\n"
        diag.analyze(Data(data.utf8))
        
        let summary = diag.summary()
        XCTAssertTrue(summary.contains("Wire:"))
        XCTAssertTrue(summary.contains("outputs"))
    }
    
    // MARK: - Edge Cases
    
    func testEmptyData() {
        diag.analyze(Data())
        XCTAssertEqual(diag.totalBytesAnalyzed, 0)
        XCTAssertEqual(diag.events.count, 0)
    }
    
    func testNotActiveIgnoresData() {
        diag.stop()
        diag.analyze(Data("%output %0 hello\n".utf8))
        XCTAssertEqual(diag.totalBytesAnalyzed, 0)
    }
    
    func testMaxEventsCapped() {
        diag.maxEvents = 5
        for i in 0..<10 {
            let line = "%output %0 \(i)mOrphan\n"
            diag.analyze(Data(line.utf8))
        }
        XCTAssertLessThanOrEqual(diag.events.count, 5)
    }
    
    func testCarriageReturnStripped() {
        let line = "%output %0 \\033[0mHello\r\n"
        diag.analyze(Data(line.utf8))
        
        XCTAssertEqual(diag.totalOutputLines, 1)
        XCTAssertEqual(diag.totalAnomalies, 0)
    }
    
    // MARK: - Realistic Multi-Line Session
    
    func testRealisticTmuxSession() {
        // Simulates a real tmux control mode session startup + cmatrix output
        let session = [
            // Session start
            "%begin 1707000000 42 1\n",
            "\n",
            "%end 1707000000 42 1\n",
            // Layout notification
            "%layout-change @0 80x24,0,0,0 80x24,0,0,0 *\n",
            // Initial prompt output
            "%output %0 \\033[0m$ \n",
            // User runs cmatrix, we get rapid output
            "%output %0 \\033[?1049h\\033[H\\033[2J\n", // alt screen + clear
            "%output %0 \\033[32m|\\033[0m\\033[2;5H\\033[1;32m/\\033[0m\n",
            "%output %0 \\033[3;10H\\033[32m.\\033[0m\\033[4;15H\\033[2;32m,\\033[0m\n",
            // Window rename from cmatrix
            "%window-renamed @0 cmatrix\n",
            // More output
            "%output %0 \\033[5;20H\\033[32m|\\033[0m\n",
        ].joined()
        
        diag.analyze(Data(session.utf8))
        
        XCTAssertEqual(diag.totalOutputLines, 5)
        XCTAssertEqual(diag.totalAnomalies, 0,
                       "A properly formatted tmux session should have zero anomalies")
    }
    
    func testRealisticCorruptedSession() {
        // Same session but with the artifacts we're seeing
        let session = [
            "%begin 1707000000 42 1\n",
            "\n",
            "%end 1707000000 42 1\n",
            "%layout-change @0 80x24,0,0,0 80x24,0,0,0 *\n",
            "%output %0 \\033[0m$ \n",
            // CORRUPTED: ESC missing from some sequences
            "%output %0 \\033[?1049h\\033[H\\033[2J\n", // This one is fine
            "%output %0 32m|\\033[0m\\033[2;5H\\033[1;32m/\\033[0m\n", // "32m" orphaned!
            "%output %0 \\033[3;10H\\033[32m.\\033[0m\\033[4;15H2m,\\033[0m\n", // "2m" orphaned!
            "%window-renamed @0 cmatrix\n",
            "%output %0 \\033[5;20H[32m|\\033[0m\n", // "[32m" — bracket without ESC
        ].joined()
        
        diag.analyze(Data(session.utf8))
        
        XCTAssertEqual(diag.totalOutputLines, 5)
        XCTAssertGreaterThanOrEqual(diag.totalAnomalies, 2,
                                    "Corrupted session should detect orphaned SGR fragments")
        
        // Verify specific orphaned fragments were detected
        let orphans = diag.events.filter {
            if case .orphanedSGR = $0.kind { return true }
            return false
        }
        XCTAssertGreaterThanOrEqual(orphans.count, 2)
    }
}

// MARK: - Octal Escaping Roundtrip Tests

extension TmuxWireDiagnosticsTests {
    
    /// Simulate what tmux's control_append_data() does — escape bytes < 0x20 and backslash
    static func tmuxOctalEscape(_ bytes: [UInt8]) -> String {
        var result = ""
        for byte in bytes {
            if byte < 0x20 || byte == 0x5C { // < space or backslash
                result += String(format: "\\%03o", byte)
            } else {
                result += String(UnicodeScalar(byte))
            }
        }
        return result
    }
    
    func testRoundtripESC() {
        let original: [UInt8] = [0x1B, 0x5B, 0x33, 0x32, 0x6D] // ESC[32m
        let escaped = Self.tmuxOctalEscape(original)
        XCTAssertEqual(escaped, "\\033[32m")
        
        let unescaped = TmuxWireDiagnostics.unescapeOctal(escaped)
        XCTAssertEqual(unescaped, original)
    }
    
    func testRoundtripMixed() {
        // "Hello" + ESC[31m + "World" + CR + LF
        let original: [UInt8] = Array("Hello".utf8) + [0x1B, 0x5B, 0x33, 0x31, 0x6D] + Array("World".utf8) + [0x0D, 0x0A]
        let escaped = Self.tmuxOctalEscape(original)
        let unescaped = TmuxWireDiagnostics.unescapeOctal(escaped)
        XCTAssertEqual(unescaped, original)
    }
    
    func testRoundtripAllControlChars() {
        // Every byte from 0x00 to 0x1F should roundtrip
        var original: [UInt8] = []
        for byte in UInt8(0)...UInt8(0x1F) {
            original.append(byte)
        }
        let escaped = Self.tmuxOctalEscape(original)
        let unescaped = TmuxWireDiagnostics.unescapeOctal(escaped)
        XCTAssertEqual(unescaped, original)
    }
    
    func testRoundtripBackslash() {
        let original: [UInt8] = [0x5C] // backslash
        let escaped = Self.tmuxOctalEscape(original)
        XCTAssertEqual(escaped, "\\134")
        
        let unescaped = TmuxWireDiagnostics.unescapeOctal(escaped)
        XCTAssertEqual(unescaped, original)
    }
}
