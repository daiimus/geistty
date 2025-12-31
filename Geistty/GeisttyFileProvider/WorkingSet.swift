//
//  WorkingSet.swift
//  GeisttyFileProvider
//
//  Manages the File Provider working set with proper change detection and sync anchors.
//  This is the core component that enables iOS to detect and display changes to remote files.
//
//  Architecture:
//  - WorkingSet actor: Manages sync anchors, change tracking, and active folder list
//  - Detects changes by comparing server state vs cached state
//  - Signals .workingSet enumerator when changes detected
//
//  Based on patterns from Blink's FileProviderReplicatedEnumerator
//

import FileProvider
import Foundation
import os.log

private let logger = Logger(subsystem: "com.geistty.fileprovider", category: "WorkingSet")

// MARK: - Sync Anchor

/// Sync anchor format: "VERSION-ITERATION" (e.g., "ABCD-42")
/// VERSION is a random string that changes when the working set is reset
/// ITERATION increments with each change batch
struct SyncAnchorState {
    var version: String
    var iteration: Int
    
    init() {
        self.version = Self.generateVersion()
        self.iteration = 0
    }
    
    init?(from anchor: NSFileProviderSyncAnchor) {
        guard let string = String(data: anchor.rawValue, encoding: .utf8) else { return nil }
        let parts = string.components(separatedBy: "-")
        guard parts.count == 2,
              let iteration = Int(parts[1]) else { return nil }
        self.version = parts[0]
        self.iteration = iteration
    }
    
    var anchor: NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor("\(version)-\(iteration)".data(using: .utf8)!)
    }
    
    mutating func increment() {
        iteration += 1
    }
    
    mutating func reset() {
        version = Self.generateVersion()
        iteration = 0
    }
    
    func isNewer(than other: SyncAnchorState) -> Bool {
        if version != other.version { return true }
        return iteration > other.iteration
    }
    
    func isCompatible(with other: SyncAnchorState) -> Bool {
        version == other.version
    }
    
    private static func generateVersion() -> String {
        String((0..<4).map { _ in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".randomElement()! })
    }
}

// MARK: - Active Folder Tracking

/// Tracks a folder that the user has visited and should be polled for changes
struct ActiveFolder: Hashable {
    let connectionId: String
    let path: String
    let itemIdentifier: NSFileProviderItemIdentifier
    
    /// For hashing - use path-based identity
    func hash(into hasher: inout Hasher) {
        hasher.combine(connectionId)
        hasher.combine(path)
    }
    
    static func == (lhs: ActiveFolder, rhs: ActiveFolder) -> Bool {
        lhs.connectionId == rhs.connectionId && lhs.path == rhs.path
    }
}

// MARK: - Detected Changes

/// Collection of changes detected in a polling cycle
struct DetectedChanges {
    var creates: [NSFileProviderItemIdentifier] = []
    var updates: [NSFileProviderItemIdentifier] = []
    var deletions: [NSFileProviderItemIdentifier] = []
    
    var isEmpty: Bool {
        creates.isEmpty && updates.isEmpty && deletions.isEmpty
    }
    
    var count: Int {
        creates.count + updates.count + deletions.count
    }
    
    mutating func merge(_ other: DetectedChanges) {
        creates.append(contentsOf: other.creates)
        updates.append(contentsOf: other.updates)
        deletions.append(contentsOf: other.deletions)
    }
}

// MARK: - Working Set Actor

/// Central manager for change detection and working set synchronization.
/// Manages sync anchors, tracks active folders, and stores pending changes.
/// Active folders are persisted to survive extension relaunches.
actor WorkingSet {
    
    // MARK: - Properties
    
    /// The File Provider domain we're managing
    let domain: NSFileProviderDomain
    
    /// File Provider manager for signaling
    let manager: NSFileProviderManager?
    
    /// Current sync anchor state
    private var anchorState = SyncAnchorState()
    
    /// Pending changes to report in next enumerateChanges call
    private var pendingChanges = DetectedChanges()
    
    /// Folders that should be polled for changes (loaded from persistent storage)
    private var _activeFolders: Set<ActiveFolder>?
    
    /// App Group identifier for persistent storage
    private let appGroupIdentifier = "group.com.geistty.fileprovider"
    
    /// Maximum number of active folders to track (prevent memory bloat)
    private let maxActiveFolders = 20
    
    /// Whether we've been invalidated
    private var isInvalidated = false
    
    // MARK: - Initialization
    
    init(domain: NSFileProviderDomain) {
        self.domain = domain
        self.manager = NSFileProviderManager(for: domain)
        NSLog("🔄 [WorkingSet] initialized for domain: %@", domain.identifier.rawValue)
        Self.debugLog("WorkingSet initialized for domain: \(domain.identifier.rawValue)")
    }
    
    // MARK: - Public API
    
    /// Get active folders (loads from persistent storage on first access)
    var activeFolders: Set<ActiveFolder> {
        get {
            if _activeFolders == nil {
                _activeFolders = loadActiveFolders()
                NSLog("🔄 [WorkingSet] Loaded %d active folders from storage", _activeFolders?.count ?? 0)
            }
            return _activeFolders ?? []
        }
    }
    
    /// Get current sync anchor
    var currentAnchor: NSFileProviderSyncAnchor {
        anchorState.anchor
    }
    
    /// Check if invalidated
    var invalidated: Bool {
        isInvalidated
    }
    
    /// Register a folder as active (will be polled for changes)
    func registerActiveFolder(connectionId: String, path: String, identifier: NSFileProviderItemIdentifier) {
        guard !isInvalidated else { return }
        
        // Ensure loaded
        if _activeFolders == nil {
            _activeFolders = loadActiveFolders()
        }
        
        let folder = ActiveFolder(connectionId: connectionId, path: path, itemIdentifier: identifier)
        
        // If we're at capacity, remove oldest
        if _activeFolders!.count >= maxActiveFolders && !_activeFolders!.contains(folder) {
            if let oldest = _activeFolders!.first {
                _activeFolders!.remove(oldest)
            }
        }
        
        _activeFolders!.insert(folder)
        saveActiveFolders()
        NSLog("🔄 [WorkingSet] Registered active folder: %@ (%d total)", path, _activeFolders!.count)
        Self.debugLog("Registered active folder: \(path) (\(_activeFolders!.count) active)")
    }
    
    /// Unregister a folder (no longer needs polling)
    func unregisterActiveFolder(connectionId: String, path: String) {
        if _activeFolders == nil {
            _activeFolders = loadActiveFolders()
        }
        
        let folder = ActiveFolder(connectionId: connectionId, path: path, 
                                  itemIdentifier: NSFileProviderItemIdentifier("")) // identifier not used for equality
        _activeFolders?.remove(folder)
        saveActiveFolders()
        NSLog("🔄 [WorkingSet] Unregistered active folder: %@ (%d remaining)", path, _activeFolders?.count ?? 0)
        Self.debugLog("Unregistered active folder: \(path) (\(_activeFolders?.count ?? 0) active)")
    }
    
    /// Record detected changes and increment anchor
    func recordChanges(_ changes: DetectedChanges) {
        guard !changes.isEmpty else { return }
        
        pendingChanges.merge(changes)
        anchorState.increment()
        Self.debugLog("Recorded \(changes.count) changes, anchor now: \(anchorState.iteration)")
        
        // Signal iOS that the working set has changes
        signalWorkingSetChange()
    }
    
    /// Get changes since the given anchor
    func getChanges(since anchor: NSFileProviderSyncAnchor) -> (changes: DetectedChanges, newAnchor: NSFileProviderSyncAnchor, expired: Bool) {
        guard let requestedState = SyncAnchorState(from: anchor) else {
            // Invalid anchor - return expired
            Self.debugLog("Invalid anchor format, returning expired")
            return (DetectedChanges(), currentAnchor, true)
        }
        
        // Check if anchor version matches (indicates whether we've been reset)
        if !requestedState.isCompatible(with: anchorState) {
            Self.debugLog("Anchor version mismatch, returning expired")
            return (DetectedChanges(), currentAnchor, true)
        }
        
        // Check if there are changes
        if requestedState.iteration == anchorState.iteration {
            // Same anchor - no changes
            Self.debugLog("Same anchor iteration, no changes")
            return (DetectedChanges(), currentAnchor, false)
        }
        
        if requestedState.iteration == anchorState.iteration - 1 {
            // Client is one behind - return pending changes
            Self.debugLog("Returning \(pendingChanges.count) pending changes")
            let changes = pendingChanges
            pendingChanges = DetectedChanges() // Clear after returning
            return (changes, currentAnchor, false)
        }
        
        // Client is too far behind - return expired
        Self.debugLog("Anchor too old (\(requestedState.iteration) vs \(anchorState.iteration)), returning expired")
        return (DetectedChanges(), currentAnchor, true)
    }
    
    /// Invalidate the working set (called on extension shutdown)
    func invalidate() {
        isInvalidated = true
        _activeFolders?.removeAll()
        pendingChanges = DetectedChanges()
        Self.debugLog("WorkingSet invalidated")
    }
    
    // MARK: - Persistence
    
    /// File URL for persisted active folders
    private var activeFoldersFileURL: URL? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return nil
        }
        return containerURL.appendingPathComponent("active_folders.json")
    }
    
    /// Load active folders from persistent storage
    private func loadActiveFolders() -> Set<ActiveFolder> {
        guard let fileURL = activeFoldersFileURL else {
            NSLog("🔄 [WorkingSet] Cannot access app group container")
            return []
        }
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            NSLog("🔄 [WorkingSet] No persisted active folders file")
            return []
        }
        
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode([PersistedActiveFolder].self, from: data)
            let folders = Set(decoded.map { 
                ActiveFolder(
                    connectionId: $0.connectionId, 
                    path: $0.path, 
                    itemIdentifier: NSFileProviderItemIdentifier($0.itemIdentifier)
                )
            })
            NSLog("🔄 [WorkingSet] Loaded %d active folders from disk", folders.count)
            return folders
        } catch {
            NSLog("🔄 [WorkingSet] Failed to load active folders: %@", error.localizedDescription)
            return []
        }
    }
    
    /// Save active folders to persistent storage
    private func saveActiveFolders() {
        guard let fileURL = activeFoldersFileURL else {
            NSLog("🔄 [WorkingSet] Cannot access app group container for saving")
            return
        }
        
        guard let folders = _activeFolders else { return }
        
        let persisted = folders.map { 
            PersistedActiveFolder(
                connectionId: $0.connectionId, 
                path: $0.path, 
                itemIdentifier: $0.itemIdentifier.rawValue
            )
        }
        
        do {
            let data = try JSONEncoder().encode(persisted)
            try data.write(to: fileURL)
            NSLog("🔄 [WorkingSet] Saved %d active folders to disk", folders.count)
        } catch {
            NSLog("🔄 [WorkingSet] Failed to save active folders: %@", error.localizedDescription)
        }
    }
    
    // MARK: - Private (Signaling)
    
    private func signalWorkingSetChange() {
        manager?.signalEnumerator(for: .workingSet) { error in
            if let error = error {
                Self.debugLog("Failed to signal working set: \(error.localizedDescription)")
            } else {
                Self.debugLog("Successfully signaled working set change")
            }
        }
    }
    
    // MARK: - Debug Logging
    
    private static func debugLog(_ message: String) {
        logger.debug("🔄 [WorkingSet] \(message)")
        NSLog("🔄 [WorkingSet] %@", message)
    }
}

// MARK: - Persistence Helper

/// Codable struct for persisting ActiveFolder
private struct PersistedActiveFolder: Codable {
    let connectionId: String
    let path: String
    let itemIdentifier: String
}
