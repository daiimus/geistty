//
//  MetadataStoreEnumerator.swift
//  Geistty
//
//  Working set enumerator that uses MetadataStore for change tracking.
//  Replaces the old WorkingSetEnumerator with proper anchor-based queries.
//
//  Key differences from old implementation:
//  - Uses UInt64 monotonic anchor (not VERSION-ITERATION string)
//  - Permissive change enumeration (any older anchor, not strict +1)
//  - Direct SwiftData queries for changes (not in-memory pending list)
//  - Never returns syncAnchorExpired (always brings client up to date)
//

import FileProvider
import Foundation
import os.log
import UniformTypeIdentifiers

private let logger = Logger(subsystem: "com.geistty.fileprovider", category: "MetadataStoreEnumerator")

// MARK: - MetadataStoreEnumerator

/// Working set enumerator using MetadataStore for change tracking.
/// 
/// Architecture:
/// - Uses MetadataAnchorCache for synchronous anchor access
/// - Queries MetadataStore for changes since anchor
/// - Returns ALL changes since requested anchor (permissive)
/// - Never returns syncAnchorExpired (always succeeds)
class MetadataStoreEnumerator: NSObject, NSFileProviderEnumerator {
    
    override init() {
        super.init()
        logger.info("MetadataStoreEnumerator created, anchor=\(MetadataAnchorCache.shared.currentAnchor)")
    }
    
    func invalidate() {
        logger.info("MetadataStoreEnumerator invalidated")
    }
    
    // MARK: - Enumerate Items
    
    /// Working set returns NO items in enumerateItems.
    /// All content flows through enumerateChanges.
    /// This matches Blink/Cryptomator patterns.
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        logger.info("enumerateItems called - returning empty (correct behavior)")
        observer.finishEnumerating(upTo: nil)
    }
    
    // MARK: - Enumerate Changes
    
    /// Report all changes since the requested anchor.
    /// Uses permissive approach: accepts ANY older anchor and reports ALL changes since then.
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let anchorData = anchor.rawValue
        
        // Parse anchor
        var requestedAnchor: UInt64 = 0
        
        if anchorData.count == 8 {
            requestedAnchor = anchorData.withUnsafeBytes { $0.load(as: UInt64.self) }
        } else if let _ = String(data: anchorData, encoding: .utf8) {
            // Legacy string anchor - treat as 0 to get all changes
            requestedAnchor = 0
        }
        
        let currentAnchor = MetadataAnchorCache.shared.currentAnchor
        
        logger.info("enumerateChanges: requested=\(requestedAnchor) current=\(currentAnchor)")
        
        // CASE 1: Same anchor - no changes
        if requestedAnchor >= currentAnchor {
            logger.info("No changes (requested >= current)")
            let newAnchor = makeAnchor(currentAnchor)
            observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)
            return
        }
        
        // CASE 2: Older anchor - query MetadataStore for changes
        Task {
            do {
                let (modified, deletedIds, newAnchorValue) = try await MetadataStore.shared.changesSince(anchor: requestedAnchor)
                
                logger.info("Changes: \(modified.count) modified, \(deletedIds.count) deleted")
                
                // Report deletions first
                if !deletedIds.isEmpty {
                    let identifiers = deletedIds.map { NSFileProviderItemIdentifier($0) }
                    observer.didDeleteItems(withIdentifiers: identifiers)
                }
                
                // Report modified items
                // Note: We report ALL modified items. iOS will handle parent resolution.
                // Previously we filtered to only items with parent in modified set, but this
                // incorrectly excluded items in subfolders when the subfolder wasn't modified.
                // Fixed Jan 2, 2026 - see testSubfolderFileChangesAreReported test.
                if !modified.isEmpty {
                    let items = modified.map { CachedMetadataItem(metadata: $0) }
                    observer.didUpdate(items)
                }
                
                let newAnchor = self.makeAnchor(newAnchorValue)
                observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)
                logger.info("enumerateChanges completed, finalAnchor=\(newAnchorValue)")
                
            } catch {
                logger.error("enumerateChanges error: \(error.localizedDescription)")
                // On error, still finish with current anchor
                let newAnchor = self.makeAnchor(currentAnchor)
                observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)
            }
        }
    }
    
    // MARK: - Current Sync Anchor
    
    /// Return current anchor synchronously.
    /// Uses MetadataAnchorCache for thread-safe sync access.
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let anchor = MetadataAnchorCache.shared.syncAnchor
        let anchorValue = MetadataAnchorCache.shared.currentAnchor
        logger.info("currentSyncAnchor: \(anchorValue)")
        completionHandler(anchor)
    }
    
    // MARK: - Helpers
    
    /// Create NSFileProviderSyncAnchor from UInt64
    private func makeAnchor(_ value: UInt64) -> NSFileProviderSyncAnchor {
        var v = value
        let data = Data(bytes: &v, count: 8)
        return NSFileProviderSyncAnchor(data)
    }
}

// MARK: - CachedMetadataItem

/// NSFileProviderItem wrapper for CachedFileMetadata
/// Used to report items in enumerateChanges
final class CachedMetadataItem: NSObject, NSFileProviderItem {
    let metadata: CachedFileMetadata
    
    init(metadata: CachedFileMetadata) {
        self.metadata = metadata
        super.init()
    }
    
    var itemIdentifier: NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(metadata.itemIdentifier)
    }
    
    var parentItemIdentifier: NSFileProviderItemIdentifier {
        if metadata.parentIdentifier == "root" {
            return .rootContainer
        }
        return NSFileProviderItemIdentifier(metadata.parentIdentifier)
    }
    
    var capabilities: NSFileProviderItemCapabilities {
        if metadata.isDirectory {
            return [.allowsReading, .allowsWriting, .allowsContentEnumerating, .allowsAddingSubItems, .allowsDeleting, .allowsRenaming]
        }
        return [.allowsReading, .allowsWriting, .allowsDeleting, .allowsRenaming]
    }
    
    var filename: String {
        metadata.filename
    }
    
    var contentType: UTType {
        metadata.isDirectory ? .folder : .data
    }
    
    var documentSize: NSNumber? {
        NSNumber(value: metadata.size)
    }
    
    var contentModificationDate: Date? {
        metadata.modificationDate
    }
    
    var creationDate: Date? {
        metadata.modificationDate // Use mod date as creation date
    }
    
    // CRITICAL: Required for NSFileProviderReplicatedExtension
    // Without this, iOS may reject items or show "Syncing Paused"
    var itemVersion: NSFileProviderItemVersion {
        let modTime = metadata.modificationDate?.timeIntervalSince1970 ?? 0
        let contentVer = "\(metadata.size):\(modTime)".data(using: .utf8)!
        let metaVer = "\(modTime)".data(using: .utf8)!
        return NSFileProviderItemVersion(contentVersion: contentVer, metadataVersion: metaVer)
    }
    
    // MARK: - Transfer Status Properties
    
    /// Folders are always "downloaded" for browsing. Files are streamed on demand.
    var isDownloaded: Bool {
        metadata.isDirectory // Folders always show as available
    }
    
    /// All items exist on remote server (cached metadata = server state)
    var isUploaded: Bool {
        true
    }
    
    /// No active downloads in enumerator (downloads happen through startProvidingItem)
    var isDownloading: Bool {
        false
    }
    
    /// No active uploads from File Provider (read-only currently)
    var isUploading: Bool {
        false
    }
}
