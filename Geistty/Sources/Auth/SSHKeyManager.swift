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
    case ecdsa = "ecdsa"
    case rsa2048 = "rsa-2048"
    case rsa4096 = "rsa-4096"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .ed25519: return "Ed25519 (Recommended)"
        case .ecdsa: return "ECDSA (P-256)"
        case .rsa2048: return "RSA 2048-bit"
        case .rsa4096: return "RSA 4096-bit"
        }
    }
    
    var keySize: Int {
        switch self {
        case .ed25519: return 256
        case .ecdsa: return 256
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
    func generateKey(name: String, type: SSHKeyType) throws -> SSHKeyPair {
        logger.info("🔑 Generating \(type.rawValue) key: \(name)")
        
        let (privateKey, publicKey): (Data, String)
        
        switch type {
        case .ed25519:
            (privateKey, publicKey) = try generateEd25519Key(name: name)
        case .ecdsa:
            throw SSHKeyError.notSupported
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
    
    /// Generate Ed25519 key pair using CryptoKit.
    /// Returns (privateKeyPEM, publicKeyString) where privateKeyPEM is in openssh-key-v1
    /// format that SSHKeyParser can parse, and publicKeyString is in authorized_keys format.
    private func generateEd25519Key(name: String) throws -> (Data, String) {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKeyData = privateKey.publicKey.rawRepresentation
        let privateKeyData = privateKey.rawRepresentation  // 32-byte seed
        
        // Format public key string in OpenSSH authorized_keys format:
        // ssh-ed25519 <base64(keyblob)> <comment>
        var pubBlob = Data()
        appendSSHString(&pubBlob, "ssh-ed25519")
        appendSSHBytes(&pubBlob, publicKeyData)
        let publicKeyString = "ssh-ed25519 \(pubBlob.base64EncodedString()) \(name)@ghostty-ssh"
        
        // Serialize private key in openssh-key-v1 PEM format so SSHKeyParser can parse it.
        // Format: https://github.com/openssh/openssh-portable/blob/master/PROTOCOL.key
        let pemData = serializeOpenSSHEd25519(seed: privateKeyData, publicKey: publicKeyData, comment: "\(name)@ghostty-ssh")
        
        return (pemData, publicKeyString)
    }
    
    /// Serialize an Ed25519 key pair in openssh-key-v1 format (unencrypted).
    /// This produces the same binary format as `ssh-keygen -t ed25519` with no passphrase.
    private func serializeOpenSSHEd25519(seed: Data, publicKey: Data, comment: String) -> Data {
        // Build the public key blob: string "ssh-ed25519" + string pubkey
        var pubBlob = Data()
        appendSSHString(&pubBlob, "ssh-ed25519")
        appendSSHBytes(&pubBlob, publicKey)
        
        // Build the private section (unencrypted):
        // uint32 checkint1 (random, must match checkint2)
        // uint32 checkint2
        // string keytype ("ssh-ed25519")
        // string pubkey (32 bytes)
        // string privkey (64 bytes: seed || pubkey, per OpenSSH convention)
        // string comment
        // padding (1, 2, 3, ... to align to block size 8)
        let checkInt = UInt32.random(in: 0...UInt32.max)
        var privSection = Data()
        appendUInt32(&privSection, checkInt)
        appendUInt32(&privSection, checkInt)
        appendSSHString(&privSection, "ssh-ed25519")
        appendSSHBytes(&privSection, publicKey)
        // OpenSSH stores the 64-byte "expanded" private key: 32-byte seed + 32-byte public key
        var fullPrivKey = Data(seed)
        fullPrivKey.append(publicKey)
        appendSSHBytes(&privSection, fullPrivKey)
        appendSSHString(&privSection, comment)
        
        // Padding to block size (8 for unencrypted)
        let blockSize = 8
        let paddingNeeded = blockSize - (privSection.count % blockSize)
        if paddingNeeded < blockSize {
            for i in 1...paddingNeeded {
                privSection.append(UInt8(i))
            }
        }
        
        // Build the full openssh-key-v1 binary:
        // AUTH_MAGIC: "openssh-key-v1\0"
        // string ciphername: "none"
        // string kdfname: "none"
        // string kdfoptions: "" (empty)
        // uint32 number-of-keys: 1
        // string public-key-blob
        // string private-key-blob (the privSection above)
        var keyData = Data()
        let magic = "openssh-key-v1\0"
        keyData.append(contentsOf: Array(magic.utf8))
        appendSSHString(&keyData, "none")       // ciphername
        appendSSHString(&keyData, "none")       // kdfname
        appendSSHString(&keyData, "")           // kdfoptions (empty string)
        appendUInt32(&keyData, 1)               // number of keys
        appendSSHBytes(&keyData, pubBlob)       // public key blob
        appendSSHBytes(&keyData, privSection)   // private key section
        
        // Wrap in PEM armor
        let base64 = keyData.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        let pem = "-----BEGIN OPENSSH PRIVATE KEY-----\n\(base64)\n-----END OPENSSH PRIVATE KEY-----\n"
        
        guard let pemData = pem.data(using: .utf8) else {
            // This should never happen — PEM contains only ASCII/base64 characters
            logger.error("Failed to encode PEM as UTF-8 — returning empty data")
            return Data()
        }
        return pemData
    }
    
    /// Append a uint32 in big-endian format.
    private func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var be = value.bigEndian
        data.append(Data(bytes: &be, count: 4))
    }
    
    /// Append SSH wire-format bytes (uint32 length + raw bytes).
    private func appendSSHBytes(_ data: inout Data, _ bytes: Data) {
        var length = UInt32(bytes.count).bigEndian
        data.append(Data(bytes: &length, count: 4))
        data.append(bytes)
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
    
    /// Format RSA public key in OpenSSH format.
    /// SecKeyCopyExternalRepresentation returns PKCS#1 DER: SEQUENCE { INTEGER n, INTEGER e }
    /// SSH wire format needs: string "ssh-rsa" + mpint e + mpint n
    private func formatRSAPublicKey(_ pkcs1Data: Data, name: String) -> String {
        // Parse PKCS#1 DER to extract n and e
        guard let (modulus, exponent) = parseRSAPublicKeyDER(pkcs1Data) else {
            logger.error("Failed to parse RSA public key DER, falling back to raw encoding")
            // Fallback: return a clearly-marked invalid key rather than a silently broken one
            return "# ERROR: Failed to parse RSA key for \(name)"
        }
        
        var keyBlob = Data()
        
        // Key type string: uint32 length + "ssh-rsa"
        let keyType = "ssh-rsa"
        appendSSHString(&keyBlob, keyType)
        
        // SSH wire format: mpint e, then mpint n (e before n!)
        appendSSHMPInt(&keyBlob, exponent)
        appendSSHMPInt(&keyBlob, modulus)
        
        return "ssh-rsa \(keyBlob.base64EncodedString()) \(name)@ghostty-ssh"
    }
    
    /// Parse PKCS#1 DER-encoded RSA public key to extract modulus (n) and exponent (e).
    /// PKCS#1 RSAPublicKey: SEQUENCE { INTEGER n, INTEGER e }
    private func parseRSAPublicKeyDER(_ data: Data) -> (modulus: Data, exponent: Data)? {
        var offset = 0
        let bytes = [UInt8](data)
        
        // SEQUENCE tag (0x30)
        guard offset < bytes.count, bytes[offset] == 0x30 else { return nil }
        offset += 1
        
        // Skip SEQUENCE length
        guard let _ = readDERLength(bytes, offset: &offset) else { return nil }
        
        // First INTEGER: modulus (n)
        guard offset < bytes.count, bytes[offset] == 0x02 else { return nil }
        offset += 1
        guard let modulusLength = readDERLength(bytes, offset: &offset) else { return nil }
        guard offset + modulusLength <= bytes.count else { return nil }
        var modulus = Data(bytes[offset..<offset + modulusLength])
        offset += modulusLength
        
        // Strip leading zero byte if present (DER uses it for positive sign)
        if modulus.first == 0x00 && modulus.count > 1 {
            modulus = modulus.dropFirst()
        }
        
        // Second INTEGER: exponent (e)
        guard offset < bytes.count, bytes[offset] == 0x02 else { return nil }
        offset += 1
        guard let exponentLength = readDERLength(bytes, offset: &offset) else { return nil }
        guard offset + exponentLength <= bytes.count else { return nil }
        var exponent = Data(bytes[offset..<offset + exponentLength])
        
        // Strip leading zero byte if present
        if exponent.first == 0x00 && exponent.count > 1 {
            exponent = exponent.dropFirst()
        }
        
        return (modulus, exponent)
    }
    
    /// Read a DER length field (handles short and long form).
    /// Advances offset past the length bytes. Returns the decoded length.
    private func readDERLength(_ bytes: [UInt8], offset: inout Int) -> Int? {
        guard offset < bytes.count else { return nil }
        let first = bytes[offset]
        offset += 1
        
        if first < 0x80 {
            // Short form: length is the byte itself
            return Int(first)
        }
        
        // Long form: first byte = 0x80 | numLengthBytes
        let numLengthBytes = Int(first & 0x7F)
        guard numLengthBytes > 0, numLengthBytes <= 4 else { return nil }
        guard offset + numLengthBytes <= bytes.count else { return nil }
        
        var length = 0
        for i in 0..<numLengthBytes {
            length = (length << 8) | Int(bytes[offset + i])
        }
        offset += numLengthBytes
        return length
    }
    
    /// Append an SSH wire-format string (uint32 length + bytes).
    private func appendSSHString(_ data: inout Data, _ string: String) {
        let bytes = Array(string.utf8)
        var length = UInt32(bytes.count).bigEndian
        data.append(Data(bytes: &length, count: 4))
        data.append(contentsOf: bytes)
    }
    
    /// Append an SSH wire-format mpint (uint32 length + big-endian bytes with leading
    /// zero if high bit is set, per RFC 4251 section 5).
    private func appendSSHMPInt(_ data: inout Data, _ value: Data) {
        var bytes = [UInt8](value)
        
        // Strip leading zeros (but keep at least one byte)
        while bytes.count > 1 && bytes.first == 0x00 {
            bytes.removeFirst()
        }
        
        // If high bit is set, prepend a zero byte (positive sign)
        let needsPadding = (bytes.first ?? 0) & 0x80 != 0
        let totalLength = bytes.count + (needsPadding ? 1 : 0)
        
        var length = UInt32(totalLength).bigEndian
        data.append(Data(bytes: &length, count: 4))
        if needsPadding {
            data.append(0x00)
        }
        data.append(contentsOf: bytes)
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
            type = .ecdsa
            logger.info("📥 Detected EC PEM format (ECDSA)")
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
            return .ecdsa
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
