//
//  ConnectionEditorView.swift
//  Geistty
//
//  View for creating/editing connection profiles
//

import os
import SwiftUI

private let logger = Logger(subsystem: "com.geistty", category: "ConnectionEditor")

struct ConnectionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    
    // Existing profile (nil for new)
    let profile: ConnectionProfile?
    let onSave: (ConnectionProfile) -> Void
    
    // Form state
    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var authMethod: AuthMethod = .sshKey
    @State private var password = ""
    @State private var selectedKeyName: String?
    @State private var isFavorite = false
    @State private var useTmux = false
    @State private var tmuxSessionName = ""
    
    // Key import
    @State private var showingKeyImport = false
    @State private var importError: String?
    @State private var showingImportError = false
    
    // SSH Key manager
    @ObservedObject private var keyManager = SSHKeyManager.shared
    
    // U9: Keyboard field navigation via @FocusState
    private enum Field: Hashable {
        case name, host, port, username, password, tmuxSession
    }
    @FocusState private var focusedField: Field?
    
    var body: some View {
        Form {
            // Basic Info
            Section("Connection") {
                TextField("Name", text: $name)
                    .textContentType(.name)
                    .focused($focusedField, equals: .name)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .host }
                    .accessibilityIdentifier("EditorNameField")
                    .accessibilityLabel("Connection name")
                
                TextField("Host", text: $host)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .focused($focusedField, equals: .host)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .port }
                    .accessibilityIdentifier("EditorHostField")
                    .accessibilityLabel("Host address")
                
                TextField("Port", text: $port)
                    .keyboardType(.numberPad)
                    .focused($focusedField, equals: .port)
                    .accessibilityIdentifier("EditorPortField")
                    .accessibilityLabel("Port number")
                
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .focused($focusedField, equals: .username)
                    .submitLabel(authMethod == .password ? .next : .done)
                    .onSubmit {
                        if authMethod == .password {
                            focusedField = .password
                        } else {
                            focusedField = nil
                        }
                    }
                    .accessibilityIdentifier("EditorUsernameField")
                    .accessibilityLabel("SSH username")
            }
            
            // Authentication
            Section {
                Picker("Method", selection: $authMethod) {
                    ForEach(AuthMethod.allCases) { method in
                        Label(method.displayName, systemImage: method.icon)
                            .tag(method)
                    }
                }
                .accessibilityIdentifier("AuthMethodPicker")
                
                if authMethod == .password {
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                        .accessibilityIdentifier("EditorPasswordField")
                        .accessibilityLabel("SSH password")
                }
                
                Text(authMethod.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Authentication")
            } footer: {
                if authMethod == .sshKey {
                    Text("SSH keys are more secure than passwords. Import a .pem file from Files, or generate a new key.")
                } else {
                    Text("Password is saved securely in the iOS Keychain.")
                }
            }
            
            // SSH Key selection (only shown for sshKey auth)
            if authMethod == .sshKey {
                Section("SSH Key") {
                    if keyManager.keys.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundColor(.orange)
                                Text("No SSH keys yet")
                                    .foregroundColor(.secondary)
                            }
                            
                            Button {
                                showingKeyImport = true
                            } label: {
                                Label("Import Key from Files", systemImage: "square.and.arrow.down")
                            }
                            
                            NavigationLink {
                                SSHKeyGeneratorView()
                            } label: {
                                Label("Generate New Key", systemImage: "plus.circle")
                            }
                        }
                    } else {
                        Picker("Select Key", selection: $selectedKeyName) {
                            Text("Choose a key...").tag(nil as String?)
                            ForEach(keyManager.keys, id: \.name) { key in
                                HStack {
                                    Image(systemName: "key.horizontal")
                                    Text(key.name)
                                }
                                .tag(key.name as String?)
                            }
                        }
                        .accessibilityIdentifier("SSHKeyPicker")
                        
                        HStack {
                            Button {
                                showingKeyImport = true
                            } label: {
                                Label("Import", systemImage: "square.and.arrow.down")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("ImportKeyButton")
                            
                            NavigationLink {
                                SSHKeyGeneratorView()
                            } label: {
                                Label("Generate", systemImage: "plus.circle")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("GenerateKeyLink")
                            
                            NavigationLink {
                                SSHKeyListView()
                            } label: {
                                Label("Manage", systemImage: "list.bullet")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("ManageKeysLink")
                        }
                    }
                }
            }
            
            // Options
            Section {
                Toggle("Add to Favorites", isOn: $isFavorite)
                    .accessibilityIdentifier("FavoriteToggle")
            }
            
            // tmux Integration
            Section {
                Toggle("Auto-attach to tmux", isOn: $useTmux)
                    .accessibilityIdentifier("TmuxToggle")
                
                if useTmux {
                    TextField("Session Name", text: $tmuxSessionName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .tmuxSession)
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                        .accessibilityIdentifier("TmuxSessionNameField")
                        .accessibilityLabel("tmux session name")
                }
            } header: {
                Text("tmux")
            } footer: {
                if useTmux {
                    Text("Automatically attach to or create a tmux session on connect. Leave session name empty to use \"main\".")
                } else {
                    Text("Enable to automatically start or attach to a tmux session.")
                }
            }
            
            // Validation feedback — shown only when there's an error
            if let message = validationMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                        .font(.callout)
                        .accessibilityIdentifier("ValidationMessage")
                }
            }
        }
        .navigationTitle(profile == nil ? "New Connection" : "Edit Connection")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
                .accessibilityIdentifier("EditorCancelButton")
            }
            
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    save()
                }
                .disabled(!isValid)
                .accessibilityIdentifier("EditorSaveButton")
            }
        }
        .sheet(isPresented: $showingKeyImport) {
            SSHKeyImportPicker { url in
                importKey(from: url)
            }
        }
        .alert("Import Error", isPresented: $showingImportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "Unknown error")
        }
        .onAppear {
            loadProfile()
        }
    }
    
    private var isValid: Bool {
        validationMessage == nil
    }
    
    /// Returns a human-readable validation error, or nil if the form is valid.
    ///
    /// U2: For edits, empty password means "keep existing keychain entry" — only
    /// require a password on new connections.
    /// U3: Provides specific field-level feedback instead of a silent disabled Save.
    private var validationMessage: String? {
        if name.isEmpty { return "Name is required" }
        if host.isEmpty { return "Host is required" }
        if username.isEmpty { return "Username is required" }
        let portNum = Int(port) ?? 0
        if portNum <= 0 || portNum > 65535 { return "Port must be 1\u{2013}65535" }
        if authMethod == .sshKey && selectedKeyName == nil { return "Select an SSH key" }
        // Only require password on new connections — edits keep the existing keychain entry
        if authMethod == .password && password.isEmpty && profile == nil {
            return "Password is required"
        }
        return nil
    }
    
    private func importKey(from url: URL) {
        do {
            // Start accessing the security-scoped resource
            guard url.startAccessingSecurityScopedResource() else {
                throw SSHKeyError.invalidKeyFormat
            }
            defer { url.stopAccessingSecurityScopedResource() }
            
            // Read the key data
            let keyData = try Data(contentsOf: url)
            let keyName = url.deletingPathExtension().lastPathComponent
            
            // Import the key (name first, then data as pemData)
            let _ = try keyManager.importKey(name: keyName, pemData: keyData)
            
            // Auto-select the imported key
            selectedKeyName = keyName
        } catch {
            logger.error("Failed to import SSH key from \(url.lastPathComponent): \(error.localizedDescription)")
            importError = error.localizedDescription
            showingImportError = true
        }
    }
    
    private func loadProfile() {
        guard let profile = profile else {
            // For new profiles, default to sshKey if keys exist
            if !keyManager.keys.isEmpty {
                authMethod = .sshKey
                selectedKeyName = keyManager.keys.first?.name
            }
            return
        }
        
        name = profile.name
        host = profile.host
        port = String(profile.port)
        username = profile.username
        authMethod = profile.authMethod
        selectedKeyName = profile.sshKeyName
        isFavorite = profile.isFavorite
        useTmux = profile.useTmux
        tmuxSessionName = profile.tmuxSessionName ?? ""
        // Load saved password from keychain if using password auth
        if profile.authMethod == .password {
            if let savedPassword = try? KeychainManager.shared.getPassword(
                for: profile.host, username: profile.username
            ) {
                password = savedPassword
                logger.debug("Loaded saved password for \(profile.username)@\(profile.host)")
            }
        }
    }
    
    private func save() {
        var newProfile = ConnectionProfile(
            id: profile?.id ?? UUID(),
            name: name,
            host: host,
            port: Int(port) ?? 22,
            username: username,
            authMethod: authMethod,
            sshKeyName: authMethod == .sshKey ? selectedKeyName : nil,
            useTmux: useTmux,
            tmuxSessionName: tmuxSessionName.isEmpty ? nil : tmuxSessionName,
            enableFilesIntegration: false  // Feature archived
        )
        
        newProfile.isFavorite = isFavorite
        
        // Preserve existing metadata if editing
        if let existing = profile {
            newProfile.createdAt = existing.createdAt
            newProfile.lastConnectedAt = existing.lastConnectedAt
            newProfile.colorTag = existing.colorTag
        }
        
        // Save password to keychain when using password auth
        if authMethod == .password, !password.isEmpty {
            do {
                try KeychainManager.shared.savePassword(
                    password, for: host, username: username
                )
                logger.info("Saved password to keychain for \(username)@\(host)")
            } catch {
                logger.error("Failed to save password to keychain: \(error.localizedDescription)")
            }
        }
        
        onSave(newProfile)
        dismiss()
    }
}

// MARK: - SSH Key Generator View

struct SSHKeyGeneratorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var keyManager = SSHKeyManager.shared
    
    @State private var keyName = ""
    @State private var keyType: KeyType = .ed25519
    @State private var isGenerating = false
    @State private var generatedKey: SSHKeyPair?
    @State private var showingPublicKey = false
    @State private var errorMessage: String?
    
    enum KeyType: String, CaseIterable, Identifiable {
        case ed25519 = "Ed25519"
        case secureEnclave = "Secure Enclave (P-256)"
        case rsa2048 = "RSA-2048"
        case rsa4096 = "RSA-4096"
        
        var id: String { rawValue }
        
        var description: String {
            switch self {
            case .ed25519: return "Modern, fast, recommended"
            case .secureEnclave: return "Hardware-backed, device-bound, non-exportable"
            case .rsa2048: return "Compatible with older systems"
            case .rsa4096: return "Higher security, slower"
            }
        }
    }
    
    var body: some View {
        Form {
            Section("Key Details") {
                TextField("Key Name", text: $keyName)
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("KeyNameField")
                
                Picker("Key Type", selection: $keyType) {
                    ForEach(KeyType.allCases) { type in
                        VStack(alignment: .leading) {
                            Text(type.rawValue)
                            Text(type.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .tag(type)
                    }
                }
                .accessibilityIdentifier("KeyTypePicker")
            }
            
            if keyType == .secureEnclave {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Device-Bound Key")
                                .font(.subheadline.bold())
                            Text("The private key is stored in the Secure Enclave and can never be exported or backed up. If you lose this device, you'll need to add a new key to your servers.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: "lock.shield.fill")
                            .foregroundColor(.green)
                    }
                }
            }
            
            if let error = errorMessage {
                Section {
                    Text(error)
                        .foregroundColor(.red)
                }
            }
            
            if let key = generatedKey {
                Section("Generated Key") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Key generated successfully!")
                            .foregroundColor(.green)
                        
                        Button {
                            showingPublicKey = true
                        } label: {
                            Label("View Public Key", systemImage: "eye")
                        }
                        .accessibilityIdentifier("ViewPublicKeyButton")
                        
                        Button {
                            copyPublicKey(key)
                        } label: {
                            Label("Copy Public Key", systemImage: "doc.on.doc")
                        }
                        .accessibilityIdentifier("CopyPublicKeyButton")
                    }
                }
            }
        }
        .navigationTitle("Generate SSH Key")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    generateKey()
                } label: {
                    if isGenerating {
                        ProgressView()
                    } else {
                        Text("Generate")
                    }
                }
                .disabled(keyName.isEmpty || isGenerating || generatedKey != nil)
                .accessibilityIdentifier("GenerateButton")
            }
        }
        .sheet(isPresented: $showingPublicKey) {
            if let key = generatedKey {
                PublicKeyView(keyInfo: key)
            }
        }
    }
    
    private func generateKey() {
        isGenerating = true
        errorMessage = nil
        
        Task {
            do {
                let key: SSHKeyPair
                
                switch keyType {
                case .ed25519:
                    key = try keyManager.generateKey(name: keyName, type: .ed25519)
                case .rsa2048:
                    key = try keyManager.generateKey(name: keyName, type: .rsa2048)
                case .rsa4096:
                    key = try keyManager.generateKey(name: keyName, type: .rsa4096)
                case .secureEnclave:
                    key = try keyManager.generateKey(name: keyName, type: .secureEnclaveP256)
                }
                
                await MainActor.run {
                    isGenerating = false
                    generatedKey = key
                }
            } catch {
                logger.error("Failed to generate SSH key '\(keyName)': \(error.localizedDescription)")
                await MainActor.run {
                    isGenerating = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    private func copyPublicKey(_ key: SSHKeyPair) {
        UIPasteboard.general.string = key.publicKey
    }
}

// MARK: - Public Key View

struct PublicKeyView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var keyManager = SSHKeyManager.shared
    
    let keyInfo: SSHKeyPair
    @State private var publicKey: String
    @State private var copied = false
    @State private var showingInstaller = false
    
    init(keyInfo: SSHKeyPair) {
        self.keyInfo = keyInfo
        _publicKey = State(initialValue: keyInfo.publicKey)
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Key info header
                    HStack {
                        Image(systemName: keyInfo.isSecureEnclave ? "lock.shield.fill" : "key.fill")
                            .foregroundColor(keyInfo.isSecureEnclave ? .green : .accentColor)
                            .font(.title2)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(keyInfo.name)
                                .font(.headline)
                            HStack(spacing: 4) {
                                Text(keyInfo.type.displayName)
                                if keyInfo.isSecureEnclave {
                                    Text("• Secure Enclave")
                                        .foregroundColor(.green)
                                }
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }
                    }
                    .padding(.bottom, 4)
                    
                    Text("Add this public key to your server's ~/.ssh/authorized_keys file:")
                        .foregroundColor(.secondary)
                    
                    Text(publicKey)
                        .font(.system(.caption, design: .monospaced))
                        .padding()
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(8)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("PublicKeyText")
                    
                    // Action buttons
                    VStack(spacing: 12) {
                        Button {
                            UIPasteboard.general.string = publicKey
                            copied = true
                            // Reset after 2 seconds
                            Task {
                                try? await Task.sleep(nanoseconds: 2_000_000_000)
                                copied = false
                            }
                        } label: {
                            Label(copied ? "Copied!" : "Copy to Clipboard", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(copied ? .green : .accentColor)
                        .accessibilityIdentifier("PublicKeyCopyButton")
                        
                        Button {
                            showingInstaller = true
                        } label: {
                            Label("Install on Server...", systemImage: "server.rack")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("InstallOnServerButton")
                    }
                }
                .padding()
            }
            .navigationTitle("Public Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .accessibilityIdentifier("PublicKeyDoneButton")
                }
            }
            .sheet(isPresented: $showingInstaller) {
                NavigationStack {
                    PublicKeyInstallerView(publicKey: publicKey, keyName: keyInfo.name)
                }
            }
        }
    }
}

// MARK: - SSH Key List View

struct SSHKeyListView: View {
    @ObservedObject private var keyManager = SSHKeyManager.shared
    @ObservedObject private var biometricGatekeeper = BiometricGatekeeper.shared
    @State private var showingGenerator = false
    @State private var showingFilePicker = false
    @State private var selectedKey: SSHKeyPair?
    @State private var showingImportAlert = false
    @State private var showingImportError = false
    @State private var importKeyName = ""
    @State private var importKeyData: Data?
    @State private var importError: String?
    @State private var biometricError: String?
    @State private var showingBiometricError = false
    @State private var showingClearClipboard = false
    @State private var importedFromClipboard = false
    
    var body: some View {
        List {
            if keyManager.keys.isEmpty {
                ContentUnavailableView(
                    "No SSH Keys",
                    systemImage: "key",
                    description: Text("Generate an SSH key or import one to enable key-based authentication")
                )
            } else {
                ForEach(keyManager.keys, id: \.name) { key in
                    SSHKeyRow(keyInfo: key)
                        .contextMenu {
                            Button {
                                selectedKey = key
                            } label: {
                                Label("View Public Key", systemImage: "eye")
                            }
                            
                            Button {
                                UIPasteboard.general.string = key.publicKey
                            } label: {
                                Label("Copy Public Key", systemImage: "doc.on.doc")
                            }
                            
                            if biometricGatekeeper.isBiometricAvailable {
                                Button {
                                    toggleBiometric(for: key)
                                } label: {
                                    if key.requiresBiometric {
                                        Label("Disable \(biometricGatekeeper.biometricTypeName)", systemImage: "faceid")
                                    } else {
                                        Label("Require \(biometricGatekeeper.biometricTypeName)", systemImage: "faceid")
                                    }
                                }
                            }
                            
                            Divider()
                            
                            Button(role: .destructive) {
                                try? keyManager.deleteKey(name: key.name)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
                .onDelete { offsets in
                    for index in offsets {
                        try? keyManager.deleteKey(name: keyManager.keys[index].name)
                    }
                }
            }
        }
        .navigationTitle("SSH Keys")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showingGenerator = true
                    } label: {
                        Label("Generate Key...", systemImage: "wand.and.stars")
                    }
                    
                    Button {
                        importFromClipboard()
                    } label: {
                        Label("Import from Clipboard", systemImage: "doc.on.clipboard")
                    }
                    
                    Button {
                        showingFilePicker = true
                    } label: {
                        Label("Import from File...", systemImage: "doc.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingGenerator) {
            NavigationStack {
                SSHKeyGeneratorView()
            }
        }
        .sheet(isPresented: $showingFilePicker) {
            SSHKeyImportPicker { url in
                importKeyFromFile(url)
            }
        }
        .sheet(item: $selectedKey) { key in
            PublicKeyView(keyInfo: key)
        }
        .alert("Import Key", isPresented: $showingImportAlert) {
            TextField("Key Name", text: $importKeyName)
            Button("Cancel", role: .cancel) {
                importedFromClipboard = false
            }
            Button("Import") {
                if let data = importKeyData {
                    Task {
                        do {
                            _ = try keyManager.importKey(name: importKeyName, pemData: data)
                            if importedFromClipboard {
                                await MainActor.run {
                                    showingClearClipboard = true
                                }
                            }
                        } catch {
                            logger.error("Failed to import SSH key '\(importKeyName)': \(error.localizedDescription)")
                            importError = error.localizedDescription
                            showingImportError = true
                            importedFromClipboard = false
                        }
                    }
                }
            }
        } message: {
            if importedFromClipboard {
                Text("Enter a name for the imported key.\n\nNote: If you copied this key via Universal Clipboard, it may still be on other iCloud devices' clipboards.")
            } else {
                Text("Enter a name for the imported key")
            }
        }
        .alert("Import Error", isPresented: $showingImportError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(importError ?? "Unknown error")
        }
        .alert("Biometric Error", isPresented: $showingBiometricError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(biometricError ?? "Unknown error")
        }
        .alert("Clear Clipboard?", isPresented: $showingClearClipboard) {
            Button("Clear", role: .destructive) {
                UIPasteboard.general.string = ""
                importedFromClipboard = false
                logger.info("Clipboard cleared after key import")
            }
            Button("Keep", role: .cancel) {
                importedFromClipboard = false
            }
        } message: {
            Text("Your private key is still on the clipboard. Clear it for security?")
        }
    }
    
    private func toggleBiometric(for key: SSHKeyPair) {
        if key.requiresBiometric {
            // Disabling biometric requires successful biometric auth first —
            // prevents silent downgrade on a briefly unlocked device.
            Task {
                do {
                    try await biometricGatekeeper.ensureAuthenticated()
                    keyManager.setBiometricRequired(false, for: key.name)
                } catch {
                    biometricError = "Authenticate with \(biometricGatekeeper.biometricTypeName) to disable biometric protection"
                    showingBiometricError = true
                }
            }
        } else {
            // Enabling biometric doesn't require auth — it's an additive security step
            keyManager.setBiometricRequired(true, for: key.name)
        }
    }
    
    private func importFromClipboard() {
        guard let clipboardString = UIPasteboard.general.string,
              let data = clipboardString.data(using: .utf8) else {
            importError = "No valid key data in clipboard"
            showingImportError = true
            return
        }
        
        // Check if it looks like a private key
        if clipboardString.contains("PRIVATE KEY") {
            importKeyData = data
            importKeyName = "Imported-\(Date().formatted(date: .numeric, time: .omitted))"
            importedFromClipboard = true
            showingImportAlert = true
        } else {
            importError = "Clipboard doesn't contain a private key. Keys should start with '-----BEGIN'"
            showingImportError = true
        }
    }
    
    private func importKeyFromFile(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            importError = "Cannot access file"
            showingImportError = true
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        
        do {
            let data = try Data(contentsOf: url)
            importKeyData = data
            importKeyName = url.deletingPathExtension().lastPathComponent
            importedFromClipboard = false
            showingImportAlert = true
        } catch {
            logger.error("Failed to read key file \(url.lastPathComponent): \(error.localizedDescription)")
            importError = error.localizedDescription
            showingImportError = true
        }
    }
}

struct SSHKeyRow: View {
    let keyInfo: SSHKeyPair
    
    var body: some View {
        HStack {
            Image(systemName: keyInfo.isSecureEnclave ? "lock.shield.fill" : "key.fill")
                .foregroundColor(keyInfo.isSecureEnclave ? .green : .accentColor)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(keyInfo.name)
                    .font(.headline)
                
                // Show truncated fingerprint like ShellFish does
                Text(keyInfo.fingerprint.prefix(30) + "...")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                
                HStack {
                    Text(keyInfo.type.displayName)
                    if keyInfo.isSecureEnclave {
                        Text("• Secure Enclave")
                            .foregroundColor(.green)
                    }
                    if keyInfo.requiresBiometric {
                        Text("• \(BiometricGatekeeper.shared.biometricTypeName)")
                            .foregroundColor(.blue)
                    }
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }
        }
        .accessibilityIdentifier("SSHKeyRow-\(keyInfo.name)")
    }
}

// MARK: - SSH Key Import Picker

import UniformTypeIdentifiers

struct SSHKeyImportPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // .data (public.data) covers all flat files including extensionless SSH keys (id_rsa, id_ed25519)
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: SSHKeyImportPicker
        
        init(_ parent: SSHKeyImportPicker) {
            self.parent = parent
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first {
                parent.onPick(url)
            }
        }
        
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            // Just dismiss, no action needed
        }
    }
}

// MARK: - Public Key Installer View

struct PublicKeyInstallerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var profileManager = ConnectionProfileManager.shared
    
    let publicKey: String
    let keyName: String
    
    // Server fields
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var password = ""
    
    // State
    @State private var installState: InstallState = .idle
    @State private var selectedProfileId: UUID?
    
    enum InstallState: Equatable {
        case idle
        case connecting
        case installing
        case success
        case failed(String)
    }
    
    var body: some View {
        Form {
            // Quick fill from existing profiles
            if !profileManager.profiles.isEmpty {
                Section {
                    Picker("Fill from profile", selection: $selectedProfileId) {
                        Text("Manual entry").tag(nil as UUID?)
                        ForEach(profileManager.profiles) { profile in
                            Text(profile.displayString).tag(profile.id as UUID?)
                        }
                    }
                    .accessibilityIdentifier("InstallerProfilePicker")
                    .onChange(of: selectedProfileId) { _, newValue in
                        if let id = newValue,
                           let profile = profileManager.profiles.first(where: { $0.id == id }) {
                            host = profile.host
                            port = String(profile.port)
                            username = profile.username
                        }
                    }
                } header: {
                    Text("Quick Fill")
                } footer: {
                    Text("Select a saved connection to auto-fill server details.")
                }
            }
            
            Section {
                TextField("Host", text: $host)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .disabled(isWorking)
                    .accessibilityIdentifier("InstallerHostField")
                
                TextField("Port", text: $port)
                    .keyboardType(.numberPad)
                    .disabled(isWorking)
                    .accessibilityIdentifier("InstallerPortField")
                
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .disabled(isWorking)
                    .accessibilityIdentifier("InstallerUsernameField")
                
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .disabled(isWorking)
                    .accessibilityIdentifier("InstallerPasswordField")
            } header: {
                Text("Server")
            } footer: {
                Text("Password is required because the key is not yet installed on this server. It is used only for this operation and is not saved.")
            }
            
            Section {
                Text(publicKey)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
            } header: {
                Text("Key to Install")
            } footer: {
                Text("This key will be appended to ~/.ssh/authorized_keys on the server.")
            }
            
            Section {
                Button {
                    installKey()
                } label: {
                    HStack {
                        switch installState {
                        case .idle, .failed:
                            Label("Install Key", systemImage: "arrow.up.circle.fill")
                        case .connecting:
                            ProgressView()
                                .controlSize(.small)
                            Text("Connecting...")
                        case .installing:
                            ProgressView()
                                .controlSize(.small)
                            Text("Installing...")
                        case .success:
                            Label("Installed!", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .disabled(!canInstall)
                .accessibilityIdentifier("InstallKeyButton")
                
                if case .failed(let message) = installState {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                
                if case .success = installState {
                    Text("Public key has been added to the server. You can now connect using key-based authentication.")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
        }
        .navigationTitle("Install on Server")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(installState == .success ? "Done" : "Cancel") {
                    dismiss()
                }
            }
        }
    }
    
    private var isWorking: Bool {
        installState == .connecting || installState == .installing
    }
    
    private var canInstall: Bool {
        !host.isEmpty && !username.isEmpty && !password.isEmpty &&
        (Int(port) ?? 0) > 0 && (Int(port) ?? 0) <= 65535 &&
        !isWorking && installState != .success
    }
    
    private func installKey() {
        guard canInstall else { return }
        
        let targetHost = host
        let targetPort = Int(port) ?? 22
        let targetUsername = username
        let targetPassword = password
        let keyToInstall = publicKey
        
        // Shell-escape the public key to prevent injection.
        // Single quotes prevent all shell interpretation; any literal single quotes
        // in the key (unlikely but possible in comments) are handled by ending the
        // single-quoted string, adding an escaped single quote, and resuming.
        let escapedKey = keyToInstall.replacingOccurrences(of: "'", with: "'\\''")
        
        // The install command:
        // 1. Create ~/.ssh if it doesn't exist (with correct permissions)
        // 2. Append the public key
        // 3. Ensure correct permissions on authorized_keys
        // 4. Echo a marker so we can verify success even without exit status
        let installCommand = """
            mkdir -p ~/.ssh && chmod 700 ~/.ssh && \
            echo '\(escapedKey)' >> ~/.ssh/authorized_keys && \
            chmod 600 ~/.ssh/authorized_keys && \
            echo 'GEISTTY_KEY_INSTALLED'
            """
        
        installState = .connecting
        
        Task {
            do {
                let runner = SSHCommandRunner(
                    host: targetHost,
                    port: targetPort,
                    username: targetUsername
                )
                
                await MainActor.run { installState = .installing }
                
                let result = try await runner.run(command: installCommand, password: targetPassword)
                
                if result.succeeded || result.stdout.contains("GEISTTY_KEY_INSTALLED") {
                    installState = .success
                } else {
                    let errorMsg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    installState = .failed(errorMsg.isEmpty
                        ? "Command failed with exit code \(result.exitStatus ?? -1)"
                        : errorMsg)
                }
            } catch {
                installState = .failed(error.localizedDescription)
            }
        }
    }
}

#Preview {
    NavigationStack {
        ConnectionEditorView(profile: nil) { _ in }
    }
}
