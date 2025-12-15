//
//  SSHKeyManager.swift
//  Geistty
//
//  SSH key generation, import, and management
//

import Foundation
import Security
import CryptoKit
import os.log

private let logger = Logger(subsystem: "com.geistty", category: "SSHKey")

/// Types of SSH keys we support
enum SSHKeyType: String, CaseIterable, Identifiable {
    case ed25519 = "ed25519"
    case rsa2048 = "rsa-2048"
    case rsa4096 = "rsa-4096"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .ed25519: return "Ed25519 (Recommended)"
        case .rsa2048: return "RSA 2048-bit"
        case .rsa4096: return "RSA 4096-bit"
        }
    }
    
    var keySize: Int {
        switch self {
        case .ed25519: return 256
        case .rsa2048: return 2048
        case .rsa4096: return 4096
        }
    }
}

/// Represents an SSH key pair
struct SSHKeyPair: Identifiable {
    let id: UUID
    let name: String
    let type: SSHKeyType
    let publicKey: String
    let createdAt: Date
    let isSecureEnclave: Bool
    
    /// The fingerprint of the public key (SHA256)
    var fingerprint: String {
        // Parse the public key and compute SHA256 fingerprint
        guard let keyData = publicKeyData else { return "unknown" }
        let hash = SHA256.hash(data: keyData)
        let base64 = Data(hash).base64EncodedString()
        return "SHA256:\(base64)"
    }
    
    /// Extract the raw key data from the public key string
    private var publicKeyData: Data? {
        // Public key format: "ssh-ed25519 AAAA... comment"
        let parts = publicKey.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return Data(base64Encoded: String(parts[1]))
    }
}

/// Manages SSH key generation, storage, and retrieval
class SSHKeyManager: ObservableObject {
    
    /// Shared instance
    static let shared = SSHKeyManager()
    
    /// Published list of available keys
    @Published var keys: [SSHKeyPair] = []
    
    /// Keychain manager for storage
    private let keychain = KeychainManager.shared
    
    private init() {
        loadKeys()
    }
    
    // MARK: - Key Generation
    
    /// Generate a new SSH key pair
    func generateKey(name: String, type: SSHKeyType, passphrase: String? = nil) throws -> SSHKeyPair {
        logger.info("🔑 Generating \(type.rawValue) key: \(name)")
        
        let (privateKey, publicKey): (Data, String)
        
        switch type {
        case .ed25519:
            (privateKey, publicKey) = try generateEd25519Key(name: name)
        case .rsa2048, .rsa4096:
            (privateKey, publicKey) = try generateRSAKey(name: name, bits: type.keySize)
        }
        
        // Save private key to Keychain
        try keychain.saveSSHKey(privateKey, name: name)
        
        // Save key metadata
        let keyPair = SSHKeyPair(
            id: UUID(),
            name: name,
            type: type,
            publicKey: publicKey,
            createdAt: Date(),
            isSecureEnclave: false
        )
        
        saveKeyMetadata(keyPair)
        loadKeys()
        
        logger.info("✅ Generated key: \(name)")
        return keyPair
    }
    
    /// Generate Ed25519 key pair using CryptoKit
    private func generateEd25519Key(name: String) throws -> (Data, String) {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKeyData = privateKey.publicKey.rawRepresentation
        
        // Format public key in OpenSSH format
        // ssh-ed25519 <base64-encoded-key> <comment>
        var keyBlob = Data()
        
        // Key type string
        let keyType = "ssh-ed25519"
        var typeLength = UInt32(keyType.count).bigEndian
        keyBlob.append(Data(bytes: &typeLength, count: 4))
        keyBlob.append(keyType.data(using: .utf8)!)
        
        // Public key data
        var keyLength = UInt32(publicKeyData.count).bigEndian
        keyBlob.append(Data(bytes: &keyLength, count: 4))
        keyBlob.append(publicKeyData)
        
        let publicKeyString = "ssh-ed25519 \(keyBlob.base64EncodedString()) \(name)@ghostty-ssh"
        
        // For the private key, we'll store it in OpenSSH format
        // This is a simplified version - full OpenSSH format is more complex
        let privateKeyData = privateKey.rawRepresentation
        
        return (privateKeyData, publicKeyString)
    }
    
    /// Generate RSA key pair using Security framework
    private func generateRSAKey(name: String, bits: Int) throws -> (Data, String) {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: bits,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: false
            ]
        ]
        
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw SSHKeyError.keyGenerationFailed
        }
        
        // Export private key
        var exportError: Unmanaged<CFError>?
        guard let privateKeyData = SecKeyCopyExternalRepresentation(privateKey, &exportError) as Data? else {
            throw exportError!.takeRetainedValue() as Error
        }
        
        // Export public key and format as OpenSSH
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &exportError) as Data? else {
            throw exportError!.takeRetainedValue() as Error
        }
        
        let publicKeyString = formatRSAPublicKey(publicKeyData, name: name)
        
        return (privateKeyData, publicKeyString)
    }
    
    /// Format RSA public key in OpenSSH format
    private func formatRSAPublicKey(_ data: Data, name: String) -> String {
        // RSA public key in OpenSSH format
        // This is simplified - real implementation needs proper ASN.1 parsing
        var keyBlob = Data()
        
        let keyType = "ssh-rsa"
        var typeLength = UInt32(keyType.count).bigEndian
        keyBlob.append(Data(bytes: &typeLength, count: 4))
        keyBlob.append(keyType.data(using: .utf8)!)
        
        // For now, just base64 encode the raw data
        // A proper implementation would parse the ASN.1 structure
        keyBlob.append(data)
        
        return "ssh-rsa \(keyBlob.base64EncodedString()) \(name)@ghostty-ssh"
    }
    
    // MARK: - Key Import
    
    /// Import a private key from PEM data
    func importKey(name: String, pemData: Data, passphrase: String? = nil) throws -> SSHKeyPair {
        logger.info("📥 Importing key: \(name)")
        
        guard let pemString = String(data: pemData, encoding: .utf8) else {
            throw SSHKeyError.invalidKeyFormat
        }
        
        // Detect key type from PEM header
        let type: SSHKeyType
        if pemString.contains("OPENSSH PRIVATE KEY") {
            // Could be Ed25519 or RSA in new OpenSSH format
            if pemString.contains("ssh-ed25519") {
                type = .ed25519
            } else {
                type = .rsa4096 // Assume RSA
            }
        } else if pemString.contains("RSA PRIVATE KEY") {
            type = .rsa4096
        } else {
            throw SSHKeyError.unsupportedKeyType
        }
        
        // Save to Keychain
        try keychain.saveSSHKey(pemData, name: name)
        
        // Extract public key (simplified - real implementation would parse the key)
        let publicKey = "Imported key - run `ssh-keygen -y -f` to extract public key"
        
        let keyPair = SSHKeyPair(
            id: UUID(),
            name: name,
            type: type,
            publicKey: publicKey,
            createdAt: Date(),
            isSecureEnclave: false
        )
        
        saveKeyMetadata(keyPair)
        loadKeys()
        
        logger.info("✅ Imported key: \(name)")
        return keyPair
    }
    
    // MARK: - Key Retrieval
    
    /// Get the private key data for use with SSH
    func getPrivateKey(name: String) throws -> Data {
        return try keychain.getSSHKey(name: name)
    }
    
    /// Get a temporary file path containing the private key (for libssh2)
    func getPrivateKeyPath(name: String) throws -> String {
        let keyData = try getPrivateKey(name: name)
        
        // Write to temporary file
        let tempDir = FileManager.default.temporaryDirectory
        let keyFile = tempDir.appendingPathComponent("ghostty_key_\(name)")
        
        try keyData.write(to: keyFile)
        
        // Set restrictive permissions
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: keyFile.path
        )
        
        return keyFile.path
    }
    
    /// Delete a key
    func deleteKey(name: String) throws {
        try keychain.deleteSSHKey(name: name)
        deleteKeyMetadata(name: name)
        loadKeys()
        logger.info("🗑️ Deleted key: \(name)")
    }
    
    // MARK: - Key Metadata Persistence
    
    private func loadKeys() {
        // Load from UserDefaults (metadata only, actual keys in Keychain)
        guard let data = UserDefaults.standard.data(forKey: "ssh_key_metadata"),
              let metadata = try? JSONDecoder().decode([SSHKeyMetadata].self, from: data) else {
            keys = []
            return
        }
        
        keys = metadata.map { meta in
            SSHKeyPair(
                id: meta.id,
                name: meta.name,
                type: SSHKeyType(rawValue: meta.type) ?? .ed25519,
                publicKey: meta.publicKey,
                createdAt: meta.createdAt,
                isSecureEnclave: meta.isSecureEnclave
            )
        }
    }
    
    private func saveKeyMetadata(_ keyPair: SSHKeyPair) {
        var metadata = loadKeyMetadata()
        
        // Remove existing with same name
        metadata.removeAll { $0.name == keyPair.name }
        
        metadata.append(SSHKeyMetadata(
            id: keyPair.id,
            name: keyPair.name,
            type: keyPair.type.rawValue,
            publicKey: keyPair.publicKey,
            createdAt: keyPair.createdAt,
            isSecureEnclave: keyPair.isSecureEnclave
        ))
        
        if let data = try? JSONEncoder().encode(metadata) {
            UserDefaults.standard.set(data, forKey: "ssh_key_metadata")
        }
    }
    
    private func deleteKeyMetadata(name: String) {
        var metadata = loadKeyMetadata()
        metadata.removeAll { $0.name == name }
        
        if let data = try? JSONEncoder().encode(metadata) {
            UserDefaults.standard.set(data, forKey: "ssh_key_metadata")
        }
    }
    
    private func loadKeyMetadata() -> [SSHKeyMetadata] {
        guard let data = UserDefaults.standard.data(forKey: "ssh_key_metadata"),
              let metadata = try? JSONDecoder().decode([SSHKeyMetadata].self, from: data) else {
            return []
        }
        return metadata
    }
}

// MARK: - Supporting Types

enum SSHKeyError: LocalizedError {
    case keyGenerationFailed
    case invalidKeyFormat
    case unsupportedKeyType
    case keyNotFound
    case passphraseRequired
    case notSupported
    
    var errorDescription: String? {
        switch self {
        case .keyGenerationFailed:
            return "Failed to generate SSH key"
        case .invalidKeyFormat:
            return "Invalid key format"
        case .unsupportedKeyType:
            return "Unsupported key type"
        case .keyNotFound:
            return "SSH key not found"
        case .passphraseRequired:
            return "Passphrase required for this key"
        case .notSupported:
            return "This feature is not yet supported"
        }
    }
}

/// Metadata for storing key info (actual key data is in Keychain)
private struct SSHKeyMetadata: Codable {
    let id: UUID
    let name: String
    let type: String
    let publicKey: String
    let createdAt: Date
    let isSecureEnclave: Bool
}
