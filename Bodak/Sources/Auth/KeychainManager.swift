//
//  KeychainManager.swift
//  Bodak
//
//  Secure storage for SSH keys and credentials using iOS Keychain
//

import Foundation
import Security
import os.log

private let logger = Logger(subsystem: "com.bodak", category: "Keychain")

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
    private let service = "com.bodak"
    
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
    
    /// Save an SSH private key to the Keychain
    func saveSSHKey(_ privateKey: Data, name: String, useSecureEnclave: Bool = false) throws {
        let tag = "com.bodak.key.\(name)"
        
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
            kSecValueData as String: privateKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        if let group = accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        
        // Delete existing key with same name
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag.data(using: .utf8)!
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        
        let status = SecItemAdd(query as CFDictionary, nil)
        
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        
        logger.info("💾 Saved SSH key: \(name)")
    }
    
    /// Retrieve an SSH private key from the Keychain
    func getSSHKey(name: String) throws -> Data {
        let tag = "com.bodak.key.\(name)"
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
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
        
        guard let data = result as? Data else {
            throw KeychainError.dataConversionError
        }
        
        return data
    }
    
    /// Delete an SSH key
    func deleteSSHKey(name: String) throws {
        let tag = "com.bodak.key.\(name)"
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag.data(using: .utf8)!
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
        
        logger.info("🗑️ Deleted SSH key: \(name)")
    }
    
    /// List all saved SSH key names
    func listSSHKeys() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: "com.bodak.key.".data(using: .utf8)!,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }
        
        return items.compactMap { item in
            guard let tagData = item[kSecAttrApplicationTag as String] as? Data,
                  let tag = String(data: tagData, encoding: .utf8) else {
                return nil
            }
            // Extract key name from tag
            let prefix = "com.bodak.key."
            if tag.hasPrefix(prefix) {
                return String(tag.dropFirst(prefix.count))
            }
            return nil
        }
    }
}
