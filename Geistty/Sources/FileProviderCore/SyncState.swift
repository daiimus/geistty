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
//  - Anchor format: "V{version}-{iteration}" string (like Blink)
//  - Persisted in shared App Group container via SwiftData
//
//  Anchor Format (Jan 16, 2026):
//  - Version prefix changes on DB reset/schema change
//  - Iteration is monotonic counter
//  - Example: "V1-42" means version 1, iteration 42
//  - If iOS sends old version, we return syncAnchorExpired
//

import FileProvider
import Foundation
import SwiftData

/// Sync state for the File Provider domain
/// Contains a monotonic counter that serves as our sync anchor
@Model
final class SyncState {
    
    /// Current schema/database version - bump this on breaking changes
    /// If iOS sends an anchor with a different version, we return syncAnchorExpired
    static let currentVersion: Int = 1
    
    /// Singleton identifier (we only have one domain)
    @Attribute(.unique)
    var id: String = "default"
    
    /// Anchor version - changes on DB reset or schema migration
    var anchorVersion: Int = SyncState.currentVersion
    
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
        self.anchorVersion = SyncState.currentVersion
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
    /// Format: "V{version}-{iteration}" as UTF-8 string
    func toSyncAnchor() -> NSFileProviderSyncAnchor {
        let anchorString = "V\(anchorVersion)-\(currentAnchor)"
        let data = anchorString.data(using: .utf8)!
        return NSFileProviderSyncAnchor(data)
    }
    
    /// Parse anchor from NSFileProviderSyncAnchor
    /// Returns (version, iteration) if valid, nil otherwise
    static func parseAnchor(from syncAnchor: NSFileProviderSyncAnchor) -> (version: Int, iteration: UInt64)? {
        let data = syncAnchor.rawValue
        
        // Try new format: "V{version}-{iteration}"
        if let string = String(data: data, encoding: .utf8),
           string.hasPrefix("V"),
           let dashIndex = string.firstIndex(of: "-") {
            let versionStr = string[string.index(after: string.startIndex)..<dashIndex]
            let iterationStr = string[string.index(after: dashIndex)...]
            if let version = Int(versionStr), let iteration = UInt64(iterationStr) {
                return (version, iteration)
            }
        }
        
        // Try legacy format: 8-byte UInt64
        if data.count == 8 {
            let iteration = data.withUnsafeBytes { $0.load(as: UInt64.self) }
            // Legacy anchors are treated as version 0
            return (0, iteration)
        }
        
        return nil
    }
    
    /// Check if an anchor is valid for change enumeration
    /// Returns .valid(iteration), .expired, or .invalid
    func validateAnchor(_ syncAnchor: NSFileProviderSyncAnchor) -> AnchorValidation {
        guard let (version, iteration) = SyncState.parseAnchor(from: syncAnchor) else {
            return .invalid
        }
        
        // Version mismatch = expired (DB was reset or schema changed)
        // Legacy anchors (version 0) are also treated as expired to force re-sync
        if version != anchorVersion {
            return .expired(requestedVersion: version, currentVersion: anchorVersion)
        }
        
        // Same anchor = no changes
        if iteration == currentAnchor {
            return .noChanges
        }
        
        // Future anchor = invalid (shouldn't happen)
        if iteration > currentAnchor {
            return .invalid
        }
        
        // Valid: iOS has older anchor, we have changes
        return .valid(iteration: iteration)
    }
}

/// Result of anchor validation
enum AnchorValidation {
    /// Anchor is valid, enumerate changes since iteration
    case valid(iteration: UInt64)
    /// Same anchor, no changes to report
    case noChanges
    /// Anchor version mismatch, return syncAnchorExpired
    case expired(requestedVersion: Int, currentVersion: Int)
    /// Anchor is malformed or from the future
    case invalid
}

// MARK: - Debugging

extension SyncState: CustomStringConvertible {
    var description: String {
        "SyncState(anchor: \(currentAnchor), modified: \(lastModified))"
    }
}
