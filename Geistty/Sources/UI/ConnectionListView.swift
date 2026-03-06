//
//  ConnectionListView.swift
//  Geistty
//
//  Main view for managing saved connections
//

import os
import SwiftUI

private let logger = Logger(subsystem: "com.geistty", category: "ConnectionList")

/// Main view showing saved connections with quick connect
struct ConnectionListView: View {
    
    @ObservedObject private var profileManager = ConnectionProfileManager.shared
    @ObservedObject private var keyManager = SSHKeyManager.shared
    
    @State private var showingAddConnection = false
    @State private var showingKeyManager = false
    @State private var showingQuickConnect = false
    @State private var selectedProfile: ConnectionProfile?
    @State private var connectionInProgress: ConnectionProfile?
    @State private var searchText = ""
    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var showingPasswordPrompt = false
    @State private var passwordPromptProfile: ConnectionProfile?
    @State private var promptedPassword = ""
    
    // Callback for when connection succeeds
    var onConnect: ((SSHSession) -> Void)?
    
    var body: some View {
        NavigationStack {
            List {
                // Quick Connect Section
                Section {
                    Button {
                        showingQuickConnect = true
                    } label: {
                        Label("Quick Connect", systemImage: "bolt.fill")
                    }
                    .accessibilityIdentifier("QuickConnectButton")
                }
                
                // Favorites Section
                if !profileManager.favorites.isEmpty {
                    Section("Favorites") {
                        ForEach(filteredFavorites) { profile in
                            ConnectionRow(
                                profile: profile,
                                isConnecting: connectionInProgress?.id == profile.id
                            ) {
                                connect(to: profile)
                            }
                            .contextMenu {
                                connectionContextMenu(for: profile)
                            }
                        }
                        .onDelete { offsets in
                            deleteProfiles(from: filteredFavorites, at: offsets)
                        }
                    }
                }
                
                // Recent Section — only show when there are visible non-favorite recents
                let visibleRecents = filteredRecents.prefix(5).filter { !$0.isFavorite }
                if !visibleRecents.isEmpty {
                    Section("Recent") {
                        ForEach(visibleRecents) { profile in
                            ConnectionRow(
                                profile: profile,
                                isConnecting: connectionInProgress?.id == profile.id
                            ) {
                                connect(to: profile)
                            }
                            .contextMenu {
                                connectionContextMenu(for: profile)
                            }
                        }
                    }
                }
                
                // All Connections Section
                Section("All Connections") {
                    if filteredProfiles.isEmpty {
                        ContentUnavailableView(
                            "No Connections",
                            systemImage: "server.rack",
                            description: Text("Tap + to add a new connection")
                        )
                    } else {
                        ForEach(filteredProfiles) { profile in
                            ConnectionRow(
                                profile: profile,
                                isConnecting: connectionInProgress?.id == profile.id
                            ) {
                                connect(to: profile)
                            }
                            .contextMenu {
                                connectionContextMenu(for: profile)
                            }
                        }
                        .onDelete { offsets in
                            deleteProfiles(from: filteredProfiles, at: offsets)
                        }
                    }
                }
                
                // SSH Keys Section
                Section {
                    NavigationLink {
                        SSHKeyListView()
                    } label: {
                        Label("SSH Keys", systemImage: "key.fill")
                        Spacer()
                        Text("\(keyManager.keys.count)")
                            .foregroundColor(.secondary)
                    }
                    .accessibilityIdentifier("SSHKeysLink")
                }
            }
            .navigationTitle("Connections")
            .searchable(text: $searchText, prompt: "Search connections")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddConnection = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityIdentifier("AddConnectionButton")
                }
            }
            .sheet(isPresented: $showingAddConnection) {
                NavigationStack {
                    ConnectionEditorView(profile: nil) { newProfile in
                        profileManager.addProfile(newProfile)
                    }
                }
            }
            .sheet(isPresented: $showingQuickConnect) {
                NavigationStack {
                    QuickConnectView { session in
                        showingQuickConnect = false
                        onConnect?(session)
                    }
                }
            }
            .sheet(item: $selectedProfile) { profile in
                NavigationStack {
                    ConnectionEditorView(profile: profile) { updatedProfile in
                        profileManager.updateProfile(updatedProfile)
                    }
                }
            }
            .alert("Connection Error", isPresented: $showingError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Unknown error")
                    .accessibilityIdentifier("ConnectionErrorMessage")
            }
            .alert("Enter Password", isPresented: $showingPasswordPrompt) {
                SecureField("Password", text: $promptedPassword)
                    .accessibilityIdentifier("PasswordPromptField")
                Button("Connect") {
                    guard let profile = passwordPromptProfile else { return }
                    let password = promptedPassword
                    promptedPassword = ""
                    passwordPromptProfile = nil
                    connectWithPassword(profile: profile, password: password)
                }
                Button("Cancel", role: .cancel) {
                    promptedPassword = ""
                    passwordPromptProfile = nil
                    connectionInProgress = nil
                }
            } message: {
                if let profile = passwordPromptProfile {
                    Text("\(profile.username)@\(profile.host)")
                }
            }
            // Keyboard shortcut handlers (Cmd+N, Cmd+O) are owned by ContentView
            // to avoid double sheet presentation. See #47.
        }
    }
    
    // MARK: - Filtered Data
    
    private var filteredProfiles: [ConnectionProfile] {
        profileManager.search(searchText)
    }
    
    private var filteredFavorites: [ConnectionProfile] {
        profileManager.favorites.filter {
            searchText.isEmpty ||
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.host.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    private var filteredRecents: [ConnectionProfile] {
        profileManager.recents.filter {
            searchText.isEmpty ||
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.host.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    // MARK: - Context Menu
    
    @ViewBuilder
    private func connectionContextMenu(for profile: ConnectionProfile) -> some View {
        Group {
            Button {
                connect(to: profile)
            } label: {
                Label("Connect", systemImage: "bolt.fill")
            }
            .accessibilityIdentifier("ContextMenuConnect")
            
            Button {
                profileManager.toggleFavorite(profile)
            } label: {
                if profile.isFavorite {
                    Label("Remove from Favorites", systemImage: "star.slash")
                } else {
                    Label("Add to Favorites", systemImage: "star")
                }
            }
            .accessibilityIdentifier("ContextMenuToggleFavorite")
            
            Divider()
            
            Button {
                selectedProfile = profile
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .accessibilityIdentifier("ContextMenuEdit")
            
            Button {
                duplicateProfile(profile)
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            .accessibilityIdentifier("ContextMenuDuplicate")
            
            Divider()
            
            // Copy actions
            Button {
                UIPasteboard.general.string = profile.host
            } label: {
                Label("Copy Host", systemImage: "doc.on.doc")
            }
            .accessibilityIdentifier("ContextMenuCopyHost")
            
            Button {
                UIPasteboard.general.string = "\(profile.username)@\(profile.host):\(profile.port)"
            } label: {
                Label("Copy Connection String", systemImage: "terminal")
            }
            .accessibilityIdentifier("ContextMenuCopyConnectionString")
            
            Divider()
            
            Button(role: .destructive) {
                profileManager.deleteProfile(profile)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier("ContextMenuDelete")
        }
    }
    
    private func duplicateProfile(_ profile: ConnectionProfile) {
        let duplicate = ConnectionProfile(
            id: UUID(),
            name: "\(profile.name) Copy",
            host: profile.host,
            port: profile.port,
            username: profile.username,
            authMethod: profile.authMethod,
            sshKeyName: profile.sshKeyName,
            useTmux: profile.useTmux,
            tmuxSessionName: profile.tmuxSessionName,
            enableFilesIntegration: false  // Don't duplicate Files integration to avoid domain conflicts
        )
        profileManager.addProfile(duplicate)
    }
    
    // MARK: - Actions
    
    private func connect(to profile: ConnectionProfile) {
        connectionInProgress = profile
        
        Task {
            do {
                let session = SSHSession()
                let credential = try await CredentialManager.shared.getCredentials(for: profile)
                try await session.connect(profile: profile, credential: credential)
                
                await MainActor.run {
                    connectionInProgress = nil
                    onConnect?(session)
                }
            } catch is KeychainError where profile.authMethod == .password {
                // No password saved in keychain — prompt the user to enter one
                logger.info("No saved password for \(profile.username)@\(profile.host), prompting")
                await MainActor.run {
                    passwordPromptProfile = profile
                    showingPasswordPrompt = true
                }
            } catch {
                logger.error("Connection failed to \(profile.username)@\(profile.host): \(error.localizedDescription)")
                await MainActor.run {
                    connectionInProgress = nil
                    errorMessage = error.localizedDescription
                    showingError = true
                }
            }
        }
    }
    
    private func connectWithPassword(profile: ConnectionProfile, password: String) {
        connectionInProgress = profile
        
        Task {
            do {
                let session = SSHSession()
                try await session.connect(
                    host: profile.host,
                    port: profile.port,
                    username: profile.username,
                    password: password,
                    useTmux: profile.useTmux,
                    tmuxSessionName: profile.tmuxSessionName
                )
                
                // Save password to keychain for next time
                try? KeychainManager.shared.savePassword(
                    password, for: profile.host, username: profile.username
                )
                logger.info("Saved password to keychain for \(profile.username)@\(profile.host)")
                
                await MainActor.run {
                    connectionInProgress = nil
                    onConnect?(session)
                }
            } catch {
                logger.error("Password connection failed to \(profile.username)@\(profile.host): \(error.localizedDescription)")
                await MainActor.run {
                    connectionInProgress = nil
                    errorMessage = error.localizedDescription
                    showingError = true
                }
            }
        }
    }
    
    private func deleteProfiles(from profiles: [ConnectionProfile], at offsets: IndexSet) {
        for index in offsets {
            profileManager.deleteProfile(profiles[index])
        }
    }
}

// MARK: - Connection Row

struct ConnectionRow: View {
    let profile: ConnectionProfile
    var isConnecting: Bool = false
    var onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack {
                // Auth method icon
                Image(systemName: profile.authIcon)
                    .foregroundColor(.accentColor)
                    .frame(width: 24)
                
                VStack(alignment: .leading) {
                    Text(profile.name)
                        .font(.headline)
                    Text(profile.displayString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if isConnecting {
                    ProgressView()
                } else if profile.isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundColor(.yellow)
                        .font(.caption)
                }
            }
        }
        .disabled(isConnecting)
        .accessibilityIdentifier("ConnectionRow-\(profile.name)")
        .accessibilityLabel("\(profile.name), \(profile.displayString)")
        .accessibilityHint(isConnecting ? "Connecting" : "Double-tap to connect")
    }
}

// MARK: - Quick Connect View

struct QuickConnectView: View {
    @Environment(\.dismiss) private var dismiss
    
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var password = ""
    @State private var saveConnection = true
    @State private var isConnecting = false
    @State private var errorMessage: String?
    
    var onConnect: (SSHSession) -> Void
    
    var body: some View {
        Form {
            Section("Server") {
                TextField("Host", text: $host)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .accessibilityIdentifier("HostField")
                
                TextField("Port", text: $port)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("PortField")
            }
            
            Section {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("UsernameField")
                
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .accessibilityIdentifier("PasswordField")
            } header: {
                Text("Authentication")
            } footer: {
                Text("For SSH key authentication, create a saved connection instead.")
                    .font(.caption)
            }
            
            Section {
                Toggle("Save connection", isOn: $saveConnection)
                    .accessibilityIdentifier("SaveConnectionToggle")
            }
            
            if let error = errorMessage {
                Section {
                    Text(error)
                        .foregroundColor(.red)
                        .accessibilityIdentifier("QuickConnectErrorMessage")
                }
            }
        }
        .navigationTitle("Quick Connect")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
                .accessibilityIdentifier("QuickConnectCancelButton")
            }
            
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    connect()
                } label: {
                    if isConnecting {
                        ProgressView()
                    } else {
                        Text("Connect")
                    }
                }
                .disabled(!isValid || isConnecting)
                .accessibilityIdentifier("ConnectButton")
            }
        }
    }
    
    private var isValid: Bool {
        !host.isEmpty && !username.isEmpty && (Int(port) ?? 0) > 0 && (Int(port) ?? 0) <= 65535
    }
    
    private func connect() {
        isConnecting = true
        errorMessage = nil
        
        Task {
            do {
                let session = SSHSession()
                let portNum = Int(port) ?? 22
                
                try await session.connect(
                    host: host,
                    port: portNum,
                    username: username,
                    password: password
                )
                
                // Save connection if requested
                if saveConnection {
                    let profile = ConnectionProfile(
                        name: "\(username)@\(host)",
                        host: host,
                        port: portNum,
                        username: username,
                        authMethod: .password
                    )
                    ConnectionProfileManager.shared.addProfile(profile)
                    
                    // Also save password to keychain
                    try? KeychainManager.shared.savePassword(
                        password,
                        for: host,
                        username: username
                    )
                }
                
                await MainActor.run {
                    isConnecting = false
                    onConnect(session)
                }
            } catch {
                logger.error("Quick connect failed to \(host): \(error.localizedDescription)")
                await MainActor.run {
                    isConnecting = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

#Preview {
    ConnectionListView()
}
