//
//  CredentialProvider.swift
//  Bodak
//
//  Unified interface for getting credentials from various sources
//

import Foundation
import AuthenticationServices
import UIKit
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

// MARK: - Password AutoFill Provider (1Password, iCloud Keychain, etc.)

/// Provides credentials via iOS Password AutoFill
/// This integrates with 1Password, iCloud Keychain, and other password managers
class PasswordAutoFillProvider: CredentialProvider {
    
    var isAvailable: Bool { true }
    var displayName: String { "Password Manager" }
    
    private var presentingViewController: UIViewController?
    
    init(presentingViewController: UIViewController? = nil) {
        self.presentingViewController = presentingViewController
    }
    
    func getCredentials(for host: String, username: String) async throws -> SSHCredential {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async { [weak self] in
                self?.requestCredentials(host: host, username: username, continuation: continuation)
            }
        }
    }
    
    @MainActor
    private func requestCredentials(
        host: String,
        username: String,
        continuation: CheckedContinuation<SSHCredential, Error>
    ) {
        // Get the presenting view controller
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first,
              let rootVC = window.rootViewController else {
            continuation.resume(throwing: CredentialError.noPresentingViewController)
            return
        }
        
        let presenter = presentingViewController ?? rootVC.presentedViewController ?? rootVC
        
        // Create the authorization request
        let passwordProvider = ASAuthorizationPasswordProvider()
        let request = passwordProvider.createRequest()
        
        // Create the controller
        let controller = ASAuthorizationController(authorizationRequests: [request])
        
        // Create delegate to handle result
        let delegate = PasswordAuthDelegate(host: host, username: username, continuation: continuation)
        controller.delegate = delegate
        controller.presentationContextProvider = PasswordPresentationContext(anchor: presenter)
        
        // Store delegate to prevent deallocation
        objc_setAssociatedObject(controller, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
        
        // Perform the request
        controller.performRequests()
    }
}

// MARK: - ASAuthorizationController Delegate

private class PasswordAuthDelegate: NSObject, ASAuthorizationControllerDelegate {
    let host: String
    let username: String
    var continuation: CheckedContinuation<SSHCredential, Error>?
    
    init(host: String, username: String, continuation: CheckedContinuation<SSHCredential, Error>) {
        self.host = host
        self.username = username
        self.continuation = continuation
    }
    
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let continuation = continuation else { return }
        self.continuation = nil  // Prevent double-resume
        
        if let credential = authorization.credential as? ASPasswordCredential {
            let password = credential.password
            let retrievedUsername = credential.user
            
            logger.info("✅ Got password from AutoFill for user: \(retrievedUsername)")
            
            continuation.resume(returning: SSHCredential(
                authType: .password(password),
                source: "Password AutoFill"
            ))
        } else {
            continuation.resume(throwing: CredentialError.unsupportedCredentialType)
        }
    }
    
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        guard let continuation = continuation else { return }
        self.continuation = nil  // Prevent double-resume
        
        logger.error("❌ AutoFill error: \(error.localizedDescription)")
        
        if let authError = error as? ASAuthorizationError {
            switch authError.code {
            case .canceled:
                continuation.resume(throwing: CredentialError.cancelled)
            case .failed:
                continuation.resume(throwing: CredentialError.autoFillFailed(error.localizedDescription))
            case .notHandled:
                continuation.resume(throwing: CredentialError.autoFillNotAvailable)
            case .invalidResponse:
                continuation.resume(throwing: CredentialError.invalidResponse)
            case .unknown:
                continuation.resume(throwing: CredentialError.autoFillFailed(error.localizedDescription))
            case .notInteractive:
                continuation.resume(throwing: CredentialError.autoFillFailed("Not interactive"))
            case .matchedExcludedCredential:
                continuation.resume(throwing: CredentialError.autoFillFailed("Credential excluded"))
            @unknown default:
                continuation.resume(throwing: CredentialError.autoFillFailed(error.localizedDescription))
            }
        } else {
            continuation.resume(throwing: error)
        }
    }
}

// MARK: - Presentation Context

private class PasswordPresentationContext: NSObject, ASAuthorizationControllerPresentationContextProviding {
    let anchor: UIViewController
    
    init(anchor: UIViewController) {
        self.anchor = anchor
    }
    
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        return anchor.view.window!
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
            PasswordAutoFillProvider()  // Unified provider for 1Password, iCloud Keychain, etc.
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
            // Try saved keychain first, fall back to autofill
            do {
                let provider = KeychainCredentialProvider()
                return try await provider.getCredentials(for: profile.host, username: profile.username)
            } catch {
                // Password not saved, try autofill
                let provider = PasswordAutoFillProvider()
                return try await provider.getCredentials(for: profile.host, username: profile.username)
            }
            
        case .sshKey:
            guard let keyName = profile.sshKeyName else {
                throw CredentialError.noKeySelected
            }
            let provider = SSHKeyCredentialProvider(keyName: keyName)
            return try await provider.getCredentials(for: profile.host, username: profile.username)
            
        case .passwordManager:
            // Use the unified Password AutoFill provider
            // This shows the iOS credential picker with 1Password, iCloud Keychain, etc.
            let provider = PasswordAutoFillProvider()
            return try await provider.getCredentials(for: profile.host, username: profile.username)
        }
    }
    
    /// Request credentials via AutoFill (shows system credential picker)
    /// This integrates with 1Password, iCloud Keychain, and other password managers
    func requestCredentialsViaAutoFill(for host: String, username: String) async throws -> SSHCredential {
        let provider = PasswordAutoFillProvider()
        return try await provider.getCredentials(for: host, username: username)
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
    case noPresentingViewController
    case unsupportedCredentialType
    case autoFillNotAvailable
    case autoFillFailed(String)
    case invalidResponse
    
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
        case .noPresentingViewController:
            return "Cannot present credential picker"
        case .unsupportedCredentialType:
            return "Unsupported credential type received"
        case .autoFillNotAvailable:
            return "Password AutoFill is not available"
        case .autoFillFailed(let reason):
            return "Password AutoFill failed: \(reason)"
        case .invalidResponse:
            return "Invalid response from credential provider"
        }
    }
}
