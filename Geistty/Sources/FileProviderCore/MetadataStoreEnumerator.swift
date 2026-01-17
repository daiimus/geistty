//
//  MetadataStoreEnumerator.swift
//  Geistty
//
//  Working set enumerator that uses MetadataStore for change tracking.
//  
//  Architecture (Jan 16, 2026):
//  - Queries MetadataStore directly (no separate anchor cache)
//  - Uses "V{version}-{iteration}" anchor format (like Blink)
//  - Strict anchor validation - returns syncAnchorExpired on version mismatch
//  - SwiftData is the ONLY source of truth
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
/// - Queries MetadataStore actor directly for anchors
/// - Uses "V{version}-{iteration}" format for anchors
/// - Strict validation: version mismatch → syncAnchorExpired
/// - Task{} for async operations (Apple-approved)
class MetadataStoreEnumerator: NSObject, NSFileProviderEnumerator {
    
    override init() {
        super.init()
        logger.info("📦 MetadataStoreEnumerator created")
    }
    
    func invalidate() {
        logger.info("📦 MetadataStoreEnumerator invalidated")
    }
    
    // MARK: - Enumerate Items
    
    /// Working set returns NO items in enumerateItems.
    /// All content flows through enumerateChanges.
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        logger.info("📦 enumerateItems called - returning empty (per Apple pattern)")
        observer.finishEnumerating(upTo: nil)
    }
    
    // MARK: - Enumerate Changes
    
    /// Report all changes since the requested anchor.
    /// For expired/invalid anchors, returns ALL items as a fresh sync.
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let anchorString = String(data: anchor.rawValue, encoding: .utf8) ?? "<binary>"
        logger.info("📦 enumerateChanges called: anchor=\(anchorString)")
        
        Task {
            do {
                // Validate anchor using the new strict validation
                let validation = try await MetadataStore.shared.validateAnchor(anchor)
                
                switch validation {
                case .noChanges:
                    // Same anchor - no changes to report
                    logger.info("📦 enumerateChanges: no changes (same anchor)")
                    observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
                    return
                    
                case .expired(let requestedVersion, let currentVersion):
                    // Version mismatch - enumerate ALL items as fresh sync
                    // DO NOT return syncAnchorExpired (causes "Syncing Paused")
                    logger.warning("📦 enumerateChanges: anchor expired (v\(requestedVersion) != v\(currentVersion)), returning all items")
                    try await enumerateAllItems(for: observer)
                    return
                    
                case .invalid:
                    // Malformed anchor - enumerate ALL items as fresh sync
                    logger.warning("📦 enumerateChanges: invalid anchor format, returning all items")
                    try await enumerateAllItems(for: observer)
                    return
                    
                case .valid(let iteration):
                    // Valid anchor - get changes since iteration
                    let (modified, deletedIds, newAnchor) = try await MetadataStore.shared.changesSince(anchor: iteration)
                    
                    logger.info("📦 Changes found: \(modified.count) modified, \(deletedIds.count) deleted")
                    
                    // Report deletions first
                    if !deletedIds.isEmpty {
                        let identifiers = deletedIds.map { NSFileProviderItemIdentifier($0) }
                        observer.didDeleteItems(withIdentifiers: identifiers)
                    }
                    
                    // Report modified items
                    if !modified.isEmpty {
                        let items = modified.map { CachedMetadataItem(metadata: $0) }
                        observer.didUpdate(items)
                    }
                    
                    observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)
                    let anchorStr = String(data: newAnchor.rawValue, encoding: .utf8) ?? "<binary>"
                    logger.info("📦 enumerateChanges completed, newAnchor=\(anchorStr)")
                }
                
            } catch {
                logger.error("📦 enumerateChanges error: \(error.localizedDescription)")
                // On unexpected error, try to return all items as fallback
                do {
                    try await enumerateAllItems(for: observer)
                } catch {
                    // NEVER return syncAnchorExpired - it causes "Syncing Paused"
                    // Instead, complete with empty results and current anchor
                    // iOS will retry later
                    logger.error("📦 Failed to enumerate all items: \(error.localizedDescription), completing with empty results")
                    let emptyAnchor = "V1-0".data(using: .utf8)!
                    observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(emptyAnchor), moreComing: false)
                }
            }
        }
    }
    
    /// Enumerate ALL items as a fresh sync (used for expired/invalid anchors)
    private func enumerateAllItems(for observer: NSFileProviderChangeObserver) async throws {
        let allItems = try await MetadataStore.shared.allActiveItems()
        let newAnchor = try await MetadataStore.shared.currentSyncAnchor
        
        logger.info("📦 Fresh sync: returning \(allItems.count) items")
        
        if !allItems.isEmpty {
            let items = allItems.map { CachedMetadataItem(metadata: $0) }
            observer.didUpdate(items)
        }
        
        observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)
        let anchorStr = String(data: newAnchor.rawValue, encoding: .utf8) ?? "<binary>"
        logger.info("📦 Fresh sync completed, newAnchor=\(anchorStr)")
    }
    
    // MARK: - Current Sync Anchor
    
    /// Return current anchor by querying MetadataStore.
    /// Uses Task{} pattern - Apple docs confirm this is fine for File Provider callbacks.
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        logger.info("📦 currentSyncAnchor called")
        
        Task {
            do {
                let anchor = try await MetadataStore.shared.currentSyncAnchor
                let anchorStr = String(data: anchor.rawValue, encoding: .utf8) ?? "<binary>"
                logger.info("📦 currentSyncAnchor returning: \(anchorStr)")
                completionHandler(anchor)
            } catch {
                logger.error("📦 currentSyncAnchor error: \(error.localizedDescription)")
                // Return nil to signal iOS should start fresh
                completionHandler(nil)
            }
        }
    }
}

// MARK: - CachedMetadataItem

/// NSFileProviderItem wrapper for CachedFileMetadata
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
        metadata.modificationDate
    }
    
    var itemVersion: NSFileProviderItemVersion {
        let modTime = metadata.modificationDate?.timeIntervalSince1970 ?? 0
        let contentVer = "\(metadata.size):\(modTime)".data(using: .utf8)!
        let metaVer = "\(modTime)".data(using: .utf8)!
        return NSFileProviderItemVersion(contentVersion: contentVer, metadataVersion: metaVer)
    }
    
    var isDownloaded: Bool {
        metadata.isDirectory
    }
    
    var isUploaded: Bool {
        true
    }
    
    var isDownloading: Bool {
        false
    }
    
    var isUploading: Bool {
        false
    }
}
