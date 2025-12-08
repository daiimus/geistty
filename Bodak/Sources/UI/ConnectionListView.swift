//
//  ConnectionListView.swift
//  Bodak
//
//  Main view for managing saved connections
//

import SwiftUI

/// Main view showing saved connections with quick connect
struct ConnectionListView: View {
    
    @StateObject private var profileManager = ConnectionProfileManager.shared
    @StateObject private var keyManager = SSHKeyManager.shared
    
    @State private var showingAddConnection = false
    @State private var showingKeyManager = false
    @State private var showingQuickConnect = false
    @State private var selectedProfile: ConnectionProfile?
    @State private var connectionInProgress: ConnectionProfile?
    @State private var searchText = ""
    @State private var errorMessage: String?
    @State private var showingError = false
    
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
                
                // Recent Section
                if !profileManager.recents.isEmpty {
                    Section("Recent") {
                        ForEach(filteredRecents.prefix(5)) { profile in
                            if !profile.isFavorite {
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
            }
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
        Button {
            connect(to: profile)
        } label: {
            Label("Connect", systemImage: "bolt.fill")
        }
        
        Button {
            profileManager.toggleFavorite(profile)
        } label: {
            if profile.isFavorite {
                Label("Remove from Favorites", systemImage: "star.slash")
            } else {
                Label("Add to Favorites", systemImage: "star")
            }
        }
        
        Button {
            selectedProfile = profile
        } label: {
            Label("Edit", systemImage: "pencil")
        }
        
        Divider()
        
        Button(role: .destructive) {
            profileManager.deleteProfile(profile)
        } label: {
            Label("Delete", systemImage: "trash")
        }
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
            } catch {
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
    @State private var showingPasswordManager = false
    
    var onConnect: (SSHSession) -> Void
    
    var body: some View {
        Form {
            Section("Server") {
                TextField("Host", text: $host)
                    .textContentType(.URL)
                    .autocapitalization(.none)
                    .keyboardType(.URL)
                
                TextField("Port", text: $port)
                    .keyboardType(.numberPad)
            }
            
            Section("Authentication") {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .autocapitalization(.none)
                
                SecureField("Password", text: $password)
                    .textContentType(.password)
                
                Button {
                    requestPasswordFromManager()
                } label: {
                    Label("Use Password Manager", systemImage: "key.viewfinder")
                }
                .foregroundColor(.accentColor)
            }
            
            Section {
                Toggle("Save connection", isOn: $saveConnection)
            }
            
            if let error = errorMessage {
                Section {
                    Text(error)
                        .foregroundColor(.red)
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
            }
        }
    }
    
    private var isValid: Bool {
        !host.isEmpty && !username.isEmpty && (Int(port) ?? 0) > 0
    }
    
    private func requestPasswordFromManager() {
        Task {
            do {
                let credential = try await CredentialManager.shared.requestCredentialsViaAutoFill(
                    for: host.isEmpty ? "ssh" : host,
                    username: username
                )
                
                await MainActor.run {
                    if case .password(let pw) = credential.authType {
                        password = pw
                    }
                }
            } catch CredentialError.cancelled {
                // User cancelled, do nothing
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
        }
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
