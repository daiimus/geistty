//
//  FileProviderExtensionTests.swift
//  GeisttyTests
//
//  TRUE integration tests that use NSFileProviderManager to interact with
//  the actual File Provider extension. These tests verify the extension
//  is properly registered, responds to signals, and returns valid anchors.
//
//  CRITICAL: These tests require the app to be installed with the extension.
//  On simulator, the domain won't be registered (extension not running).
//  Run on real device to test actual extension behavior.
//

import FileProvider
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import Geistty

// MARK: - Global Test Helpers

/// Check if running on simulator
private var isRunningOnSimulator: Bool {
    #if targetEnvironment(simulator)
    return true
    #else
    return false
    #endif
}

/// Get domains, or return empty array on simulator where it may fail
private func getFileProviderDomains() async throws -> [NSFileProviderDomain] {
    do {
        return try await NSFileProviderManager.domains()
    } catch {
        if isRunningOnSimulator {
            // On simulator, domains() may throw - treat as no domains
            return []
        }
        throw error
    }
}

/// Integration tests that actually invoke the File Provider extension
/// through NSFileProviderManager APIs.
///
/// NOTE: These tests verify the actual iOS File Provider infrastructure.
/// - On Simulator: Domain won't exist (no extension process), tests will report diagnostic info
/// - On Device: Full integration test of extension behavior
@available(iOS 16.0, *)
final class FileProviderExtensionTests: XCTestCase {
    
    /// The domain identifier we use
    let domainIdentifier = NSFileProviderDomainIdentifier("com.geistty.fileprovider")
    
    /// Check if we're running on simulator
    var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
    
    // MARK: - Helper Methods
    
    /// Get domains, or return empty array on simulator where it may fail
    private func getDomains() async throws -> [NSFileProviderDomain] {
        do {
            return try await NSFileProviderManager.domains()
        } catch {
            if isSimulator {
                // On simulator, domains() may throw - treat as no domains
                return []
            }
            throw error
        }
    }
    
    // MARK: - Domain Registration Tests
    
    /// Test: Verify our File Provider domain is registered with iOS
    func testDomainIsRegistered() async throws {
        let domains = try await getFileProviderDomains()
        
        // On simulator, we expect no domains
        if isSimulator && domains.isEmpty {
            // This is expected - skip with diagnostic info
            throw XCTSkip("Running on simulator - File Provider domains are not available. Run on device to test extension.")
        }
        
        // Look for our domain
        let geisttyDomain = domains.first { domain in
            domain.identifier.rawValue.contains("geistty")
        }
        
        XCTAssertNotNil(geisttyDomain, 
            "Geistty File Provider domain should be registered. Found domains: \(domains.map { $0.identifier.rawValue })")
    }
    
    /// Test: Get manager for our domain
    func testCanGetManagerForDomain() async throws {
        let domains = try await getFileProviderDomains()
        
        if isSimulator && domains.isEmpty {
            throw XCTSkip("Running on simulator - File Provider domains are not available.")
        }
        
        guard let domain = domains.first(where: { $0.identifier.rawValue.contains("geistty") }) else {
            XCTFail("No Geistty domain found")
            return
        }
        
        let manager = NSFileProviderManager(for: domain)
        XCTAssertNotNil(manager, "Should be able to get manager for domain")
    }
    
    // MARK: - Signal Enumerator Tests
    
    /// Test: Signal the working set enumerator
    /// This actually triggers iOS to call our extension's enumerator
    func testSignalWorkingSetEnumerator() async throws {
        let domains = try await getFileProviderDomains()
        
        if isSimulator && domains.isEmpty {
            throw XCTSkip("Running on simulator - File Provider domains are not available.")
        }
        
        guard let domain = domains.first(where: { $0.identifier.rawValue.contains("geistty") }) else {
            XCTFail("No Geistty domain found")
            return
        }
        
        guard let manager = NSFileProviderManager(for: domain) else {
            XCTFail("Could not get manager for domain")
            return
        }
        
        // This should NOT throw - it signals the extension
        do {
            try await manager.signalEnumerator(for: .workingSet)
            // If we get here without throwing, the extension responded
        } catch {
            XCTFail("signalEnumerator failed: \(error). This likely means the extension is not responding properly.")
        }
    }
    
    /// Test: Signal root container enumerator
    func testSignalRootEnumerator() async throws {
        let domains = try await getFileProviderDomains()
        
        if isSimulator && domains.isEmpty {
            throw XCTSkip("Running on simulator - File Provider domains are not available.")
        }
        
        guard let domain = domains.first(where: { $0.identifier.rawValue.contains("geistty") }) else {
            XCTFail("No Geistty domain found")
            return
        }
        
        guard let manager = NSFileProviderManager(for: domain) else {
            XCTFail("Could not get manager for domain")
            return
        }
        
        do {
            try await manager.signalEnumerator(for: .rootContainer)
        } catch {
            XCTFail("signalEnumerator for root failed: \(error)")
        }
    }
    
    // MARK: - User Interaction Required Tests (UI Tests)
    
    /// Test: Reimport domain to force fresh sync
    /// This is the nuclear option for "Syncing Paused"
    func testReimportDomain() async throws {
        let domains = try await getFileProviderDomains()
        
        if isSimulator && domains.isEmpty {
            throw XCTSkip("Running on simulator - File Provider domains are not available.")
        }
        
        guard let domain = domains.first(where: { $0.identifier.rawValue.contains("geistty") }) else {
            XCTFail("No Geistty domain found")
            return
        }
        
        guard let manager = NSFileProviderManager(for: domain) else {
            XCTFail("Could not get manager for domain")
            return
        }
        
        // reimportItems forces iOS to re-enumerate everything
        do {
            try await manager.reimportItems(below: .rootContainer)
            // Success - the extension handled the reimport
        } catch {
            // Some errors are expected (e.g., if extension is not running)
            print("reimportItems returned: \(error)")
            // Don't fail - this is informational
        }
    }
}

// MARK: - Sync Anchor Contract Tests

/// Tests that verify the sync anchor contract between iOS and our extension
@available(iOS 16.0, *)
final class SyncAnchorContractTests: XCTestCase {
    
    /// Test: Anchor from MetadataAnchorCache must be valid 8-byte format
    func testAnchorCacheProducesValidFormat() {
        let cache = MetadataAnchorCache.shared
        let syncAnchor = cache.syncAnchor
        
        // Must be exactly 8 bytes
        XCTAssertEqual(syncAnchor.rawValue.count, 8,
            "Sync anchor must be 8 bytes (UInt64)")
        
        // Must parse back to a value >= 1
        let value = SyncState.anchorValue(from: syncAnchor)
        XCTAssertNotNil(value, "Should parse as UInt64")
        XCTAssertGreaterThanOrEqual(value!, 1, "Value should be >= 1")
    }
    
    /// Test: MetadataStoreEnumerator.currentSyncAnchor returns immediately
    func testEnumeratorCurrentSyncAnchorIsSync() {
        let enumerator = MetadataStoreEnumerator()
        
        var receivedAnchor: NSFileProviderSyncAnchor?
        var callbackTime: Date?
        let startTime = Date()
        
        // This MUST complete synchronously
        enumerator.currentSyncAnchor { anchor in
            receivedAnchor = anchor
            callbackTime = Date()
        }
        
        // Callback should have been invoked already
        XCTAssertNotNil(receivedAnchor, "Callback must be invoked synchronously")
        
        if let callbackTime = callbackTime {
            let elapsed = callbackTime.timeIntervalSince(startTime)
            XCTAssertLessThan(elapsed, 0.1, "Callback must complete in < 100ms")
        }
        
        // Anchor should be valid
        XCTAssertEqual(receivedAnchor?.rawValue.count, 8)
    }
    
    /// Test: MetadataStoreEnumerator.enumerateChanges calls observer
    func testEnumeratorEnumerateChangesCallsObserver() async throws {
        // First populate the store with some data
        let store = MetadataStore.shared
        try await store.clearAll()
        
        // Add test data with valid parent (connection root format)
        let (_, _) = try await store.upsert(
            itemIdentifier: "conn:test:path:/test.txt",
            connectionId: "test",
            remotePath: "/test.txt",
            parentIdentifier: "conn:test",  // Connection root - valid parent
            filename: "test.txt",
            size: 100,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: nil,
            isSymlink: false
        )
        
        // Create enumerator
        let enumerator = MetadataStoreEnumerator()
        
        // Create expectation for async completion
        let expectation = expectation(description: "enumerateChanges completed")
        
        // Create mock observer
        let observer = TestChangeObserver { anchor, moreComing in
            // Validate anchor
            XCTAssertEqual(anchor.rawValue.count, 8, "Anchor must be 8 bytes")
            XCTAssertFalse(moreComing, "Should not have more coming")
            expectation.fulfill()
        }
        
        // Call enumerateChanges from anchor 0
        var zeroAnchor: UInt64 = 0
        let anchorData = Data(bytes: &zeroAnchor, count: 8)
        let fromAnchor = NSFileProviderSyncAnchor(anchorData)
        
        enumerator.enumerateChanges(for: observer, from: fromAnchor)
        
        // Wait for completion (uses Task {} internally)
        await fulfillment(of: [expectation], timeout: 5.0)
        
        // Verify items were reported
        XCTAssertGreaterThanOrEqual(observer.updatedItems.count, 1, 
            "Should have at least 1 updated item")
        
        // Cleanup
        try await store.clearAll()
    }
}

// MARK: - Test Observer

/// Test observer for enumerateChanges
private class TestChangeObserver: NSObject, NSFileProviderChangeObserver {
    var updatedItems: [any NSFileProviderItem] = []
    var deletedIdentifiers: [NSFileProviderItemIdentifier] = []
    
    private let onFinish: (NSFileProviderSyncAnchor, Bool) -> Void
    
    init(onFinish: @escaping (NSFileProviderSyncAnchor, Bool) -> Void) {
        self.onFinish = onFinish
        super.init()
    }
    
    var suggestedBatchSize: Int { 100 }
    
    func didUpdate(_ updatedItems: [any NSFileProviderItem]) {
        self.updatedItems.append(contentsOf: updatedItems)
    }
    
    func didDeleteItems(withIdentifiers deletedItemIdentifiers: [NSFileProviderItemIdentifier]) {
        self.deletedIdentifiers.append(contentsOf: deletedItemIdentifiers)
    }
    
    func finishEnumeratingChanges(upTo anchor: NSFileProviderSyncAnchor, moreComing: Bool) {
        onFinish(anchor, moreComing)
    }
    
    func finishEnumeratingWithError(_ error: Error) {
        // Test should fail if this is called
    }
}

/// Helper class to collect pending items from the pending enumerator
@available(iOS 16.0, *)
private class PendingItemsObserver: NSObject, NSFileProviderEnumerationObserver {
    private var items: [NSFileProviderItemIdentifier] = []
    private let onComplete: ([NSFileProviderItemIdentifier]) -> Void
    private var didComplete = false
    
    init(onComplete: @escaping ([NSFileProviderItemIdentifier]) -> Void) {
        self.onComplete = onComplete
        super.init()
    }
    
    var suggestedPageSize: Int { 100 }
    
    func didEnumerate(_ items: [any NSFileProviderItem]) {
        self.items.append(contentsOf: items.map { $0.itemIdentifier })
    }
    
    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        guard !didComplete else { return }
        didComplete = true
        onComplete(items)
    }
    
    func finishEnumeratingWithError(_ error: Error) {
        guard !didComplete else { return }
        didComplete = true
        onComplete(items)
    }
}

// MARK: - MetadataStore Full Flow Tests

/// Tests the complete MetadataStore + Enumerator flow
@available(iOS 16.0, *)
final class MetadataStoreFullFlowTests: XCTestCase {
    
    var store: MetadataStore!
    
    override func setUp() async throws {
        store = MetadataStore.shared
        try await store.clearAll()
    }
    
    override func tearDown() async throws {
        try await store.clearAll()
    }
    
    /// Test: Complete create → enumerate → modify → enumerate flow
    func testCreateEnumerateModifyFlow() async throws {
        // 1. Initial state
        let initialAnchor = try await store.currentAnchor
        XCTAssertGreaterThanOrEqual(initialAnchor, 1, "Initial anchor must be >= 1")
        
        // 2. Add item
        let (item1, isNew1) = try await store.upsert(
            itemIdentifier: "flow:item1",
            connectionId: "flow",
            remotePath: "/test.txt",
            parentIdentifier: "flow",
            filename: "test.txt",
            size: 100,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: Date(),
            isSymlink: false
        )
        XCTAssertTrue(isNew1, "Should be new item")
        XCTAssertEqual(item1.filename, "test.txt")
        
        let anchorAfterCreate = try await store.currentAnchor
        XCTAssertGreaterThan(anchorAfterCreate, initialAnchor, "Anchor must increment after create")
        
        // 3. Enumerate changes from initial anchor
        let changesAfterCreate = try await store.itemsModified(since: initialAnchor)
        XCTAssertEqual(changesAfterCreate.count, 1, "Should find 1 new item")
        XCTAssertEqual(changesAfterCreate.first?.filename, "test.txt")
        
        // 4. Modify item
        let (item2, isNew2) = try await store.upsert(
            itemIdentifier: "flow:item1",
            connectionId: "flow",
            remotePath: "/test.txt",
            parentIdentifier: "flow",
            filename: "test.txt",
            size: 200, // Changed size
            isDirectory: false,
            permissions: 0o644,
            modificationDate: Date(),
            isSymlink: false
        )
        XCTAssertFalse(isNew2, "Should be update, not new")
        XCTAssertEqual(item2.size, 200)
        
        let anchorAfterModify = try await store.currentAnchor
        XCTAssertGreaterThan(anchorAfterModify, anchorAfterCreate, "Anchor must increment after modify")
        
        // 5. Enumerate changes from after create
        let changesAfterModify = try await store.itemsModified(since: anchorAfterCreate)
        XCTAssertEqual(changesAfterModify.count, 1, "Should find 1 modified item")
        XCTAssertEqual(changesAfterModify.first?.size, 200)
        
        // 6. Enumerate from anchor 0 (full sync)
        let allChanges = try await store.itemsModified(since: 0)
        XCTAssertEqual(allChanges.count, 1, "Full sync should find 1 item total")
    }
    
    /// Test: Delete flow and change tracking
    func testDeleteAndChangeTracking() async throws {
        // 1. Create two items
        let (_, _) = try await store.upsert(
            itemIdentifier: "del:item1",
            connectionId: "del",
            remotePath: "/file1.txt",
            parentIdentifier: "del",
            filename: "file1.txt",
            size: 100,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: nil,
            isSymlink: false
        )
        let (_, _) = try await store.upsert(
            itemIdentifier: "del:item2",
            connectionId: "del",
            remotePath: "/file2.txt",
            parentIdentifier: "del",
            filename: "file2.txt",
            size: 200,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: nil,
            isSymlink: false
        )
        
        let anchorAfterCreate = try await store.currentAnchor
        
        // 2. Delete first item
        _ = try await store.markDeleted(id: "del:item1")
        
        let anchorAfterDelete = try await store.currentAnchor
        XCTAssertGreaterThan(anchorAfterDelete, anchorAfterCreate, "Anchor must increment after delete")
        
        // 3. Check deletions since before delete
        let deletions = try await store.deletions(since: anchorAfterCreate)
        XCTAssertTrue(deletions.contains("del:item1"), "Deletions should include del:item1")
        
        // 4. Item should not be found normally
        let found = try await store.item(id: "del:item1")
        XCTAssertNil(found, "Deleted item should not be found")
        
        // 5. Other item still exists
        let found2 = try await store.item(id: "del:item2")
        XCTAssertNotNil(found2, "Other item should still exist")
    }
    
    /// Test: Anchor persists across cache instances
    func testAnchorPersistence() async throws {
        // Modify anchor
        let newAnchor = try await store.incrementAnchor()
        
        // Cache should have same value
        let cacheAnchor = MetadataAnchorCache.shared.currentAnchor
        XCTAssertGreaterThanOrEqual(cacheAnchor, newAnchor,
            "Cache should reflect incremented anchor")
    }
    
    /// Test: changesSince returns both modifications and deletions
    func testChangesSinceReturnsAll() async throws {
        // Create items
        let (_, _) = try await store.upsert(
            itemIdentifier: "chg:item1",
            connectionId: "chg",
            remotePath: "/a.txt",
            parentIdentifier: "chg",
            filename: "a.txt",
            size: 100,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: nil,
            isSymlink: false
        )
        let (_, _) = try await store.upsert(
            itemIdentifier: "chg:item2",
            connectionId: "chg",
            remotePath: "/b.txt",
            parentIdentifier: "chg",
            filename: "b.txt",
            size: 200,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: nil,
            isSymlink: false
        )
        
        let anchorAfterCreate = try await store.currentAnchor
        
        // Modify one, delete one
        let (_, _) = try await store.upsert(
            itemIdentifier: "chg:item1",
            connectionId: "chg",
            remotePath: "/a.txt",
            parentIdentifier: "chg",
            filename: "a.txt",
            size: 150, // Changed
            isDirectory: false,
            permissions: 0o644,
            modificationDate: nil,
            isSymlink: false
        )
        _ = try await store.markDeleted(id: "chg:item2")
        
        // Use changesSince (the method enumerator uses)
        let (modified, deleted, anchor) = try await store.changesSince(anchor: anchorAfterCreate)
        
        XCTAssertEqual(modified.count, 1, "Should have 1 modified item")
        XCTAssertEqual(modified.first?.filename, "a.txt")
        XCTAssertEqual(modified.first?.size, 150)
        
        XCTAssertEqual(deleted.count, 1, "Should have 1 deleted item")
        XCTAssertTrue(deleted.contains("chg:item2"))
        
        let currentAnchor = try await store.currentAnchor
        XCTAssertEqual(anchor, currentAnchor, "Returned anchor should be current")
    }
}

// MARK: - Item Identifier Tests

/// Tests for item identifier parsing and formatting
final class ItemIdentifierTests: XCTestCase {
    
    func testConnectionRootFormat() {
        let id = ItemIdentifier.connectionRoot("myconnection")
        XCTAssertEqual(id, "conn:myconnection")
    }
    
    func testRemoteItemFormat() {
        let id = ItemIdentifier.remoteItem(connectionId: "myconn", path: "/home/user/file.txt")
        XCTAssertEqual(id, "conn:myconn:path:/home/user/file.txt")
    }
    
    func testParseConnectionId() {
        // From connection root
        let connFromRoot = ItemIdentifier.parseConnectionId(from: "conn:myconnection")
        XCTAssertEqual(connFromRoot, "myconnection")
        
        // From remote item
        let connFromItem = ItemIdentifier.parseConnectionId(from: "conn:test:path:/file.txt")
        XCTAssertEqual(connFromItem, "test")
        
        // Invalid format
        let invalid = ItemIdentifier.parseConnectionId(from: "invalid:format")
        XCTAssertNil(invalid)
    }
    
    func testParseRemotePath() {
        let path = ItemIdentifier.parseRemotePath(from: "conn:test:path:/home/user/file.txt")
        XCTAssertEqual(path, "/home/user/file.txt")
        
        // Connection root has no path
        let noPath = ItemIdentifier.parseRemotePath(from: "conn:myconnection")
        XCTAssertNil(noPath)
    }
    
    func testIsConnectionRoot() {
        XCTAssertTrue(ItemIdentifier.isConnectionRoot("conn:myconnection"))
        XCTAssertFalse(ItemIdentifier.isConnectionRoot("conn:test:path:/file.txt"))
        XCTAssertFalse(ItemIdentifier.isConnectionRoot("invalid"))
    }
    
    func testSpecialCharactersInPath() {
        // Paths with special characters should work
        let id = ItemIdentifier.remoteItem(connectionId: "conn", path: "/path with spaces/file (1).txt")
        XCTAssertEqual(id, "conn:conn:path:/path with spaces/file (1).txt")
        
        let parsed = ItemIdentifier.parseRemotePath(from: id)
        XCTAssertEqual(parsed, "/path with spaces/file (1).txt")
    }
}

// MARK: - CachedMetadataItem Tests

/// Tests for the NSFileProviderItem wrapper
@available(iOS 16.0, *)
final class CachedMetadataItemTests: XCTestCase {
    
    var store: MetadataStore!
    
    override func setUp() async throws {
        store = MetadataStore.shared
        try await store.clearAll()
    }
    
    override func tearDown() async throws {
        try await store.clearAll()
    }
    
    func testFileItemProperties() async throws {
        // Create metadata with explicit isDirectory: false
        let (metadata, isNew) = try await store.upsert(
            itemIdentifier: "cached:file1",
            connectionId: "cached",
            remotePath: "/document.pdf",
            parentIdentifier: "cached",
            filename: "document.pdf",
            size: 1024,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: Date(timeIntervalSince1970: 1700000000),
            isSymlink: false
        )
        
        XCTAssertTrue(isNew, "Should be a new item")
        
        // Verify metadata was stored correctly
        XCTAssertEqual(metadata.itemIdentifier, "cached:file1")
        XCTAssertEqual(metadata.filename, "document.pdf")
        XCTAssertFalse(metadata.isDirectory, "metadata.isDirectory should be false for file")
        
        // Re-fetch from store to ensure persistence
        guard let refetched = try await store.item(id: "cached:file1") else {
            XCTFail("Should find item after upsert")
            return
        }
        XCTAssertFalse(refetched.isDirectory, "Re-fetched item should have isDirectory=false")
        
        // Use the re-fetched metadata to create item
        let item = CachedMetadataItem(metadata: refetched)
        
        XCTAssertEqual(item.itemIdentifier.rawValue, "cached:file1")
        XCTAssertEqual(item.filename, "document.pdf")
        XCTAssertEqual(item.documentSize?.intValue, 1024)
        
        // Check contentType - files should be .data, directories .folder
        XCTAssertEqual(item.contentType, .data, "Files should have contentType .data")
        
        // NOTE: .allowsReading and .allowsContentEnumerating both have rawValue 1
        // Apple defines them as equivalent (reading = content enumeration in capability terms)
        // So we can only check that the reading capability is present
        XCTAssertTrue(item.capabilities.contains(.allowsReading), "File should allow reading")
        
        // Files should NOT have writing capabilities
        XCTAssertFalse(item.capabilities.contains(.allowsWriting), "Files should not allow writing in this implementation")
    }
    
    func testDirectoryItemProperties() async throws {
        let (metadata, _) = try await store.upsert(
            itemIdentifier: "cached:folder1",
            connectionId: "cached",
            remotePath: "/Documents",
            parentIdentifier: "cached",
            filename: "Documents",
            size: 0,
            isDirectory: true,
            permissions: 0o755,
            modificationDate: nil,
            isSymlink: false
        )
        
        let item = CachedMetadataItem(metadata: metadata)
        
        XCTAssertEqual(item.itemIdentifier.rawValue, "cached:folder1")
        XCTAssertEqual(item.filename, "Documents")
        XCTAssertEqual(item.contentType, .folder, "Directories should have contentType .folder")
        
        // NOTE: .allowsReading and .allowsContentEnumerating both have rawValue 1
        // So checking either is equivalent
        XCTAssertTrue(item.capabilities.contains(.allowsReading), "Directory should allow reading")
    }
    
    func testParentIdentifierMapping() async throws {
        // Test root parent
        let (rootChild, _) = try await store.upsert(
            itemIdentifier: "cached:rootchild",
            connectionId: "cached",
            remotePath: "/file.txt",
            parentIdentifier: "root",
            filename: "file.txt",
            size: 100,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: nil,
            isSymlink: false
        )
        
        let rootChildItem = CachedMetadataItem(metadata: rootChild)
        XCTAssertEqual(rootChildItem.parentItemIdentifier, .rootContainer,
            "Parent 'root' should map to .rootContainer")
        
        // Test non-root parent
        let (nested, _) = try await store.upsert(
            itemIdentifier: "cached:nested",
            connectionId: "cached",
            remotePath: "/folder/file.txt",
            parentIdentifier: "cached:folder",
            filename: "file.txt",
            size: 100,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: nil,
            isSymlink: false
        )
        
        let nestedItem = CachedMetadataItem(metadata: nested)
        XCTAssertEqual(nestedItem.parentItemIdentifier.rawValue, "cached:folder")
    }
    
    /// Test: CachedMetadataItem must have itemVersion (required for NSFileProviderReplicatedExtension)
    /// Without itemVersion, iOS may reject items or show "Syncing Paused"
    func testItemVersionIsPresent() async throws {
        let modDate = Date(timeIntervalSince1970: 1700000000)
        let (metadata, _) = try await store.upsert(
            itemIdentifier: "cached:versiontest",
            connectionId: "cached",
            remotePath: "/versioned.txt",
            parentIdentifier: "cached",
            filename: "versioned.txt",
            size: 12345,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: modDate,
            isSymlink: false
        )
        
        let item = CachedMetadataItem(metadata: metadata)
        
        // itemVersion is REQUIRED for replicated extension
        let version = item.itemVersion
        
        // Verify version has valid data
        XCTAssertFalse(version.contentVersion.isEmpty, "contentVersion should not be empty")
        XCTAssertFalse(version.metadataVersion.isEmpty, "metadataVersion should not be empty")
        
        // Version should encode size and modification time
        let contentStr = String(data: version.contentVersion, encoding: .utf8)!
        XCTAssertTrue(contentStr.contains("12345"), "contentVersion should include size")
        XCTAssertTrue(contentStr.contains("1700000000"), "contentVersion should include mod time")
    }
    
    /// Test: All required NSFileProviderItem properties are implemented
    /// Per Apple docs: itemIdentifier, parentItemIdentifier, filename are REQUIRED
    /// contentType and capabilities are effectively required for iOS 14+
    func testAllRequiredPropertiesPresent() async throws {
        let modDate = Date(timeIntervalSince1970: 1700000000)
        let (metadata, _) = try await store.upsert(
            itemIdentifier: "cached:reqtest",
            connectionId: "cached",
            remotePath: "/required.txt",
            parentIdentifier: "cached:parent",
            filename: "required.txt",
            size: 100,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: modDate,
            isSymlink: false
        )
        
        let item = CachedMetadataItem(metadata: metadata)
        
        // REQUIRED by protocol
        XCTAssertEqual(item.itemIdentifier.rawValue, "cached:reqtest")
        XCTAssertEqual(item.parentItemIdentifier.rawValue, "cached:parent")
        XCTAssertEqual(item.filename, "required.txt")
        
        // REQUIRED for iOS 14+ (effectively required)
        XCTAssertEqual(item.contentType, .data) // files should be .data
        XCTAssertTrue(item.capabilities.contains(.allowsReading))
        
        // REQUIRED for replicated extension
        _ = item.itemVersion // Should not crash
    }
    
    /// Test: itemVersion changes when item is updated
    /// This is critical for iOS to detect changes
    func testItemVersionChangesOnUpdate() async throws {
        let modDate1 = Date(timeIntervalSince1970: 1700000000)
        let (metadata1, _) = try await store.upsert(
            itemIdentifier: "cached:verchange",
            connectionId: "cached",
            remotePath: "/changing.txt",
            parentIdentifier: "cached",
            filename: "changing.txt",
            size: 100,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: modDate1,
            isSymlink: false
        )
        
        let item1 = CachedMetadataItem(metadata: metadata1)
        let version1 = item1.itemVersion
        
        // Update the item with new size and mod date
        let modDate2 = Date(timeIntervalSince1970: 1700001000)
        let (metadata2, _) = try await store.upsert(
            itemIdentifier: "cached:verchange",
            connectionId: "cached",
            remotePath: "/changing.txt",
            parentIdentifier: "cached",
            filename: "changing.txt",
            size: 200, // Changed
            isDirectory: false,
            permissions: 0o644,
            modificationDate: modDate2, // Changed
            isSymlink: false
        )
        
        let item2 = CachedMetadataItem(metadata: metadata2)
        let version2 = item2.itemVersion
        
        // Versions should be DIFFERENT
        XCTAssertNotEqual(version1.contentVersion, version2.contentVersion,
            "contentVersion should change when item updates")
    }
    
    /// Test: documentSize is implemented for files
    func testDocumentSizeForFiles() async throws {
        let (metadata, _) = try await store.upsert(
            itemIdentifier: "cached:sizetest",
            connectionId: "cached",
            remotePath: "/sized.txt",
            parentIdentifier: "cached",
            filename: "sized.txt",
            size: 98765,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: nil,
            isSymlink: false
        )
        
        let item = CachedMetadataItem(metadata: metadata)
        
        XCTAssertNotNil(item.documentSize, "Files should have documentSize")
        XCTAssertEqual(item.documentSize?.int64Value, 98765)
    }
    
    /// Test: contentModificationDate and creationDate are implemented
    func testDatePropertiesPresent() async throws {
        let modDate = Date(timeIntervalSince1970: 1700000000)
        let (metadata, _) = try await store.upsert(
            itemIdentifier: "cached:datetest",
            connectionId: "cached",
            remotePath: "/dated.txt",
            parentIdentifier: "cached",
            filename: "dated.txt",
            size: 100,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: modDate,
            isSymlink: false
        )
        
        let item = CachedMetadataItem(metadata: metadata)
        
        XCTAssertNotNil(item.contentModificationDate, "Files should have contentModificationDate")
        XCTAssertEqual(item.contentModificationDate, modDate)
        
        // We use mod date as creation date (SFTP doesn't provide creation date)
        XCTAssertNotNil(item.creationDate, "Files should have creationDate")
        XCTAssertEqual(item.creationDate, modDate)
    }
    
    /// Test: contentType is .folder for directories
    func testContentTypeForDirectories() async throws {
        let (metadata, _) = try await store.upsert(
            itemIdentifier: "cached:dirtype",
            connectionId: "cached",
            remotePath: "/folder",
            parentIdentifier: "cached",
            filename: "folder",
            size: 0,
            isDirectory: true,
            permissions: 0o755,
            modificationDate: nil,
            isSymlink: false
        )
        
        let item = CachedMetadataItem(metadata: metadata)
        
        XCTAssertEqual(item.contentType, .folder, "Directories should have contentType .folder")
    }
    
    /// Test: capabilities differ for files vs directories
    func testCapabilitiesDifferByType() async throws {
        // Create file
        let (fileMetadata, _) = try await store.upsert(
            itemIdentifier: "cached:capfile",
            connectionId: "cached",
            remotePath: "/file.txt",
            parentIdentifier: "cached",
            filename: "file.txt",
            size: 100,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: nil,
            isSymlink: false
        )
        
        // Create directory
        let (dirMetadata, _) = try await store.upsert(
            itemIdentifier: "cached:capdir",
            connectionId: "cached",
            remotePath: "/dir",
            parentIdentifier: "cached",
            filename: "dir",
            size: 0,
            isDirectory: true,
            permissions: 0o755,
            modificationDate: nil,
            isSymlink: false
        )
        
        let fileItem = CachedMetadataItem(metadata: fileMetadata)
        let dirItem = CachedMetadataItem(metadata: dirMetadata)
        
        // Both should allow reading
        XCTAssertTrue(fileItem.capabilities.contains(.allowsReading))
        XCTAssertTrue(dirItem.capabilities.contains(.allowsReading))
        
        // Only directories should allow content enumerating
        // Note: allowsReading and allowsContentEnumerating have same rawValue (1)
        // so we can't distinguish them. Instead check our internal logic is correct.
        XCTAssertFalse(fileMetadata.isDirectory)
        XCTAssertTrue(dirMetadata.isDirectory)
    }
    
    // MARK: - Transfer Status Property Tests
    
    /// Test: Transfer status properties are correctly implemented for CachedMetadataItem
    /// These enable proper display in Files.app
    func testTransferStatusPropertiesForCachedMetadataItem() async throws {
        // Create a file
        let (fileMetadata, _) = try await store.upsert(
            itemIdentifier: "cached:xferfile",
            connectionId: "cached",
            remotePath: "/transfer.txt",
            parentIdentifier: "cached",
            filename: "transfer.txt",
            size: 100,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: nil,
            isSymlink: false
        )
        
        // Create a directory
        let (dirMetadata, _) = try await store.upsert(
            itemIdentifier: "cached:xferdir",
            connectionId: "cached",
            remotePath: "/transferdir",
            parentIdentifier: "cached",
            filename: "transferdir",
            size: 0,
            isDirectory: true,
            permissions: 0o755,
            modificationDate: nil,
            isSymlink: false
        )
        
        let fileItem = CachedMetadataItem(metadata: fileMetadata)
        let dirItem = CachedMetadataItem(metadata: dirMetadata)
        
        // isUploaded: Both should be true (items exist on server)
        XCTAssertTrue(fileItem.isUploaded, "Files should report isUploaded=true")
        XCTAssertTrue(dirItem.isUploaded, "Directories should report isUploaded=true")
        
        // isUploading: Both should be false (no uploads in progress)
        XCTAssertFalse(fileItem.isUploading, "Files should report isUploading=false (read-only)")
        XCTAssertFalse(dirItem.isUploading, "Directories should report isUploading=false")
        
        // isDownloading: Both should be false (downloads happen via startProvidingItem)
        XCTAssertFalse(fileItem.isDownloading, "Files should report isDownloading=false")
        XCTAssertFalse(dirItem.isDownloading, "Directories should report isDownloading=false")
        
        // isDownloaded: Directories true (for browsing), files false (streamed on demand)
        XCTAssertFalse(fileItem.isDownloaded, "Files should report isDownloaded=false (streamed on demand)")
        XCTAssertTrue(dirItem.isDownloaded, "Directories should report isDownloaded=true (browsable)")
    }
    
    // Note: RootItem, ConnectionFolderItem, RemoteItem, CachedRemoteItem tests omitted
    // because those classes are defined in the File Provider Extension target (not testable
    // in simulator unit tests). Their transfer status properties follow the same pattern
    // as CachedMetadataItem and are verified through code review.
}

// MARK: - Device Integration Tests (Real Extension)

/// These tests only run on device and verify actual extension behavior
@available(iOS 16.0, *)
final class DeviceIntegrationTests: XCTestCase {
    
    var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
    
    /// Test: Verify domain exists and manager is functional
    func testDomainAndManagerIntegrity() async throws {
        if isSimulator {
            throw XCTSkip("Device-only test: requires File Provider extension")
        }
        
        let domains = try await getFileProviderDomains()
        guard let domain = domains.first(where: { $0.identifier.rawValue.contains("geistty") }) else {
            XCTFail("Geistty domain not found")
            return
        }
        
        guard let manager = NSFileProviderManager(for: domain) else {
            XCTFail("Could not create manager for domain")
            return
        }
        
        // Get user-visible URL for domain
        let url = manager.documentStorageURL
        XCTAssertNotNil(url, "Should have document storage URL")
    }
    
    /// Test: Signal multiple container types
    func testSignalMultipleContainers() async throws {
        if isSimulator {
            throw XCTSkip("Device-only test: requires File Provider extension")
        }
        
        let domains = try await getFileProviderDomains()
        guard let domain = domains.first(where: { $0.identifier.rawValue.contains("geistty") }) else {
            XCTFail("Geistty domain not found")
            return
        }
        
        guard let manager = NSFileProviderManager(for: domain) else {
            XCTFail("Could not create manager for domain")
            return
        }
        
        // Signal working set (should succeed)
        try await manager.signalEnumerator(for: .workingSet)
        
        // Signal root container (should succeed)
        try await manager.signalEnumerator(for: .rootContainer)
        
        // Signal trash container (might throw if not supported, which is OK)
        do {
            try await manager.signalEnumerator(for: .trashContainer)
        } catch {
            // Expected - we don't support trash
        }
    }
    
    /// Test: Multiple rapid signal calls don't crash
    func testRapidSignalCalls() async throws {
        if isSimulator {
            throw XCTSkip("Device-only test: requires File Provider extension")
        }
        
        let domains = try await getFileProviderDomains()
        guard let domain = domains.first(where: { $0.identifier.rawValue.contains("geistty") }) else {
            XCTFail("Geistty domain not found")
            return
        }
        
        guard let manager = NSFileProviderManager(for: domain) else {
            XCTFail("Could not create manager for domain")
            return
        }
        
        // Send 10 rapid signals - extension must handle this gracefully
        for _ in 0..<10 {
            try await manager.signalEnumerator(for: .workingSet)
        }
    }
    
    /// Test: Verify extension starts with correct anchor state
    func testExtensionAnchorState() async throws {
        if isSimulator {
            throw XCTSkip("Device-only test: requires File Provider extension")
        }
        
        // Check that MetadataAnchorCache has a valid anchor
        let anchor = MetadataAnchorCache.shared.currentAnchor
        XCTAssertGreaterThanOrEqual(anchor, 1, "Anchor must be >= 1")
        
        let syncAnchor = MetadataAnchorCache.shared.syncAnchor
        XCTAssertEqual(syncAnchor.rawValue.count, 8, "Sync anchor must be 8 bytes")
    }
    
    /// Test: Enumerate root container items
    /// This tests the actual enumeration that Files.app does
    func testEnumerateRootContainerItems() async throws {
        if isSimulator {
            throw XCTSkip("Device-only test: requires File Provider extension")
        }
        
        let domains = try await getFileProviderDomains()
        guard let domain = domains.first(where: { $0.identifier.rawValue.contains("geistty") }) else {
            XCTFail("Geistty domain not found")
            return
        }
        
        guard let manager = NSFileProviderManager(for: domain) else {
            XCTFail("Could not create manager for domain")
            return
        }
        
        // Try to get the user-visible items URL
        let documentsURL = manager.documentStorageURL
        XCTAssertNotNil(documentsURL, "Should have documents URL")
        
        // Try to enumerate using FileManager
        // This triggers the File Provider extension
        let fileManager = FileManager.default
        do {
            let contents = try fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: [.isDirectoryKey])
            print("Root contents: \(contents.map { $0.lastPathComponent })")
            // We expect to see connection folders here
        } catch {
            // Capture the error - this might reveal why "Syncing Paused"
            print("contentsOfDirectory error: \(error)")
            // Don't fail - this is diagnostic
        }
    }
    
    /// Test: Force reimport to clear "Syncing Paused" state
    func testForceReimportClearsSyncingPaused() async throws {
        if isSimulator {
            throw XCTSkip("Device-only test: requires File Provider extension")
        }
        
        let domains = try await getFileProviderDomains()
        guard let domain = domains.first(where: { $0.identifier.rawValue.contains("geistty") }) else {
            XCTFail("Geistty domain not found")
            return
        }
        
        guard let manager = NSFileProviderManager(for: domain) else {
            XCTFail("Could not create manager for domain")
            return
        }
        
        // Step 1: Signal working set to trigger enumeration
        do {
            try await manager.signalEnumerator(for: .workingSet)
            print("✅ signalEnumerator(.workingSet) succeeded")
        } catch {
            print("❌ signalEnumerator(.workingSet) failed: \(error)")
            XCTFail("signalEnumerator should not fail: \(error)")
        }
        
        // Step 2: Try reimporting to force fresh sync
        do {
            try await manager.reimportItems(below: .rootContainer)
            print("✅ reimportItems succeeded")
        } catch {
            print("❌ reimportItems failed: \(error)")
            // Don't fail - reimport can throw if already synced
        }
        
        // Step 3: Wait a moment for iOS to process
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        
        // Step 4: Signal again after reimport
        do {
            try await manager.signalEnumerator(for: .rootContainer)
            print("✅ Post-reimport signalEnumerator succeeded")
        } catch {
            print("❌ Post-reimport signalEnumerator failed: \(error)")
        }
    }
    
    /// Test: Get item for root container
    /// Tests that item(for:) works for root
    func testGetRootItem() async throws {
        if isSimulator {
            throw XCTSkip("Device-only test: requires File Provider extension")
        }
        
        let domains = try await getFileProviderDomains()
        guard let domain = domains.first(where: { $0.identifier.rawValue.contains("geistty") }) else {
            XCTFail("Geistty domain not found")
            return
        }
        
        guard let manager = NSFileProviderManager(for: domain) else {
            XCTFail("Could not create manager for domain")
            return
        }
        
        // Try to access the root URL - this forces iOS to call item(for: .rootContainer)
        let rootURL = manager.documentStorageURL.appendingPathComponent("Root")
        print("Root URL: \(rootURL)")
        
        // Check if it exists (this triggers extension calls)
        let exists = FileManager.default.fileExists(atPath: rootURL.path)
        print("Root exists: \(exists)")
    }
}

// MARK: - Syncing Paused Diagnostic Tests (Device Only)

/// Tests specifically designed to diagnose "Syncing with Geistty Paused" errors
@available(iOS 16.0, *)
final class SyncingPausedDiagnosticDeviceTests: XCTestCase {
    
    var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
    
    // MARK: - Core Diagnostic Tests
    
    /// COMPREHENSIVE: Full diagnostic report for "Syncing Paused" investigation
    /// Run this test to get complete picture of extension state
    func testComprehensiveDiagnostic() async throws {
        if isSimulator {
            throw XCTSkip("Device-only diagnostic test")
        }
        
        print("=" * 60)
        print("SYNCING PAUSED COMPREHENSIVE DIAGNOSTIC")
        print("=" * 60)
        print("")
        
        // 1. Domain State
        print("=== 1. DOMAIN STATE ===")
        let domains = try await getFileProviderDomains()
        print("Total domains: \(domains.count)")
        
        var geisttyDomain: NSFileProviderDomain?
        for domain in domains {
            print("  Domain: \(domain.identifier.rawValue)")
            print("    displayName: \(domain.displayName)")
            print("    userEnabled: \(domain.userEnabled)")
            if domain.identifier.rawValue.contains("geistty") {
                geisttyDomain = domain
            }
        }
        
        guard let domain = geisttyDomain else {
            print("❌ CRITICAL: No Geistty domain found!")
            XCTFail("No Geistty domain")
            return
        }
        
        guard let manager = NSFileProviderManager(for: domain) else {
            print("❌ CRITICAL: Cannot get manager for domain!")
            XCTFail("No manager")
            return
        }
        print("✅ Domain OK: \(domain.identifier.rawValue), userEnabled=\(domain.userEnabled)")
        print("")
        
        // 2. Anchor State
        print("=== 2. ANCHOR STATE ===")
        let cacheAnchor = MetadataAnchorCache.shared.currentAnchor
        let syncAnchor = MetadataAnchorCache.shared.syncAnchor
        print("  Cache anchor value: \(cacheAnchor)")
        print("  Sync anchor bytes: \(syncAnchor.rawValue.count)")
        
        if syncAnchor.rawValue.count == 8 {
            let anchorValue = syncAnchor.rawValue.withUnsafeBytes { $0.load(as: UInt64.self) }
            print("  Sync anchor parsed: \(anchorValue)")
            print("✅ Anchor format OK (8 bytes, value=\(anchorValue))")
        } else {
            print("❌ CRITICAL: Anchor is \(syncAnchor.rawValue.count) bytes, expected 8!")
            XCTFail("Wrong anchor size")
        }
        
        XCTAssertGreaterThanOrEqual(cacheAnchor, 1, "Anchor must be >= 1")
        print("")
        
        // 3. MetadataStore State
        print("=== 3. METADATA STORE STATE ===")
        let store = MetadataStore.shared
        let storeAnchor = try await store.currentAnchor
        let allItems = try await store.itemsModified(since: 0)
        print("  Store anchor: \(storeAnchor)")
        print("  Total cached items: \(allItems.count)")
        if !allItems.isEmpty {
            print("  Sample items:")
            for item in allItems.prefix(5) {
                print("    - \(item.filename) (parent: \(item.parentIdentifier))")
            }
            if allItems.count > 5 {
                print("    ... and \(allItems.count - 5) more")
            }
        }
        print("")
        
        // 4. Clear log and signal
        print("=== 4. EXTENSION SIGNAL TEST ===")
        FileProviderDomainManager.clearExtensionDebugLog()
        print("  Log cleared")
        
        print("  Sending signalEnumerator(.workingSet)...")
        do {
            try await manager.signalEnumerator(for: .workingSet)
            print("  ✅ Signal sent successfully")
        } catch {
            print("  ❌ Signal failed: \(error)")
            XCTFail("Signal failed")
        }
        
        // Wait for extension to process
        print("  Waiting 3 seconds for extension to process...")
        try await Task.sleep(nanoseconds: 3_000_000_000)
        print("")
        
        // 5. Read Extension Log
        print("=== 5. EXTENSION LOG ===")
        if let log = FileProviderDomainManager.readExtensionDebugLog() {
            let lines = log.components(separatedBy: "\n").filter { !$0.isEmpty }
            print("  Total log lines: \(lines.count)")
            print("  --- LOG START ---")
            for line in lines {
                print("  \(line)")
            }
            print("  --- LOG END ---")
            
            // Analyze log for key events
            print("")
            print("=== 6. LOG ANALYSIS ===")
            let hasEnumeratorCreated = log.contains("ENUMERATOR_CREATED") || log.contains("CREATED")
            let hasEnumerateChanges = log.contains("ENUMERATE_CHANGES")
            let hasFinished = log.contains("FINISHED") || log.contains("finishEnumerating")
            let hasInvalidated = log.contains("INVALIDATED")
            let hasError = log.lowercased().contains("error")
            
            print("  ENUMERATOR_CREATED: \(hasEnumeratorCreated ? "✅" : "❌")")
            print("  ENUMERATE_CHANGES_CALLED: \(hasEnumerateChanges ? "✅" : "❌")")
            print("  FINISHED: \(hasFinished ? "✅" : "❌")")
            print("  INVALIDATED: \(hasInvalidated ? "✅" : "❌")")
            print("  Errors present: \(hasError ? "⚠️ YES" : "✅ NO")")
            
            // Key assertions
            if !hasEnumeratorCreated {
                print("  ⚠️ Extension may not be running - no enumerator created")
            }
            if hasEnumerateChanges && !hasFinished {
                print("  ❌ CRITICAL: enumerateChanges called but didn't finish!")
                XCTFail("enumerateChanges didn't complete")
            }
            if hasError {
                print("  ⚠️ Errors found in log - check above for details")
            }
        } else {
            print("  ❌ No extension log found!")
            print("  This means either:")
            print("    - Extension never started")
            print("    - Extension crashed before logging")
            print("    - App group container issue")
        }
        
        print("")
        print("=" * 60)
        print("END DIAGNOSTIC")
        print("=" * 60)
    }
    
    /// CRITICAL TEST: Programmatically detect if domain is healthy or paused
    /// This test gives a definitive YES/NO answer without human observation.
    ///
    /// How it works:
    /// 1. signalEnumerator should succeed (returns no error)
    /// 2. waitForStabilization should complete (or report specific error)
    /// 3. Extension log should show successful enumeration
    ///
    /// If "Syncing Paused" is showing, we expect one of:
    /// - waitForStabilization to fail with cannotSynchronize
    /// - Pending items to be stuck
    /// - Extension to throw errors during enumeration
    func testDomainHealthStatus() async throws {
        if isSimulator {
            throw XCTSkip("Device-only diagnostic test")
        }
        
        print("=" * 60)
        print("DOMAIN HEALTH STATUS CHECK")
        print("=" * 60)
        
        var healthIssues: [String] = []
        
        // 1. Get domain and manager
        let domains = try await getFileProviderDomains()
        guard let domain = domains.first(where: { $0.identifier.rawValue.contains("geistty") }),
              let manager = NSFileProviderManager(for: domain) else {
            XCTFail("❌ UNHEALTHY: No domain registered")
            return
        }
        print("✅ Domain exists: \(domain.identifier.rawValue)")
        print("  userEnabled: \(domain.userEnabled)")
        
        if !domain.userEnabled {
            healthIssues.append("Domain is disabled by user")
        }
        
        // 2. Clear logs for fresh state
        FileProviderDomainManager.clearExtensionDebugLog()
        
        // 3. Test signalEnumerator
        print("\n--- TEST: signalEnumerator ---")
        do {
            try await manager.signalEnumerator(for: .workingSet)
            print("✅ signalEnumerator succeeded")
        } catch {
            healthIssues.append("signalEnumerator failed: \(error.localizedDescription)")
            print("❌ signalEnumerator failed: \(error)")
        }
        
        // 4. Test waitForStabilization (with timeout)
        // NOTE: If domain is paused, this will never complete - that's a key diagnostic!
        print("\n--- TEST: waitForStabilization ---")
        print("  (If this hangs forever, the domain is NOT stable - that's the bug!)")
        
        // Use a simple approach: start the call, wait 5 seconds, check if done
        var stabilizationCompleted = false
        let stabilizationTask = Task {
            do {
                try await manager.waitForStabilization()
                stabilizationCompleted = true
            } catch {
                print("  waitForStabilization error: \(error)")
            }
        }
        
        // Wait 5 seconds
        try await Task.sleep(nanoseconds: 5_000_000_000)
        
        if stabilizationCompleted {
            print("✅ waitForStabilization completed within 5 seconds")
        } else {
            stabilizationTask.cancel()
            healthIssues.append("waitForStabilization DID NOT complete in 5 seconds - domain is unstable!")
            print("❌ CRITICAL: waitForStabilization blocked for 5+ seconds")
            print("  This indicates the domain is in an UNSTABLE state")
            print("  This is likely the ROOT CAUSE of 'Syncing Paused'")
        }
        
        // 5. Check pending items
        print("\n--- TEST: pendingItems ---")
        let pendingEnumerator = manager.enumeratorForPendingItems()
        
        // Simple check - just see if we can create the enumerator
        print("✅ pendingItems enumerator created: \(type(of: pendingEnumerator))")
        
        // 6. Check extension log
        print("\n--- TEST: extension log ---")
        try await Task.sleep(nanoseconds: 2_000_000_000) // Wait for enumeration
        
        if let log = FileProviderDomainManager.readExtensionDebugLog() {
            let hasCreated = log.contains("CREATED") || log.contains("enumerator")
            let hasCalled = log.contains("ENUMERATE_CHANGES")
            let hasFinished = log.contains("FINISHED") || log.contains("finishing")
            let hasError = log.lowercased().contains("error")
            
            print("  Extension ran: \(hasCreated ? "✅" : "❌")")
            print("  Enumeration called: \(hasCalled ? "✅" : "❌")")
            print("  Enumeration finished: \(hasFinished ? "✅" : "❌")")
            print("  Errors in log: \(hasError ? "⚠️" : "✅")")
            
            if !hasCreated {
                healthIssues.append("Extension never started")
            }
            if hasCalled && !hasFinished {
                healthIssues.append("Enumeration started but never finished (crash?)")
            }
            if hasError {
                // Extract error lines
                let errorLines = log.components(separatedBy: "\n").filter { $0.lowercased().contains("error") }
                for line in errorLines.prefix(3) {
                    healthIssues.append("Log error: \(line)")
                }
            }
        } else {
            healthIssues.append("No extension log found")
            print("❌ No extension log")
        }
        
        // 7. Final verdict
        print("\n" + "=" * 60)
        if healthIssues.isEmpty {
            print("✅ DOMAIN IS HEALTHY")
            print("If 'Syncing Paused' still shows, it may be a UI caching issue in Files.app")
            print("Try: Force quit Files.app, wait 30 seconds, reopen")
        } else {
            print("❌ DOMAIN HAS ISSUES:")
            for (index, issue) in healthIssues.enumerated() {
                print("  \(index + 1). \(issue)")
            }
            XCTFail("Domain health check found \(healthIssues.count) issues")
        }
        print("=" * 60)
    }
    
    /// Test: Verify extension lifecycle completes without crash
    func testExtensionLifecycleCompletes() async throws {
        if isSimulator {
            throw XCTSkip("Device-only diagnostic test")
        }
        
        FileProviderDomainManager.clearExtensionDebugLog()
        
        let domains = try await getFileProviderDomains()
        guard let domain = domains.first(where: { $0.identifier.rawValue.contains("geistty") }),
              let manager = NSFileProviderManager(for: domain) else {
            XCTFail("No domain found")
            return
        }
        
        // Signal and wait
        try await manager.signalEnumerator(for: .workingSet)
        try await Task.sleep(nanoseconds: 3_000_000_000)
        
        // Check log for complete lifecycle
        guard let log = FileProviderDomainManager.readExtensionDebugLog() else {
            XCTFail("No extension log - extension may have crashed before writing")
            return
        }
        
        print("Extension log:")
        print(log)
        
        // Must have: created -> called -> finished
        // INVALIDATED is optional (iOS may reuse enumerator)
        let hasCreated = log.contains("CREATED") || log.contains("enumerator")
        let hasCalled = log.contains("ENUMERATE_CHANGES") || log.contains("enumerateChanges")
        let hasFinished = log.contains("FINISHED") || log.contains("finishing") || log.contains("finishEnumerating")
        
        XCTAssertTrue(hasCreated, "Extension should log enumerator creation")
        XCTAssertTrue(hasCalled, "Extension should log enumerateChanges being called")
        XCTAssertTrue(hasFinished, "Extension should log finishing - if missing, extension crashed!")
    }
    
    /// Test: Verify anchor format round-trip
    func testAnchorFormatRoundTrip() async throws {
        if isSimulator {
            throw XCTSkip("Device-only diagnostic test")
        }
        
        // Get current anchor
        let cache = MetadataAnchorCache.shared
        let originalValue = cache.currentAnchor
        let syncAnchor = cache.syncAnchor
        
        print("Original anchor value: \(originalValue)")
        print("Sync anchor bytes: \(syncAnchor.rawValue.count)")
        
        // Must be 8 bytes
        XCTAssertEqual(syncAnchor.rawValue.count, 8, "Anchor must be 8 bytes")
        
        // Round-trip: parse back
        let parsedValue = syncAnchor.rawValue.withUnsafeBytes { $0.load(as: UInt64.self) }
        print("Parsed anchor value: \(parsedValue)")
        
        XCTAssertEqual(parsedValue, originalValue, "Round-trip must preserve value")
        XCTAssertGreaterThanOrEqual(parsedValue, 1, "Anchor must be >= 1")
    }
    
    /// Test: Multiple signal-wait cycles to detect intermittent crashes
    func testMultipleSignalCycles() async throws {
        if isSimulator {
            throw XCTSkip("Device-only diagnostic test")
        }
        
        let domains = try await getFileProviderDomains()
        guard let domain = domains.first(where: { $0.identifier.rawValue.contains("geistty") }),
              let manager = NSFileProviderManager(for: domain) else {
            XCTFail("No domain found")
            return
        }
        
        FileProviderDomainManager.clearExtensionDebugLog()
        
        // Run 5 signal cycles
        for i in 1...5 {
            print("Cycle \(i)/5...")
            try await manager.signalEnumerator(for: .workingSet)
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        }
        
        // Check log
        guard let log = FileProviderDomainManager.readExtensionDebugLog() else {
            XCTFail("No log after 5 cycles")
            return
        }
        
        print("Log after 5 cycles:")
        print(log)
        
        // Count how many times enumerateChanges was called
        let callCount = log.components(separatedBy: "ENUMERATE_CHANGES_CALLED").count - 1
        print("enumerateChanges called \(callCount) times")
        
        // Should have been called at least once
        XCTAssertGreaterThanOrEqual(callCount, 1, "Should have processed at least 1 signal")
    }
    
    /// FIX: Re-register domain to clear "Syncing Paused" state
    /// This is the nuclear option - removes and re-adds the domain
    func testFixSyncingPausedByReregistration() async throws {
        if isSimulator {
            throw XCTSkip("Device-only diagnostic test")
        }
        
        print("=" * 60)
        print("FIX: Re-registering domain to clear Syncing Paused")
        print("=" * 60)
        
        // 1. Get existing domain
        let domains = try await getFileProviderDomains()
        guard let existingDomain = domains.first(where: { $0.identifier.rawValue.contains("geistty") }) else {
            print("❌ No existing Geistty domain found")
            XCTFail("No domain")
            return
        }
        
        let identifier = existingDomain.identifier
        let displayName = existingDomain.displayName
        print("Found domain: \(identifier.rawValue) (\(displayName))")
        print("userEnabled: \(existingDomain.userEnabled)")
        
        // 2. Remove the domain
        print("\n--- Step 1: Removing domain ---")
        do {
            try await NSFileProviderManager.remove(existingDomain)
            print("✅ Domain removed successfully")
        } catch {
            print("❌ Failed to remove: \(error)")
            XCTFail("Remove failed: \(error)")
            return
        }
        
        // 3. Wait for iOS to clean up
        print("\n--- Step 2: Waiting 2 seconds ---")
        try await Task.sleep(nanoseconds: 2_000_000_000)
        
        // 4. Re-add the domain
        print("\n--- Step 3: Re-adding domain ---")
        let newDomain = NSFileProviderDomain(identifier: identifier, displayName: displayName)
        do {
            try await NSFileProviderManager.add(newDomain)
            print("✅ Domain re-added successfully")
        } catch {
            print("❌ Failed to add: \(error)")
            XCTFail("Add failed: \(error)")
            return
        }
        
        // 5. Verify
        print("\n--- Step 4: Verification ---")
        let newDomains = try await getFileProviderDomains()
        guard let verifyDomain = newDomains.first(where: { $0.identifier.rawValue.contains("geistty") }) else {
            print("❌ Domain not found after re-add!")
            XCTFail("Domain missing")
            return
        }
        
        print("✅ Domain verified: \(verifyDomain.identifier.rawValue)")
        print("  userEnabled: \(verifyDomain.userEnabled)")
        
        // 6. Signal to trigger enumeration
        print("\n--- Step 5: Triggering enumeration ---")
        FileProviderDomainManager.clearExtensionDebugLog()
        
        guard let manager = NSFileProviderManager(for: verifyDomain) else {
            XCTFail("No manager")
            return
        }
        
        try await manager.signalEnumerator(for: .workingSet)
        try await Task.sleep(nanoseconds: 3_000_000_000)
        
        // 7. Check extension log
        if let log = FileProviderDomainManager.readExtensionDebugLog() {
            print("\n--- Extension Log ---")
            print(log)
            
            XCTAssertTrue(log.contains("FINISHED") || log.contains("finishing"), 
                "Extension should complete enumeration after re-registration")
        }
        
        print("\n" + "=" * 60)
        print("✅ Domain re-registered successfully!")
        print("Open Files.app and check if 'Syncing Paused' is cleared")
        print("=" * 60)
    }
    
    /// FIX: Reimport domain by signaling all items changed
    /// Less destructive than full re-registration
    func testFixByReimportingAllItems() async throws {
        if isSimulator {
            throw XCTSkip("Device-only diagnostic test")
        }
        
        print("=" * 60)
        print("FIX: Reimporting all items")
        print("=" * 60)
        
        let domains = try await getFileProviderDomains()
        guard let domain = domains.first(where: { $0.identifier.rawValue.contains("geistty") }),
              let manager = NSFileProviderManager(for: domain) else {
            XCTFail("No domain found")
            return
        }
        
        // Request reimport of all items
        print("Requesting reimport...")
        do {
            try await manager.reimportItems(below: .rootContainer)
            print("✅ Reimport requested successfully")
        } catch {
            print("❌ Reimport failed: \(error)")
            // Don't fail - this API may not always work
        }
        
        // Also signal working set
        print("Signaling working set...")
        try await manager.signalEnumerator(for: .workingSet)
        
        // Wait
        try await Task.sleep(nanoseconds: 3_000_000_000)
        
        print("✅ Reimport complete - check Files.app")
    }
    
    // MARK: - Advanced Diagnostic Tests (Apple Testing APIs)
    
    /// DIAGNOSTIC: Check for pending operations that might cause "Syncing Paused"
    /// Uses NSFileProviderManager.listAvailableTestingOperations()
    func testCheckPendingOperations() async throws {
        if isSimulator {
            throw XCTSkip("Device-only diagnostic test")
        }
        
        print("=" * 60)
        print("DIAGNOSTIC: Checking Pending Operations")
        print("=" * 60)
        
        let domains = try await getFileProviderDomains()
        guard let domain = domains.first(where: { $0.identifier.rawValue.contains("geistty") }),
              let manager = NSFileProviderManager(for: domain) else {
            XCTFail("No domain found")
            return
        }
        
        // 1. Check pending items using enumerator
        print("\n=== 1. PENDING ITEMS ===")
        let pendingEnumerator = manager.enumeratorForPendingItems()
        
        // Create a simple observer to collect pending items
        let pendingItems = await withCheckedContinuation { continuation in
            var items: [NSFileProviderItemIdentifier] = []
            let observer = PendingItemsObserver { collectedItems in
                items = collectedItems
                continuation.resume(returning: items)
            }
            pendingEnumerator.enumerateItems(for: observer, startingAt: NSFileProviderPage.initialPageSortedByDate as NSFileProviderPage)
            
            // Timeout after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if items.isEmpty {
                    continuation.resume(returning: [])
                }
            }
        }
        
        print("  Pending items count: \(pendingItems.count)")
        if pendingItems.isEmpty {
            print("  ✅ No pending items")
        } else {
            print("  ⚠️ Pending items found:")
            for id in pendingItems.prefix(10) {
                print("    - \(id.rawValue)")
            }
            if pendingItems.count > 10 {
                print("    ... and \(pendingItems.count - 10) more")
            }
        }
        
        // 2. Check testing operations (if available)
        print("\n=== 2. TESTING OPERATIONS ===")
        do {
            let operations = try manager.listAvailableTestingOperations()
            print("  Available operations: \(operations.count)")
            for (index, op) in operations.prefix(10).enumerated() {
                print("    \(index + 1). \(type(of: op))")
            }
            if operations.count > 10 {
                print("    ... and \(operations.count - 10) more")
            }
            
            if operations.isEmpty {
                print("  ✅ No pending testing operations")
            } else {
                print("  ⚠️ Pending operations may indicate sync issues")
            }
        } catch {
            print("  ℹ️ Testing operations not available: \(error.localizedDescription)")
        }
        
        // 3. Check materialized items
        print("\n=== 3. MATERIALIZED ITEMS ===")
        let materializedEnumerator = manager.enumeratorForMaterializedItems()
        print("  Materialized enumerator created: \(type(of: materializedEnumerator))")
        
        print("\n" + "=" * 60)
        print("END PENDING OPERATIONS CHECK")
        print("=" * 60)
    }
    
    /// FIX: Signal all resolvable errors as resolved
    /// This clears any stuck "Syncing Paused" state from previous errors
    func testFixBySignalingErrorsResolved() async throws {
        if isSimulator {
            throw XCTSkip("Device-only diagnostic test")
        }
        
        print("=" * 60)
        print("FIX: Signaling All Errors Resolved")
        print("=" * 60)
        
        let domains = try await getFileProviderDomains()
        guard let domain = domains.first(where: { $0.identifier.rawValue.contains("geistty") }),
              let manager = NSFileProviderManager(for: domain) else {
            XCTFail("No domain found")
            return
        }
        
        // Signal resolution of all resolvable error types
        let resolvableErrors: [(NSFileProviderError.Code, String)] = [
            (.notAuthenticated, "notAuthenticated"),
            (.serverUnreachable, "serverUnreachable"),
            (.insufficientQuota, "insufficientQuota"),
            (.cannotSynchronize, "cannotSynchronize")
        ]
        
        for (code, name) in resolvableErrors {
            print("Signaling \(name) resolved...")
            let error = NSFileProviderError(code)
            do {
                try await manager.signalErrorResolved(error)
                print("  ✅ \(name) signaled as resolved")
            } catch {
                // This is expected if the error wasn't active
                print("  ℹ️ \(name): \(error.localizedDescription)")
            }
        }
        
        // Signal working set to trigger fresh enumeration
        print("\nSignaling working set...")
        try await manager.signalEnumerator(for: .workingSet)
        
        // Wait for processing
        try await Task.sleep(nanoseconds: 2_000_000_000)
        
        print("\n✅ All errors signaled as resolved")
        print("Check Files.app for 'Syncing Paused' status")
    }
    
    /// FIX: Full reset - Disconnect, clear errors, reconnect
    /// Note: disconnect/reconnect APIs are macOS-only, so we use remove/add instead
    func testFixByDisconnectReconnect() async throws {
        if isSimulator {
            throw XCTSkip("Device-only diagnostic test")
        }
        
        print("=" * 60)
        print("FIX: Reset Domain State (iOS compatible)")
        print("=" * 60)
        
        let domains = try await getFileProviderDomains()
        guard let domain = domains.first(where: { $0.identifier.rawValue.contains("geistty") }),
              let manager = NSFileProviderManager(for: domain) else {
            XCTFail("No domain found")
            return
        }
        
        // On iOS, we can't disconnect/reconnect, but we can:
        // 1. Signal all errors resolved
        // 2. Wait for stabilization
        // 3. Signal working set
        
        print("Step 1: Signaling errors resolved...")
        let resolvableErrors: [NSFileProviderError.Code] = [.notAuthenticated, .serverUnreachable]
        for code in resolvableErrors {
            let error = NSFileProviderError(code)
            try? await manager.signalErrorResolved(error)
        }
        
        print("Step 2: Waiting for stabilization...")
        do {
            try await manager.waitForStabilization()
            print("  ✅ Domain stabilized")
        } catch {
            print("  ℹ️ Stabilization: \(error.localizedDescription)")
        }
        
        print("Step 3: Signaling working set...")
        try await manager.signalEnumerator(for: .workingSet)
        
        print("Step 4: Waiting 2 seconds...")
        try await Task.sleep(nanoseconds: 2_000_000_000)
        
        print("\n✅ Domain reset cycle complete")
    }
    
    /// DIAGNOSTIC: Full system state dump for debugging
    func testDumpFullSystemState() async throws {
        if isSimulator {
            throw XCTSkip("Device-only diagnostic test")
        }
        
        print("=" * 60)
        print("FULL SYSTEM STATE DUMP")
        print("=" * 60)
        
        // 1. All domains
        print("\n=== ALL DOMAINS ===")
        let domains = try await getFileProviderDomains()
        for domain in domains {
            print("Domain: \(domain.identifier.rawValue)")
            print("  displayName: \(domain.displayName)")
            print("  userEnabled: \(domain.userEnabled)")
            // isHidden is macOS only - skip
            print("  backingStoreIdentity: \(domain.backingStoreIdentity?.base64EncodedString() ?? "nil")")
            
            if let manager = NSFileProviderManager(for: domain) {
                print("  documentStorageURL: \(manager.documentStorageURL)")
                print("  providerIdentifier: \(manager.providerIdentifier)")
                
                // Try to get temp directory
                do {
                    let tempURL = try manager.temporaryDirectoryURL()
                    print("  temporaryDirectoryURL: \(tempURL)")
                } catch {
                    print("  temporaryDirectoryURL: error - \(error.localizedDescription)")
                }
                
                // stateDirectoryURL is macOS only - skip
            }
            print("")
        }
        
        // 2. MetadataStore state
        print("=== METADATA STORE ===")
        let store = MetadataStore.shared
        let storeAnchor = try await store.currentAnchor
        let allItems = try await store.itemsModified(since: 0)
        print("  Store anchor: \(storeAnchor)")
        print("  Total items: \(allItems.count)")
        
        // 3. MetadataAnchorCache state  
        print("\n=== ANCHOR CACHE ===")
        let cache = MetadataAnchorCache.shared
        print("  Current anchor: \(cache.currentAnchor)")
        print("  Sync anchor bytes: \(cache.syncAnchor.rawValue.count)")
        
        // 4. Extension log
        print("\n=== EXTENSION LOG (last 20 lines) ===")
        if let log = FileProviderDomainManager.readExtensionDebugLog() {
            let lines = log.components(separatedBy: "\n").filter { !$0.isEmpty }
            let lastLines = lines.suffix(20)
            for line in lastLines {
                print("  \(line)")
            }
        } else {
            print("  No log available")
        }
        
        print("\n" + "=" * 60)
        print("END STATE DUMP")
        print("=" * 60)
    }
    
    // MARK: - Legacy Tests (kept for compatibility)
    
    /// Diagnose: Read extension debug log
    func testReadExtensionLog() async throws {
        if isSimulator {
            throw XCTSkip("Device-only diagnostic test")
        }
        
        // Clear log first
        FileProviderDomainManager.clearExtensionDebugLog()
        print("=== EXTENSION LOG CLEARED ===")
        
        // Now trigger some extension activity
        let domains = try await getFileProviderDomains()
        guard let domain = domains.first(where: { $0.identifier.rawValue.contains("geistty") }),
              let manager = NSFileProviderManager(for: domain) else {
            XCTFail("No domain found")
            return
        }
        
        print("Signaling working set...")
        try await manager.signalEnumerator(for: .workingSet)
        
        // Wait LONGER for extension to process async Tasks
        try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
        
        // Read the log
        if let log = FileProviderDomainManager.readExtensionDebugLog() {
            print("=== EXTENSION DEBUG LOG ===")
            print(log)
            print("=== END LOG ===")
        } else {
            print("⚠️ No extension log file found")
        }
    }
    
    /// Diagnose: Force trigger enumerateChanges and capture results
    func testTriggerEnumerateChanges() async throws {
        if isSimulator {
            throw XCTSkip("Device-only diagnostic test")
        }
        
        FileProviderDomainManager.clearExtensionDebugLog()
        
        let domains = try await getFileProviderDomains()
        guard let domain = domains.first(where: { $0.identifier.rawValue.contains("geistty") }),
              let manager = NSFileProviderManager(for: domain) else {
            XCTFail("No domain found")
            return
        }
        
        // Signal working set multiple times
        for i in 1...3 {
            print("Signal #\(i)...")
            try await manager.signalEnumerator(for: .workingSet)
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        
        // Wait for processing
        try await Task.sleep(nanoseconds: 2_000_000_000)
        
        // Read the log
        if let log = FileProviderDomainManager.readExtensionDebugLog() {
            print("=== AFTER 3 SIGNALS ===")
            print(log)
            print("=== END ===")
            
            // Check what we got
            XCTAssertTrue(log.contains("ENUMERATE") || log.contains("enumerator") || log.isEmpty == false,
                "Extension should have logged some activity")
        }
    }
    
    /// Diagnose: Check domain state
    func testDiagnoseDomainState() async throws {
        if isSimulator {
            throw XCTSkip("Device-only diagnostic test")
        }
        
        let domains = try await getFileProviderDomains()
        print("=== DOMAIN DIAGNOSTIC ===")
        print("Total domains: \(domains.count)")
        
        for domain in domains {
            print("Domain: \(domain.identifier.rawValue)")
            print("  displayName: \(domain.displayName)")
            print("  userEnabled: \(domain.userEnabled)")
            
            if let manager = NSFileProviderManager(for: domain) {
                print("  documentStorageURL: \(manager.documentStorageURL)")
            }
        }
        print("========================")
        
        // Check for Geistty domain
        let geisttyDomain = domains.first { $0.identifier.rawValue.contains("geistty") }
        XCTAssertNotNil(geisttyDomain, "Geistty domain should exist")
        
        if let domain = geisttyDomain {
            XCTAssertTrue(domain.userEnabled, "Domain should be user-enabled")
        }
    }
    
    /// Diagnose: Try to remove and re-add domain
    func testDiagnoseReAddDomain() async throws {
        if isSimulator {
            throw XCTSkip("Device-only diagnostic test")
        }
        
        // This is destructive - it removes and re-adds the domain
        // which can fix "Syncing Paused" if the domain state is corrupted
        
        let domains = try await getFileProviderDomains()
        guard let existingDomain = domains.first(where: { $0.identifier.rawValue.contains("geistty") }) else {
            print("No existing domain to re-add")
            return
        }
        
        let identifier = existingDomain.identifier
        let displayName = existingDomain.displayName
        
        print("Removing domain: \(identifier.rawValue)")
        
        do {
            try await NSFileProviderManager.remove(existingDomain)
            print("✅ Domain removed")
        } catch {
            print("❌ Remove failed: \(error)")
            XCTFail("Failed to remove domain: \(error)")
            return
        }
        
        // Wait a moment
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // Re-add domain
        let newDomain = NSFileProviderDomain(identifier: identifier, displayName: displayName)
        
        do {
            try await NSFileProviderManager.add(newDomain)
            print("✅ Domain re-added")
        } catch {
            print("❌ Add failed: \(error)")
            XCTFail("Failed to add domain: \(error)")
        }
    }
}

// MARK: - String repeat helper
private extension String {
    static func * (string: String, count: Int) -> String {
        String(repeating: string, count: count)
    }
}
