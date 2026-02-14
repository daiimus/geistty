import Foundation

// MARK: - TmuxSendKeys

/// Pure-function utility for wrapping raw terminal input bytes in tmux `send-keys`
/// commands suitable for control mode.
///
/// Uses iTerm2's proven approach:
/// - Safe chars (alphanumeric + `+/):,_.`): `send -lt %<id> '<chars>'`
/// - Everything else (control chars, escape seqs, space, special): `send -t %<id> 0x<hex>`
///
/// Batches consecutive same-type bytes. Commands are joined with ` ; ` separators
/// (tmux command separator) to reduce the number of SSH writes.
enum TmuxSendKeys {

    /// Characters that can be sent via `send -lt` (literal mode) without escaping.
    /// This matches iTerm2's safe character set for tmux send-keys.
    static let literalSafe: Set<UInt8> = {
        var safe = Set<UInt8>()
        // a-z
        for c in UInt8(ascii: "a")...UInt8(ascii: "z") { safe.insert(c) }
        // A-Z
        for c in UInt8(ascii: "A")...UInt8(ascii: "Z") { safe.insert(c) }
        // 0-9
        for c in UInt8(ascii: "0")...UInt8(ascii: "9") { safe.insert(c) }
        // iTerm2's additional safe chars: + / ) : , _ .
        for c: UInt8 in [
            UInt8(ascii: "+"), UInt8(ascii: "/"), UInt8(ascii: ")"),
            UInt8(ascii: ":"), UInt8(ascii: ","), UInt8(ascii: "_"),
            UInt8(ascii: ".")
        ] {
            safe.insert(c)
        }
        return safe
    }()

    /// Wrap raw user input bytes in tmux `send-keys` commands for a given pane.
    ///
    /// - Parameters:
    ///   - data: Raw bytes from Ghostty's key encoder
    ///   - paneId: The tmux pane ID (e.g. `2` for `%2`)
    /// - Returns: The wrapped command(s) as UTF-8 Data terminated by `\n`, or `nil` if
    ///   `data` is empty.
    static func wrap(_ data: Data, paneId: Int) -> Data? {
        guard !data.isEmpty else { return nil }

        let target = "%\(paneId)"
        var commands: [String] = []
        var literalBuffer = ""

        /// Flush accumulated literal chars into a send-keys command
        func flushLiteral() {
            guard !literalBuffer.isEmpty else { return }
            // Single-quote the literal string to prevent tmux from interpreting
            // special characters. Escape embedded single quotes with '\'' .
            let escaped = literalBuffer.replacingOccurrences(of: "'", with: "'\\''")
            commands.append("send -lt \(target) '\(escaped)'")
            literalBuffer = ""
        }

        for byte in data {
            if literalSafe.contains(byte) {
                literalBuffer.append(Character(UnicodeScalar(byte)))
            } else {
                // Non-literal byte — flush any accumulated literals first
                flushLiteral()
                // Send as hex
                commands.append("send -t \(target) 0x\(String(format: "%02x", byte))")
            }
        }

        // Flush any remaining literals
        flushLiteral()

        guard !commands.isEmpty else { return nil }

        // Join with tmux command separator and terminate with newline.
        // tmux reads one command per line in control mode, but ` ; ` allows
        // multiple commands on a single line.
        let line = commands.joined(separator: " ; ") + "\n"

        return line.data(using: .utf8)
    }
}
