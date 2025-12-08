import SwiftUI
import GhosttyKit

@main
struct BodakApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var ghosttyApp = Ghostty.App()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(ghosttyApp)
        }
    }
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
