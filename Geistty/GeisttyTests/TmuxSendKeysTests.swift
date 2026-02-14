import XCTest
@testable import Geistty

// MARK: - TmuxSendKeys Tests

final class TmuxSendKeysTests: XCTestCase {

    // MARK: - Helpers

    /// Convert wrap() output to a String for easier assertion.
    private func wrapped(_ bytes: [UInt8], paneId: Int = 2) -> String? {
        guard let data = TmuxSendKeys.wrap(Data(bytes), paneId: paneId) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Convenience: wrap a UTF-8 string.
    private func wrapped(_ string: String, paneId: Int = 2) -> String? {
        guard let data = TmuxSendKeys.wrap(Data(string.utf8), paneId: paneId) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Empty Input

    func testEmptyDataReturnsNil() {
        XCTAssertNil(TmuxSendKeys.wrap(Data(), paneId: 2))
    }

    // MARK: - Literal-Safe Characters

    func testAlphanumericLiteral() {
        let result = wrapped("ls")
        XCTAssertEqual(result, "send -lt %2 'ls'\n")
    }

    func testUppercaseLiteral() {
        let result = wrapped("ABC")
        XCTAssertEqual(result, "send -lt %2 'ABC'\n")
    }

    func testDigitsLiteral() {
        let result = wrapped("123")
        XCTAssertEqual(result, "send -lt %2 '123'\n")
    }

    func testSafeSpecialCharsLiteral() {
        // iTerm2's safe set: + / ) : , _ .
        let result = wrapped("+/):,_.")
        XCTAssertEqual(result, "send -lt %2 '+/):,_.'\n")
    }

    func testMixedAlphanumericAndSafeSpecial() {
        let result = wrapped("file_name.txt")
        XCTAssertEqual(result, "send -lt %2 'file_name.txt'\n")
    }

    // MARK: - Hex-Encoded Characters

    func testCarriageReturnHex() {
        // \r = 0x0d
        let result = wrapped([0x0D])
        XCTAssertEqual(result, "send -t %2 0x0d\n")
    }

    func testEscapeHex() {
        // ESC = 0x1b
        let result = wrapped([0x1B])
        XCTAssertEqual(result, "send -t %2 0x1b\n")
    }

    func testBackspaceHex() {
        // BS = 0x08
        let result = wrapped([0x08])
        XCTAssertEqual(result, "send -t %2 0x08\n")
    }

    func testTabHex() {
        // TAB = 0x09
        let result = wrapped([0x09])
        XCTAssertEqual(result, "send -t %2 0x09\n")
    }

    func testSpaceIsHex() {
        // Space = 0x20 — NOT in the literal-safe set
        let result = wrapped(" ")
        XCTAssertEqual(result, "send -t %2 0x20\n")
    }

    func testNullByteHex() {
        let result = wrapped([0x00])
        XCTAssertEqual(result, "send -t %2 0x00\n")
    }

    // MARK: - Mixed Input (Literal + Hex)

    func testCommandWithCR() {
        // "ls\r" — "ls" is literal, \r is hex
        let result = wrapped([0x6C, 0x73, 0x0D]) // l, s, CR
        XCTAssertEqual(result, "send -lt %2 'ls' ; send -t %2 0x0d\n")
    }

    func testCommandWithSpaces() {
        // "ls -alf" — "ls" literal, space hex, "-alf" has '-' as hex then "alf" literal
        // '-' = 0x2D, not in safe set
        let result = wrapped("ls -alf")
        XCTAssertEqual(result, "send -lt %2 'ls' ; send -t %2 0x20 ; send -t %2 0x2d ; send -lt %2 'alf'\n")
    }

    func testCommandWithSpaceAndCR() {
        // "ls\r" with a space: "ls -l\r"
        let bytes: [UInt8] = [0x6C, 0x73, 0x20, 0x2D, 0x6C, 0x0D] // l, s, space, -, l, CR
        let result = wrapped(bytes)
        XCTAssertEqual(result, "send -lt %2 'ls' ; send -t %2 0x20 ; send -t %2 0x2d ; send -lt %2 'l' ; send -t %2 0x0d\n")
    }

    // MARK: - Single Quote Escaping

    func testSingleQuoteInLiteralRun() {
        // Input: echo 'hello' — the quotes themselves are not literal-safe (0x27),
        // but let's verify: ' = 0x27, not in safe set → should be hex
        let result = wrapped([0x27]) // single quote
        XCTAssertEqual(result, "send -t %2 0x27\n")
    }

    func testDoubleQuoteIsHex() {
        // " = 0x22, not in safe set
        let result = wrapped([0x22])
        XCTAssertEqual(result, "send -t %2 0x22\n")
    }

    // MARK: - Pane ID Variations

    func testPaneIdZero() {
        let data = Data("ls".utf8)
        let result = TmuxSendKeys.wrap(data, paneId: 0)
        let str = result.flatMap { String(data: $0, encoding: .utf8) }
        XCTAssertEqual(str, "send -lt %0 'ls'\n")
    }

    func testPaneIdLargeNumber() {
        let data = Data("x".utf8)
        let result = TmuxSendKeys.wrap(data, paneId: 42)
        let str = result.flatMap { String(data: $0, encoding: .utf8) }
        XCTAssertEqual(str, "send -lt %42 'x'\n")
    }

    // MARK: - All-Hex Input

    func testAllControlChars() {
        // Multiple consecutive control chars: ESC [ A (arrow up escape sequence)
        let bytes: [UInt8] = [0x1B, 0x5B, 0x41] // ESC, [, A
        let result = wrapped(bytes)
        // '[' = 0x5B not in safe set, 'A' IS safe
        XCTAssertEqual(result, "send -t %2 0x1b ; send -t %2 0x5b ; send -lt %2 'A'\n")
    }

    func testOnlyCR() {
        // Just pressing Enter
        let result = wrapped([0x0D])
        XCTAssertEqual(result, "send -t %2 0x0d\n")
    }

    // MARK: - Multi-Byte / UTF-8 Sequences

    func testHighBytesAreHex() {
        // UTF-8 multi-byte: é = 0xC3 0xA9
        let bytes: [UInt8] = [0xC3, 0xA9]
        let result = wrapped(bytes)
        XCTAssertEqual(result, "send -t %2 0xc3 ; send -t %2 0xa9\n")
    }

    func testMixedASCIIAndUTF8() {
        // "café" = 63 61 66 C3 A9
        let bytes: [UInt8] = [0x63, 0x61, 0x66, 0xC3, 0xA9] // c, a, f, é
        let result = wrapped(bytes)
        XCTAssertEqual(result, "send -lt %2 'caf' ; send -t %2 0xc3 ; send -t %2 0xa9\n")
    }

    // MARK: - literalSafe Set Verification

    func testLiteralSafeContainsExpectedChars() {
        let safe = TmuxSendKeys.literalSafe

        // All lowercase letters
        for c in UInt8(ascii: "a")...UInt8(ascii: "z") {
            XCTAssertTrue(safe.contains(c), "Expected '\(Character(UnicodeScalar(c)))' to be literal-safe")
        }

        // All uppercase letters
        for c in UInt8(ascii: "A")...UInt8(ascii: "Z") {
            XCTAssertTrue(safe.contains(c), "Expected '\(Character(UnicodeScalar(c)))' to be literal-safe")
        }

        // All digits
        for c in UInt8(ascii: "0")...UInt8(ascii: "9") {
            XCTAssertTrue(safe.contains(c), "Expected '\(Character(UnicodeScalar(c)))' to be literal-safe")
        }

        // iTerm2 safe specials
        for ch: Character in ["+", "/", ")", ":", ",", "_", "."] {
            let byte = ch.asciiValue!
            XCTAssertTrue(safe.contains(byte), "Expected '\(ch)' to be literal-safe")
        }
    }

    func testLiteralSafeExcludesDangerousChars() {
        let safe = TmuxSendKeys.literalSafe

        // These must NOT be in the safe set
        let dangerous: [UInt8] = [
            0x20,                   // space
            0x0D,                   // CR
            0x0A,                   // LF
            0x1B,                   // ESC
            0x08,                   // BS
            0x09,                   // TAB
            0x00,                   // NULL
            UInt8(ascii: "'"),      // single quote
            UInt8(ascii: "\""),     // double quote
            UInt8(ascii: "\\"),     // backslash
            UInt8(ascii: "-"),      // hyphen (tmux flag prefix)
            UInt8(ascii: ";"),      // semicolon (tmux command separator)
            UInt8(ascii: "#"),      // hash
            UInt8(ascii: "~"),      // tilde
            UInt8(ascii: "`"),      // backtick
            UInt8(ascii: "("),      // open paren (close is safe, open is not)
            UInt8(ascii: "{"),      // open brace
            UInt8(ascii: "}"),      // close brace
            UInt8(ascii: "["),      // open bracket
            UInt8(ascii: "]"),      // close bracket
            UInt8(ascii: "<"),      // less than
            UInt8(ascii: ">"),      // greater than
            UInt8(ascii: "|"),      // pipe
            UInt8(ascii: "&"),      // ampersand
            UInt8(ascii: "*"),      // asterisk
            UInt8(ascii: "?"),      // question mark
            UInt8(ascii: "!"),      // exclamation
            UInt8(ascii: "$"),      // dollar
            UInt8(ascii: "="),      // equals
            UInt8(ascii: "@"),      // at sign
            UInt8(ascii: "^"),      // caret
        ]

        for byte in dangerous {
            XCTAssertFalse(safe.contains(byte), "Expected 0x\(String(format: "%02x", byte)) to NOT be literal-safe")
        }
    }

    func testLiteralSafeCount() {
        // 26 lowercase + 26 uppercase + 10 digits + 7 specials = 69
        XCTAssertEqual(TmuxSendKeys.literalSafe.count, 69)
    }

    // MARK: - Output Format

    func testOutputEndsWithNewline() {
        let data = TmuxSendKeys.wrap(Data("x".utf8), paneId: 1)!
        let str = String(data: data, encoding: .utf8)!
        XCTAssertTrue(str.hasSuffix("\n"), "Output must end with newline")
    }

    func testOutputIsValidUTF8() {
        // Even with high bytes in input, the output is always valid UTF-8
        // because we format as hex strings
        let data = TmuxSendKeys.wrap(Data([0xFF, 0xFE]), paneId: 3)!
        let str = String(data: data, encoding: .utf8)
        XCTAssertNotNil(str, "Output must be valid UTF-8")
    }

    func testSemicolonSeparator() {
        // Two commands should be separated by " ; "
        let result = wrapped([0x61, 0x0D]) // 'a', CR
        XCTAssertTrue(result!.contains(" ; "), "Commands must be separated by ' ; '")
    }
}
