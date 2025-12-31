//
//  CachedItem.swift
//  Geistty
//
//  SwiftData model for caching SFTP file/directory metadata.
//  Used by File Provider extension to enable fast enumeration without
//  blocking on network I/O.
//
//  Architecture:
//  - Stored in shared App Group container (accessible by main app + extension)
//  - Enumeration returns cached items immediately
//  - Background refresh updates cache and calls signalEnumerator()
//

import Foundation
import SwiftData

/// Cached metadata for a remote file or directory
@Model
final class CachedItem {
    // MARK: - Identity
    
    /// Unique identifier (NSFileProviderItemIdentifier.rawValue)
    /// Format: "conn:<connectionId>:path:<remotePath>" or "conn:<connectionId>" for connection root
    @Attribute(.unique)
    var id: String
    
    /// Connection this item belongs to (profile ID)
    var connectionId: String
    
    /// Full remote path
    var path: String
    
    /// Parent item identifier (or "root" for connection root items)
    var parentId: String
    
    // MARK: - Metadata
    
    /// File or directory name
    var name: String
    
    /// File size in bytes (0 for directories)
    var size: Int64
    
    /// True if this is a directory
    var isDirectory: Bool
    
    /// Unix permissions (e.g., 0o755)
    var permissions: Int32
    
    /// Last modification time from server
    var modificationDate: Date?
    
    /// True if this is a symbolic link
    var isSymlink: Bool
    
    // MARK: - Cache Management
    
    /// When this item was cached/updated
    var cachedAt: Date
    
    /// Whether children have been enumerated (for directories)
    var childrenCached: Bool
    
    // MARK: - Initialization
    
    init(
        id: String,
        connectionId: String,
        path: String,
        parentId: String,
        name: String,
        size: Int64 = 0,
        isDirectory: Bool = false,
        permissions: Int32 = 0,
        modificationDate: Date? = nil,
        isSymlink: Bool = false,
        cachedAt: Date = Date(),
        childrenCached: Bool = false
    ) {
        self.id = id
        self.connectionId = connectionId
        self.path = path
        self.parentId = parentId
        self.name = name
        self.size = size
        self.isDirectory = isDirectory
        self.permissions = permissions
        self.modificationDate = modificationDate
        self.isSymlink = isSymlink
        self.cachedAt = cachedAt
        self.childrenCached = childrenCached
    }
}

// MARK: - Convenience Extensions

extension CachedItem {
    /// Create identifier for a connection root folder
    static func connectionRootId(_ connectionId: String) -> String {
        "conn:\(connectionId)"
    }
    
    /// Create identifier for a remote path
    static func remoteItemId(connectionId: String, path: String) -> String {
        "conn:\(connectionId):path:\(path)"
    }
    
    /// Parse connection ID from item identifier
    static func parseConnectionId(from identifier: String) -> String? {
        guard identifier.hasPrefix("conn:") else { return nil }
        
        if let pathRange = identifier.range(of: ":path:") {
            return String(identifier[identifier.index(identifier.startIndex, offsetBy: 5)..<pathRange.lowerBound])
        } else {
            return String(identifier.dropFirst(5))
        }
    }
    
    /// Parse remote path from item identifier (nil for connection root)
    static func parseRemotePath(from identifier: String) -> String? {
        guard let pathRange = identifier.range(of: ":path:") else { return nil }
        return String(identifier[pathRange.upperBound...])
    }
    
    /// Check if cache is stale (older than specified interval)
    func isStale(olderThan interval: TimeInterval = 300) -> Bool {
        Date().timeIntervalSince(cachedAt) > interval
    }
}

// MARK: - SwiftData Schema Configuration

extension CachedItem {
    /// Schema version for migrations
    static let schemaVersion = Schema.Version(1, 0, 0)
}
