//
//  FileProviderExtension.swift
//  GeisttyFileProvider
//
//  NSFileProviderReplicatedExtension implementation for SFTP access via Files.app
//
//  Architecture:
//  - ONE "Geistty" domain in Files.app sidebar
//  - Root shows connections with Files integration enabled as folders
//  - Each connection folder shows remote files via SFTP
//  - SwiftData cache enables fast enumeration (return cached, refresh in background)
//
//  Item Identifier Format:
//  - Root: .rootContainer
//  - Connection folder: "conn:<profileId>"
//  - Remote file/folder: "conn:<profileId>:path:<remotePath>"
//

import FileProvider
import NIOCore
import NIOSSH
import os.log
import SwiftData
import UniformTypeIdentifiers

private let logger = Logger(subsystem: "com.geistty.fileprovider", category: "Extension")

// MARK: - Shared Debug Logging

/// Writes debug info to shared container for debugging File Provider issues.
/// This is separate from os.Logger because File Provider extension logs can be
/// difficult to capture. The log file is in the shared App Group container.
///
/// Usage: `FileProviderDebugLog.write("message", category: "MyClass")`
enum FileProviderDebugLog {
    private static let groupId = FileProviderDomainManager.appGroupIdentifier
    
    /// Write a debug message to the shared log file
    static func write(_ message: String, category: String = "Extension") {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupId
        ) else {
            NSLog("❌ [FP-DEBUG] Cannot access shared container")
            return
        }
        
        let logFile = containerURL.appendingPathComponent("fileprovider_debug.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(timestamp)] \(category): \(message)\n"
        
        if FileManager.default.fileExists(atPath: logFile.path) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(entry.data(using: .utf8)!)
                handle.closeFile()
            }
        } else {
            try? entry.write(to: logFile, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Shared Connection Manager

/// Singleton to manage SFTP connections across the extension
/// Enumerators and the extension share this to avoid creating new connections for each request
actor SFTPConnectionManager {
    static let shared = SFTPConnectionManager()
    
    private var sftpClients: [String: SFTPClient] = [:]
    private var sshConnections: [String: NIOSSHConnection] = [:]
    private var connectingTasks: [String: Task<SFTPClient, Error>] = [:]
    
    private init() {}
    
    /// Gets or creates an SFTP client for a connection
    func getClient(for connectionId: String) async throws -> SFTPClient {
        Self.debugLog("getClient for: \(connectionId)")
        
        // Return existing connected client
        if let client = sftpClients[connectionId], await client.isConnected {
            Self.debugLog("Returning cached client")
            return client
        }
        
        // If already connecting, wait for that task
        if let existingTask = connectingTasks[connectionId] {
            Self.debugLog("Waiting for existing connection task")
            return try await existingTask.value
        }
        
        // Create new connection task
        Self.debugLog("Creating new connection task")
        let task = Task<SFTPClient, Error> {
            let client = try await self.createConnection(connectionId: connectionId)
            return client
        }
        
        connectingTasks[connectionId] = task
        
        do {
            let client = try await task.value
            connectingTasks.removeValue(forKey: connectionId)
            Self.debugLog("Connection successful")
            return client
        } catch {
            connectingTasks.removeValue(forKey: connectionId)
            Self.debugLog("Connection failed: \(error.localizedDescription)")
            throw error
        }
    }
    
    /// Delegate to shared debug log utility
    private static func debugLog(_ message: String) {
        FileProviderDebugLog.write(message, category: "SFTPConnectionManager")
    }
    
    private func createConnection(connectionId: String) async throws -> SFTPClient {
        Self.debugLog("createConnection for: \(connectionId)")
        
        // Step 1: Get connection info from shared storage
        guard let conn = FileProviderDomainManager.getConnection(id: connectionId) else {
            Self.debugLog("ERROR: Connection not found: \(connectionId)")
            NSLog("❌ [FP-MGR] Connection not found: %@", connectionId)
            // Connection not found is noSuchItem, not auth error
            throw NSFileProviderError(.noSuchItem)
        }
        
        Self.debugLog("Found connection: \(conn.name) @ \(conn.host):\(conn.port)")
        Self.debugLog("authMethod=\(conn.authMethod), hasSSHKey=\(conn.sshKeyData != nil), hasPassword=\(conn.password != nil)")
        
        NSLog("📂 [FP-MGR] Connecting to %@:%d as %@...", conn.host, conn.port, conn.username)
        NSLog("📂 [FP-MGR] authMethod=%@, hasSSHKeyData=%d, hasPassword=%d", 
              conn.authMethod, conn.sshKeyData != nil ? 1 : 0, conn.password != nil ? 1 : 0)
        
        // Step 2: Decode credentials from stored data
        var sshKeyData: Data?
        var password: String?
        
        if let keyDataB64 = conn.sshKeyData {
            NSLog("📂 [FP-MGR] Decoding SSH key from base64 (%d chars)", keyDataB64.count)
            if let data = Data(base64Encoded: keyDataB64) {
                sshKeyData = data
                Self.debugLog("SSH key decoded: \(data.count) bytes")
                NSLog("📂 [FP-MGR] SSH key decoded: %d bytes", data.count)
            } else {
                Self.debugLog("ERROR: Failed to decode SSH key from base64")
                NSLog("❌ [FP-MGR] Failed to decode SSH key from base64")
            }
        }
        password = conn.password
        
        // No credentials = auth required
        guard sshKeyData != nil || password != nil else {
            Self.debugLog("ERROR: No credentials for connection")
            NSLog("❌ [FP-MGR] No credentials for connection %@", connectionId)
            throw NSFileProviderError(.notAuthenticated)
        }
        
        // Step 3: Create SSH connection object
        Self.debugLog("Creating SSH connection...")
        let connection = await NIOSSHConnection(host: conn.host, port: conn.port, username: conn.username)
        
        // Step 4: Build auth method from credentials
        let authMethod: SSHAuthMethod
        if let keyData = sshKeyData {
            NSLog("📂 [FP-MGR] Parsing SSH key...")
            do {
                let privateKey = try SSHKeyParser.parsePrivateKey(keyData, passphrase: nil)
                authMethod = .publicKey(privateKey: privateKey)
                Self.debugLog("SSH key parsed successfully")
                NSLog("📂 [FP-MGR] SSH key parsed successfully")
            } catch {
                Self.debugLog("SSH key parse error: \(error.localizedDescription)")
                NSLog("❌ [FP-MGR] SSH key parse error: %@", error.localizedDescription)
                // Key parsing failed - this is an auth problem (invalid key)
                if let pwd = password {
                    // Fall back to password if available
                    Self.debugLog("Falling back to password auth")
                    authMethod = .password(pwd)
                } else {
                    throw NSFileProviderError(.notAuthenticated)
                }
            }
        } else if let pwd = password {
            authMethod = .password(pwd)
        } else {
            throw NSFileProviderError(.notAuthenticated)
        }
        
        // Step 5: Connect SSH with proper error mapping
        Self.debugLog("Connecting SSH (SFTP mode)...")
        do {
            try await connection.connectForSFTP(authMethod: authMethod)
            Self.debugLog("SSH connected to \(conn.host)")
            NSLog("📂 [FP-MGR] SSH connected to %@", conn.host)
        } catch let error as NIOSSHError {
            // Map NIOSSH errors to appropriate File Provider errors
            Self.debugLog("SSH connection error: \(error)")
            NSLog("❌ [FP-MGR] SSH connection error: %@", String(describing: error))
            switch error {
            case .networkUnavailable:
                throw NSFileProviderError(.serverUnreachable)
            case .connectionFailed(let reason):
                // Connection failures could be network or auth - check the reason
                if reason.lowercased().contains("auth") ||
                   reason.lowercased().contains("permission") ||
                   reason.lowercased().contains("denied") {
                    throw NSFileProviderError(.notAuthenticated)
                }
                throw NSFileProviderError(.serverUnreachable)
            case .channelError:
                // Channel errors during auth verification = auth failed
                throw NSFileProviderError(.notAuthenticated)
            default:
                throw NSFileProviderError(.serverUnreachable)
            }
        } catch {
            // Unknown errors default to serverUnreachable
            Self.debugLog("Unknown connection error: \(error.localizedDescription)")
            NSLog("❌ [FP-MGR] Unknown connection error: %@", error.localizedDescription)
            throw NSFileProviderError(.serverUnreachable)
        }
        
        // Step 6: Get parent channel for SFTP
        guard let parentChannel = await connection.parentChannel else {
            Self.debugLog("ERROR: parentChannel is nil after connect")
            NSLog("❌ [FP-MGR] parentChannel is nil after connect")
            throw NSFileProviderError(.serverUnreachable)
        }
        
        // Step 7: Create and connect SFTP client
        Self.debugLog("Creating SFTP client...")
        let client = SFTPClient(parentChannel: parentChannel)
        
        do {
            // Skip realpath for File Provider - avoids blocking network call
            try await client.connect(host: conn.host, username: conn.username, resolveHomePath: false)
            Self.debugLog("SFTP connected!")
            NSLog("📂 [FP-MGR] SFTP connected to %@", conn.host)
            
            // Step 7a: Signal that previous errors are resolved now that we're connected
            // This clears "Syncing Paused" state in Files.app
            await self.signalErrorsResolved()
        } catch let error as SFTPError {
            Self.debugLog("SFTP error: \(error)")
            NSLog("❌ [FP-MGR] SFTP error: %@", error.localizedDescription)
            // SFTP errors after SSH connected are usually server issues
            throw NSFileProviderError(.serverUnreachable)
        } catch {
            Self.debugLog("Unknown SFTP error: \(error.localizedDescription)")
            NSLog("❌ [FP-MGR] Unknown SFTP error: %@", error.localizedDescription)
            throw NSFileProviderError(.serverUnreachable)
        }
        
        // Step 8: Store for reuse
        sshConnections[connectionId] = connection
        sftpClients[connectionId] = client
        
        return client
    }
    
    /// Disconnects all clients
    func disconnectAll() async {
        for (_, client) in sftpClients {
            await client.disconnect()
        }
        sftpClients.removeAll()
        
        for (_, conn) in sshConnections {
            await conn.disconnect()
        }
        sshConnections.removeAll()
    }
    
    /// Disconnects a specific client
    func disconnect(connectionId: String) async {
        if let client = sftpClients.removeValue(forKey: connectionId) {
            await client.disconnect()
        }
        if let conn = sshConnections.removeValue(forKey: connectionId) {
            await conn.disconnect()
        }
    }
    
    /// Signal that previous errors (serverUnreachable, notAuthenticated) are resolved
    /// This clears "Syncing Paused" state in Files.app
    private func signalErrorsResolved() async {
        // Get all domains and signal errors resolved for each
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
                guard error == nil else {
                    Self.debugLog("Failed to get domains: \(error?.localizedDescription ?? "unknown")")
                    continuation.resume()
                    return
                }
                
                Task {
                    for domain in domains {
                        guard let manager = NSFileProviderManager(for: domain) else { continue }
                        
                        // Signal both resolvable error types as resolved
                        let resolvableErrors: [NSFileProviderError.Code] = [.notAuthenticated, .serverUnreachable]
                        for errorCode in resolvableErrors {
                            let error = NSFileProviderError(errorCode)
                            do {
                                try await manager.signalErrorResolved(error)
                                Self.debugLog("Signaled error resolved: \(errorCode.rawValue)")
                            } catch {
                                // Ignore - the error type might not be pending
                            }
                        }
                    }
                    continuation.resume()
                }
            }
        }
    }
}

/// Main File Provider extension class
class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    
    // MARK: - Properties
    
    let domain: NSFileProviderDomain
    
    /// Manager for this domain
    private lazy var manager: NSFileProviderManager? = {
        NSFileProviderManager(for: domain)
    }()
    
    /// Background polling task for change detection
    private var pollingTask: Task<Void, Never>?
    
    /// Polling interval in seconds
    private let pollingInterval: TimeInterval = 5
    
    // MARK: - Initialization
    
    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        NSLog("📂 [FP-EXT] FileProviderExtension init for domain: %@ [BUILD:2026-01-01-C]", domain.identifier.rawValue)
        
        // Debug: Write to shared container with build marker
        Self.debugLog("Extension init for domain: \(domain.identifier.rawValue) [BUILD:2026-01-01-C]")
        
        // Clear old log entries on fresh start
        Self.clearLogFile()
        
        // CRITICAL: Initialize MetadataStore anchor cache on startup
        // This ensures currentSyncAnchor() returns a valid value immediately
        Task {
            do {
                let anchor = try await MetadataStore.shared.currentAnchor
                NSLog("📂 [FP-EXT] MetadataStore initialized with anchor: %llu", anchor)
                Self.debugLog("MetadataStore initialized with anchor: \(anchor)")
            } catch {
                NSLog("❌ [FP-EXT] MetadataStore init failed: %@", error.localizedDescription)
                Self.debugLog("MetadataStore init failed: \(error.localizedDescription)")
            }
        }
        
        // CRITICAL: Signal working set immediately on startup
        // This tells iOS we support working set sync and triggers it to call
        // currentSyncAnchor and enumerateChanges, which clears "Syncing Paused"
        Task { @MainActor [weak self] in
            guard let self = self, let manager = self.manager else { return }
            do {
                try await manager.signalEnumerator(for: .workingSet)
                Self.debugLog("Initial workingSet signal sent successfully")
            } catch {
                Self.debugLog("Initial workingSet signal failed: \(error.localizedDescription)")
            }
        }
        
        // Start background polling for change detection
        startPolling()
    }
    
    /// Delegate to shared debug log utility
    private static func debugLog(_ message: String) {
        FileProviderDebugLog.write(message, category: "Extension")
    }
    
    /// Clear the log file to start fresh
    private static func clearLogFile() {
        let groupId = FileProviderDomainManager.appGroupIdentifier
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupId) else {
            return
        }
        
        let logFile = containerURL.appendingPathComponent("fileprovider_debug.log")
        try? FileManager.default.removeItem(at: logFile)
        
        // Write initial header
        let header = "=== LOG CLEARED - NEW SESSION ===\n"
        try? header.write(to: logFile, atomically: true, encoding: .utf8)
    }
    
    func invalidate() {
        NSLog("📂 [FP-EXT] Invalidating extension")
        // Stop polling and disconnect all SFTP connections
        pollingTask?.cancel()
        pollingTask = nil
        Task {
            await SFTPConnectionManager.shared.disconnectAll()
        }
    }
    
    // MARK: - Change Detection Polling
    
    /// Start background polling for change detection in active folders
    private func startPolling() {
        NSLog("🔄 [FP-EXT] startPolling() called")
        Self.debugLog("Starting change detection polling (interval: \(pollingInterval)s)")
        
        pollingTask = Task { [weak self] in
            NSLog("🔄 [FP-EXT] Polling task started")
            var pollCount = 0
            while !Task.isCancelled {
                // Wait for polling interval
                try? await Task.sleep(nanoseconds: UInt64(5_000_000_000)) // 5 seconds
                
                guard let self = self else { 
                    NSLog("🔄 [FP-EXT] Polling task: self is nil, breaking")
                    break 
                }
                guard !Task.isCancelled else { 
                    NSLog("🔄 [FP-EXT] Polling task: cancelled, breaking")
                    break 
                }
                
                pollCount += 1
                NSLog("🔄 [FP-EXT] Polling tick #%d", pollCount)
                await self.pollActiveFolders()
            }
            NSLog("🔄 [FP-EXT] Polling task ended")
        }
    }
    
    /// Poll all active folders for changes
    /// Uses MetadataStore for folder tracking and change detection
    private func pollActiveFolders() async {
        do {
            let folders = try await MetadataStore.shared.activeFolders()
            NSLog("🔄 [FP-EXT] pollActiveFolders: %d active folders", folders.count)
            guard !folders.isEmpty else { 
                NSLog("🔄 [FP-EXT] No active folders, skipping poll")
                return 
            }
            
            Self.debugLog("Polling \(folders.count) active folders for changes...")
            NSLog("🔄 [FP-EXT] Polling folders: %@", folders.map { $0.remotePath }.joined(separator: ", "))
            
            var anyChanges = false
            var foldersWithChanges: [String] = []  // folder identifiers with changes
            
            for folder in folders {
                do {
                    let hadChanges = try await detectChangesInFolderNew(connectionId: folder.connectionId, remotePath: folder.remotePath)
                    if hadChanges {
                        foldersWithChanges.append(CachedItem.remoteItemId(connectionId: folder.connectionId, path: folder.remotePath))
                        anyChanges = true
                    }
                } catch {
                    Self.debugLog("Error polling \(folder.remotePath): \(error.localizedDescription)")
                }
            }
            
            // Signal enumerators if we found changes
            if anyChanges, let manager = self.manager {
                // Signal EACH folder that had changes
                for folderId in foldersWithChanges {
                    do {
                        try await manager.signalEnumerator(for: NSFileProviderItemIdentifier(folderId))
                        Self.debugLog("Signaled folder enumerator: \(folderId)")
                    } catch {
                        Self.debugLog("signalEnumerator(\(folderId)) error: \(error.localizedDescription)")
                    }
                }
                
                // Signal working set for change tracking
                do {
                    try await manager.signalEnumerator(for: .workingSet)
                    Self.debugLog("Signaled working set enumerator successfully")
                } catch {
                    Self.debugLog("signalEnumerator(.workingSet) error: \(error.localizedDescription)")
                }
            }
        } catch {
            Self.debugLog("pollActiveFolders error: \(error.localizedDescription)")
        }
    }
    
    /// Detect changes in a single folder using MetadataStore
    /// Returns true if any changes were detected
    private func detectChangesInFolderNew(connectionId: String, remotePath: String) async throws -> Bool {
        // Get SFTP client for this connection
        let client = try await SFTPConnectionManager.shared.getClient(for: connectionId)
        
        // Get current server state
        let serverEntries = try await client.listDirectory(remotePath)
        
        // Build parent ID
        let parentId = remotePath == "/" 
            ? CachedItem.connectionRootId(connectionId)
            : CachedItem.remoteItemId(connectionId: connectionId, path: remotePath)
        
        // Build items list for MetadataStore
        let items = serverEntries.compactMap { entry -> (id: String, connId: String, path: String, parentId: String, name: String, size: Int64, isDir: Bool, perms: Int32, modDate: Date?, isSymlink: Bool)? in
            guard entry.name != "." && entry.name != ".." else { return nil }
            
            let itemPath = remotePath == "/" ? "/\(entry.name)" : "\(remotePath)/\(entry.name)"
            let itemId = CachedItem.remoteItemId(connectionId: connectionId, path: itemPath)
            
            return (
                id: itemId,
                connId: connectionId,
                path: itemPath,
                parentId: parentId,
                name: entry.name,
                size: Int64(entry.size),
                isDir: entry.isDirectory,
                perms: Int32(entry.permissions),
                modDate: entry.modificationDate,
                isSymlink: entry.isSymlink
            )
        }
        
        // Use MetadataStore.upsertBatch which handles change detection
        let hadChanges = try await MetadataStore.shared.upsertBatch(items: items, parentId: parentId)
        
        if hadChanges {
            Self.debugLog("Changes detected in \(remotePath)")
        }
        
        return hadChanges
    }
    
    // MARK: - Error Conversion
    
    /// Convert various errors to user-friendly NSFileProviderError
    private func toFileProviderError(_ error: Error) -> Error {
        // Already a file provider error
        if error is NSFileProviderError {
            return error
        }
        
        let message = error.localizedDescription.lowercased()
        
        // Connection/network errors
        if message.contains("connection") || message.contains("network") || 
           message.contains("timeout") || message.contains("refused") ||
           message.contains("unreachable") || message.contains("offline") {
            return NSFileProviderError(.serverUnreachable)
        }
        
        // Authentication errors
        if message.contains("auth") || message.contains("permission denied") ||
           message.contains("access denied") || message.contains("credential") {
            return NSFileProviderError(.notAuthenticated)
        }
        
        // File not found
        if message.contains("no such file") || message.contains("not found") ||
           message.contains("does not exist") {
            return NSFileProviderError(.noSuchItem)
        }
        
        // Disk full / quota
        if message.contains("disk full") || message.contains("quota") ||
           message.contains("no space") {
            return NSFileProviderError(.insufficientQuota)
        }
        
        // Default: wrap as server error with description
        NSLog("⚠️ [FP-EXT] Unmapped error: %@", error.localizedDescription)
        return NSFileProviderError(.serverUnreachable)
    }
    
    // MARK: - Item Identifier Parsing
    
    /// Parses an item identifier to extract connection ID and remote path
    private struct ParsedIdentifier {
        let connectionId: String?
        let remotePath: String?
        
        var isRoot: Bool { connectionId == nil }
        var isConnectionRoot: Bool { connectionId != nil && remotePath == nil }
        var isRemotePath: Bool { connectionId != nil && remotePath != nil }
    }
    
    private func parseIdentifier(_ identifier: NSFileProviderItemIdentifier) -> ParsedIdentifier {
        if identifier == .rootContainer {
            return ParsedIdentifier(connectionId: nil, remotePath: nil)
        }
        
        let raw = identifier.rawValue
        
        // Connection folder: "conn:<profileId>"
        if raw.hasPrefix("conn:") && !raw.contains(":path:") {
            let connId = String(raw.dropFirst(5))
            return ParsedIdentifier(connectionId: connId, remotePath: nil)
        }
        
        // Remote item: "conn:<profileId>:path:<remotePath>"
        if raw.hasPrefix("conn:"), let pathRange = raw.range(of: ":path:") {
            let connId = String(raw[raw.index(raw.startIndex, offsetBy: 5)..<pathRange.lowerBound])
            let path = String(raw[pathRange.upperBound...])
            return ParsedIdentifier(connectionId: connId, remotePath: path)
        }
        
        return ParsedIdentifier(connectionId: nil, remotePath: nil)
    }
    
    private func makeConnectionIdentifier(_ connectionId: String) -> NSFileProviderItemIdentifier {
        return NSFileProviderItemIdentifier("conn:\(connectionId)")
    }
    
    private func makeRemoteItemIdentifier(connectionId: String, path: String) -> NSFileProviderItemIdentifier {
        return NSFileProviderItemIdentifier("conn:\(connectionId):path:\(path)")
    }
    
    // MARK: - NSFileProviderReplicatedExtension
    
    func item(for identifier: NSFileProviderItemIdentifier,
              request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        
        NSLog("📂 [FP-EXT] item(for: %@)", identifier.rawValue)
        
        let progress = Progress(totalUnitCount: 1)
        
        Task {
            do {
                let parsed = parseIdentifier(identifier)
                
                if parsed.isRoot {
                    // Root container
                    completionHandler(RootItem(), nil)
                } else if parsed.isConnectionRoot, let connId = parsed.connectionId {
                    // Connection folder
                    if let conn = FileProviderDomainManager.getConnection(id: connId) {
                        completionHandler(ConnectionFolderItem(connection: conn), nil)
                    } else {
                        completionHandler(nil, NSFileProviderError(.noSuchItem))
                    }
                } else if let connId = parsed.connectionId, let path = parsed.remotePath {
                    // Remote item - try cache first for offline support
                    let itemId = identifier.rawValue
                    
                    // Check cache first - this doesn't require a server connection
                    if let cachedItem = try? await MetadataCache.shared.getItem(id: itemId) {
                        // Return cached data immediately
                        completionHandler(CachedRemoteItem(cachedItem: cachedItem, connectionId: connId), nil)
                    } else {
                        // No cache - try server
                        do {
                            let client = try await ensureConnected(connectionId: connId)
                            let attrs = try await client.stat(path)
                            completionHandler(RemoteItem(connectionId: connId, path: path, attributes: attrs), nil)
                        } catch {
                            // Server failed and no cache - report the error
                            NSLog("❌ [FP-EXT] item(for:) no cache and server error: %@", error.localizedDescription)
                            completionHandler(nil, self.toFileProviderError(error))
                        }
                    }
                } else {
                    completionHandler(nil, NSFileProviderError(.noSuchItem))
                }
            } catch {
                NSLog("❌ [FP-EXT] item(for:) error: %@", error.localizedDescription)
                completionHandler(nil, self.toFileProviderError(error))
            }
            progress.completedUnitCount = 1
        }
        
        return progress
    }
    
    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        
        NSLog("📂 [FP-EXT] fetchContents(for: %@)", itemIdentifier.rawValue)
        
        let progress = Progress(totalUnitCount: 100)
        
        Task {
            do {
                let parsed = parseIdentifier(itemIdentifier)
                guard let connId = parsed.connectionId, let path = parsed.remotePath else {
                    throw NSFileProviderError(.noSuchItem)
                }
                
                let client = try await ensureConnected(connectionId: connId)
                
                // Create temp file
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathComponent((path as NSString).lastPathComponent)
                
                try FileManager.default.createDirectory(at: tempURL.deletingLastPathComponent(),
                                                       withIntermediateDirectories: true)
                
                // Download
                let data = try await client.readFile(path) { current, total in
                    if total > 0 {
                        progress.completedUnitCount = Int64(Double(current) / Double(total) * 100)
                    }
                }
                
                try data.write(to: tempURL)
                
                let attrs = try await client.stat(path)
                completionHandler(tempURL, RemoteItem(connectionId: connId, path: path, attributes: attrs), nil)
                
            } catch {
                NSLog("❌ [FP-EXT] fetchContents error: %@", error.localizedDescription)
                completionHandler(nil, nil, self.toFileProviderError(error))
            }
            progress.completedUnitCount = 100
        }
        
        return progress
    }
    
    func createItem(basedOn itemTemplate: NSFileProviderItem,
                    fields: NSFileProviderItemFields,
                    contents url: URL?,
                    options: NSFileProviderCreateItemOptions,
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        
        NSLog("📂 [FP-EXT] createItem: %@ in %@", itemTemplate.filename, itemTemplate.parentItemIdentifier.rawValue)
        
        let progress = Progress(totalUnitCount: 100)
        
        Task {
            do {
                let parentParsed = parseIdentifier(itemTemplate.parentItemIdentifier)
                guard let connId = parentParsed.connectionId else {
                    throw NSFileProviderError(.noSuchItem)
                }
                
                let client = try await ensureConnected(connectionId: connId)
                
                // Determine parent path
                let parentPath = parentParsed.remotePath ?? "/"
                let remotePath = (parentPath as NSString).appendingPathComponent(itemTemplate.filename)
                
                if itemTemplate.contentType == .folder {
                    try await client.mkdir(remotePath)
                } else if let localURL = url {
                    let data = try Data(contentsOf: localURL)
                    try await client.writeFile(remotePath, data: data) { current, total in
                        if total > 0 {
                            progress.completedUnitCount = Int64(Double(current) / Double(total) * 100)
                        }
                    }
                }
                
                let attrs = try await client.stat(remotePath)
                let newItem = RemoteItem(connectionId: connId, path: remotePath, attributes: attrs)
                
                // Signal parent to refresh
                if let manager = NSFileProviderManager(for: self.domain) {
                    try? await manager.signalEnumerator(for: itemTemplate.parentItemIdentifier)
                }
                
                completionHandler(newItem, [], false, nil)
                
            } catch {
                NSLog("❌ [FP-EXT] createItem error: %@", error.localizedDescription)
                completionHandler(nil, [], false, self.toFileProviderError(error))
            }
            progress.completedUnitCount = 100
        }
        
        return progress
    }
    
    func modifyItem(_ item: NSFileProviderItem,
                    baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields,
                    contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions,
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        
        NSLog("📂 [FP-EXT] modifyItem: %@", item.itemIdentifier.rawValue)
        
        let progress = Progress(totalUnitCount: 100)
        
        Task {
            do {
                let parsed = parseIdentifier(item.itemIdentifier)
                guard let connId = parsed.connectionId, var remotePath = parsed.remotePath else {
                    throw NSFileProviderError(.noSuchItem)
                }
                
                let client = try await ensureConnected(connectionId: connId)
                
                // Handle rename/move
                if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                    let parentParsed = parseIdentifier(item.parentItemIdentifier)
                    let newParentPath = parentParsed.remotePath ?? "/"
                    let newPath = (newParentPath as NSString).appendingPathComponent(item.filename)
                    
                    if newPath != remotePath {
                        try await client.rename(from: remotePath, to: newPath)
                        remotePath = newPath
                    }
                }
                
                // Handle content update
                if changedFields.contains(.contents), let localURL = newContents {
                    let data = try Data(contentsOf: localURL)
                    try await client.writeFile(remotePath, data: data) { current, total in
                        if total > 0 {
                            progress.completedUnitCount = Int64(Double(current) / Double(total) * 100)
                        }
                    }
                }
                
                let attrs = try await client.stat(remotePath)
                let modifiedItem = RemoteItem(connectionId: connId, path: remotePath, attributes: attrs)
                
                // Signal parent to refresh
                if let manager = NSFileProviderManager(for: self.domain) {
                    try? await manager.signalEnumerator(for: item.parentItemIdentifier)
                }
                
                completionHandler(modifiedItem, [], false, nil)
                
            } catch {
                NSLog("❌ [FP-EXT] modifyItem error: %@", error.localizedDescription)
                completionHandler(nil, [], false, self.toFileProviderError(error))
            }
            progress.completedUnitCount = 100
        }
        
        return progress
    }
    
    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions,
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        
        NSLog("📂 [FP-EXT] deleteItem: %@", identifier.rawValue)
        
        let progress = Progress(totalUnitCount: 1)
        
        Task {
            do {
                let parsed = parseIdentifier(identifier)
                guard let connId = parsed.connectionId, let path = parsed.remotePath else {
                    throw NSFileProviderError(.noSuchItem)
                }
                
                let client = try await ensureConnected(connectionId: connId)
                try await client.delete(path)
                
                // Invalidate cache and signal parent to refresh
                let parentParsed = self.parseIdentifier(identifier)
                let parentId: NSFileProviderItemIdentifier
                if let remotePath = parentParsed.remotePath {
                    let parentPath = (remotePath as NSString).deletingLastPathComponent
                    if parentPath == "/" || parentPath.isEmpty {
                        parentId = self.makeConnectionIdentifier(connId)
                    } else {
                        parentId = self.makeRemoteItemIdentifier(connectionId: connId, path: parentPath)
                    }
                } else {
                    parentId = .rootContainer
                }
                
                if let manager = NSFileProviderManager(for: self.domain) {
                    try? await manager.signalEnumerator(for: parentId)
                }
                
                completionHandler(nil)
                
            } catch {
                NSLog("❌ [FP-EXT] deleteItem error: %@", error.localizedDescription)
                completionHandler(self.toFileProviderError(error))
            }
            progress.completedUnitCount = 1
        }
        
        return progress
    }
    
    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        
        NSLog("📂 [FP-EXT] enumerator(for: %@)", containerItemIdentifier.rawValue)
        Self.debugLog("enumerator(for: \(containerItemIdentifier.rawValue))")
        
        let parsed = parseIdentifier(containerItemIdentifier)
        
        if containerItemIdentifier == .workingSet {
            // Working set - use MetadataStoreEnumerator for proper change tracking
            // Uses UInt64 monotonic anchor per FILE_PROVIDER_IMPLEMENTATION.md design
            Self.debugLog("Creating MetadataStoreEnumerator for working set")
            return MetadataStoreEnumerator()
        }
        
        if parsed.isRoot {
            // Root container - list connections
            Self.debugLog("Creating ConnectionsEnumerator for root")
            return ConnectionsEnumerator()
        }
        
        if let connId = parsed.connectionId {
            // Connection or subfolder - list remote items
            let path = parsed.remotePath ?? "/"
            Self.debugLog("Creating RemoteEnumerator for conn=\(connId) path=\(path)")
            return RemoteEnumerator(connectionId: connId, path: path, domain: domain)
        }
        
        throw NSFileProviderError(.noSuchItem)
    }
    
    // MARK: - Materialized Items Tracking
    
    /// Called by iOS when items are materialized or rendered dataless.
    /// We use this to track which items need to be in our working set.
    func materializedItemsDidChange(completionHandler: @escaping () -> Void) {
        NSLog("📂 [FP-EXT] materializedItemsDidChange called")
        Self.debugLog("materializedItemsDidChange: tracking materialized items")
        
        Task {
            do {
                guard let manager = manager else {
                    NSLog("❌ [FP-EXT] No manager available for materialized items")
                    completionHandler()
                    return
                }
                
                // Get enumerator for materialized items
                let enumerator = manager.enumeratorForMaterializedItems()
                
                // Create observer to collect items
                let observer = MaterializedItemsObserver { [weak self] items in
                    guard let self = self else { return }
                    
                    NSLog("📂 [FP-EXT] Tracking %d materialized items", items.count)
                    Self.debugLog("Tracking \(items.count) materialized items")
                    
                    // Register each materialized item's parent folder as active
                    Task {
                        for item in items {
                            let parsed = self.parseIdentifier(item.parentItemIdentifier)
                            if let connId = parsed.connectionId {
                                let path = parsed.remotePath ?? "/"
                                do {
                                    try await MetadataStore.shared.registerActiveFolder(
                                        connectionId: connId,
                                        remotePath: path
                                    )
                                } catch {
                                    Self.debugLog("Failed to register folder: \(error.localizedDescription)")
                                }
                            }
                        }
                    }
                }
                
                // Enumerate materialized items
                enumerator.enumerateItems(for: observer, startingAt: NSFileProviderPage.initialPageSortedByDate as NSFileProviderPage)
                
            } catch {
                NSLog("❌ [FP-EXT] materializedItemsDidChange error: %@", error.localizedDescription)
            }
            
            completionHandler()
        }
    }
    
    // MARK: - Connection Management
    
    private func ensureConnected(connectionId: String) async throws -> SFTPClient {
        // Use shared connection manager
        return try await SFTPConnectionManager.shared.getClient(for: connectionId)
    }
}

// MARK: - Item Types

/// Root container item
class RootItem: NSObject, NSFileProviderItem {
    var itemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var filename: String { "Geistty" }
    var contentType: UTType { .folder }
    var capabilities: NSFileProviderItemCapabilities { [.allowsReading, .allowsContentEnumerating] }
    
    // Required for NSFileProviderReplicatedExtension
    // Version based on connection count so it changes when connections are added/removed
    var itemVersion: NSFileProviderItemVersion {
        let connectionCount = FileProviderDomainManager.getConnections().count
        let versionData = "root-v\(connectionCount)".data(using: .utf8)!
        return NSFileProviderItemVersion(contentVersion: versionData, metadataVersion: versionData)
    }
    
    // Transfer status - root folder is always local
    var isDownloaded: Bool { true }
    var isUploaded: Bool { true }
    var isDownloading: Bool { false }
    var isUploading: Bool { false }
}

/// Connection folder item (appears in root)
class ConnectionFolderItem: NSObject, NSFileProviderItem {
    let connection: FileProviderDomainManager.FileProviderConnection
    
    init(connection: FileProviderDomainManager.FileProviderConnection) {
        self.connection = connection
    }
    
    var itemIdentifier: NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier("conn:\(connection.id)")
    }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var filename: String { connection.name }
    var contentType: UTType { .folder }
    var capabilities: NSFileProviderItemCapabilities {
        [.allowsReading, .allowsWriting, .allowsContentEnumerating, .allowsAddingSubItems, .allowsDeleting]
    }
    
    // Required for NSFileProviderReplicatedExtension
    var itemVersion: NSFileProviderItemVersion {
        // Use connection ID as version - static since connection config doesn't change
        NSFileProviderItemVersion(contentVersion: connection.id.data(using: .utf8)!, metadataVersion: "1".data(using: .utf8)!)
    }
    
    // Transfer status - connection folder is always local/available
    var isDownloaded: Bool { true }
    var isUploaded: Bool { true }
    var isDownloading: Bool { false }
    var isUploading: Bool { false }
}

/// Remote file/folder item
class RemoteItem: NSObject, NSFileProviderItem {
    let connectionId: String
    let path: String
    let attributes: SFTPFileAttributes
    
    init(connectionId: String, path: String, attributes: SFTPFileAttributes) {
        self.connectionId = connectionId
        self.path = path
        self.attributes = attributes
    }
    
    var itemIdentifier: NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier("conn:\(connectionId):path:\(path)")
    }
    
    var parentItemIdentifier: NSFileProviderItemIdentifier {
        let parent = (path as NSString).deletingLastPathComponent
        if parent == "/" || parent.isEmpty {
            return NSFileProviderItemIdentifier("conn:\(connectionId)")
        }
        return NSFileProviderItemIdentifier("conn:\(connectionId):path:\(parent)")
    }
    
    var filename: String {
        (path as NSString).lastPathComponent
    }
    
    var contentType: UTType {
        attributes.isDirectory ? .folder : UTType(filenameExtension: (path as NSString).pathExtension) ?? .data
    }
    
    var documentSize: NSNumber? {
        NSNumber(value: attributes.size)
    }
    
    var creationDate: Date? {
        attributes.modificationDate
    }
    
    var contentModificationDate: Date? {
        attributes.modificationDate
    }
    
    var capabilities: NSFileProviderItemCapabilities {
        if attributes.isDirectory {
            return [.allowsReading, .allowsWriting, .allowsContentEnumerating, .allowsAddingSubItems, .allowsDeleting, .allowsRenaming]
        } else {
            return [.allowsReading, .allowsWriting, .allowsDeleting, .allowsRenaming]
        }
    }
    
    // Required for NSFileProviderReplicatedExtension
    var itemVersion: NSFileProviderItemVersion {
        // Use modification time and size as version indicators
        let modTime = attributes.modificationDate?.timeIntervalSince1970 ?? 0
        let contentVer = "\(attributes.size):\(modTime)".data(using: .utf8)!
        let metaVer = "\(modTime)".data(using: .utf8)!
        return NSFileProviderItemVersion(contentVersion: contentVer, metadataVersion: metaVer)
    }
    
    // MARK: - Transfer Status
    
    /// Folders show as downloaded for browsing. Files are on remote (not cached locally).
    var isDownloaded: Bool {
        attributes.isDirectory
    }
    
    /// All remote items exist on server
    var isUploaded: Bool {
        true
    }
    
    /// No active downloads tracked here (happens via startProvidingItem)
    var isDownloading: Bool {
        false
    }
    
    /// No uploads from File Provider extension (read-only for remote)
    var isUploading: Bool {
        false
    }
}

// MARK: - Enumerators

// NOTE: Old WorkingSetEnumerator has been replaced by MetadataStoreEnumerator
// which uses SwiftData MetadataStore for proper change tracking.
// See Sources/FileProviderCore/MetadataStoreEnumerator.swift

/// Enumerates connections (root level)
/// Per Blink's pattern: folder enumerators return nil for currentSyncAnchor()
/// Change tracking is handled by MetadataStoreEnumerator
class ConnectionsEnumerator: NSObject, NSFileProviderEnumerator {
    
    func invalidate() {}
    
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        NSLog("📂 [FP-EXT] Enumerating connections...")
        Self.debugLog("Enumerating connections...")
        
        let connections = FileProviderDomainManager.getConnections()
        NSLog("📂 [FP-EXT] Found %d connections", connections.count)
        Self.debugLog("Found \(connections.count) connections")
        
        for conn in connections {
            NSLog("📂 [FP-EXT] - Connection: %@ (%@)", conn.name, conn.id)
            Self.debugLog("- Connection: \(conn.name) (\(conn.id))")
        }
        
        let items = connections.map { ConnectionFolderItem(connection: $0) }
        observer.didEnumerate(items)
        observer.finishEnumerating(upTo: nil)
        Self.debugLog("Enumeration complete")
    }
    
    /// Delegate to shared debug log utility
    private static func debugLog(_ message: String) {
        FileProviderDebugLog.write(message, category: "ConnectionsEnumerator")
    }
    
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        // Per Blink: folder enumerators just return the same anchor with no changes.
        // All change tracking is via MetadataStoreEnumerator.
        Self.debugLog("enumerateChanges: no changes at folder enumerator")
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }
    
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        // Per Blink's pattern: folder enumerators return nil.
        // Only MetadataStoreEnumerator returns a real anchor.
        // iOS will re-enumerate when needed.
        Self.debugLog("currentSyncAnchor: returning nil (folder enumerator)")
        completionHandler(nil)
    }
}

/// Enumerates remote files/folders - always fetches fresh data
/// Per Blink's pattern: folder enumerators return nil for currentSyncAnchor()
/// Change tracking is handled by MetadataStoreEnumerator
class RemoteEnumerator: NSObject, NSFileProviderEnumerator {
    let connectionId: String
    let path: String
    let domain: NSFileProviderDomain
    
    /// Item identifier for this folder
    private var itemIdentifier: NSFileProviderItemIdentifier {
        if path == "/" {
            return NSFileProviderItemIdentifier(CachedItem.connectionRootId(connectionId))
        }
        return NSFileProviderItemIdentifier(CachedItem.remoteItemId(connectionId: connectionId, path: path))
    }
    
    /// Parent item identifier for cache lookups
    private var parentId: String {
        if path == "/" {
            return CachedItem.connectionRootId(connectionId)
        }
        return CachedItem.remoteItemId(connectionId: connectionId, path: path)
    }
    
    init(connectionId: String, path: String, domain: NSFileProviderDomain) {
        self.connectionId = connectionId
        self.path = path
        self.domain = domain
    }
    
    func invalidate() {
        // Unregister from active folders when enumerator is invalidated
        Task {
            do {
                try await MetadataStore.shared.unregisterActiveFolder(connectionId: connectionId, remotePath: path)
            } catch {
                Self.debugLog("Failed to unregister active folder: \(error.localizedDescription)")
            }
        }
    }
    
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        NSLog("📂 [FP-EXT] Enumerating remote path: %@ for conn: %@", path, connectionId)
        Self.debugLog("enumerateItems START: path=\(path), parentId=\(parentId)")
        
        // Register this folder as active for change detection polling
        NSLog("📂 [FP-EXT] Registering active folder: %@ (conn: %@)", path, connectionId)
        Task {
            do {
                try await MetadataStore.shared.registerActiveFolder(connectionId: connectionId, remotePath: path)
                let count = try await MetadataStore.shared.activeFolderCount()
                NSLog("📂 [FP-EXT] After registration, active folder count: %d", count)
            } catch {
                Self.debugLog("Failed to register active folder: \(error.localizedDescription)")
            }
        }
        
        // STRATEGY: Always fetch fresh from server for best UX.
        // Cache is only used as fallback on network error.
        Task {
            do {
                // Try to fetch fresh data from server
                Self.debugLog("Fetching fresh from server...")
                try await refreshFromServer(observer: observer)
                Self.debugLog("enumerateItems COMPLETE (fresh data)")
            } catch {
                // Server fetch failed - try cache as fallback
                Self.debugLog("Server error: \(error.localizedDescription), trying cache...")
                
                do {
                    let cached = try await MetadataCache.shared.getChildren(parentId: parentId)
                    
                    if !cached.isEmpty {
                        Self.debugLog("Cache fallback: \(cached.count) items")
                        let items = cached.map { CachedRemoteItem(cachedItem: $0, connectionId: connectionId) }
                        observer.didEnumerate(items)
                        observer.finishEnumerating(upTo: nil)
                    } else {
                        // No cache either - report the original error
                        Self.debugLog("No cache available, reporting error")
                        observer.finishEnumeratingWithError(Self.toFileProviderError(error))
                    }
                } catch {
                    Self.debugLog("Cache error: \(error.localizedDescription)")
                    observer.finishEnumeratingWithError(Self.toFileProviderError(error))
                }
            }
        }
    }
    
    /// Convert errors to user-friendly NSFileProviderError
    private static func toFileProviderError(_ error: Error) -> Error {
        if error is NSFileProviderError {
            return error
        }
        
        let message = error.localizedDescription.lowercased()
        
        if message.contains("connection") || message.contains("network") || 
           message.contains("timeout") || message.contains("refused") {
            return NSFileProviderError(.serverUnreachable)
        }
        
        if message.contains("auth") || message.contains("permission denied") {
            return NSFileProviderError(.notAuthenticated)
        }
        
        if message.contains("no such file") || message.contains("not found") {
            return NSFileProviderError(.noSuchItem)
        }
        
        return NSFileProviderError(.serverUnreachable)
    }
    
    /// Refresh cache from server
    private func refreshFromServer(observer: NSFileProviderEnumerationObserver?) async throws {
        Self.debugLog("refreshFromServer START: hasObserver=\(observer != nil)")
        
        Self.debugLog("Getting SFTP client...")
        let client = try await SFTPConnectionManager.shared.getClient(for: connectionId)
        Self.debugLog("Got client, listing directory \(path)...")
        
        let entries = try await client.listDirectory(path)
        
        Self.debugLog("Server returned \(entries.count) items")
        NSLog("📂 [FP-EXT] Server returned %d items in %@", entries.count, path)
        
        // Convert to CachedItem and store
        let cachedItems = entries.compactMap { entry -> CachedItem? in
            guard entry.name != "." && entry.name != ".." else { return nil }
            let itemPath = (path as NSString).appendingPathComponent(entry.name)
            let itemId = CachedItem.remoteItemId(connectionId: connectionId, path: itemPath)
            
            return CachedItem(
                id: itemId,
                connectionId: connectionId,
                path: itemPath,
                parentId: parentId,
                name: entry.name,
                size: Int64(entry.size),
                isDirectory: entry.isDirectory,
                permissions: Int32(entry.permissions),
                modificationDate: entry.modificationDate,
                isSymlink: entry.isSymlink
            )
        }
        
        Self.debugLog("Created \(cachedItems.count) cached items")
        
        // Update cache
        try await MetadataCache.shared.upsertBatch(cachedItems, parentId: parentId)
        Self.debugLog("MetadataCache updated")
        
        // Also update MetadataStore for working set change tracking
        let metadataItems = cachedItems.map { item in
            (id: item.id, connId: item.connectionId, path: item.path, parentId: item.parentId,
             name: item.name, size: item.size, isDir: item.isDirectory, perms: item.permissions,
             modDate: item.modificationDate, isSymlink: item.isSymlink)
        }
        let hasChanges = try await MetadataStore.shared.upsertBatch(items: metadataItems, parentId: parentId)
        Self.debugLog("MetadataStore updated - hasChanges=\(hasChanges)")
        
        // Signal working set ONLY if there were actual changes
        if hasChanges, let manager = NSFileProviderManager(for: domain) {
            Self.debugLog("Signaling working set for new changes")
            try? await manager.signalEnumerator(for: .workingSet)
        }
        
        // NOTE: Do NOT call recordChanges() here! 
        // Change detection happens in pollActiveFolders() which compares server state to cache.
        // Calling recordChanges() on every enumeration would flood the change system and
        // cause "Syncing Paused" because the anchor keeps incrementing.
        
        // If we have an observer (cache miss case), return results now
        if let observer = observer {
            Self.debugLog("Reporting \(cachedItems.count) items to observer")
            let items = cachedItems.map { CachedRemoteItem(cachedItem: $0, connectionId: connectionId) }
            observer.didEnumerate(items)
            observer.finishEnumerating(upTo: nil)
            Self.debugLog("Observer finished")
        } else {
            // Signal that cache was updated (system will re-enumerate)
            if let manager = NSFileProviderManager(for: domain) {
                Self.debugLog("Signaling enumerator for \(parentId)")
                try? await manager.signalEnumerator(for: NSFileProviderItemIdentifier(parentId))
            }
        }
        
        Self.debugLog("refreshFromServer COMPLETE")
    }
    
    /// Delegate to shared debug log utility
    private static func debugLog(_ message: String) {
        FileProviderDebugLog.write(message, category: "RemoteEnumerator")
    }
    
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        // For remote folders, MetadataStoreEnumerator handles change tracking.
        // Don't return syncAnchorExpired - that breaks iOS's sync state machine.
        // Instead, return no changes; iOS will call enumerateItems when user navigates.
        NSLog("📂 [FP-EXT] RemoteEnumerator.enumerateChanges - no changes to report")
        Self.debugLog("enumerateChanges: returning no changes (change tracking via MetadataStoreEnumerator)")
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }
    
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        // Per Blink's pattern: folder enumerators return nil.
        // Only MetadataStoreEnumerator returns a real anchor for change tracking.
        // iOS will call enumerateItems when the user navigates to this folder.
        NSLog("📂 [FP-EXT] RemoteEnumerator.currentSyncAnchor: returning nil (folder enumerator)")
        Self.debugLog("currentSyncAnchor: returning nil (folder enumerator)")
        completionHandler(nil)
    }
}

// MARK: - CachedRemoteItem

/// NSFileProviderItem backed by CachedItem from SwiftData
class CachedRemoteItem: NSObject, NSFileProviderItem {
    let cachedItem: CachedItem
    let connectionId: String
    
    init(cachedItem: CachedItem, connectionId: String) {
        self.cachedItem = cachedItem
        self.connectionId = connectionId
    }
    
    var itemIdentifier: NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(cachedItem.id)
    }
    
    var parentItemIdentifier: NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(cachedItem.parentId)
    }
    
    var filename: String {
        cachedItem.name
    }
    
    var contentType: UTType {
        cachedItem.isDirectory ? .folder : UTType(filenameExtension: (cachedItem.name as NSString).pathExtension) ?? .data
    }
    
    var documentSize: NSNumber? {
        NSNumber(value: cachedItem.size)
    }
    
    var creationDate: Date? {
        cachedItem.modificationDate
    }
    
    var contentModificationDate: Date? {
        cachedItem.modificationDate
    }
    
    var capabilities: NSFileProviderItemCapabilities {
        if cachedItem.isDirectory {
            return [.allowsReading, .allowsWriting, .allowsContentEnumerating, .allowsAddingSubItems, .allowsDeleting, .allowsRenaming]
        } else {
            return [.allowsReading, .allowsWriting, .allowsDeleting, .allowsRenaming]
        }
    }
    
    var itemVersion: NSFileProviderItemVersion {
        let modTime = cachedItem.modificationDate?.timeIntervalSince1970 ?? 0
        let contentVer = "\(cachedItem.size):\(modTime)".data(using: .utf8)!
        let metaVer = "\(modTime)".data(using: .utf8)!
        return NSFileProviderItemVersion(contentVersion: contentVer, metadataVersion: metaVer)
    }
    
    // MARK: - Transfer Status
    
    /// Folders show as downloaded for browsing. Files are streamed on demand.
    var isDownloaded: Bool {
        cachedItem.isDirectory
    }
    
    /// All cached items exist on server (this is cached server state)
    var isUploaded: Bool {
        true
    }
    
    /// No active downloads tracked here
    var isDownloading: Bool {
        false
    }
    
    /// No uploads (read-only cached state)
    var isUploading: Bool {
        false
    }
}

// MARK: - Materialized Items Observer

/// Observer for collecting materialized items from the system enumerator.
/// Used by materializedItemsDidChange() to track which items iOS has materialized.
private class MaterializedItemsObserver: NSObject, NSFileProviderEnumerationObserver {
    private var items: [NSFileProviderItem] = []
    private let completion: ([NSFileProviderItem]) -> Void
    
    init(completion: @escaping ([NSFileProviderItem]) -> Void) {
        self.completion = completion
    }
    
    func didEnumerate(_ updatedItems: [any NSFileProviderItemProtocol]) {
        items.append(contentsOf: updatedItems.compactMap { $0 as? NSFileProviderItem })
    }
    
    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        completion(items)
    }
    
    func finishEnumeratingWithError(_ error: any Error) {
        NSLog("❌ [MaterializedItemsObserver] Error: %@", error.localizedDescription)
        completion(items)
    }
}
