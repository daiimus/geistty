//
//  MetadataCache.swift
//  Geistty
//
//  Thread-safe SwiftData cache for SFTP file metadata.
//  Used by File Provider extension to enable fast enumeration.
//
//  Architecture:
//  - Actor isolation for thread safety
//  - ModelContainer in shared App Group container
//  - Both main app and File Provider extension can read/write
//  - Background refresh updates cache, then calls signalEnumerator()
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.geistty", category: "MetadataCache")

/// Thread-safe cache for SFTP file metadata using SwiftData
actor MetadataCache {
    
    /// Shared instance
    static let shared = MetadataCache()
    
    /// SwiftData model container
    private var container: ModelContainer?
    
    /// App Group identifier for shared storage
    private let appGroupIdentifier = "group.com.geistty.fileprovider"
    
    /// Cache staleness threshold (5 minutes)
    private let staleThreshold: TimeInterval = 300
    
    private init() {}
    
    // MARK: - Container Management
    
    /// Get or create the SwiftData model container
    private func getContainer() throws -> ModelContainer {
        if let container = container {
            return container
        }
        
        // Get shared App Group container URL
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw MetadataCacheError.appGroupUnavailable
        }
        
        let storeURL = containerURL.appendingPathComponent("MetadataCache.store")
        
        let schema = Schema([CachedItem.self])
        let config = ModelConfiguration(
            "MetadataCache",
            schema: schema,
            url: storeURL,
            allowsSave: true
        )
        
        let container = try ModelContainer(for: schema, configurations: [config])
        self.container = container
        
        logger.info("📦 MetadataCache initialized at \(storeURL.path)")
        return container
    }
    
    // MARK: - Query Operations
    
    /// Get cached children of a directory
    func getChildren(parentId: String) async throws -> [CachedItem] {
        let container = try getContainer()
        let context = ModelContext(container)
        
        let targetParentId = parentId
        let predicate = #Predicate<CachedItem> { item in
            item.parentId == targetParentId
        }
        let descriptor = FetchDescriptor<CachedItem>(predicate: predicate)
        
        return try context.fetch(descriptor)
    }
    
    /// Get a specific cached item by ID
    func getItem(id: String) async throws -> CachedItem? {
        let container = try getContainer()
        let context = ModelContext(container)
        
        let targetId = id
        let predicate = #Predicate<CachedItem> { item in
            item.id == targetId
        }
        let descriptor = FetchDescriptor<CachedItem>(predicate: predicate)
        
        return try context.fetch(descriptor).first
    }
    
    /// Get all cached items for a connection
    func getItems(connectionId: String) async throws -> [CachedItem] {
        let container = try getContainer()
        let context = ModelContext(container)
        
        let targetConnectionId = connectionId
        let predicate = #Predicate<CachedItem> { item in
            item.connectionId == targetConnectionId
        }
        let descriptor = FetchDescriptor<CachedItem>(predicate: predicate)
        
        return try context.fetch(descriptor)
    }
    
    /// Get all cached items (for working set enumeration)
    func getAllItems() async throws -> [CachedItem] {
        let container = try getContainer()
        let context = ModelContext(container)
        
        let descriptor = FetchDescriptor<CachedItem>()
        return try context.fetch(descriptor)
    }
    
    /// Check if we have cached children for a directory
    func hasChildren(parentId: String) async throws -> Bool {
        let container = try getContainer()
        let context = ModelContext(container)
        
        let targetParentId = parentId
        let predicate = #Predicate<CachedItem> { item in
            item.parentId == targetParentId
        }
        var descriptor = FetchDescriptor<CachedItem>(predicate: predicate)
        descriptor.fetchLimit = 1
        
        return try !context.fetch(descriptor).isEmpty
    }
    
    /// Check if cache is stale for a directory
    func isStale(parentId: String) async throws -> Bool {
        let container = try getContainer()
        let context = ModelContext(container)
        
        // Get the parent item
        let targetId = parentId
        let predicate = #Predicate<CachedItem> { item in
            item.id == targetId
        }
        let descriptor = FetchDescriptor<CachedItem>(predicate: predicate)
        
        guard let parent = try context.fetch(descriptor).first else {
            return true // No cached parent = stale
        }
        
        return parent.isStale(olderThan: staleThreshold)
    }
    
    // MARK: - Write Operations
    
    /// Store or update a cached item
    func upsert(_ item: CachedItem) async throws {
        let container = try getContainer()
        let context = ModelContext(container)
        
        // Check if exists
        let targetId = item.id
        let predicate = #Predicate<CachedItem> { existing in
            existing.id == targetId
        }
        let descriptor = FetchDescriptor<CachedItem>(predicate: predicate)
        
        if let existing = try context.fetch(descriptor).first {
            // Update existing
            existing.name = item.name
            existing.size = item.size
            existing.isDirectory = item.isDirectory
            existing.permissions = item.permissions
            existing.modificationDate = item.modificationDate
            existing.isSymlink = item.isSymlink
            existing.cachedAt = Date()
            existing.childrenCached = item.childrenCached
        } else {
            // Insert new
            context.insert(item)
        }
        
        try context.save()
    }
    
    /// Store multiple items (batch operation for directory listing)
    func upsertBatch(_ items: [CachedItem], parentId: String) async throws {
        let container = try getContainer()
        let context = ModelContext(container)
        
        // Build a set of new item IDs for efficient lookup
        let newIds = Set(items.map { $0.id })
        
        // Get existing children
        let targetParentId = parentId
        let predicate = #Predicate<CachedItem> { item in
            item.parentId == targetParentId
        }
        let descriptor = FetchDescriptor<CachedItem>(predicate: predicate)
        let existing = try context.fetch(descriptor)
        let existingById = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        
        // Update or insert each item
        for item in items {
            if let existingItem = existingById[item.id] {
                // Update existing
                existingItem.name = item.name
                existingItem.size = item.size
                existingItem.isDirectory = item.isDirectory
                existingItem.permissions = item.permissions
                existingItem.modificationDate = item.modificationDate
                existingItem.isSymlink = item.isSymlink
                existingItem.cachedAt = Date()
            } else {
                // Insert new
                context.insert(item)
            }
        }
        
        // Delete items that no longer exist on server
        for existingItem in existing {
            if !newIds.contains(existingItem.id) {
                context.delete(existingItem)
            }
        }
        
        // Mark parent as having children cached
        let parentTargetId = parentId
        let parentPredicate = #Predicate<CachedItem> { item in
            item.id == parentTargetId
        }
        let parentDescriptor = FetchDescriptor<CachedItem>(predicate: parentPredicate)
        if let parent = try context.fetch(parentDescriptor).first {
            parent.childrenCached = true
            parent.cachedAt = Date()
        }
        
        try context.save()
        logger.debug("📦 Cached \(items.count) items under \(parentId)")
    }
    
    /// Delete all cached items for a connection
    func deleteConnection(_ connectionId: String) async throws {
        let container = try getContainer()
        let context = ModelContext(container)
        
        let targetConnectionId = connectionId
        let predicate = #Predicate<CachedItem> { item in
            item.connectionId == targetConnectionId
        }
        let descriptor = FetchDescriptor<CachedItem>(predicate: predicate)
        let items = try context.fetch(descriptor)
        
        for item in items {
            context.delete(item)
        }
        
        try context.save()
        logger.info("📦 Deleted cache for connection \(connectionId)")
    }
    
    /// Delete a specific item by ID (without recursive child deletion)
    func delete(id: String) async throws {
        let container = try getContainer()
        let context = ModelContext(container)
        
        let targetId = id
        let predicate = #Predicate<CachedItem> { item in
            item.id == targetId
        }
        let descriptor = FetchDescriptor<CachedItem>(predicate: predicate)
        if let item = try context.fetch(descriptor).first {
            context.delete(item)
            try context.save()
        }
    }
    
    /// Delete a specific item and its children
    func deleteItem(_ id: String) async throws {
        let container = try getContainer()
        let context = ModelContext(container)
        
        // Delete the item
        let targetId = id
        let predicate = #Predicate<CachedItem> { item in
            item.id == targetId
        }
        let descriptor = FetchDescriptor<CachedItem>(predicate: predicate)
        if let item = try context.fetch(descriptor).first {
            context.delete(item)
        }
        
        // Delete children recursively
        let childParentId = id
        let childPredicate = #Predicate<CachedItem> { item in
            item.parentId == childParentId
        }
        let childDescriptor = FetchDescriptor<CachedItem>(predicate: childPredicate)
        let children = try context.fetch(childDescriptor)
        
        for child in children {
            context.delete(child)
            // Note: For deep trees, this should be recursive
            // For now, assume shallow deletion is sufficient
        }
        
        try context.save()
    }
    
    /// Clear all cached data
    func clearAll() async throws {
        let container = try getContainer()
        let context = ModelContext(container)
        
        let descriptor = FetchDescriptor<CachedItem>()
        let items = try context.fetch(descriptor)
        
        for item in items {
            context.delete(item)
        }
        
        try context.save()
        logger.info("📦 Cleared all cached metadata")
    }
}

// MARK: - Errors

enum MetadataCacheError: LocalizedError {
    case appGroupUnavailable
    case containerInitFailed(Error)
    
    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "App Group container not available"
        case .containerInitFailed(let error):
            return "Failed to initialize cache: \(error.localizedDescription)"
        }
    }
}
