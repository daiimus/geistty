//
//  GhosttyInput.swift
//  Geistty
//
//  Ghostty input types for proper keyboard handling.
//  Based on macOS Ghostty implementation in Ghostty.Input.swift
//

import UIKit
import GhosttyKit

// MARK: - Input Namespace

extension Ghostty {
    struct Input {}
}

// MARK: - Mods

extension Ghostty.Input {
    /// Input modifiers matching `ghostty_input_mods_e`
    struct Mods: OptionSet {
        let rawValue: UInt32
        
        static let none = Mods([])
        static let shift = Mods(rawValue: GHOSTTY_MODS_SHIFT.rawValue)
        static let ctrl = Mods(rawValue: GHOSTTY_MODS_CTRL.rawValue)
        static let alt = Mods(rawValue: GHOSTTY_MODS_ALT.rawValue)
        static let `super` = Mods(rawValue: GHOSTTY_MODS_SUPER.rawValue)
        static let caps = Mods(rawValue: GHOSTTY_MODS_CAPS.rawValue)
        static let num = Mods(rawValue: GHOSTTY_MODS_NUM.rawValue)
        static let shiftRight = Mods(rawValue: GHOSTTY_MODS_SHIFT_RIGHT.rawValue)
        static let ctrlRight = Mods(rawValue: GHOSTTY_MODS_CTRL_RIGHT.rawValue)
        static let altRight = Mods(rawValue: GHOSTTY_MODS_ALT_RIGHT.rawValue)
        static let superRight = Mods(rawValue: GHOSTTY_MODS_SUPER_RIGHT.rawValue)
        
        var cMods: ghostty_input_mods_e {
            ghostty_input_mods_e(rawValue)
        }
        
        init(rawValue: UInt32) {
            self.rawValue = rawValue
        }
        
        init(cMods: ghostty_input_mods_e) {
            self.rawValue = cMods.rawValue
        }
        
        /// Create Mods from iOS UIKeyModifierFlags
        init(uiMods: UIKeyModifierFlags) {
            var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
            
            if uiMods.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
            if uiMods.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
            if uiMods.contains(.alternate) { mods |= GHOSTTY_MODS_ALT.rawValue }
            if uiMods.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
            if uiMods.contains(.alphaShift) { mods |= GHOSTTY_MODS_CAPS.rawValue }
            if uiMods.contains(.numericPad) { mods |= GHOSTTY_MODS_NUM.rawValue }
            
            self.rawValue = mods
        }
    }
}

// MARK: - Action

extension Ghostty.Input {
    /// Key action matching `ghostty_input_action_e`
    enum Action {
        case press
        case release
        case `repeat`
        
        var cAction: ghostty_input_action_e {
            switch self {
            case .press: return GHOSTTY_ACTION_PRESS
            case .release: return GHOSTTY_ACTION_RELEASE
            case .repeat: return GHOSTTY_ACTION_REPEAT
            }
        }
    }
}

// MARK: - Key

extension Ghostty.Input {
    /// Ghostty key codes matching `ghostty_input_key_e`
    enum Key {
        // Writing System Keys
        case backquote, backslash, bracketLeft, bracketRight, comma
        case digit0, digit1, digit2, digit3, digit4, digit5, digit6, digit7, digit8, digit9
        case equal, intlBackslash, intlRo, intlYen
        case a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z
        case minus, period, quote, semicolon, slash
        
        // Functional Keys
        case altLeft, altRight, backspace, capsLock, contextMenu
        case controlLeft, controlRight, enter, metaLeft, metaRight
        case shiftLeft, shiftRight, space, tab
        case convert, kanaMode, nonConvert
        
        // Control Pad Section
        case delete, end, help, home, insert, pageDown, pageUp
        
        // Arrow Pad Section
        case arrowDown, arrowLeft, arrowRight, arrowUp
        
        // Numpad Section
        case numLock
        case numpad0, numpad1, numpad2, numpad3, numpad4, numpad5, numpad6, numpad7, numpad8, numpad9
        case numpadAdd, numpadBackspace, numpadClear, numpadClearEntry, numpadComma
        case numpadDecimal, numpadDivide, numpadEnter, numpadEqual
        case numpadMemoryAdd, numpadMemoryClear, numpadMemoryRecall, numpadMemoryStore, numpadMemorySubtract
        case numpadMultiply, numpadParenLeft, numpadParenRight, numpadSubtract, numpadSeparator
        case numpadUp, numpadDown, numpadRight, numpadLeft, numpadBegin
        case numpadHome, numpadEnd, numpadInsert, numpadDelete, numpadPageUp, numpadPageDown
        
        // Function Section
        case escape
        case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
        case f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24, f25
        case fn, fnLock, printScreen, scrollLock, pause
        
        // Media Keys
        case browserBack, browserFavorites, browserForward, browserHome
        case browserRefresh, browserSearch, browserStop
        case eject, launchApp1, launchApp2, launchMail
        case mediaPlayPause, mediaSelect, mediaStop, mediaTrackNext, mediaTrackPrevious
        case power, sleep, audioVolumeDown, audioVolumeMute, audioVolumeUp, wakeUp
        
        // Legacy, Non-standard, and Special Keys
        case copy, cut, paste
        
        // Unidentified key
        case unidentified
        
        /// Convert to Ghostty C enum value
        var cKey: ghostty_input_key_e {
            switch self {
            // Writing System Keys
            case .backquote: return GHOSTTY_KEY_BACKQUOTE
            case .backslash: return GHOSTTY_KEY_BACKSLASH
            case .bracketLeft: return GHOSTTY_KEY_BRACKET_LEFT
            case .bracketRight: return GHOSTTY_KEY_BRACKET_RIGHT
            case .comma: return GHOSTTY_KEY_COMMA
            case .digit0: return GHOSTTY_KEY_DIGIT_0
            case .digit1: return GHOSTTY_KEY_DIGIT_1
            case .digit2: return GHOSTTY_KEY_DIGIT_2
            case .digit3: return GHOSTTY_KEY_DIGIT_3
            case .digit4: return GHOSTTY_KEY_DIGIT_4
            case .digit5: return GHOSTTY_KEY_DIGIT_5
            case .digit6: return GHOSTTY_KEY_DIGIT_6
            case .digit7: return GHOSTTY_KEY_DIGIT_7
            case .digit8: return GHOSTTY_KEY_DIGIT_8
            case .digit9: return GHOSTTY_KEY_DIGIT_9
            case .equal: return GHOSTTY_KEY_EQUAL
            case .intlBackslash: return GHOSTTY_KEY_INTL_BACKSLASH
            case .intlRo: return GHOSTTY_KEY_INTL_RO
            case .intlYen: return GHOSTTY_KEY_INTL_YEN
            case .a: return GHOSTTY_KEY_A
            case .b: return GHOSTTY_KEY_B
            case .c: return GHOSTTY_KEY_C
            case .d: return GHOSTTY_KEY_D
            case .e: return GHOSTTY_KEY_E
            case .f: return GHOSTTY_KEY_F
            case .g: return GHOSTTY_KEY_G
            case .h: return GHOSTTY_KEY_H
            case .i: return GHOSTTY_KEY_I
            case .j: return GHOSTTY_KEY_J
            case .k: return GHOSTTY_KEY_K
            case .l: return GHOSTTY_KEY_L
            case .m: return GHOSTTY_KEY_M
            case .n: return GHOSTTY_KEY_N
            case .o: return GHOSTTY_KEY_O
            case .p: return GHOSTTY_KEY_P
            case .q: return GHOSTTY_KEY_Q
            case .r: return GHOSTTY_KEY_R
            case .s: return GHOSTTY_KEY_S
            case .t: return GHOSTTY_KEY_T
            case .u: return GHOSTTY_KEY_U
            case .v: return GHOSTTY_KEY_V
            case .w: return GHOSTTY_KEY_W
            case .x: return GHOSTTY_KEY_X
            case .y: return GHOSTTY_KEY_Y
            case .z: return GHOSTTY_KEY_Z
            case .minus: return GHOSTTY_KEY_MINUS
            case .period: return GHOSTTY_KEY_PERIOD
            case .quote: return GHOSTTY_KEY_QUOTE
            case .semicolon: return GHOSTTY_KEY_SEMICOLON
            case .slash: return GHOSTTY_KEY_SLASH
            
            // Functional Keys
            case .altLeft: return GHOSTTY_KEY_ALT_LEFT
            case .altRight: return GHOSTTY_KEY_ALT_RIGHT
            case .backspace: return GHOSTTY_KEY_BACKSPACE
            case .capsLock: return GHOSTTY_KEY_CAPS_LOCK
            case .contextMenu: return GHOSTTY_KEY_CONTEXT_MENU
            case .controlLeft: return GHOSTTY_KEY_CONTROL_LEFT
            case .controlRight: return GHOSTTY_KEY_CONTROL_RIGHT
            case .enter: return GHOSTTY_KEY_ENTER
            case .metaLeft: return GHOSTTY_KEY_META_LEFT
            case .metaRight: return GHOSTTY_KEY_META_RIGHT
            case .shiftLeft: return GHOSTTY_KEY_SHIFT_LEFT
            case .shiftRight: return GHOSTTY_KEY_SHIFT_RIGHT
            case .space: return GHOSTTY_KEY_SPACE
            case .tab: return GHOSTTY_KEY_TAB
            case .convert: return GHOSTTY_KEY_CONVERT
            case .kanaMode: return GHOSTTY_KEY_KANA_MODE
            case .nonConvert: return GHOSTTY_KEY_NON_CONVERT
            
            // Control Pad Section
            case .delete: return GHOSTTY_KEY_DELETE
            case .end: return GHOSTTY_KEY_END
            case .help: return GHOSTTY_KEY_HELP
            case .home: return GHOSTTY_KEY_HOME
            case .insert: return GHOSTTY_KEY_INSERT
            case .pageDown: return GHOSTTY_KEY_PAGE_DOWN
            case .pageUp: return GHOSTTY_KEY_PAGE_UP
            
            // Arrow Pad Section
            case .arrowDown: return GHOSTTY_KEY_ARROW_DOWN
            case .arrowLeft: return GHOSTTY_KEY_ARROW_LEFT
            case .arrowRight: return GHOSTTY_KEY_ARROW_RIGHT
            case .arrowUp: return GHOSTTY_KEY_ARROW_UP
            
            // Numpad Section
            case .numLock: return GHOSTTY_KEY_NUM_LOCK
            case .numpad0: return GHOSTTY_KEY_NUMPAD_0
            case .numpad1: return GHOSTTY_KEY_NUMPAD_1
            case .numpad2: return GHOSTTY_KEY_NUMPAD_2
            case .numpad3: return GHOSTTY_KEY_NUMPAD_3
            case .numpad4: return GHOSTTY_KEY_NUMPAD_4
            case .numpad5: return GHOSTTY_KEY_NUMPAD_5
            case .numpad6: return GHOSTTY_KEY_NUMPAD_6
            case .numpad7: return GHOSTTY_KEY_NUMPAD_7
            case .numpad8: return GHOSTTY_KEY_NUMPAD_8
            case .numpad9: return GHOSTTY_KEY_NUMPAD_9
            case .numpadAdd: return GHOSTTY_KEY_NUMPAD_ADD
            case .numpadBackspace: return GHOSTTY_KEY_NUMPAD_BACKSPACE
            case .numpadClear: return GHOSTTY_KEY_NUMPAD_CLEAR
            case .numpadClearEntry: return GHOSTTY_KEY_NUMPAD_CLEAR_ENTRY
            case .numpadComma: return GHOSTTY_KEY_NUMPAD_COMMA
            case .numpadDecimal: return GHOSTTY_KEY_NUMPAD_DECIMAL
            case .numpadDivide: return GHOSTTY_KEY_NUMPAD_DIVIDE
            case .numpadEnter: return GHOSTTY_KEY_NUMPAD_ENTER
            case .numpadEqual: return GHOSTTY_KEY_NUMPAD_EQUAL
            case .numpadMemoryAdd: return GHOSTTY_KEY_NUMPAD_MEMORY_ADD
            case .numpadMemoryClear: return GHOSTTY_KEY_NUMPAD_MEMORY_CLEAR
            case .numpadMemoryRecall: return GHOSTTY_KEY_NUMPAD_MEMORY_RECALL
            case .numpadMemoryStore: return GHOSTTY_KEY_NUMPAD_MEMORY_STORE
            case .numpadMemorySubtract: return GHOSTTY_KEY_NUMPAD_MEMORY_SUBTRACT
            case .numpadMultiply: return GHOSTTY_KEY_NUMPAD_MULTIPLY
            case .numpadParenLeft: return GHOSTTY_KEY_NUMPAD_PAREN_LEFT
            case .numpadParenRight: return GHOSTTY_KEY_NUMPAD_PAREN_RIGHT
            case .numpadSubtract: return GHOSTTY_KEY_NUMPAD_SUBTRACT
            case .numpadSeparator: return GHOSTTY_KEY_NUMPAD_SEPARATOR
            case .numpadUp: return GHOSTTY_KEY_NUMPAD_UP
            case .numpadDown: return GHOSTTY_KEY_NUMPAD_DOWN
            case .numpadRight: return GHOSTTY_KEY_NUMPAD_RIGHT
            case .numpadLeft: return GHOSTTY_KEY_NUMPAD_LEFT
            case .numpadBegin: return GHOSTTY_KEY_NUMPAD_BEGIN
            case .numpadHome: return GHOSTTY_KEY_NUMPAD_HOME
            case .numpadEnd: return GHOSTTY_KEY_NUMPAD_END
            case .numpadInsert: return GHOSTTY_KEY_NUMPAD_INSERT
            case .numpadDelete: return GHOSTTY_KEY_NUMPAD_DELETE
            case .numpadPageUp: return GHOSTTY_KEY_NUMPAD_PAGE_UP
            case .numpadPageDown: return GHOSTTY_KEY_NUMPAD_PAGE_DOWN
            
            // Function Section
            case .escape: return GHOSTTY_KEY_ESCAPE
            case .f1: return GHOSTTY_KEY_F1
            case .f2: return GHOSTTY_KEY_F2
            case .f3: return GHOSTTY_KEY_F3
            case .f4: return GHOSTTY_KEY_F4
            case .f5: return GHOSTTY_KEY_F5
            case .f6: return GHOSTTY_KEY_F6
            case .f7: return GHOSTTY_KEY_F7
            case .f8: return GHOSTTY_KEY_F8
            case .f9: return GHOSTTY_KEY_F9
            case .f10: return GHOSTTY_KEY_F10
            case .f11: return GHOSTTY_KEY_F11
            case .f12: return GHOSTTY_KEY_F12
            case .f13: return GHOSTTY_KEY_F13
            case .f14: return GHOSTTY_KEY_F14
            case .f15: return GHOSTTY_KEY_F15
            case .f16: return GHOSTTY_KEY_F16
            case .f17: return GHOSTTY_KEY_F17
            case .f18: return GHOSTTY_KEY_F18
            case .f19: return GHOSTTY_KEY_F19
            case .f20: return GHOSTTY_KEY_F20
            case .f21: return GHOSTTY_KEY_F21
            case .f22: return GHOSTTY_KEY_F22
            case .f23: return GHOSTTY_KEY_F23
            case .f24: return GHOSTTY_KEY_F24
            case .f25: return GHOSTTY_KEY_F25
            case .fn: return GHOSTTY_KEY_FN
            case .fnLock: return GHOSTTY_KEY_FN_LOCK
            case .printScreen: return GHOSTTY_KEY_PRINT_SCREEN
            case .scrollLock: return GHOSTTY_KEY_SCROLL_LOCK
            case .pause: return GHOSTTY_KEY_PAUSE
            
            // Media Keys
            case .browserBack: return GHOSTTY_KEY_BROWSER_BACK
            case .browserFavorites: return GHOSTTY_KEY_BROWSER_FAVORITES
            case .browserForward: return GHOSTTY_KEY_BROWSER_FORWARD
            case .browserHome: return GHOSTTY_KEY_BROWSER_HOME
            case .browserRefresh: return GHOSTTY_KEY_BROWSER_REFRESH
            case .browserSearch: return GHOSTTY_KEY_BROWSER_SEARCH
            case .browserStop: return GHOSTTY_KEY_BROWSER_STOP
            case .eject: return GHOSTTY_KEY_EJECT
            case .launchApp1: return GHOSTTY_KEY_LAUNCH_APP_1
            case .launchApp2: return GHOSTTY_KEY_LAUNCH_APP_2
            case .launchMail: return GHOSTTY_KEY_LAUNCH_MAIL
            case .mediaPlayPause: return GHOSTTY_KEY_MEDIA_PLAY_PAUSE
            case .mediaSelect: return GHOSTTY_KEY_MEDIA_SELECT
            case .mediaStop: return GHOSTTY_KEY_MEDIA_STOP
            case .mediaTrackNext: return GHOSTTY_KEY_MEDIA_TRACK_NEXT
            case .mediaTrackPrevious: return GHOSTTY_KEY_MEDIA_TRACK_PREVIOUS
            case .power: return GHOSTTY_KEY_POWER
            case .sleep: return GHOSTTY_KEY_SLEEP
            case .audioVolumeDown: return GHOSTTY_KEY_AUDIO_VOLUME_DOWN
            case .audioVolumeMute: return GHOSTTY_KEY_AUDIO_VOLUME_MUTE
            case .audioVolumeUp: return GHOSTTY_KEY_AUDIO_VOLUME_UP
            case .wakeUp: return GHOSTTY_KEY_WAKE_UP
            
            // Legacy, Non-standard, and Special Keys
            case .copy: return GHOSTTY_KEY_COPY
            case .cut: return GHOSTTY_KEY_CUT
            case .paste: return GHOSTTY_KEY_PASTE
            
            case .unidentified: return GHOSTTY_KEY_UNIDENTIFIED
            }
        }
        
        /// macOS keycode for this key (used by Ghostty internally)
        /// Based on src/input/keycodes.zig
        var keyCode: UInt32? {
            switch self {
            // Writing System Keys
            case .backquote: return 0x0032
            case .backslash: return 0x002a
            case .bracketLeft: return 0x0021
            case .bracketRight: return 0x001e
            case .comma: return 0x002b
            case .digit0: return 0x001d
            case .digit1: return 0x0012
            case .digit2: return 0x0013
            case .digit3: return 0x0014
            case .digit4: return 0x0015
            case .digit5: return 0x0017
            case .digit6: return 0x0016
            case .digit7: return 0x001a
            case .digit8: return 0x001c
            case .digit9: return 0x0019
            case .equal: return 0x0018
            case .intlBackslash: return 0x000a
            case .intlRo: return 0x005e
            case .intlYen: return 0x005d
            case .a: return 0x0000
            case .b: return 0x000b
            case .c: return 0x0008
            case .d: return 0x0002
            case .e: return 0x000e
            case .f: return 0x0003
            case .g: return 0x0005
            case .h: return 0x0004
            case .i: return 0x0022
            case .j: return 0x0026
            case .k: return 0x0028
            case .l: return 0x0025
            case .m: return 0x002e
            case .n: return 0x002d
            case .o: return 0x001f
            case .p: return 0x0023
            case .q: return 0x000c
            case .r: return 0x000f
            case .s: return 0x0001
            case .t: return 0x0011
            case .u: return 0x0020
            case .v: return 0x0009
            case .w: return 0x000d
            case .x: return 0x0007
            case .y: return 0x0010
            case .z: return 0x0006
            case .minus: return 0x001b
            case .period: return 0x002f
            case .quote: return 0x0027
            case .semicolon: return 0x0029
            case .slash: return 0x002c
            
            // Functional Keys
            case .altLeft: return 0x003a
            case .altRight: return 0x003d
            case .backspace: return 0x0033
            case .capsLock: return 0x0039
            case .contextMenu: return 0x006e
            case .controlLeft: return 0x003b
            case .controlRight: return 0x003e
            case .enter: return 0x0024
            case .metaLeft: return 0x0037
            case .metaRight: return 0x0036
            case .shiftLeft: return 0x0038
            case .shiftRight: return 0x003c
            case .space: return 0x0031
            case .tab: return 0x0030
            case .convert: return nil
            case .kanaMode: return nil
            case .nonConvert: return nil
            
            // Control Pad Section
            case .delete: return 0x0075
            case .end: return 0x0077
            case .help: return nil
            case .home: return 0x0073
            case .insert: return 0x0072
            case .pageDown: return 0x0079
            case .pageUp: return 0x0074
            
            // Arrow Pad Section
            case .arrowDown: return 0x007d
            case .arrowLeft: return 0x007b
            case .arrowRight: return 0x007c
            case .arrowUp: return 0x007e
            
            // Numpad Section
            case .numLock: return 0x0047
            case .numpad0: return 0x0052
            case .numpad1: return 0x0053
            case .numpad2: return 0x0054
            case .numpad3: return 0x0055
            case .numpad4: return 0x0056
            case .numpad5: return 0x0057
            case .numpad6: return 0x0058
            case .numpad7: return 0x0059
            case .numpad8: return 0x005b
            case .numpad9: return 0x005c
            case .numpadAdd: return 0x0045
            case .numpadBackspace: return nil
            case .numpadClear: return nil
            case .numpadClearEntry: return nil
            case .numpadComma: return 0x005f
            case .numpadDecimal: return 0x0041
            case .numpadDivide: return 0x004b
            case .numpadEnter: return 0x004c
            case .numpadEqual: return 0x0051
            case .numpadMemoryAdd: return nil
            case .numpadMemoryClear: return nil
            case .numpadMemoryRecall: return nil
            case .numpadMemoryStore: return nil
            case .numpadMemorySubtract: return nil
            case .numpadMultiply: return 0x0043
            case .numpadParenLeft: return nil
            case .numpadParenRight: return nil
            case .numpadSubtract: return 0x004e
            case .numpadSeparator: return nil
            case .numpadUp: return nil
            case .numpadDown: return nil
            case .numpadRight: return nil
            case .numpadLeft: return nil
            case .numpadBegin: return nil
            case .numpadHome: return nil
            case .numpadEnd: return nil
            case .numpadInsert: return nil
            case .numpadDelete: return nil
            case .numpadPageUp: return nil
            case .numpadPageDown: return nil
            
            // Function Section
            case .escape: return 0x0035
            case .f1: return 0x007a
            case .f2: return 0x0078
            case .f3: return 0x0063
            case .f4: return 0x0076
            case .f5: return 0x0060
            case .f6: return 0x0061
            case .f7: return 0x0062
            case .f8: return 0x0064
            case .f9: return 0x0065
            case .f10: return 0x006d
            case .f11: return 0x0067
            case .f12: return 0x006f
            case .f13: return 0x0069
            case .f14: return 0x006b
            case .f15: return 0x0071
            case .f16: return 0x006a
            case .f17: return 0x0040
            case .f18: return 0x004f
            case .f19: return 0x0050
            case .f20: return 0x005a
            case .f21: return nil
            case .f22: return nil
            case .f23: return nil
            case .f24: return nil
            case .f25: return nil
            case .fn: return nil
            case .fnLock: return nil
            case .printScreen: return nil
            case .scrollLock: return nil
            case .pause: return nil
            
            // Media Keys
            case .browserBack: return nil
            case .browserFavorites: return nil
            case .browserForward: return nil
            case .browserHome: return nil
            case .browserRefresh: return nil
            case .browserSearch: return nil
            case .browserStop: return nil
            case .eject: return nil
            case .launchApp1: return nil
            case .launchApp2: return nil
            case .launchMail: return nil
            case .mediaPlayPause: return nil
            case .mediaSelect: return nil
            case .mediaStop: return nil
            case .mediaTrackNext: return nil
            case .mediaTrackPrevious: return nil
            case .power: return nil
            case .sleep: return nil
            case .audioVolumeDown: return 0x0049
            case .audioVolumeMute: return 0x004a
            case .audioVolumeUp: return 0x0048
            case .wakeUp: return nil
            
            // Legacy, Non-standard, and Special Keys
            case .copy: return nil
            case .cut: return nil
            case .paste: return nil
            
            case .unidentified: return nil
            }
        }
        
        /// Create Key from iOS UIKeyboardHIDUsage
        init?(hidUsage: UIKeyboardHIDUsage) {
            switch hidUsage {
            // Letters (A-Z)
            case .keyboardA: self = .a
            case .keyboardB: self = .b
            case .keyboardC: self = .c
            case .keyboardD: self = .d
            case .keyboardE: self = .e
            case .keyboardF: self = .f
            case .keyboardG: self = .g
            case .keyboardH: self = .h
            case .keyboardI: self = .i
            case .keyboardJ: self = .j
            case .keyboardK: self = .k
            case .keyboardL: self = .l
            case .keyboardM: self = .m
            case .keyboardN: self = .n
            case .keyboardO: self = .o
            case .keyboardP: self = .p
            case .keyboardQ: self = .q
            case .keyboardR: self = .r
            case .keyboardS: self = .s
            case .keyboardT: self = .t
            case .keyboardU: self = .u
            case .keyboardV: self = .v
            case .keyboardW: self = .w
            case .keyboardX: self = .x
            case .keyboardY: self = .y
            case .keyboardZ: self = .z
            
            // Numbers (0-9)
            case .keyboard0: self = .digit0
            case .keyboard1: self = .digit1
            case .keyboard2: self = .digit2
            case .keyboard3: self = .digit3
            case .keyboard4: self = .digit4
            case .keyboard5: self = .digit5
            case .keyboard6: self = .digit6
            case .keyboard7: self = .digit7
            case .keyboard8: self = .digit8
            case .keyboard9: self = .digit9
            
            // Punctuation & Symbols
            case .keyboardHyphen: self = .minus
            case .keyboardEqualSign: self = .equal
            case .keyboardOpenBracket: self = .bracketLeft
            case .keyboardCloseBracket: self = .bracketRight
            case .keyboardBackslash: self = .backslash
            case .keyboardSemicolon: self = .semicolon
            case .keyboardQuote: self = .quote
            case .keyboardGraveAccentAndTilde: self = .backquote
            case .keyboardComma: self = .comma
            case .keyboardPeriod: self = .period
            case .keyboardSlash: self = .slash
            
            // Functional Keys
            case .keyboardEscape: self = .escape
            case .keyboardTab: self = .tab
            case .keyboardSpacebar: self = .space
            case .keyboardReturnOrEnter: self = .enter
            case .keyboardDeleteOrBackspace: self = .backspace
            case .keyboardDeleteForward: self = .delete
            case .keyboardCapsLock: self = .capsLock
            
            // Navigation
            case .keyboardHome: self = .home
            case .keyboardEnd: self = .end
            case .keyboardPageUp: self = .pageUp
            case .keyboardPageDown: self = .pageDown
            case .keyboardInsert: self = .insert
            
            // Arrows
            case .keyboardUpArrow: self = .arrowUp
            case .keyboardDownArrow: self = .arrowDown
            case .keyboardLeftArrow: self = .arrowLeft
            case .keyboardRightArrow: self = .arrowRight
            
            // Function Keys
            case .keyboardF1: self = .f1
            case .keyboardF2: self = .f2
            case .keyboardF3: self = .f3
            case .keyboardF4: self = .f4
            case .keyboardF5: self = .f5
            case .keyboardF6: self = .f6
            case .keyboardF7: self = .f7
            case .keyboardF8: self = .f8
            case .keyboardF9: self = .f9
            case .keyboardF10: self = .f10
            case .keyboardF11: self = .f11
            case .keyboardF12: self = .f12
            case .keyboardF13: self = .f13
            case .keyboardF14: self = .f14
            case .keyboardF15: self = .f15
            case .keyboardF16: self = .f16
            case .keyboardF17: self = .f17
            case .keyboardF18: self = .f18
            case .keyboardF19: self = .f19
            case .keyboardF20: self = .f20
            
            // Modifier Keys (these are physical keys, not modifiers)
            case .keyboardLeftShift: self = .shiftLeft
            case .keyboardRightShift: self = .shiftRight
            case .keyboardLeftControl: self = .controlLeft
            case .keyboardRightControl: self = .controlRight
            case .keyboardLeftAlt: self = .altLeft
            case .keyboardRightAlt: self = .altRight
            case .keyboardLeftGUI: self = .metaLeft
            case .keyboardRightGUI: self = .metaRight
            
            // Numpad
            case .keypadNumLock: self = .numLock
            case .keypad0: self = .numpad0
            case .keypad1: self = .numpad1
            case .keypad2: self = .numpad2
            case .keypad3: self = .numpad3
            case .keypad4: self = .numpad4
            case .keypad5: self = .numpad5
            case .keypad6: self = .numpad6
            case .keypad7: self = .numpad7
            case .keypad8: self = .numpad8
            case .keypad9: self = .numpad9
            case .keypadPlus: self = .numpadAdd
            case .keypadHyphen: self = .numpadSubtract
            case .keypadAsterisk: self = .numpadMultiply
            case .keypadSlash: self = .numpadDivide
            case .keypadPeriod: self = .numpadDecimal
            case .keypadEnter: self = .numpadEnter
            case .keypadEqualSign: self = .numpadEqual
            
            // International Keys
            case .keyboardNonUSBackslash: self = .intlBackslash
            
            // Media Keys
            case .keyboardVolumeUp: self = .audioVolumeUp
            case .keyboardVolumeDown: self = .audioVolumeDown
            case .keyboardMute: self = .audioVolumeMute
            
            // Other
            case .keyboardApplication: self = .contextMenu
            case .keyboardPrintScreen: self = .printScreen
            case .keyboardScrollLock: self = .scrollLock
            case .keyboardPause: self = .pause
            
            default:
                return nil
            }
        }
    }
}

// MARK: - KeyEvent

extension Ghostty.Input {
    /// Key event structure matching `ghostty_input_key_s`
    struct KeyEvent {
        let action: Action
        let key: Key
        let text: String?
        let composing: Bool
        let mods: Mods
        let consumedMods: Mods
        let unshiftedCodepoint: UInt32
        
        init(
            key: Key,
            action: Action = .press,
            text: String? = nil,
            composing: Bool = false,
            mods: Mods = [],
            consumedMods: Mods = [],
            unshiftedCodepoint: UInt32 = 0
        ) {
            self.action = action
            self.key = key
            self.text = text
            self.composing = composing
            self.mods = mods
            self.consumedMods = consumedMods
            self.unshiftedCodepoint = unshiftedCodepoint
        }
        
        /// Create from iOS UIPress
        /// 
        /// Note: We deliberately set `text` to nil for special keys. iOS represents special keys
        /// like Escape, arrows, etc. as string constants (e.g., "UIKeyInputEscape") rather than
        /// actual characters. This mirrors macOS Ghostty's approach of filtering PUA (Private Use Area)
        /// codepoints that represent function keys. Ghostty's KeyEncoder handles these keys properly
        /// using just the keycode.
        init?(press: UIPress, action: Action) {
            guard let uiKey = press.key else { return nil }
            
            // Try to map the HID usage to a Ghostty key
            guard let ghosttyKey = Key(hidUsage: uiKey.keyCode) else {
                return nil
            }
            
            self.action = action
            self.key = ghosttyKey
            
            // Get text, filtering out iOS special key constants and control characters.
            // iOS uses "UIKeyInput*" strings for special keys (Escape, arrows, etc.)
            // Similar to how macOS uses Unicode PUA (0xF700-0xF8FF) for function keys.
            //
            // For control characters (codepoint < 0x20): iOS returns the raw control
            // character in UIKey.characters (e.g. "\u{03}" for Ctrl+C). macOS Ghostty
            // strips the control modifier to re-derive the printable character (e.g. "c")
            // via its ghosttyCharacters property, then applies a second filter dropping
            // text with first byte < 0x20. Ghostty's ctrlSeq() encoder expects either
            // the printable character or nil — not the raw control byte — because its
            // switch starts at 0x20. We mirror the macOS behavior by setting text to nil
            // for control characters and letting ctrlSeq() use the logical key codepoint.
            let rawText = uiKey.characters
            if rawText.hasPrefix("UIKeyInput") {
                self.text = nil
            } else if let firstByte = rawText.utf8.first, firstByte < 0x20 {
                // Control character — don't pass raw C0 bytes as text.
                // Ghostty's key encoder will derive the correct byte from the
                // key and modifiers via ctrlSeq().
                self.text = nil
            } else {
                self.text = rawText
            }
            
            self.composing = false
            self.mods = Mods(uiMods: uiKey.modifierFlags)
            self.consumedMods = []
            
            // Get unshifted codepoint from charactersIgnoringModifiers
            // Filter out UIKeyInput constants here too
            let chars = uiKey.charactersIgnoringModifiers
            if !chars.hasPrefix("UIKeyInput"), let scalar = chars.unicodeScalars.first {
                self.unshiftedCodepoint = scalar.value
            } else {
                self.unshiftedCodepoint = 0
            }
        }
        
        /// Execute a closure with a temporary C representation of this KeyEvent
        @discardableResult
        func withCValue<T>(execute: (ghostty_input_key_s) -> T) -> T {
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = action.cAction
            keyEvent.keycode = key.keyCode ?? 0
            keyEvent.composing = composing
            keyEvent.mods = mods.cMods
            keyEvent.consumed_mods = consumedMods.cMods
            keyEvent.unshifted_codepoint = unshiftedCodepoint
            
            // Handle text with proper memory management
            if let text = text, !text.isEmpty {
                return text.withCString { textPtr in
                    keyEvent.text = textPtr
                    return execute(keyEvent)
                }
            } else {
                keyEvent.text = nil
                return execute(keyEvent)
            }
        }
    }
}

// MARK: - Text Input Event

extension Ghostty.Input {
    /// For soft keyboard text input (not hardware keys)
    /// This creates a synthetic key event for each character
    struct TextInputEvent {
        let text: String
        let mods: Mods
        
        init(text: String, mods: Mods = []) {
            self.text = text
            self.mods = mods
        }
        
        /// Get the key for this text character
        var key: Key {
            guard let char = text.lowercased().first else {
                return .unidentified
            }
            
            switch char {
            case "a": return .a
            case "b": return .b
            case "c": return .c
            case "d": return .d
            case "e": return .e
            case "f": return .f
            case "g": return .g
            case "h": return .h
            case "i": return .i
            case "j": return .j
            case "k": return .k
            case "l": return .l
            case "m": return .m
            case "n": return .n
            case "o": return .o
            case "p": return .p
            case "q": return .q
            case "r": return .r
            case "s": return .s
            case "t": return .t
            case "u": return .u
            case "v": return .v
            case "w": return .w
            case "x": return .x
            case "y": return .y
            case "z": return .z
            case "0": return .digit0
            case "1": return .digit1
            case "2": return .digit2
            case "3": return .digit3
            case "4": return .digit4
            case "5": return .digit5
            case "6": return .digit6
            case "7": return .digit7
            case "8": return .digit8
            case "9": return .digit9
            case " ": return .space
            case "-": return .minus
            case "=": return .equal
            case "[": return .bracketLeft
            case "]": return .bracketRight
            case "\\": return .backslash
            case ";": return .semicolon
            case "'": return .quote
            case "`": return .backquote
            case ",": return .comma
            case ".": return .period
            case "/": return .slash
            case "\t": return .tab
            case "\r", "\n": return .enter
            default: return .unidentified
            }
        }
        
        /// Get unshifted codepoint
        var unshiftedCodepoint: UInt32 {
            if let scalar = text.lowercased().unicodeScalars.first {
                return scalar.value
            }
            return 0
        }
        
        /// Create a KeyEvent from this text input
        func toKeyEvent(action: Action = .press) -> KeyEvent {
            return KeyEvent(
                key: key,
                action: action,
                text: text,
                composing: false,
                mods: mods,
                consumedMods: [],
                unshiftedCodepoint: unshiftedCodepoint
            )
        }
    }
}
