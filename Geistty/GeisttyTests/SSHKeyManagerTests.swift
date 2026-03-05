import XCTest
import CryptoKit
@testable import Geistty

// MARK: - SSHKeyType Tests

final class SSHKeyTypeTests: XCTestCase {
    
    func testRawValues() {
        XCTAssertEqual(SSHKeyType.ed25519.rawValue, "ed25519")
        XCTAssertEqual(SSHKeyType.ecdsa.rawValue, "ecdsa")
        XCTAssertEqual(SSHKeyType.rsa2048.rawValue, "rsa-2048")
        XCTAssertEqual(SSHKeyType.rsa4096.rawValue, "rsa-4096")
    }
    
    func testDisplayNames() {
        XCTAssertEqual(SSHKeyType.ed25519.displayName, "Ed25519 (Recommended)")
        XCTAssertEqual(SSHKeyType.ecdsa.displayName, "ECDSA (P-256)")
        XCTAssertEqual(SSHKeyType.rsa2048.displayName, "RSA 2048-bit")
        XCTAssertEqual(SSHKeyType.rsa4096.displayName, "RSA 4096-bit")
    }
    
    func testKeySizes() {
        XCTAssertEqual(SSHKeyType.ed25519.keySize, 256)
        XCTAssertEqual(SSHKeyType.ecdsa.keySize, 256)
        XCTAssertEqual(SSHKeyType.rsa2048.keySize, 2048)
        XCTAssertEqual(SSHKeyType.rsa4096.keySize, 4096)
    }
    
    func testIdentifiable() {
        XCTAssertEqual(SSHKeyType.ed25519.id, "ed25519")
        XCTAssertEqual(SSHKeyType.rsa4096.id, "rsa-4096")
    }
    
    func testCaseIterable() {
        XCTAssertEqual(SSHKeyType.allCases.count, 4)
        XCTAssertTrue(SSHKeyType.allCases.contains(.ed25519))
        XCTAssertTrue(SSHKeyType.allCases.contains(.ecdsa))
        XCTAssertTrue(SSHKeyType.allCases.contains(.rsa2048))
        XCTAssertTrue(SSHKeyType.allCases.contains(.rsa4096))
    }
    
    func testInitFromRawValue() {
        XCTAssertEqual(SSHKeyType(rawValue: "ed25519"), .ed25519)
        XCTAssertEqual(SSHKeyType(rawValue: "ecdsa"), .ecdsa)
        XCTAssertEqual(SSHKeyType(rawValue: "rsa-2048"), .rsa2048)
        XCTAssertEqual(SSHKeyType(rawValue: "rsa-4096"), .rsa4096)
        XCTAssertNil(SSHKeyType(rawValue: "dsa"))
        XCTAssertNil(SSHKeyType(rawValue: ""))
    }
}

// MARK: - SSHKeyPair Tests

final class SSHKeyPairTests: XCTestCase {
    
    func testFingerprintFromValidPublicKey() {
        // Build a real Ed25519 public key string
        let key = Curve25519.Signing.PrivateKey()
        var pubBlob = Data()
        // "ssh-ed25519" as SSH string
        let keyType = "ssh-ed25519"
        var typeLen = UInt32(keyType.utf8.count).bigEndian
        pubBlob.append(Data(bytes: &typeLen, count: 4))
        pubBlob.append(contentsOf: keyType.utf8)
        // public key bytes as SSH string
        let pubBytes = key.publicKey.rawRepresentation
        var pubLen = UInt32(pubBytes.count).bigEndian
        pubBlob.append(Data(bytes: &pubLen, count: 4))
        pubBlob.append(pubBytes)
        
        let publicKeyString = "ssh-ed25519 \(pubBlob.base64EncodedString()) test@geistty"
        
        let keyPair = SSHKeyPair(
            id: UUID(),
            name: "test",
            type: .ed25519,
            publicKey: publicKeyString,
            createdAt: Date(),
            isSecureEnclave: false
        )
        
        // Fingerprint should start with SHA256:
        XCTAssertTrue(keyPair.fingerprint.hasPrefix("SHA256:"), "Fingerprint should start with SHA256:, got: \(keyPair.fingerprint)")
        // Should be deterministic
        XCTAssertEqual(keyPair.fingerprint, keyPair.fingerprint)
        // Should not be "unknown"
        XCTAssertNotEqual(keyPair.fingerprint, "unknown")
    }
    
    func testFingerprintFromInvalidPublicKey() {
        let keyPair = SSHKeyPair(
            id: UUID(),
            name: "bad",
            type: .ed25519,
            publicKey: "not-a-valid-key",
            createdAt: Date(),
            isSecureEnclave: false
        )
        
        XCTAssertEqual(keyPair.fingerprint, "unknown")
    }
    
    func testFingerprintFromEmptyPublicKey() {
        let keyPair = SSHKeyPair(
            id: UUID(),
            name: "empty",
            type: .ed25519,
            publicKey: "",
            createdAt: Date(),
            isSecureEnclave: false
        )
        
        XCTAssertEqual(keyPair.fingerprint, "unknown")
    }
    
    func testIdentifiable() {
        let id = UUID()
        let keyPair = SSHKeyPair(
            id: id,
            name: "test",
            type: .ed25519,
            publicKey: "ssh-ed25519 AAAA test",
            createdAt: Date(),
            isSecureEnclave: false
        )
        
        XCTAssertEqual(keyPair.id, id)
    }
}

// MARK: - SSHKeyError Tests

final class SSHKeyErrorTests: XCTestCase {
    
    func testAllErrorDescriptionsNonEmpty() {
        let errors: [SSHKeyError] = [
            .keyGenerationFailed,
            .invalidKeyFormat,
            .unsupportedKeyType,
            .keyNotFound,
            .passphraseRequired,
            .notSupported
        ]
        
        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error \(error) should have a description")
            XCTAssertFalse(error.errorDescription!.isEmpty, "Error description for \(error) should not be empty")
        }
    }
    
    func testSpecificErrorMessages() {
        XCTAssertEqual(SSHKeyError.keyGenerationFailed.errorDescription, "Failed to generate SSH key")
        XCTAssertEqual(SSHKeyError.invalidKeyFormat.errorDescription, "Invalid key format")
        XCTAssertEqual(SSHKeyError.unsupportedKeyType.errorDescription, "Unsupported key type")
        XCTAssertEqual(SSHKeyError.keyNotFound.errorDescription, "SSH key not found")
        XCTAssertEqual(SSHKeyError.passphraseRequired.errorDescription, "Passphrase required for this key")
        XCTAssertEqual(SSHKeyError.notSupported.errorDescription, "This feature is not yet supported")
    }
}

// MARK: - SSHKeyManager Tests

/// Tests for SSHKeyManager's key generation and management.
///
/// These tests use the real Keychain on the test device/simulator.
/// Each test cleans up by deleting any keys it created, using a unique
/// name prefix to avoid collisions with real keys.
@MainActor
final class SSHKeyManagerTests: XCTestCase {
    
    /// Prefix for test key names to avoid collisions with real keys
    private static let testPrefix = "__test_geistty_"
    
    /// Track names of keys created during tests for cleanup
    private var createdKeyNames: [String] = []
    
    override func setUp() {
        super.setUp()
        createdKeyNames = []
    }
    
    override func tearDown() {
        // Clean up all test keys from Keychain and UserDefaults
        let manager = SSHKeyManager.shared
        for name in createdKeyNames {
            try? manager.deleteKey(name: name)
        }
        
        // Also clean up UserDefaults metadata
        // loadKeyMetadata is private, but deleteKey handles both Keychain and metadata
        
        super.tearDown()
    }
    
    /// Generate a unique test key name
    private func testKeyName(_ suffix: String = UUID().uuidString.prefix(8).lowercased()) -> String {
        let name = "\(Self.testPrefix)\(suffix)"
        createdKeyNames.append(name)
        return name
    }
    
    // MARK: - Ed25519 Generation
    
    func testGenerateEd25519Key() throws {
        let name = testKeyName("ed25519_gen")
        let keyPair = try SSHKeyManager.shared.generateKey(name: name, type: .ed25519)
        
        XCTAssertEqual(keyPair.name, name)
        XCTAssertEqual(keyPair.type, .ed25519)
        XCTAssertFalse(keyPair.isSecureEnclave)
    }
    
    func testGenerateEd25519PublicKeyFormat() throws {
        let name = testKeyName("ed25519_pub")
        let keyPair = try SSHKeyManager.shared.generateKey(name: name, type: .ed25519)
        
        // Public key should be in authorized_keys format
        XCTAssertTrue(keyPair.publicKey.hasPrefix("ssh-ed25519 "),
                     "Public key should start with 'ssh-ed25519 ', got: \(keyPair.publicKey.prefix(30))")
        
        // Should have base64 section
        let parts = keyPair.publicKey.split(separator: " ")
        XCTAssertGreaterThanOrEqual(parts.count, 2, "Public key should have at least 2 space-separated parts")
        
        // Base64 should decode
        let base64 = String(parts[1])
        XCTAssertNotNil(Data(base64Encoded: base64), "Public key base64 section should be valid")
        
        // Should have comment
        XCTAssertGreaterThanOrEqual(parts.count, 3, "Public key should have a comment")
        XCTAssertTrue(keyPair.publicKey.contains("@ghostty-ssh"), "Comment should contain @ghostty-ssh")
    }
    
    func testGenerateEd25519RoundTrip() throws {
        // Generate a key with SSHKeyManager, retrieve PEM from Keychain,
        // then parse it with SSHKeyParser — validates the entire pipeline
        let name = testKeyName("ed25519_rt")
        let _ = try SSHKeyManager.shared.generateKey(name: name, type: .ed25519)
        
        // Retrieve the saved PEM from Keychain
        let pemData = try SSHKeyManager.shared.getPrivateKey(name: name)
        
        // PEM should be parseable by SSHKeyParser
        let parsedKey = try SSHKeyParser.parsePrivateKey(pemData)
        XCTAssertNotNil(parsedKey, "Generated Ed25519 PEM should be parseable by SSHKeyParser")
    }
    
    func testGenerateEd25519PEMFormat() throws {
        let name = testKeyName("ed25519_pem")
        let _ = try SSHKeyManager.shared.generateKey(name: name, type: .ed25519)
        
        let pemData = try SSHKeyManager.shared.getPrivateKey(name: name)
        let pemString = String(data: pemData, encoding: .utf8)
        
        XCTAssertNotNil(pemString, "PEM should be valid UTF-8")
        XCTAssertTrue(pemString!.contains("BEGIN OPENSSH PRIVATE KEY"),
                     "PEM should have OpenSSH header")
        XCTAssertTrue(pemString!.contains("END OPENSSH PRIVATE KEY"),
                     "PEM should have OpenSSH footer")
    }
    
    func testGenerateEd25519UniqueKeys() throws {
        // Two generated keys should be different
        let name1 = testKeyName("ed25519_u1")
        let name2 = testKeyName("ed25519_u2")
        
        let keyPair1 = try SSHKeyManager.shared.generateKey(name: name1, type: .ed25519)
        let keyPair2 = try SSHKeyManager.shared.generateKey(name: name2, type: .ed25519)
        
        XCTAssertNotEqual(keyPair1.publicKey, keyPair2.publicKey,
                         "Two generated keys should have different public keys")
    }
    
    func testGenerateEd25519FingerprintValid() throws {
        let name = testKeyName("ed25519_fp")
        let keyPair = try SSHKeyManager.shared.generateKey(name: name, type: .ed25519)
        
        XCTAssertTrue(keyPair.fingerprint.hasPrefix("SHA256:"),
                     "Fingerprint should start with SHA256:, got: \(keyPair.fingerprint)")
        XCTAssertNotEqual(keyPair.fingerprint, "unknown")
    }
    
    // MARK: - ECDSA Generation (Not Supported)
    
    func testGenerateECDSAThrowsNotSupported() {
        let name = testKeyName("ecdsa_ns")
        
        XCTAssertThrowsError(try SSHKeyManager.shared.generateKey(name: name, type: .ecdsa)) { error in
            guard case SSHKeyError.notSupported = error else {
                XCTFail("Expected .notSupported error, got \(error)")
                return
            }
        }
    }
    
    // MARK: - Key Retrieval and Deletion
    
    func testGetPrivateKeyAfterGeneration() throws {
        let name = testKeyName("ed25519_get")
        let _ = try SSHKeyManager.shared.generateKey(name: name, type: .ed25519)
        
        // Should be retrievable
        let data = try SSHKeyManager.shared.getPrivateKey(name: name)
        XCTAssertFalse(data.isEmpty, "Retrieved key data should not be empty")
    }
    
    func testDeleteKeyRemovesFromKeychain() throws {
        let name = testKeyName("ed25519_del")
        let _ = try SSHKeyManager.shared.generateKey(name: name, type: .ed25519)
        
        // Delete it
        try SSHKeyManager.shared.deleteKey(name: name)
        
        // Should no longer be retrievable
        XCTAssertThrowsError(try SSHKeyManager.shared.getPrivateKey(name: name)) { error in
            guard case KeychainError.itemNotFound = error else {
                XCTFail("Expected .itemNotFound after deletion, got \(error)")
                return
            }
        }
    }
    
    func testDeleteKeyUpdatesPublishedList() throws {
        let name = testKeyName("ed25519_list")
        let _ = try SSHKeyManager.shared.generateKey(name: name, type: .ed25519)
        
        // Key should appear in list
        XCTAssertTrue(SSHKeyManager.shared.keys.contains { $0.name == name },
                     "Generated key should appear in keys list")
        
        try SSHKeyManager.shared.deleteKey(name: name)
        
        // Key should NOT appear in list
        XCTAssertFalse(SSHKeyManager.shared.keys.contains { $0.name == name },
                      "Deleted key should not appear in keys list")
    }
    
    // MARK: - Key Name Overwrite
    
    func testGenerateKeyOverwritesSameName() throws {
        let name = testKeyName("ed25519_ow")
        
        let keyPair1 = try SSHKeyManager.shared.generateKey(name: name, type: .ed25519)
        let keyPair2 = try SSHKeyManager.shared.generateKey(name: name, type: .ed25519)
        
        // Second generation should overwrite the first
        XCTAssertNotEqual(keyPair1.publicKey, keyPair2.publicKey,
                         "Overwritten key should have new public key")
        
        // Only one key with this name should exist in the list
        let matchingKeys = SSHKeyManager.shared.keys.filter { $0.name == name }
        XCTAssertEqual(matchingKeys.count, 1,
                      "Should have exactly 1 key with name '\(name)', found \(matchingKeys.count)")
    }
}
