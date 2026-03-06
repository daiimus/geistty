//
//  SSHKeyParser.swift
//  Geistty
//
//  SSH private key parsing utilities
//  Extracted from SSHSession for sharing with File Provider extension
//

import Foundation
import NIOSSH
import Crypto
@_spi(CryptoExtras) import _CryptoExtras
import os.log

private let logger = Logger(subsystem: "com.geistty", category: "SSHKeyParser")

/// SSH key parsing errors
enum SSHKeyParseError: LocalizedError {
    case invalidKey(String)
    case encryptedKeyNoPassphrase
    case unsupportedFormat(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidKey(let msg): return "Invalid SSH key: \(msg)"
        case .encryptedKeyNoPassphrase: return "Key is encrypted. Passphrase-protected keys are not yet supported. Use ssh-keygen -p to remove the passphrase, or generate an unencrypted key."
        case .unsupportedFormat(let format): return "Unsupported key format: \(format)"
        }
    }
}

/// Result of parsing a private key, carrying both the NIO key and the extracted public key string
struct SSHKeyParseResult {
    let privateKey: NIOSSHPrivateKey
    /// Public key in SSH authorized_keys format (e.g. "ssh-ed25519 AAAA... comment")
    let publicKeyString: String
    /// Detected key type for metadata
    let keyType: SSHKeyType
}

/// Utility for parsing SSH private keys
enum SSHKeyParser {
    
    /// Check whether a PEM string indicates an encrypted private key.
    /// Matches specific PEM header patterns rather than a blanket `contains("ENCRYPTED")`
    /// to avoid false positives from key data or comments that happen to contain that word.
    ///
    /// Recognized patterns:
    /// - `-----BEGIN ENCRYPTED PRIVATE KEY-----` (PKCS#8 encrypted)
    /// - `Proc-Type: 4,ENCRYPTED` (traditional PEM encrypted header)
    ///
    /// OpenSSH format (`-----BEGIN OPENSSH PRIVATE KEY-----`) stores encryption info
    /// in the binary payload (`cipherName != "none"`), not in the PEM header — those
    /// keys are detected during parsing, not here.
    private static func isPEMEncrypted(_ pemString: String) -> Bool {
        pemString.contains("BEGIN ENCRYPTED PRIVATE KEY") ||
        pemString.contains("Proc-Type: 4,ENCRYPTED")
    }
    
    /// Parse a private key from PEM data and extract public key + key type.
    /// This is the preferred entry point for key import — it returns everything
    /// needed to populate SSHKeyPair metadata without placeholder strings.
    static func parsePrivateKeyWithPublicKey(_ data: Data, comment: String, passphrase: String? = nil) throws -> SSHKeyParseResult {
        guard let pemString = String(data: data, encoding: .utf8) else {
            throw SSHKeyParseError.invalidKey("Unable to read key as UTF-8")
        }
        
        // Encrypted keys require passphrase handling
        if isPEMEncrypted(pemString) && passphrase == nil {
            throw SSHKeyParseError.encryptedKeyNoPassphrase
        }
        
        // Try OpenSSH format first (most common modern format from ssh-keygen)
        if pemString.contains("OPENSSH PRIVATE KEY") {
            return try parseOpenSSHPrivateKeyFull(pemString, comment: comment, passphrase: passphrase)
        }
        
        // Try RSA (common for cloud providers)
        if pemString.contains("RSA PRIVATE KEY") || pemString.contains("BEGIN PRIVATE KEY") {
            do {
                let rsaKey = try _RSA.Signing.PrivateKey(pemRepresentation: pemString)
                let nioKey = NIOSSHPrivateKey(rsaKey: rsaKey)
                
                // Determine key size from modulus bit count
                let keySizeBits = rsaKey.keySizeInBits
                let keyType: SSHKeyType = keySizeBits <= 2048 ? .rsa2048 : .rsa4096
                
                // Extract public key in SSH format
                let publicKeyString = formatRSAPublicKeyFromCrypto(rsaKey, comment: comment)
                
                return SSHKeyParseResult(privateKey: nioKey, publicKeyString: publicKeyString, keyType: keyType)
            } catch {
                if pemString.contains("BEGIN PRIVATE KEY") {
                    logger.debug("[KeyParse] PKCS#8 key is not RSA, trying ECDSA...")
                } else {
                    throw SSHKeyParseError.invalidKey("Failed to parse RSA key: \(error.localizedDescription)")
                }
            }
        }
        
        // Try ECDSA — matches both SEC1 ("EC PRIVATE KEY") and PKCS#8 ("BEGIN PRIVATE KEY")
        if pemString.contains("EC PRIVATE KEY") || pemString.contains("BEGIN PRIVATE KEY") {
            if let p256Key = try? P256.Signing.PrivateKey(pemRepresentation: pemString) {
                let nioKey = NIOSSHPrivateKey(p256Key: p256Key)
                let publicKeyString = formatP256PublicKeyStatic(p256Key.publicKey, comment: comment)
                return SSHKeyParseResult(privateKey: nioKey, publicKeyString: publicKeyString, keyType: .ecdsa)
            }
            if let p384Key = try? P384.Signing.PrivateKey(pemRepresentation: pemString) {
                let nioKey = NIOSSHPrivateKey(p384Key: p384Key)
                let publicKeyString = formatP384PublicKeyStatic(p384Key.publicKey, comment: comment)
                return SSHKeyParseResult(privateKey: nioKey, publicKeyString: publicKeyString, keyType: .ecdsa)
            }
            if let p521Key = try? P521.Signing.PrivateKey(pemRepresentation: pemString) {
                let nioKey = NIOSSHPrivateKey(p521Key: p521Key)
                let publicKeyString = formatP521PublicKeyStatic(p521Key.publicKey, comment: comment)
                return SSHKeyParseResult(privateKey: nioKey, publicKeyString: publicKeyString, keyType: .ecdsa)
            }
            throw SSHKeyParseError.unsupportedFormat("ECDSA key curve not supported")
        }
        
        throw SSHKeyParseError.unsupportedFormat("Supported formats: RSA, ECDSA, Ed25519 (OpenSSH)")
    }
    
    /// Parse a private key from PEM data
    static func parsePrivateKey(_ data: Data, passphrase: String? = nil) throws -> NIOSSHPrivateKey {
        logger.debug("[KeyParse] parsePrivateKey called with \(data.count) bytes")
        
        guard let pemString = String(data: data, encoding: .utf8) else {
            throw SSHKeyParseError.invalidKey("Unable to read key as UTF-8")
        }
        
        // Encrypted keys require passphrase handling
        if isPEMEncrypted(pemString) && passphrase == nil {
            throw SSHKeyParseError.encryptedKeyNoPassphrase
        }
        
        // Try OpenSSH format first (most common modern format from ssh-keygen)
        if pemString.contains("OPENSSH PRIVATE KEY") {
            logger.debug("[KeyParse] Detected OpenSSH format")
            return try parseOpenSSHPrivateKey(pemString, passphrase: passphrase)
        }
        
        // Try RSA (common for cloud providers)
        if pemString.contains("RSA PRIVATE KEY") || pemString.contains("BEGIN PRIVATE KEY") {
            do {
                let rsaKey = try _RSA.Signing.PrivateKey(pemRepresentation: pemString)
                logger.debug("[KeyParse] Parsed RSA key")
                return NIOSSHPrivateKey(rsaKey: rsaKey)
            } catch {
                // For generic PKCS#8 ("BEGIN PRIVATE KEY"), RSA parsing may fail because
                // the key is actually ECDSA. Fall through to try ECDSA below.
                if pemString.contains("BEGIN PRIVATE KEY") {
                    logger.debug("[KeyParse] PKCS#8 key is not RSA, trying ECDSA...")
                } else {
                    logger.debug("[KeyParse] WARNING: RSA key parsing failed: \(error.localizedDescription)")
                    throw SSHKeyParseError.invalidKey("Failed to parse RSA key: \(error.localizedDescription)")
                }
            }
        }
        
        // Try ECDSA — matches both SEC1 ("EC PRIVATE KEY") and PKCS#8 ("BEGIN PRIVATE KEY")
        if pemString.contains("EC PRIVATE KEY") || pemString.contains("BEGIN PRIVATE KEY") {
            // Try P-256 first (most common)
            if let p256Key = try? P256.Signing.PrivateKey(pemRepresentation: pemString) {
                logger.debug("[KeyParse] Parsed P-256 ECDSA key")
                return NIOSSHPrivateKey(p256Key: p256Key)
            }
            // Try P-384
            if let p384Key = try? P384.Signing.PrivateKey(pemRepresentation: pemString) {
                logger.debug("[KeyParse] Parsed P-384 ECDSA key")
                return NIOSSHPrivateKey(p384Key: p384Key)
            }
            // Try P-521
            if let p521Key = try? P521.Signing.PrivateKey(pemRepresentation: pemString) {
                logger.debug("[KeyParse] Parsed P-521 ECDSA key")
                return NIOSSHPrivateKey(p521Key: p521Key)
            }
            throw SSHKeyParseError.unsupportedFormat("ECDSA key curve not supported")
        }
        
        throw SSHKeyParseError.unsupportedFormat("Supported formats: RSA, ECDSA, Ed25519 (OpenSSH)")
    }
    
    /// Strip leading zero byte from SSH mpint format
    /// SSH mpint format adds a 0x00 prefix when the high bit is set to indicate positive number.
    /// swift-crypto expects raw unsigned integers without this padding.
    private static func stripMPIntPadding(_ data: Data) -> Data {
        guard data.count > 1, data[0] == 0 else { return data }
        return Data(data.dropFirst())
    }
    
    /// Parse OpenSSH private key format (openssh-key-v1)
    /// This is the default format generated by ssh-keygen since OpenSSH 6.5
    private static func parseOpenSSHPrivateKey(_ pemString: String, passphrase: String?) throws -> NIOSSHPrivateKey {
        logger.debug("[KeyParse] parseOpenSSHPrivateKey: Starting")
        
        // Extract base64 content between PEM headers
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
        
        guard let keyData = Data(base64Encoded: base64Content) else {
            throw SSHKeyParseError.invalidKey("Failed to decode base64 key data")
        }
        
        logger.debug("[KeyParse] Decoded \(keyData.count) bytes from base64")
        
        // OpenSSH key format:
        // "openssh-key-v1\0" (AUTH_MAGIC)
        // ciphername (string)
        // kdfname (string)
        // kdfoptions (string)
        // number of keys (uint32)
        // public key (string)
        // encrypted private key (string)
        
        let authMagic = "openssh-key-v1\0"
        guard let authMagicData = authMagic.data(using: .utf8),
              keyData.starts(with: authMagicData) else {
            throw SSHKeyParseError.invalidKey("Invalid OpenSSH key magic")
        }
        
        var offset = authMagic.count
        
        // Read ciphername
        let cipherName = try readString(from: keyData, at: &offset)
        logger.debug("[KeyParse] Cipher: \(cipherName)")
        
        // Read kdfname
        let kdfName = try readString(from: keyData, at: &offset)
        logger.debug("[KeyParse] KDF: \(kdfName)")
        
        // Read kdfoptions
        let _ = try readString(from: keyData, at: &offset) // kdfoptions
        
        // Read number of keys
        let numKeys = try readUInt32(from: keyData, at: &offset)
        guard numKeys == 1 else {
            throw SSHKeyParseError.invalidKey("Multiple keys not supported")
        }
        
        // Skip public key
        let _ = try readBytes(from: keyData, at: &offset)
        
        // Read private key section (this is binary, not a string!)
        var privateData = try readBytes(from: keyData, at: &offset)
        logger.debug("[KeyParse] Private data: \(privateData.count) bytes at offset \(offset)")
        
        // Handle encrypted keys
        if cipherName != "none" {
            guard let passphrase = passphrase else {
                throw SSHKeyParseError.encryptedKeyNoPassphrase
            }
            // Decrypt the private section
            privateData = try decryptPrivateData(privateData, cipher: cipherName, kdf: kdfName, passphrase: passphrase)
        }
        
        // Parse unencrypted private key data
        return try parsePrivateKeyData(privateData)
    }
    
    /// Read a uint32 in big-endian format
    private static func readUInt32(from data: Data, at offset: inout Int) throws -> UInt32 {
        guard offset + 4 <= data.count else {
            throw SSHKeyParseError.invalidKey("Unexpected end of key data")
        }
        let value = UInt32(data[offset]) << 24 |
                    UInt32(data[offset + 1]) << 16 |
                    UInt32(data[offset + 2]) << 8 |
                    UInt32(data[offset + 3])
        offset += 4
        return value
    }
    
    /// Read a length-prefixed string
    private static func readString(from data: Data, at offset: inout Int) throws -> String {
        let length = Int(try readUInt32(from: data, at: &offset))
        guard offset + length <= data.count else {
            throw SSHKeyParseError.invalidKey("String exceeds key data bounds")
        }
        let stringData = data.subdata(in: offset..<(offset + length))
        offset += length
        guard let str = String(data: stringData, encoding: .utf8) else {
            throw SSHKeyParseError.invalidKey("Invalid UTF-8 in string field")
        }
        return str
    }
    
    /// Read length-prefixed binary data
    private static func readBytes(from data: Data, at offset: inout Int) throws -> Data {
        let length = Int(try readUInt32(from: data, at: &offset))
        guard offset + length <= data.count else {
            throw SSHKeyParseError.invalidKey("Data exceeds key bounds")
        }
        let result = data.subdata(in: offset..<(offset + length))
        offset += length
        return result
    }
    
    /// Decrypt private key data (basic AES-256-CTR support)
    private static func decryptPrivateData(_ data: Data, cipher: String, kdf: String, passphrase: String) throws -> Data {
        // For now, only support common cipher
        guard cipher == "aes256-ctr" else {
            throw SSHKeyParseError.unsupportedFormat("Cipher \(cipher) not supported")
        }
        
        // This would require proper KDF derivation and AES decryption
        // For encrypted keys, users should use ssh-keygen to remove passphrase
        // or we implement full bcrypt KDF + AES-CTR
        throw SSHKeyParseError.invalidKey("Encrypted keys not yet supported - please use ssh-keygen -p to remove passphrase")
    }
    
    /// Parse the unencrypted private key data section
    private static func parsePrivateKeyData(_ data: Data) throws -> NIOSSHPrivateKey {
        var offset = 0
        
        // Check padding
        let check1 = try readUInt32(from: data, at: &offset)
        let check2 = try readUInt32(from: data, at: &offset)
        guard check1 == check2 else {
            throw SSHKeyParseError.invalidKey("Check bytes mismatch - wrong passphrase?")
        }
        
        // Read key type
        let keyType = try readString(from: data, at: &offset)
        logger.debug("[KeyParse] Key type: \(keyType)")
        
        switch keyType {
        case "ssh-ed25519":
            // Ed25519: public key (32 bytes) + private key (64 bytes, first 32 are seed)
            let pubKey = try readBytes(from: data, at: &offset)
            let privKey = try readBytes(from: data, at: &offset)
            
            guard pubKey.count == 32 else {
                throw SSHKeyParseError.invalidKey("Invalid Ed25519 public key length: \(pubKey.count)")
            }
            guard privKey.count == 64 else {
                throw SSHKeyParseError.invalidKey("Invalid Ed25519 private key length: \(privKey.count)")
            }
            
            // Ed25519 private key in OpenSSH format is seed (32) + public (32)
            // We need just the seed
            let seed = privKey.prefix(32)
            let ed25519Key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            logger.debug("[KeyParse] Parsed Ed25519 key")
            return NIOSSHPrivateKey(ed25519Key: ed25519Key)
            
        case "ecdsa-sha2-nistp256":
            let _ = try readString(from: data, at: &offset) // curve name
            let pubKey = try readBytes(from: data, at: &offset)
            let privKey = try readBytes(from: data, at: &offset)
            
            let strippedPriv = stripMPIntPadding(privKey)
            let p256Key = try P256.Signing.PrivateKey(rawRepresentation: strippedPriv)
            logger.debug("[KeyParse] Parsed P-256 ECDSA key, pub=\(pubKey.count) priv=\(privKey.count)")
            return NIOSSHPrivateKey(p256Key: p256Key)
            
        case "ecdsa-sha2-nistp384":
            let _ = try readString(from: data, at: &offset)
            let pubKey = try readBytes(from: data, at: &offset)
            let privKey = try readBytes(from: data, at: &offset)
            
            let strippedPriv = stripMPIntPadding(privKey)
            let p384Key = try P384.Signing.PrivateKey(rawRepresentation: strippedPriv)
            logger.debug("[KeyParse] Parsed P-384 ECDSA key, pub=\(pubKey.count) priv=\(privKey.count)")
            return NIOSSHPrivateKey(p384Key: p384Key)
            
        case "ecdsa-sha2-nistp521":
            let _ = try readString(from: data, at: &offset)
            let pubKey = try readBytes(from: data, at: &offset)
            let privKey = try readBytes(from: data, at: &offset)
            
            let strippedPriv = stripMPIntPadding(privKey)
            let p521Key = try P521.Signing.PrivateKey(rawRepresentation: strippedPriv)
            logger.debug("[KeyParse] Parsed P-521 ECDSA key, pub=\(pubKey.count) priv=\(privKey.count)")
            return NIOSSHPrivateKey(p521Key: p521Key)
            
        case "ssh-rsa":
            // RSA: n, e, d, iqmp, p, q
            let n = try readBytes(from: data, at: &offset)
            let e = try readBytes(from: data, at: &offset)
            let d = try readBytes(from: data, at: &offset)
            let _ = try readBytes(from: data, at: &offset) // iqmp
            let p = try readBytes(from: data, at: &offset)
            let q = try readBytes(from: data, at: &offset)
            
            // Use raw components to create RSA key
            let rsaKey = try _RSA.Signing.PrivateKey(
                n: stripMPIntPadding(n),
                e: stripMPIntPadding(e),
                d: stripMPIntPadding(d),
                p: stripMPIntPadding(p),
                q: stripMPIntPadding(q)
            )
            logger.debug("[KeyParse] Parsed RSA key")
            return NIOSSHPrivateKey(rsaKey: rsaKey)
            
        default:
            throw SSHKeyParseError.unsupportedFormat("Key type \(keyType)")
        }
    }
    
    // MARK: - Full Parse (with public key extraction)
    
    /// Parse OpenSSH private key and extract public key string + key type for import metadata.
    private static func parseOpenSSHPrivateKeyFull(_ pemString: String, comment: String, passphrase: String?) throws -> SSHKeyParseResult {
        logger.debug("[KeyParse] parseOpenSSHPrivateKeyFull: Starting")
        
        // Extract base64 content between PEM headers
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
        
        guard let keyData = Data(base64Encoded: base64Content) else {
            throw SSHKeyParseError.invalidKey("Failed to decode base64 key data")
        }
        
        let authMagic = "openssh-key-v1\0"
        guard let authMagicData = authMagic.data(using: .utf8),
              keyData.starts(with: authMagicData) else {
            throw SSHKeyParseError.invalidKey("Invalid OpenSSH key magic")
        }
        
        var offset = authMagic.count
        
        let cipherName = try readString(from: keyData, at: &offset)
        let _ = try readString(from: keyData, at: &offset) // kdfname
        let _ = try readString(from: keyData, at: &offset) // kdfoptions
        
        let numKeys = try readUInt32(from: keyData, at: &offset)
        guard numKeys == 1 else {
            throw SSHKeyParseError.invalidKey("Multiple keys not supported")
        }
        
        // Skip public key blob
        let _ = try readBytes(from: keyData, at: &offset)
        
        // Read private key section
        var privateData = try readBytes(from: keyData, at: &offset)
        
        if cipherName != "none" {
            guard let passphrase = passphrase else {
                throw SSHKeyParseError.encryptedKeyNoPassphrase
            }
            privateData = try decryptPrivateData(privateData, cipher: cipherName, kdf: "bcrypt", passphrase: passphrase)
        }
        
        return try parsePrivateKeyDataFull(privateData, comment: comment)
    }
    
    /// Parse unencrypted private key data section and extract public key + key type.
    private static func parsePrivateKeyDataFull(_ data: Data, comment: String) throws -> SSHKeyParseResult {
        var offset = 0
        
        let check1 = try readUInt32(from: data, at: &offset)
        let check2 = try readUInt32(from: data, at: &offset)
        guard check1 == check2 else {
            throw SSHKeyParseError.invalidKey("Check bytes mismatch - wrong passphrase?")
        }
        
        let keyType = try readString(from: data, at: &offset)
        logger.debug("[KeyParse] Key type (full parse): \(keyType)")
        
        switch keyType {
        case "ssh-ed25519":
            let pubKey = try readBytes(from: data, at: &offset)
            let privKey = try readBytes(from: data, at: &offset)
            
            guard pubKey.count == 32 else {
                throw SSHKeyParseError.invalidKey("Invalid Ed25519 public key length: \(pubKey.count)")
            }
            guard privKey.count == 64 else {
                throw SSHKeyParseError.invalidKey("Invalid Ed25519 private key length: \(privKey.count)")
            }
            
            let seed = privKey.prefix(32)
            let ed25519Key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            let nioKey = NIOSSHPrivateKey(ed25519Key: ed25519Key)
            
            // Format public key: ssh-ed25519 <base64(keyblob)> comment
            var pubBlob = Data()
            appendSSHString(&pubBlob, "ssh-ed25519")
            appendSSHBytes(&pubBlob, pubKey)
            let publicKeyString = "ssh-ed25519 \(pubBlob.base64EncodedString()) \(comment)"
            
            return SSHKeyParseResult(privateKey: nioKey, publicKeyString: publicKeyString, keyType: .ed25519)
            
        case "ecdsa-sha2-nistp256":
            let curveName = try readString(from: data, at: &offset)
            let pubKey = try readBytes(from: data, at: &offset)
            let privKey = try readBytes(from: data, at: &offset)
            
            let strippedPriv = stripMPIntPadding(privKey)
            let p256Key = try P256.Signing.PrivateKey(rawRepresentation: strippedPriv)
            let nioKey = NIOSSHPrivateKey(p256Key: p256Key)
            
            var pubBlob = Data()
            appendSSHString(&pubBlob, "ecdsa-sha2-nistp256")
            appendSSHString(&pubBlob, curveName)
            appendSSHBytes(&pubBlob, pubKey)
            let publicKeyString = "ecdsa-sha2-nistp256 \(pubBlob.base64EncodedString()) \(comment)"
            
            return SSHKeyParseResult(privateKey: nioKey, publicKeyString: publicKeyString, keyType: .ecdsa)
            
        case "ecdsa-sha2-nistp384":
            let curveName = try readString(from: data, at: &offset)
            let pubKey = try readBytes(from: data, at: &offset)
            let privKey = try readBytes(from: data, at: &offset)
            
            let strippedPriv = stripMPIntPadding(privKey)
            let p384Key = try P384.Signing.PrivateKey(rawRepresentation: strippedPriv)
            let nioKey = NIOSSHPrivateKey(p384Key: p384Key)
            
            var pubBlob = Data()
            appendSSHString(&pubBlob, "ecdsa-sha2-nistp384")
            appendSSHString(&pubBlob, curveName)
            appendSSHBytes(&pubBlob, pubKey)
            let publicKeyString = "ecdsa-sha2-nistp384 \(pubBlob.base64EncodedString()) \(comment)"
            
            return SSHKeyParseResult(privateKey: nioKey, publicKeyString: publicKeyString, keyType: .ecdsa)
            
        case "ecdsa-sha2-nistp521":
            let curveName = try readString(from: data, at: &offset)
            let pubKey = try readBytes(from: data, at: &offset)
            let privKey = try readBytes(from: data, at: &offset)
            
            let strippedPriv = stripMPIntPadding(privKey)
            let p521Key = try P521.Signing.PrivateKey(rawRepresentation: strippedPriv)
            let nioKey = NIOSSHPrivateKey(p521Key: p521Key)
            
            var pubBlob = Data()
            appendSSHString(&pubBlob, "ecdsa-sha2-nistp521")
            appendSSHString(&pubBlob, curveName)
            appendSSHBytes(&pubBlob, pubKey)
            let publicKeyString = "ecdsa-sha2-nistp521 \(pubBlob.base64EncodedString()) \(comment)"
            
            return SSHKeyParseResult(privateKey: nioKey, publicKeyString: publicKeyString, keyType: .ecdsa)
            
        case "ssh-rsa":
            let n = try readBytes(from: data, at: &offset)
            let e = try readBytes(from: data, at: &offset)
            let d = try readBytes(from: data, at: &offset)
            let _ = try readBytes(from: data, at: &offset) // iqmp
            let p = try readBytes(from: data, at: &offset)
            let q = try readBytes(from: data, at: &offset)
            
            let rsaKey = try _RSA.Signing.PrivateKey(
                n: stripMPIntPadding(n),
                e: stripMPIntPadding(e),
                d: stripMPIntPadding(d),
                p: stripMPIntPadding(p),
                q: stripMPIntPadding(q)
            )
            let nioKey = NIOSSHPrivateKey(rsaKey: rsaKey)
            
            // Determine RSA key size from modulus
            let modulusBytes = stripMPIntPadding(n)
            let keySizeBits = modulusBytes.count * 8
            let sshKeyType: SSHKeyType = keySizeBits <= 2048 ? .rsa2048 : .rsa4096
            
            // Format public key: ssh-rsa <base64(keyblob)> comment
            // SSH wire format: string "ssh-rsa" + mpint e + mpint n
            var pubBlob = Data()
            appendSSHString(&pubBlob, "ssh-rsa")
            appendSSHMPInt(&pubBlob, stripMPIntPadding(e))
            appendSSHMPInt(&pubBlob, modulusBytes)
            let publicKeyString = "ssh-rsa \(pubBlob.base64EncodedString()) \(comment)"
            
            return SSHKeyParseResult(privateKey: nioKey, publicKeyString: publicKeyString, keyType: sshKeyType)
            
        default:
            throw SSHKeyParseError.unsupportedFormat("Key type \(keyType)")
        }
    }
    
    // MARK: - Static Public Key Formatting
    
    /// Format RSA public key in SSH authorized_keys format from a _CryptoExtras RSA key.
    private static func formatRSAPublicKeyFromCrypto(_ rsaKey: _RSA.Signing.PrivateKey, comment: String) -> String {
        // Get the PKCS#1 DER representation of the public key
        let publicKeyDER = rsaKey.publicKey.pkcs1DERRepresentation
        
        // Parse the DER to extract n and e
        guard let (modulus, exponent) = parseRSAPublicKeyDERStatic(publicKeyDER) else {
            logger.error("[KeyParse] Failed to parse RSA public key DER for import")
            return "# ERROR: Failed to extract RSA public key"
        }
        
        var keyBlob = Data()
        appendSSHString(&keyBlob, "ssh-rsa")
        appendSSHMPInt(&keyBlob, exponent)
        appendSSHMPInt(&keyBlob, modulus)
        
        return "ssh-rsa \(keyBlob.base64EncodedString()) \(comment)"
    }
    
    /// Format a P-256 public key in SSH authorized_keys format (static version for parser use).
    private static func formatP256PublicKeyStatic(_ publicKey: P256.Signing.PublicKey, comment: String) -> String {
        let pointData = publicKey.x963Representation
        var keyBlob = Data()
        appendSSHString(&keyBlob, "ecdsa-sha2-nistp256")
        appendSSHString(&keyBlob, "nistp256")
        appendSSHBytes(&keyBlob, pointData)
        return "ecdsa-sha2-nistp256 \(keyBlob.base64EncodedString()) \(comment)"
    }
    
    /// Format a P-384 public key in SSH authorized_keys format.
    private static func formatP384PublicKeyStatic(_ publicKey: P384.Signing.PublicKey, comment: String) -> String {
        let pointData = publicKey.x963Representation
        var keyBlob = Data()
        appendSSHString(&keyBlob, "ecdsa-sha2-nistp384")
        appendSSHString(&keyBlob, "nistp384")
        appendSSHBytes(&keyBlob, pointData)
        return "ecdsa-sha2-nistp384 \(keyBlob.base64EncodedString()) \(comment)"
    }
    
    /// Format a P-521 public key in SSH authorized_keys format.
    private static func formatP521PublicKeyStatic(_ publicKey: P521.Signing.PublicKey, comment: String) -> String {
        let pointData = publicKey.x963Representation
        var keyBlob = Data()
        appendSSHString(&keyBlob, "ecdsa-sha2-nistp521")
        appendSSHString(&keyBlob, "nistp521")
        appendSSHBytes(&keyBlob, pointData)
        return "ecdsa-sha2-nistp521 \(keyBlob.base64EncodedString()) \(comment)"
    }
    
    // MARK: - Static SSH Wire Format Helpers
    
    /// Append SSH wire-format string (uint32 length + bytes) — static version for parser use.
    private static func appendSSHString(_ data: inout Data, _ string: String) {
        let bytes = Array(string.utf8)
        var length = UInt32(bytes.count).bigEndian
        data.append(Data(bytes: &length, count: 4))
        data.append(contentsOf: bytes)
    }
    
    /// Append SSH wire-format bytes (uint32 length + raw bytes) — static version for parser use.
    private static func appendSSHBytes(_ data: inout Data, _ bytes: Data) {
        var length = UInt32(bytes.count).bigEndian
        data.append(Data(bytes: &length, count: 4))
        data.append(bytes)
    }
    
    /// Append SSH wire-format mpint (uint32 length + big-endian bytes with sign padding).
    private static func appendSSHMPInt(_ data: inout Data, _ value: Data) {
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
    
    /// Parse PKCS#1 DER-encoded RSA public key — static version for parser use.
    private static func parseRSAPublicKeyDERStatic(_ data: Data) -> (modulus: Data, exponent: Data)? {
        var offset = 0
        let bytes = [UInt8](data)
        
        // SEQUENCE tag (0x30)
        guard offset < bytes.count, bytes[offset] == 0x30 else { return nil }
        offset += 1
        guard let _ = readDERLengthStatic(bytes, offset: &offset) else { return nil }
        
        // First INTEGER: modulus (n)
        guard offset < bytes.count, bytes[offset] == 0x02 else { return nil }
        offset += 1
        guard let modulusLength = readDERLengthStatic(bytes, offset: &offset) else { return nil }
        guard offset + modulusLength <= bytes.count else { return nil }
        var modulus = Data(bytes[offset..<offset + modulusLength])
        offset += modulusLength
        if modulus.first == 0x00 && modulus.count > 1 { modulus = modulus.dropFirst() }
        
        // Second INTEGER: exponent (e)
        guard offset < bytes.count, bytes[offset] == 0x02 else { return nil }
        offset += 1
        guard let exponentLength = readDERLengthStatic(bytes, offset: &offset) else { return nil }
        guard offset + exponentLength <= bytes.count else { return nil }
        var exponent = Data(bytes[offset..<offset + exponentLength])
        if exponent.first == 0x00 && exponent.count > 1 { exponent = exponent.dropFirst() }
        
        return (modulus, exponent)
    }
    
    /// Read a DER length field — static version for parser use.
    private static func readDERLengthStatic(_ bytes: [UInt8], offset: inout Int) -> Int? {
        guard offset < bytes.count else { return nil }
        let first = bytes[offset]
        offset += 1
        
        if first < 0x80 { return Int(first) }
        
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
}
