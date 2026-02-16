//
//  Ghostty.Command.swift
//  Geistty
//
//  Swift wrapper for ghostty_command_s — represents a command palette entry.
//  Ported from upstream Ghostty macOS with iOS-specific unsupported action filtering.
//

import GhosttyKit

extension Ghostty {
    /// Wraps `ghostty_command_s` — a single command palette entry from Ghostty config.
    struct Command: Sendable {
        /// The primary title displayed in the command palette.
        let title: String

        /// Human-friendly description of what this command will do.
        let description: String

        /// The full action string to pass to `ghostty_surface_binding_action`,
        /// e.g. "goto_split:left" or "clear_screen".
        let action: String

        /// Only the key portion of the action for filtering, e.g. "goto_split"
        /// instead of "goto_split:left".
        let actionKey: String

        /// Whether this command can be performed on iOS.
        var isSupported: Bool {
            !Self.unsupportedActionKeys.contains(actionKey)
        }

        /// Action keys that don't apply on iOS — desktop windowing concepts,
        /// GTK-specific features, and actions already handled by tmux shortcuts.
        static let unsupportedActionKeys: Set<String> = [
            // Desktop window management (no multi-window on iOS)
            "new_window",
            "close_window",
            "close_all_windows",
            "toggle_fullscreen",
            "toggle_maximize",
            "float_window",
            "toggle_quick_terminal",
            "toggle_visibility",
            "toggle_window_decorations",

            // Tab management (tmux windows serve as tabs; handled via ShortcutDelegate)
            "new_tab",
            "close_tab",
            "previous_tab",
            "next_tab",
            "last_tab",
            "goto_tab",
            "move_tab",

            // Desktop-only UI
            "toggle_tab_overview",
            "show_gtk_inspector",

            // macOS-specific
            "quit",
            "undo",
            "redo",

            // Already handled by iOS system / Geistty directly
            "open_config",
        ]

        init(cValue: ghostty_command_s) {
            self.title = String(cString: cValue.title)
            self.description = String(cString: cValue.description)
            self.action = String(cString: cValue.action)
            self.actionKey = String(cString: cValue.action_key)
        }

        /// Test-only memberwise initializer — avoids needing a C struct in unit tests.
        #if DEBUG
        init(title: String, description: String, action: String, actionKey: String) {
            self.title = title
            self.description = description
            self.action = action
            self.actionKey = actionKey
        }
        #endif
    }
}
