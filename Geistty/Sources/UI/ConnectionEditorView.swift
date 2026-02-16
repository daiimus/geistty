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
    
    var body: some View {
        Form {
            // Basic Info
            Section("Connection") {
                TextField("Name", text: $name)
                    .textContentType(.name)
                
                TextField("Host", text: $host)
                    .textContentType(.URL)
                    .autocapitalization(.none)
                    .keyboardType(.URL)
                
                TextField("Port", text: $port)
                    .keyboardType(.numberPad)
                
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .autocapitalization(.none)
            }
            
            // Authentication
            Section {
                Picker("Method", selection: $authMethod) {
                    ForEach(AuthMethod.allCases) { method in
                        Label(method.displayName, systemImage: method.icon)
                            .tag(method)
                    }
                }
                
                if authMethod == .password {
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                }
                
                Text(authMethod.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Authentication")
            } footer: {
                if authMethod == .sshKey {
                    Text("SSH keys are more secure than passwords. Import a .pem file from 1Password or Files, or generate a new key.")
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
                        
                        HStack {
                            Button {
                                showingKeyImport = true
                            } label: {
                                Label("Import", systemImage: "square.and.arrow.down")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            
                            NavigationLink {
                                SSHKeyGeneratorView()
                            } label: {
                                Label("Generate", systemImage: "plus.circle")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            
                            NavigationLink {
                                SSHKeyListView()
                            } label: {
                                Label("Manage", systemImage: "list.bullet")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            
            // Options
            Section {
                Toggle("Add to Favorites", isOn: $isFavorite)
            }
            
            // tmux Integration
            Section {
                Toggle("Auto-attach to tmux", isOn: $useTmux)
                
                if useTmux {
                    TextField("Session Name", text: $tmuxSessionName)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
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
        }
        .navigationTitle(profile == nil ? "New Connection" : "Edit Connection")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
            
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    save()
                }
                .disabled(!isValid)
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
        !name.isEmpty && !host.isEmpty && !username.isEmpty && (Int(port) ?? 0) > 0 && (Int(port) ?? 0) <= 65535 &&
        (authMethod == .password ? !password.isEmpty : true) &&
        (authMethod == .sshKey ? selectedKeyName != nil : true)
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
        case rsa2048 = "RSA-2048"
        case rsa4096 = "RSA-4096"
        case secureEnclave = "Secure Enclave"
        
        var id: String { rawValue }
        
        var description: String {
            switch self {
            case .ed25519: return "Modern, fast, recommended"
            case .rsa2048: return "Compatible with older systems"
            case .rsa4096: return "Higher security, slower"
            case .secureEnclave: return "Hardware-backed, most secure"
            }
        }
    }
    
    var body: some View {
        Form {
            Section("Key Details") {
                TextField("Key Name", text: $keyName)
                    .autocapitalization(.none)
                
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
            }
            
            if keyType == .secureEnclave {
                Section {
                    HStack {
                        Image(systemName: "lock.shield.fill")
                            .foregroundColor(.green)
                        VStack(alignment: .leading) {
                            Text("Secure Enclave")
                                .font(.headline)
                            Text("Key is stored in hardware and never leaves the device")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
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
                        
                        Button {
                            copyPublicKey(key)
                        } label: {
                            Label("Copy Public Key", systemImage: "doc.on.doc")
                        }
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
                    // Secure Enclave uses different API - not yet implemented
                    throw SSHKeyError.notSupported
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
    @State private var publicKey: String = "Loading..."
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Add this public key to your server's ~/.ssh/authorized_keys file:")
                        .foregroundColor(.secondary)
                    
                    Text(publicKey)
                        .font(.system(.caption, design: .monospaced))
                        .padding()
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(8)
                        .textSelection(.enabled)
                    
                    Button {
                        UIPasteboard.general.string = publicKey
                    } label: {
                        Label("Copy to Clipboard", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
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
                }
            }
            .onAppear {
                loadPublicKey()
            }
        }
    }
    
    private func loadPublicKey() {
        // Public key is already in the keyInfo
        publicKey = keyInfo.publicKey
    }
}

// MARK: - SSH Key List View

struct SSHKeyListView: View {
    @ObservedObject private var keyManager = SSHKeyManager.shared
    @State private var showingGenerator = false
    @State private var showingFilePicker = false
    @State private var selectedKey: SSHKeyPair?
    @State private var showingImportAlert = false
    @State private var showingImportError = false
    @State private var importKeyName = ""
    @State private var importKeyData: Data?
    @State private var importError: String?
    
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
            Button("Cancel", role: .cancel) { }
            Button("Import") {
                if let data = importKeyData {
                    Task {
                        do {
                            _ = try keyManager.importKey(name: importKeyName, pemData: data)
                        } catch {
                            logger.error("Failed to import SSH key '\(importKeyName)': \(error.localizedDescription)")
                            importError = error.localizedDescription
                            showingImportError = true
                        }
                    }
                }
            }
        } message: {
            Text("Enter a name for the imported key")
        }
        .alert("Import Error", isPresented: $showingImportError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(importError ?? "Unknown error")
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
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - SSH Key Import Picker

import UniformTypeIdentifiers

struct SSHKeyImportPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Allow any file type since SSH keys can have various extensions (.pem, .key, no extension, etc.)
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data, .text, .plainText])
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

#Preview {
    NavigationStack {
        ConnectionEditorView(profile: nil) { _ in }
    }
}
