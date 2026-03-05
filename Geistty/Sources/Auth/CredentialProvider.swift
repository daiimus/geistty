//
//  CredentialProvider.swift
//  Geistty
//
//  Unified interface for getting credentials from various sources
//
//  Best Practices for SSH Authentication:
//  1. SSH Keys (preferred) - More secure, no password to remember
//     - Import .pem/.key files from Files app
//     - Generate Ed25519 or RSA keys directly in Geistty
//     - Keys stored securely in iOS Keychain
//
//  2. Password - User enters at connection time
//     - Can be saved to Keychain for convenience
//     - Never stored in plaintext
//
//  Note on Password Managers:
//  - Desktop SSH agent integrations (1Password, LastPass, etc.) are not available on iOS
//  - To use keys from a password manager, export the .pem file and import into Geistty via Files
//

import Foundation
import NIOSSH
import os.log

private let logger = Logger(subsystem: "com.geistty", category: "Credentials")

/// Protocol for credential providers
protocol CredentialProvider {
    /// Get credentials for a host/username combination
    func getCredentials(for host: String, username: String) async throws -> SSHCredential
    
    /// Check if this provider is available
    var isAvailable: Bool { get }
    
    /// Display name for the provider
    var displayName: String { get }
}

/// Represents SSH credentials
struct SSHCredential {
    enum AuthType {
        case password(String)
        case privateKey(path: String, passphrase: String?)
        case privateKeyData(Data, passphrase: String?)
        /// Pre-built NIOSSHPrivateKey — used for Secure Enclave keys that bypass SSHKeyParser.
        /// The NIOSSHPrivateKey wraps the SE key and handles signing internally.
        case sshPrivateKey(NIOSSHPrivateKey)
    }
    
    let authType: AuthType
    let source: String  // Where the credential came from
}

// MARK: - Keychain Provider

/// Provides saved passwords from the iOS Keychain
class KeychainCredentialProvider: CredentialProvider {
    
    private let keychain = KeychainManager.shared
    
    var isAvailable: Bool { true }
    var displayName: String { "Saved Passwords" }
    
    func getCredentials(for host: String, username: String) async throws -> SSHCredential {
        let password = try keychain.getPassword(for: host, username: username)
        return SSHCredential(authType: .password(password), source: "Keychain")
    }
}

// MARK: - SSH Key Provider

/// Provides credentials from saved SSH keys
@MainActor
class SSHKeyCredentialProvider: CredentialProvider {
    
    private let keyManager = SSHKeyManager.shared
    
    var isAvailable: Bool { !keyManager.keys.isEmpty }
    var displayName: String { "SSH Keys" }
    
    private var selectedKeyName: String?
    
    init(keyName: String? = nil) {
        self.selectedKeyName = keyName
    }
    
    func getCredentials(for host: String, username: String) async throws -> SSHCredential {
        guard let keyName = selectedKeyName ?? keyManager.keys.first?.name else {
            throw SSHKeyError.keyNotFound
        }
        
        // Look up the key metadata to determine if it's a Secure Enclave key
        guard let keyPair = keyManager.keys.first(where: { $0.name == keyName }) else {
            throw SSHKeyError.keyNotFound
        }
        
        // Biometric gate: if the key requires biometric auth, ensure the session is valid
        if keyPair.requiresBiometric {
            try await BiometricGatekeeper.shared.ensureAuthenticated()
        }
        
        if keyPair.isSecureEnclave {
            // SE key path: reconstruct the SE key and wrap in NIOSSHPrivateKey directly.
            // This bypasses SSHKeyParser entirely — SE keys have no PEM representation.
            let seKey = try keyManager.getSecureEnclaveKey(name: keyName)
            let nioKey = NIOSSHPrivateKey(secureEnclaveP256Key: seKey)
            return SSHCredential(authType: .sshPrivateKey(nioKey), source: "SSH Key (Secure Enclave): \(keyName)")
        } else {
            // Software key path: get raw PEM data for SSHKeyParser
            let keyData = try keyManager.getPrivateKey(name: keyName)
            return SSHCredential(authType: .privateKeyData(keyData, passphrase: nil), source: "SSH Key: \(keyName)")
        }
    }
}

// MARK: - Credential Manager

/// Manages credential providers and handles credential retrieval for SSH connections
@MainActor
class CredentialManager: ObservableObject {
    
    static let shared = CredentialManager()
    
    /// Available providers
    @Published var providers: [any CredentialProvider] = []
    
    private init() {
        refreshProviders()
    }
    
    /// Refresh the list of available providers
    func refreshProviders() {
        providers = [
            KeychainCredentialProvider(),
            SSHKeyCredentialProvider()
        ].filter { $0.isAvailable }
    }
    
    /// Get credentials using a specific provider
    func getCredentials(
        for profile: ConnectionProfile,
        using provider: any CredentialProvider
    ) async throws -> SSHCredential {
        return try await provider.getCredentials(for: profile.host, username: profile.username)
    }
    
    /// Get credentials automatically based on profile's auth method
    func getCredentials(for profile: ConnectionProfile) async throws -> SSHCredential {
        switch profile.authMethod {
        case .sshKey:
            guard let keyName = profile.sshKeyName else {
                throw CredentialError.noKeySelected
            }
            let provider = SSHKeyCredentialProvider(keyName: keyName)
            return try await provider.getCredentials(for: profile.host, username: profile.username)
            
        case .password:
            // Try saved keychain password
            let provider = KeychainCredentialProvider()
            return try await provider.getCredentials(for: profile.host, username: profile.username)
        }
    }
    
    /// Check if credentials exist for a profile
    func hasCredentials(for profile: ConnectionProfile) -> Bool {
        switch profile.authMethod {
        case .sshKey:
            guard let keyName = profile.sshKeyName else { return false }
            return SSHKeyManager.shared.keys.contains { $0.name == keyName }
            
        case .password:
            return (try? KeychainManager.shared.getPassword(for: profile.host, username: profile.username)) != nil
        }
    }
    
    /// Save password to Keychain for a profile
    func savePassword(_ password: String, for profile: ConnectionProfile) throws {
        try KeychainManager.shared.savePassword(password, for: profile.host, username: profile.username)
    }
    
    /// Save password to Keychain for host/username
    func savePassword(_ password: String, for host: String, username: String) throws {
        try KeychainManager.shared.savePassword(password, for: host, username: username)
    }
}

// MARK: - Errors

enum CredentialError: LocalizedError {
    case noKeySelected
    case noPasswordSaved
    case cancelled
    
    var errorDescription: String? {
        switch self {
        case .noKeySelected:
            return "No SSH key selected for this connection"
        case .noPasswordSaved:
            return "No password saved for this connection"
        case .cancelled:
            return "Authentication cancelled"
        }
    }
}
