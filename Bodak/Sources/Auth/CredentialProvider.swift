//
//  CredentialProvider.swift
//  Bodak
//
//  Unified interface for getting credentials from various sources
//

import Foundation
import AuthenticationServices
import os.log

private let logger = Logger(subsystem: "com.bodak", category: "Credentials")

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
    }
    
    let authType: AuthType
    let source: String  // Where the credential came from
}

// MARK: - Keychain Provider

/// Provides credentials from the iOS Keychain
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
        
        let keyPath = try keyManager.getPrivateKeyPath(name: keyName)
        return SSHCredential(authType: .privateKey(path: keyPath, passphrase: nil), source: "SSH Key: \(keyName)")
    }
}

// MARK: - iCloud Keychain Provider (via ASAuthorizationController)

/// Provides credentials from iCloud Keychain using system UI
class iCloudKeychainProvider: CredentialProvider {
    
    var isAvailable: Bool { true }
    var displayName: String { "iCloud Keychain" }
    
    func getCredentials(for host: String, username: String) async throws -> SSHCredential {
        // This uses the system's password autofill
        // In a real implementation, you'd present ASAuthorizationController
        
        return try await withCheckedThrowingContinuation { continuation in
            // TODO: Implement ASAuthorizationController flow
            // For now, throw an error indicating this needs to be implemented
            continuation.resume(throwing: CredentialError.notImplemented)
        }
    }
}

// MARK: - 1Password Provider

/// Provides credentials from 1Password
class OnePasswordProvider: CredentialProvider {
    
    var isAvailable: Bool {
        // Check if 1Password is installed
        // Could also check for 1Password SDK availability
        return UIApplication.shared.canOpenURL(URL(string: "onepassword://")!)
    }
    
    var displayName: String { "1Password" }
    
    func getCredentials(for host: String, username: String) async throws -> SSHCredential {
        // 1Password integration options:
        // 1. Use 1Password SDK (requires CocoaPods/SPM integration)
        // 2. Use 1Password URL scheme
        // 3. Use AutoFill via ASCredentialProviderViewController
        
        // For now, we'll use the URL scheme approach
        guard isAvailable else {
            throw CredentialError.providerNotAvailable("1Password")
        }
        
        // TODO: Implement 1Password URL scheme or SDK integration
        throw CredentialError.notImplemented
    }
}

// MARK: - Credential Manager

/// Manages multiple credential providers and handles credential retrieval
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
            SSHKeyCredentialProvider(),
            iCloudKeychainProvider(),
            OnePasswordProvider()
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
        case .password:
            let provider = KeychainCredentialProvider()
            return try await provider.getCredentials(for: profile.host, username: profile.username)
            
        case .sshKey:
            guard let keyName = profile.sshKeyName else {
                throw CredentialError.noKeySelected
            }
            let provider = SSHKeyCredentialProvider(keyName: keyName)
            return try await provider.getCredentials(for: profile.host, username: profile.username)
            
        case .passwordManager:
            guard let pmProvider = profile.passwordManagerProvider else {
                throw CredentialError.noProviderSelected
            }
            
            switch pmProvider {
            case .icloudKeychain:
                let provider = iCloudKeychainProvider()
                return try await provider.getCredentials(for: profile.host, username: profile.username)
            case .onePassword:
                let provider = OnePasswordProvider()
                return try await provider.getCredentials(for: profile.host, username: profile.username)
            case .lastPass:
                throw CredentialError.notImplemented
            }
        }
    }
    
    /// Save password to Keychain for a profile
    func savePassword(_ password: String, for profile: ConnectionProfile) throws {
        try KeychainManager.shared.savePassword(password, for: profile.host, username: profile.username)
    }
}

// MARK: - Errors

enum CredentialError: LocalizedError {
    case notImplemented
    case providerNotAvailable(String)
    case noKeySelected
    case noProviderSelected
    case cancelled
    
    var errorDescription: String? {
        switch self {
        case .notImplemented:
            return "This feature is not yet implemented"
        case .providerNotAvailable(let provider):
            return "\(provider) is not available"
        case .noKeySelected:
            return "No SSH key selected"
        case .noProviderSelected:
            return "No password manager selected"
        case .cancelled:
            return "Authentication cancelled"
        }
    }
}
