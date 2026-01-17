//
//  MetadataStore.swift
//  Geistty
//
//  Actor that manages all File Provider metadata and sync state.
//  Single source of truth for cached file metadata and sync anchors.
//
//  Architecture (Option B - Simplified Jan 5, 2026):
//  - Actor isolation for thread safety
//  - SwiftData is the ONLY source of truth for anchors
//  - No separate anchor cache or file-based persistence
//  - Enumerators query MetadataStore directly (async is fine per Apple docs)
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

// MARK: - MetadataStore Actor

/// Actor that owns all File Provider metadata and sync state.
/// SwiftData is the ONLY source of truth - no separate caches.
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
    private func getSyncState(in context: ModelContext) throws -> SyncState {
        let descriptor = FetchDescriptor<SyncState>()
        if let existing = try context.fetch(descriptor).first {
            logger.debug("📦 Loaded existing SyncState: anchor=\(existing.currentAnchor)")
            return existing
        }
        
        // Create new sync state - starts at anchor 1
        let newState = SyncState()
        context.insert(newState)
        try context.save()
        
        logger.info("📦 Created new SyncState: anchor=\(newState.currentAnchor)")
        return newState
    }
    
    // MARK: - Sync Anchor API
    
    /// Current anchor value from SwiftData (ONLY source of truth)
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
            
            logger.debug("📦 currentAnchor queried: \(anchor)")
            return anchor
        }
    }
    
    /// Current anchor as NSFileProviderSyncAnchor
    var currentSyncAnchor: NSFileProviderSyncAnchor {
        get throws {
            let container = try getContainer()
            let context = ModelContext(container)
            let state = try getSyncState(in: context)
            let anchor = state.toSyncAnchor()
            logger.debug("📦 currentSyncAnchor queried: \(state.currentAnchor)")
            return anchor
        }
    }
    
    /// Increment anchor and return the new value
    func incrementAnchor() throws -> UInt64 {
        let container = try getContainer()
        let context = ModelContext(container)
        let state = try getSyncState(in: context)
        let newAnchor = state.incrementAndGet()
        try context.save()
        logger.debug("📦 Anchor incremented to \(newAnchor)")
        return newAnchor
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
    
    /// Get items modified since the given anchor
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
    func deletions(since anchor: UInt64) throws -> [String] {
        let container = try getContainer()
        let context = ModelContext(container)
        
        let predicate = #Predicate<CachedFileMetadata> { item in
            item.deletedAtAnchor != nil
        }
        let descriptor = FetchDescriptor<CachedFileMetadata>(predicate: predicate)
        
        let deleted = try context.fetch(descriptor)
        return deleted
            .filter { $0.deletedAtAnchor! > anchor }
            .map { $0.itemIdentifier }
    }
    
    // MARK: - Anchor Validation
    
    /// Validate an anchor from iOS using strict version checking
    func validateAnchor(_ syncAnchor: NSFileProviderSyncAnchor) throws -> AnchorValidation {
        let container = try getContainer()
        let context = ModelContext(container)
        let state = try getSyncState(in: context)
        return state.validateAnchor(syncAnchor)
    }
    
    /// Get all changes since anchor for enumerateChanges()
    /// Returns changes and the NEW anchor in proper "V{version}-{iteration}" format
    func changesSince(anchor: UInt64) throws -> (
        modified: [CachedFileMetadata],
        deletions: [String],
        newAnchor: NSFileProviderSyncAnchor
    ) {
        let container = try getContainer()
        let context = ModelContext(container)
        let state = try getSyncState(in: context)
        
        let currentAnchorValue = state.currentAnchor
        
        guard anchor < currentAnchorValue else {
            return ([], [], state.toSyncAnchor())
        }
        
        let modified = try itemsModified(since: anchor)
        let deletedIds = try deletions(since: anchor)
        
        logger.debug("📦 Changes since \(anchor): \(modified.count) modified, \(deletedIds.count) deleted")
        
        return (modified, deletedIds, state.toSyncAnchor())
    }
    
    // MARK: - Reset Operations
    
    /// Reset the metadata store for domain clearing
    func resetForDomainClear() async throws {
        let container = try getContainer()
        let context = ModelContext(container)
        
        try context.delete(model: CachedFileMetadata.self)
        try context.delete(model: ActiveFolderRecord.self)
        
        let statePredicate = #Predicate<SyncState> { _ in true }
        let stateDescriptor = FetchDescriptor<SyncState>(predicate: statePredicate)
        if let existingState = try context.fetch(stateDescriptor).first {
            existingState.currentAnchor = 1
            existingState.lastModified = Date()
        } else {
            let newState = SyncState()
            context.insert(newState)
        }
        
        try context.save()
        logger.info("📦 MetadataStore reset complete - anchor reset to 1")
    }
    
    // MARK: - Write Operations
    
    /// Upsert an item from SFTP attributes
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
        
        let state = try getSyncState(in: context)
        let anchor = state.incrementAndGet()
        
        let targetId = itemIdentifier
        let predicate = #Predicate<CachedFileMetadata> { item in
            item.itemIdentifier == targetId
        }
        let descriptor = FetchDescriptor<CachedFileMetadata>(predicate: predicate)
        
        if let existing = try context.fetch(descriptor).first {
            existing.filename = filename
            existing.size = size
            existing.isDirectory = isDirectory
            existing.permissions = permissions
            existing.modificationDate = modificationDate
            existing.isSymlink = isSymlink
            existing.modifiedAtAnchor = anchor
            existing.deletedAtAnchor = nil
            existing.cachedAt = Date()
            
            try context.save()
            logger.debug("📦 Updated item: \(filename) @ anchor \(anchor)")
            return (existing, false)
        } else {
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
            try context.save()
            logger.debug("📦 Inserted item: \(filename) @ anchor \(anchor)")
            return (newItem, true)
        }
    }
    
    /// Mark an item as deleted (soft delete)
    @discardableResult
    func markDeleted(id: String) throws -> UInt64 {
        let container = try getContainer()
        let context = ModelContext(container)
        
        let state = try getSyncState(in: context)
        let anchor = state.incrementAndGet()
        
        let targetId = id
        let predicate = #Predicate<CachedFileMetadata> { item in
            item.itemIdentifier == targetId
        }
        let descriptor = FetchDescriptor<CachedFileMetadata>(predicate: predicate)
        
        if let item = try context.fetch(descriptor).first {
            item.deletedAtAnchor = anchor
            try context.save()
            logger.debug("📦 Marked deleted: \(item.filename) @ anchor \(anchor)")
        }
        
        return anchor
    }
    
    /// Batch upsert items (for directory listing)
    @discardableResult
    func upsertBatch(
        items: [(id: String, connId: String, path: String, parentId: String, name: String, size: Int64, isDir: Bool, perms: Int32, modDate: Date?, isSymlink: Bool)],
        parentId: String
    ) throws -> Bool {
        let container = try getContainer()
        let context = ModelContext(container)
        
        // Get existing children
        let targetParentId = parentId
        let existingPredicate = #Predicate<CachedFileMetadata> { item in
            item.parentIdentifier == targetParentId && item.deletedAtAnchor == nil
        }
        let existingDescriptor = FetchDescriptor<CachedFileMetadata>(predicate: existingPredicate)
        let existing = try context.fetch(existingDescriptor)
        let existingById = Dictionary(uniqueKeysWithValues: existing.map { ($0.itemIdentifier, $0) })
        
        // Check for changes
        var hasNewItems = false
        var hasDeletions = false
        var seenIds = Set<String>()
        
        for item in items {
            seenIds.insert(item.id)
            if existingById[item.id] == nil {
                hasNewItems = true
            }
        }
        
        for existingItem in existing {
            if !seenIds.contains(existingItem.itemIdentifier) {
                hasDeletions = true
                break
            }
        }
        
        let hasChanges = hasNewItems || hasDeletions
        
        guard hasChanges else {
            logger.debug("📦 No changes detected for \(parentId)")
            return false
        }
        
        // Increment anchor for real changes
        let state = try getSyncState(in: context)
        let anchor = state.incrementAndGet()
        
        // Apply changes
        for item in items {
            if let existingItem = existingById[item.id] {
                existingItem.filename = item.name
                existingItem.size = item.size
                existingItem.isDirectory = item.isDir
                existingItem.permissions = item.perms
                existingItem.modificationDate = item.modDate
                existingItem.isSymlink = item.isSymlink
                existingItem.modifiedAtAnchor = anchor
                existingItem.cachedAt = Date()
            } else {
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
        
        // Mark deletions
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
        
        try context.save()
        logger.debug("📦 Batch upserted \(items.count) items under \(parentId) @ anchor \(anchor)")
        return true
    }
    
    /// Delete all data for a connection
    func deleteConnection(_ connectionId: String) throws {
        let container = try getContainer()
        let context = ModelContext(container)
        
        let state = try getSyncState(in: context)
        let anchor = state.incrementAndGet()
        
        let targetConnectionId = connectionId
        let predicate = #Predicate<CachedFileMetadata> { item in
            item.connectionId == targetConnectionId && item.deletedAtAnchor == nil
        }
        let descriptor = FetchDescriptor<CachedFileMetadata>(predicate: predicate)
        let items = try context.fetch(descriptor)
        
        for item in items {
            item.deletedAtAnchor = anchor
        }
        
        try context.save()
        logger.info("📦 Deleted connection \(connectionId): \(items.count) items @ anchor \(anchor)")
    }
    
    /// Purge items deleted before anchor
    func purgeDeleted(before anchor: UInt64) throws {
        let container = try getContainer()
        let context = ModelContext(container)
        
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
        
        let metadataDescriptor = FetchDescriptor<CachedFileMetadata>()
        for item in try context.fetch(metadataDescriptor) {
            context.delete(item)
        }
        
        let stateDescriptor = FetchDescriptor<SyncState>()
        for state in try context.fetch(stateDescriptor) {
            context.delete(state)
        }
        
        try context.save()
        logger.info("📦 Cleared all MetadataStore data")
    }
    
    // MARK: - Cache Staleness
    
    func isStale(parentId: String) throws -> Bool {
        guard let item = try self.item(id: parentId) else {
            return true
        }
        return item.isStale(olderThan: staleThreshold)
    }
    
    func hasChildren(parentId: String) throws -> Bool {
        guard let item = try self.item(id: parentId) else {
            return false
        }
        return item.childrenCached
    }
    
    // MARK: - Active Folder Management
    
    private static let maxActiveFolders = 20
    
    func registerActiveFolder(connectionId: String, remotePath: String) throws {
        let container = try getContainer()
        let context = ModelContext(container)
        
        let targetId = "conn:\(connectionId):path:\(remotePath)"
        let predicate = #Predicate<ActiveFolderRecord> { $0.folderIdentifier == targetId }
        let descriptor = FetchDescriptor<ActiveFolderRecord>(predicate: predicate)
        
        if let existing = try context.fetch(descriptor).first {
            existing.touch()
            try context.save()
            logger.debug("📂 Updated active folder access time: \(remotePath)")
            return
        }
        
        let allDescriptor = FetchDescriptor<ActiveFolderRecord>(
            sortBy: [SortDescriptor(\.lastAccessed, order: .forward)]
        )
        let allFolders = try context.fetch(allDescriptor)
        
        if allFolders.count >= Self.maxActiveFolders {
            if let oldest = allFolders.first {
                context.delete(oldest)
                logger.debug("📂 Removed oldest active folder: \(oldest.remotePath)")
            }
        }
        
        let newFolder = ActiveFolderRecord(connectionId: connectionId, remotePath: remotePath)
        context.insert(newFolder)
        try context.save()
        
        logger.info("📂 Registered active folder: \(remotePath) (conn: \(connectionId))")
    }
    
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
    
    func activeFolders() throws -> [(connectionId: String, remotePath: String)] {
        let container = try getContainer()
        let context = ModelContext(container)
        
        let descriptor = FetchDescriptor<ActiveFolderRecord>(
            sortBy: [SortDescriptor(\.lastAccessed, order: .reverse)]
        )
        let folders = try context.fetch(descriptor)
        
        return folders.map { ($0.connectionId, $0.remotePath) }
    }
    
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
