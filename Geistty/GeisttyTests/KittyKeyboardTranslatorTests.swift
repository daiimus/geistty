import XCTest
@testable import Geistty

// MARK: - KittyKeyboardTranslator Tests

final class KittyKeyboardTranslatorTests: XCTestCase {

    private var translator: KittyKeyboardTranslator!

    override func setUp() {
        super.setUp()
        translator = KittyKeyboardTranslator()
    }

    // MARK: - Helpers

    /// Build a CSI sequence: ESC [ <params> <final>
    private func csi(_ params: String, final: UInt8) -> Data {
        var d = Data([0x1b, 0x5b])
        d.append(contentsOf: Array(params.utf8))
        d.append(final)
        return d
    }

    /// Shorthand: translate a CSI sequence and return result
    private func translate(_ params: String, final: UInt8) -> Data {
        translator.translate(csi(params, final: final))
    }

    // MARK: - FunctionalKey.from(code:final:)

    func testFunctionalKeyFromCSIU() {
        XCTAssertEqual(FunctionalKey.from(code: 27, final: 0x75), .escape)
        XCTAssertEqual(FunctionalKey.from(code: 13, final: 0x75), .enter)
        XCTAssertEqual(FunctionalKey.from(code: 9, final: 0x75), .tab)
        XCTAssertEqual(FunctionalKey.from(code: 127, final: 0x75), .backspace)
    }

    func testFunctionalKeyFromCSITilde() {
        XCTAssertEqual(FunctionalKey.from(code: 2, final: 0x7e), .insert)
        XCTAssertEqual(FunctionalKey.from(code: 3, final: 0x7e), .delete)
        XCTAssertEqual(FunctionalKey.from(code: 5, final: 0x7e), .pageUp)
        XCTAssertEqual(FunctionalKey.from(code: 6, final: 0x7e), .pageDown)
    }

    func testFunctionalKeyFromCSILetter() {
        XCTAssertEqual(FunctionalKey.from(code: 1, final: 0x41), .arrowUp)
        XCTAssertEqual(FunctionalKey.from(code: 1, final: 0x42), .arrowDown)
        XCTAssertEqual(FunctionalKey.from(code: 1, final: 0x43), .arrowRight)
        XCTAssertEqual(FunctionalKey.from(code: 1, final: 0x44), .arrowLeft)
        XCTAssertEqual(FunctionalKey.from(code: 1, final: 0x48), .home)
        XCTAssertEqual(FunctionalKey.from(code: 1, final: 0x46), .end)
    }

    func testFunctionalKeyFromFunctionKeys() {
        XCTAssertEqual(FunctionalKey.from(code: 1, final: 0x50), .f1)
        XCTAssertEqual(FunctionalKey.from(code: 1, final: 0x51), .f2)
        // F3 uses code 13, final ~
        XCTAssertEqual(FunctionalKey.from(code: 13, final: 0x7e), .f3)
        XCTAssertEqual(FunctionalKey.from(code: 1, final: 0x53), .f4)
        XCTAssertEqual(FunctionalKey.from(code: 15, final: 0x7e), .f5)
        XCTAssertEqual(FunctionalKey.from(code: 17, final: 0x7e), .f6)
        XCTAssertEqual(FunctionalKey.from(code: 18, final: 0x7e), .f7)
        XCTAssertEqual(FunctionalKey.from(code: 19, final: 0x7e), .f8)
        XCTAssertEqual(FunctionalKey.from(code: 20, final: 0x7e), .f9)
        XCTAssertEqual(FunctionalKey.from(code: 21, final: 0x7e), .f10)
        XCTAssertEqual(FunctionalKey.from(code: 23, final: 0x7e), .f11)
        XCTAssertEqual(FunctionalKey.from(code: 24, final: 0x7e), .f12)
    }

    func testFunctionalKeyHighNumberedFKeys() {
        XCTAssertEqual(FunctionalKey.from(code: 57376, final: 0x75), .f13)
        XCTAssertEqual(FunctionalKey.from(code: 57377, final: 0x75), .f14)
        XCTAssertEqual(FunctionalKey.from(code: 57378, final: 0x75), .f15)
        XCTAssertEqual(FunctionalKey.from(code: 57379, final: 0x75), .f16)
        XCTAssertEqual(FunctionalKey.from(code: 57380, final: 0x75), .f17)
        XCTAssertEqual(FunctionalKey.from(code: 57381, final: 0x75), .f18)
        XCTAssertEqual(FunctionalKey.from(code: 57382, final: 0x75), .f19)
        XCTAssertEqual(FunctionalKey.from(code: 57383, final: 0x75), .f20)
        XCTAssertEqual(FunctionalKey.from(code: 57384, final: 0x75), .f21)
        XCTAssertEqual(FunctionalKey.from(code: 57385, final: 0x75), .f22)
        XCTAssertEqual(FunctionalKey.from(code: 57386, final: 0x75), .f23)
        XCTAssertEqual(FunctionalKey.from(code: 57387, final: 0x75), .f24)
        XCTAssertEqual(FunctionalKey.from(code: 57388, final: 0x75), .f25)
    }

    func testFunctionalKeyUnknown() {
        XCTAssertNil(FunctionalKey.from(code: 999, final: 0x75))
        XCTAssertNil(FunctionalKey.from(code: 0, final: 0x75))
    }

    // MARK: - KittyModifiers

    func testModifiersNoMods() {
        let m = KittyModifiers(sequenceValue: 1) // 1 = no modifiers (mods+1=1 → bits=0)
        XCTAssertFalse(m.shift)
        XCTAssertFalse(m.alt)
        XCTAssertFalse(m.ctrl)
        XCTAssertFalse(m.superKey)
        XCTAssertFalse(m.hasBindingModifiers)
    }

    func testModifiersShift() {
        let m = KittyModifiers(sequenceValue: 2) // bits=1 → shift
        XCTAssertTrue(m.shift)
        XCTAssertFalse(m.alt)
        XCTAssertFalse(m.ctrl)
        XCTAssertFalse(m.hasBindingModifiers) // shift alone isn't a "binding" modifier
    }

    func testModifiersAlt() {
        let m = KittyModifiers(sequenceValue: 3) // bits=2 → alt
        XCTAssertFalse(m.shift)
        XCTAssertTrue(m.alt)
        XCTAssertFalse(m.ctrl)
        XCTAssertTrue(m.hasBindingModifiers)
    }

    func testModifiersCtrl() {
        let m = KittyModifiers(sequenceValue: 5) // bits=4 → ctrl
        XCTAssertFalse(m.shift)
        XCTAssertFalse(m.alt)
        XCTAssertTrue(m.ctrl)
        XCTAssertTrue(m.hasBindingModifiers)
    }

    func testModifiersCtrlShift() {
        let m = KittyModifiers(sequenceValue: 6) // bits=5 → shift+ctrl
        XCTAssertTrue(m.shift)
        XCTAssertFalse(m.alt)
        XCTAssertTrue(m.ctrl)
        XCTAssertTrue(m.hasBindingModifiers)
    }

    func testModifiersAllBits() {
        // bits = 1+2+4+8+16+32+64+128 = 255 → sequenceValue = 256
        let m = KittyModifiers(sequenceValue: 256)
        XCTAssertTrue(m.shift)
        XCTAssertTrue(m.alt)
        XCTAssertTrue(m.ctrl)
        XCTAssertTrue(m.superKey)
        XCTAssertTrue(m.hyper)
        XCTAssertTrue(m.meta)
        XCTAssertTrue(m.capsLock)
        XCTAssertTrue(m.numLock)
    }

    func testModifiersZeroSequenceValue() {
        // Edge case: 0 means bits=-1 but code clamps to 0
        let m = KittyModifiers(sequenceValue: 0)
        XCTAssertFalse(m.shift)
        XCTAssertFalse(m.alt)
        XCTAssertFalse(m.ctrl)
    }

    // MARK: - translate(): Functional Keys

    func testTranslateEscape() {
        // ESC[27u → ESC
        let result = translate("27", final: 0x75) // 'u'
        XCTAssertEqual(result, Data([0x1b]))
    }

    func testTranslateEnter() {
        // ESC[13u → CR
        let result = translate("13", final: 0x75)
        XCTAssertEqual(result, Data([0x0d]))
    }

    func testTranslateTab() {
        // ESC[9u → HT
        let result = translate("9", final: 0x75)
        XCTAssertEqual(result, Data([0x09]))
    }

    func testTranslateShiftTab() {
        // ESC[9;2u → ESC[Z (Shift+Tab = backtab)
        let result = translate("9;2", final: 0x75)
        XCTAssertEqual(result, Data([0x1b, 0x5b, 0x5a]))
    }

    func testTranslateBackspace() {
        // ESC[127u → DEL
        let result = translate("127", final: 0x75)
        XCTAssertEqual(result, Data([0x7f]))
    }

    func testTranslateCtrlBackspace() {
        // ESC[127;5u → BS (0x08)
        let result = translate("127;5", final: 0x75)
        XCTAssertEqual(result, Data([0x08]))
    }

    // MARK: - translate(): Arrow Keys

    func testTranslateArrowUp() {
        // ESC[A (no code, just final A)
        let result = translator.translate(Data([0x1b, 0x5b, 0x41]))
        XCTAssertEqual(result, Data([0x1b, 0x5b, 0x41])) // ESC[A
    }

    func testTranslateArrowUpWithModCtrl() {
        // ESC[1;5A → ESC[1;5A (Ctrl+Up)
        let result = translate("1;5", final: 0x41)
        XCTAssertEqual(result, Data([0x1b, 0x5b, 0x31, 0x3b, 0x35, 0x41])) // ESC[1;5A
    }

    func testTranslateArrowDown() {
        let result = translator.translate(Data([0x1b, 0x5b, 0x42]))
        XCTAssertEqual(result, Data([0x1b, 0x5b, 0x42]))
    }

    func testTranslateArrowLeft() {
        let result = translator.translate(Data([0x1b, 0x5b, 0x44]))
        XCTAssertEqual(result, Data([0x1b, 0x5b, 0x44]))
    }

    func testTranslateArrowRight() {
        let result = translator.translate(Data([0x1b, 0x5b, 0x43]))
        XCTAssertEqual(result, Data([0x1b, 0x5b, 0x43]))
    }

    // MARK: - translate(): Home/End

    func testTranslateHome() {
        let result = translator.translate(Data([0x1b, 0x5b, 0x48]))
        XCTAssertEqual(result, Data([0x1b, 0x5b, 0x48])) // ESC[H
    }

    func testTranslateEnd() {
        let result = translator.translate(Data([0x1b, 0x5b, 0x46]))
        XCTAssertEqual(result, Data([0x1b, 0x5b, 0x46])) // ESC[F
    }

    // MARK: - translate(): Insert/Delete/Page

    func testTranslateInsert() {
        // ESC[2~ → ESC[2~
        let result = translate("2", final: 0x7e)
        XCTAssertEqual(result, Data([0x1b, 0x5b, 0x32, 0x7e]))
    }

    func testTranslateDelete() {
        // ESC[3~ → ESC[3~
        let result = translate("3", final: 0x7e)
        XCTAssertEqual(result, Data([0x1b, 0x5b, 0x33, 0x7e]))
    }

    func testTranslatePageUp() {
        // ESC[5~ → ESC[5~
        let result = translate("5", final: 0x7e)
        XCTAssertEqual(result, Data([0x1b, 0x5b, 0x35, 0x7e]))
    }

    func testTranslatePageDown() {
        // ESC[6~ → ESC[6~
        let result = translate("6", final: 0x7e)
        XCTAssertEqual(result, Data([0x1b, 0x5b, 0x36, 0x7e]))
    }

    // MARK: - translate(): Function Keys

    func testTranslateF1() {
        // ESC[P (F1 legacy = ESC[OP, but kitty sends ESC[1;1P or just ESC[P)
        let result = translator.translate(Data([0x1b, 0x5b, 0x50])) // ESC[P
        XCTAssertEqual(result, Data([0x1b, 0x5b, 0x50])) // ESC[P
    }

    func testTranslateF5() {
        // ESC[15~ → ESC[15~
        let result = translate("15", final: 0x7e)
        XCTAssertEqual(result, Data([0x1b, 0x5b, 0x31, 0x35, 0x7e]))
    }

    func testTranslateF12() {
        // ESC[24~ → ESC[24~
        let result = translate("24", final: 0x7e)
        XCTAssertEqual(result, Data([0x1b, 0x5b, 0x32, 0x34, 0x7e]))
    }

    func testTranslateF5WithCtrl() {
        // ESC[15;5~ → ESC[15;5~ (Ctrl+F5)
        let result = translate("15;5", final: 0x7e)
        XCTAssertEqual(result, Data([0x1b, 0x5b, 0x31, 0x35, 0x3b, 0x35, 0x7e]))
    }

    // MARK: - translate(): Ctrl+Letter → C0 Control Codes

    func testTranslateCtrlC() {
        // ESC[99;5u → 0x03 (ETX / Ctrl+C)
        // code=99 ('c'), mods=5 (ctrl: bits=4)
        let result = translate("99;5", final: 0x75)
        XCTAssertEqual(result, Data([0x03]))
    }

    func testTranslateCtrlA() {
        // ESC[97;5u → 0x01 (SOH / Ctrl+A)
        let result = translate("97;5", final: 0x75)
        XCTAssertEqual(result, Data([0x01]))
    }

    func testTranslateCtrlZ() {
        // ESC[122;5u → 0x1A (SUB / Ctrl+Z)
        let result = translate("122;5", final: 0x75)
        XCTAssertEqual(result, Data([0x1a]))
    }

    func testTranslateCtrlD() {
        // ESC[100;5u → 0x04 (EOT / Ctrl+D)
        let result = translate("100;5", final: 0x75)
        XCTAssertEqual(result, Data([0x04]))
    }

    func testTranslateCtrlL() {
        // ESC[108;5u → 0x0C (FF / Ctrl+L)
        let result = translate("108;5", final: 0x75)
        XCTAssertEqual(result, Data([0x0c]))
    }

    func testTranslateCtrlBracket() {
        // ESC[91;5u → 0x1B (ESC / Ctrl+[)
        // code=91 ('['), ctrl
        let result = translate("91;5", final: 0x75)
        XCTAssertEqual(result, Data([0x1b]))
    }

    // MARK: - translate(): Alt+Character → ESC + Character

    func testTranslateAltA() {
        // ESC[97;3u → ESC a (Alt+a)
        // mods=3 → bits=2 → alt
        let result = translate("97;3", final: 0x75)
        XCTAssertEqual(result, Data([0x1b, 0x61]))
    }

    func testTranslateAltX() {
        // ESC[120;3u → ESC x
        let result = translate("120;3", final: 0x75)
        XCTAssertEqual(result, Data([0x1b, 0x78]))
    }

    // MARK: - translate(): Ctrl+Alt combinations

    func testTranslateCtrlAltC() {
        // ESC[99;7u → ESC 0x03 (Ctrl+Alt+C)
        // mods=7 → bits=6 → alt+ctrl
        let result = translate("99;7", final: 0x75)
        XCTAssertEqual(result, Data([0x1b, 0x03]))
    }

    // MARK: - translate(): Plain Characters via CSI u

    func testTranslatePlainCharacterA() {
        // ESC[97u → 'a' (no modifiers, mods defaults to 1)
        let result = translate("97", final: 0x75)
        XCTAssertEqual(result, Data([0x61]))
    }

    func testTranslatePlainSpace() {
        // ESC[32u → space
        let result = translate("32", final: 0x75)
        XCTAssertEqual(result, Data([0x20]))
    }

    func testTranslateShiftedCharacter() {
        // ESC[65;2u → 'A' (shift, code=65='A')
        // mods=2 → shift only, no binding modifiers → passes through
        let result = translate("65;2", final: 0x75)
        XCTAssertEqual(result, Data([0x41]))
    }

    // MARK: - translate(): Unicode via CSI u

    func testTranslateUnicodeCharacter() {
        // ESC[233u → 'é' (U+00E9, 2-byte UTF-8: 0xC3 0xA9)
        let result = translate("233", final: 0x75)
        XCTAssertEqual(result, Data([0xC3, 0xA9]))
    }

    func testTranslateUnicodeCJK() {
        // ESC[20013u → '中' (U+4E2D, 3-byte UTF-8: 0xE4 0xB8 0xAD)
        let result = translate("20013", final: 0x75)
        XCTAssertEqual(result, Data([0xE4, 0xB8, 0xAD]))
    }

    func testTranslateUnicodeEmoji() {
        // ESC[128578u → '🙂' (U+1F642, 4-byte UTF-8: 0xF0 0x9F 0x99 0x82)
        let result = translate("128578", final: 0x75)
        XCTAssertEqual(result, Data([0xF0, 0x9F, 0x99, 0x82]))
    }

    // MARK: - translate(): Passthrough of Non-CSI Data

    func testPassthroughPlainText() {
        let input = Data("hello world".utf8)
        let result = translator.translate(input)
        XCTAssertEqual(result, input)
    }

    func testPassthroughSingleByte() {
        let input = Data([0x41]) // 'A'
        let result = translator.translate(input)
        XCTAssertEqual(result, input)
    }

    func testPassthroughESCWithoutBracket() {
        // ESC followed by something other than '[' → not CSI, pass through
        let input = Data([0x1b, 0x4f, 0x50]) // ESC O P (SS3 F1)
        let result = translator.translate(input)
        XCTAssertEqual(result, input) // Passed through unchanged
    }

    // MARK: - translate(): Mixed Data

    func testMixedCSIAndPlainText() {
        // "hello" + ESC[97u + "world"
        var input = Data("hello".utf8)
        input.append(contentsOf: [0x1b, 0x5b]) // ESC[
        input.append(contentsOf: "97".utf8)      // code 97
        input.append(0x75)                        // 'u'
        input.append(contentsOf: "world".utf8)

        let result = translator.translate(input)
        var expected = Data("hello".utf8)
        expected.append(0x61)  // 'a' from CSI 97 u
        expected.append(contentsOf: "world".utf8)
        XCTAssertEqual(result, expected)
    }

    func testMultipleCSISequences() {
        // ESC[97u + ESC[98u → "ab"
        var input = Data([0x1b, 0x5b])
        input.append(contentsOf: "97".utf8)
        input.append(0x75)
        input.append(contentsOf: [0x1b, 0x5b])
        input.append(contentsOf: "98".utf8)
        input.append(0x75)

        let result = translator.translate(input)
        XCTAssertEqual(result, Data([0x61, 0x62])) // "ab"
    }

    // MARK: - translate(): Event Types (colon-separated)

    func testEventTypeIgnored() {
        // ESC[97;1:1u → 'a' (press event, no modifiers)
        // The :1 event type should be skipped
        let result = translate("97;1:1", final: 0x75)
        XCTAssertEqual(result, Data([0x61]))
    }

    func testReleaseEventTranslated() {
        // ESC[97;1:3u → 'a' (release event, still translates the same)
        let result = translate("97;1:3", final: 0x75)
        XCTAssertEqual(result, Data([0x61]))
    }

    // MARK: - translate(): Alternate Representations (colon-separated code)

    func testAlternateCodeRepresentation() {
        // ESC[97:65u → 'a' (code=97, shifted='A'=65)
        // The :65 alternate should be skipped, code=97 used
        let result = translate("97:65", final: 0x75)
        XCTAssertEqual(result, Data([0x61]))
    }

    // MARK: - translate(): Edge Cases

    func testEmptyInput() {
        let result = translator.translate(Data())
        XCTAssertEqual(result, Data())
    }

    func testTruncatedCSI() {
        // ESC[ with no following bytes
        let input = Data([0x1b, 0x5b])
        let result = translator.translate(input)
        // No valid final byte found → ESC passes through, then '[' passes through
        XCTAssertEqual(result, Data([0x1b, 0x5b]))
    }

    func testCSIWithoutFinalByte() {
        // ESC[97 (no final byte) — incomplete sequence
        let input = Data([0x1b, 0x5b, 0x39, 0x37])
        let result = translator.translate(input)
        // Parser can't find final byte → passes bytes through
        XCTAssertEqual(result, Data([0x1b, 0x5b, 0x39, 0x37]))
    }

    // MARK: - FunctionalKey.toLegacyBytes: F21-F25 Return Empty

    func testF21ToF25ReturnEmpty() {
        let mods = KittyModifiers(sequenceValue: 1) // no mods
        XCTAssertTrue(FunctionalKey.f21.toLegacyBytes(mods: mods).isEmpty)
        XCTAssertTrue(FunctionalKey.f22.toLegacyBytes(mods: mods).isEmpty)
        XCTAssertTrue(FunctionalKey.f23.toLegacyBytes(mods: mods).isEmpty)
        XCTAssertTrue(FunctionalKey.f24.toLegacyBytes(mods: mods).isEmpty)
        XCTAssertTrue(FunctionalKey.f25.toLegacyBytes(mods: mods).isEmpty)
    }

    // MARK: - Modifier Parameter Encoding in Legacy Output

    func testArrowUpWithShift() {
        // ESC[1;2A → ESC[1;2A (Shift+Up)
        let result = translate("1;2", final: 0x41)
        XCTAssertEqual(result, Data([0x1b, 0x5b, 0x31, 0x3b, 0x32, 0x41]))
    }

    func testArrowUpWithCtrlAlt() {
        // ESC[1;7A → ESC[1;7A (Ctrl+Alt+Up)
        let result = translate("1;7", final: 0x41)
        XCTAssertEqual(result, Data([0x1b, 0x5b, 0x31, 0x3b, 0x37, 0x41]))
    }

    func testDeleteWithShift() {
        // ESC[3;2~ → ESC[3;2~ (Shift+Delete)
        let result = translate("3;2", final: 0x7e)
        XCTAssertEqual(result, Data([0x1b, 0x5b, 0x33, 0x3b, 0x32, 0x7e]))
    }
}
