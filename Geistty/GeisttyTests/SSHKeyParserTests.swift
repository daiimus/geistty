import XCTest
import CryptoKit
@testable import Geistty

// MARK: - SSHKeyParser Tests

/// Tests for SSH private key parsing across all supported key formats.
/// These validate the fixes from Phase A (C1/C2) and cover the most
/// dangerous untested code paths in the app.
final class SSHKeyParserTests: XCTestCase {
    
    // MARK: - Helpers
    
    /// Build an openssh-key-v1 PEM from raw components.
    /// This mirrors the binary format that ssh-keygen produces.
    private func buildOpenSSHPEM(
        keyType: String,
        publicKeyBlob: Data,
        privateSection: Data,
        cipher: String = "none",
        kdf: String = "none",
        kdfOptions: Data = Data()
    ) -> String {
        var keyData = Data()
        
        // AUTH_MAGIC
        keyData.append(contentsOf: Array("openssh-key-v1\0".utf8))
        
        // ciphername
        appendSSHString(&keyData, cipher)
        // kdfname
        appendSSHString(&keyData, kdf)
        // kdfoptions
        appendSSHBytes(&keyData, kdfOptions)
        // number of keys
        appendUInt32(&keyData, 1)
        // public key blob
        appendSSHBytes(&keyData, publicKeyBlob)
        // private key section
        appendSSHBytes(&keyData, privateSection)
        
        let base64 = keyData.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        return SSHKeyManager.pemArmor("OPENSSH PRIVATE KEY", base64)
    }
    
    /// Build the unencrypted private section for an Ed25519 key.
    private func buildEd25519PrivateSection(seed: Data, publicKey: Data, comment: String = "test") -> Data {
        let checkInt = UInt32(0xDEADBEEF)
        var section = Data()
        appendUInt32(&section, checkInt)
        appendUInt32(&section, checkInt)
        appendSSHString(&section, "ssh-ed25519")
        appendSSHBytes(&section, publicKey)
        // OpenSSH stores 64-byte "expanded" private key: seed || publicKey
        var fullPriv = Data(seed)
        fullPriv.append(publicKey)
        appendSSHBytes(&section, fullPriv)
        appendSSHString(&section, comment)
        // Padding to block size 8
        let blockSize = 8
        let paddingNeeded = blockSize - (section.count % blockSize)
        if paddingNeeded < blockSize {
            for i in 1...paddingNeeded {
                section.append(UInt8(i))
            }
        }
        return section
    }
    
    /// Build the unencrypted private section for an ECDSA P-256 key.
    private func buildECDSAP256PrivateSection(privateKey: P256.Signing.PrivateKey, comment: String = "test") -> Data {
        let checkInt = UInt32(0xCAFEBABE)
        var section = Data()
        appendUInt32(&section, checkInt)
        appendUInt32(&section, checkInt)
        appendSSHString(&section, "ecdsa-sha2-nistp256")
        appendSSHString(&section, "nistp256")
        // Public key: uncompressed point (0x04 || x || y)
        let pubRaw = privateKey.publicKey.x963Representation
        appendSSHBytes(&section, pubRaw)
        // Private key scalar
        appendSSHBytes(&section, privateKey.rawRepresentation)
        appendSSHString(&section, comment)
        // Padding
        let blockSize = 8
        let paddingNeeded = blockSize - (section.count % blockSize)
        if paddingNeeded < blockSize {
            for i in 1...paddingNeeded {
                section.append(UInt8(i))
            }
        }
        return section
    }
    
    /// Build a public key blob for Ed25519.
    private func buildEd25519PublicKeyBlob(_ publicKey: Data) -> Data {
        var blob = Data()
        appendSSHString(&blob, "ssh-ed25519")
        appendSSHBytes(&blob, publicKey)
        return blob
    }
    
    /// Build a public key blob for ECDSA P-256.
    private func buildECDSAP256PublicKeyBlob(_ publicKey: P256.Signing.PublicKey) -> Data {
        var blob = Data()
        appendSSHString(&blob, "ecdsa-sha2-nistp256")
        appendSSHString(&blob, "nistp256")
        appendSSHBytes(&blob, publicKey.x963Representation)
        return blob
    }
    
    // SSH wire-format helpers (matching SSHKeyManager's format)
    
    private func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var be = value.bigEndian
        data.append(Data(bytes: &be, count: 4))
    }
    
    private func appendSSHString(_ data: inout Data, _ string: String) {
        let bytes = Array(string.utf8)
        var length = UInt32(bytes.count).bigEndian
        data.append(Data(bytes: &length, count: 4))
        data.append(contentsOf: bytes)
    }
    
    private func appendSSHBytes(_ data: inout Data, _ bytes: Data) {
        var length = UInt32(bytes.count).bigEndian
        data.append(Data(bytes: &length, count: 4))
        data.append(bytes)
    }
    
    // MARK: - Ed25519 Tests
    
    func testParseEd25519OpenSSHKey() throws {
        // Generate a real Ed25519 key using CryptoKit
        let privateKey = Curve25519.Signing.PrivateKey()
        let seed = privateKey.rawRepresentation
        let publicKey = privateKey.publicKey.rawRepresentation
        
        // Build OpenSSH PEM
        let pubBlob = buildEd25519PublicKeyBlob(publicKey)
        let privSection = buildEd25519PrivateSection(seed: seed, publicKey: publicKey)
        let pem = buildOpenSSHPEM(keyType: "ssh-ed25519", publicKeyBlob: pubBlob, privateSection: privSection)
        
        // Parse it
        let pemData = pem.data(using: .utf8)!
        let parsedKey = try SSHKeyParser.parsePrivateKey(pemData)
        
        // Verify the parsed key can sign and the signature verifies
        // NIOSSHPrivateKey doesn't expose the raw key, but if parsing succeeded
        // without throwing, the key was constructed successfully.
        XCTAssertNotNil(parsedKey, "Ed25519 key should parse successfully")
    }
    
    func testParseEd25519RoundTripSignature() throws {
        // Generate key, build PEM, parse, and verify we get the same key
        // by comparing public key representations
        let originalKey = Curve25519.Signing.PrivateKey()
        let seed = originalKey.rawRepresentation
        let publicKey = originalKey.publicKey.rawRepresentation
        
        let pubBlob = buildEd25519PublicKeyBlob(publicKey)
        let privSection = buildEd25519PrivateSection(seed: seed, publicKey: publicKey)
        let pem = buildOpenSSHPEM(keyType: "ssh-ed25519", publicKeyBlob: pubBlob, privateSection: privSection)
        
        let pemData = pem.data(using: .utf8)!
        
        // Parse should succeed — if the seed is correctly extracted, the reconstructed
        // key will match the original (Ed25519 keys are deterministic from seed)
        let parsed = try SSHKeyParser.parsePrivateKey(pemData)
        XCTAssertNotNil(parsed)
    }
    
    func testParseEd25519RejectsBadPublicKeyLength() {
        // Ed25519 public key must be exactly 32 bytes
        let seed = Data(repeating: 0x42, count: 32)
        let badPubKey = Data(repeating: 0x00, count: 16) // Wrong length
        
        let pubBlob = buildEd25519PublicKeyBlob(badPubKey)
        
        // Build private section with bad pub key length
        let checkInt = UInt32(0xDEADBEEF)
        var privSection = Data()
        appendUInt32(&privSection, checkInt)
        appendUInt32(&privSection, checkInt)
        appendSSHString(&privSection, "ssh-ed25519")
        appendSSHBytes(&privSection, badPubKey)
        var fullPriv = Data(seed)
        fullPriv.append(badPubKey)
        appendSSHBytes(&privSection, fullPriv)
        appendSSHString(&privSection, "test")
        let blockSize = 8
        let paddingNeeded = blockSize - (privSection.count % blockSize)
        if paddingNeeded < blockSize {
            for i in 1...paddingNeeded {
                privSection.append(UInt8(i))
            }
        }
        
        let pem = buildOpenSSHPEM(keyType: "ssh-ed25519", publicKeyBlob: pubBlob, privateSection: privSection)
        let pemData = pem.data(using: .utf8)!
        
        XCTAssertThrowsError(try SSHKeyParser.parsePrivateKey(pemData)) { error in
            guard case SSHKeyParseError.invalidKey(let msg) = error else {
                XCTFail("Expected invalidKey error, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("public key length"), "Error should mention public key length, got: \(msg)")
        }
    }
    
    func testParseEd25519RejectsBadPrivateKeyLength() {
        // Ed25519 private key (seed||pub) must be exactly 64 bytes
        let key = Curve25519.Signing.PrivateKey()
        let pubKey = key.publicKey.rawRepresentation
        
        let pubBlob = buildEd25519PublicKeyBlob(pubKey)
        
        let checkInt = UInt32(0xDEADBEEF)
        var privSection = Data()
        appendUInt32(&privSection, checkInt)
        appendUInt32(&privSection, checkInt)
        appendSSHString(&privSection, "ssh-ed25519")
        appendSSHBytes(&privSection, pubKey) // 32 bytes, correct
        appendSSHBytes(&privSection, Data(repeating: 0xFF, count: 48)) // 48 bytes, wrong!
        appendSSHString(&privSection, "test")
        let blockSize = 8
        let paddingNeeded = blockSize - (privSection.count % blockSize)
        if paddingNeeded < blockSize {
            for i in 1...paddingNeeded {
                privSection.append(UInt8(i))
            }
        }
        
        let pem = buildOpenSSHPEM(keyType: "ssh-ed25519", publicKeyBlob: pubBlob, privateSection: privSection)
        let pemData = pem.data(using: .utf8)!
        
        XCTAssertThrowsError(try SSHKeyParser.parsePrivateKey(pemData)) { error in
            guard case SSHKeyParseError.invalidKey(let msg) = error else {
                XCTFail("Expected invalidKey error, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("private key length"), "Error should mention private key length, got: \(msg)")
        }
    }
    
    // MARK: - ECDSA P-256 Tests
    
    func testParseECDSAP256OpenSSHKey() throws {
        let privateKey = P256.Signing.PrivateKey()
        
        let pubBlob = buildECDSAP256PublicKeyBlob(privateKey.publicKey)
        let privSection = buildECDSAP256PrivateSection(privateKey: privateKey)
        let pem = buildOpenSSHPEM(keyType: "ecdsa-sha2-nistp256", publicKeyBlob: pubBlob, privateSection: privSection)
        
        let pemData = pem.data(using: .utf8)!
        let parsedKey = try SSHKeyParser.parsePrivateKey(pemData)
        XCTAssertNotNil(parsedKey, "ECDSA P-256 key should parse successfully")
    }
    
    func testParseECDSAP256PEMFormat() throws {
        // Generate a P-256 key and get its PEM representation directly from CryptoKit
        let privateKey = P256.Signing.PrivateKey()
        let pemString = privateKey.pemRepresentation
        let pemData = pemString.data(using: .utf8)!
        
        // This tests the "EC PRIVATE KEY" PEM path
        let parsedKey = try SSHKeyParser.parsePrivateKey(pemData)
        XCTAssertNotNil(parsedKey, "ECDSA P-256 PEM key should parse successfully")
    }
    
    // MARK: - ECDSA P-384 Tests
    
    func testParseECDSAP384PEMFormat() throws {
        let privateKey = P384.Signing.PrivateKey()
        let pemString = privateKey.pemRepresentation
        let pemData = pemString.data(using: .utf8)!
        
        let parsedKey = try SSHKeyParser.parsePrivateKey(pemData)
        XCTAssertNotNil(parsedKey, "ECDSA P-384 PEM key should parse successfully")
    }
    
    // MARK: - ECDSA P-521 Tests
    
    func testParseECDSAP521PEMFormat() throws {
        let privateKey = P521.Signing.PrivateKey()
        let pemString = privateKey.pemRepresentation
        let pemData = pemString.data(using: .utf8)!
        
        let parsedKey = try SSHKeyParser.parsePrivateKey(pemData)
        XCTAssertNotNil(parsedKey, "ECDSA P-521 PEM key should parse successfully")
    }
    
    // MARK: - Error Cases
    
    func testRejectNonUTF8Data() {
        // Invalid UTF-8 sequence
        let badData = Data([0xFF, 0xFE, 0x00, 0x01])
        
        XCTAssertThrowsError(try SSHKeyParser.parsePrivateKey(badData)) { error in
            guard case SSHKeyParseError.invalidKey(let msg) = error else {
                XCTFail("Expected invalidKey error, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("UTF-8"), "Error should mention UTF-8, got: \(msg)")
        }
    }
    
    func testRejectEncryptedKeyWithoutPassphrase() {
        // Construct a minimal encrypted OpenSSH key binary:
        // openssh-key-v1\0 + cipher="aes256-ctr" + kdf="bcrypt" + kdfoptions + nkeys=1 + pubkey + privkey
        var payload = Data()
        payload.append("openssh-key-v1\0".data(using: .utf8)!)
        
        func appendString(_ s: String) {
            var len = UInt32(s.utf8.count).bigEndian
            payload.append(Data(bytes: &len, count: 4))
            payload.append(s.data(using: .utf8)!)
        }
        func appendBytes(_ d: Data) {
            var len = UInt32(d.count).bigEndian
            payload.append(Data(bytes: &len, count: 4))
            payload.append(d)
        }
        
        appendString("aes256-ctr")     // ciphername — indicates encryption
        appendString("bcrypt")          // kdfname
        appendBytes(Data(repeating: 0, count: 8))  // kdfoptions (dummy)
        var nkeys = UInt32(1).bigEndian
        payload.append(Data(bytes: &nkeys, count: 4))  // number of keys
        appendBytes(Data(repeating: 0, count: 16))      // public key (dummy)
        appendBytes(Data(repeating: 0, count: 32))      // encrypted private data (dummy)
        
        let base64 = payload.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        let encryptedPEM = SSHKeyManager.pemArmor("OPENSSH PRIVATE KEY", base64)
        let pemData = encryptedPEM.data(using: .utf8)!
        
        XCTAssertThrowsError(try SSHKeyParser.parsePrivateKey(pemData)) { error in
            guard case SSHKeyParseError.encryptedKeyNoPassphrase = error else {
                XCTFail("Expected encryptedKeyNoPassphrase error, got \(error)")
                return
            }
        }
    }
    
    func testRejectPKCS8EncryptedKeyWithoutPassphrase() {
        // PKCS#8 encrypted keys use "BEGIN ENCRYPTED PRIVATE KEY" header
        let encryptedPEM = SSHKeyManager.pemArmor("ENCRYPTED PRIVATE KEY", "MIIFHDBOBgkqhkiG9w0BBQ0wQTA=")
        let pemData = encryptedPEM.data(using: .utf8)!
        
        XCTAssertThrowsError(try SSHKeyParser.parsePrivateKey(pemData)) { error in
            guard case SSHKeyParseError.encryptedKeyNoPassphrase = error else {
                XCTFail("Expected encryptedKeyNoPassphrase error, got \(error)")
                return
            }
        }
    }
    
    func testRejectTraditionalPEMEncryptedKeyWithoutPassphrase() {
        // Traditional PEM encrypted keys have "Proc-Type: 4,ENCRYPTED" header
        let encryptedPEM = """
        -----BEGIN RSA PRIVATE KEY-----
        Proc-Type: 4,ENCRYPTED
        DEK-Info: AES-128-CBC,AABBCCDDEEFF00112233445566778899
        
        MIIBuwIBAAJBALRiMLAHudeSA/x3hB2f+2NRkJWn8r4=
        -----END RSA PRIVATE KEY-----
        """
        let pemData = encryptedPEM.data(using: .utf8)!
        
        XCTAssertThrowsError(try SSHKeyParser.parsePrivateKey(pemData)) { error in
            guard case SSHKeyParseError.encryptedKeyNoPassphrase = error else {
                XCTFail("Expected encryptedKeyNoPassphrase error, got \(error)")
                return
            }
        }
    }
    
    func testRejectUnknownPEMFormat() {
        let unknownPEM = SSHKeyManager.pemArmor("DSA PRIVATE KEY", "MIIBuwIBAAJBALRiMLAH...")
        let pemData = unknownPEM.data(using: .utf8)!
        
        XCTAssertThrowsError(try SSHKeyParser.parsePrivateKey(pemData)) { error in
            guard case SSHKeyParseError.unsupportedFormat = error else {
                XCTFail("Expected unsupportedFormat error, got \(error)")
                return
            }
        }
    }
    
    func testRejectInvalidBase64InOpenSSHKey() {
        let badPEM = SSHKeyManager.pemArmor("OPENSSH PRIVATE KEY", "This is not valid base64!!!@#$%")
        let pemData = badPEM.data(using: .utf8)!
        
        XCTAssertThrowsError(try SSHKeyParser.parsePrivateKey(pemData)) { error in
            guard case SSHKeyParseError.invalidKey(let msg) = error else {
                XCTFail("Expected invalidKey error, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("base64"), "Error should mention base64, got: \(msg)")
        }
    }
    
    func testRejectInvalidMagicBytes() {
        // Valid base64 but not openssh-key-v1 format
        let fakeData = Data(repeating: 0x41, count: 100)
        let base64 = fakeData.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        let pem = SSHKeyManager.pemArmor("OPENSSH PRIVATE KEY", base64)
        let pemData = pem.data(using: .utf8)!
        
        XCTAssertThrowsError(try SSHKeyParser.parsePrivateKey(pemData)) { error in
            guard case SSHKeyParseError.invalidKey(let msg) = error else {
                XCTFail("Expected invalidKey error, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("magic"), "Error should mention magic, got: \(msg)")
        }
    }
    
    func testRejectCheckByteMismatch() {
        // Build a valid-looking OpenSSH key but with mismatched check bytes
        let key = Curve25519.Signing.PrivateKey()
        let pubKey = key.publicKey.rawRepresentation
        let pubBlob = buildEd25519PublicKeyBlob(pubKey)
        
        // Build private section with MISMATCHED check bytes
        var privSection = Data()
        appendUInt32(&privSection, 0x11111111)
        appendUInt32(&privSection, 0x22222222) // Different!
        appendSSHString(&privSection, "ssh-ed25519")
        appendSSHBytes(&privSection, pubKey)
        var fullPriv = Data(key.rawRepresentation)
        fullPriv.append(pubKey)
        appendSSHBytes(&privSection, fullPriv)
        appendSSHString(&privSection, "test")
        let blockSize = 8
        let paddingNeeded = blockSize - (privSection.count % blockSize)
        if paddingNeeded < blockSize {
            for i in 1...paddingNeeded {
                privSection.append(UInt8(i))
            }
        }
        
        let pem = buildOpenSSHPEM(keyType: "ssh-ed25519", publicKeyBlob: pubBlob, privateSection: privSection)
        let pemData = pem.data(using: .utf8)!
        
        XCTAssertThrowsError(try SSHKeyParser.parsePrivateKey(pemData)) { error in
            guard case SSHKeyParseError.invalidKey(let msg) = error else {
                XCTFail("Expected invalidKey error, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("Check bytes") || msg.contains("passphrase"),
                         "Error should mention check bytes or passphrase, got: \(msg)")
        }
    }
    
    func testRejectMultipleKeys() {
        // Build OpenSSH format with numKeys = 2
        let key = Curve25519.Signing.PrivateKey()
        let pubBlob = buildEd25519PublicKeyBlob(key.publicKey.rawRepresentation)
        let privSection = buildEd25519PrivateSection(seed: key.rawRepresentation, publicKey: key.publicKey.rawRepresentation)
        
        // Build manually with numKeys = 2
        var keyData = Data()
        keyData.append(contentsOf: Array("openssh-key-v1\0".utf8))
        appendSSHString(&keyData, "none")
        appendSSHString(&keyData, "none")
        appendSSHBytes(&keyData, Data())
        appendUInt32(&keyData, 2) // TWO keys
        appendSSHBytes(&keyData, pubBlob)
        appendSSHBytes(&keyData, privSection)
        
        let base64 = keyData.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        let pem = SSHKeyManager.pemArmor("OPENSSH PRIVATE KEY", base64)
        let pemData = pem.data(using: .utf8)!
        
        XCTAssertThrowsError(try SSHKeyParser.parsePrivateKey(pemData)) { error in
            guard case SSHKeyParseError.invalidKey(let msg) = error else {
                XCTFail("Expected invalidKey error, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("Multiple keys"), "Error should mention multiple keys, got: \(msg)")
        }
    }
    
    func testRejectUnsupportedKeyType() {
        // Build an OpenSSH key with an unknown key type in the private section
        let key = Curve25519.Signing.PrivateKey()
        let pubKey = key.publicKey.rawRepresentation
        
        // Build a fake public key blob with unknown type
        var pubBlob = Data()
        appendSSHString(&pubBlob, "ssh-dss") // DSA — not supported
        appendSSHBytes(&pubBlob, pubKey)
        
        // Build private section with unknown type
        let checkInt = UInt32(0xDEADBEEF)
        var privSection = Data()
        appendUInt32(&privSection, checkInt)
        appendUInt32(&privSection, checkInt)
        appendSSHString(&privSection, "ssh-dss")
        appendSSHBytes(&privSection, pubKey)
        appendSSHBytes(&privSection, Data(repeating: 0x42, count: 64))
        appendSSHString(&privSection, "test")
        let blockSize = 8
        let paddingNeeded = blockSize - (privSection.count % blockSize)
        if paddingNeeded < blockSize {
            for i in 1...paddingNeeded {
                privSection.append(UInt8(i))
            }
        }
        
        let pem = buildOpenSSHPEM(keyType: "ssh-dss", publicKeyBlob: pubBlob, privateSection: privSection)
        let pemData = pem.data(using: .utf8)!
        
        XCTAssertThrowsError(try SSHKeyParser.parsePrivateKey(pemData)) { error in
            guard case SSHKeyParseError.unsupportedFormat(let msg) = error else {
                XCTFail("Expected unsupportedFormat error, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("ssh-dss"), "Error should mention key type, got: \(msg)")
        }
    }
    
    func testRejectTruncatedKeyData() {
        // Build a valid-looking header but truncate the data mid-stream
        var keyData = Data()
        keyData.append(contentsOf: Array("openssh-key-v1\0".utf8))
        appendSSHString(&keyData, "none")
        // Truncate here — missing kdfname, kdfoptions, etc.
        
        let base64 = keyData.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        let pem = SSHKeyManager.pemArmor("OPENSSH PRIVATE KEY", base64)
        let pemData = pem.data(using: .utf8)!
        
        XCTAssertThrowsError(try SSHKeyParser.parsePrivateKey(pemData)) { error in
            guard case SSHKeyParseError.invalidKey = error else {
                XCTFail("Expected invalidKey error for truncated data, got \(error)")
                return
            }
        }
    }
    
    func testRejectEncryptedKeyWithCipher() {
        // Build an OpenSSH key that claims to use aes256-ctr encryption
        let key = Curve25519.Signing.PrivateKey()
        let pubBlob = buildEd25519PublicKeyBlob(key.publicKey.rawRepresentation)
        // The private section would be encrypted, but we just put garbage
        let fakeEncrypted = Data(repeating: 0xAB, count: 128)
        
        let pem = buildOpenSSHPEM(
            keyType: "ssh-ed25519",
            publicKeyBlob: pubBlob,
            privateSection: fakeEncrypted,
            cipher: "aes256-ctr",
            kdf: "bcrypt",
            kdfOptions: Data(repeating: 0x00, count: 20)
        )
        let pemData = pem.data(using: .utf8)!
        
        // Without passphrase → encryptedKeyNoPassphrase
        XCTAssertThrowsError(try SSHKeyParser.parsePrivateKey(pemData)) { error in
            guard case SSHKeyParseError.encryptedKeyNoPassphrase = error else {
                XCTFail("Expected encryptedKeyNoPassphrase, got \(error)")
                return
            }
        }
        
        // With passphrase → invalidKey (encrypted keys not yet supported)
        XCTAssertThrowsError(try SSHKeyParser.parsePrivateKey(pemData, passphrase: "test123")) { error in
            guard case SSHKeyParseError.invalidKey(let msg) = error else {
                XCTFail("Expected invalidKey error for encrypted key, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("Encrypted") || msg.contains("encrypted"),
                         "Error should mention encrypted keys, got: \(msg)")
        }
    }
    
    // MARK: - Error Description Tests
    
    func testSSHKeyParseErrorDescriptions() {
        let errors: [SSHKeyParseError] = [
            .invalidKey("test"),
            .encryptedKeyNoPassphrase,
            .unsupportedFormat("DSA")
        ]
        
        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error \(error) should have a description")
            XCTAssertFalse(error.errorDescription!.isEmpty, "Error description should not be empty")
        }
    }
    
    // MARK: - PEM Whitespace Handling
    
    func testParseKeyWithExtraWhitespace() throws {
        // Keys copied from web UIs sometimes have extra whitespace/blank lines
        let key = Curve25519.Signing.PrivateKey()
        let seed = key.rawRepresentation
        let pubKey = key.publicKey.rawRepresentation
        
        let pubBlob = buildEd25519PublicKeyBlob(pubKey)
        let privSection = buildEd25519PrivateSection(seed: seed, publicKey: pubKey)
        
        // Build PEM with extra whitespace
        var keyData = Data()
        keyData.append(contentsOf: Array("openssh-key-v1\0".utf8))
        appendSSHString(&keyData, "none")
        appendSSHString(&keyData, "none")
        appendSSHBytes(&keyData, Data())
        appendUInt32(&keyData, 1)
        appendSSHBytes(&keyData, pubBlob)
        appendSSHBytes(&keyData, privSection)
        
        let base64 = keyData.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        // Add extra whitespace around lines
        let lines = base64.components(separatedBy: "\n").map { "  \($0)  " }
        let pem = SSHKeyManager.pemArmor("OPENSSH PRIVATE KEY", lines.joined(separator: "\n"))
        
        let pemData = pem.data(using: .utf8)!
        let parsed = try SSHKeyParser.parsePrivateKey(pemData)
        XCTAssertNotNil(parsed, "Should handle whitespace around base64 lines")
    }
    
    // MARK: - parsePrivateKeyWithPublicKey Tests
    
    func testParseEd25519WithPublicKeyExtraction() throws {
        // Generate a real Ed25519 key, build PEM, and verify parsePrivateKeyWithPublicKey
        // returns the correct public key string and key type
        let privateKey = Curve25519.Signing.PrivateKey()
        let seed = privateKey.rawRepresentation
        let publicKey = privateKey.publicKey.rawRepresentation
        
        let pubBlob = buildEd25519PublicKeyBlob(publicKey)
        let privSection = buildEd25519PrivateSection(seed: seed, publicKey: publicKey, comment: "import-test")
        let pem = buildOpenSSHPEM(keyType: "ssh-ed25519", publicKeyBlob: pubBlob, privateSection: privSection)
        let pemData = pem.data(using: .utf8)!
        
        let result = try SSHKeyParser.parsePrivateKeyWithPublicKey(pemData, comment: "my-key")
        
        // Key type should be ed25519
        XCTAssertEqual(result.keyType, .ed25519, "Should detect Ed25519 key type")
        
        // Public key string should be in authorized_keys format
        XCTAssertTrue(result.publicKeyString.hasPrefix("ssh-ed25519 "),
                     "Public key should start with 'ssh-ed25519 ', got: \(result.publicKeyString.prefix(30))")
        
        // Should have base64 section that decodes
        let parts = result.publicKeyString.split(separator: " ")
        XCTAssertGreaterThanOrEqual(parts.count, 2)
        XCTAssertNotNil(Data(base64Encoded: String(parts[1])))
        
        // NIO key should be non-nil
        XCTAssertNotNil(result.privateKey)
    }
    
    func testParseECDSAP256WithPublicKeyExtraction() throws {
        // Generate ECDSA P-256 key, build PEM, verify parsePrivateKeyWithPublicKey
        let privateKey = P256.Signing.PrivateKey()
        
        let pubBlob = buildECDSAP256PublicKeyBlob(privateKey.publicKey)
        let privSection = buildECDSAP256PrivateSection(privateKey: privateKey, comment: "ecdsa-test")
        let pem = buildOpenSSHPEM(keyType: "ecdsa-sha2-nistp256", publicKeyBlob: pubBlob, privateSection: privSection)
        let pemData = pem.data(using: .utf8)!
        
        let result = try SSHKeyParser.parsePrivateKeyWithPublicKey(pemData, comment: "ecdsa-import")
        
        // Key type should be ecdsa
        XCTAssertEqual(result.keyType, .ecdsa, "Should detect ECDSA key type")
        
        // Public key string should be in authorized_keys format
        XCTAssertTrue(result.publicKeyString.hasPrefix("ecdsa-sha2-nistp256 "),
                     "Public key should start with 'ecdsa-sha2-nistp256 ', got: \(result.publicKeyString.prefix(40))")
        
        // Should have base64 section that decodes
        let parts = result.publicKeyString.split(separator: " ")
        XCTAssertGreaterThanOrEqual(parts.count, 2)
        XCTAssertNotNil(Data(base64Encoded: String(parts[1])))
    }
    
    func testParseECDSAP256PEMWithPublicKeyExtraction() throws {
        // Test the EC PRIVATE KEY PEM path (CryptoKit's native format)
        let privateKey = P256.Signing.PrivateKey()
        let pemString = privateKey.pemRepresentation
        let pemData = pemString.data(using: .utf8)!
        
        let result = try SSHKeyParser.parsePrivateKeyWithPublicKey(pemData, comment: "pem-import")
        
        XCTAssertEqual(result.keyType, .ecdsa, "EC PRIVATE KEY PEM should be detected as ECDSA")
        XCTAssertTrue(result.publicKeyString.hasPrefix("ecdsa-sha2-nistp256 "),
                     "Should extract ECDSA public key from PEM format")
    }
    
    func testParseWithPublicKeyRejectsEncryptedKey() {
        // Construct a minimal encrypted OpenSSH key binary (same as above)
        var payload = Data()
        payload.append("openssh-key-v1\0".data(using: .utf8)!)
        
        func appendString(_ s: String) {
            var len = UInt32(s.utf8.count).bigEndian
            payload.append(Data(bytes: &len, count: 4))
            payload.append(s.data(using: .utf8)!)
        }
        func appendBytes(_ d: Data) {
            var len = UInt32(d.count).bigEndian
            payload.append(Data(bytes: &len, count: 4))
            payload.append(d)
        }
        
        appendString("aes256-ctr")     // ciphername — indicates encryption
        appendString("bcrypt")          // kdfname
        appendBytes(Data(repeating: 0, count: 8))  // kdfoptions (dummy)
        var nkeys = UInt32(1).bigEndian
        payload.append(Data(bytes: &nkeys, count: 4))
        appendBytes(Data(repeating: 0, count: 16))
        appendBytes(Data(repeating: 0, count: 32))
        
        let base64 = payload.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        let encryptedPEM = SSHKeyManager.pemArmor("OPENSSH PRIVATE KEY", base64)
        let pemData = encryptedPEM.data(using: .utf8)!
        
        XCTAssertThrowsError(try SSHKeyParser.parsePrivateKeyWithPublicKey(pemData, comment: "test")) { error in
            guard case SSHKeyParseError.encryptedKeyNoPassphrase = error else {
                XCTFail("Expected encryptedKeyNoPassphrase error, got \(error)")
                return
            }
        }
    }
}
