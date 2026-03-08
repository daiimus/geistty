//
//  TmuxStatusBarView.swift
//  Geistty
//
//  A horizontal bar rendering tmux's expanded status-left and status-right text.
//  Driven reactively by format subscriptions (refresh-client -B) — the Zig viewer
//  subscribes to #{T:status-left} and #{T:status-right} at startup (tmux >= 3.2)
//  and the expanded text arrives via %subscription-changed notifications.
//

import SwiftUI

/// Renders the tmux status bar as a simple native SwiftUI view.
///
/// This is a first-pass implementation that displays the already-expanded text
/// from tmux's status-left and status-right options. tmux style attributes
/// (colors, bold, etc.) embedded in the expanded text are stripped for now —
/// full style parsing is a future enhancement.
struct TmuxStatusBarView: View {
    @ObservedObject var sessionManager: TmuxSessionManager

    /// Height of the status bar
    static let barHeight: CGFloat = 24

    /// Background color matching the window picker
    private let backgroundColor = Color(white: 0.12)

    var body: some View {
        HStack(spacing: 0) {
            Text(strippedStatus(sessionManager.statusLeft))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            Text(strippedStatus(sessionManager.statusRight))
                .lineLimit(1)
                .truncationMode(.head)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundColor(.secondary)
        .padding(.horizontal, 8)
        .frame(height: TmuxStatusBarView.barHeight)
        .frame(maxWidth: .infinity)
        .background(backgroundColor)
    }

    /// Strip tmux style sequences from expanded text.
    ///
    /// tmux's `#{T:status-left}` expansion may contain embedded style directives
    /// like `#[fg=green,bold]`. These are terminal-style instructions that don't
    /// render as visible text. This function removes them for plain-text display.
    private func strippedStatus(_ text: String) -> String {
        // tmux style tags: #[...] where ... can contain any characters except ]
        var result = ""
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "#",
               text.index(after: i) < text.endIndex,
               text[text.index(after: i)] == "[" {
                // Skip to closing ]
                var j = text.index(text.index(after: i), offsetBy: 1)
                while j < text.endIndex && text[j] != "]" {
                    j = text.index(after: j)
                }
                if j < text.endIndex {
                    // Skip past the ]
                    i = text.index(after: j)
                } else {
                    // No closing ], keep the rest as-is
                    result.append(contentsOf: text[i...])
                    return result
                }
            } else {
                result.append(text[i])
                i = text.index(after: i)
            }
        }
        return result
    }
}
