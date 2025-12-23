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
enum TestConfig {
    
    // MARK: - SSH Test Server
    
    /// SSH hostname or IP address
    static let sshHost = "your-test-server.example.com"
    
    /// SSH port (default 22)
    static let sshPort: UInt16 = 22
    
    /// SSH username
    static let sshUsername = "testuser"
    
    /// Path to PEM file (relative to test bundle or absolute)
    /// Place your .pem file in a gitignored location like ~/
    static let pemFilePath = "/path/to/your/key.pem"
    
    /// Alternative: SSH password (use PEM key instead when possible)
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
        guard FileManager.default.fileExists(atPath: pemFilePath) || sshPassword != nil else {
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
                return "No PEM file or password configured"
            }
        }
    }
}
