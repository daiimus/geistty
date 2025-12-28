//
//  KeychainManager.swift
//  Geistty
//
//  Secure storage for SSH keys and credentials using iOS Keychain
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

/// Manages secure storage of credentials and SSH keys in the iOS Keychain
class KeychainManager {
    
    /// Shared instance
    static let shared = KeychainManager()
    
    /// Service identifier for our app's keychain items
    private let service = "com.geistty"
    
    /// Access group for sharing across app extensions (if needed)
    private let accessGroup: String? = nil
    
    private init() {}
    
    // MARK: - Password Storage
    
    /// Save a password for a connection
    func savePassword(_ password: String, for host: String, username: String) throws {
        let account = "\(username)@\(host)"
        guard let data = password.data(using: .utf8) else {
            throw KeychainError.dataConversionError
        }
        
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        if let group = accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        
        // Try to add, if duplicate exists, update it
        var status = SecItemAdd(query as CFDictionary, nil)
        
        if status == errSecDuplicateItem {
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            let updateAttributes: [String: Any] = [
                kSecValueData as String: data
            ]
            status = SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)
        }
        
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        
        logger.info("💾 Saved password for \(account)")
    }
    
    /// Retrieve a password for a connection
    func getPassword(for host: String, username: String) throws -> String {
        let account = "\(username)@\(host)"
        
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        if let group = accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        
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
    /// Note: We store raw PEM data as generic password, not as kSecClassKey,
    /// because kSecClassKey expects specific cryptographic formats and may corrupt PEM text.
    func saveSSHKey(_ privateKey: Data, name: String, useSecureEnclave: Bool = false) throws {
        let account = "ssh-key:\(name)"
        
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: privateKey,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        if let group = accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        
        // Delete existing key with same name (both old and new format)
        let deleteQueryOld: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: "com.geistty.key.\(name)".data(using: .utf8)!
        ]
        SecItemDelete(deleteQueryOld as CFDictionary)
        
        let deleteQueryNew: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQueryNew as CFDictionary)
        
        let status = SecItemAdd(query as CFDictionary, nil)
        
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        
        logger.info("💾 Saved SSH key: \(name)")
    }
    
    /// Retrieve an SSH private key PEM data from the Keychain
    func getSSHKey(name: String) throws -> Data {
        let account = "ssh-key:\(name)"
        
        // Try new format first (generic password)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecSuccess {
            logger.info("🔑 Retrieved key '\(name)' from NEW format (kSecClassGenericPassword)")
        }
        
        // Fallback to old format (kSecClassKey) for migration
        // WARNING: Old format likely corrupted non-RSA keys!
        if status == errSecItemNotFound {
            logger.warning("⚠️ Key '\(name)' not found in new format, trying OLD format (may be corrupted!)")
            let tag = "com.geistty.key.\(name)"
            let oldQuery: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            status = SecItemCopyMatching(oldQuery as CFDictionary, &result)
            if status == errSecSuccess {
                logger.error("❌ Key '\(name)' retrieved from OLD format - THIS KEY IS LIKELY CORRUPTED! Delete and re-import.")
            }
        }
        
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeychainError.itemNotFound
            }
            throw KeychainError.unexpectedStatus(status)
        }
        
        guard let data = result as? Data else {
            throw KeychainError.dataConversionError
        }
        
        return data
    }
    
    /// Delete an SSH key
    func deleteSSHKey(name: String) throws {
        let account = "ssh-key:\(name)"
        
        // Delete new format
        let queryNew: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(queryNew as CFDictionary)
        
        // Also delete old format for migration
        let tag = "com.geistty.key.\(name)"
        let queryOld: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag.data(using: .utf8)!
        ]
        let status = SecItemDelete(queryOld as CFDictionary)
        
        // Consider success if either was deleted or not found
        logger.info("🗑️ Deleted SSH key: \(name)")
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
        
        var resultNew: AnyObject?
        if SecItemCopyMatching(queryNew as CFDictionary, &resultNew) == errSecSuccess,
           let items = resultNew as? [[String: Any]] {
            for item in items {
                if let account = item[kSecAttrAccount as String] as? String,
                   account.hasPrefix("ssh-key:") {
                    keyNames.insert(String(account.dropFirst("ssh-key:".count)))
                }
            }
        }
        
        // Also query old format for migration
        let queryOld: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        
        var resultOld: AnyObject?
        if SecItemCopyMatching(queryOld as CFDictionary, &resultOld) == errSecSuccess,
           let items = resultOld as? [[String: Any]] {
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
