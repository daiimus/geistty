//
//  KeychainManager.swift
//  Geistty
//
//  Secure storage for SSH keys and credentials using iOS Keychain.
//  
//  Both the main app and File Provider extension have the same keychain-access-groups
//  entitlement, which automatically allows them to share keychain items.
//  We don't need to specify kSecAttrAccessGroup - iOS handles sharing automatically.
//

import Foundation
import Security
import os.log

private let logger = Logger(subsystem: "com.geistty", category: "Keychain")

/// Errors that can occur during Keychain operations
enum KeychainError: LocalizedError {
    case itemNotFound
    case duplicateItem
    case unexpectedStatus(OSStatus)
    case dataConversionError
    case secureEnclaveNotAvailable
    case authenticationFailed
    
    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "Item not found in Keychain"
        case .duplicateItem:
            return "Item already exists in Keychain"
        case .unexpectedStatus(let status):
            return "Keychain error: \(status)"
        case .dataConversionError:
            return "Failed to convert data"
        case .secureEnclaveNotAvailable:
            return "Secure Enclave is not available on this device"
        case .authenticationFailed:
            return "Authentication failed"
        }
    }
}

/// Manages secure storage of credentials and SSH keys in the iOS Keychain.
///
/// Both the main app and File Provider extension share the same keychain-access-groups
/// entitlement. We explicitly specify the access group to ensure items are accessible
/// across app extensions.
class KeychainManager {
    
    /// Shared instance - use this everywhere (main app and extensions)
    static let shared = KeychainManager()
    
    /// Legacy alias for backwards compatibility
    static var sharedForExtension: KeychainManager { shared }
    
    /// Service identifier for our app's keychain items
    private let service = "com.geistty"
    
    /// Access group for sharing between main app and extensions
    /// This must match the keychain-access-groups in entitlements
    /// The actual value at runtime will be "TEAMID.com.geistty.shared"
    private let accessGroup = "com.geistty.shared"
    
    private init() {}
    
    // MARK: - Password Storage
    
    /// Save a password for a connection
    func savePassword(_ password: String, for host: String, username: String) throws {
        let account = "\(username)@\(host)"
        guard let data = password.data(using: .utf8) else {
            throw KeychainError.dataConversionError
        }
        
        // Delete existing first to avoid duplicate issues
        try? deletePassword(for: host, username: username)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        
        guard status == errSecSuccess else {
            logger.error("❌ Failed to save password for \(account): OSStatus \(status)")
            throw KeychainError.unexpectedStatus(status)
        }
        
        logger.info("💾 Saved password for \(account)")
    }
    
    /// Retrieve a password for a connection
    func getPassword(for host: String, username: String) throws -> String {
        let account = "\(username)@\(host)"
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeychainError.itemNotFound
            }
            throw KeychainError.unexpectedStatus(status)
        }
        
        guard let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw KeychainError.dataConversionError
        }
        
        return password
    }
    
    /// Delete a password
    func deletePassword(for host: String, username: String) throws {
        let account = "\(username)@\(host)"
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
        
        logger.info("🗑️ Deleted password for \(account)")
    }
    
    // MARK: - SSH Key Storage
    
    /// Save an SSH private key PEM data to the Keychain
    func saveSSHKey(_ privateKey: Data, name: String, useSecureEnclave: Bool = false) throws {
        let account = "ssh-key:\(name)"
        
        // Delete existing key with same name (all formats)
        try? deleteSSHKey(name: name)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: privateKey,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        
        guard status == errSecSuccess else {
            logger.error("❌ Failed to save SSH key '\(name)': OSStatus \(status)")
            throw KeychainError.unexpectedStatus(status)
        }
        
        logger.info("💾 Saved SSH key '\(name)'")
    }
    
    /// Retrieve an SSH private key PEM data from the Keychain
    func getSSHKey(name: String) throws -> Data {
        let account = "ssh-key:\(name)"
        
        // Try new format first (generic password)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        
        // Fallback: old kSecClassKey format (pre-migration)
        if status == errSecItemNotFound {
            let tag = "com.geistty.key.\(name)"
            let oldQuery: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            status = SecItemCopyMatching(oldQuery as CFDictionary, &result)
            
            // If found in old format, migrate to new format
            if status == errSecSuccess, let data = result as? Data {
                logger.info("🔄 Migrating SSH key '\(name)' from old format")
                try? saveSSHKey(data, name: name)
            }
        }
        
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                logger.warning("🔑 SSH key '\(name)' not found in keychain")
                throw KeychainError.itemNotFound
            }
            throw KeychainError.unexpectedStatus(status)
        }
        
        guard let data = result as? Data else {
            throw KeychainError.dataConversionError
        }
        
        logger.info("🔑 Retrieved SSH key '\(name)'")
        return data
    }
    
    /// Delete an SSH key
    func deleteSSHKey(name: String) throws {
        let account = "ssh-key:\(name)"
        
        // Delete new format
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        
        // Also delete old kSecClassKey format
        let tag = "com.geistty.key.\(name)"
        let oldQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag.data(using: .utf8)!
        ]
        SecItemDelete(oldQuery as CFDictionary)
        
        logger.info("🗑️ Deleted SSH key '\(name)'")
    }
    
    /// List all saved SSH key names
    func listSSHKeys() -> [String] {
        var keyNames: Set<String> = []
        
        // Query new format (generic password with ssh-key: prefix)
        let queryNew: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        
        var result: AnyObject?
        if SecItemCopyMatching(queryNew as CFDictionary, &result) == errSecSuccess,
           let items = result as? [[String: Any]] {
            for item in items {
                if let account = item[kSecAttrAccount as String] as? String,
                   account.hasPrefix("ssh-key:") {
                    keyNames.insert(String(account.dropFirst("ssh-key:".count)))
                }
            }
        }
        
        // Also query old kSecClassKey format for migration
        let queryOld: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        
        if SecItemCopyMatching(queryOld as CFDictionary, &result) == errSecSuccess,
           let items = result as? [[String: Any]] {
            for item in items {
                if let tagData = item[kSecAttrApplicationTag as String] as? Data,
                   let tag = String(data: tagData, encoding: .utf8),
                   tag.hasPrefix("com.geistty.key.") {
                    keyNames.insert(String(tag.dropFirst("com.geistty.key.".count)))
                }
            }
        }
        
        return Array(keyNames).sorted()
    }
}
