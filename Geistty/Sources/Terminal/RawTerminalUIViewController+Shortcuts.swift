//
//  RawTerminalUIViewController+Shortcuts.swift
//  Geistty
//
//  Ghostty ShortcutDelegate implementation for the terminal view controller.
//  Routes keyboard shortcuts to TmuxSessionManager for split/tab/window management.
//

import UIKit
import GhosttyKit
import os.log

private let logger = Logger(subsystem: "com.geistty", category: "Terminal")

// MARK: - Ghostty Shortcut Delegate

extension RawTerminalUIViewController: Ghostty.ShortcutDelegate {
    /// Handle Ghostty-style keyboard shortcuts
    /// Routes shortcuts to TmuxSessionManager for split/tab/window management
    func handleShortcut(_ action: Ghostty.ShortcutAction) -> Bool {
        guard let tmuxManager = viewModel?.tmuxManager else {
            // Not in tmux mode - shortcuts not applicable
            logger.debug("⌨️ Shortcut ignored - no tmux manager")
            return false
        }
        
        logger.info("⌨️ Handling shortcut: \(String(describing: action))")
        
        switch action {
        // MARK: - Split Management
        case .newSplitRight:
            tmuxManager.splitHorizontal()
            return true
            
        case .newSplitDown:
            tmuxManager.splitVertical()
            return true
            
        case .gotoSplitPrevious:
            tmuxManager.previousPane()
            return true
            
        case .gotoSplitNext:
            tmuxManager.nextPane()
            return true
            
        case .gotoSplitUp:
            tmuxManager.navigatePane(.up)
            return true
            
        case .gotoSplitDown:
            tmuxManager.navigatePane(.down)
            return true
            
        case .gotoSplitLeft:
            tmuxManager.navigatePane(.left)
            return true
            
        case .gotoSplitRight:
            tmuxManager.navigatePane(.right)
            return true
            
        case .toggleSplitZoom:
            tmuxManager.toggleTmuxZoom()
            return true
            
        case .equalizeSplits:
            tmuxManager.equalizeSplits()
            return true
            
        // MARK: - Tab/Window Management
        case .newTab:
            tmuxManager.newWindow()
            return true
            
        case .previousTab:
            tmuxManager.previousWindow()
            return true
            
        case .nextTab:
            tmuxManager.nextWindow()
            return true
            
        case .lastTab:
            tmuxManager.lastWindow()
            return true
            
        case .gotoTab(let index):
            tmuxManager.selectWindowByIndex(index)
            return true
            
        case .closeTab:
            tmuxManager.closeWindow()
            return true
            
        case .closeWindow:
            // On iOS, close window means close the tab (tmux window)
            tmuxManager.closeWindow()
            return true
            
        case .closeSurface:
            // Close current pane
            tmuxManager.closePane()
            return true
            
        case .newWindow:
            // On iOS, new window means new tmux window (tab)
            tmuxManager.newWindow()
            return true
            
        // MARK: - Connection Management
        case .reconnect:
            // Post notification for reconnect (handled by ContentView)
            NotificationCenter.default.post(name: .terminalReconnect, object: nil)
            return true
            
        case .disconnect:
            // Post notification for disconnect
            NotificationCenter.default.post(name: .terminalDisconnect, object: nil)
            return true
            
        // MARK: - Window Operations
        case .renameWindow:
            // Show rename dialog
            showRenameWindowDialog(tmuxManager: tmuxManager)
            return true
            
        // MARK: - Session Management
        case .showSessions:
            showSessionPicker()
            return true
        }
    }
    
    /// Show a dialog to rename the current tmux window
    private func showRenameWindowDialog(tmuxManager: TmuxSessionManager) {
        let alert = UIAlertController(
            title: "Rename Window",
            message: "Enter a new name for the tmux window",
            preferredStyle: .alert
        )
        
        // Get current window name
        let currentName = tmuxManager.windows[tmuxManager.focusedWindowId]?.name ?? ""
        
        alert.addTextField { textField in
            textField.text = currentName
            textField.placeholder = "Window name"
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
            textField.clearButtonMode = .whileEditing
        }
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak tmuxManager] _ in
            if let newName = alert.textFields?.first?.text, !newName.isEmpty {
                tmuxManager?.renameWindow(newName)
            }
        })
        
        present(alert, animated: true)
    }
}
