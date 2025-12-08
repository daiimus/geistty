import SwiftUI
import GhosttyKit

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var showConnectionSheet = false
    @State private var showConnectionList = false
    @State private var connectionInfo = ConnectionInfo()
    @State private var connectedSession: SSHSession?
    
    var body: some View {
        NavigationStack {
            Group {
                switch appState.connectionStatus {
                case .disconnected:
                    DisconnectedView(
                        showConnectionSheet: $showConnectionSheet,
                        showConnectionList: $showConnectionList
                    )
                case .connecting:
                    ConnectingView()
                case .connected:
                    TerminalContainerView()
                case .error(let message):
                    ErrorView(message: message, showConnectionSheet: $showConnectionSheet)
                }
            }
            .navigationTitle("Bodak")
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
    
    private func connect() {
        // Store connection info in app state so TerminalContainerView can use it
        appState.setConnectionParams(
            host: connectionInfo.host,
            port: connectionInfo.port,
            username: connectionInfo.username,
            password: connectionInfo.password
        )
        
        // Set status to connected - the actual SSH connection happens in TerminalContainerView
        appState.connectionStatus = .connected
        showConnectionSheet = false
    }
}

// MARK: - Sub Views

struct DisconnectedView: View {
    @Binding var showConnectionSheet: Bool
    @Binding var showConnectionList: Bool
    
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
    }
}

struct ConnectingView: View {
    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            
            Text("Connecting...")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }
}

struct ErrorView: View {
    let message: String
    @Binding var showConnectionSheet: Bool
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundStyle(.red)
            
            Text("Connection Error")
                .font(.title2)
            
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            VStack(spacing: 12) {
                // Reconnect button (uses last connection if available)
                if appState.currentHost != nil {
                    Button {
                        appState.connectionStatus = .connected
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
    }
}

// MARK: - Connection Sheet

struct ConnectionInfo {
    var host: String = "test.rebex.net"  // Default test server
    var port: Int = 22
    var username: String = "demo"
    var password: String = "password"
    var useKeyAuth: Bool = false
    var privateKeyPath: String = ""
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
                    
                    Toggle("Use Key Authentication", isOn: $connectionInfo.useKeyAuth)
                    
                    if connectionInfo.useKeyAuth {
                        TextField("Private Key Path", text: $connectionInfo.privateKeyPath)
                            .autocapitalization(.none)
                    } else {
                        SecureField("Password", text: $connectionInfo.password)
                            .textContentType(.password)
                    }
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
                        connectionInfo.useKeyAuth = false
                    }
                    .foregroundColor(.blue)
                    
                    Button("Use OverTheWire Bandit") {
                        connectionInfo.host = "bandit.labs.overthewire.org"
                        connectionInfo.port = 2220
                        connectionInfo.username = "bandit0"
                        connectionInfo.password = "bandit0"
                        connectionInfo.useKeyAuth = false
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
        (connectionInfo.useKeyAuth ? !connectionInfo.privateKeyPath.isEmpty : !connectionInfo.password.isEmpty)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
        .environmentObject(Ghostty.App())
}
