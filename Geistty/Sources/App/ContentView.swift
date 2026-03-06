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
    @Environment(\.scenePhase) private var scenePhase
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
            if appState.connectionStatus == .connected || appState.connectionStatus == .connecting {
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
                        case .connecting, .connected:
                            // Both handled by outer `if` — required for exhaustiveness
                            EmptyView()
                        case .error(let message):
                            ErrorView(
                                message: message,
                                showConnectionSheet: $showConnectionSheet,
                                backgroundColor: themeBackground,
                                onReconnect: reconnect
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
        // Handle navigation notifications from menu bar.
        // H13 fix: Guard on scenePhase == .active to prevent inactive/background
        // scenes from processing keyboard shortcut notifications on multi-window iPad.
        .onReceive(NotificationCenter.default.publisher(for: .showNewConnection)) { _ in
            guard scenePhase == .active else { return }
            // Disconnect active session before showing new connection
            disconnectAndReset()
            showConnectionList = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showQuickConnect)) { _ in
            guard scenePhase == .active else { return }
            // Disconnect active session before showing quick connect
            disconnectAndReset()
            showConnectionSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showConnectionProfiles)) { _ in
            guard scenePhase == .active else { return }
            // Disconnect active session before showing connection list
            disconnectAndReset()
            showConnectionList = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalDisconnect)) { _ in
            guard scenePhase == .active else { return }
            // Disconnect active session and go back to disconnected state
            disconnectAndReset()
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalReconnect)) { _ in
            guard scenePhase == .active else { return }
            reconnect()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSettings)) { _ in
            guard scenePhase == .active else { return }
            showSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSSHKeyManager)) { _ in
            guard scenePhase == .active else { return }
            showSSHKeyManager = true
        }
        .sheet(isPresented: $showSSHKeyManager) {
            NavigationStack {
                SSHKeyListView()
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
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
        
        // Transition to .connecting — TerminalContainerView mounts immediately
        // and initiates the SSH handshake. It transitions to .connected on success
        // or .error on failure via setupConnection().
        appState.connectionStatus = .connecting
        showConnectionSheet = false
    }
    
    /// Disconnect the active SSH session and reset to disconnected state (C3 fix).
    /// Prevents leaking active SSH connections when navigating away.
    private func disconnectAndReset() {
        appState.sshSession?.disconnect()
        appState.clearConnectionParams()
        appState.connectionStatus = .disconnected
    }
    
    /// Shared reconnect logic — used by both the notification handler and ErrorView
    /// button. Checks canReconnect, transitions to .connecting, awaits reconnect,
    /// and sets final state based on session outcome. See #27.
    private func reconnect() {
        guard let session = appState.sshSession, session.canReconnect else {
            appState.connectionStatus = .error("No session available for reconnect")
            return
        }
        appState.connectionStatus = .connecting
        Task {
            await session.attemptReconnect()
            // If reconnect failed and we're still in .connecting, transition
            // to error. If it succeeded, setupConnection() already set .connected.
            if session.state == .disconnected && appState.connectionStatus == .connecting {
                appState.connectionStatus = .error("Reconnect failed")
            }
        }
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
    /// Shared reconnect action provided by ContentView. See #27.
    let onReconnect: () -> Void
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
                // Reconnect button — delegates to shared reconnect() via closure. See #27.
                if let session = appState.sshSession, session.canReconnect {
                    Button {
                        onReconnect()
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
                        .textInputAutocapitalization(.never)
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
                        .textInputAutocapitalization(.never)
                    
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
                
                #if DEBUG
                Section("Test Servers") {
                    Button("Use test.rebex.net") {
                        connectionInfo.host = "test.rebex.net"
                        connectionInfo.port = 22
                        connectionInfo.username = "demo"
                        connectionInfo.password = "password"
                    }
                    .foregroundColor(.blue)
                }
                #endif
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
        connectionInfo.port >= 1 && connectionInfo.port <= 65535
    }
}

#Preview {
    WindowContentView()
        .environmentObject(Ghostty.App())
}
