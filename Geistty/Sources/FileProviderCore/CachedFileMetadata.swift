//
//  CachedFileMetadata.swift
//  Geistty
//
//  SwiftData model for caching SFTP file/directory metadata.
//  Includes anchor tracking for change detection in File Provider.
//
//  Architecture:
//  - Stored in shared App Group container (main app + extension)
//  - Each item tracks WHEN it was created/modified/deleted (as anchor values)
//  - Queries can efficiently find "all changes since anchor X"
//  - Soft deletes preserve history for change enumeration
//

import Foundation
import SwiftData

/// Cached metadata for a remote file or directory
@Model
final class CachedFileMetadata {
    
    // MARK: - Identity
    
    /// Unique identifier (NSFileProviderItemIdentifier.rawValue)
    /// Format: "conn:<connectionId>:path:<remotePath>" or "conn:<connectionId>" for connection root
    @Attribute(.unique)
    var itemIdentifier: String
    
    /// Connection this item belongs to (profile ID)
    var connectionId: String
    
    /// Full remote path
    var remotePath: String
    
    /// Parent item identifier (or "root" for connection root items)
    var parentIdentifier: String
    
    // MARK: - File Metadata
    
    /// File or directory name
    var filename: String
    
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
    
    // MARK: - Anchor Tracking (Change Detection)
    
    /// Anchor value when this item was first cached
    /// Used to detect "new items since anchor X"
    var createdAtAnchor: UInt64
    
    /// Anchor value when this item was last modified
    /// Updated on any metadata change
    var modifiedAtAnchor: UInt64
    
    /// Anchor value when this item was soft-deleted
    /// nil = item is active, non-nil = item was deleted at this anchor
    var deletedAtAnchor: UInt64?
    
    // MARK: - Cache Management
    
    /// When this item was last refreshed from server
    var cachedAt: Date
    
    /// Whether children have been enumerated (for directories)
    var childrenCached: Bool
    
    // MARK: - Initialization
    
    init(
        itemIdentifier: String,
        connectionId: String,
        remotePath: String,
        parentIdentifier: String,
        filename: String,
        size: Int64 = 0,
        isDirectory: Bool = false,
        permissions: Int32 = 0,
        modificationDate: Date? = nil,
        isSymlink: Bool = false,
        createdAtAnchor: UInt64,
        modifiedAtAnchor: UInt64,
        deletedAtAnchor: UInt64? = nil,
        cachedAt: Date = Date(),
        childrenCached: Bool = false
    ) {
        self.itemIdentifier = itemIdentifier
        self.connectionId = connectionId
        self.remotePath = remotePath
        self.parentIdentifier = parentIdentifier
        self.filename = filename
        self.size = size
        self.isDirectory = isDirectory
        self.permissions = permissions
        self.modificationDate = modificationDate
        self.isSymlink = isSymlink
        self.createdAtAnchor = createdAtAnchor
        self.modifiedAtAnchor = modifiedAtAnchor
        self.deletedAtAnchor = deletedAtAnchor
        self.cachedAt = cachedAt
        self.childrenCached = childrenCached
    }
    
    // MARK: - Change Detection
    
    /// Check if this item was modified after the given anchor
    /// Used by enumerateChanges to find updated items
    func wasModifiedSince(_ anchor: UInt64) -> Bool {
        modifiedAtAnchor > anchor && deletedAtAnchor == nil
    }
    
    /// Check if this item was deleted after the given anchor
    /// Used by enumerateChanges to find deleted items
    func wasDeletedSince(_ anchor: UInt64) -> Bool {
        guard let deleted = deletedAtAnchor else { return false }
        return deleted > anchor
    }
    
    /// Check if this item is active (not deleted)
    var isActive: Bool {
        deletedAtAnchor == nil
    }
}

// MARK: - Identifier Utilities

extension CachedFileMetadata {
    
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
}

// MARK: - Staleness Check

extension CachedFileMetadata {
    
    /// Default staleness threshold (5 minutes)
    static let defaultStaleThreshold: TimeInterval = 300
    
    /// Check if cache is stale (older than specified interval)
    func isStale(olderThan interval: TimeInterval = defaultStaleThreshold) -> Bool {
        Date().timeIntervalSince(cachedAt) > interval
    }
}

// MARK: - Debugging

extension CachedFileMetadata: CustomStringConvertible {
    var description: String {
        let type = isDirectory ? "dir" : "file"
        let status = deletedAtAnchor != nil ? "deleted@\(deletedAtAnchor!)" : "active"
        return "CachedFileMetadata(\(filename), \(type), \(status), modified@\(modifiedAtAnchor))"
    }
}
