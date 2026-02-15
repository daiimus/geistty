//
//  RawTerminalUIViewController+MenuBar.swift
//  Geistty
//
//  Menu bar notification setup and action handlers for the terminal view controller.
//

import UIKit
import SwiftUI
import GhosttyKit
import os.log

private let logger = Logger(subsystem: "com.geistty", category: "Terminal")

// MARK: - Menu Bar

extension RawTerminalUIViewController {
    
    func setupMenuBarNotifications() {
        let nc = NotificationCenter.default
        
        // Terminal actions
        menuBarObservers.append(nc.addObserver(forName: .terminalClearScreen, object: nil, queue: .main) { [weak self] _ in
            self?.handleClearScreen()
        })
        menuBarObservers.append(nc.addObserver(forName: .terminalReset, object: nil, queue: .main) { [weak self] _ in
            self?.handleResetTerminal()
        })
        menuBarObservers.append(nc.addObserver(forName: .terminalIncreaseFontSize, object: nil, queue: .main) { [weak self] _ in
            self?.handleIncreaseFontSize()
        })
        menuBarObservers.append(nc.addObserver(forName: .terminalDecreaseFontSize, object: nil, queue: .main) { [weak self] _ in
            self?.handleDecreaseFontSize()
        })
        menuBarObservers.append(nc.addObserver(forName: .terminalResetFontSize, object: nil, queue: .main) { [weak self] _ in
            self?.handleResetFontSize()
        })
        menuBarObservers.append(nc.addObserver(forName: .terminalSelectAll, object: nil, queue: .main) { [weak self] _ in
            self?.handleSelectAll()
        })
        menuBarObservers.append(nc.addObserver(forName: .showKeyboardShortcuts, object: nil, queue: .main) { [weak self] _ in
            self?.showKeyboardShortcutsHelp()
        })
        menuBarObservers.append(nc.addObserver(forName: .showSettings, object: nil, queue: .main) { [weak self] _ in
            self?.handleSettingsButton()
        })
        menuBarObservers.append(nc.addObserver(forName: .reloadConfiguration, object: nil, queue: .main) { [weak self] _ in
            self?.reloadConfiguration()
        })
        
        // Copy/Paste
        menuBarObservers.append(nc.addObserver(forName: .terminalCopy, object: nil, queue: .main) { [weak self] _ in
            self?.viewModel?.copy()
        })
        menuBarObservers.append(nc.addObserver(forName: .terminalPaste, object: nil, queue: .main) { [weak self] _ in
            self?.viewModel?.paste()
        })
        
        // Search/Find
        menuBarObservers.append(nc.addObserver(forName: .terminalFind, object: nil, queue: .main) { [weak self] _ in
            self?.handleFind()
        })
        menuBarObservers.append(nc.addObserver(forName: .terminalFindNext, object: nil, queue: .main) { [weak self] _ in
            self?.handleFindNext()
        })
        menuBarObservers.append(nc.addObserver(forName: .terminalFindPrevious, object: nil, queue: .main) { [weak self] _ in
            self?.handleFindPrevious()
        })
        menuBarObservers.append(nc.addObserver(forName: .terminalHideFindBar, object: nil, queue: .main) { [weak self] _ in
            self?.closeSearch()
        })
        
        // Background opacity toggle
        menuBarObservers.append(nc.addObserver(forName: .toggleBackgroundOpacity, object: nil, queue: .main) { [weak self] _ in
            self?.toggleBackgroundOpacity()
        })
        
        // Connection management
        menuBarObservers.append(nc.addObserver(forName: .terminalDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.handleBackButton()
        })
        // Note: terminalReconnect is handled in ContentView which has access to appState
    }
    
    // MARK: - Menu Action Handlers
    
    func handleSelectAll() {
        // Select all text in terminal
        // TODO: Implement via Ghostty API if available
        viewModel?.surfaceView?.selectAll()
    }
    
    /// Toggle between transparent and opaque background
    /// Saves state to config file and reloads configuration
    func toggleBackgroundOpacity() {
        let currentOpacity = ConfigSyncManager.shared.getBackgroundOpacity()
        let newOpacity: Double
        
        if currentOpacity < 1.0 {
            // Currently transparent → make opaque
            newOpacity = 1.0
        } else {
            // Currently opaque → use configured transparent value (default 0.95)
            // Or use the stored transparent value if user had set one
            let settings = AppSettings.shared
            newOpacity = settings.backgroundOpacity < 1.0 ? settings.backgroundOpacity : 0.95
        }
        
        ConfigSyncManager.shared.updateBackgroundOpacity(newOpacity)
        reloadConfiguration()
        
        logger.info("🎨 Toggled background opacity: \(currentOpacity) → \(newOpacity)")
    }
    
    func handleIncreaseFontSize() {
        let currentSize = viewModel?.currentFontSize ?? 14
        viewModel?.setFontSize(Int(currentSize) + 1)
    }
    
    func handleDecreaseFontSize() {
        let currentSize = viewModel?.currentFontSize ?? 14
        viewModel?.setFontSize(max(8, Int(currentSize) - 1))
    }
    
    func handleResetFontSize() {
        viewModel?.resetFontSize()
    }
    
    func handleClearScreen() {
        viewModel?.clearScreen()
    }
    
    func handleResetTerminal() {
        viewModel?.resetTerminal()
    }
    
    func showKeyboardShortcutsHelp() {
        let shortcuts = """
        Keyboard Shortcuts
        
        Cmd+C        Copy
        Cmd+V        Paste
        Cmd+K        Clear Screen
        Cmd+0        Reset Font Size
        Cmd++        Increase Font Size
        Cmd+-        Decrease Font Size
        Cmd+W        Disconnect
        
        Ctrl+C       Interrupt (SIGINT)
        Ctrl+D       EOF / Logout
        Ctrl+L       Clear Screen
        Ctrl+Z       Suspend
        
        Arrow Keys   Navigate
        Tab          Complete
        Esc          Cancel
        """
        
        let alert = UIAlertController(title: nil, message: shortcuts, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
    
    @objc func handleBackButton() {
        // Disconnect SSH session. Navigation back to the connection list is handled
        // by ContentView's .terminalDisconnect observer setting appState.connectionStatus.
        // Do NOT post .terminalDisconnect here — this method IS the handler for that
        // notification (line 79), so re-posting would cause an infinite loop.
        viewModel?.disconnect()
    }
}
