//
//  MetadataStore.swift
//  Geistty
//
//  Actor that manages all File Provider metadata and sync state.
//  Single source of truth for cached file metadata and sync anchors.
//
//  Architecture:
//  - Actor isolation for thread safety
//  - Owns SwiftData ModelContainer in shared App Group
//  - Provides anchor-based change queries for enumerateChanges()
//  - Handles both main app and File Provider extension access
//
//  Key Design Decisions:
//  - Monotonic UInt64 anchor (not VERSION-ITERATION)
//  - Permissive change enumeration (any older anchor, not strict +1)
//  - Soft deletes for change tracking (deletedAtAnchor)
//  - Task-based async for File Provider callbacks (Apple-approved)
//

import FileProvider
import Foundation
import os.log
import SwiftData

private let logger = Logger(subsystem: "com.geistty", category: "MetadataStore")

// MARK: - Item Identifier Helpers

/// Helper functions for constructing item identifiers
/// Format: "conn:<connectionId>" for root, "conn:<connectionId>:path:<remotePath>" for files
enum ItemIdentifier {
    
    /// Create identifier for connection root
    static func connectionRoot(_ connectionId: String) -> String {
        "conn:\(connectionId)"
    }
    
    /// Create identifier for remote item
    static func remoteItem(connectionId: String, path: String) -> String {
        "conn:\(connectionId):path:\(path)"
    }
    
    /// Parse connection ID from item identifier
    static func parseConnectionId(from identifier: String) -> String? {
        guard identifier.hasPrefix("conn:") else { return nil }
        let afterConn = identifier.dropFirst(5) // "conn:"
        if let pathRange = afterConn.range(of: ":path:") {
            return String(afterConn[..<pathRange.lowerBound])
        }
        return String(afterConn)
    }
    
    /// Parse remote path from item identifier
    static func parseRemotePath(from identifier: String) -> String? {
        guard let range = identifier.range(of: ":path:") else { return nil }
        return String(identifier[range.upperBound...])
    }
    
    /// Check if identifier is a connection root
    static func isConnectionRoot(_ identifier: String) -> Bool {
        identifier.hasPrefix("conn:") && !identifier.contains(":path:")
    }
}

// MARK: - Synchronous Anchor Cache

/// Thread-safe synchronous cache for sync anchors.
/// File Provider completion handlers MUST be called synchronously.
/// This cache allows currentSyncAnchor() calls to work in sync context.
///
/// CRITICAL: This cache loads persisted anchor on init to avoid race conditions.
/// The MetadataStore actor updates this cache whenever anchor changes.
final class MetadataAnchorCache: @unchecked Sendable {
    static let shared = MetadataAnchorCache()
    
    private let lock = NSLock()
    private var _currentAnchor: UInt64 = 0
    private var _syncAnchor: NSFileProviderSyncAnchor?
    
    /// App group identifier - must match MetadataStore
    private let appGroupIdentifier = "group.com.geistty.fileprovider"
    
    private init() {
        // CRITICAL: Load persisted anchor synchronously on init
        // This ensures currentSyncAnchor() has a valid value before any async code runs
        if let anchor = Self.loadPersistedAnchor(appGroupIdentifier: appGroupIdentifier), anchor > 0 {
            // Valid persisted anchor (must be > 0)
            _currentAnchor = anchor
            var value = anchor
            let data = Data(bytes: &value, count: 8)
            _syncAnchor = NSFileProviderSyncAnchor(data)
            NSLog("📂 [MetadataAnchorCache] Loaded persisted anchor: %llu", anchor)
        } else {
            // No valid persisted anchor OR anchor was 0 - start at 1 (fresh install)
            // CRITICAL: Start at 1 so enumerateChanges(from: 0) can detect changes
            _currentAnchor = 1
            var value: UInt64 = 1
            let data = Data(bytes: &value, count: 8)
            _syncAnchor = NSFileProviderSyncAnchor(data)
            savePersistedAnchor(1)  // Persist immediately
            NSLog("📂 [MetadataAnchorCache] No valid persisted anchor, starting at 1")
        }
    }
    
    /// Load anchor from persisted storage synchronously
    /// Uses a simple file-based approach for reliability
    private static func loadPersistedAnchor(appGroupIdentifier: String) -> UInt64? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return nil
        }
        
        let anchorFile = containerURL.appendingPathComponent("sync_anchor.dat")
        
        guard let data = try? Data(contentsOf: anchorFile),
              data.count == 8 else {
            return nil
        }
        
        return data.withUnsafeBytes { $0.load(as: UInt64.self) }
    }
    
    /// Save anchor to persisted storage synchronously
    private func savePersistedAnchor(_ anchor: UInt64) {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return
        }
        
        let anchorFile = containerURL.appendingPathComponent("sync_anchor.dat")
        var value = anchor
        let data = Data(bytes: &value, count: 8)
        try? data.write(to: anchorFile, options: .atomic)
    }
    
    /// Current anchor value (synchronous)
    var currentAnchor: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _currentAnchor
    }
    
    /// Current sync anchor for File Provider (synchronous)
    var syncAnchor: NSFileProviderSyncAnchor {
        lock.lock()
        defer { lock.unlock() }
        if let anchor = _syncAnchor {
            return anchor
        }
        // Create from current anchor value
        var value = _currentAnchor
        let data = Data(bytes: &value, count: 8)
        return NSFileProviderSyncAnchor(data)
    }
    
    /// Update cache (called from MetadataStore actor)
    func update(anchor: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        _currentAnchor = anchor
        var value = anchor
        let data = Data(bytes: &value, count: 8)
        _syncAnchor = NSFileProviderSyncAnchor(data)
        
        // Persist to file for next launch
        savePersistedAnchor(anchor)
        
        logger.debug("🔄 MetadataAnchorCache updated: \(anchor)")
    }
    
    /// Refresh cache from persisted storage (used after reset)
    func refresh() {
        lock.lock()
        defer { lock.unlock() }
        
        if let anchor = Self.loadPersistedAnchor(appGroupIdentifier: appGroupIdentifier), anchor > 0 {
            _currentAnchor = anchor
            var value = anchor
            let data = Data(bytes: &value, count: 8)
            _syncAnchor = NSFileProviderSyncAnchor(data)
        } else {
            // No valid persisted anchor - reset to 1
            _currentAnchor = 1
            var value: UInt64 = 1
            let data = Data(bytes: &value, count: 8)
            _syncAnchor = NSFileProviderSyncAnchor(data)
            savePersistedAnchor(1)
        }
        
        logger.debug("🔄 MetadataAnchorCache refreshed: \(self._currentAnchor)")
    }
}

// MARK: - MetadataStore Actor

/// Actor that owns all File Provider metadata and sync state
actor MetadataStore {
    
    /// Shared singleton instance
    static let shared = MetadataStore()
    
    /// App Group identifier for shared storage
    private let appGroupIdentifier = "group.com.geistty.fileprovider"
    
    /// SwiftData model container
    private var container: ModelContainer?
    
    /// Staleness threshold for cache (5 minutes)
    private let staleThreshold: TimeInterval = 300
    
    private init() {}
    
    // MARK: - Container Management
    
    /// Get or create the SwiftData model container
    private func getContainer() throws -> ModelContainer {
        if let container = container {
            return container
        }
        
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw MetadataStoreError.appGroupUnavailable
        }
        
        let storeURL = containerURL.appendingPathComponent("MetadataStore.sqlite")
        
        let schema = Schema([CachedFileMetadata.self, SyncState.self, ActiveFolderRecord.self])
        let config = ModelConfiguration(
            "MetadataStore",
            schema: schema,
            url: storeURL,
            allowsSave: true
        )
        
        let newContainer = try ModelContainer(for: schema, configurations: [config])
        self.container = newContainer
        
        logger.info("📦 MetadataStore initialized at \(storeURL.path)")
        return newContainer
    }
    
    /// Get or create the SyncState record within the given context
    /// This ensures SyncState changes are saved with the same context as other operations
    private func getSyncState(in context: ModelContext) throws -> SyncState {
        // Try to fetch existing sync state
        let descriptor = FetchDescriptor<SyncState>()
        if let existing = try context.fetch(descriptor).first {
            logger.debug("📦 Loaded existing SyncState: anchor=\(existing.currentAnchor)")
            return existing
        }
        
        // Create new sync state - starts at anchor 1
        let newState = SyncState()
        context.insert(newState)
        
        // CRITICAL: Save immediately so the new state persists
        try context.save()
        
        logger.info("📦 Created and saved new SyncState: anchor=\(newState.currentAnchor)")
        
        // Update synchronous cache
        MetadataAnchorCache.shared.update(anchor: newState.currentAnchor)
        
        return newState
    }
    
    // MARK: - Sync Anchor API
    
    /// Current anchor value
    /// CRITICAL: If anchor is 0, reset to 1 (legacy data migration)
    var currentAnchor: UInt64 {
        get throws {
            let container = try getContainer()
            let context = ModelContext(container)
            let state = try getSyncState(in: context)
            var anchor = state.currentAnchor
            
            // Fix legacy data: anchor must be >= 1
            if anchor == 0 {
                state.currentAnchor = 1
                try context.save()
                anchor = 1
                logger.warning("📦 Fixed legacy anchor: 0 → 1")
            }
            
            // Keep sync cache updated
            MetadataAnchorCache.shared.update(anchor: anchor)
            return anchor
        }
    }
    
    /// Current anchor as NSFileProviderSyncAnchor
    var currentSyncAnchor: NSFileProviderSyncAnchor {
        get throws {
            let container = try getContainer()
            let context = ModelContext(container)
            return try getSyncState(in: context).toSyncAnchor()
        }
    }
    
    /// Increment anchor and return the new value
    /// Call this when recording changes
    func incrementAnchor() throws -> UInt64 {
        let container = try getContainer()
        let context = ModelContext(container)
        let state = try getSyncState(in: context)
        let newAnchor = state.incrementAndGet()
        
        try context.save()  // Save in same context as SyncState
        
        // Update synchronous cache
        MetadataAnchorCache.shared.update(anchor: newAnchor)
        
        logger.debug("📦 Anchor incremented to \(newAnchor)")
        return newAnchor
    }
    
    // MARK: - Synchronous Access (for File Provider callbacks)
    
    /// Get item synchronously - blocks calling thread
    /// WARNING: Only use in File Provider synchronous callbacks
    nonisolated func itemSync(id: String) -> CachedFileMetadata? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: CachedFileMetadata?
        
        Task {
            result = try? await self.item(id: id)
            semaphore.signal()
        }
        
        semaphore.wait()
        return result
    }
    
    // MARK: - Item Queries
    
    /// Get item by identifier
    func item(id: String) throws -> CachedFileMetadata? {
        let container = try getContainer()
        let context = ModelContext(container)
        
        let targetId = id
        let predicate = #Predicate<CachedFileMetadata> { item in
            item.itemIdentifier == targetId && item.deletedAtAnchor == nil
        }
        let descriptor = FetchDescriptor<CachedFileMetadata>(predicate: predicate)
        
        return try context.fetch(descriptor).first
    }
    
    /// Get all active items in a folder (for enumeration)
    func items(inFolder parentId: String) throws -> [CachedFileMetadata] {
        let container = try getContainer()
        let context = ModelContext(container)
        
        let targetParentId = parentId
        let predicate = #Predicate<CachedFileMetadata> { item in
            item.parentIdentifier == targetParentId && item.deletedAtAnchor == nil
        }
        let descriptor = FetchDescriptor<CachedFileMetadata>(predicate: predicate)
        
        return try context.fetch(descriptor)
    }
    
    /// Get all active items for a connection
    func items(forConnection connectionId: String) throws -> [CachedFileMetadata] {
        let container = try getContainer()
        let context = ModelContext(container)
        
        let targetConnectionId = connectionId
        let predicate = #Predicate<CachedFileMetadata> { item in
            item.connectionId == targetConnectionId && item.deletedAtAnchor == nil
        }
        let descriptor = FetchDescriptor<CachedFileMetadata>(predicate: predicate)
        
        return try context.fetch(descriptor)
    }
    
    /// Get all active items (for working set)
    func allActiveItems() throws -> [CachedFileMetadata] {
        let container = try getContainer()
        let context = ModelContext(container)
        
        let predicate = #Predicate<CachedFileMetadata> { item in
            item.deletedAtAnchor == nil
        }
        let descriptor = FetchDescriptor<CachedFileMetadata>(predicate: predicate)
        
        return try context.fetch(descriptor)
    }
    
    // MARK: - Change Queries (for enumerateChanges)
    
    /// Get items modified since the given anchor (creates + updates)
    /// Returns items where modifiedAtAnchor > anchor AND not deleted
    func itemsModified(since anchor: UInt64) throws -> [CachedFileMetadata] {
        let container = try getContainer()
        let context = ModelContext(container)
        
        let targetAnchor = anchor
        let predicate = #Predicate<CachedFileMetadata> { item in
            item.modifiedAtAnchor > targetAnchor && item.deletedAtAnchor == nil
        }
        let descriptor = FetchDescriptor<CachedFileMetadata>(predicate: predicate)
        
        return try context.fetch(descriptor)
    }
    
    /// Get item identifiers deleted since the given anchor
    /// Returns identifiers where deletedAtAnchor > anchor
    func deletions(since anchor: UInt64) throws -> [String] {
        let container = try getContainer()
        let context = ModelContext(container)
        
        // SwiftData predicate can't directly compare optional > value
        // Fetch all with deletedAtAnchor != nil, then filter
        let predicate = #Predicate<CachedFileMetadata> { item in
            item.deletedAtAnchor != nil
        }
        let descriptor = FetchDescriptor<CachedFileMetadata>(predicate: predicate)
        
        let deleted = try context.fetch(descriptor)
        return deleted
            .filter { $0.deletedAtAnchor! > anchor }
            .map { $0.itemIdentifier }
    }
    
    /// Get all changes since anchor in a format ready for enumerateChanges()
    /// CRITICAL: This is the permissive approach - accepts ANY older anchor
    /// Returns (modifiedItems, deletedIdentifiers, newAnchor)
    func changesSince(anchor: UInt64) throws -> (
        modified: [CachedFileMetadata],
        deletions: [String],
        newAnchor: UInt64
    ) {
        let currentAnchorValue = try currentAnchor
        
        // If anchor is same as current, no changes
        guard anchor < currentAnchorValue else {
            return ([], [], currentAnchorValue)
        }
        
        // Get all modified items since anchor
        let modified = try itemsModified(since: anchor)
        
        // Get all deletions since anchor
        let deletedIds = try deletions(since: anchor)
        
        logger.debug("📦 Changes since \(anchor): \(modified.count) modified, \(deletedIds.count) deleted")
        
        return (modified, deletedIds, currentAnchorValue)
    }
    
    // MARK: - Reset Operations
    
    /// Reset the metadata store for domain clearing.
    /// Deletes all data and resets anchor to 1.
    /// Called during domain reset to ensure clean state.
    func resetForDomainClear() async throws {
        let container = try getContainer()
        let context = ModelContext(container)
        
        // Delete all cached metadata (includes soft-deleted items via deletedAtAnchor)
        try context.delete(model: CachedFileMetadata.self)
        
        // Delete all active folders
        try context.delete(model: ActiveFolderRecord.self)
        
        // Reset sync state to anchor 1
        let statePredicate = #Predicate<SyncState> { _ in true }
        let stateDescriptor = FetchDescriptor<SyncState>(predicate: statePredicate)
        if let existingState = try context.fetch(stateDescriptor).first {
            existingState.currentAnchor = 1
            existingState.lastModified = Date()
        } else {
            // Create new state - init() sets anchor to 1
            let newState = SyncState()
            context.insert(newState)
        }
        
        try context.save()
        
        // Reset the synchronous cache
        MetadataAnchorCache.shared.update(anchor: 1)
        
        logger.info("📦 MetadataStore reset complete - anchor reset to 1")
    }
    
    // MARK: - Write Operations
    
    /// Upsert an item from SFTP attributes
    /// Returns (item, isNew) tuple
    @discardableResult
    func upsert(
        itemIdentifier: String,
        connectionId: String,
        remotePath: String,
        parentIdentifier: String,
        filename: String,
        size: Int64,
        isDirectory: Bool,
        permissions: Int32,
        modificationDate: Date?,
        isSymlink: Bool
    ) throws -> (item: CachedFileMetadata, isNew: Bool) {
        let container = try getContainer()
        let context = ModelContext(container)
        
        // Get SyncState in SAME context - critical for proper save
        let state = try getSyncState(in: context)
        let anchor = state.incrementAndGet()
        
        // Update synchronous cache with new anchor
        MetadataAnchorCache.shared.update(anchor: anchor)
        
        // Check if item exists
        let targetId = itemIdentifier
        let predicate = #Predicate<CachedFileMetadata> { item in
            item.itemIdentifier == targetId
        }
        let descriptor = FetchDescriptor<CachedFileMetadata>(predicate: predicate)
        
        if let existing = try context.fetch(descriptor).first {
            // Update existing item
            existing.filename = filename
            existing.size = size
            existing.isDirectory = isDirectory
            existing.permissions = permissions
            existing.modificationDate = modificationDate
            existing.isSymlink = isSymlink
            existing.modifiedAtAnchor = anchor
            existing.deletedAtAnchor = nil  // Undelete if was soft-deleted
            existing.cachedAt = Date()
            
            try context.save()  // Saves both SyncState and CachedFileMetadata
            logger.debug("📦 Updated item: \(filename) @ anchor \(anchor)")
            return (existing, false)
        } else {
            // Insert new item
            let newItem = CachedFileMetadata(
                itemIdentifier: itemIdentifier,
                connectionId: connectionId,
                remotePath: remotePath,
                parentIdentifier: parentIdentifier,
                filename: filename,
                size: size,
                isDirectory: isDirectory,
                permissions: permissions,
                modificationDate: modificationDate,
                isSymlink: isSymlink,
                createdAtAnchor: anchor,
                modifiedAtAnchor: anchor,
                deletedAtAnchor: nil,
                cachedAt: Date(),
                childrenCached: false
            )
            
            context.insert(newItem)
            try context.save()  // Saves both SyncState and CachedFileMetadata
            logger.debug("📦 Inserted item: \(filename) @ anchor \(anchor)")
            return (newItem, true)
        }
    }
    
    /// Mark an item as deleted (soft delete)
    /// Returns the deletion anchor
    @discardableResult
    func markDeleted(id: String) throws -> UInt64 {
        let container = try getContainer()
        let context = ModelContext(container)
        
        // Get SyncState in SAME context
        let state = try getSyncState(in: context)
        let anchor = state.incrementAndGet()
        
        // Update synchronous cache with new anchor
        MetadataAnchorCache.shared.update(anchor: anchor)
        
        let targetId = id
        let predicate = #Predicate<CachedFileMetadata> { item in
            item.itemIdentifier == targetId
        }
        let descriptor = FetchDescriptor<CachedFileMetadata>(predicate: predicate)
        
        if let item = try context.fetch(descriptor).first {
            item.deletedAtAnchor = anchor
            try context.save()  // Saves both SyncState and CachedFileMetadata
            logger.debug("📦 Marked deleted: \(item.filename) @ anchor \(anchor)")
        }
        
        return anchor
    }
    
    /// Batch upsert items (for directory listing)
    /// Also handles detecting deleted items
    /// Returns true if any actual changes occurred (new items, updates, deletions)
    @discardableResult
    func upsertBatch(
        items: [(id: String, connId: String, path: String, parentId: String, name: String, size: Int64, isDir: Bool, perms: Int32, modDate: Date?, isSymlink: Bool)],
        parentId: String
    ) throws -> Bool {
        let container = try getContainer()
        let context = ModelContext(container)
        
        // Get existing children FIRST (before any anchor changes)
        let targetParentId = parentId
        let existingPredicate = #Predicate<CachedFileMetadata> { item in
            item.parentIdentifier == targetParentId && item.deletedAtAnchor == nil
        }
        let existingDescriptor = FetchDescriptor<CachedFileMetadata>(predicate: existingPredicate)
        let existing = try context.fetch(existingDescriptor)
        let existingById = Dictionary(uniqueKeysWithValues: existing.map { ($0.itemIdentifier, $0) })
        
        // Track changes
        var hasNewItems = false
        let hasUpdates = false  // TODO: Track actual item updates (size/date changes)
        var hasDeletions = false
        var seenIds = Set<String>()
        
        // Check for new or modified items
        for item in items {
            seenIds.insert(item.id)
            
            if existingById[item.id] == nil {
                // New item
                hasNewItems = true
            }
        }
        
        // Check for deletions
        for existingItem in existing {
            if !seenIds.contains(existingItem.itemIdentifier) {
                hasDeletions = true
                break
            }
        }
        
        let hasChanges = hasNewItems || hasUpdates || hasDeletions
        
        // Only increment anchor if there are actual changes
        guard hasChanges else {
            logger.debug("📦 No changes detected for \(parentId), anchor unchanged")
            return false
        }
        
        // NOW increment anchor since we have real changes
        // Get SyncState in SAME context - critical for proper save
        let state = try getSyncState(in: context)
        let anchor = state.incrementAndGet()
        
        // Update synchronous cache with new anchor
        MetadataAnchorCache.shared.update(anchor: anchor)
        
        // Apply changes
        for item in items {
            if let existingItem = existingById[item.id] {
                // Update existing
                existingItem.filename = item.name
                existingItem.size = item.size
                existingItem.isDirectory = item.isDir
                existingItem.permissions = item.perms
                existingItem.modificationDate = item.modDate
                existingItem.isSymlink = item.isSymlink
                existingItem.modifiedAtAnchor = anchor
                existingItem.cachedAt = Date()
            } else {
                // Insert new
                let newItem = CachedFileMetadata(
                    itemIdentifier: item.id,
                    connectionId: item.connId,
                    remotePath: item.path,
                    parentIdentifier: item.parentId,
                    filename: item.name,
                    size: item.size,
                    isDirectory: item.isDir,
                    permissions: item.perms,
                    modificationDate: item.modDate,
                    isSymlink: item.isSymlink,
                    createdAtAnchor: anchor,
                    modifiedAtAnchor: anchor
                )
                context.insert(newItem)
            }
        }
        
        // Mark missing items as deleted
        for existingItem in existing {
            if !seenIds.contains(existingItem.itemIdentifier) {
                existingItem.deletedAtAnchor = anchor
                logger.debug("📦 Detected deletion: \(existingItem.filename)")
            }
        }
        
        // Mark parent as having children cached
        let parentTargetId = parentId
        let parentPredicate = #Predicate<CachedFileMetadata> { item in
            item.itemIdentifier == parentTargetId
        }
        let parentDescriptor = FetchDescriptor<CachedFileMetadata>(predicate: parentPredicate)
        if let parent = try context.fetch(parentDescriptor).first {
            parent.childrenCached = true
            parent.cachedAt = Date()
        }
        
        try context.save()  // Saves both SyncState and CachedFileMetadata
        logger.debug("📦 Batch upserted \(items.count) items under \(parentId) @ anchor \(anchor)")
        return true
    }
    
    /// Delete all data for a connection
    func deleteConnection(_ connectionId: String) throws {
        let container = try getContainer()
        let context = ModelContext(container)
        
        // Get SyncState in SAME context - critical for proper save
        let state = try getSyncState(in: context)
        let anchor = state.incrementAndGet()
        
        // Update synchronous cache with new anchor
        MetadataAnchorCache.shared.update(anchor: anchor)
        
        let targetConnectionId = connectionId
        let predicate = #Predicate<CachedFileMetadata> { item in
            item.connectionId == targetConnectionId && item.deletedAtAnchor == nil
        }
        let descriptor = FetchDescriptor<CachedFileMetadata>(predicate: predicate)
        let items = try context.fetch(descriptor)
        
        // Soft delete all items
        for item in items {
            item.deletedAtAnchor = anchor
        }
        
        try context.save()  // Saves both SyncState and CachedFileMetadata
        logger.info("📦 Deleted connection \(connectionId): \(items.count) items @ anchor \(anchor)")
    }
    
    /// Purge items deleted before anchor (cleanup old history)
    func purgeDeleted(before anchor: UInt64) throws {
        let container = try getContainer()
        let context = ModelContext(container)
        
        // SwiftData can't do optional < comparison in predicate
        let predicate = #Predicate<CachedFileMetadata> { item in
            item.deletedAtAnchor != nil
        }
        let descriptor = FetchDescriptor<CachedFileMetadata>(predicate: predicate)
        
        let deleted = try context.fetch(descriptor)
        var purged = 0
        for item in deleted {
            if let deletedAt = item.deletedAtAnchor, deletedAt < anchor {
                context.delete(item)
                purged += 1
            }
        }
        
        try context.save()
        logger.info("📦 Purged \(purged) items deleted before anchor \(anchor)")
    }
    
    /// Clear all data (for testing/reset)
    func clearAll() throws {
        let container = try getContainer()
        let context = ModelContext(container)
        
        // Delete all metadata
        let metadataDescriptor = FetchDescriptor<CachedFileMetadata>()
        for item in try context.fetch(metadataDescriptor) {
            context.delete(item)
        }
        
        // Reset sync state
        let stateDescriptor = FetchDescriptor<SyncState>()
        for state in try context.fetch(stateDescriptor) {
            context.delete(state)
        }
        
        try context.save()
        
        // Reset anchor cache
        MetadataAnchorCache.shared.update(anchor: 1)
        
        logger.info("📦 Cleared all MetadataStore data")
    }
    
    // MARK: - Cache Staleness
    
    /// Check if cache is stale for a directory
    func isStale(parentId: String) throws -> Bool {
        guard let item = try self.item(id: parentId) else {
            return true // Not cached = stale
        }
        
        return item.isStale(olderThan: staleThreshold)
    }
    
    /// Check if we have cached children for a directory
    func hasChildren(parentId: String) throws -> Bool {
        guard let item = try self.item(id: parentId) else {
            return false
        }
        return item.childrenCached
    }
    
    // MARK: - Active Folder Management
    
    /// Maximum number of active folders to track
    private static let maxActiveFolders = 20
    
    /// Register a folder as active (will be polled for changes)
    func registerActiveFolder(connectionId: String, remotePath: String) throws {
        let container = try getContainer()
        let context = ModelContext(container)
        
        let targetId = "conn:\(connectionId):path:\(remotePath)"
        let predicate = #Predicate<ActiveFolderRecord> { $0.folderIdentifier == targetId }
        let descriptor = FetchDescriptor<ActiveFolderRecord>(predicate: predicate)
        
        if let existing = try context.fetch(descriptor).first {
            // Already registered - just update access time
            existing.touch()
            try context.save()
            logger.debug("📂 Updated active folder access time: \(remotePath)")
            return
        }
        
        // Check if at capacity - remove oldest if needed
        let allDescriptor = FetchDescriptor<ActiveFolderRecord>(
            sortBy: [SortDescriptor(\.lastAccessed, order: .forward)]
        )
        let allFolders = try context.fetch(allDescriptor)
        
        if allFolders.count >= Self.maxActiveFolders {
            // Remove oldest
            if let oldest = allFolders.first {
                context.delete(oldest)
                logger.debug("📂 Removed oldest active folder: \(oldest.remotePath)")
            }
        }
        
        // Insert new
        let newFolder = ActiveFolderRecord(connectionId: connectionId, remotePath: remotePath)
        context.insert(newFolder)
        try context.save()
        
        logger.info("📂 Registered active folder: \(remotePath) (conn: \(connectionId))")
    }
    
    /// Unregister a folder (no longer needs polling)
    func unregisterActiveFolder(connectionId: String, remotePath: String) throws {
        let container = try getContainer()
        let context = ModelContext(container)
        
        let targetId = "conn:\(connectionId):path:\(remotePath)"
        let predicate = #Predicate<ActiveFolderRecord> { $0.folderIdentifier == targetId }
        let descriptor = FetchDescriptor<ActiveFolderRecord>(predicate: predicate)
        
        if let folder = try context.fetch(descriptor).first {
            context.delete(folder)
            try context.save()
            logger.debug("📂 Unregistered active folder: \(remotePath)")
        }
    }
    
    /// Get all active folders for polling
    func activeFolders() throws -> [(connectionId: String, remotePath: String)] {
        let container = try getContainer()
        let context = ModelContext(container)
        
        let descriptor = FetchDescriptor<ActiveFolderRecord>(
            sortBy: [SortDescriptor(\.lastAccessed, order: .reverse)]
        )
        let folders = try context.fetch(descriptor)
        
        return folders.map { ($0.connectionId, $0.remotePath) }
    }
    
    /// Get active folder count
    func activeFolderCount() throws -> Int {
        let container = try getContainer()
        let context = ModelContext(container)
        
        let descriptor = FetchDescriptor<ActiveFolderRecord>()
        return try context.fetchCount(descriptor)
    }
}

// MARK: - Errors

enum MetadataStoreError: LocalizedError {
    case appGroupUnavailable
    case containerInitFailed(Error)
    case syncStateNotFound
    
    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "App Group container not available"
        case .containerInitFailed(let error):
            return "Failed to initialize store: \(error.localizedDescription)"
        case .syncStateNotFound:
            return "Sync state not found"
        }
    }
}
