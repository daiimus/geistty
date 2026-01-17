//
//  FileProviderTests.swift
//  GeisttyTests
//
//  Unit tests for File Provider infrastructure.
//  Tests MetadataStore, enumerators, anchor handling, and sync behavior.
//
//  These tests run on macOS (simulator) without requiring a device or network.
//

import Foundation
import XCTest
import FileProvider
@testable import Geistty

// MARK: - MetadataStore Tests

final class MetadataStoreTests: XCTestCase {
    
    var store: MetadataStore!
    
    override func setUp() async throws {
        store = MetadataStore.shared
        try await store.clearAll()
    }
    
    override func tearDown() async throws {
        try await store.clearAll()
    }
    
    // MARK: - Critical Anchor Tests
    
    /// Initial anchor MUST be 1 (not 0) for enumerateChanges(from: 0) to work
    func testInitialAnchorIsOne() async throws {
        let anchor = try await store.currentAnchor
        XCTAssertEqual(anchor, 1, "Initial anchor must be 1, not 0")
    }
    
    /// Anchor must increment monotonically
    func testAnchorIncrementsCorrectly() async throws {
        let initial = try await store.currentAnchor
        XCTAssertEqual(initial, 1)
        
        let second = try await store.incrementAnchor()
        XCTAssertEqual(second, 2)
        
        let third = try await store.incrementAnchor()
        XCTAssertEqual(third, 3)
        
        let current = try await store.currentAnchor
        XCTAssertEqual(current, 3)
    }
    
    /// Test anchor serialization to Data (what File Provider uses)
    func testAnchorSerialization() async throws {
        _ = try await store.incrementAnchor() // Now at 2
        _ = try await store.incrementAnchor() // Now at 3
        
        let syncAnchor = try await store.currentSyncAnchor
        guard let (version, iteration) = SyncState.parseAnchor(from: syncAnchor) else {
            XCTFail("Failed to parse anchor")
            return
        }
        
        XCTAssertEqual(version, SyncState.currentVersion, "Version should match current")
        XCTAssertEqual(iteration, 3, "Serialized anchor should round-trip to 3")
    }
    
    /// Empty store should still have anchor > 0
    func testEmptyStoreHasValidAnchor() async throws {
        let items = try await store.itemsModified(since: 0)
        XCTAssertEqual(items.count, 0, "No items yet")
        
        let anchor = try await store.currentAnchor
        XCTAssertGreaterThan(anchor, 0, "Anchor must be > 0 even with no items")
    }
    
    // MARK: - The Critical "Syncing Paused" Test
    
    /// This tests the exact scenario that causes "Syncing Paused"
    /// iOS calls enumerateChanges(from: NSFileProviderSyncAnchor(rawValue: Data()))
    /// which we interpret as anchor = 0
    func testEnumerateChangesFromZeroWorks() async throws {
        // Simulate fresh install state
        try await store.clearAll()
        
        let currentAnchor = try await store.currentAnchor
        let requestedAnchor: UInt64 = 0
        
        // This is the critical check: 0 < 1 means we should report changes
        XCTAssertLessThan(requestedAnchor, currentAnchor,
            "Requested anchor (0) must be < current (1) to trigger change enumeration")
        
        // Simulate what MetadataStoreEnumerator does
        let changes = try await store.itemsModified(since: requestedAnchor)
        let deletions = try await store.deletions(since: requestedAnchor)
        
        // Empty changes are OK - but we need to return a valid anchor
        XCTAssertGreaterThanOrEqual(currentAnchor, 1, "Must return anchor >= 1")
    }
    
    /// Test that changes since anchor 0 includes all items
    func testChangesFromZeroIncludesAllItems() async throws {
        // Add some items
        let (_, _) = try await store.upsert(
            itemIdentifier: "test:1",
            connectionId: "test",
            remotePath: "/file1.txt",
            parentIdentifier: "test",
            filename: "file1.txt",
            size: 100,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: nil,
            isSymlink: false
        )
        
        let (_, _) = try await store.upsert(
            itemIdentifier: "test:2",
            connectionId: "test",
            remotePath: "/file2.txt",
            parentIdentifier: "test",
            filename: "file2.txt",
            size: 200,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: nil,
            isSymlink: false
        )
        
        // Changes from 0 should include both
        let changes = try await store.itemsModified(since: 0)
        XCTAssertEqual(changes.count, 2, "Should find all 2 items when querying from anchor 0")
    }
    
    // MARK: - Item CRUD Tests
    
    func testUpsertCreatesNewItem() async throws {
        let (item, isNew) = try await store.upsert(
            itemIdentifier: "test:item",
            connectionId: "test",
            remotePath: "/test.txt",
            parentIdentifier: "test",
            filename: "test.txt",
            size: 100,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: Date(),
            isSymlink: false
        )
        
        XCTAssertTrue(isNew)
        XCTAssertEqual(item.filename, "test.txt")
        XCTAssertEqual(item.size, 100)
        XCTAssertGreaterThan(item.createdAtAnchor, 0)
    }
    
    func testUpsertUpdatesExistingItem() async throws {
        // Create
        let (_, _) = try await store.upsert(
            itemIdentifier: "test:item",
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
        
        let anchorAfterCreate = try await store.currentAnchor
        
        // Update
        let (updated, isNew) = try await store.upsert(
            itemIdentifier: "test:item",
            connectionId: "test",
            remotePath: "/test.txt",
            parentIdentifier: "test",
            filename: "test.txt",
            size: 200, // Changed
            isDirectory: false,
            permissions: 0o644,
            modificationDate: nil,
            isSymlink: false
        )
        
        XCTAssertFalse(isNew)
        XCTAssertEqual(updated.size, 200)
        XCTAssertGreaterThan(updated.modifiedAtAnchor, anchorAfterCreate)
    }
    
    func testMarkDeleted() async throws {
        // Create
        let (_, _) = try await store.upsert(
            itemIdentifier: "test:item",
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
        
        let anchorBeforeDelete = try await store.currentAnchor
        
        // Delete
        let deleteAnchor = try await store.markDeleted(id: "test:item")
        XCTAssertGreaterThan(deleteAnchor, anchorBeforeDelete)
        
        // Should not be found
        let found = try await store.item(id: "test:item")
        XCTAssertNil(found)
        
        // Should be in deletions
        let deletions = try await store.deletions(since: anchorBeforeDelete)
        XCTAssertTrue(deletions.contains("test:item"))
    }
    
    // MARK: - Batch Upsert Tests
    
    func testBatchUpsertDetectsRemovedItems() async throws {
        let parentId = "test:folder"
        
        // First batch: a, b
        try await store.upsertBatch(items: [
            (id: "test:a", connId: "test", path: "/a.txt", parentId: parentId, name: "a.txt", size: 100, isDir: false, perms: 0o644, modDate: nil, isSymlink: false),
            (id: "test:b", connId: "test", path: "/b.txt", parentId: parentId, name: "b.txt", size: 200, isDir: false, perms: 0o644, modDate: nil, isSymlink: false),
        ], parentId: parentId)
        
        var items = try await store.items(inFolder: parentId)
        XCTAssertEqual(items.count, 2)
        
        // Second batch: a, c (b removed)
        try await store.upsertBatch(items: [
            (id: "test:a", connId: "test", path: "/a.txt", parentId: parentId, name: "a.txt", size: 100, isDir: false, perms: 0o644, modDate: nil, isSymlink: false),
            (id: "test:c", connId: "test", path: "/c.txt", parentId: parentId, name: "c.txt", size: 300, isDir: false, perms: 0o644, modDate: nil, isSymlink: false),
        ], parentId: parentId)
        
        items = try await store.items(inFolder: parentId)
        XCTAssertEqual(items.count, 2)
        
        let filenames = Set(items.map { $0.filename })
        XCTAssertTrue(filenames.contains("a.txt"))
        XCTAssertTrue(filenames.contains("c.txt"))
        XCTAssertFalse(filenames.contains("b.txt"))
        
        // b should be in deletions
        let deletions = try await store.deletions(since: 0)
        XCTAssertTrue(deletions.contains("test:b"))
    }
}

// NOTE: MetadataAnchorCacheTests removed - Option B simplification (Jan 5, 2026)
// MetadataAnchorCache has been removed. SwiftData is now the only source of truth.

// MARK: - SyncState Tests

final class SyncStateTests: XCTestCase {
    
    func testAnchorToSyncAnchor() {
        let state = SyncState()
        state.currentAnchor = 12345
        let syncAnchor = state.toSyncAnchor()
        
        // New format: "V{version}-{iteration}" as UTF-8
        guard let (version, iteration) = SyncState.parseAnchor(from: syncAnchor) else {
            XCTFail("Failed to parse anchor")
            return
        }
        XCTAssertEqual(version, SyncState.currentVersion)
        XCTAssertEqual(iteration, 12345)
    }
    
    func testZeroAnchorParsing() {
        // Empty sync anchor should parse as nil (not 0)
        let empty = NSFileProviderSyncAnchor(Data())
        let parsed = SyncState.parseAnchor(from: empty)
        XCTAssertNil(parsed, "Empty data should parse as nil (invalid)")
    }
    
    func testAnchorRoundTrip() {
        for testValue: UInt64 in [1, 100, 999999999] {
            let state = SyncState()
            state.currentAnchor = testValue
            let syncAnchor = state.toSyncAnchor()
            guard let (version, iteration) = SyncState.parseAnchor(from: syncAnchor) else {
                XCTFail("Failed to parse anchor for value \(testValue)")
                continue
            }
            XCTAssertEqual(version, SyncState.currentVersion)
            XCTAssertEqual(iteration, testValue, "Anchor \(testValue) should round-trip")
        }
    }
    
    func testLegacyAnchorParsing() {
        // Legacy anchors are 8-byte UInt64
        var value: UInt64 = 42
        let data = Data(bytes: &value, count: 8)
        let syncAnchor = NSFileProviderSyncAnchor(data)
        
        guard let (version, iteration) = SyncState.parseAnchor(from: syncAnchor) else {
            XCTFail("Failed to parse legacy anchor")
            return
        }
        
        // Legacy anchors are version 0
        XCTAssertEqual(version, 0)
        XCTAssertEqual(iteration, 42)
    }
    
    func testAnchorValidation() {
        let state = SyncState()
        state.currentAnchor = 10
        
        // Valid anchor with same version
        let validAnchor = state.toSyncAnchor()
        let validation = state.validateAnchor(validAnchor)
        if case .noChanges = validation {
            // Expected - same anchor
        } else {
            XCTFail("Expected noChanges for same anchor, got \(validation)")
        }
        
        // Older anchor is valid
        state.currentAnchor = 5
        let olderAnchor = state.toSyncAnchor()
        state.currentAnchor = 10
        let olderValidation = state.validateAnchor(olderAnchor)
        if case .valid(let iteration) = olderValidation {
            XCTAssertEqual(iteration, 5)
        } else {
            XCTFail("Expected valid for older anchor, got \(olderValidation)")
        }
        
        // Legacy anchor is expired (forces re-sync)
        var legacyValue: UInt64 = 5
        let legacyData = Data(bytes: &legacyValue, count: 8)
        let legacyAnchor = NSFileProviderSyncAnchor(legacyData)
        let legacyValidation = state.validateAnchor(legacyAnchor)
        if case .expired(let reqVersion, let curVersion) = legacyValidation {
            XCTAssertEqual(reqVersion, 0) // Legacy
            XCTAssertEqual(curVersion, SyncState.currentVersion)
        } else {
            XCTFail("Expected expired for legacy anchor, got \(legacyValidation)")
        }
    }
}

// MARK: - Enumerator Behavior Tests (Mock-based)

/// Tests for MetadataStoreEnumerator using the real MetadataStore
final class EnumeratorBehaviorTests: XCTestCase {
    
    var store: MetadataStore!
    
    override func setUp() async throws {
        store = MetadataStore.shared
        try await store.clearAll()
    }
    
    override func tearDown() async throws {
        try await store.clearAll()
    }
    
    /// Test that enumerator correctly reports "no changes" when anchor is current
    func testNoChangesWhenAnchorIsCurrent() async throws {
        // Add an item
        let (_, _) = try await store.upsert(
            itemIdentifier: "test:1",
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
        
        let currentAnchor = try await store.currentAnchor
        
        // Query changes since current anchor - should be empty
        let changes = try await store.itemsModified(since: currentAnchor)
        XCTAssertEqual(changes.count, 0, "No changes since current anchor")
    }
    
    /// Test incremental change detection
    func testIncrementalChangeDetection() async throws {
        // Add first item
        let (_, _) = try await store.upsert(
            itemIdentifier: "test:1",
            connectionId: "test",
            remotePath: "/file1.txt",
            parentIdentifier: "test",
            filename: "file1.txt",
            size: 100,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: nil,
            isSymlink: false
        )
        
        let anchorAfterFirst = try await store.currentAnchor
        
        // Add second item
        let (_, _) = try await store.upsert(
            itemIdentifier: "test:2",
            connectionId: "test",
            remotePath: "/file2.txt",
            parentIdentifier: "test",
            filename: "file2.txt",
            size: 200,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: nil,
            isSymlink: false
        )
        
        // Changes since first item should only include second
        let changes = try await store.itemsModified(since: anchorAfterFirst)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.filename, "file2.txt")
    }
}

// MARK: - "Syncing Paused" Diagnostic Tests

/// These tests specifically target scenarios that cause "Syncing Paused" in Files.app.
/// Based on Apple's File Provider documentation and observed failure modes.
final class SyncingPausedDiagnosticTests: XCTestCase {
    
    var store: MetadataStore!
    
    override func setUp() async throws {
        store = MetadataStore.shared
        try await store.clearAll()
    }
    
    override func tearDown() async throws {
        try await store.clearAll()
    }
    
    // MARK: - Root Cause #1: Anchor Format Issues
    
    /// Test: Anchor format is versioned string (not 8-byte UInt64)
    /// Format: "V{version}-{iteration}" as UTF-8
    func testAnchorIsVersionedString() async throws {
        let syncAnchor = try await store.currentSyncAnchor
        guard let string = String(data: syncAnchor.rawValue, encoding: .utf8) else {
            XCTFail("Anchor should be valid UTF-8 string")
            return
        }
        XCTAssertTrue(string.hasPrefix("V"), "Anchor should start with V")
        XCTAssertTrue(string.contains("-"), "Anchor should contain dash separator")
    }
    
    /// Test: Anchor data should be parseable
    func testAnchorIsParseable() async throws {
        let syncAnchor = try await store.currentSyncAnchor
        guard let (version, iteration) = SyncState.parseAnchor(from: syncAnchor) else {
            XCTFail("Should parse anchor")
            return
        }
        XCTAssertEqual(version, SyncState.currentVersion, "Version should match current")
        XCTAssertGreaterThan(iteration, 0, "Iteration should be > 0")
    }
    
    /// Test: Empty/nil anchor should be handled gracefully (parsed as nil)
    func testEmptyAnchorParsedAsNil() {
        let emptyAnchor = NSFileProviderSyncAnchor(Data())
        let parsed = SyncState.parseAnchor(from: emptyAnchor)
        XCTAssertNil(parsed, "Empty anchor data should parse as nil")
    }
    
    /// Test: Garbage anchor data handled gracefully
    func testGarbageAnchorParsedAsNil() {
        // Random garbage
        let garbage = Data([0xFF, 0xFE, 0xFD])
        let garbageAnchor = NSFileProviderSyncAnchor(garbage)
        let parsed = SyncState.parseAnchor(from: garbageAnchor)
        XCTAssertNil(parsed, "Garbage data should parse as nil")
    }
    
    // MARK: - Root Cause #2: Anchor Never at 0
    
    /// Test: Anchor must start at 1, not 0
    /// iOS calls enumerateChanges(from: 0) on fresh install.
    /// If our anchor starts at 0, we'd report "no changes" incorrectly.
    func testAnchorNeverStartsAtZero() async throws {
        // Clear to simulate fresh install
        try await store.clearAll()
        
        let anchor = try await store.currentAnchor
        XCTAssertGreaterThanOrEqual(anchor, 1,
            "Fresh anchor must be >= 1 (so enumerateChanges from 0 detects changes)")
    }
    
    // NOTE: testCacheNeverReturnsZero removed - Option B simplification (Jan 5, 2026)
    
    // MARK: - Root Cause #3: The iOS Call Sequence
    
    /// Test: Simulate the exact iOS call pattern
    /// iOS does: currentSyncAnchor() -> enumerateChanges(from: anchor) -> finish
    /// If any step fails or returns wrong data, "Syncing Paused" appears
    func testIOSCallSequenceSimulation() async throws {
        // Step 1: iOS gets current anchor
        let syncAnchor = try await store.currentSyncAnchor
        guard let (version, iteration) = SyncState.parseAnchor(from: syncAnchor) else {
            XCTFail("Step 1: currentSyncAnchor must return valid anchor")
            return
        }
        XCTAssertEqual(version, SyncState.currentVersion, "Step 1: version must match current")
        XCTAssertGreaterThan(iteration, 0, "Step 1: iteration must be > 0")
        
        // Step 2: iOS calls enumerateChanges with anchor 0 (fresh install)
        let changes = try await store.itemsModified(since: 0)
        let deletions = try await store.deletions(since: 0)
        // Empty is OK - important thing is it doesn't crash
        XCTAssertNotNil(changes, "Step 2: Should return changes array (may be empty)")
        XCTAssertNotNil(deletions, "Step 2: Should return deletions array (may be empty)")
        
        // Step 3: After enumerateChanges, anchor should still be valid
        let finalAnchor = try await store.currentAnchor
        XCTAssertGreaterThanOrEqual(finalAnchor, iteration,
            "Step 3: Anchor should be >= original after enumeration")
    }
    
    /// Test: Simulate repeated enumeration calls (iOS polling pattern)
    func testRepeatedEnumerationCalls() async throws {
        var previousAnchor: UInt64 = 0
        
        for i in 0..<5 {
            let anchor = try await store.currentAnchor
            XCTAssertGreaterThanOrEqual(anchor, previousAnchor,
                "Iteration \(i): anchor must be monotonically increasing")
            
            // Query changes from previous anchor
            let changes = try await store.itemsModified(since: previousAnchor)
            let deletions = try await store.deletions(since: previousAnchor)
            
            // Should not crash
            _ = changes
            _ = deletions
            
            previousAnchor = anchor
        }
    }
    
    // MARK: - Root Cause #4: SyncState anchor validation
    
    // NOTE: testCacheSyncAnchorIsSynchronous removed - Option B simplification (Jan 5, 2026)
    // We now use Task{} pattern in currentSyncAnchor, which is Apple-approved.
    
    /// Test: Verify SyncState.toSyncAnchor() produces valid anchor
    func testSyncStateProducesValidAnchor() {
        let state = SyncState()
        state.currentAnchor = 42
        
        let syncAnchor = state.toSyncAnchor()
        guard let (version, iteration) = SyncState.parseAnchor(from: syncAnchor) else {
            XCTFail("Should parse anchor")
            return
        }
        XCTAssertEqual(version, SyncState.currentVersion)
        XCTAssertEqual(iteration, 42)
    }
    
    // MARK: - Root Cause #5: Change Detection Edge Cases
    
    /// Test: Changes from anchor 0 must include all items
    func testChangesFromZeroReturnsAllItems() async throws {
        // Add items
        for i in 1...3 {
            let (_, _) = try await store.upsert(
                itemIdentifier: "test:\(i)",
                connectionId: "test",
                remotePath: "/file\(i).txt",
                parentIdentifier: "test",
                filename: "file\(i).txt",
                size: Int64(i * 100),
                isDirectory: false,
                permissions: 0o644,
                modificationDate: nil,
                isSymlink: false
            )
        }
        
        // Query from anchor 0 should find all 3
        let changes = try await store.itemsModified(since: 0)
        XCTAssertEqual(changes.count, 3,
            "Changes since anchor 0 must include ALL items")
    }
    
    /// Test: Changes from current anchor returns nothing
    func testChangesFromCurrentAnchorReturnsNothing() async throws {
        // Add item
        let (_, _) = try await store.upsert(
            itemIdentifier: "test:1",
            connectionId: "test",
            remotePath: "/file.txt",
            parentIdentifier: "test",
            filename: "file.txt",
            size: 100,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: nil,
            isSymlink: false
        )
        
        let currentAnchor = try await store.currentAnchor
        
        // Query from current anchor should find nothing
        let changes = try await store.itemsModified(since: currentAnchor)
        XCTAssertEqual(changes.count, 0,
            "Changes since current anchor should be empty")
    }
    
    /// Test: Anchor increments after item modifications
    func testAnchorIncrementsOnModification() async throws {
        let initialAnchor = try await store.currentAnchor
        
        let (_, _) = try await store.upsert(
            itemIdentifier: "test:1",
            connectionId: "test",
            remotePath: "/file.txt",
            parentIdentifier: "test",
            filename: "file.txt",
            size: 100,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: nil,
            isSymlink: false
        )
        
        let afterUpsert = try await store.currentAnchor
        XCTAssertGreaterThan(afterUpsert, initialAnchor,
            "Anchor must increase after upsert")
        
        // Update the item
        let (_, _) = try await store.upsert(
            itemIdentifier: "test:1",
            connectionId: "test",
            remotePath: "/file.txt",
            parentIdentifier: "test",
            filename: "file.txt",
            size: 200, // Changed
            isDirectory: false,
            permissions: 0o644,
            modificationDate: nil,
            isSymlink: false
        )
        
        let afterUpdate = try await store.currentAnchor
        XCTAssertGreaterThan(afterUpdate, afterUpsert,
            "Anchor must increase after update")
    }
    
    // MARK: - Root Cause #6: Deletion Tracking
    
    /// Test: Deletions are tracked and queryable by anchor
    func testDeletionsTrackedByAnchor() async throws {
        // Create item
        let (_, _) = try await store.upsert(
            itemIdentifier: "test:deleteme",
            connectionId: "test",
            remotePath: "/deleteme.txt",
            parentIdentifier: "test",
            filename: "deleteme.txt",
            size: 100,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: nil,
            isSymlink: false
        )
        
        let anchorBeforeDelete = try await store.currentAnchor
        
        // Delete it
        _ = try await store.markDeleted(id: "test:deleteme")
        
        // Query deletions since before delete
        let deletions = try await store.deletions(since: anchorBeforeDelete)
        XCTAssertTrue(deletions.contains("test:deleteme"),
            "Deleted item must appear in deletions query")
    }
}

// MARK: - Enumerator Mock Tests

/// Tests that verify MetadataStoreEnumerator behavior matches File Provider requirements
final class EnumeratorContractTests: XCTestCase {
    
    var store: MetadataStore!
    
    override func setUp() async throws {
        store = MetadataStore.shared
        try await store.clearAll()
    }
    
    override func tearDown() async throws {
        try await store.clearAll()
    }
    
    /// Test: enumerator currentSyncAnchor must call completion handler
    func testEnumeratorCallsCompletionHandler() {
        let enumerator = MetadataStoreEnumerator()
        let expectation = expectation(description: "completion called")
        
        enumerator.currentSyncAnchor { anchor in
            XCTAssertNotNil(anchor, "Must return non-nil anchor")
            // New format is versioned string, not 8 bytes
            let parsed = SyncState.parseAnchor(from: anchor!)
            XCTAssertNotNil(parsed, "Must be parseable anchor")
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 1.0)
    }
    
    /// Test: enumerator returns valid anchor with correct format
    func testEnumeratorAnchorFormat() {
        let enumerator = MetadataStoreEnumerator()
        let expectation = expectation(description: "got anchor")
        
        enumerator.currentSyncAnchor { anchor in
            guard let anchor = anchor else {
                XCTFail("Anchor should not be nil")
                return
            }
            
            // Parse it back - new format is versioned string
            guard let (version, iteration) = SyncState.parseAnchor(from: anchor) else {
                XCTFail("Anchor should be parseable")
                return
            }
            XCTAssertEqual(version, SyncState.currentVersion, "Version should match current")
            XCTAssertGreaterThanOrEqual(iteration, 1, "Iteration should be >= 1")
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 1.0)
    }
    
    /// Test: MetadataStore.changesSince returns correct format
    func testChangesSinceReturnsCorrectFormat() async throws {
        // Add an item
        let (_, _) = try await store.upsert(
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
        
        // Call changesSince(0) - the exact call enumerateChanges makes
        let (modified, deletions, newAnchor) = try await store.changesSince(anchor: 0)
        
        XCTAssertEqual(modified.count, 1, "Should have 1 modified item")
        XCTAssertEqual(deletions.count, 0, "Should have no deletions")
        
        // newAnchor is now NSFileProviderSyncAnchor, parse it
        guard let (version, iteration) = SyncState.parseAnchor(from: newAnchor) else {
            XCTFail("New anchor should be parseable")
            return
        }
        XCTAssertEqual(version, SyncState.currentVersion)
        XCTAssertGreaterThan(iteration, 0, "New anchor iteration should be > 0")
    }
    
    /// Test: changesSince with current anchor returns empty
    func testChangesSinceWithCurrentAnchorReturnsEmpty() async throws {
        // Add an item
        let (_, _) = try await store.upsert(
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
        
        let currentAnchor = try await store.currentAnchor
        
        // changesSince(currentAnchor) should return empty
        let (modified, deletions, newAnchor) = try await store.changesSince(anchor: currentAnchor)
        
        XCTAssertEqual(modified.count, 0, "Should have no changes since current anchor")
        XCTAssertEqual(deletions.count, 0, "Should have no deletions")
        
        // Parse and compare the iteration values
        guard let (_, iteration) = SyncState.parseAnchor(from: newAnchor) else {
            XCTFail("Anchor should be parseable")
            return
        }
        XCTAssertEqual(iteration, currentAnchor, "Anchor iteration should be unchanged")
    }
    
    /// Test: Simulate complete enumerateChanges flow with mock observer
    func testEnumerateChangesCompletesWithValidAnchor() async throws {
        // Add items to the store with valid parent identifiers (connection root format)
        for i in 1...3 {
            let (_, _) = try await store.upsert(
                itemIdentifier: "conn:test:path:/file\(i).txt",
                connectionId: "test",
                remotePath: "/file\(i).txt",
                parentIdentifier: "conn:test",  // Connection root - valid parent
                filename: "file\(i).txt",
                size: Int64(i * 100),
                isDirectory: false,
                permissions: 0o644,
                modificationDate: nil,
                isSymlink: false
            )
        }
        
        // Create mock observer that handles both success and error
        let expectation = expectation(description: "enumerateChanges completed")
        var gotError = false
        let mockObserver = MockChangeObserver { anchor, moreComing in
            XCTAssertFalse(moreComing, "Should not have more coming")
            // New format is versioned string
            guard let (version, iteration) = SyncState.parseAnchor(from: anchor) else {
                XCTFail("Anchor should be parseable")
                return
            }
            XCTAssertEqual(version, SyncState.currentVersion)
            XCTAssertGreaterThan(iteration, 0)
            expectation.fulfill()
        }
        
        // Create enumerator and call enumerateChanges
        // Use new versioned format with version 1, iteration 0 (before any items added)
        let enumerator = MetadataStoreEnumerator()
        let anchorString = "V\(SyncState.currentVersion)-0"
        let anchorData = anchorString.data(using: .utf8)!
        let anchor = NSFileProviderSyncAnchor(anchorData)
        
        enumerator.enumerateChanges(for: mockObserver, from: anchor)
        
        // Wait for async completion
        await fulfillment(of: [expectation], timeout: 5.0)
        
        // Verify observer received items
        XCTAssertEqual(mockObserver.updatedItems.count, 3, "Should have 3 updated items")
    }
}

// MARK: - Mock Change Observer

/// Mock observer for testing enumerateChanges behavior
class MockChangeObserver: NSObject, NSFileProviderChangeObserver {
    var updatedItems: [any NSFileProviderItem] = []
    var deletedIdentifiers: [NSFileProviderItemIdentifier] = []
    var finishedAnchor: NSFileProviderSyncAnchor?
    var moreComing: Bool = false
    var error: Error?
    
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
        self.finishedAnchor = anchor
        self.moreComing = moreComing
        onFinish(anchor, moreComing)
    }
    
    func finishEnumeratingWithError(_ error: Error) {
        self.error = error
    }
}

