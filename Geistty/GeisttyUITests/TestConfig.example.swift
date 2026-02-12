//
//  TestConfig.example.swift
//  GeisttyUITests
//
//  TEMPLATE FILE - Copy to TestConfig.local.swift and fill in real values
//  TestConfig.local.swift is gitignored and will NOT be committed
//

import Foundation

/// Test configuration for UI tests that require SSH connections
/// Copy this file to TestConfig.local.swift and fill in your test credentials
///
/// Setup steps:
///   1. Generate a test-only ed25519 key pair (no passphrase):
///        ssh-keygen -t ed25519 -f GeisttyUITests/test_secrets/geistty_test_ed25519 -N "" -C "geistty-test-key"
///   2. Add the public key to your test server's authorized_keys:
///        cat GeisttyUITests/test_secrets/geistty_test_ed25519.pub >> ~/.ssh/authorized_keys
///   3. Copy this file to TestConfig.local.swift and update the values below
///   4. Set isConfigured = true
///
/// The test_secrets/ directory is gitignored. Never commit private keys.
enum TestConfig {
    
    // MARK: - SSH Test Server
    
    /// SSH hostname or IP address (use "localhost" to test against your Mac)
    static let sshHost = "localhost"
    
    /// SSH port (default 22)
    static let sshPort: UInt16 = 22
    
    /// SSH username
    static let sshUsername = "your-username"
    
    /// Path to ed25519 private key for key-based auth
    /// Place your key in GeisttyUITests/test_secrets/ (gitignored)
    static let keyFilePath = Bundle(for: BundleToken.self).path(
        forResource: "geistty_test_ed25519",
        ofType: nil,
        inDirectory: "test_secrets"
    ) ?? "/path/to/your/geistty_test_ed25519"
    
    /// SSH password — prefer key-based auth; set to nil when using a key
    static let sshPassword: String? = nil
    
    // MARK: - Test Timeouts
    
    /// How long to wait for SSH connection
    static let connectionTimeout: TimeInterval = 30
    
    /// How long to wait for tmux operations
    static let tmuxOperationTimeout: TimeInterval = 5
    
    // MARK: - Feature Flags
    
    /// Set to true once you've configured real credentials
    static let isConfigured = false
    
    /// Enable verbose logging during tests
    static let verboseLogging = true
}

// Helper class to get bundle reference
private class BundleToken {}

// MARK: - Validation

extension TestConfig {
    static func validate() throws {
        guard isConfigured else {
            throw TestConfigError.notConfigured
        }
        guard !sshHost.contains("example.com") else {
            throw TestConfigError.placeholderHost
        }
        guard !sshUsername.isEmpty else {
            throw TestConfigError.missingUsername
        }
        guard FileManager.default.fileExists(atPath: keyFilePath) || sshPassword != nil else {
            throw TestConfigError.missingCredentials
        }
    }
    
    enum TestConfigError: Error, CustomStringConvertible {
        case notConfigured
        case placeholderHost
        case missingUsername
        case missingCredentials
        
        var description: String {
            switch self {
            case .notConfigured:
                return "TestConfig.isConfigured is false. Copy TestConfig.example.swift to TestConfig.local.swift and configure it."
            case .placeholderHost:
                return "SSH host still contains placeholder value"
            case .missingUsername:
                return "SSH username is empty"
            case .missingCredentials:
                return "No key file or password configured"
            }
        }
    }
}
