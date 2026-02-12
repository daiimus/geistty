import XCTest
@testable import Geistty

// MARK: - GhosttyInput Tests
//
// Tests for GhosttyInput.swift types. These test the Swift-level logic:
// - TextInputEvent.key character → Key mapping
// - TextInputEvent.unshiftedCodepoint
// - Key.keyCode for spot-checked keys (macOS keycodes from keycodes.zig)
// - KeyEvent initialization defaults
//
// Note: Tests for Mods.init(uiMods:) and Key.init(hidUsage:) are included
// since the test target builds for iOS simulator where UIKit is available.

final class GhosttyInputTests: XCTestCase {

    // MARK: - TextInputEvent.key: Letters

    func testTextInputKeyLetters() {
        let letters: [(String, Ghostty.Input.Key)] = [
            ("a", .a), ("b", .b), ("c", .c), ("d", .d), ("e", .e),
            ("f", .f), ("g", .g), ("h", .h), ("i", .i), ("j", .j),
            ("k", .k), ("l", .l), ("m", .m), ("n", .n), ("o", .o),
            ("p", .p), ("q", .q), ("r", .r), ("s", .s), ("t", .t),
            ("u", .u), ("v", .v), ("w", .w), ("x", .x), ("y", .y),
            ("z", .z),
        ]
        for (char, expectedKey) in letters {
            let event = Ghostty.Input.TextInputEvent(text: char)
            XCTAssertEqual(event.key.keyCode, expectedKey.keyCode,
                           "Key mismatch for '\(char)'")
        }
    }

    func testTextInputKeyUppercaseLetters() {
        // Uppercase should map to same key (lowercased internally)
        let event = Ghostty.Input.TextInputEvent(text: "A")
        XCTAssertEqual(event.key.keyCode, Ghostty.Input.Key.a.keyCode)

        let eventZ = Ghostty.Input.TextInputEvent(text: "Z")
        XCTAssertEqual(eventZ.key.keyCode, Ghostty.Input.Key.z.keyCode)
    }

    // MARK: - TextInputEvent.key: Digits

    func testTextInputKeyDigits() {
        let digits: [(String, Ghostty.Input.Key)] = [
            ("0", .digit0), ("1", .digit1), ("2", .digit2), ("3", .digit3), ("4", .digit4),
            ("5", .digit5), ("6", .digit6), ("7", .digit7), ("8", .digit8), ("9", .digit9),
        ]
        for (char, expectedKey) in digits {
            let event = Ghostty.Input.TextInputEvent(text: char)
            XCTAssertEqual(event.key.keyCode, expectedKey.keyCode,
                           "Key mismatch for '\(char)'")
        }
    }

    // MARK: - TextInputEvent.key: Punctuation

    func testTextInputKeyPunctuation() {
        let mappings: [(String, Ghostty.Input.Key)] = [
            (" ", .space), ("-", .minus), ("=", .equal),
            ("[", .bracketLeft), ("]", .bracketRight), ("\\", .backslash),
            (";", .semicolon), ("'", .quote), ("`", .backquote),
            (",", .comma), (".", .period), ("/", .slash),
        ]
        for (char, expectedKey) in mappings {
            let event = Ghostty.Input.TextInputEvent(text: char)
            XCTAssertEqual(event.key.keyCode, expectedKey.keyCode,
                           "Key mismatch for '\(char)'")
        }
    }

    // MARK: - TextInputEvent.key: Special Characters

    func testTextInputKeyTab() {
        let event = Ghostty.Input.TextInputEvent(text: "\t")
        XCTAssertEqual(event.key.keyCode, Ghostty.Input.Key.tab.keyCode)
    }

    func testTextInputKeyEnterCR() {
        let event = Ghostty.Input.TextInputEvent(text: "\r")
        XCTAssertEqual(event.key.keyCode, Ghostty.Input.Key.enter.keyCode)
    }

    func testTextInputKeyEnterLF() {
        let event = Ghostty.Input.TextInputEvent(text: "\n")
        XCTAssertEqual(event.key.keyCode, Ghostty.Input.Key.enter.keyCode)
    }

    func testTextInputKeyUnidentified() {
        let event = Ghostty.Input.TextInputEvent(text: "🎉")
        XCTAssertNil(event.key.keyCode) // .unidentified → nil
    }

    func testTextInputKeyEmptyString() {
        let event = Ghostty.Input.TextInputEvent(text: "")
        XCTAssertNil(event.key.keyCode) // .unidentified → nil
    }

    // MARK: - TextInputEvent.unshiftedCodepoint

    func testUnshiftedCodepointLowercase() {
        let event = Ghostty.Input.TextInputEvent(text: "a")
        XCTAssertEqual(event.unshiftedCodepoint, 0x61)
    }

    func testUnshiftedCodepointUppercaseLowered() {
        // unshiftedCodepoint lowercases the text first
        let event = Ghostty.Input.TextInputEvent(text: "A")
        XCTAssertEqual(event.unshiftedCodepoint, 0x61) // 'a'
    }

    func testUnshiftedCodepointDigit() {
        let event = Ghostty.Input.TextInputEvent(text: "5")
        XCTAssertEqual(event.unshiftedCodepoint, 0x35) // '5'
    }

    func testUnshiftedCodepointSpace() {
        let event = Ghostty.Input.TextInputEvent(text: " ")
        XCTAssertEqual(event.unshiftedCodepoint, 0x20)
    }

    func testUnshiftedCodepointEmpty() {
        let event = Ghostty.Input.TextInputEvent(text: "")
        XCTAssertEqual(event.unshiftedCodepoint, 0)
    }

    // MARK: - Key.keyCode: Spot Checks

    func testKeyCodeA() {
        XCTAssertEqual(Ghostty.Input.Key.a.keyCode, 0x0000)
    }

    func testKeyCodeS() {
        XCTAssertEqual(Ghostty.Input.Key.s.keyCode, 0x0001)
    }

    func testKeyCodeSpace() {
        XCTAssertEqual(Ghostty.Input.Key.space.keyCode, 0x0031)
    }

    func testKeyCodeEscape() {
        XCTAssertEqual(Ghostty.Input.Key.escape.keyCode, 0x0035)
    }

    func testKeyCodeEnter() {
        XCTAssertEqual(Ghostty.Input.Key.enter.keyCode, 0x0024)
    }

    func testKeyCodeTab() {
        XCTAssertEqual(Ghostty.Input.Key.tab.keyCode, 0x0030)
    }

    func testKeyCodeBackspace() {
        XCTAssertEqual(Ghostty.Input.Key.backspace.keyCode, 0x0033)
    }

    func testKeyCodeArrows() {
        XCTAssertEqual(Ghostty.Input.Key.arrowUp.keyCode, 0x007e)
        XCTAssertEqual(Ghostty.Input.Key.arrowDown.keyCode, 0x007d)
        XCTAssertEqual(Ghostty.Input.Key.arrowLeft.keyCode, 0x007b)
        XCTAssertEqual(Ghostty.Input.Key.arrowRight.keyCode, 0x007c)
    }

    func testKeyCodeFunctionKeys() {
        XCTAssertEqual(Ghostty.Input.Key.f1.keyCode, 0x007a)
        XCTAssertEqual(Ghostty.Input.Key.f2.keyCode, 0x0078)
        XCTAssertEqual(Ghostty.Input.Key.f12.keyCode, 0x006f)
    }

    func testKeyCodeDelete() {
        XCTAssertEqual(Ghostty.Input.Key.delete.keyCode, 0x0075)
    }

    func testKeyCodeHome() {
        XCTAssertEqual(Ghostty.Input.Key.home.keyCode, 0x0073)
    }

    func testKeyCodeEnd() {
        XCTAssertEqual(Ghostty.Input.Key.end.keyCode, 0x0077)
    }

    func testKeyCodeNilForUnsupported() {
        XCTAssertNil(Ghostty.Input.Key.unidentified.keyCode)
        XCTAssertNil(Ghostty.Input.Key.f21.keyCode)
        XCTAssertNil(Ghostty.Input.Key.fn.keyCode)
        XCTAssertNil(Ghostty.Input.Key.copy.keyCode)
    }

    // MARK: - KeyEvent Initialization Defaults

    func testKeyEventDefaults() {
        let event = Ghostty.Input.KeyEvent(key: .a)
        XCTAssertNil(event.text)
        XCTAssertFalse(event.composing)
        XCTAssertEqual(event.unshiftedCodepoint, 0)
    }

    func testKeyEventWithText() {
        let event = Ghostty.Input.KeyEvent(
            key: .a,
            action: .press,
            text: "a",
            mods: [],
            unshiftedCodepoint: 0x61
        )
        XCTAssertEqual(event.text, "a")
        XCTAssertEqual(event.unshiftedCodepoint, 0x61)
    }

    // MARK: - TextInputEvent.toKeyEvent()

    func testTextInputToKeyEvent() {
        let textEvent = Ghostty.Input.TextInputEvent(text: "x")
        let keyEvent = textEvent.toKeyEvent()
        XCTAssertEqual(keyEvent.key.keyCode, Ghostty.Input.Key.x.keyCode)
        XCTAssertEqual(keyEvent.text, "x")
        XCTAssertEqual(keyEvent.unshiftedCodepoint, 0x78) // 'x'
        XCTAssertFalse(keyEvent.composing)
    }

    func testTextInputToKeyEventWithAction() {
        let textEvent = Ghostty.Input.TextInputEvent(text: "a")
        let keyEvent = textEvent.toKeyEvent(action: .release)
        // We can't check cAction without GhosttyKit, but we can verify the
        // key event was created with the right key
        XCTAssertEqual(keyEvent.key.keyCode, Ghostty.Input.Key.a.keyCode)
    }

    // MARK: - Mods.init(uiMods:) — UIKit available on simulator

    func testModsFromUIModsNone() {
        let mods = Ghostty.Input.Mods(uiMods: [])
        XCTAssertEqual(mods.rawValue & 0xFF, 0) // No modifier bits set
    }

    func testModsFromUIModsShift() {
        let mods = Ghostty.Input.Mods(uiMods: .shift)
        XCTAssertTrue(mods.contains(.shift))
        XCTAssertFalse(mods.contains(.ctrl))
    }

    func testModsFromUIModsControl() {
        let mods = Ghostty.Input.Mods(uiMods: .control)
        XCTAssertTrue(mods.contains(.ctrl))
    }

    func testModsFromUIModsAlternate() {
        let mods = Ghostty.Input.Mods(uiMods: .alternate)
        XCTAssertTrue(mods.contains(.alt))
    }

    func testModsFromUIModsCommand() {
        let mods = Ghostty.Input.Mods(uiMods: .command)
        XCTAssertTrue(mods.contains(.super))
    }

    func testModsFromUIModsCombined() {
        let mods = Ghostty.Input.Mods(uiMods: [.shift, .control, .alternate])
        XCTAssertTrue(mods.contains(.shift))
        XCTAssertTrue(mods.contains(.ctrl))
        XCTAssertTrue(mods.contains(.alt))
        XCTAssertFalse(mods.contains(.super))
    }

    // MARK: - Key.init(hidUsage:) — UIKit available on simulator

    func testHIDUsageLetters() {
        XCTAssertEqual(Ghostty.Input.Key(hidUsage: .keyboardA)?.keyCode, Ghostty.Input.Key.a.keyCode)
        XCTAssertEqual(Ghostty.Input.Key(hidUsage: .keyboardZ)?.keyCode, Ghostty.Input.Key.z.keyCode)
        XCTAssertEqual(Ghostty.Input.Key(hidUsage: .keyboardM)?.keyCode, Ghostty.Input.Key.m.keyCode)
    }

    func testHIDUsageDigits() {
        XCTAssertEqual(Ghostty.Input.Key(hidUsage: .keyboard0)?.keyCode, Ghostty.Input.Key.digit0.keyCode)
        XCTAssertEqual(Ghostty.Input.Key(hidUsage: .keyboard9)?.keyCode, Ghostty.Input.Key.digit9.keyCode)
    }

    func testHIDUsageArrows() {
        XCTAssertEqual(Ghostty.Input.Key(hidUsage: .keyboardUpArrow)?.keyCode, Ghostty.Input.Key.arrowUp.keyCode)
        XCTAssertEqual(Ghostty.Input.Key(hidUsage: .keyboardDownArrow)?.keyCode, Ghostty.Input.Key.arrowDown.keyCode)
        XCTAssertEqual(Ghostty.Input.Key(hidUsage: .keyboardLeftArrow)?.keyCode, Ghostty.Input.Key.arrowLeft.keyCode)
        XCTAssertEqual(Ghostty.Input.Key(hidUsage: .keyboardRightArrow)?.keyCode, Ghostty.Input.Key.arrowRight.keyCode)
    }

    func testHIDUsageFunctionKeys() {
        XCTAssertEqual(Ghostty.Input.Key(hidUsage: .keyboardF1)?.keyCode, Ghostty.Input.Key.f1.keyCode)
        XCTAssertEqual(Ghostty.Input.Key(hidUsage: .keyboardF12)?.keyCode, Ghostty.Input.Key.f12.keyCode)
    }

    func testHIDUsageSpecialKeys() {
        XCTAssertEqual(Ghostty.Input.Key(hidUsage: .keyboardEscape)?.keyCode, Ghostty.Input.Key.escape.keyCode)
        XCTAssertEqual(Ghostty.Input.Key(hidUsage: .keyboardTab)?.keyCode, Ghostty.Input.Key.tab.keyCode)
        XCTAssertEqual(Ghostty.Input.Key(hidUsage: .keyboardSpacebar)?.keyCode, Ghostty.Input.Key.space.keyCode)
        XCTAssertEqual(Ghostty.Input.Key(hidUsage: .keyboardReturnOrEnter)?.keyCode, Ghostty.Input.Key.enter.keyCode)
        XCTAssertEqual(Ghostty.Input.Key(hidUsage: .keyboardDeleteOrBackspace)?.keyCode, Ghostty.Input.Key.backspace.keyCode)
    }

    func testHIDUsageModifiers() {
        XCTAssertEqual(Ghostty.Input.Key(hidUsage: .keyboardLeftShift)?.keyCode, Ghostty.Input.Key.shiftLeft.keyCode)
        XCTAssertEqual(Ghostty.Input.Key(hidUsage: .keyboardRightShift)?.keyCode, Ghostty.Input.Key.shiftRight.keyCode)
        XCTAssertEqual(Ghostty.Input.Key(hidUsage: .keyboardLeftControl)?.keyCode, Ghostty.Input.Key.controlLeft.keyCode)
        XCTAssertEqual(Ghostty.Input.Key(hidUsage: .keyboardLeftAlt)?.keyCode, Ghostty.Input.Key.altLeft.keyCode)
        XCTAssertEqual(Ghostty.Input.Key(hidUsage: .keyboardLeftGUI)?.keyCode, Ghostty.Input.Key.metaLeft.keyCode)
    }

    func testHIDUsageNumpad() {
        XCTAssertEqual(Ghostty.Input.Key(hidUsage: .keypad0)?.keyCode, Ghostty.Input.Key.numpad0.keyCode)
        XCTAssertEqual(Ghostty.Input.Key(hidUsage: .keypadEnter)?.keyCode, Ghostty.Input.Key.numpadEnter.keyCode)
        XCTAssertEqual(Ghostty.Input.Key(hidUsage: .keypadPlus)?.keyCode, Ghostty.Input.Key.numpadAdd.keyCode)
    }
}
