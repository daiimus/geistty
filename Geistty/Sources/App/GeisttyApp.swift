import SwiftUI
import GhosttyKit

@main
struct GeisttyApp: App {
    // Ghostty backend is shared across all windows
    @StateObject private var ghosttyApp = Ghostty.App()
    
    init() {
        // CRITICAL: Set the window background color to match the theme
        // This prevents the gray system background from showing through
        // during any view transitions or layout changes
        let themeBg = ThemeManager.shared.selectedTheme.background
        let bgColor = UIColor(themeBg)
        
        // Set default background for all windows
        UIWindow.appearance().backgroundColor = bgColor
        
        // Also set for UIView to catch any edge cases
        // UIView.appearance().backgroundColor = bgColor  // Too aggressive, breaks other UI
    }
    
    var body: some Scene {
        WindowGroup {
            // Each window gets its own AppState for independent sessions
            WindowContentView()
                .environmentObject(ghosttyApp)
                .onAppear {
                    // Ensure window background is set after scene is created
                    setWindowBackground()
                }
        }
        .commands {
            // MARK: - App Menu (Geistty menu)
            // Add Preferences to the app menu (Cmd+,)
            CommandGroup(replacing: .appSettings) {
                Button("Preferences…") {
                    NotificationCenter.default.post(name: .showSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            
            // MARK: - File Menu
            // Replace "New" with connection-related items
            CommandGroup(replacing: .newItem) {
                Button("New Connection…") {
                    NotificationCenter.default.post(name: .showNewConnection, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
                
                Button("Quick Connect…") {
                    NotificationCenter.default.post(name: .showQuickConnect, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                
                Divider()
                
                Button("Close Connection") {
                    NotificationCenter.default.post(name: .terminalDisconnect, object: nil)
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            
            // MARK: - Edit Menu
            // Add Copy, Paste, Select All, and Find commands
            // Note: System provides "Show Keyboard" / "Hide Keyboard" automatically
            CommandGroup(replacing: .pasteboard) {
                Button("Copy") {
                    NotificationCenter.default.post(name: .terminalCopy, object: nil)
                }
                .keyboardShortcut("c", modifiers: .command)
                
                Button("Paste") {
                    NotificationCenter.default.post(name: .terminalPaste, object: nil)
                }
                .keyboardShortcut("v", modifiers: .command)
                
                Divider()
                
                Button("Select All") {
                    NotificationCenter.default.post(name: .terminalSelectAll, object: nil)
                }
                .keyboardShortcut("a", modifiers: .command)
                
                Divider()
                
                Menu("Find") {
                    Button("Find…") {
                        NotificationCenter.default.post(name: .terminalFind, object: nil)
                    }
                    .keyboardShortcut("f", modifiers: .command)
                    
                    Button("Find Next") {
                        NotificationCenter.default.post(name: .terminalFindNext, object: nil)
                    }
                    .keyboardShortcut("g", modifiers: .command)
                    
                    Button("Find Previous") {
                        NotificationCenter.default.post(name: .terminalFindPrevious, object: nil)
                    }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    
                    Divider()
                    
                    Button("Hide Find Bar") {
                        NotificationCenter.default.post(name: .terminalHideFindBar, object: nil)
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                }
            }
            
            // MARK: - View Menu
            CommandGroup(replacing: .toolbar) {
                Button("Increase Font Size") {
                    NotificationCenter.default.post(name: .terminalIncreaseFontSize, object: nil)
                }
                .keyboardShortcut("+", modifiers: .command)
                
                Button("Decrease Font Size") {
                    NotificationCenter.default.post(name: .terminalDecreaseFontSize, object: nil)
                }
                .keyboardShortcut("-", modifiers: .command)
                
                Button("Reset Font Size") {
                    NotificationCenter.default.post(name: .terminalResetFontSize, object: nil)
                }
                .keyboardShortcut("0", modifiers: .command)
                
                Divider()
                
                Button("Toggle Background Transparency") {
                    NotificationCenter.default.post(name: .toggleBackgroundOpacity, object: nil)
                }
                .keyboardShortcut("u", modifiers: .command)
            }
            
            // MARK: - Terminal Menu (Custom)
            CommandMenu("Terminal") {
                Button("Clear Screen") {
                    NotificationCenter.default.post(name: .terminalClearScreen, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
                
                Button("Reset Terminal") {
                    NotificationCenter.default.post(name: .terminalReset, object: nil)
                }
                
                Divider()
                
                Button("Reload Configuration") {
                    NotificationCenter.default.post(name: .reloadConfiguration, object: nil)
                }
                .keyboardShortcut(",", modifiers: [.command, .shift])
                
                Divider()
                
                Button("Reconnect") {
                    NotificationCenter.default.post(name: .terminalReconnect, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            
            // MARK: - Connection Menu (Custom)
            CommandMenu("Connection") {
                Button("Connection Profiles…") {
                    NotificationCenter.default.post(name: .showConnectionProfiles, object: nil)
                }
                
                Button("SSH Key Manager…") {
                    NotificationCenter.default.post(name: .showSSHKeyManager, object: nil)
                }
                
                Divider()
                
                Button("Toggle Secure Keyboard Entry") {
                    NotificationCenter.default.post(name: .terminalToggleSecureKeyboard, object: nil)
                }
            }
            
            // MARK: - Help Menu
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") {
                    NotificationCenter.default.post(name: .showKeyboardShortcuts, object: nil)
                }
                .keyboardShortcut("/", modifiers: .command)
            }
        }
    }
    
    /// Set the window background color to match the theme
    private func setWindowBackground() {
        let themeBg = ThemeManager.shared.selectedTheme.background
        let bgColor = UIColor(themeBg)
        
        // Find all windows and set their background
        for scene in UIApplication.shared.connectedScenes {
            if let windowScene = scene as? UIWindowScene {
                for window in windowScene.windows {
                    window.backgroundColor = bgColor
                }
            }
        }
    }
}

// MARK: - Notification Names for Keyboard Shortcuts

extension Notification.Name {
    // Terminal actions
    static let terminalClearScreen = Notification.Name("terminalClearScreen")
    static let terminalReset = Notification.Name("terminalReset")
    static let terminalIncreaseFontSize = Notification.Name("terminalIncreaseFontSize")
    static let terminalDecreaseFontSize = Notification.Name("terminalDecreaseFontSize")
    static let terminalResetFontSize = Notification.Name("terminalResetFontSize")
    static let terminalDisconnect = Notification.Name("terminalDisconnect")
    static let terminalSelectAll = Notification.Name("terminalSelectAll")
    static let terminalCopy = Notification.Name("terminalCopy")
    static let terminalPaste = Notification.Name("terminalPaste")
    static let terminalToggleStatusBar = Notification.Name("terminalToggleStatusBar")
    static let terminalToggleSecureKeyboard = Notification.Name("terminalToggleSecureKeyboard")
    static let terminalReconnect = Notification.Name("terminalReconnect")
    static let reloadConfiguration = Notification.Name("reloadConfiguration")
    
    // Search actions
    static let terminalFind = Notification.Name("terminalFind")
    static let terminalFindNext = Notification.Name("terminalFindNext")
    static let terminalFindPrevious = Notification.Name("terminalFindPrevious")
    static let terminalHideFindBar = Notification.Name("terminalHideFindBar")
    static let ghosttySearchFocus = Notification.Name("ghosttySearchFocus")
    
    // Navigation/UI
    static let showNewConnection = Notification.Name("showNewConnection")
    static let showQuickConnect = Notification.Name("showQuickConnect")
    static let showSSHKeyManager = Notification.Name("showSSHKeyManager")
    static let showConnectionProfiles = Notification.Name("showConnectionProfiles")
    static let showKeyboardShortcuts = Notification.Name("showKeyboardShortcuts")
    static let showSettings = Notification.Name("showSettings")
    
    // Appearance
    static let toggleBackgroundOpacity = Notification.Name("toggleBackgroundOpacity")
    
    // tmux control mode (from Ghostty)
    static let tmuxStateChanged = Notification.Name("tmuxStateChanged")
    static let tmuxExited = Notification.Name("tmuxExited")
}

/// Global application state
@MainActor
class AppState: ObservableObject {
    /// Active SSH sessions
    @Published var sessions: [SSHSession] = []
    
    /// Current active session (for profile-based connections)
    @Published var sshSession: SSHSession?
    
    /// Current connection status
    @Published var connectionStatus: ConnectionStatus = .disconnected
    
    /// Current connection parameters (set when connecting)
    @Published var currentHost: String?
    @Published var currentPort: Int?
    @Published var currentUsername: String?
    @Published var currentPassword: String?
    
    enum ConnectionStatus: Equatable {
        case disconnected
        case connecting
        case connected
        case error(String)
    }
    
    init() {}
    
    /// Set connection parameters before navigating to terminal
    func setConnectionParams(host: String, port: Int, username: String, password: String?) {
        currentHost = host
        currentPort = port
        currentUsername = username
        currentPassword = password
    }
    
    /// Clear connection parameters
    func clearConnectionParams() {
        currentHost = nil
        currentPort = nil
        currentUsername = nil
        currentPassword = nil
        sshSession = nil
    }
}
