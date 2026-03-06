import XCTest
import CryptoKit
@testable import Geistty

// MARK: - SSHKeyType Tests

final class SSHKeyTypeTests: XCTestCase {
    
    func testRawValues() {
        XCTAssertEqual(SSHKeyType.ed25519.rawValue, "ed25519")
        XCTAssertEqual(SSHKeyType.ecdsa.rawValue, "ecdsa")
        XCTAssertEqual(SSHKeyType.secureEnclaveP256.rawValue, "secure-enclave-p256")
        XCTAssertEqual(SSHKeyType.rsa2048.rawValue, "rsa-2048")
        XCTAssertEqual(SSHKeyType.rsa4096.rawValue, "rsa-4096")
    }
    
    func testDisplayNames() {
        XCTAssertEqual(SSHKeyType.ed25519.displayName, "Ed25519 (Recommended)")
        XCTAssertEqual(SSHKeyType.ecdsa.displayName, "ECDSA (P-256)")
        XCTAssertEqual(SSHKeyType.secureEnclaveP256.displayName, "Secure Enclave (P-256)")
        XCTAssertEqual(SSHKeyType.rsa2048.displayName, "RSA 2048-bit")
        XCTAssertEqual(SSHKeyType.rsa4096.displayName, "RSA 4096-bit")
    }
    
    func testKeySizes() {
        XCTAssertEqual(SSHKeyType.ed25519.keySize, 256)
        XCTAssertEqual(SSHKeyType.ecdsa.keySize, 256)
        XCTAssertEqual(SSHKeyType.secureEnclaveP256.keySize, 256)
        XCTAssertEqual(SSHKeyType.rsa2048.keySize, 2048)
        XCTAssertEqual(SSHKeyType.rsa4096.keySize, 4096)
    }
    
    func testIdentifiable() {
        XCTAssertEqual(SSHKeyType.ed25519.id, "ed25519")
        XCTAssertEqual(SSHKeyType.secureEnclaveP256.id, "secure-enclave-p256")
        XCTAssertEqual(SSHKeyType.rsa4096.id, "rsa-4096")
    }
    
    func testIsSecureEnclave() {
        XCTAssertFalse(SSHKeyType.ed25519.isSecureEnclave)
        XCTAssertFalse(SSHKeyType.ecdsa.isSecureEnclave)
        XCTAssertTrue(SSHKeyType.secureEnclaveP256.isSecureEnclave)
        XCTAssertFalse(SSHKeyType.rsa2048.isSecureEnclave)
        XCTAssertFalse(SSHKeyType.rsa4096.isSecureEnclave)
    }
    
    func testCaseIterable() {
        XCTAssertEqual(SSHKeyType.allCases.count, 5)
        XCTAssertTrue(SSHKeyType.allCases.contains(.ed25519))
        XCTAssertTrue(SSHKeyType.allCases.contains(.ecdsa))
        XCTAssertTrue(SSHKeyType.allCases.contains(.secureEnclaveP256))
        XCTAssertTrue(SSHKeyType.allCases.contains(.rsa2048))
        XCTAssertTrue(SSHKeyType.allCases.contains(.rsa4096))
    }
    
    func testInitFromRawValue() {
        XCTAssertEqual(SSHKeyType(rawValue: "ed25519"), .ed25519)
        XCTAssertEqual(SSHKeyType(rawValue: "ecdsa"), .ecdsa)
        XCTAssertEqual(SSHKeyType(rawValue: "secure-enclave-p256"), .secureEnclaveP256)
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
            isSecureEnclave: false,
            requiresBiometric: false
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
            isSecureEnclave: false,
            requiresBiometric: false
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
            isSecureEnclave: false,
            requiresBiometric: false
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
            isSecureEnclave: false,
            requiresBiometric: false
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
            .notSupported,
            .secureEnclaveNotAvailable,
            .biometricAuthRequired
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
        XCTAssertEqual(SSHKeyError.secureEnclaveNotAvailable.errorDescription,
                       "Secure Enclave is not available on this device")
        XCTAssertEqual(SSHKeyError.biometricAuthRequired.errorDescription,
                       "Biometric authentication is required to use this key")
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
    
    // MARK: - ECDSA Generation
    
    func testGenerateECDSAKey() throws {
        let name = testKeyName("ecdsa_gen")
        let keyPair = try SSHKeyManager.shared.generateKey(name: name, type: .ecdsa)
        
        XCTAssertEqual(keyPair.name, name)
        XCTAssertEqual(keyPair.type, .ecdsa)
        XCTAssertFalse(keyPair.isSecureEnclave)
    }
    
    func testGenerateECDSAPublicKeyFormat() throws {
        let name = testKeyName("ecdsa_pub")
        let keyPair = try SSHKeyManager.shared.generateKey(name: name, type: .ecdsa)
        
        // Public key should be in authorized_keys format
        XCTAssertTrue(keyPair.publicKey.hasPrefix("ecdsa-sha2-nistp256 "),
                     "ECDSA public key should start with 'ecdsa-sha2-nistp256 ', got: \(keyPair.publicKey.prefix(40))")
        
        // Should have base64 section
        let parts = keyPair.publicKey.split(separator: " ")
        XCTAssertGreaterThanOrEqual(parts.count, 2, "Public key should have at least 2 space-separated parts")
        
        // Base64 should decode
        let base64 = String(parts[1])
        XCTAssertNotNil(Data(base64Encoded: base64), "Public key base64 section should be valid")
    }
    
    func testGenerateECDSARoundTrip() throws {
        // Generate an ECDSA key with SSHKeyManager, retrieve PEM from Keychain,
        // then parse it with SSHKeyParser — validates the entire pipeline
        let name = testKeyName("ecdsa_rt")
        let _ = try SSHKeyManager.shared.generateKey(name: name, type: .ecdsa)
        
        // Retrieve the saved PEM from Keychain
        let pemData = try SSHKeyManager.shared.getPrivateKey(name: name)
        
        // PEM should be parseable by SSHKeyParser
        let parsedKey = try SSHKeyParser.parsePrivateKey(pemData)
        XCTAssertNotNil(parsedKey, "Generated ECDSA PEM should be parseable by SSHKeyParser")
    }
    
    func testGenerateECDSAUniqueKeys() throws {
        // Two generated ECDSA keys should be different
        let name1 = testKeyName("ecdsa_u1")
        let name2 = testKeyName("ecdsa_u2")
        
        let keyPair1 = try SSHKeyManager.shared.generateKey(name: name1, type: .ecdsa)
        let keyPair2 = try SSHKeyManager.shared.generateKey(name: name2, type: .ecdsa)
        
        XCTAssertNotEqual(keyPair1.publicKey, keyPair2.publicKey,
                         "Two generated ECDSA keys should have different public keys")
    }
    
    func testGenerateECDSAFingerprintValid() throws {
        let name = testKeyName("ecdsa_fp")
        let keyPair = try SSHKeyManager.shared.generateKey(name: name, type: .ecdsa)
        
        XCTAssertTrue(keyPair.fingerprint.hasPrefix("SHA256:"),
                     "Fingerprint should start with SHA256:, got: \(keyPair.fingerprint)")
        XCTAssertNotEqual(keyPair.fingerprint, "unknown")
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

// MARK: - BiometricGatekeeper Tests

/// Tests for BiometricGatekeeper session state management.
///
/// These test the state machine logic (session invalidation, initial state).
/// Actual biometric prompts can't be tested in CI — those are integration tests.
@MainActor
final class BiometricGatekeeperTests: XCTestCase {
    
    func testInitialStateNotAuthenticated() {
        let gatekeeper = BiometricGatekeeper.shared
        // Fresh or invalidated — should not be authenticated
        // (In CI, no prior auth would have happened)
        gatekeeper.invalidateSession()
        XCTAssertFalse(gatekeeper.isAuthenticated,
                      "Gatekeeper should not be authenticated after invalidation")
    }
    
    func testInvalidateSessionClearsAuth() {
        let gatekeeper = BiometricGatekeeper.shared
        // Invalidate should set isAuthenticated to false
        gatekeeper.invalidateSession()
        XCTAssertFalse(gatekeeper.isAuthenticated)
        // Calling invalidate again should be a no-op (not crash)
        gatekeeper.invalidateSession()
        XCTAssertFalse(gatekeeper.isAuthenticated)
    }
    
    func testBiometricTypeNameReturnsString() {
        let gatekeeper = BiometricGatekeeper.shared
        let name = gatekeeper.biometricTypeName
        // On simulator, biometrics are not available, so should return "Biometrics"
        XCTAssertFalse(name.isEmpty, "biometricTypeName should not be empty")
    }
    
    func testEnsureAuthenticatedThrowsOnSimulator() async {
        // On simulator, biometrics are not available
        // ensureAuthenticated should throw secureEnclaveNotAvailable
        let gatekeeper = BiometricGatekeeper.shared
        gatekeeper.invalidateSession()
        
        do {
            try await gatekeeper.ensureAuthenticated()
            // If biometrics ARE available (device), this might succeed — that's OK
        } catch {
            // On simulator, should get secureEnclaveNotAvailable
            // (the method throws this when canEvaluatePolicy fails)
            guard case SSHKeyError.secureEnclaveNotAvailable = error else {
                // biometricAuthRequired is also acceptable (e.g. if LAContext fails differently)
                guard case SSHKeyError.biometricAuthRequired = error else {
                    XCTFail("Expected secureEnclaveNotAvailable or biometricAuthRequired, got \(error)")
                    return
                }
                return
            }
        }
    }
}

// MARK: - SSHKeyPair Biometric Tests

final class SSHKeyPairBiometricTests: XCTestCase {
    
    func testRequiresBiometricDefaultFalse() {
        let keyPair = SSHKeyPair(
            id: UUID(),
            name: "test",
            type: .ed25519,
            publicKey: "ssh-ed25519 AAAA test",
            createdAt: Date(),
            isSecureEnclave: false,
            requiresBiometric: false
        )
        XCTAssertFalse(keyPair.requiresBiometric)
    }
    
    func testRequiresBiometricTrue() {
        let keyPair = SSHKeyPair(
            id: UUID(),
            name: "bio-key",
            type: .ed25519,
            publicKey: "ssh-ed25519 AAAA test",
            createdAt: Date(),
            isSecureEnclave: false,
            requiresBiometric: true
        )
        XCTAssertTrue(keyPair.requiresBiometric)
    }
    
    func testSecureEnclaveKeyPair() {
        let keyPair = SSHKeyPair(
            id: UUID(),
            name: "se-key",
            type: .secureEnclaveP256,
            publicKey: "ecdsa-sha2-nistp256 AAAA test",
            createdAt: Date(),
            isSecureEnclave: true,
            requiresBiometric: false
        )
        XCTAssertTrue(keyPair.isSecureEnclave)
        XCTAssertEqual(keyPair.type, .secureEnclaveP256)
    }
}

// MARK: - SSHCommandResult Tests

final class SSHCommandResultTests: XCTestCase {
    
    func testSucceededWithExitZero() {
        let result = SSHCommandResult(exitStatus: 0, stdout: "ok", stderr: "")
        XCTAssertTrue(result.succeeded)
    }
    
    func testNotSucceededWithNonZeroExit() {
        let result = SSHCommandResult(exitStatus: 1, stdout: "", stderr: "error")
        XCTAssertFalse(result.succeeded)
    }
    
    func testNotSucceededWithNilExit() {
        // No exit status (e.g. channel closed without exit)
        let result = SSHCommandResult(exitStatus: nil, stdout: "", stderr: "")
        XCTAssertFalse(result.succeeded)
    }
    
    func testStdoutAndStderrCaptured() {
        let result = SSHCommandResult(exitStatus: 0, stdout: "hello world", stderr: "warning: something")
        XCTAssertEqual(result.stdout, "hello world")
        XCTAssertEqual(result.stderr, "warning: something")
    }
}

// MARK: - NIOSSHError Tests

final class NIOSSHErrorTests: XCTestCase {
    
    func testAllErrorDescriptionsNonEmpty() {
        let errors: [NIOSSHError] = [
            .notConnected,
            .alreadyConnected,
            .connectionFailed("test"),
            .authenticationFailed("test"),
            .channelError("test"),
            .sessionError("test"),
            .timeout,
            .networkUnavailable,
            .hostKeyMismatch(host: "example.com", port: 22, expected: "ssh-ed25519 AAAA", actual: "ssh-rsa BBBB")
        ]
        
        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error \(error) should have a description")
            XCTAssertFalse(error.errorDescription!.isEmpty, "Error description for \(error) should not be empty")
        }
    }
    
    func testSpecificErrorMessages() {
        XCTAssertEqual(NIOSSHError.notConnected.errorDescription, "Not connected to server")
        XCTAssertEqual(NIOSSHError.timeout.errorDescription, "Operation timed out")
        XCTAssertEqual(NIOSSHError.networkUnavailable.errorDescription, "Network unavailable")
    }
    
    func testErrorMessagesIncludeReason() {
        XCTAssertTrue(NIOSSHError.connectionFailed("host unreachable").errorDescription!.contains("host unreachable"))
        XCTAssertTrue(NIOSSHError.authenticationFailed("bad password").errorDescription!.contains("bad password"))
        XCTAssertTrue(NIOSSHError.channelError("rejected").errorDescription!.contains("rejected"))
        XCTAssertTrue(NIOSSHError.sessionError("pty failed").errorDescription!.contains("pty failed"))
    }
    
    func testHostKeyMismatchIncludesHostAndPort() {
        let error = NIOSSHError.hostKeyMismatch(
            host: "example.com",
            port: 22,
            expected: "ssh-ed25519 AAAA",
            actual: "ssh-rsa BBBB"
        )
        let desc = error.errorDescription!
        XCTAssertTrue(desc.contains("example.com"), "Should include host")
        XCTAssertTrue(desc.contains("22"), "Should include port")
        XCTAssertTrue(desc.contains("man-in-the-middle") || desc.contains("changed"), "Should warn about key change")
    }
}
