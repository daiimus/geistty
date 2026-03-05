import XCTest
@testable import Geistty

// MARK: - KeychainError Tests

final class KeychainErrorTests: XCTestCase {
    
    func testAllErrorDescriptionsNonEmpty() {
        let errors: [KeychainError] = [
            .itemNotFound,
            .duplicateItem,
            .unexpectedStatus(-25300),
            .dataConversionError,
            .secureEnclaveNotAvailable,
            .authenticationFailed
        ]
        
        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error \(error) should have a description")
            XCTAssertFalse(error.errorDescription!.isEmpty, "Error description for \(error) should not be empty")
        }
    }
    
    func testSpecificErrorMessages() {
        XCTAssertEqual(KeychainError.itemNotFound.errorDescription, "Item not found in Keychain")
        XCTAssertEqual(KeychainError.duplicateItem.errorDescription, "Item already exists in Keychain")
        XCTAssertEqual(KeychainError.dataConversionError.errorDescription, "Failed to convert data")
        XCTAssertEqual(KeychainError.secureEnclaveNotAvailable.errorDescription,
                       "Secure Enclave is not available on this device")
        XCTAssertEqual(KeychainError.authenticationFailed.errorDescription, "Authentication failed")
    }
    
    func testUnexpectedStatusIncludesCode() {
        let error = KeychainError.unexpectedStatus(-25300)
        XCTAssertTrue(error.errorDescription!.contains("-25300"),
                     "unexpectedStatus should include the OSStatus code")
    }
}

// MARK: - KeychainManager Password Tests

/// Tests for KeychainManager password operations.
///
/// These tests use the real iOS Keychain on the simulator. Each test
/// creates items with a unique prefix and cleans them up in tearDown.
final class KeychainManagerPasswordTests: XCTestCase {
    
    private let keychain = KeychainManager.shared
    
    /// Unique host/username prefix for this test run to avoid collisions
    private let testHost = "__test_geistty_kc_host"
    private var testUsers: [String] = []
    
    override func setUp() {
        super.setUp()
        testUsers = []
    }
    
    override func tearDown() {
        // Clean up all test passwords
        for user in testUsers {
            try? keychain.deletePassword(for: testHost, username: user)
        }
        super.tearDown()
    }
    
    /// Register a test username for cleanup
    private func testUsername(_ suffix: String = UUID().uuidString.prefix(8).lowercased()) -> String {
        let user = "__test_\(suffix)"
        testUsers.append(user)
        return user
    }
    
    // MARK: - Save/Get/Delete Cycle
    
    func testSaveAndGetPassword() throws {
        let user = testUsername("pw_save")
        let password = "s3cur3P@ssw0rd!"
        
        try keychain.savePassword(password, for: testHost, username: user)
        let retrieved = try keychain.getPassword(for: testHost, username: user)
        
        XCTAssertEqual(retrieved, password)
    }
    
    func testDeletePassword() throws {
        let user = testUsername("pw_del")
        
        try keychain.savePassword("temp", for: testHost, username: user)
        try keychain.deletePassword(for: testHost, username: user)
        
        XCTAssertThrowsError(try keychain.getPassword(for: testHost, username: user)) { error in
            guard case KeychainError.itemNotFound = error else {
                XCTFail("Expected .itemNotFound after deletion, got \(error)")
                return
            }
        }
    }
    
    func testGetNonexistentPasswordThrows() {
        XCTAssertThrowsError(try keychain.getPassword(for: testHost, username: "__nonexistent_user_xyz")) { error in
            guard case KeychainError.itemNotFound = error else {
                XCTFail("Expected .itemNotFound, got \(error)")
                return
            }
        }
    }
    
    func testSaveOverwritesExisting() throws {
        let user = testUsername("pw_ow")
        
        try keychain.savePassword("old_password", for: testHost, username: user)
        try keychain.savePassword("new_password", for: testHost, username: user)
        
        let retrieved = try keychain.getPassword(for: testHost, username: user)
        XCTAssertEqual(retrieved, "new_password")
    }
    
    func testSaveEmptyPassword() throws {
        let user = testUsername("pw_empty")
        
        try keychain.savePassword("", for: testHost, username: user)
        let retrieved = try keychain.getPassword(for: testHost, username: user)
        XCTAssertEqual(retrieved, "")
    }
    
    func testSaveUnicodePassword() throws {
        let user = testUsername("pw_unicode")
        let password = "p@$$w0rd_\u{1F512}_\u{00E9}\u{00F1}\u{00FC}"
        
        try keychain.savePassword(password, for: testHost, username: user)
        let retrieved = try keychain.getPassword(for: testHost, username: user)
        XCTAssertEqual(retrieved, password)
    }
    
    func testDeleteNonexistentPasswordDoesNotThrow() {
        // deletePassword should succeed (or at least not throw) for non-existent items
        XCTAssertNoThrow(try keychain.deletePassword(for: testHost, username: "__nonexistent_del_xyz"))
    }
    
    func testMultiplePasswordsForDifferentUsers() throws {
        let user1 = testUsername("pw_m1")
        let user2 = testUsername("pw_m2")
        
        try keychain.savePassword("pass1", for: testHost, username: user1)
        try keychain.savePassword("pass2", for: testHost, username: user2)
        
        XCTAssertEqual(try keychain.getPassword(for: testHost, username: user1), "pass1")
        XCTAssertEqual(try keychain.getPassword(for: testHost, username: user2), "pass2")
    }
}

// MARK: - KeychainManager SSH Key Tests

/// Tests for KeychainManager SSH key storage operations.
final class KeychainManagerSSHKeyTests: XCTestCase {
    
    private let keychain = KeychainManager.shared
    private var createdKeyNames: [String] = []
    
    override func setUp() {
        super.setUp()
        createdKeyNames = []
    }
    
    override func tearDown() {
        for name in createdKeyNames {
            try? keychain.deleteSSHKey(name: name)
        }
        super.tearDown()
    }
    
    private func testKeyName(_ suffix: String = UUID().uuidString.prefix(8).lowercased()) -> String {
        let name = "__test_kc_key_\(suffix)"
        createdKeyNames.append(name)
        return name
    }
    
    // MARK: - Save/Get/Delete Cycle
    
    func testSaveAndGetSSHKey() throws {
        let name = testKeyName("save")
        let pemLabel = "OPENSSH PRIVATE KEY"
        let keyData = Data("-----BEGIN \(pemLabel)-----\nfake\n-----END \(pemLabel)-----".utf8)
        
        try keychain.saveSSHKey(keyData, name: name)
        let retrieved = try keychain.getSSHKey(name: name)
        
        XCTAssertEqual(retrieved, keyData)
    }
    
    func testDeleteSSHKey() throws {
        let name = testKeyName("del")
        let keyData = Data("test-key-data".utf8)
        
        try keychain.saveSSHKey(keyData, name: name)
        try keychain.deleteSSHKey(name: name)
        
        XCTAssertThrowsError(try keychain.getSSHKey(name: name)) { error in
            guard case KeychainError.itemNotFound = error else {
                XCTFail("Expected .itemNotFound after SSH key deletion, got \(error)")
                return
            }
        }
    }
    
    func testGetNonexistentSSHKeyThrows() {
        XCTAssertThrowsError(try keychain.getSSHKey(name: "__nonexistent_key_xyz")) { error in
            guard case KeychainError.itemNotFound = error else {
                XCTFail("Expected .itemNotFound, got \(error)")
                return
            }
        }
    }
    
    func testSaveSSHKeyOverwritesExisting() throws {
        let name = testKeyName("ow")
        let oldData = Data("old-key".utf8)
        let newData = Data("new-key".utf8)
        
        try keychain.saveSSHKey(oldData, name: name)
        try keychain.saveSSHKey(newData, name: name)
        
        let retrieved = try keychain.getSSHKey(name: name)
        XCTAssertEqual(retrieved, newData)
    }
    
    func testSaveLargeSSHKey() throws {
        // RSA 4096-bit keys can be ~3KB
        let name = testKeyName("large")
        let keyData = Data(repeating: 0x42, count: 4096)
        
        try keychain.saveSSHKey(keyData, name: name)
        let retrieved = try keychain.getSSHKey(name: name)
        XCTAssertEqual(retrieved, keyData)
    }
    
    // MARK: - List SSH Keys
    
    func testListSSHKeysIncludesCreated() throws {
        let name = testKeyName("list")
        let keyData = Data("list-test".utf8)
        
        try keychain.saveSSHKey(keyData, name: name)
        
        let keys = keychain.listSSHKeys()
        XCTAssertTrue(keys.contains(name), "listSSHKeys should include '\(name)', got: \(keys)")
    }
    
    func testListSSHKeysExcludesDeleted() throws {
        let name = testKeyName("list_del")
        let keyData = Data("list-del-test".utf8)
        
        try keychain.saveSSHKey(keyData, name: name)
        try keychain.deleteSSHKey(name: name)
        
        let keys = keychain.listSSHKeys()
        XCTAssertFalse(keys.contains(name), "listSSHKeys should NOT include deleted key '\(name)'")
    }
    
    func testListSSHKeysIsSorted() throws {
        let names = ["list_z", "list_a", "list_m"].map { testKeyName($0) }
        
        for name in names {
            try keychain.saveSSHKey(Data("key".utf8), name: name)
        }
        
        let keys = keychain.listSSHKeys().filter { $0.hasPrefix("__test_kc_key_list_") }
        
        // Verify sorted
        let sorted = keys.sorted()
        XCTAssertEqual(keys, sorted, "listSSHKeys results should be sorted")
    }
    
    func testDeleteSSHKeyAlsoDeletesOldFormat() throws {
        // deleteSSHKey cleans up both new (kSecClassGenericPassword) and old (kSecClassKey) formats.
        // We can't easily test the old format creation, but we can verify deleteSSHKey
        // doesn't crash when the old format doesn't exist.
        let name = testKeyName("old_fmt")
        let keyData = Data("test".utf8)
        
        try keychain.saveSSHKey(keyData, name: name)
        // This should clean up both formats without error
        XCTAssertNoThrow(try keychain.deleteSSHKey(name: name))
    }
}
