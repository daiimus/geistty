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
@MainActor
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
            throw (error?.takeRetainedValue() as Error?) ?? SSHKeyError.keyGenerationFailed
        }
        
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw SSHKeyError.keyGenerationFailed
        }
        
        // Export private key
        var exportError: Unmanaged<CFError>?
        guard let privateKeyData = SecKeyCopyExternalRepresentation(privateKey, &exportError) as Data? else {
            throw (exportError?.takeRetainedValue() as Error?) ?? SSHKeyError.keyGenerationFailed
        }
        
        // Export public key and format as OpenSSH
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &exportError) as Data? else {
            throw (exportError?.takeRetainedValue() as Error?) ?? SSHKeyError.keyGenerationFailed
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
        logger.info("📥 Importing key: \(name), data size: \(pemData.count) bytes")
        
        guard let pemString = String(data: pemData, encoding: .utf8) else {
            logger.error("📥 Failed to decode key as UTF-8")
            throw SSHKeyError.invalidKeyFormat
        }
        
        logger.debug("📥 PEM preview: \(String(pemString.prefix(100)))...")
        
        // Detect key type from PEM header and content
        let type: SSHKeyType
        if pemString.contains("OPENSSH PRIVATE KEY") {
            logger.info("📥 Detected OpenSSH format, parsing binary...")
            // Parse OpenSSH format to detect actual key type
            if let detected = detectOpenSSHKeyType(pemString) {
                type = detected
                logger.info("📥 ✅ Detected key type: \(type.rawValue) (\(type.displayName))")
            } else {
                logger.error("📥 ❌ Failed to detect OpenSSH key type! Defaulting to ed25519")
                type = .ed25519
            }
        } else if pemString.contains("RSA PRIVATE KEY") {
            type = .rsa4096
            logger.info("📥 Detected RSA PEM format")
        } else if pemString.contains("EC PRIVATE KEY") {
            type = .ed25519 // Map ECDSA to ed25519 for display purposes
            logger.info("📥 Detected EC PEM format")
        } else {
            logger.error("📥 Unknown key format! Headers: \(pemString.prefix(200))")
            throw SSHKeyError.unsupportedKeyType
        }
        
        logger.info("📥 Final key type: \(type.rawValue)")
        
        // Save to Keychain
        try keychain.saveSSHKey(pemData, name: name)
        logger.info("📥 Saved to keychain")
        
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
    
    /// Detect key type from OpenSSH format by parsing the binary content
    private func detectOpenSSHKeyType(_ pemString: String) -> SSHKeyType? {
        logger.info("🔍 detectOpenSSHKeyType: Starting parse")
        
        // Extract base64 content
        let lines = pemString.components(separatedBy: .newlines)
        var base64Content = ""
        var inKey = false
        
        for line in lines {
            if line.contains("BEGIN OPENSSH PRIVATE KEY") {
                inKey = true
                continue
            }
            if line.contains("END OPENSSH PRIVATE KEY") {
                break
            }
            if inKey {
                base64Content += line.trimmingCharacters(in: .whitespaces)
            }
        }
        
        logger.info("🔍 Base64 content length: \(base64Content.count)")
        
        guard let keyData = Data(base64Encoded: base64Content),
              keyData.count > 50 else {
            logger.error("🔍 Failed to decode base64 or data too short")
            return nil
        }
        
        logger.info("🔍 Decoded \(keyData.count) bytes")
        logger.info("🔍 First 30 bytes: \(keyData.prefix(30).map { String(format: "%02x", $0) }.joined(separator: " "))")
        
        // OpenSSH format: magic + ciphername + kdfname + kdfoptions + numkeys + pubkey
        // The public key blob contains the key type as a string
        // Skip to public key section and read the key type
        
        let magic = "openssh-key-v1\0"
        let magicBytes = Array(magic.utf8)
        guard keyData.count > magicBytes.count else { return nil }
        
        var offset = magicBytes.count
        logger.debug("🔍 After magic, offset=\(offset)")
        
        // Helper to read uint32 big-endian
        func readUInt32() -> UInt32? {
            guard offset + 4 <= keyData.count else { return nil }
            let value = keyData.withUnsafeBytes { ptr in
                ptr.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian
            }
            offset += 4
            return value
        }
        
        // Helper to read string
        func readString() -> String? {
            guard let length = readUInt32(), length < 1000 else { return nil }
            guard offset + Int(length) <= keyData.count else { return nil }
            let data = keyData[offset..<(offset + Int(length))]
            offset += Int(length)
            return String(data: data, encoding: .utf8)
        }
        
        // Skip: ciphername, kdfname, kdfoptions
        let cipher = readString()
        let kdf = readString()
        logger.debug("🔍 cipher='\(cipher ?? "nil")', kdf='\(kdf ?? "nil")'")
        
        guard let kdfOptionsLen = readUInt32() else { return nil }
        offset += Int(kdfOptionsLen) // skip kdf options
        logger.debug("🔍 After kdf options, offset=\(offset)")
        
        // Number of keys
        guard let numKeys = readUInt32(), numKeys >= 1 else { return nil }
        logger.debug("🔍 numKeys=\(numKeys)")
        
        // Public key blob length
        guard let pubKeyLen = readUInt32(), pubKeyLen > 4 else { return nil }
        logger.debug("🔍 pubKeyLen=\(pubKeyLen), offset=\(offset)")
        
        // First field in public key blob is the key type
        guard let keyType = readString() else {
            logger.error("🔍 Failed to read key type string")
            return nil
        }
        
        logger.info("🔍 OpenSSH key type from binary: '\(keyType)'")
        
        switch keyType {
        case "ssh-ed25519":
            return .ed25519
        case "ssh-rsa":
            return .rsa4096
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            return .ed25519 // Map ECDSA to ed25519 for display (actual parsing handles it correctly)
        default:
            logger.warning("📥 Unknown key type: \(keyType)")
            return nil
        }
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
