//
//  CommandPaletteTests.swift
//  GeisttyTests
//
//  Tests for Ghostty.Command struct and CommandPaletteState.
//

import XCTest
@testable import Geistty

final class CommandPaletteTests: XCTestCase {

    // MARK: - Ghostty.Command: isSupported

    func testSupportedActionReturnsTrue() {
        let cmd = Ghostty.Command(
            title: "Clear Screen",
            description: "Clears the terminal",
            action: "clear_screen",
            actionKey: "clear_screen"
        )
        XCTAssertTrue(cmd.isSupported)
    }

    func testJumpToPromptIsSupported() {
        let cmd = Ghostty.Command(
            title: "Jump to Previous Prompt",
            description: "Jump to previous shell prompt",
            action: "jump_to_prompt:-1",
            actionKey: "jump_to_prompt"
        )
        XCTAssertTrue(cmd.isSupported)
    }

    func testGotoSplitIsSupported() {
        let cmd = Ghostty.Command(
            title: "Go to Left Split",
            description: "Focus split to the left",
            action: "goto_split:left",
            actionKey: "goto_split"
        )
        XCTAssertTrue(cmd.isSupported)
    }

    func testCopyToClipboardIsSupported() {
        let cmd = Ghostty.Command(
            title: "Copy to Clipboard",
            description: "Copy selection",
            action: "copy_to_clipboard",
            actionKey: "copy_to_clipboard"
        )
        XCTAssertTrue(cmd.isSupported)
    }

    func testPasteFromClipboardIsSupported() {
        let cmd = Ghostty.Command(
            title: "Paste from Clipboard",
            description: "Paste from clipboard",
            action: "paste_from_clipboard",
            actionKey: "paste_from_clipboard"
        )
        XCTAssertTrue(cmd.isSupported)
    }

    func testResetTerminalIsSupported() {
        let cmd = Ghostty.Command(
            title: "Reset Terminal",
            description: "Reset terminal state",
            action: "reset",
            actionKey: "reset"
        )
        XCTAssertTrue(cmd.isSupported)
    }

    func testToggleCommandPaletteIsSupported() {
        let cmd = Ghostty.Command(
            title: "Toggle Command Palette",
            description: "Show/hide command palette",
            action: "toggle_command_palette",
            actionKey: "toggle_command_palette"
        )
        XCTAssertTrue(cmd.isSupported)
    }

    // MARK: - Unsupported Actions

    func testNewWindowIsUnsupported() {
        let cmd = Ghostty.Command(
            title: "New Window",
            description: "Open a new window",
            action: "new_window",
            actionKey: "new_window"
        )
        XCTAssertFalse(cmd.isSupported)
    }

    func testCloseWindowIsUnsupported() {
        let cmd = Ghostty.Command(
            title: "Close Window",
            description: "Close the window",
            action: "close_window",
            actionKey: "close_window"
        )
        XCTAssertFalse(cmd.isSupported)
    }

    func testToggleFullscreenIsUnsupported() {
        let cmd = Ghostty.Command(
            title: "Toggle Fullscreen",
            description: "Toggle fullscreen mode",
            action: "toggle_fullscreen",
            actionKey: "toggle_fullscreen"
        )
        XCTAssertFalse(cmd.isSupported)
    }

    func testNewTabIsUnsupported() {
        let cmd = Ghostty.Command(
            title: "New Tab",
            description: "Open a new tab",
            action: "new_tab",
            actionKey: "new_tab"
        )
        XCTAssertFalse(cmd.isSupported)
    }

    func testCloseTabIsUnsupported() {
        let cmd = Ghostty.Command(
            title: "Close Tab",
            description: "Close the current tab",
            action: "close_tab",
            actionKey: "close_tab"
        )
        XCTAssertFalse(cmd.isSupported)
    }

    func testGotoTabIsUnsupported() {
        let cmd = Ghostty.Command(
            title: "Go to Tab 3",
            description: "Switch to tab 3",
            action: "goto_tab:3",
            actionKey: "goto_tab"
        )
        XCTAssertFalse(cmd.isSupported)
    }

    func testQuitIsUnsupported() {
        let cmd = Ghostty.Command(
            title: "Quit",
            description: "Quit the application",
            action: "quit",
            actionKey: "quit"
        )
        XCTAssertFalse(cmd.isSupported)
    }

    func testShowGtkInspectorIsUnsupported() {
        let cmd = Ghostty.Command(
            title: "Show GTK Inspector",
            description: "Open GTK inspector",
            action: "show_gtk_inspector",
            actionKey: "show_gtk_inspector"
        )
        XCTAssertFalse(cmd.isSupported)
    }

    func testOpenConfigIsUnsupported() {
        let cmd = Ghostty.Command(
            title: "Open Config",
            description: "Open configuration file",
            action: "open_config",
            actionKey: "open_config"
        )
        XCTAssertFalse(cmd.isSupported)
    }

    func testToggleQuickTerminalIsUnsupported() {
        let cmd = Ghostty.Command(
            title: "Toggle Quick Terminal",
            description: "Toggle quick terminal overlay",
            action: "toggle_quick_terminal",
            actionKey: "toggle_quick_terminal"
        )
        XCTAssertFalse(cmd.isSupported)
    }

    func testUndoIsUnsupported() {
        let cmd = Ghostty.Command(
            title: "Undo",
            description: "Undo last action",
            action: "undo",
            actionKey: "undo"
        )
        XCTAssertFalse(cmd.isSupported)
    }

    func testRedoIsUnsupported() {
        let cmd = Ghostty.Command(
            title: "Redo",
            description: "Redo last action",
            action: "redo",
            actionKey: "redo"
        )
        XCTAssertFalse(cmd.isSupported)
    }

    // MARK: - All unsupported keys covered

    func testAllUnsupportedKeysAreTestedExhaustively() {
        // Verify the set contains exactly the expected count
        XCTAssertEqual(Ghostty.Command.unsupportedActionKeys.count, 22)
    }

    func testEveryUnsupportedKeyMakesCommandUnsupported() {
        for key in Ghostty.Command.unsupportedActionKeys {
            let cmd = Ghostty.Command(
                title: "Test \(key)",
                description: "Test",
                action: key,
                actionKey: key
            )
            XCTAssertFalse(cmd.isSupported, "Expected \(key) to be unsupported")
        }
    }

    func testUnsupportedActionKeysContainsAllWindowManagement() {
        let windowKeys: Set<String> = [
            "new_window", "close_window", "close_all_windows",
            "toggle_fullscreen", "toggle_maximize", "float_window",
            "toggle_quick_terminal", "toggle_visibility", "toggle_window_decorations"
        ]
        XCTAssertTrue(windowKeys.isSubset(of: Ghostty.Command.unsupportedActionKeys))
    }

    func testUnsupportedActionKeysContainsAllTabManagement() {
        let tabKeys: Set<String> = [
            "new_tab", "close_tab", "previous_tab", "next_tab",
            "last_tab", "goto_tab", "move_tab"
        ]
        XCTAssertTrue(tabKeys.isSubset(of: Ghostty.Command.unsupportedActionKeys))
    }

    // MARK: - Edge cases

    func testEmptyActionKeyIsSupported() {
        // An empty action key should not match any unsupported key
        let cmd = Ghostty.Command(
            title: "Empty",
            description: "",
            action: "",
            actionKey: ""
        )
        XCTAssertTrue(cmd.isSupported)
    }

    func testActionKeyWithParameterStillFiltered() {
        // The actionKey should be just the key part, not include parameters.
        // If someone passes "new_window" as the actionKey (even if action is "new_window:foo"),
        // it should still be filtered.
        let cmd = Ghostty.Command(
            title: "New Window with Args",
            description: "Test",
            action: "new_window:some_arg",
            actionKey: "new_window"
        )
        XCTAssertFalse(cmd.isSupported)
    }

    func testSimilarButDifferentActionKeyIsSupported() {
        // "new_window_tab" is not "new_window" — should pass
        let cmd = Ghostty.Command(
            title: "Hypothetical",
            description: "Test",
            action: "new_window_tab",
            actionKey: "new_window_tab"
        )
        XCTAssertTrue(cmd.isSupported)
    }

    func testPartialMatchDoesNotFilter() {
        // "close" alone is not in the unsupported set
        let cmd = Ghostty.Command(
            title: "Close",
            description: "Test",
            action: "close",
            actionKey: "close"
        )
        XCTAssertTrue(cmd.isSupported)
    }

    // MARK: - Command properties

    func testCommandStoresAllProperties() {
        let cmd = Ghostty.Command(
            title: "My Title",
            description: "My Description",
            action: "my_action:param",
            actionKey: "my_action"
        )
        XCTAssertEqual(cmd.title, "My Title")
        XCTAssertEqual(cmd.description, "My Description")
        XCTAssertEqual(cmd.action, "my_action:param")
        XCTAssertEqual(cmd.actionKey, "my_action")
    }

    // MARK: - CommandPaletteState

    func testCommandPaletteStateDefaultsToNotPresented() {
        let state = CommandPaletteState()
        XCTAssertFalse(state.isPresented)
    }

    func testCommandPaletteStateCanBeToggled() {
        let state = CommandPaletteState()
        state.isPresented = true
        XCTAssertTrue(state.isPresented)
        state.isPresented = false
        XCTAssertFalse(state.isPresented)
    }
}
