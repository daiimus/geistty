//
//  KittyKeyboardTranslator.swift
//  Geistty
//
//  Translates Kitty keyboard protocol sequences to legacy terminal codes.
//  This is a terminal concern, not a tmux concern, so it's extracted here.
//
//  The Kitty keyboard protocol (https://sw.kovidgoyal.net/kitty/keyboard-protocol/)
//  encodes keys as CSI sequences that many terminal multiplexers don't understand.
//  This translator converts them to legacy sequences for compatibility.
//

import Foundation

// MARK: - Protocol

/// Protocol for keyboard input translation
/// Allows different translation strategies to be injected
public protocol KeyboardTranslator: Sendable {
    /// Translate input data, converting protocol-specific sequences to target format
    func translate(_ data: Data) -> Data
}

// MARK: - Kitty Keyboard Translator

/// Translates Kitty keyboard protocol sequences to legacy terminal codes.
///
/// Kitty protocol encodes keys as CSI sequences with different final bytes:
/// - `ESC [ <code> ; <mods> u` - Unicode codepoints and special keys
/// - `ESC [ <code> ; <mods> ~` - Function keys, insert, delete, page up/down
/// - `ESC [ 1 ; <mods> <letter>` - Arrow keys (A/B/C/D), Home (H), End (F), F1-F4 (P/Q/R/S)
///
/// Modifier encoding: sequence value = modifier_bits + 1
/// - shift=1, alt=2, ctrl=4, super=8, hyper=16, meta=32, caps_lock=64, num_lock=128
///
/// Event types (after colon): 1=press, 2=repeat, 3=release
public struct KittyKeyboardTranslator: KeyboardTranslator, Sendable {
    
    public init() {}
    
    /// Translate Kitty protocol sequences to legacy terminal codes
    public func translate(_ data: Data) -> Data {
        var result = Data()
        var i = 0
        let bytes = Array(data)
        
        while i < bytes.count {
            // Check for CSI sequence: ESC [
            if i + 2 < bytes.count && bytes[i] == 0x1b && bytes[i + 1] == 0x5b {
                if let (translated, consumed) = parseAndTranslateCSI(bytes: bytes, startIndex: i + 2) {
                    result.append(contentsOf: translated)
                    i += consumed + 2  // +2 for ESC [
                    continue
                }
            }
            
            // Not a translatable CSI sequence - copy byte as-is
            result.append(bytes[i])
            i += 1
        }
        
        return result
    }
    
    // MARK: - CSI Parsing
    
    /// Parse and translate a CSI sequence starting after "ESC ["
    /// Returns (translated bytes, number of bytes consumed from input) or nil if not translatable
    private func parseAndTranslateCSI(bytes: [UInt8], startIndex: Int) -> (translated: [UInt8], consumed: Int)? {
        var j = startIndex
        
        // Parse the first number (code)
        var code: Int = 0
        var hasCode = false
        while j < bytes.count && bytes[j] >= 0x30 && bytes[j] <= 0x39 {
            code = code * 10 + Int(bytes[j] - 0x30)
            hasCode = true
            j += 1
        }
        
        // Parse alternates (colon-separated, used in kitty for shifted/base keys)
        // Format: code:shifted:base
        while j < bytes.count && bytes[j] == 0x3a {  // ':'
            j += 1
            while j < bytes.count && bytes[j] >= 0x30 && bytes[j] <= 0x39 {
                j += 1
            }
        }
        
        // Parse modifiers (after semicolon)
        var mods: Int = 1
        if j < bytes.count && bytes[j] == 0x3b {  // ';'
            j += 1
            mods = 0
            while j < bytes.count && bytes[j] >= 0x30 && bytes[j] <= 0x39 {
                mods = mods * 10 + Int(bytes[j] - 0x30)
                j += 1
            }
            
            // Skip event type (after colon) - we only care about the key, not press/release
            if j < bytes.count && bytes[j] == 0x3a {  // ':'
                j += 1
                while j < bytes.count && bytes[j] >= 0x30 && bytes[j] <= 0x39 {
                    j += 1
                }
            }
        }
        
        // Parse text section (after second semicolon, kitty report_associated mode)
        // Format: ;mods;text1:text2:...
        if j < bytes.count && bytes[j] == 0x3b {  // ';'
            j += 1
            // Skip the text codepoints
            while j < bytes.count && (bytes[j] >= 0x30 && bytes[j] <= 0x39 || bytes[j] == 0x3a) {
                j += 1
            }
        }
        
        // Check for final byte (must be in range 0x40-0x7e for CSI sequences)
        guard j < bytes.count && bytes[j] >= 0x40 && bytes[j] <= 0x7e else {
            return nil
        }
        
        let finalByte = bytes[j]
        let consumed = j - startIndex + 1
        let modifiers = KittyModifiers(sequenceValue: mods)
        
        // Try to match as a functional key
        if let functionalKey = FunctionalKey.from(code: code, final: finalByte) {
            let translated = functionalKey.toLegacyBytes(mods: modifiers)
            if !translated.isEmpty {
                return (translated, consumed)
            }
        }
        
        // Handle CSI u sequences for regular characters
        if finalByte == 0x75 {  // 'u'
            // Ctrl+letter -> C0 control code
            if modifiers.ctrl && !modifiers.shift {
                if code >= 0x40 && code <= 0x7f {
                    // Standard ctrl translation
                    var ctrlChar = code
                    if code >= 0x61 && code <= 0x7a {  // lowercase a-z
                        ctrlChar = code - 0x20  // convert to uppercase
                    }
                    let c0Code = UInt8((ctrlChar - 0x40) & 0x1f)
                    
                    var translated: [UInt8] = []
                    if modifiers.alt {
                        translated.append(0x1b)  // ESC prefix for Alt
                    }
                    translated.append(c0Code)
                    
                    return (translated, consumed)
                }
                
                // Special control codes (code < 0x20)
                if code < 0x20 {
                    var translated: [UInt8] = []
                    if modifiers.alt {
                        translated.append(0x1b)
                    }
                    translated.append(UInt8(code))
                    
                    return (translated, consumed)
                }
            }
            
            // Alt+character -> ESC + character
            if modifiers.alt && !modifiers.ctrl && !modifiers.shift {
                if code > 0 && code < 128 {
                    return ([0x1b, UInt8(code)], consumed)
                }
            }
            
            // Plain character (no modifiers or just shift) -> pass the character
            if !modifiers.hasBindingModifiers || (modifiers.shift && !modifiers.ctrl && !modifiers.alt) {
                if code > 0 && code < 128 {
                    return ([UInt8(code)], consumed)
                }
                // For Unicode characters, encode as UTF-8
                if code > 127 {
                    let utf8 = encodeUTF8(code)
                    return (utf8, consumed)
                }
            }
        }
        
        // For CSI ~ and letter sequences without special handling,
        // reconstruct legacy sequence format
        if finalByte == 0x7e || (finalByte >= 0x41 && finalByte <= 0x5a) {  // ~ or A-Z
            var legacy: [UInt8] = [0x1b, 0x5b]  // ESC [
            
            if hasCode && (finalByte == 0x7e || mods > 1) {
                for char in String(code).utf8 {
                    legacy.append(char)
                }
            }
            
            if mods > 1 {
                legacy.append(0x3b)  // ;
                for char in String(mods).utf8 {
                    legacy.append(char)
                }
            }
            
            legacy.append(finalByte)
            
            return (legacy, consumed)
        }
        
        // Unknown sequence - don't translate
        return nil
    }
    
    // MARK: - UTF-8 Encoding
    
    private func encodeUTF8(_ code: Int) -> [UInt8] {
        var utf8: [UInt8] = []
        if code < 0x80 {
            utf8.append(UInt8(code))
        } else if code < 0x800 {
            utf8.append(UInt8(0xC0 | (code >> 6)))
            utf8.append(UInt8(0x80 | (code & 0x3F)))
        } else if code < 0x10000 {
            utf8.append(UInt8(0xE0 | (code >> 12)))
            utf8.append(UInt8(0x80 | ((code >> 6) & 0x3F)))
            utf8.append(UInt8(0x80 | (code & 0x3F)))
        } else {
            utf8.append(UInt8(0xF0 | (code >> 18)))
            utf8.append(UInt8(0x80 | ((code >> 12) & 0x3F)))
            utf8.append(UInt8(0x80 | ((code >> 6) & 0x3F)))
            utf8.append(UInt8(0x80 | (code & 0x3F)))
        }
        return utf8
    }
}

// MARK: - Kitty Modifiers

/// Kitty keyboard protocol modifier bits (after subtracting 1 from sequence value)
struct KittyModifiers {
    let shift: Bool
    let alt: Bool
    let ctrl: Bool
    let superKey: Bool
    let hyper: Bool
    let meta: Bool
    let capsLock: Bool
    let numLock: Bool
    
    init(sequenceValue: Int) {
        // Sequence encodes mods+1, so subtract 1 to get raw bits
        let bits = sequenceValue > 0 ? sequenceValue - 1 : 0
        self.shift = (bits & 1) != 0
        self.alt = (bits & 2) != 0
        self.ctrl = (bits & 4) != 0
        self.superKey = (bits & 8) != 0
        self.hyper = (bits & 16) != 0
        self.meta = (bits & 32) != 0
        self.capsLock = (bits & 64) != 0
        self.numLock = (bits & 128) != 0
    }
    
    var hasBindingModifiers: Bool {
        ctrl || alt || superKey || hyper || meta
    }
}

// MARK: - Functional Keys

/// Functional key codes in the kitty protocol
/// Maps kitty protocol codes to legacy escape sequences
enum FunctionalKey {
    case escape         // 27
    case enter          // 13
    case tab            // 9
    case backspace      // 127
    case insert         // 2~
    case delete         // 3~
    case arrowLeft      // D
    case arrowRight     // C
    case arrowUp        // A
    case arrowDown      // B
    case pageUp         // 5~
    case pageDown       // 6~
    case home           // H
    case end            // F
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    case f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24, f25
    
    /// Convert kitty code to legacy bytes
    func toLegacyBytes(mods: KittyModifiers) -> [UInt8] {
        // For modified keys, we need to include the modifier in the sequence
        let modParam = mods.hasBindingModifiers ? modifierParam(mods) : nil
        
        switch self {
        case .escape:
            return [0x1b]
        case .enter:
            return [0x0d]  // CR
        case .tab:
            if mods.shift {
                return [0x1b, 0x5b, 0x5a]  // ESC[Z for Shift+Tab
            }
            return [0x09]
        case .backspace:
            if mods.ctrl {
                return [0x08]  // Ctrl+Backspace = BS
            }
            return [0x7f]  // DEL
        case .insert:
            return csiSequence(code: 2, final: 0x7e, mods: modParam)
        case .delete:
            return csiSequence(code: 3, final: 0x7e, mods: modParam)
        case .arrowUp:
            return csiSequence(code: modParam != nil ? 1 : nil, final: 0x41, mods: modParam)
        case .arrowDown:
            return csiSequence(code: modParam != nil ? 1 : nil, final: 0x42, mods: modParam)
        case .arrowRight:
            return csiSequence(code: modParam != nil ? 1 : nil, final: 0x43, mods: modParam)
        case .arrowLeft:
            return csiSequence(code: modParam != nil ? 1 : nil, final: 0x44, mods: modParam)
        case .home:
            return csiSequence(code: modParam != nil ? 1 : nil, final: 0x48, mods: modParam)
        case .end:
            return csiSequence(code: modParam != nil ? 1 : nil, final: 0x46, mods: modParam)
        case .pageUp:
            return csiSequence(code: 5, final: 0x7e, mods: modParam)
        case .pageDown:
            return csiSequence(code: 6, final: 0x7e, mods: modParam)
        case .f1:
            return csiSequence(code: modParam != nil ? 1 : nil, final: 0x50, mods: modParam)
        case .f2:
            return csiSequence(code: modParam != nil ? 1 : nil, final: 0x51, mods: modParam)
        case .f3:
            return csiSequence(code: 13, final: 0x7e, mods: modParam)
        case .f4:
            return csiSequence(code: modParam != nil ? 1 : nil, final: 0x53, mods: modParam)
        case .f5:
            return csiSequence(code: 15, final: 0x7e, mods: modParam)
        case .f6:
            return csiSequence(code: 17, final: 0x7e, mods: modParam)
        case .f7:
            return csiSequence(code: 18, final: 0x7e, mods: modParam)
        case .f8:
            return csiSequence(code: 19, final: 0x7e, mods: modParam)
        case .f9:
            return csiSequence(code: 20, final: 0x7e, mods: modParam)
        case .f10:
            return csiSequence(code: 21, final: 0x7e, mods: modParam)
        case .f11:
            return csiSequence(code: 23, final: 0x7e, mods: modParam)
        case .f12:
            return csiSequence(code: 24, final: 0x7e, mods: modParam)
        case .f13:
            return csiSequence(code: 25, final: 0x7e, mods: modParam)
        case .f14:
            return csiSequence(code: 26, final: 0x7e, mods: modParam)
        case .f15:
            return csiSequence(code: 28, final: 0x7e, mods: modParam)
        case .f16:
            return csiSequence(code: 29, final: 0x7e, mods: modParam)
        case .f17:
            return csiSequence(code: 31, final: 0x7e, mods: modParam)
        case .f18:
            return csiSequence(code: 32, final: 0x7e, mods: modParam)
        case .f19:
            return csiSequence(code: 33, final: 0x7e, mods: modParam)
        case .f20:
            return csiSequence(code: 34, final: 0x7e, mods: modParam)
        case .f21, .f22, .f23, .f24, .f25:
            // F21-F25 don't have standard legacy codes, pass as-is
            return []
        }
    }
    
    private func modifierParam(_ mods: KittyModifiers) -> Int {
        var param = 1
        if mods.shift { param += 1 }
        if mods.alt { param += 2 }
        if mods.ctrl { param += 4 }
        if mods.superKey { param += 8 }
        return param
    }
    
    private func csiSequence(code: Int?, final: UInt8, mods: Int?) -> [UInt8] {
        var result: [UInt8] = [0x1b, 0x5b]  // ESC [
        
        if let code = code {
            for char in String(code).utf8 {
                result.append(char)
            }
        }
        
        if let mods = mods {
            result.append(0x3b)  // ;
            for char in String(mods).utf8 {
                result.append(char)
            }
        }
        
        result.append(final)
        return result
    }
    
    /// Create from kitty protocol code and final byte
    static func from(code: Int, final: UInt8) -> FunctionalKey? {
        switch (code, final) {
        // CSI u sequences (final = 'u')
        case (27, 0x75): return .escape
        case (13, 0x75): return .enter
        case (9, 0x75): return .tab
        case (127, 0x75): return .backspace
        
        // CSI ~ sequences (final = '~')
        case (2, 0x7e): return .insert
        case (3, 0x7e): return .delete
        case (5, 0x7e): return .pageUp
        case (6, 0x7e): return .pageDown
        case (13, 0x7e): return .f3
        case (15, 0x7e): return .f5
        case (17, 0x7e): return .f6
        case (18, 0x7e): return .f7
        case (19, 0x7e): return .f8
        case (20, 0x7e): return .f9
        case (21, 0x7e): return .f10
        case (23, 0x7e): return .f11
        case (24, 0x7e): return .f12
        
        // High-numbered function keys (kitty-specific codes)
        case (57376, 0x75): return .f13
        case (57377, 0x75): return .f14
        case (57378, 0x75): return .f15
        case (57379, 0x75): return .f16
        case (57380, 0x75): return .f17
        case (57381, 0x75): return .f18
        case (57382, 0x75): return .f19
        case (57383, 0x75): return .f20
        case (57384, 0x75): return .f21
        case (57385, 0x75): return .f22
        case (57386, 0x75): return .f23
        case (57387, 0x75): return .f24
        case (57388, 0x75): return .f25
        
        // CSI letter sequences (code = 1 typically)
        case (_, 0x41): return .arrowUp      // A
        case (_, 0x42): return .arrowDown    // B
        case (_, 0x43): return .arrowRight   // C
        case (_, 0x44): return .arrowLeft    // D
        case (_, 0x48): return .home         // H
        case (_, 0x46): return .end          // F
        case (_, 0x50): return .f1           // P
        case (_, 0x51): return .f2           // Q
        case (_, 0x53): return .f4           // S
        
        default: return nil
        }
    }
}

// MARK: - Passthrough Translator

/// A no-op translator that passes data through unchanged
/// Useful for terminals that support the Kitty protocol natively
public struct PassthroughKeyboardTranslator: KeyboardTranslator, Sendable {
    public init() {}
    
    public func translate(_ data: Data) -> Data {
        return data
    }
}
