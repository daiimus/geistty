//
//  MetadataStoreTests.swift
//  Geistty
//
//  Unit tests for MetadataStore actor.
//  Tests CRUD operations, anchor-based change queries, and sync state.
//
//  To run: Add to a test target and run with XCTest
//

import Foundation
import XCTest
import FileProvider
@testable import Geistty

/// Unit tests for MetadataStore
final class MetadataStoreTests: XCTestCase {
    
    var store: MetadataStore!
    
    override func setUp() async throws {
        store = MetadataStore.shared
        // Clear all data before each test
        try await store.clearAll()
    }
    
    override func tearDown() async throws {
        // Clean up after each test
        try await store.clearAll()
    }
    
    // MARK: - Sync Anchor Tests
    
    func testInitialAnchorIsOne() async throws {
        // After clearAll(), anchor resets to 1 (not 0)
        // This is CRITICAL: anchor must be > 0 so enumerateChanges(from: 0) works
        let anchor = try await store.currentAnchor
        XCTAssertEqual(anchor, 1, "Initial anchor should be 1 (not 0) to support enumerateChanges from 0")
    }
    
    func testIncrementAnchor() async throws {
        let initial = try await store.currentAnchor
        XCTAssertEqual(initial, 1, "Initial anchor should be 1")
        
        let incremented = try await store.incrementAnchor()
        XCTAssertEqual(incremented, initial + 1, "Anchor should increment by 1")
        XCTAssertEqual(incremented, 2, "After one increment, anchor should be 2")
        
        let current = try await store.currentAnchor
        XCTAssertEqual(current, incremented, "Current anchor should match incremented value")
    }
    
    func testSyncAnchorSerialization() async throws {
        // After clearAll, anchor is 1
        // Increment 3 times: 1 -> 2 -> 3 -> 4
        _ = try await store.incrementAnchor()
        _ = try await store.incrementAnchor()
        _ = try await store.incrementAnchor()
        
        let anchor = try await store.currentSyncAnchor
        
        // Parse it back - should be 4 (started at 1 + 3 increments)
        let value = SyncState.anchorValue(from: anchor)
        XCTAssertEqual(value, 4, "Serialized anchor should parse back to 4 (1 + 3 increments)")
    }
    
    // MARK: - Item CRUD Tests
    
    func testUpsertNewItem() async throws {
        let (item, isNew) = try await store.upsert(
            itemIdentifier: "conn:test:path:/test.txt",
            connectionId: "test",
            remotePath: "/test.txt",
            parentIdentifier: "conn:test",
            filename: "test.txt",
            size: 100,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: Date(),
            isSymlink: false
        )
        
        XCTAssertTrue(isNew, "Item should be new")
        XCTAssertEqual(item.filename, "test.txt")
        XCTAssertEqual(item.size, 100)
        XCTAssertFalse(item.isDirectory)
        XCTAssertTrue(item.createdAtAnchor > 0, "Created anchor should be set")
        XCTAssertEqual(item.createdAtAnchor, item.modifiedAtAnchor, "Create and modify anchors should match for new item")
    }
    
    func testUpsertExistingItem() async throws {
        // Create initial item
        let (_, _) = try await store.upsert(
            itemIdentifier: "conn:test:path:/test.txt",
            connectionId: "test",
            remotePath: "/test.txt",
            parentIdentifier: "conn:test",
            filename: "test.txt",
            size: 100,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: Date(),
            isSymlink: false
        )
        
        let anchorAfterCreate = try await store.currentAnchor
        
        // Update the item
        let (updated, isNew) = try await store.upsert(
            itemIdentifier: "conn:test:path:/test.txt",
            connectionId: "test",
            remotePath: "/test.txt",
            parentIdentifier: "conn:test",
            filename: "test.txt",
            size: 200,  // Changed size
            isDirectory: false,
            permissions: 0o644,
            modificationDate: Date(),
            isSymlink: false
        )
        
        XCTAssertFalse(isNew, "Item should not be new on update")
        XCTAssertEqual(updated.size, 200, "Size should be updated")
        XCTAssertGreaterThan(updated.modifiedAtAnchor, anchorAfterCreate, "Modified anchor should increase")
    }
    
    func testGetItemById() async throws {
        let itemId = "conn:test:path:/test.txt"
        
        // Item doesn't exist yet
        let notFound = try await store.item(id: itemId)
        XCTAssertNil(notFound, "Item should not exist yet")
        
        // Create item
        let (_, _) = try await store.upsert(
            itemIdentifier: itemId,
            connectionId: "test",
            remotePath: "/test.txt",
            parentIdentifier: "conn:test",
            filename: "test.txt",
            size: 100,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: nil,
            isSymlink: false
        )
        
        // Now it should exist
        let found = try await store.item(id: itemId)
        XCTAssertNotNil(found, "Item should exist after creation")
        XCTAssertEqual(found?.filename, "test.txt")
    }
    
    func testMarkDeleted() async throws {
        let itemId = "conn:test:path:/test.txt"
        
        // Create item
        let (_, _) = try await store.upsert(
            itemIdentifier: itemId,
            connectionId: "test",
            remotePath: "/test.txt",
            parentIdentifier: "conn:test",
            filename: "test.txt",
            size: 100,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: nil,
            isSymlink: false
        )
        
        // Mark as deleted
        let deleteAnchor = try await store.markDeleted(id: itemId)
        XCTAssertGreaterThan(deleteAnchor, 0, "Delete anchor should be set")
        
        // Should not be found via normal query
        let found = try await store.item(id: itemId)
        XCTAssertNil(found, "Deleted item should not be found")
    }
    
    // MARK: - Change Query Tests
    
    func testItemsModifiedSince() async throws {
        // Get initial anchor
        let initialAnchor = try await store.currentAnchor
        
        // Create some items
        let (_, _) = try await store.upsert(
            itemIdentifier: "conn:test:path:/file1.txt",
            connectionId: "test",
            remotePath: "/file1.txt",
            parentIdentifier: "conn:test",
            filename: "file1.txt",
            size: 100,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: nil,
            isSymlink: false
        )
        
        let anchorAfterFile1 = try await store.currentAnchor
        
        let (_, _) = try await store.upsert(
            itemIdentifier: "conn:test:path:/file2.txt",
            connectionId: "test",
            remotePath: "/file2.txt",
            parentIdentifier: "conn:test",
            filename: "file2.txt",
            size: 200,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: nil,
            isSymlink: false
        )
        
        // Query changes since initial anchor - should find both
        let allChanges = try await store.itemsModified(since: initialAnchor)
        XCTAssertEqual(allChanges.count, 2, "Should find 2 items modified since initial anchor")
        
        // Query changes since file1 - should find only file2
        let recentChanges = try await store.itemsModified(since: anchorAfterFile1)
        XCTAssertEqual(recentChanges.count, 1, "Should find 1 item modified since file1")
        XCTAssertEqual(recentChanges.first?.filename, "file2.txt")
    }
    
    func testDeletionsSince() async throws {
        // Create items
        let (_, _) = try await store.upsert(
            itemIdentifier: "conn:test:path:/file1.txt",
            connectionId: "test",
            remotePath: "/file1.txt",
            parentIdentifier: "conn:test",
            filename: "file1.txt",
            size: 100,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: nil,
            isSymlink: false
        )
        
        let anchorBeforeDelete = try await store.currentAnchor
        
        // Delete one
        _ = try await store.markDeleted(id: "conn:test:path:/file1.txt")
        
        // Query deletions
        let deletions = try await store.deletions(since: anchorBeforeDelete)
        XCTAssertEqual(deletions.count, 1, "Should find 1 deletion")
        XCTAssertEqual(deletions.first, "conn:test:path:/file1.txt")
        
        // Query deletions from earlier - should still find it
        let allDeletions = try await store.deletions(since: 0)
        XCTAssertEqual(allDeletions.count, 1)
    }
    
    // MARK: - Folder Query Tests
    
    func testItemsInFolder() async throws {
        let parentId = "conn:test"
        
        // Create items in the folder
        let (_, _) = try await store.upsert(
            itemIdentifier: "conn:test:path:/file1.txt",
            connectionId: "test",
            remotePath: "/file1.txt",
            parentIdentifier: parentId,
            filename: "file1.txt",
            size: 100,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: nil,
            isSymlink: false
        )
        
        let (_, _) = try await store.upsert(
            itemIdentifier: "conn:test:path:/file2.txt",
            connectionId: "test",
            remotePath: "/file2.txt",
            parentIdentifier: parentId,
            filename: "file2.txt",
            size: 200,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: nil,
            isSymlink: false
        )
        
        // Create item in different folder
        let (_, _) = try await store.upsert(
            itemIdentifier: "conn:test:path:/sub/file3.txt",
            connectionId: "test",
            remotePath: "/sub/file3.txt",
            parentIdentifier: "conn:test:path:/sub",
            filename: "file3.txt",
            size: 300,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: nil,
            isSymlink: false
        )
        
        // Query folder
        let items = try await store.items(inFolder: parentId)
        XCTAssertEqual(items.count, 2, "Should find 2 items in folder")
    }
    
    // MARK: - Batch Upsert Tests
    
    func testBatchUpsert() async throws {
        let parentId = "conn:test:path:/folder"
        
        // First batch
        try await store.upsertBatch(items: [
            (id: "conn:test:path:/folder/a.txt", connId: "test", path: "/folder/a.txt", parentId: parentId, name: "a.txt", size: 100, isDir: false, perms: 0o644, modDate: nil, isSymlink: false),
            (id: "conn:test:path:/folder/b.txt", connId: "test", path: "/folder/b.txt", parentId: parentId, name: "b.txt", size: 200, isDir: false, perms: 0o644, modDate: nil, isSymlink: false),
        ], parentId: parentId)
        
        var items = try await store.items(inFolder: parentId)
        XCTAssertEqual(items.count, 2)
        
        // Second batch - b.txt removed, c.txt added
        try await store.upsertBatch(items: [
            (id: "conn:test:path:/folder/a.txt", connId: "test", path: "/folder/a.txt", parentId: parentId, name: "a.txt", size: 100, isDir: false, perms: 0o644, modDate: nil, isSymlink: false),
            (id: "conn:test:path:/folder/c.txt", connId: "test", path: "/folder/c.txt", parentId: parentId, name: "c.txt", size: 300, isDir: false, perms: 0o644, modDate: nil, isSymlink: false),
        ], parentId: parentId)
        
        items = try await store.items(inFolder: parentId)
        XCTAssertEqual(items.count, 2, "Should have 2 active items (b deleted, c added)")
        
        let filenames = Set(items.map { $0.filename })
        XCTAssertTrue(filenames.contains("a.txt"))
        XCTAssertTrue(filenames.contains("c.txt"))
        XCTAssertFalse(filenames.contains("b.txt"), "b.txt should be deleted")
        
        // Check b.txt is in deletions
        let deletions = try await store.deletions(since: 0)
        XCTAssertTrue(deletions.contains("conn:test:path:/folder/b.txt"))
    }
    
    // MARK: - Persistence Tests
    
    func testAnchorPersistence() async throws {
        // Increment anchor several times
        _ = try await store.incrementAnchor()
        _ = try await store.incrementAnchor()
        let finalAnchor = try await store.incrementAnchor()
        
        XCTAssertEqual(finalAnchor, 3)
        
        // Note: Can't easily test persistence across process restarts in unit test
        // But we verify the value is stored correctly within the session
    }
}

// MARK: - Quick Self-Test

/// Quick validation that can be run without XCTest framework
/// Usage: Call MetadataStoreSelfTest.run() from app code
enum MetadataStoreSelfTest {
    
    static func run() async {
        print("🧪 MetadataStore Self-Test Starting...")
        
        do {
            let store = MetadataStore.shared
            
            // Clear and verify initial state
            try await store.clearAll()
            let initialAnchor = try await store.currentAnchor
            // CRITICAL: Initial anchor must be 1 (not 0) for enumerateChanges(from: 0) to work
            assert(initialAnchor == 1, "Initial anchor should be 1 (not 0)")
            print("✅ Initial anchor is 1 (correct for enumerateChanges support)")
            
            // Test increment
            let newAnchor = try await store.incrementAnchor()
            assert(newAnchor == 2, "Incremented anchor should be 2")
            print("✅ Anchor incremented to 2")
            
            // Test upsert
            let (item, isNew) = try await store.upsert(
                itemIdentifier: "test:item1",
                connectionId: "test",
                remotePath: "/test.txt",
                parentIdentifier: "test",
                filename: "test.txt",
                size: 100,
                isDirectory: false,
                permissions: 0o644,
                modificationDate: nil,
                isSymlink: false
            )
            assert(isNew, "Item should be new")
            assert(item.filename == "test.txt", "Filename should match")
            print("✅ Item created successfully")
            
            // Test query
            let found = try await store.item(id: "test:item1")
            assert(found != nil, "Should find item")
            print("✅ Item query successful")
            
            // Test change detection
            let changes = try await store.itemsModified(since: 0)
            assert(changes.count == 1, "Should find 1 changed item")
            print("✅ Change detection working")
            
            // Clean up
            try await store.clearAll()
            print("✅ Cleanup successful")
            
            print("🎉 MetadataStore Self-Test PASSED!")
            
        } catch {
            print("❌ MetadataStore Self-Test FAILED: \(error)")
        }
    }
    
    // MARK: - "Syncing Paused" Fix Tests
    
    /// Tests that enumerateChanges(from: 0) works on fresh install
    /// This is the CRITICAL scenario that causes "Syncing Paused"
    func testEnumerateChangesFromZeroOnFreshInstall() async throws {
        // Simulate fresh install: clearAll resets anchor to 1
        try await store.clearAll()
        
        // iOS calls currentSyncAnchor() first
        let currentAnchor = try await store.currentAnchor
        
        // CRITICAL: anchor must be > 0, otherwise enumerateChanges(from: 0) thinks nothing has changed
        XCTAssertGreaterThan(currentAnchor, 0, "Anchor must be > 0 for enumerateChanges to work")
        XCTAssertEqual(currentAnchor, 1, "Fresh install anchor should be 1")
        
        // Simulate iOS calling enumerateChanges(from: 0) - what happens on first sync
        let requestedAnchor: UInt64 = 0
        
        // The check in MetadataStoreEnumerator is: requestedAnchor >= currentAnchor
        // If this is true, it returns "no changes" immediately
        // We need this to be FALSE so we query for changes
        XCTAssertLessThan(requestedAnchor, currentAnchor, 
                          "requestedAnchor (0) must be < currentAnchor (1) for changes to be reported")
        
        // This is what enumerateChanges does internally
        let (modified, deletions, newAnchor) = try await store.changesSince(anchor: requestedAnchor)
        
        // Even with no items, the anchor should be 1 (not 0)
        XCTAssertEqual(newAnchor, 1, "New anchor should be 1")
        
        // No items yet, but that's OK - iOS gets a valid anchor
        XCTAssertEqual(modified.count, 0, "No modified items on fresh install (expected)")
        XCTAssertEqual(deletions.count, 0, "No deletions on fresh install (expected)")
    }
    
    /// Tests that MetadataStore anchor initializes correctly
    /// NOTE: MetadataAnchorCache was removed in Option B simplification (Jan 5, 2026)
    func testAnchorInitialization() async throws {
        // After clearAll, the store should have anchor = 1
        try await store.clearAll()
        
        let storeAnchor = try await store.currentAnchor
        
        XCTAssertEqual(storeAnchor, 1, "Store anchor should be 1 after clearAll")
    }
    
    /// Tests that changes are detectable from anchor 0
    func testChangesDetectableFromZero() async throws {
        try await store.clearAll()
        
        // Create an item
        let (_, _) = try await store.upsert(
            itemIdentifier: "conn:test:path:/test.txt",
            connectionId: "test",
            remotePath: "/test.txt",
            parentIdentifier: "conn:test",
            filename: "test.txt",
            size: 100,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: nil,
            isSymlink: false
        )
        
        // Changes from anchor 0 should include the new item
        let (modified, _, _) = try await store.changesSince(anchor: 0)
        
        XCTAssertEqual(modified.count, 1, "Should detect 1 change from anchor 0")
        XCTAssertEqual(modified.first?.filename, "test.txt")
    }
    
    // MARK: - Working Set Enumerator Contract Tests
    
    /// Tests the EXACT sequence iOS uses when syncing with a file provider.
    /// This is the core flow that determines "Syncing Paused" status.
    func testWorkingSetEnumeratorIOSCallSequence() async throws {
        try await store.clearAll()
        
        // === STEP 1: iOS creates enumerator and gets current anchor ===
        let enumerator = MetadataStoreEnumerator()
        
        // iOS calls currentSyncAnchor() synchronously
        var receivedAnchor: NSFileProviderSyncAnchor?
        enumerator.currentSyncAnchor { anchor in
            receivedAnchor = anchor
        }
        
        // Anchor must be non-nil and valid
        XCTAssertNotNil(receivedAnchor, "currentSyncAnchor must return non-nil anchor")
        
        // Parse anchor using new versioned format
        guard let (version, iteration) = SyncState.parseAnchor(from: receivedAnchor!) else {
            XCTFail("Anchor must be parseable")
            return
        }
        XCTAssertEqual(version, SyncState.currentVersion, "Anchor version should match current")
        XCTAssertEqual(iteration, 1, "Fresh install anchor iteration should be 1")
        
        // === STEP 2: iOS calls enumerateChanges with anchor V1-0 (initial sync) ===
        // Using new versioned format: V{version}-0 means "give me all changes"
        let anchorString = "V\(SyncState.currentVersion)-0"
        let initialAnchor = NSFileProviderSyncAnchor(anchorString.data(using: .utf8)!)
        
        let changesExpectation = expectation(description: "enumerateChanges completes")
        var changesCompleted = false
        var finalAnchor: NSFileProviderSyncAnchor?
        
        let changeObserver = MockChangeObserver(
            onFinish: { anchor, moreComing in
                changesCompleted = true
                finalAnchor = anchor
                XCTAssertFalse(moreComing, "moreComing should be false")
                changesExpectation.fulfill()
            }
        )
        
        enumerator.enumerateChanges(for: changeObserver, from: initialAnchor)
        
        await fulfillment(of: [changesExpectation], timeout: 5.0)
        
        XCTAssertTrue(changesCompleted, "enumerateChanges must call finishEnumeratingChanges")
        XCTAssertNotNil(finalAnchor, "Final anchor must be provided")
        
        // Final anchor must be parseable with new format
        guard let (finalVersion, finalIteration) = SyncState.parseAnchor(from: finalAnchor!) else {
            XCTFail("Final anchor must be parseable")
            return
        }
        XCTAssertEqual(finalVersion, SyncState.currentVersion, "Final anchor version should match current")
        XCTAssertEqual(finalIteration, 1, "Final anchor iteration should be 1 (our current anchor)")
        
        enumerator.invalidate()
    }
    
    /// Tests that subsequent enumerateChanges calls work correctly (no changes case)
    func testWorkingSetEnumeratorNoChanges() async throws {
        try await store.clearAll()
        
        let enumerator = MetadataStoreEnumerator()
        
        // Get current anchor
        var currentAnchorData: Data?
        enumerator.currentSyncAnchor { anchor in
            currentAnchorData = anchor?.rawValue
        }
        XCTAssertNotNil(currentAnchorData)
        
        // Call enumerateChanges with the SAME anchor - should report no changes
        let sameAnchor = NSFileProviderSyncAnchor(currentAnchorData!)
        
        let expectation = expectation(description: "enumerateChanges completes")
        var finishedAnchor: NSFileProviderSyncAnchor?
        
        let observer = MockChangeObserver(
            onFinish: { anchor, _ in
                finishedAnchor = anchor
                expectation.fulfill()
            }
        )
        
        enumerator.enumerateChanges(for: observer, from: sameAnchor)
        
        await fulfillment(of: [expectation], timeout: 5.0)
        
        // Should return same anchor (no changes)
        XCTAssertEqual(finishedAnchor?.rawValue, currentAnchorData, 
                       "When no changes, should return same anchor")
        
        enumerator.invalidate()
    }
    
    /// Tests that changes ARE reported when items are added
    func testWorkingSetEnumeratorWithChanges() async throws {
        try await store.clearAll()
        
        let enumerator = MetadataStoreEnumerator()
        
        // Get initial anchor (should be 1)
        var initialAnchorValue: UInt64 = 0
        enumerator.currentSyncAnchor { anchor in
            if let data = anchor?.rawValue, data.count == 8 {
                initialAnchorValue = data.withUnsafeBytes { $0.load(as: UInt64.self) }
            }
        }
        XCTAssertEqual(initialAnchorValue, 1)
        
        // Add an item (this increments anchor to 2)
        try await store.upsert(
            itemIdentifier: "conn:test:path:/file.txt",
            connectionId: "test",
            remotePath: "/file.txt",
            parentIdentifier: "conn:test",
            filename: "file.txt",
            size: 100,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: nil,
            isSymlink: false
        )
        
        // Verify anchor incremented
        let newAnchor = try await store.currentAnchor
        XCTAssertEqual(newAnchor, 2, "Anchor should be 2 after upsert")
        
        // Call enumerateChanges from anchor 1 - should see the new item
        var anchor1: UInt64 = 1
        let oldAnchor = NSFileProviderSyncAnchor(Data(bytes: &anchor1, count: 8))
        
        let expectation = expectation(description: "enumerateChanges completes")
        var updatedItems: [any NSFileProviderItemProtocol] = []
        var finishedAnchorValue: UInt64 = 0
        
        let observer = MockChangeObserver(
            onUpdate: { items in
                updatedItems = items
            },
            onFinish: { anchor, _ in
                if let data = anchor.rawValue as Data?, data.count == 8 {
                    finishedAnchorValue = data.withUnsafeBytes { $0.load(as: UInt64.self) }
                }
                expectation.fulfill()
            }
        )
        
        enumerator.enumerateChanges(for: observer, from: oldAnchor)
        
        await fulfillment(of: [expectation], timeout: 5.0)
        
        // Should report the new item
        XCTAssertEqual(updatedItems.count, 1, "Should report 1 updated item")
        XCTAssertEqual(updatedItems.first?.filename, "file.txt")
        
        // Final anchor should be 2
        XCTAssertEqual(finishedAnchorValue, 2, "Final anchor should be 2")
        
        enumerator.invalidate()
    }
}

// MARK: - Mock Observers for Testing

/// Mock NSFileProviderChangeObserver for testing enumerateChanges
class MockChangeObserver: NSObject, NSFileProviderChangeObserver {
    var suggestedBatchSize: Int = 100
    
    private let onUpdate: (([any NSFileProviderItemProtocol]) -> Void)?
    private let onDelete: (([NSFileProviderItemIdentifier]) -> Void)?
    private let onFinish: ((NSFileProviderSyncAnchor, Bool) -> Void)?
    private let onError: ((Error) -> Void)?
    
    init(
        onUpdate: (([any NSFileProviderItemProtocol]) -> Void)? = nil,
        onDelete: (([NSFileProviderItemIdentifier]) -> Void)? = nil,
        onFinish: ((NSFileProviderSyncAnchor, Bool) -> Void)? = nil,
        onError: ((Error) -> Void)? = nil
    ) {
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        self.onFinish = onFinish
        self.onError = onError
    }
    
    func didUpdate(_ updatedItems: [any NSFileProviderItemProtocol]) {
        onUpdate?(updatedItems)
    }
    
    func didDeleteItems(withIdentifiers deletedItemIdentifiers: [NSFileProviderItemIdentifier]) {
        onDelete?(deletedItemIdentifiers)
    }
    
    func finishEnumeratingChanges(upTo anchor: NSFileProviderSyncAnchor, moreComing: Bool) {
        onFinish?(anchor, moreComing)
    }
    
    func finishEnumeratingWithError(_ error: Error) {
        onError?(error)
    }
}
