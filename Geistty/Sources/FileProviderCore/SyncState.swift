//
//  SyncState.swift
//  Geistty
//
//  SwiftData model for File Provider sync state.
//  Stores a monotonic UInt64 anchor counter that only increases.
//
//  Architecture:
//  - Single SyncState record per domain (we have one domain)
//  - Anchor increments on ANY change (create, update, delete)
//  - Anchor is serialized as 8 bytes in NSFileProviderSyncAnchor
//  - Persisted in shared App Group container via SwiftData
//

import FileProvider
import Foundation
import SwiftData

/// Sync state for the File Provider domain
/// Contains a monotonic counter that serves as our sync anchor
@Model
final class SyncState {
    
    /// Singleton identifier (we only have one domain)
    @Attribute(.unique)
    var id: String = "default"
    
    /// Monotonic anchor counter - ONLY increases
    /// This is the core of our change tracking
    /// CRITICAL: Starts at 1 (not 0) so first enumerateChanges(from: 0) sees changes
    var currentAnchor: UInt64 = 1
    
    /// When the anchor was last modified
    var lastModified: Date = Date.distantPast
    
    /// Initialize with default values
    /// Note: anchor starts at 1 so iOS can enumerate from 0
    init() {
        self.id = "default"
        self.currentAnchor = 1
        self.lastModified = Date()
    }
    
    /// Increment anchor and return the new value
    /// Call this whenever any change is recorded
    @discardableResult
    func incrementAndGet() -> UInt64 {
        currentAnchor += 1
        lastModified = Date()
        return currentAnchor
    }
    
    /// Convert current anchor to NSFileProviderSyncAnchor
    /// Serializes as 8 bytes (little-endian UInt64)
    func toSyncAnchor() -> NSFileProviderSyncAnchor {
        var value = currentAnchor
        let data = Data(bytes: &value, count: 8)
        return NSFileProviderSyncAnchor(data)
    }
    
    /// Parse anchor value from NSFileProviderSyncAnchor
    /// Returns nil if data is not exactly 8 bytes
    static func anchorValue(from syncAnchor: NSFileProviderSyncAnchor) -> UInt64? {
        let data = syncAnchor.rawValue
        guard data.count == 8 else { return nil }
        return data.withUnsafeBytes { $0.load(as: UInt64.self) }
    }
}

// MARK: - Debugging

extension SyncState: CustomStringConvertible {
    var description: String {
        "SyncState(anchor: \(currentAnchor), modified: \(lastModified))"
    }
}
