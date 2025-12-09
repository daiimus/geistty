import SwiftUI
import GhosttyKit

@main
struct BodakApp: App {
    @StateObject private var appState = AppState()
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
            ContentView()
                .environmentObject(appState)
                .environmentObject(ghosttyApp)
                .onAppear {
                    // Ensure window background is set after scene is created
                    setWindowBackground()
                }
        }
        .commands {
            // Terminal commands (Cmd+C/V work automatically via system)
            CommandGroup(replacing: .textEditing) {
                // Keep standard edit commands
            }
            
            // Custom terminal commands shown in Cmd-hold menu on iPad
            CommandMenu("Terminal") {
                Button("Clear Screen") {
                    NotificationCenter.default.post(name: .terminalClearScreen, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
                
                Button("Reset Terminal") {
                    NotificationCenter.default.post(name: .terminalReset, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                
                Divider()
                
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
                
                Button("Disconnect") {
                    NotificationCenter.default.post(name: .terminalDisconnect, object: nil)
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            
            CommandMenu("Connection") {
                Button("New Connection") {
                    NotificationCenter.default.post(name: .showNewConnection, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
                
                Button("Quick Connect") {
                    NotificationCenter.default.post(name: .showQuickConnect, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
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
    static let terminalClearScreen = Notification.Name("terminalClearScreen")
    static let terminalReset = Notification.Name("terminalReset")
    static let terminalIncreaseFontSize = Notification.Name("terminalIncreaseFontSize")
    static let terminalDecreaseFontSize = Notification.Name("terminalDecreaseFontSize")
    static let terminalResetFontSize = Notification.Name("terminalResetFontSize")
    static let terminalDisconnect = Notification.Name("terminalDisconnect")
    static let showNewConnection = Notification.Name("showNewConnection")
    static let showQuickConnect = Notification.Name("showQuickConnect")
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
