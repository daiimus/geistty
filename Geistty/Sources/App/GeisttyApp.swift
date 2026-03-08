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
        
        // NOTE: File Provider support has been archived (Jan 2026)
        // See FILE_PROVIDER_LEARNINGS.md and branch archive/file-provider-jan-2026
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
                
                Button("Command Palette") {
                    NotificationCenter.default.post(name: .toggleCommandPalette, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                
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
                
                Button("Jump to Previous Prompt") {
                    NotificationCenter.default.post(name: .terminalJumpToPromptUp, object: nil)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
                
                Button("Jump to Next Prompt") {
                    NotificationCenter.default.post(name: .terminalJumpToPromptDown, object: nil)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .shift])
                
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
    static let terminalJumpToPromptUp = Notification.Name("terminalJumpToPromptUp")
    static let terminalJumpToPromptDown = Notification.Name("terminalJumpToPromptDown")
    static let terminalDisconnect = Notification.Name("terminalDisconnect")
    static let terminalSelectAll = Notification.Name("terminalSelectAll")
    static let terminalCopy = Notification.Name("terminalCopy")
    static let terminalPaste = Notification.Name("terminalPaste")
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
    static let toggleCommandPalette = Notification.Name("toggleCommandPalette")
    
    // tmux control mode (from Ghostty)
    static let tmuxStateChanged = Notification.Name("tmuxStateChanged")
    static let tmuxExited = Notification.Name("tmuxExited")
    static let tmuxReady = Notification.Name("tmuxReady")
    static let tmuxCommandResponse = Notification.Name("tmuxCommandResponse")
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
    // Not @Published — password should not be observable or persisted in Combine buffers.
    // Stored as Data for explicit zeroing on clear. See #28.
    var currentPassword: Data?
    
    /// Whether the app was launched with --ui-testing flag.
    /// When true, the app auto-connects to localhost for XCUITest connected tests.
    let isUITesting: Bool
    
    enum ConnectionStatus: Equatable {
        case disconnected
        case connecting
        case connected
        case error(String)
    }
    
    init() {
        let args = ProcessInfo.processInfo.arguments
        self.isUITesting = args.contains("--ui-testing")
        
        if isUITesting {
            // Parse test connection parameters from launch arguments.
            // Expected: --test-host HOST --test-port PORT --test-user USER [--test-key PATH]
            var host = "localhost"
            var port = 22
            var user = NSUserName()
            
            if let hostIdx = args.firstIndex(of: "--test-host"), hostIdx + 1 < args.count {
                host = args[hostIdx + 1]
            }
            if let portIdx = args.firstIndex(of: "--test-port"), portIdx + 1 < args.count {
                port = Int(args[portIdx + 1]) ?? 22
            }
            if let userIdx = args.firstIndex(of: "--test-user"), userIdx + 1 < args.count {
                user = args[userIdx + 1]
            }
            
            // Auto-connect: set params and transition to .connecting
            setConnectionParams(host: host, port: port, username: user, password: nil)
            connectionStatus = .connecting
        }
    }
    
    /// Set connection parameters before navigating to terminal
    func setConnectionParams(host: String, port: Int, username: String, password: String?) {
        currentHost = host
        currentPort = port
        currentUsername = username
        currentPassword = password.flatMap { $0.data(using: .utf8) }
    }
    
    /// Clear connection parameters — zeroes password bytes before releasing. See #28.
    func clearConnectionParams() {
        currentHost = nil
        currentPort = nil
        currentUsername = nil
        zeroAndClearPassword()
        sshSession = nil
    }
    
    /// Zero the password buffer in-place before releasing. Data is a value type —
    /// mutating it directly ensures the backing store is overwritten. See #28.
    func zeroAndClearPassword() {
        guard currentPassword != nil else { return }
        currentPassword!.resetBytes(in: 0..<currentPassword!.count)
        currentPassword = nil
    }
}

// MARK: - Centralized UserDefaults Keys

/// All UserDefaults key strings used across the app.
/// Centralizes raw strings to prevent typos and enable refactoring.
/// Keys for ConnectionProfile and SSHKeyManager are managed separately
/// (already centralized as private constants in their respective files).
enum UserDefaultsKey {
    static let cursorStyle = "terminal.cursorStyle"
    static let fontFamily = "terminal.fontFamily"
    static let fontThicken = "terminal.fontThicken"
    static let backgroundOpacity = "terminal.backgroundOpacity"
    static let colorTheme = "terminal.colorTheme"
    static let showStatusBar = "ui.showStatusBar"
}
