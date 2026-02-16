import SwiftUI
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.geistty", category: "AppLifecycle")

/// Wrapper view that creates per-window AppState for multi-window support
struct WindowContentView: View {
    // Each window gets its own AppState instance
    @StateObject private var appState = AppState()
    
    // Track scene phase for File Provider sync
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some View {
        ContentView()
            .environmentObject(appState)
            .onChange(of: scenePhase) { oldPhase, newPhase in
                handleScenePhaseChange(from: oldPhase, to: newPhase)
            }
    }
    
    /// Handle scene phase changes
    /// App lifecycle handling for potential future features
    private func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        switch newPhase {
        case .active:
            if oldPhase == .background || oldPhase == .inactive {
                logger.info("📱 App became active")
            }
            
        case .background:
            logger.debug("📱 App entering background")
            
        case .inactive:
            break
            
        @unknown default:
            break
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var showConnectionSheet = false
    @State private var showConnectionList = false
    @State private var showSettings = false
    @State private var showSSHKeyManager = false
    @State private var connectionInfo = ConnectionInfo()
    @State private var connectedSession: SSHSession?
    
    /// Theme background color for consistent styling
    private var themeBackground: Color {
        Color(ThemeManager.shared.selectedTheme.background)
    }
    
    var body: some View {
        // When connected, show ONLY the terminal - no NavigationStack, no chrome
        // This ensures the DisconnectedView is completely removed from hierarchy
        Group {
            if appState.connectionStatus == .connected {
                TerminalContainerView()
                    .background(themeBackground)
                    .ignoresSafeArea()
            } else {
                // Non-connected states use NavigationStack with welcome/error UI
                NavigationStack {
                    Group {
                        switch appState.connectionStatus {
                        case .disconnected:
                            DisconnectedView(
                                showConnectionSheet: $showConnectionSheet,
                                showConnectionList: $showConnectionList,
                                backgroundColor: themeBackground
                            )
                        case .connecting:
                            ConnectingView(backgroundColor: themeBackground)
                        case .connected:
                            // This case won't be reached due to outer if
                            EmptyView()
                        case .error(let message):
                            ErrorView(
                                message: message,
                                showConnectionSheet: $showConnectionSheet,
                                backgroundColor: themeBackground
                            )
                        }
                    }
                    .navigationTitle("Geistty")
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Menu {
                                Button {
                                    showConnectionSheet = true
                                } label: {
                                    Label("Quick Connect", systemImage: "bolt.fill")
                                }
                                
                                Button {
                                    showConnectionList = true
                                } label: {
                                    Label("Saved Connections", systemImage: "list.bullet")
                                }
                            } label: {
                                Image(systemName: "plus.circle")
                            }
                        }
                    }
                }
                .background(themeBackground)
                .sheet(isPresented: $showConnectionSheet) {
                    ConnectionSheet(connectionInfo: $connectionInfo, onConnect: connect)
                }
                .sheet(isPresented: $showConnectionList) {
                    ConnectionListView { session in
                        // Session already connected via ConnectionListView
                        connectedSession = session
                        appState.sshSession = session
                        appState.connectionStatus = .connected
                        showConnectionList = false
                    }
                }
            }
        }
        // Disable ALL animations on state transitions to prevent flash
        .transaction { transaction in
            transaction.animation = nil
        }
        .animation(nil, value: appState.connectionStatus)
        // Handle navigation notifications from menu bar
        .onReceive(NotificationCenter.default.publisher(for: .showNewConnection)) { _ in
            // Disconnect and show new connection
            appState.connectionStatus = .disconnected
            showConnectionList = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showQuickConnect)) { _ in
            // Disconnect and show quick connect
            appState.connectionStatus = .disconnected
            showConnectionSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showConnectionProfiles)) { _ in
            // Disconnect and show connection list
            appState.connectionStatus = .disconnected
            showConnectionList = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalDisconnect)) { _ in
            // Go back to disconnected state
            appState.connectionStatus = .disconnected
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalReconnect)) { _ in
            // Reconnect using stored credentials via SSHSession
            if let session = appState.sshSession, session.canReconnect {
                Task {
                    await session.attemptReconnect()
                    if session.state != .disconnected {
                        appState.connectionStatus = .connected
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSettings)) { _ in
            showSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSSHKeyManager)) { _ in
            showSSHKeyManager = true
        }
        .sheet(isPresented: $showSSHKeyManager) {
            NavigationStack {
                SSHKeyListView()
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                currentFontSize: 14,
                onFontSizeChanged: { _ in },
                onResetFontSize: { },
                onFontFamilyChanged: { },
                onThemeChanged: { }
            )
        }
    }
    
    private func connect() {
        // Store connection info in app state so TerminalContainerView can use it
        appState.setConnectionParams(
            host: connectionInfo.host,
            port: connectionInfo.port,
            username: connectionInfo.username,
            password: connectionInfo.password
        )
        
        // Set status to connected - shows terminal view which handles SSH connection internally
        // The terminal view shows its own connecting indicator while SSH handshake happens
        appState.connectionStatus = .connected
        showConnectionSheet = false
    }
}

// MARK: - Sub Views

struct DisconnectedView: View {
    @Binding var showConnectionSheet: Bool
    @Binding var showConnectionList: Bool
    let backgroundColor: Color
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "terminal")
                .font(.system(size: 80))
                .foregroundStyle(.secondary)
            
            Text("No Active Connection")
                .font(.title2)
                .foregroundStyle(.secondary)
            
            VStack(spacing: 12) {
                Button {
                    showConnectionSheet = true
                } label: {
                    Label("Quick Connect", systemImage: "bolt.fill")
                        .frame(maxWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                
                Button {
                    showConnectionList = true
                } label: {
                    Label("Saved Connections", systemImage: "list.bullet")
                        .frame(maxWidth: 200)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor)
    }
}

struct ConnectingView: View {
    let backgroundColor: Color
    
    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            
            Text("Connecting...")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor)
    }
}

struct ErrorView: View {
    let message: String
    @Binding var showConnectionSheet: Bool
    let backgroundColor: Color
    @EnvironmentObject var appState: AppState
    
    /// Formatted connection info for display
    private var connectionDescription: String? {
        guard let host = appState.currentHost,
              let username = appState.currentUsername else {
            return nil
        }
        let port = appState.currentPort ?? 22
        if port == 22 {
            return "\(username)@\(host)"
        } else {
            return "\(username)@\(host):\(port)"
        }
    }
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 60))
                .foregroundStyle(.orange)
            
            Text("Disconnected")
                .font(.title2)
            
            // Show which connection was lost
            if let conn = connectionDescription {
                Text(conn)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            VStack(spacing: 12) {
                // Reconnect button (uses stored SSH credentials)
                if let session = appState.sshSession, session.canReconnect {
                    Button {
                        Task {
                            appState.connectionStatus = .connecting
                            await session.attemptReconnect()
                            if session.state != .disconnected {
                                appState.connectionStatus = .connected
                            } else {
                                appState.connectionStatus = .error("Reconnect failed")
                            }
                        }
                    } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                            .frame(maxWidth: 200)
                    }
                    .buttonStyle(.borderedProminent)
                }
                
                Button {
                    appState.clearConnectionParams()
                    appState.connectionStatus = .disconnected
                } label: {
                    Label("Back to Connections", systemImage: "list.bullet")
                        .frame(maxWidth: 200)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor)
    }
}

// MARK: - Connection Sheet

struct ConnectionInfo {
    #if DEBUG
    var host: String = "test.rebex.net"  // Default test server
    var username: String = "demo"
    var password: String = "password"
    #else
    var host: String = ""
    var username: String = ""
    var password: String = ""
    #endif
    var port: Int = 22
}

struct ConnectionSheet: View {
    @Binding var connectionInfo: ConnectionInfo
    let onConnect: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Host", text: $connectionInfo.host)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                    
                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("22", value: $connectionInfo.port, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                }
                
                Section("Authentication") {
                    TextField("Username", text: $connectionInfo.username)
                        .textContentType(.username)
                        .autocapitalization(.none)
                    
                    SecureField("Password", text: $connectionInfo.password)
                        .textContentType(.password)
                }
                
                Section {
                    Button("Connect") {
                        onConnect()
                    }
                    .disabled(!isValid)
                    .frame(maxWidth: .infinity)
                }
                
                Section("Test Servers") {
                    Button("Use test.rebex.net") {
                        connectionInfo.host = "test.rebex.net"
                        connectionInfo.port = 22
                        connectionInfo.username = "demo"
                        connectionInfo.password = "password"
                    }
                    .foregroundColor(.blue)
                    
                    Button("Use OverTheWire Bandit") {
                        connectionInfo.host = "bandit.labs.overthewire.org"
                        connectionInfo.port = 2220
                        connectionInfo.username = "bandit0"
                        connectionInfo.password = "bandit0"
                    }
                    .foregroundColor(.blue)
                }
            }
            .navigationTitle("New Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private var isValid: Bool {
        !connectionInfo.host.isEmpty &&
        !connectionInfo.username.isEmpty &&
        !connectionInfo.password.isEmpty
    }
}

#Preview {
    WindowContentView()
        .environmentObject(Ghostty.App())
}
