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
        menuBarObservers.append(nc.addObserver(forName: .terminalJumpToPromptUp, object: nil, queue: .main) { [weak self] _ in
            self?.handleJumpToPrompt(delta: -1)
        })
        menuBarObservers.append(nc.addObserver(forName: .terminalJumpToPromptDown, object: nil, queue: .main) { [weak self] _ in
            self?.handleJumpToPrompt(delta: 1)
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
        
        // Command palette
        menuBarObservers.append(nc.addObserver(forName: .toggleCommandPalette, object: nil, queue: .main) { [weak self] _ in
            self?.toggleCommandPalette()
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
    
    func handleJumpToPrompt(delta: Int) {
        viewModel?.jumpToPrompt(delta: delta)
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
        Cmd+Up       Jump to Previous Prompt
        Cmd+Down     Jump to Next Prompt
        Cmd+Shift+P  Command Palette
        Cmd+W        Disconnect
        
        Ctrl+C       Interrupt (SIGINT)
        Ctrl+D       EOF / Logout
        Ctrl+L       Clear Screen
        Ctrl+Z       Suspend
        
        Arrow Keys   Navigate
        Tab          Complete
        Esc          Cancel
        
        Note: Jump to Prompt requires shell
        integration (OSC 133) on the remote host.
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
    
    // MARK: - Command Palette
    
    func toggleCommandPalette() {
        // If already showing, dismiss it
        if commandPaletteHostingController != nil {
            removeCommandPalette()
            return
        }
        
        // Get command entries from Ghostty config
        guard let config = ghosttyApp?.config else {
            logger.warning("Command palette: no config available")
            return
        }
        let commands = config.commandPaletteEntries
        guard !commands.isEmpty else {
            logger.warning("Command palette: no command entries available")
            return
        }
        
        // Create the command palette view with a binding
        // We use a class wrapper to give SwiftUI a mutable binding
        let state = CommandPaletteState()
        state.isPresented = true
        
        let paletteView = CommandPaletteWrapper(
            state: state,
            commands: commands,
            onAction: { [weak self] actionStr in
                self?.executeCommandPaletteAction(actionStr)
            },
            onDismiss: { [weak self] in
                self?.removeCommandPalette()
                // Return focus to terminal
                self?.surfaceView?.becomeFirstResponder()
            }
        )
        
        let hostingController = UIHostingController(rootView: AnyView(paletteView))
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        
        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.didMove(toParent: self)
        
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        
        commandPaletteHostingController = hostingController
        logger.info("Command palette shown with \(commands.count) entries")
    }
    
    func removeCommandPalette() {
        guard let hc = commandPaletteHostingController else { return }
        hc.willMove(toParent: nil)
        hc.view.removeFromSuperview()
        hc.removeFromParent()
        commandPaletteHostingController = nil
    }
    
    private func executeCommandPaletteAction(_ actionStr: String) {
        guard let surface = surfaceView?.surface else {
            logger.warning("Command palette: no surface to execute action on")
            return
        }
        actionStr.withCString { cstr in
            ghostty_surface_binding_action(surface, cstr, UInt(actionStr.utf8.count))
        }
        logger.info("Command palette executed: \(actionStr)")
    }
}
