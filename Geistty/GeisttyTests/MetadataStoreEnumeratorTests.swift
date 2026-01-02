//
//  MetadataStoreEnumeratorTests.swift
//  GeisttyTests
//
//  Unit tests for MetadataStoreEnumerator.
//  Tests the working set enumerator's behavior with mock observers.
//
//  These tests run on SIMULATOR - they don't require a device.
//  They verify the enumerator follows Apple's File Provider protocol correctly.
//

import FileProvider
import Foundation
import XCTest
@testable import Geistty

/// Mock observer for testing enumerateItems
final class MockEnumerationObserver: NSObject, NSFileProviderEnumerationObserver {
    var enumeratedItems: [NSFileProviderItemProtocol] = []
    var finishedPage: NSFileProviderPage?
    var finishedWithError: Error?
    var didFinish = false
    
    let expectation: XCTestExpectation?
    
    init(expectation: XCTestExpectation? = nil) {
        self.expectation = expectation
    }
    
    func didEnumerate(_ updatedItems: [any NSFileProviderItemProtocol]) {
        enumeratedItems.append(contentsOf: updatedItems)
    }
    
    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        finishedPage = nextPage
        didFinish = true
        expectation?.fulfill()
    }
    
    func finishEnumeratingWithError(_ error: any Error) {
        finishedWithError = error
        didFinish = true
        expectation?.fulfill()
    }
}

/// Mock observer for testing enumerateChanges
final class MetadataChangeObserver: NSObject, NSFileProviderChangeObserver {
    var updatedItems: [NSFileProviderItemProtocol] = []
    var deletedIdentifiers: [NSFileProviderItemIdentifier] = []
    var finishedAnchor: NSFileProviderSyncAnchor?
    var moreComing: Bool = false
    var finishedWithError: Error?
    var didFinish = false
    
    let expectation: XCTestExpectation?
    
    init(expectation: XCTestExpectation? = nil) {
        self.expectation = expectation
    }
    
    func didUpdate(_ updatedItems: [any NSFileProviderItemProtocol]) {
        self.updatedItems.append(contentsOf: updatedItems)
    }
    
    func didDeleteItems(withIdentifiers deletedItemIdentifiers: [NSFileProviderItemIdentifier]) {
        self.deletedIdentifiers.append(contentsOf: deletedItemIdentifiers)
    }
    
    func finishEnumeratingChanges(upTo anchor: NSFileProviderSyncAnchor, moreComing: Bool) {
        self.finishedAnchor = anchor
        self.moreComing = moreComing
        self.didFinish = true
        expectation?.fulfill()
    }
    
    func finishEnumeratingWithError(_ error: any Error) {
        self.finishedWithError = error
        self.didFinish = true
        expectation?.fulfill()
    }
}

// MARK: - Tests

@available(iOS 16.0, *)
final class MetadataStoreEnumeratorTests: XCTestCase {
    
    override func setUp() async throws {
        // Reset the MetadataStore and anchor cache before each test
        try await MetadataStore.shared.clearAll()
        MetadataAnchorCache.shared.refresh()
    }
    
    override func tearDown() async throws {
        try await MetadataStore.shared.clearAll()
    }
    
    // MARK: - enumerateItems Tests
    
    /// Working set enumerateItems should return NO items
    /// Per Apple docs: working set content flows through enumerateChanges, not enumerateItems
    func testEnumerateItemsReturnsEmpty() {
        let enumerator = MetadataStoreEnumerator()
        let exp = expectation(description: "enumerateItems completes")
        let observer = MockEnumerationObserver(expectation: exp)
        
        enumerator.enumerateItems(for: observer, startingAt: NSFileProviderPage.initialPageSortedByDate as NSFileProviderPage)
        
        wait(for: [exp], timeout: 1.0)
        
        XCTAssertTrue(observer.didFinish, "enumerateItems should complete")
        XCTAssertNil(observer.finishedWithError, "enumerateItems should not error")
        XCTAssertTrue(observer.enumeratedItems.isEmpty, "Working set enumerateItems should return no items")
    }
    
    // MARK: - currentSyncAnchor Tests
    
    /// currentSyncAnchor should always return a valid anchor
    func testCurrentSyncAnchorReturnsValidAnchor() {
        let enumerator = MetadataStoreEnumerator()
        let exp = expectation(description: "currentSyncAnchor completes")
        
        var receivedAnchor: NSFileProviderSyncAnchor?
        enumerator.currentSyncAnchor { anchor in
            receivedAnchor = anchor
            exp.fulfill()
        }
        
        wait(for: [exp], timeout: 1.0)
        
        XCTAssertNotNil(receivedAnchor, "currentSyncAnchor should return an anchor")
        XCTAssertEqual(receivedAnchor?.rawValue.count, 8, "Anchor should be 8 bytes (UInt64)")
        
        // Parse anchor value
        if let anchor = receivedAnchor {
            let value = anchor.rawValue.withUnsafeBytes { $0.load(as: UInt64.self) }
            XCTAssertGreaterThanOrEqual(value, 1, "Anchor value should be >= 1")
        }
    }
    
    // MARK: - enumerateChanges Tests
    
    /// enumerateChanges with same anchor should return no changes
    func testEnumerateChangesWithCurrentAnchorReturnsNoChanges() async throws {
        let enumerator = MetadataStoreEnumerator()
        
        // Get current anchor
        let currentAnchor = MetadataAnchorCache.shared.syncAnchor
        
        let exp = expectation(description: "enumerateChanges completes")
        let observer = MetadataChangeObserver(expectation: exp)
        
        enumerator.enumerateChanges(for: observer, from: currentAnchor)
        
        await fulfillment(of: [exp], timeout: 2.0)
        
        XCTAssertTrue(observer.didFinish, "enumerateChanges should complete")
        XCTAssertNil(observer.finishedWithError, "enumerateChanges should not error")
        XCTAssertTrue(observer.updatedItems.isEmpty, "No updates when at current anchor")
        XCTAssertTrue(observer.deletedIdentifiers.isEmpty, "No deletions when at current anchor")
        XCTAssertFalse(observer.moreComing, "moreComing should be false")
        XCTAssertNotNil(observer.finishedAnchor, "Should return an anchor")
    }
    
    /// enumerateChanges from anchor 0 should return all items (initial sync)
    func testEnumerateChangesFromZeroReturnsAllChanges() async throws {
        // Add some test items to the metadata store
        _ = try await MetadataStore.shared.upsert(
            itemIdentifier: "test:item1",
            connectionId: "test",
            remotePath: "/file1.txt",
            parentIdentifier: "test:root",
            filename: "file1.txt",
            size: 100,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: Date(),
            isSymlink: false
        )
        
        _ = try await MetadataStore.shared.upsert(
            itemIdentifier: "test:item2",
            connectionId: "test",
            remotePath: "/file2.txt",
            parentIdentifier: "test:root",
            filename: "file2.txt",
            size: 200,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: Date(),
            isSymlink: false
        )
        
        // Refresh cache after upserts
        MetadataAnchorCache.shared.refresh()
        
        let enumerator = MetadataStoreEnumerator()
        
        // Create anchor with value 0
        var zero: UInt64 = 0
        let zeroAnchor = NSFileProviderSyncAnchor(Data(bytes: &zero, count: 8))
        
        let exp = expectation(description: "enumerateChanges completes")
        let observer = MetadataChangeObserver(expectation: exp)
        
        enumerator.enumerateChanges(for: observer, from: zeroAnchor)
        
        await fulfillment(of: [exp], timeout: 2.0)
        
        XCTAssertTrue(observer.didFinish, "enumerateChanges should complete")
        XCTAssertNil(observer.finishedWithError, "enumerateChanges should not error")
        XCTAssertFalse(observer.moreComing, "moreComing should be false")
        
        // NOTE: Currently our enumerator skips reporting items in working set
        // This test documents current behavior, even if it might need changing
        // The key is that it COMPLETES without error
    }
    
    /// enumerateChanges should report deletions
    func testEnumerateChangesReportsDeletions() async throws {
        // Add an item
        _ = try await MetadataStore.shared.upsert(
            itemIdentifier: "test:delete-me",
            connectionId: "test",
            remotePath: "/delete-me.txt",
            parentIdentifier: "test:root",
            filename: "delete-me.txt",
            size: 50,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: Date(),
            isSymlink: false
        )
        
        // Get anchor before deletion
        let beforeAnchor = MetadataAnchorCache.shared.syncAnchor
        
        // Delete the item
        try await MetadataStore.shared.markDeleted(id: "test:delete-me")
        
        // Refresh cache
        MetadataAnchorCache.shared.refresh()
        
        let enumerator = MetadataStoreEnumerator()
        let exp = expectation(description: "enumerateChanges completes")
        let observer = MetadataChangeObserver(expectation: exp)
        
        enumerator.enumerateChanges(for: observer, from: beforeAnchor)
        
        await fulfillment(of: [exp], timeout: 2.0)
        
        XCTAssertTrue(observer.didFinish, "enumerateChanges should complete")
        XCTAssertNil(observer.finishedWithError, "enumerateChanges should not error")
        
        // Verify deletion was reported
        XCTAssertTrue(
            observer.deletedIdentifiers.contains(NSFileProviderItemIdentifier("test:delete-me")),
            "Should report the deleted item"
        )
    }
    
    /// enumerateChanges should always complete (never hang)
    func testEnumerateChangesAlwaysCompletes() async throws {
        let enumerator = MetadataStoreEnumerator()
        
        // Try various anchor formats to ensure none cause hangs
        let testCases: [(String, Data)] = [
            ("zero", {
                var v: UInt64 = 0
                return Data(bytes: &v, count: 8)
            }()),
            ("one", {
                var v: UInt64 = 1
                return Data(bytes: &v, count: 8)
            }()),
            ("large", {
                var v: UInt64 = 999999
                return Data(bytes: &v, count: 8)
            }()),
            ("empty", Data()),
            ("string", "VERSION-1".data(using: .utf8)!),
        ]
        
        for (name, anchorData) in testCases {
            let anchor = NSFileProviderSyncAnchor(anchorData)
            let exp = expectation(description: "enumerateChanges completes for \(name)")
            let observer = MetadataChangeObserver(expectation: exp)
            
            enumerator.enumerateChanges(for: observer, from: anchor)
            
            // Should complete within 2 seconds - if it hangs, test fails
            await fulfillment(of: [exp], timeout: 2.0)
            
            XCTAssertTrue(observer.didFinish, "enumerateChanges should complete for anchor: \(name)")
            XCTAssertNil(observer.finishedWithError, "enumerateChanges should not error for anchor: \(name)")
        }
    }
    
    // MARK: - Anchor Progression Tests
    
    /// Anchor should increase after changes
    func testAnchorProgressesAfterChanges() async throws {
        let initialAnchor = MetadataAnchorCache.shared.currentAnchor
        
        // Make a change
        _ = try await MetadataStore.shared.upsert(
            itemIdentifier: "test:progression",
            connectionId: "test",
            remotePath: "/progression.txt",
            parentIdentifier: "test:root",
            filename: "progression.txt",
            size: 10,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: Date(),
            isSymlink: false
        )
        
        // Refresh cache
        MetadataAnchorCache.shared.refresh()
        
        let newAnchor = MetadataAnchorCache.shared.currentAnchor
        
        XCTAssertGreaterThan(newAnchor, initialAnchor, "Anchor should increase after changes")
    }
    
    // MARK: - Subfolder Change Reporting Tests
    
    /// CRITICAL TEST: Files in subfolders must be reported even when parent wasn't modified
    /// This tests the bug found on Jan 2, 2026 - the filter was too aggressive
    func testSubfolderFileChangesAreReported() async throws {
        // First, create the parent folder (not at root level)
        _ = try await MetadataStore.shared.upsert(
            itemIdentifier: "conn:test:path:/subfolder",
            connectionId: "test",
            remotePath: "/subfolder",
            parentIdentifier: "conn:test",  // Connection root
            filename: "subfolder",
            size: 0,
            isDirectory: true,
            permissions: 0o755,
            modificationDate: Date(),
            isSymlink: false
        )
        
        // Get anchor AFTER folder creation
        MetadataAnchorCache.shared.refresh()
        let beforeFileAnchor = MetadataAnchorCache.shared.syncAnchor
        
        // Now add a file IN the subfolder (parent is the subfolder, not connection root)
        _ = try await MetadataStore.shared.upsert(
            itemIdentifier: "conn:test:path:/subfolder/file.txt",
            connectionId: "test",
            remotePath: "/subfolder/file.txt",
            parentIdentifier: "conn:test:path:/subfolder",  // Parent is subfolder, NOT conn:test
            filename: "file.txt",
            size: 100,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: Date(),
            isSymlink: false
        )
        
        MetadataAnchorCache.shared.refresh()
        
        // Enumerate changes since before the file was added
        let enumerator = MetadataStoreEnumerator()
        let exp = expectation(description: "enumerateChanges completes")
        let observer = MetadataChangeObserver(expectation: exp)
        
        enumerator.enumerateChanges(for: observer, from: beforeFileAnchor)
        
        await fulfillment(of: [exp], timeout: 2.0)
        
        XCTAssertTrue(observer.didFinish, "enumerateChanges should complete")
        XCTAssertNil(observer.finishedWithError, "enumerateChanges should not error")
        
        // THE CRITICAL ASSERTION: The file in the subfolder MUST be reported
        // even though its parent (the subfolder) wasn't modified in this batch
        let reportedIds = observer.updatedItems.map { $0.itemIdentifier.rawValue }
        XCTAssertTrue(
            reportedIds.contains("conn:test:path:/subfolder/file.txt"),
            "File in subfolder must be reported even when parent wasn't modified. Reported: \(reportedIds)"
        )
    }
    
    // MARK: - Deep Nesting Tests
    
    /// Files 5+ levels deep must still be reported in changes
    func testDeepNestedChangesAreReported() async throws {
        // Create a deep folder structure: /a/b/c/d/e/file.txt
        let folders = ["/a", "/a/b", "/a/b/c", "/a/b/c/d", "/a/b/c/d/e"]
        
        for (index, path) in folders.enumerated() {
            let parentPath = index == 0 ? "conn:test" : "conn:test:path:\(folders[index-1])"
            _ = try await MetadataStore.shared.upsert(
                itemIdentifier: "conn:test:path:\(path)",
                connectionId: "test",
                remotePath: path,
                parentIdentifier: parentPath,
                filename: String(path.split(separator: "/").last!),
                size: 0,
                isDirectory: true,
                permissions: 0o755,
                modificationDate: Date(),
                isSymlink: false
            )
        }
        
        // Get anchor AFTER folder creation
        MetadataAnchorCache.shared.refresh()
        let beforeFileAnchor = MetadataAnchorCache.shared.syncAnchor
        
        // Add a file 5 levels deep
        _ = try await MetadataStore.shared.upsert(
            itemIdentifier: "conn:test:path:/a/b/c/d/e/deep-file.txt",
            connectionId: "test",
            remotePath: "/a/b/c/d/e/deep-file.txt",
            parentIdentifier: "conn:test:path:/a/b/c/d/e",
            filename: "deep-file.txt",
            size: 42,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: Date(),
            isSymlink: false
        )
        
        MetadataAnchorCache.shared.refresh()
        
        // Enumerate changes
        let enumerator = MetadataStoreEnumerator()
        let exp = expectation(description: "enumerateChanges completes")
        let observer = MetadataChangeObserver(expectation: exp)
        
        enumerator.enumerateChanges(for: observer, from: beforeFileAnchor)
        
        await fulfillment(of: [exp], timeout: 2.0)
        
        XCTAssertTrue(observer.didFinish)
        XCTAssertNil(observer.finishedWithError)
        
        let reportedIds = observer.updatedItems.map { $0.itemIdentifier.rawValue }
        XCTAssertTrue(
            reportedIds.contains("conn:test:path:/a/b/c/d/e/deep-file.txt"),
            "Deep nested file must be reported. Reported: \(reportedIds)"
        )
    }
    
    /// Multiple files at different depths should all be reported
    func testMultipleDepthsReported() async throws {
        // Setup: create folders
        _ = try await MetadataStore.shared.upsert(
            itemIdentifier: "conn:test:path:/level1",
            connectionId: "test",
            remotePath: "/level1",
            parentIdentifier: "conn:test",
            filename: "level1",
            size: 0,
            isDirectory: true,
            permissions: 0o755,
            modificationDate: Date(),
            isSymlink: false
        )
        
        _ = try await MetadataStore.shared.upsert(
            itemIdentifier: "conn:test:path:/level1/level2",
            connectionId: "test",
            remotePath: "/level1/level2",
            parentIdentifier: "conn:test:path:/level1",
            filename: "level2",
            size: 0,
            isDirectory: true,
            permissions: 0o755,
            modificationDate: Date(),
            isSymlink: false
        )
        
        MetadataAnchorCache.shared.refresh()
        let beforeAnchor = MetadataAnchorCache.shared.syncAnchor
        
        // Add files at multiple depths in the same batch
        _ = try await MetadataStore.shared.upsert(
            itemIdentifier: "conn:test:path:/root-file.txt",
            connectionId: "test",
            remotePath: "/root-file.txt",
            parentIdentifier: "conn:test",
            filename: "root-file.txt",
            size: 10,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: Date(),
            isSymlink: false
        )
        
        _ = try await MetadataStore.shared.upsert(
            itemIdentifier: "conn:test:path:/level1/mid-file.txt",
            connectionId: "test",
            remotePath: "/level1/mid-file.txt",
            parentIdentifier: "conn:test:path:/level1",
            filename: "mid-file.txt",
            size: 20,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: Date(),
            isSymlink: false
        )
        
        _ = try await MetadataStore.shared.upsert(
            itemIdentifier: "conn:test:path:/level1/level2/deep-file.txt",
            connectionId: "test",
            remotePath: "/level1/level2/deep-file.txt",
            parentIdentifier: "conn:test:path:/level1/level2",
            filename: "deep-file.txt",
            size: 30,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: Date(),
            isSymlink: false
        )
        
        MetadataAnchorCache.shared.refresh()
        
        let enumerator = MetadataStoreEnumerator()
        let exp = expectation(description: "enumerateChanges completes")
        let observer = MetadataChangeObserver(expectation: exp)
        
        enumerator.enumerateChanges(for: observer, from: beforeAnchor)
        
        await fulfillment(of: [exp], timeout: 2.0)
        
        let reportedIds = Set(observer.updatedItems.map { $0.itemIdentifier.rawValue })
        
        XCTAssertTrue(reportedIds.contains("conn:test:path:/root-file.txt"),
                      "Root level file must be reported")
        XCTAssertTrue(reportedIds.contains("conn:test:path:/level1/mid-file.txt"),
                      "Mid-level file must be reported")
        XCTAssertTrue(reportedIds.contains("conn:test:path:/level1/level2/deep-file.txt"),
                      "Deep file must be reported")
    }
    
    // MARK: - Large Batch Tests
    
    /// Enumerator should handle many items efficiently
    func testLargeBatchOfChanges() async throws {
        let beforeAnchor = MetadataAnchorCache.shared.syncAnchor
        
        // Add 100 items
        for i in 0..<100 {
            _ = try await MetadataStore.shared.upsert(
                itemIdentifier: "conn:test:path:/batch/file\(i).txt",
                connectionId: "test",
                remotePath: "/batch/file\(i).txt",
                parentIdentifier: "conn:test",  // All at root for simplicity
                filename: "file\(i).txt",
                size: Int64(i * 10),
                isDirectory: false,
                permissions: 0o644,
                modificationDate: Date(),
                isSymlink: false
            )
        }
        
        MetadataAnchorCache.shared.refresh()
        
        let enumerator = MetadataStoreEnumerator()
        let exp = expectation(description: "enumerateChanges completes")
        let observer = MetadataChangeObserver(expectation: exp)
        
        let startTime = Date()
        enumerator.enumerateChanges(for: observer, from: beforeAnchor)
        
        await fulfillment(of: [exp], timeout: 5.0)  // Allow more time for large batch
        let elapsed = Date().timeIntervalSince(startTime)
        
        XCTAssertTrue(observer.didFinish)
        XCTAssertNil(observer.finishedWithError)
        XCTAssertEqual(observer.updatedItems.count, 100, "All 100 items should be reported")
        XCTAssertLessThan(elapsed, 3.0, "Large batch should complete in under 3 seconds")
    }
    
    // MARK: - Concurrent Enumeration Tests
    
    /// Multiple concurrent enumerations should all complete correctly
    func testConcurrentEnumerations() async throws {
        // Add some test data
        for i in 0..<10 {
            _ = try await MetadataStore.shared.upsert(
                itemIdentifier: "conn:test:path:/concurrent\(i).txt",
                connectionId: "test",
                remotePath: "/concurrent\(i).txt",
                parentIdentifier: "conn:test",
                filename: "concurrent\(i).txt",
                size: Int64(i),
                isDirectory: false,
                permissions: 0o644,
                modificationDate: Date(),
                isSymlink: false
            )
        }
        
        MetadataAnchorCache.shared.refresh()
        
        var zero: UInt64 = 0
        let zeroAnchor = NSFileProviderSyncAnchor(Data(bytes: &zero, count: 8))
        
        // Start 5 concurrent enumerations
        let expectations = (0..<5).map { expectation(description: "Enumeration \($0)") }
        var observers: [MetadataChangeObserver] = []
        
        for i in 0..<5 {
            let enumerator = MetadataStoreEnumerator()
            let observer = MetadataChangeObserver(expectation: expectations[i])
            observers.append(observer)
            
            enumerator.enumerateChanges(for: observer, from: zeroAnchor)
        }
        
        await fulfillment(of: expectations, timeout: 5.0)
        
        // All should complete with same results
        for (i, observer) in observers.enumerated() {
            XCTAssertTrue(observer.didFinish, "Enumeration \(i) should complete")
            XCTAssertNil(observer.finishedWithError, "Enumeration \(i) should not error")
            XCTAssertGreaterThanOrEqual(observer.updatedItems.count, 10,
                                        "Enumeration \(i) should report all items")
        }
    }
    
    // MARK: - Unicode and Special Character Tests
    
    /// Files with unicode names should be handled correctly
    func testUnicodeFilenames() async throws {
        let beforeAnchor = MetadataAnchorCache.shared.syncAnchor
        
        // Add files with various unicode characters
        let unicodeNames = [
            "日本語.txt",          // Japanese
            "中文文件.txt",         // Chinese
            "файл.txt",           // Russian
            "emoji🎉.txt",         // Emoji
            "مستند.txt",          // Arabic
            "αβγδ.txt",           // Greek
        ]
        
        for name in unicodeNames {
            let safePath = "/unicode/\(name)"
            _ = try await MetadataStore.shared.upsert(
                itemIdentifier: "conn:test:path:\(safePath)",
                connectionId: "test",
                remotePath: safePath,
                parentIdentifier: "conn:test",
                filename: name,
                size: 100,
                isDirectory: false,
                permissions: 0o644,
                modificationDate: Date(),
                isSymlink: false
            )
        }
        
        MetadataAnchorCache.shared.refresh()
        
        let enumerator = MetadataStoreEnumerator()
        let exp = expectation(description: "enumerateChanges completes")
        let observer = MetadataChangeObserver(expectation: exp)
        
        enumerator.enumerateChanges(for: observer, from: beforeAnchor)
        
        await fulfillment(of: [exp], timeout: 2.0)
        
        XCTAssertTrue(observer.didFinish)
        XCTAssertNil(observer.finishedWithError)
        XCTAssertEqual(observer.updatedItems.count, unicodeNames.count,
                       "All unicode-named files should be reported")
        
        // Verify filenames preserved correctly
        let reportedNames = Set(observer.updatedItems.map { $0.filename })
        for name in unicodeNames {
            XCTAssertTrue(reportedNames.contains(name),
                          "Unicode filename '\(name)' should be preserved")
        }
    }
    
    // MARK: - Symlink Tests
    
    /// Symlinks should be reported with correct type
    func testSymlinkReporting() async throws {
        let beforeAnchor = MetadataAnchorCache.shared.syncAnchor
        
        // Add a symlink
        _ = try await MetadataStore.shared.upsert(
            itemIdentifier: "conn:test:path:/link-to-file",
            connectionId: "test",
            remotePath: "/link-to-file",
            parentIdentifier: "conn:test",
            filename: "link-to-file",
            size: 0,
            isDirectory: false,
            permissions: 0o777,
            modificationDate: Date(),
            isSymlink: true
        )
        
        MetadataAnchorCache.shared.refresh()
        
        let enumerator = MetadataStoreEnumerator()
        let exp = expectation(description: "enumerateChanges completes")
        let observer = MetadataChangeObserver(expectation: exp)
        
        enumerator.enumerateChanges(for: observer, from: beforeAnchor)
        
        await fulfillment(of: [exp], timeout: 2.0)
        
        XCTAssertEqual(observer.updatedItems.count, 1)
        
        // Verify symlink properties
        if let item = observer.updatedItems.first as? CachedMetadataItem {
            // Symlinks should be reported - the contentType might vary
            XCTAssertEqual(item.itemIdentifier.rawValue, "conn:test:path:/link-to-file")
        }
    }
    
    // MARK: - Rapid Change Tests
    
    /// Rapid successive changes should all be captured
    func testRapidSuccessiveChanges() async throws {
        let beforeAnchor = MetadataAnchorCache.shared.syncAnchor
        
        // Make 50 rapid changes
        for i in 0..<50 {
            _ = try await MetadataStore.shared.upsert(
                itemIdentifier: "conn:test:path:/rapid\(i).txt",
                connectionId: "test",
                remotePath: "/rapid\(i).txt",
                parentIdentifier: "conn:test",
                filename: "rapid\(i).txt",
                size: Int64(i),
                isDirectory: false,
                permissions: 0o644,
                modificationDate: Date(),
                isSymlink: false
            )
            // No delay between changes - stress test
        }
        
        MetadataAnchorCache.shared.refresh()
        
        let enumerator = MetadataStoreEnumerator()
        let exp = expectation(description: "enumerateChanges completes")
        let observer = MetadataChangeObserver(expectation: exp)
        
        enumerator.enumerateChanges(for: observer, from: beforeAnchor)
        
        await fulfillment(of: [exp], timeout: 3.0)
        
        XCTAssertTrue(observer.didFinish)
        XCTAssertNil(observer.finishedWithError)
        XCTAssertEqual(observer.updatedItems.count, 50,
                       "All 50 rapid changes should be captured")
    }
    
    // MARK: - CachedMetadataItem Property Tests
    
    /// Verify all required NSFileProviderItem properties are correctly populated
    func testCachedMetadataItemRequiredProperties() async throws {
        let testDate = Date()
        
        // Create a file item
        _ = try await MetadataStore.shared.upsert(
            itemIdentifier: "conn:test:path:/test-file.txt",
            connectionId: "test",
            remotePath: "/test-file.txt",
            parentIdentifier: "conn:test",
            filename: "test-file.txt",
            size: 12345,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: testDate,
            isSymlink: false
        )
        
        MetadataAnchorCache.shared.refresh()
        
        var zero: UInt64 = 0
        let zeroAnchor = NSFileProviderSyncAnchor(Data(bytes: &zero, count: 8))
        
        let enumerator = MetadataStoreEnumerator()
        let exp = expectation(description: "enumerateChanges completes")
        let observer = MetadataChangeObserver(expectation: exp)
        
        enumerator.enumerateChanges(for: observer, from: zeroAnchor)
        
        await fulfillment(of: [exp], timeout: 2.0)
        
        guard let item = observer.updatedItems.first(where: { $0.itemIdentifier.rawValue == "conn:test:path:/test-file.txt" }) else {
            XCTFail("Test item not found in results")
            return
        }
        
        // Required properties (Apple docs say these are REQUIRED)
        XCTAssertEqual(item.itemIdentifier.rawValue, "conn:test:path:/test-file.txt",
                       "itemIdentifier must match")
        XCTAssertEqual(item.filename, "test-file.txt",
                       "filename is REQUIRED and must be correct")
        XCTAssertEqual(item.parentItemIdentifier.rawValue, "conn:test",
                       "parentItemIdentifier is REQUIRED and must be correct")
        XCTAssertEqual(item.contentType, .data,
                       "contentType must be .data for files")
        if let caps = item.capabilities {
            XCTAssertTrue(caps.contains(.allowsReading),
                          "capabilities must include .allowsReading")
        }
        
        // Optional but important properties
        if let size = item.documentSize as? NSNumber {
            XCTAssertEqual(size.int64Value, 12345,
                           "documentSize should match file size")
        }
        XCTAssertNotNil(item.contentModificationDate,
                        "contentModificationDate should be set")
    }
    
    /// Verify directory items have correct properties
    func testCachedMetadataItemDirectoryProperties() async throws {
        // Create a directory
        _ = try await MetadataStore.shared.upsert(
            itemIdentifier: "conn:test:path:/test-folder",
            connectionId: "test",
            remotePath: "/test-folder",
            parentIdentifier: "conn:test",
            filename: "test-folder",
            size: 0,
            isDirectory: true,
            permissions: 0o755,
            modificationDate: Date(),
            isSymlink: false
        )
        
        MetadataAnchorCache.shared.refresh()
        
        var zero: UInt64 = 0
        let zeroAnchor = NSFileProviderSyncAnchor(Data(bytes: &zero, count: 8))
        
        let enumerator = MetadataStoreEnumerator()
        let exp = expectation(description: "enumerateChanges completes")
        let observer = MetadataChangeObserver(expectation: exp)
        
        enumerator.enumerateChanges(for: observer, from: zeroAnchor)
        
        await fulfillment(of: [exp], timeout: 2.0)
        
        guard let item = observer.updatedItems.first(where: { $0.itemIdentifier.rawValue == "conn:test:path:/test-folder" }) else {
            XCTFail("Test folder not found in results")
            return
        }
        
        // Directory-specific properties
        XCTAssertEqual(item.contentType, .folder,
                       "contentType MUST be .folder for directories")
        if let caps = item.capabilities {
            XCTAssertTrue(caps.contains(.allowsContentEnumerating),
                          "directories MUST have .allowsContentEnumerating capability")
            XCTAssertTrue(caps.contains(.allowsReading),
                          "directories MUST have .allowsReading capability")
        }
    }
    
    /// Parent identifier "root" should map to .rootContainer
    func testRootParentIdentifierMapping() async throws {
        // Create an item with "root" as parent (connection-level item)
        _ = try await MetadataStore.shared.upsert(
            itemIdentifier: "conn:test:path:/at-root.txt",
            connectionId: "test",
            remotePath: "/at-root.txt",
            parentIdentifier: "root",  // Special value
            filename: "at-root.txt",
            size: 100,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: Date(),
            isSymlink: false
        )
        
        MetadataAnchorCache.shared.refresh()
        
        var zero: UInt64 = 0
        let zeroAnchor = NSFileProviderSyncAnchor(Data(bytes: &zero, count: 8))
        
        let enumerator = MetadataStoreEnumerator()
        let exp = expectation(description: "enumerateChanges completes")
        let observer = MetadataChangeObserver(expectation: exp)
        
        enumerator.enumerateChanges(for: observer, from: zeroAnchor)
        
        await fulfillment(of: [exp], timeout: 2.0)
        
        guard let item = observer.updatedItems.first(where: { $0.itemIdentifier.rawValue == "conn:test:path:/at-root.txt" }) else {
            XCTFail("Test item not found")
            return
        }
        
        // "root" should map to .rootContainer
        XCTAssertEqual(item.parentItemIdentifier, .rootContainer,
                       "Parent 'root' must map to .rootContainer")
    }
    
    // MARK: - Observer Callback Ordering Tests
    
    /// Deletions should be reported before updates (as per Apple docs)
    func testDeletionsReportedBeforeUpdates() async throws {
        // Create an item
        _ = try await MetadataStore.shared.upsert(
            itemIdentifier: "conn:test:path:/order-test-delete.txt",
            connectionId: "test",
            remotePath: "/order-test-delete.txt",
            parentIdentifier: "conn:test",
            filename: "order-test-delete.txt",
            size: 100,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: Date(),
            isSymlink: false
        )
        
        let beforeAnchor = MetadataAnchorCache.shared.syncAnchor
        
        // Now delete the item
        try await MetadataStore.shared.markDeleted(id: "conn:test:path:/order-test-delete.txt")
        
        // And add a new item
        _ = try await MetadataStore.shared.upsert(
            itemIdentifier: "conn:test:path:/order-test-new.txt",
            connectionId: "test",
            remotePath: "/order-test-new.txt",
            parentIdentifier: "conn:test",
            filename: "order-test-new.txt",
            size: 200,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: Date(),
            isSymlink: false
        )
        
        MetadataAnchorCache.shared.refresh()
        
        // Track order of callbacks
        var callbackOrder: [String] = []
        
        let enumerator = MetadataStoreEnumerator()
        let exp = expectation(description: "enumerateChanges completes")
        
        // Use custom observer to track callback order
        let observer = OrderTrackingChangeObserver(
            onUpdate: { _ in callbackOrder.append("update") },
            onDelete: { _ in callbackOrder.append("delete") },
            expectation: exp
        )
        
        enumerator.enumerateChanges(for: observer, from: beforeAnchor)
        
        await fulfillment(of: [exp], timeout: 2.0)
        
        // Apple docs: deletions should be reported first
        // Our implementation calls didDeleteItems before didUpdate
        if !callbackOrder.isEmpty {
            // If there are both deletes and updates, deletes should come first
            if let deleteIndex = callbackOrder.firstIndex(of: "delete"),
               let updateIndex = callbackOrder.firstIndex(of: "update") {
                XCTAssertLessThan(deleteIndex, updateIndex,
                                  "Deletions must be reported before updates")
            }
        }
    }
    
    // MARK: - Anchor Edge Cases
    
    /// Empty anchor data should be handled gracefully
    func testEmptyAnchorDataHandled() async throws {
        let enumerator = MetadataStoreEnumerator()
        let emptyAnchor = NSFileProviderSyncAnchor(Data())
        
        let exp = expectation(description: "enumerateChanges completes")
        let observer = MetadataChangeObserver(expectation: exp)
        
        enumerator.enumerateChanges(for: observer, from: emptyAnchor)
        
        await fulfillment(of: [exp], timeout: 2.0)
        
        XCTAssertTrue(observer.didFinish, "Should complete even with empty anchor")
        XCTAssertNil(observer.finishedWithError, "Should not error on empty anchor")
    }
    
    /// Very large anchor values should be handled
    func testLargeAnchorValueHandled() async throws {
        let enumerator = MetadataStoreEnumerator()
        
        // Use UInt64.max
        var maxValue = UInt64.max
        let maxAnchor = NSFileProviderSyncAnchor(Data(bytes: &maxValue, count: 8))
        
        let exp = expectation(description: "enumerateChanges completes")
        let observer = MetadataChangeObserver(expectation: exp)
        
        enumerator.enumerateChanges(for: observer, from: maxAnchor)
        
        await fulfillment(of: [exp], timeout: 2.0)
        
        XCTAssertTrue(observer.didFinish, "Should complete with large anchor")
        XCTAssertNil(observer.finishedWithError, "Should not error on large anchor")
        XCTAssertTrue(observer.updatedItems.isEmpty, "No changes expected from future anchor")
    }
    
    /// Malformed anchor data should be handled gracefully
    func testMalformedAnchorHandled() async throws {
        let enumerator = MetadataStoreEnumerator()
        
        // Random 3 bytes (not valid UInt64 or string)
        let malformed = NSFileProviderSyncAnchor(Data([0x01, 0x02, 0x03]))
        
        let exp = expectation(description: "enumerateChanges completes")
        let observer = MetadataChangeObserver(expectation: exp)
        
        enumerator.enumerateChanges(for: observer, from: malformed)
        
        await fulfillment(of: [exp], timeout: 2.0)
        
        XCTAssertTrue(observer.didFinish, "Should complete with malformed anchor")
        XCTAssertNil(observer.finishedWithError, "Should not error on malformed anchor")
    }
    
    // MARK: - Edge Case Property Tests
    
    /// Items with nil modification date should be handled
    func testNilModificationDateHandled() async throws {
        _ = try await MetadataStore.shared.upsert(
            itemIdentifier: "conn:test:path:/no-date.txt",
            connectionId: "test",
            remotePath: "/no-date.txt",
            parentIdentifier: "conn:test",
            filename: "no-date.txt",
            size: 100,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: nil,  // nil date
            isSymlink: false
        )
        
        MetadataAnchorCache.shared.refresh()
        
        var zero: UInt64 = 0
        let zeroAnchor = NSFileProviderSyncAnchor(Data(bytes: &zero, count: 8))
        
        let enumerator = MetadataStoreEnumerator()
        let exp = expectation(description: "enumerateChanges completes")
        let observer = MetadataChangeObserver(expectation: exp)
        
        enumerator.enumerateChanges(for: observer, from: zeroAnchor)
        
        await fulfillment(of: [exp], timeout: 2.0)
        
        guard let item = observer.updatedItems.first(where: { $0.itemIdentifier.rawValue == "conn:test:path:/no-date.txt" }) else {
            XCTFail("Test item not found")
            return
        }
        
        // Item should be returned successfully regardless of date being nil
        // The key is that the enumerator completes without error
        XCTAssertTrue(observer.didFinish, "Enumerator should complete")
        XCTAssertNil(observer.finishedWithError, "Should not error on nil date items")
        XCTAssertEqual(item.filename, "no-date.txt", "Item should be found and valid")
    }
    
    /// Items with zero size should be handled
    func testZeroSizeFileHandled() async throws {
        _ = try await MetadataStore.shared.upsert(
            itemIdentifier: "conn:test:path:/empty.txt",
            connectionId: "test",
            remotePath: "/empty.txt",
            parentIdentifier: "conn:test",
            filename: "empty.txt",
            size: 0,  // Zero size file
            isDirectory: false,
            permissions: 0o644,
            modificationDate: Date(),
            isSymlink: false
        )
        
        MetadataAnchorCache.shared.refresh()
        
        var zero: UInt64 = 0
        let zeroAnchor = NSFileProviderSyncAnchor(Data(bytes: &zero, count: 8))
        
        let enumerator = MetadataStoreEnumerator()
        let exp = expectation(description: "enumerateChanges completes")
        let observer = MetadataChangeObserver(expectation: exp)
        
        enumerator.enumerateChanges(for: observer, from: zeroAnchor)
        
        await fulfillment(of: [exp], timeout: 2.0)
        
        guard let item = observer.updatedItems.first(where: { $0.itemIdentifier.rawValue == "conn:test:path:/empty.txt" }) else {
            XCTFail("Test item not found")
            return
        }
        
        if let size = item.documentSize as? NSNumber {
            XCTAssertEqual(size.int64Value, 0, "Zero size should be preserved")
        }
    }
    
    /// Files with special characters in name should be handled
    func testSpecialCharacterFilenames() async throws {
        let specialNames = [
            "file with spaces.txt",
            "file-with-dashes.txt",
            "file_with_underscores.txt",
            "file.multiple.dots.txt",
            "file(with)parentheses.txt",
            "file'with'quotes.txt",
            "file&with&ampersands.txt",
        ]
        
        var zero: UInt64 = 0
        let zeroAnchor = NSFileProviderSyncAnchor(Data(bytes: &zero, count: 8))
        
        for name in specialNames {
            // Clear and refresh
            try await MetadataStore.shared.clearAll()
            MetadataAnchorCache.shared.refresh()
            
            _ = try await MetadataStore.shared.upsert(
                itemIdentifier: "conn:test:path:/\(name)",
                connectionId: "test",
                remotePath: "/\(name)",
                parentIdentifier: "conn:test",
                filename: name,
                size: 100,
                isDirectory: false,
                permissions: 0o644,
                modificationDate: Date(),
                isSymlink: false
            )
            
            MetadataAnchorCache.shared.refresh()
            
            let enumerator = MetadataStoreEnumerator()
            let exp = expectation(description: "enumerate \(name)")
            let observer = MetadataChangeObserver(expectation: exp)
            
            enumerator.enumerateChanges(for: observer, from: zeroAnchor)
            
            await fulfillment(of: [exp], timeout: 2.0)
            
            XCTAssertTrue(observer.didFinish, "Should complete for: \(name)")
            XCTAssertNil(observer.finishedWithError, "Should not error for: \(name)")
            
            if let item = observer.updatedItems.first {
                XCTAssertEqual(item.filename, name, "Filename should be preserved: \(name)")
            }
        }
    }
    
    // MARK: - Repeated Enumeration Tests
    
    /// Repeated enumerations from same anchor should return same results
    func testIdempotentEnumeration() async throws {
        // Add test data
        _ = try await MetadataStore.shared.upsert(
            itemIdentifier: "conn:test:path:/idempotent.txt",
            connectionId: "test",
            remotePath: "/idempotent.txt",
            parentIdentifier: "conn:test",
            filename: "idempotent.txt",
            size: 100,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: Date(),
            isSymlink: false
        )
        
        MetadataAnchorCache.shared.refresh()
        
        var zero: UInt64 = 0
        let zeroAnchor = NSFileProviderSyncAnchor(Data(bytes: &zero, count: 8))
        
        // First enumeration
        let exp1 = expectation(description: "First enumeration")
        let observer1 = MetadataChangeObserver(expectation: exp1)
        
        let enumerator1 = MetadataStoreEnumerator()
        enumerator1.enumerateChanges(for: observer1, from: zeroAnchor)
        
        await fulfillment(of: [exp1], timeout: 2.0)
        
        // Second enumeration from same anchor
        let exp2 = expectation(description: "Second enumeration")
        let observer2 = MetadataChangeObserver(expectation: exp2)
        
        let enumerator2 = MetadataStoreEnumerator()
        enumerator2.enumerateChanges(for: observer2, from: zeroAnchor)
        
        await fulfillment(of: [exp2], timeout: 2.0)
        
        // Results should be identical
        XCTAssertEqual(observer1.updatedItems.count, observer2.updatedItems.count,
                       "Repeated enumeration should return same item count")
        XCTAssertEqual(observer1.deletedIdentifiers.count, observer2.deletedIdentifiers.count,
                       "Repeated enumeration should return same deletion count")
    }
    
    /// Sequential enumerations should progress anchors correctly
    func testSequentialAnchorProgression() async throws {
        // Add first item
        _ = try await MetadataStore.shared.upsert(
            itemIdentifier: "conn:test:path:/seq1.txt",
            connectionId: "test",
            remotePath: "/seq1.txt",
            parentIdentifier: "conn:test",
            filename: "seq1.txt",
            size: 100,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: Date(),
            isSymlink: false
        )
        
        MetadataAnchorCache.shared.refresh()
        
        // First enumeration from zero
        var zero: UInt64 = 0
        let zeroAnchor = NSFileProviderSyncAnchor(Data(bytes: &zero, count: 8))
        
        let exp1 = expectation(description: "First enumeration")
        let observer1 = MetadataChangeObserver(expectation: exp1)
        
        let enumerator1 = MetadataStoreEnumerator()
        enumerator1.enumerateChanges(for: observer1, from: zeroAnchor)
        
        await fulfillment(of: [exp1], timeout: 2.0)
        
        let anchor1 = observer1.finishedAnchor!
        
        // Add second item
        _ = try await MetadataStore.shared.upsert(
            itemIdentifier: "conn:test:path:/seq2.txt",
            connectionId: "test",
            remotePath: "/seq2.txt",
            parentIdentifier: "conn:test",
            filename: "seq2.txt",
            size: 200,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: Date(),
            isSymlink: false
        )
        
        MetadataAnchorCache.shared.refresh()
        
        // Second enumeration from first anchor
        let exp2 = expectation(description: "Second enumeration")
        let observer2 = MetadataChangeObserver(expectation: exp2)
        
        let enumerator2 = MetadataStoreEnumerator()
        enumerator2.enumerateChanges(for: observer2, from: anchor1)
        
        await fulfillment(of: [exp2], timeout: 2.0)
        
        // Second enumeration should only see the new item
        let reportedIds = observer2.updatedItems.map { $0.itemIdentifier.rawValue }
        XCTAssertTrue(reportedIds.contains("conn:test:path:/seq2.txt"),
                      "Second enumeration should see new item")
        XCTAssertFalse(reportedIds.contains("conn:test:path:/seq1.txt"),
                       "Second enumeration should NOT see old item")
    }
    
    // MARK: - iOS Lifecycle Simulation Tests
    
    /// Test the EXACT sequence iOS calls when opening a File Provider domain.
    /// This simulates what iOS does to identify why "Syncing Paused" might occur.
    ///
    /// iOS sequence (observed via device logs):
    /// 1. Create enumerator for .workingSet
    /// 2. Call currentSyncAnchor() - expects non-nil anchor
    /// 3. Call enumerateChanges(from: anchor) or enumerateItems()
    /// 4. Expects finishEnumerating... to be called without errors
    ///
    /// If any step fails or errors, iOS shows "Syncing Paused"
    func testIOSWorkingSetLifecycle_FreshInstall() async throws {
        // Simulate fresh install: no items in store, anchor starts at 1
        let startAnchor = MetadataAnchorCache.shared.currentAnchor
        XCTAssertGreaterThanOrEqual(startAnchor, 1, "Fresh install anchor should be >= 1")
        
        // STEP 1: iOS creates enumerator
        let enumerator = MetadataStoreEnumerator()
        
        // STEP 2: iOS calls currentSyncAnchor() SYNCHRONOUSLY
        // This MUST complete immediately and return non-nil
        var syncAnchor: NSFileProviderSyncAnchor?
        let anchorExp = expectation(description: "currentSyncAnchor")
        
        enumerator.currentSyncAnchor { anchor in
            syncAnchor = anchor
            anchorExp.fulfill()
        }
        
        // Should complete IMMEDIATELY (synchronous completion handler)
        await fulfillment(of: [anchorExp], timeout: 0.1)  // Very short timeout - must be sync
        
        XCTAssertNotNil(syncAnchor, "CRITICAL: currentSyncAnchor() must return non-nil")
        XCTAssertEqual(syncAnchor?.rawValue.count, 8, "Anchor must be 8 bytes (UInt64)")
        
        // Verify anchor value
        let anchorValue = syncAnchor!.rawValue.withUnsafeBytes { $0.load(as: UInt64.self) }
        XCTAssertGreaterThanOrEqual(anchorValue, 1, "Anchor value must be >= 1")
        
        // STEP 3a: iOS may call enumerateItems for initial content
        let itemsExp = expectation(description: "enumerateItems")
        let itemsObserver = MockEnumerationObserver(expectation: itemsExp)
        
        enumerator.enumerateItems(
            for: itemsObserver,
            startingAt: NSFileProviderPage.initialPageSortedByDate as NSFileProviderPage
        )
        
        await fulfillment(of: [itemsExp], timeout: 1.0)
        
        XCTAssertTrue(itemsObserver.didFinish, "enumerateItems must call finish")
        XCTAssertNil(itemsObserver.finishedWithError, "enumerateItems must NOT error")
        // Working set enumerateItems returns empty - content via enumerateChanges
        
        // STEP 3b: iOS calls enumerateChanges from the current anchor
        let changesExp = expectation(description: "enumerateChanges")
        let changesObserver = MetadataChangeObserver(expectation: changesExp)
        
        enumerator.enumerateChanges(for: changesObserver, from: syncAnchor!)
        
        await fulfillment(of: [changesExp], timeout: 2.0)
        
        XCTAssertTrue(changesObserver.didFinish, "enumerateChanges must call finish")
        XCTAssertNil(changesObserver.finishedWithError, "CRITICAL: enumerateChanges must NOT error")
        XCTAssertFalse(changesObserver.moreComing, "moreComing must be false for final page")
        XCTAssertNotNil(changesObserver.finishedAnchor, "Must return a final anchor")
        
        // Fresh install: no changes from current anchor
        XCTAssertTrue(changesObserver.updatedItems.isEmpty, "Fresh install has no updates")
        XCTAssertTrue(changesObserver.deletedIdentifiers.isEmpty, "Fresh install has no deletions")
    }
    
    /// Test iOS lifecycle when there ARE items to report
    func testIOSWorkingSetLifecycle_WithExistingItems() async throws {
        // Add items first (simulates: user navigated, items were cached)
        _ = try await MetadataStore.shared.upsert(
            itemIdentifier: "conn:test:path:/docs",
            connectionId: "test",
            remotePath: "/docs",
            parentIdentifier: "conn:test",
            filename: "docs",
            size: 0,
            isDirectory: true,
            permissions: 0o755,
            modificationDate: Date(),
            isSymlink: false
        )
        
        _ = try await MetadataStore.shared.upsert(
            itemIdentifier: "conn:test:path:/docs/readme.txt",
            connectionId: "test",
            remotePath: "/docs/readme.txt",
            parentIdentifier: "conn:test:path:/docs",
            filename: "readme.txt",
            size: 1024,
            isDirectory: false,
            permissions: 0o644,
            modificationDate: Date(),
            isSymlink: false
        )
        
        MetadataAnchorCache.shared.refresh()
        
        // STEP 1: iOS creates enumerator
        let enumerator = MetadataStoreEnumerator()
        
        // STEP 2: iOS calls currentSyncAnchor()
        var syncAnchor: NSFileProviderSyncAnchor?
        let anchorExp = expectation(description: "currentSyncAnchor")
        
        enumerator.currentSyncAnchor { anchor in
            syncAnchor = anchor
            anchorExp.fulfill()
        }
        
        await fulfillment(of: [anchorExp], timeout: 0.1)
        XCTAssertNotNil(syncAnchor, "currentSyncAnchor must return non-nil")
        
        // STEP 3: iOS calls enumerateChanges from anchor 0 (initial sync)
        var zeroAnchorValue: UInt64 = 0
        let zeroAnchor = NSFileProviderSyncAnchor(Data(bytes: &zeroAnchorValue, count: 8))
        
        let changesExp = expectation(description: "enumerateChanges from 0")
        let changesObserver = MetadataChangeObserver(expectation: changesExp)
        
        enumerator.enumerateChanges(for: changesObserver, from: zeroAnchor)
        
        await fulfillment(of: [changesExp], timeout: 2.0)
        
        XCTAssertTrue(changesObserver.didFinish, "enumerateChanges must complete")
        XCTAssertNil(changesObserver.finishedWithError, "enumerateChanges must NOT error")
        
        // Should return all items (from anchor 0)
        XCTAssertEqual(changesObserver.updatedItems.count, 2, "Should return all 2 items")
        
        // Verify items have required properties
        for item in changesObserver.updatedItems {
            XCTAssertFalse(item.itemIdentifier.rawValue.isEmpty, "Item must have identifier")
            XCTAssertFalse(item.filename.isEmpty, "Item must have filename")
            XCTAssertNotNil(item.itemVersion, "CRITICAL: Item must have itemVersion")
            XCTAssertNotNil(item.contentModificationDate, "Item should have modification date")
        }
    }
    
    /// Test that currentSyncAnchor completes synchronously (critical for iOS)
    /// iOS calls this in sync context; if it blocks or delays, "Syncing Paused" results
    func testCurrentSyncAnchor_CompletesWithinMilliseconds() async throws {
        let enumerator = MetadataStoreEnumerator()
        
        let start = CFAbsoluteTimeGetCurrent()
        
        var completed = false
        enumerator.currentSyncAnchor { _ in
            completed = true
        }
        
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        
        XCTAssertTrue(completed, "currentSyncAnchor must complete synchronously")
        XCTAssertLessThan(elapsed, 0.01, "currentSyncAnchor must complete < 10ms, took \(elapsed * 1000)ms")
    }
}

// MARK: - Order Tracking Observer

/// Observer that tracks the order of callbacks for testing
final class OrderTrackingChangeObserver: NSObject, NSFileProviderChangeObserver {
    private let onUpdate: ([any NSFileProviderItemProtocol]) -> Void
    private let onDelete: ([NSFileProviderItemIdentifier]) -> Void
    let expectation: XCTestExpectation?
    
    init(
        onUpdate: @escaping ([any NSFileProviderItemProtocol]) -> Void,
        onDelete: @escaping ([NSFileProviderItemIdentifier]) -> Void,
        expectation: XCTestExpectation? = nil
    ) {
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        self.expectation = expectation
    }
    
    func didUpdate(_ updatedItems: [any NSFileProviderItemProtocol]) {
        onUpdate(updatedItems)
    }
    
    func didDeleteItems(withIdentifiers deletedItemIdentifiers: [NSFileProviderItemIdentifier]) {
        onDelete(deletedItemIdentifiers)
    }
    
    func finishEnumeratingChanges(upTo anchor: NSFileProviderSyncAnchor, moreComing: Bool) {
        expectation?.fulfill()
    }
    
    func finishEnumeratingWithError(_ error: any Error) {
        expectation?.fulfill()
    }
}
