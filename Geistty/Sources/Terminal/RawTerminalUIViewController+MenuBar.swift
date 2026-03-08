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
        
        // A7 fix: Guard against cross-window command leaking on iPad multi-window.
        // Notifications are broadcast to all windows; only the foreground scene should act.
        // reloadConfiguration is intentionally unguarded — config changes are global.
        
        // Terminal actions
        menuBarObservers.append(nc.addObserver(forName: .terminalClearScreen, object: nil, queue: .main) { [weak self] _ in
            guard self?.isInForegroundScene == true else { return }
            self?.handleClearScreen()
        })
        menuBarObservers.append(nc.addObserver(forName: .terminalReset, object: nil, queue: .main) { [weak self] _ in
            guard self?.isInForegroundScene == true else { return }
            self?.handleResetTerminal()
        })
        menuBarObservers.append(nc.addObserver(forName: .terminalIncreaseFontSize, object: nil, queue: .main) { [weak self] _ in
            guard self?.isInForegroundScene == true else { return }
            self?.handleIncreaseFontSize()
        })
        menuBarObservers.append(nc.addObserver(forName: .terminalDecreaseFontSize, object: nil, queue: .main) { [weak self] _ in
            guard self?.isInForegroundScene == true else { return }
            self?.handleDecreaseFontSize()
        })
        menuBarObservers.append(nc.addObserver(forName: .terminalResetFontSize, object: nil, queue: .main) { [weak self] _ in
            guard self?.isInForegroundScene == true else { return }
            self?.handleResetFontSize()
        })
        menuBarObservers.append(nc.addObserver(forName: .terminalJumpToPromptUp, object: nil, queue: .main) { [weak self] _ in
            guard self?.isInForegroundScene == true else { return }
            self?.handleJumpToPrompt(delta: -1)
        })
        menuBarObservers.append(nc.addObserver(forName: .terminalJumpToPromptDown, object: nil, queue: .main) { [weak self] _ in
            guard self?.isInForegroundScene == true else { return }
            self?.handleJumpToPrompt(delta: 1)
        })
        menuBarObservers.append(nc.addObserver(forName: .terminalSelectAll, object: nil, queue: .main) { [weak self] _ in
            guard self?.isInForegroundScene == true else { return }
            self?.handleSelectAll()
        })
        menuBarObservers.append(nc.addObserver(forName: .showKeyboardShortcuts, object: nil, queue: .main) { [weak self] _ in
            guard self?.isInForegroundScene == true else { return }
            self?.showKeyboardShortcutsHelp()
        })
        menuBarObservers.append(nc.addObserver(forName: .showSettings, object: nil, queue: .main) { [weak self] _ in
            guard self?.isInForegroundScene == true else { return }
            self?.handleSettingsButton()
        })
        // reloadConfiguration is global — settings changes apply to all windows
        menuBarObservers.append(nc.addObserver(forName: .reloadConfiguration, object: nil, queue: .main) { [weak self] _ in
            self?.reloadConfiguration()
        })
        
        // Copy/Paste
        menuBarObservers.append(nc.addObserver(forName: .terminalCopy, object: nil, queue: .main) { [weak self] _ in
            guard self?.isInForegroundScene == true else {
                logger.debug("terminalCopy: skipped (not in foreground scene)")
                return
            }
            if self?.viewModel == nil {
                logger.warning("terminalCopy: viewModel is nil")
            }
            self?.viewModel?.copy()
        })
        menuBarObservers.append(nc.addObserver(forName: .terminalPaste, object: nil, queue: .main) { [weak self] _ in
            guard self?.isInForegroundScene == true else {
                logger.debug("terminalPaste: skipped (not in foreground scene)")
                return
            }
            if self?.viewModel == nil {
                logger.warning("terminalPaste: viewModel is nil")
            }
            self?.viewModel?.paste()
        })
        
        // Search/Find
        menuBarObservers.append(nc.addObserver(forName: .terminalFind, object: nil, queue: .main) { [weak self] _ in
            guard self?.isInForegroundScene == true else { return }
            self?.handleFind()
        })
        menuBarObservers.append(nc.addObserver(forName: .terminalFindNext, object: nil, queue: .main) { [weak self] _ in
            guard self?.isInForegroundScene == true else { return }
            self?.handleFindNext()
        })
        menuBarObservers.append(nc.addObserver(forName: .terminalFindPrevious, object: nil, queue: .main) { [weak self] _ in
            guard self?.isInForegroundScene == true else { return }
            self?.handleFindPrevious()
        })
        menuBarObservers.append(nc.addObserver(forName: .terminalHideFindBar, object: nil, queue: .main) { [weak self] _ in
            guard self?.isInForegroundScene == true else { return }
            self?.closeSearch()
        })
        
        // Background opacity toggle
        menuBarObservers.append(nc.addObserver(forName: .toggleBackgroundOpacity, object: nil, queue: .main) { [weak self] _ in
            guard self?.isInForegroundScene == true else { return }
            self?.toggleBackgroundOpacity()
        })
        
        // Command palette
        menuBarObservers.append(nc.addObserver(forName: .toggleCommandPalette, object: nil, queue: .main) { [weak self] _ in
            guard self?.isInForegroundScene == true else { return }
            self?.toggleCommandPalette()
        })
        
        // Connection management
        menuBarObservers.append(nc.addObserver(forName: .terminalDisconnect, object: nil, queue: .main) { [weak self] _ in
            guard self?.isInForegroundScene == true else { return }
            self?.handleBackButton()
        })
        // Note: terminalReconnect is handled in ContentView which has access to appState
        
        // tmux session management
        menuBarObservers.append(nc.addObserver(forName: .showTmuxSessions, object: nil, queue: .main) { [weak self] _ in
            guard self?.isInForegroundScene == true else { return }
            self?.showSessionPicker()
        })
    }
    
    /// Whether this view controller's window scene is in the foreground.
    /// Used by notification handlers to prevent cross-window command leaking
    /// on iPad multi-window (Split View, Slide Over). See issue #30 / A7 fix.
    private var isInForegroundScene: Bool {
        view.window?.windowScene?.activationState == .foregroundActive
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
        let helpVC = KeyboardShortcutsHelpController()
        let nav = UINavigationController(rootViewController: helpVC)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
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

// MARK: - Keyboard Shortcuts Help Controller

/// Full-screen scrollable keyboard shortcuts reference.
/// Uses a plain UITableView grouped by category for clean presentation
/// and easy scrollability on all device sizes.
final class KeyboardShortcutsHelpController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    
    private struct Shortcut {
        let keys: String
        let action: String
    }
    
    private struct Section {
        let title: String
        let footnote: String?
        let shortcuts: [Shortcut]
    }
    
    private let sections: [Section] = [
        Section(title: "General", footnote: nil, shortcuts: [
            Shortcut(keys: "\u{2318}C", action: "Copy"),
            Shortcut(keys: "\u{2318}V", action: "Paste"),
            Shortcut(keys: "\u{2318}A", action: "Select All"),
            Shortcut(keys: "\u{2318}F", action: "Find"),
            Shortcut(keys: "\u{2318}G", action: "Find Next"),
            Shortcut(keys: "\u{21E7}\u{2318}G", action: "Find Previous"),
            Shortcut(keys: "\u{2318}W", action: "Disconnect"),
            Shortcut(keys: "\u{2318}R", action: "Reconnect"),
            Shortcut(keys: "\u{2318},", action: "Settings"),
        ]),
        Section(title: "Terminal", footnote: "Jump to Prompt requires shell integration (OSC 133) on the remote host.", shortcuts: [
            Shortcut(keys: "\u{2318}K", action: "Clear Screen"),
            Shortcut(keys: "\u{2318}\u{2191}", action: "Jump to Previous Prompt"),
            Shortcut(keys: "\u{2318}\u{2193}", action: "Jump to Next Prompt"),
            Shortcut(keys: "\u{21E7}\u{2318}P", action: "Command Palette"),
            Shortcut(keys: "\u{2318}/", action: "Keyboard Shortcuts"),
            Shortcut(keys: "\u{21E7}\u{2318},", action: "Reload Configuration"),
            Shortcut(keys: "\u{2318}U", action: "Toggle Background Transparency"),
        ]),
        Section(title: "Font Size", footnote: nil, shortcuts: [
            Shortcut(keys: "\u{2318}+", action: "Increase"),
            Shortcut(keys: "\u{2318}\u{2212}", action: "Decrease"),
            Shortcut(keys: "\u{2318}0", action: "Reset"),
        ]),
        Section(title: "tmux Panes", footnote: "Requires an active tmux session.", shortcuts: [
            Shortcut(keys: "\u{2318}D", action: "Split Right"),
            Shortcut(keys: "\u{21E7}\u{2318}D", action: "Split Down"),
            Shortcut(keys: "\u{2318}[", action: "Previous Pane"),
            Shortcut(keys: "\u{2318}]", action: "Next Pane"),
            Shortcut(keys: "\u{2325}\u{2318}\u{2191}", action: "Navigate Up"),
            Shortcut(keys: "\u{2325}\u{2318}\u{2193}", action: "Navigate Down"),
            Shortcut(keys: "\u{2325}\u{2318}\u{2190}", action: "Navigate Left"),
            Shortcut(keys: "\u{2325}\u{2318}\u{2192}", action: "Navigate Right"),
            Shortcut(keys: "\u{21E7}\u{2318}\u{21A9}", action: "Toggle Zoom"),
            Shortcut(keys: "\u{2303}\u{2318}=", action: "Equalize Panes"),
        ]),
        Section(title: "tmux Windows", footnote: nil, shortcuts: [
            Shortcut(keys: "\u{2318}T", action: "New Window"),
            Shortcut(keys: "\u{21E7}\u{2318}[", action: "Previous Window"),
            Shortcut(keys: "\u{21E7}\u{2318}]", action: "Next Window"),
            Shortcut(keys: "\u{2318}1\u{2013}8", action: "Go to Window N"),
            Shortcut(keys: "\u{2318}9", action: "Last Window"),
            Shortcut(keys: "\u{21E7}\u{2318}W", action: "Close Window"),
            Shortcut(keys: "\u{21E7}\u{2318}R", action: "Rename Window"),
        ]),
        Section(title: "tmux Sessions", footnote: nil, shortcuts: [
            Shortcut(keys: "\u{21E7}\u{2318}S", action: "Session Picker"),
        ]),
        Section(title: "Terminal Input", footnote: nil, shortcuts: [
            Shortcut(keys: "\u{2303}C", action: "Interrupt (SIGINT)"),
            Shortcut(keys: "\u{2303}D", action: "EOF / Logout"),
            Shortcut(keys: "\u{2303}L", action: "Clear Screen"),
            Shortcut(keys: "\u{2303}Z", action: "Suspend"),
        ]),
    ]
    
    private var tableView: UITableView!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = .systemGroupedBackground
        
        // Navigation bar
        title = "Keyboard Shortcuts"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(dismissHelp)
        )
        
        // Table view
        tableView = UITableView(frame: .zero, style: .insetGrouped)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ShortcutCell")
        tableView.allowsSelection = false
        view.addSubview(tableView)
        
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
    
    @objc private func dismissHelp() {
        dismiss(animated: true)
    }
    
    // MARK: - UITableViewDataSource
    
    func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].shortcuts.count
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        sections[section].footnote
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "ShortcutCell", for: indexPath)
        let shortcut = sections[indexPath.section].shortcuts[indexPath.row]
        
        var content = cell.defaultContentConfiguration()
        content.text = shortcut.action
        content.secondaryText = shortcut.keys
        content.prefersSideBySideTextAndSecondaryText = true
        content.secondaryTextProperties.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        cell.accessibilityIdentifier = "shortcut_\(shortcut.action.lowercased().replacingOccurrences(of: " ", with: "_"))"
        
        return cell
    }
}
