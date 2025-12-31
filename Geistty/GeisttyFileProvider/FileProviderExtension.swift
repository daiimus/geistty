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
    
    /// Write debug log to shared container
    private static func debugLog(_ message: String) {
        let groupId = FileProviderDomainManager.appGroupIdentifier
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupId) else {
            return
        }
        
        let logFile = containerURL.appendingPathComponent("fileprovider_debug.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(timestamp)] SFTPConnectionManager: \(message)\n"
        
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
}

/// Main File Provider extension class
class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    
    // MARK: - Properties
    
    let domain: NSFileProviderDomain
    
    /// Manager for this domain
    private lazy var manager: NSFileProviderManager? = {
        NSFileProviderManager(for: domain)
    }()
    
    /// Working set for change detection and sync anchors
    private lazy var workingSet: WorkingSet = {
        WorkingSet(domain: domain)
    }()
    
    /// Background polling task for change detection
    private var pollingTask: Task<Void, Never>?
    
    /// Polling interval in seconds
    private let pollingInterval: TimeInterval = 5
    
    // MARK: - Initialization
    
    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        NSLog("📂 [FP-EXT] FileProviderExtension init for domain: %@", domain.identifier.rawValue)
        
        // Debug: Write to shared container
        Self.debugLog("Extension init for domain: \(domain.identifier.rawValue)")
        
        // Start background polling for change detection
        startPolling()
    }
    
    /// Write debug info to shared container for debugging
    private static func debugLog(_ message: String) {
        let groupId = FileProviderDomainManager.appGroupIdentifier
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupId) else {
            NSLog("❌ [FP-EXT] Cannot access shared container")
            return
        }
        
        let logFile = containerURL.appendingPathComponent("fileprovider_debug.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(timestamp)] \(message)\n"
        
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
    
    func invalidate() {
        NSLog("📂 [FP-EXT] Invalidating extension")
        // Stop polling and invalidate working set
        pollingTask?.cancel()
        pollingTask = nil
        Task {
            await workingSet.invalidate()
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
    private func pollActiveFolders() async {
        let folders = await workingSet.activeFolders
        NSLog("🔄 [FP-EXT] pollActiveFolders: %d active folders", folders.count)
        guard !folders.isEmpty else { 
            NSLog("🔄 [FP-EXT] No active folders, skipping poll")
            return 
        }
        
        Self.debugLog("Polling \(folders.count) active folders for changes...")
        NSLog("🔄 [FP-EXT] Polling folders: %@", folders.map { $0.path }.joined(separator: ", "))
        
        var allChanges = DetectedChanges()
        
        for folder in folders {
            do {
                let changes = try await detectChangesInFolder(folder)
                allChanges.merge(changes)
            } catch {
                Self.debugLog("Error polling \(folder.path): \(error.localizedDescription)")
            }
        }
        
        // Record any changes we found
        if !allChanges.isEmpty {
            Self.debugLog("Detected \(allChanges.count) changes total")
            await workingSet.recordChanges(allChanges)
        }
    }
    
    /// Detect changes in a single folder by comparing server state to cache
    private func detectChangesInFolder(_ folder: ActiveFolder) async throws -> DetectedChanges {
        var changes = DetectedChanges()
        
        // Get SFTP client for this connection
        let client = try await SFTPConnectionManager.shared.getClient(for: folder.connectionId)
        
        // Get current server state
        let serverEntries = try await client.listDirectory(folder.path)
        let serverByName = Dictionary(uniqueKeysWithValues: serverEntries.map { ($0.name, $0) })
        
        // Get cached state
        let parentId = folder.path == "/" 
            ? CachedItem.connectionRootId(folder.connectionId)
            : CachedItem.remoteItemId(connectionId: folder.connectionId, path: folder.path)
        let cachedItems = try await MetadataCache.shared.getChildren(parentId: parentId)
        let cachedByName = Dictionary(uniqueKeysWithValues: cachedItems.map { ($0.name, $0) })
        
        // Check for new or modified items
        for (name, entry) in serverByName {
            // Skip . and ..
            guard name != "." && name != ".." else { continue }
            
            let itemPath = folder.path == "/" ? "/\(name)" : "\(folder.path)/\(name)"
            let itemId = CachedItem.remoteItemId(connectionId: folder.connectionId, path: itemPath)
            let identifier = NSFileProviderItemIdentifier(itemId)
            
            if let cached = cachedByName[name] {
                // Check if modified (size or mtime changed)
                let serverMtime = entry.modificationDate ?? Date.distantPast
                let cachedMtime = cached.modificationDate ?? Date.distantPast
                
                if Int64(entry.size) != cached.size ||
                   abs(serverMtime.timeIntervalSince(cachedMtime)) > 1 {
                    Self.debugLog("Update detected: \(name)")
                    changes.updates.append(identifier)
                    
                    // Update cache
                    let newCached = CachedItem(
                        id: itemId,
                        connectionId: folder.connectionId,
                        path: itemPath,
                        parentId: parentId,
                        name: name,
                        size: Int64(entry.size),
                        isDirectory: entry.isDirectory,
                        modificationDate: entry.modificationDate
                    )
                    try await MetadataCache.shared.upsert(newCached)
                }
            } else {
                // New item
                Self.debugLog("Create detected: \(name)")
                changes.creates.append(identifier)
                
                // Add to cache
                let newCached = CachedItem(
                    id: itemId,
                    connectionId: folder.connectionId,
                    path: itemPath,
                    parentId: parentId,
                    name: name,
                    size: Int64(entry.size),
                    isDirectory: entry.isDirectory,
                    modificationDate: entry.modificationDate
                )
                try await MetadataCache.shared.upsert(newCached)
            }
        }
        
        // Check for deleted items
        for (name, cached) in cachedByName {
            if serverByName[name] == nil {
                Self.debugLog("Deletion detected: \(name)")
                changes.deletions.append(NSFileProviderItemIdentifier(cached.id))
                
                // Remove from cache
                try await MetadataCache.shared.delete(id: cached.id)
            }
        }
        
        return changes
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
                    // Remote item - need to stat
                    let client = try await ensureConnected(connectionId: connId)
                    let attrs = try await client.stat(path)
                    completionHandler(RemoteItem(connectionId: connId, path: path, attributes: attrs), nil)
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
        
        let parsed = parseIdentifier(containerItemIdentifier)
        
        if containerItemIdentifier == .workingSet {
            // Working set - use proper WorkingSetEnumerator with change tracking
            return WorkingSetEnumerator(workingSet: workingSet)
        }
        
        if parsed.isRoot {
            // Root container - list connections
            return ConnectionsEnumerator()
        }
        
        if let connId = parsed.connectionId {
            // Connection or subfolder - list remote items
            let path = parsed.remotePath ?? "/"
            return RemoteEnumerator(connectionId: connId, path: path, domain: domain, workingSet: workingSet)
        }
        
        throw NSFileProviderError(.noSuchItem)
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
    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: "1".data(using: .utf8)!, metadataVersion: "1".data(using: .utf8)!)
    }
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
}

// MARK: - Enumerators

/// Enumerates the working set with proper change detection.
/// This is what iOS calls to detect changes to files/folders.
class WorkingSetEnumerator: NSObject, NSFileProviderEnumerator {
    let workingSet: WorkingSet
    
    init(workingSet: WorkingSet) {
        self.workingSet = workingSet
    }
    
    func invalidate() {
        // Nothing to clean up
    }
    
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        Self.debugLog("enumerateItems called for working set")
        
        // Working set enumeration returns all items we're tracking.
        // For now, return empty - we handle changes via enumerateChanges.
        // In a full implementation, we'd return all cached items.
        Task {
            do {
                // Return all cached items as the working set
                let items = try await MetadataCache.shared.getAllItems()
                Self.debugLog("Returning \(items.count) items in working set")
                
                // Group by connection to get connectionId
                for item in items {
                    // Extract connectionId from the item id
                    if let connectionId = Self.extractConnectionId(from: item.id) {
                        let remoteItem = CachedRemoteItem(cachedItem: item, connectionId: connectionId)
                        observer.didEnumerate([remoteItem])
                    }
                }
                
                observer.finishEnumerating(upTo: nil)
            } catch {
                Self.debugLog("Failed to enumerate working set: \(error.localizedDescription)")
                observer.finishEnumerating(upTo: nil)
            }
        }
    }
    
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        Self.debugLog("enumerateChanges called from anchor: \(String(data: anchor.rawValue, encoding: .utf8) ?? "invalid")")
        
        Task {
            let (changes, newAnchor, expired) = await workingSet.getChanges(since: anchor)
            
            if expired {
                Self.debugLog("Anchor expired - telling iOS to re-enumerate")
                observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
                return
            }
            
            if changes.isEmpty {
                Self.debugLog("No changes to report")
                observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)
                return
            }
            
            Self.debugLog("Reporting \(changes.count) changes")
            
            // Report deletions
            if !changes.deletions.isEmpty {
                Self.debugLog("Reporting \(changes.deletions.count) deletions")
                observer.didDeleteItems(withIdentifiers: changes.deletions)
            }
            
            // Report creates and updates by fetching the items from cache
            let itemIds = changes.creates + changes.updates
            if !itemIds.isEmpty {
                Self.debugLog("Fetching \(itemIds.count) items for creates/updates")
                do {
                    for itemId in itemIds {
                        if let cachedItem = try await MetadataCache.shared.getItem(id: itemId.rawValue),
                           let connectionId = Self.extractConnectionId(from: cachedItem.id) {
                            let remoteItem = CachedRemoteItem(cachedItem: cachedItem, connectionId: connectionId)
                            observer.didUpdate([remoteItem])
                        }
                    }
                } catch {
                    Self.debugLog("Failed to fetch items: \(error.localizedDescription)")
                }
            }
            
            observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)
        }
    }
    
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        Task {
            let anchor = await workingSet.currentAnchor
            Self.debugLog("currentSyncAnchor: returning \(String(data: anchor.rawValue, encoding: .utf8) ?? "invalid")")
            completionHandler(anchor)
        }
    }
    
    // MARK: - Helpers
    
    /// Extract connectionId from item ID format: "sftp:connection-id:path"
    private static func extractConnectionId(from itemId: String) -> String? {
        let parts = itemId.components(separatedBy: ":")
        guard parts.count >= 2, parts[0] == "sftp" else { return nil }
        return parts[1]
    }
    
    private static func debugLog(_ message: String) {
        NSLog("🔄 [WS-ENUM] %@", message)
    }
}

/// Enumerates connections (root level)
class ConnectionsEnumerator: NSObject, NSFileProviderEnumerator {
    func invalidate() {}
    
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        NSLog("📂 [FP-EXT] Enumerating connections...")
        Self.debugLog("Enumerating connections...")
        
        // Debug: Check shared defaults access
        let groupId = FileProviderDomainManager.appGroupIdentifier
        NSLog("📂 [FP-EXT] App Group: %@", groupId)
        
        if let defaults = UserDefaults(suiteName: groupId) {
            NSLog("📂 [FP-EXT] Shared UserDefaults accessible")
            let keys = defaults.dictionaryRepresentation().keys
            NSLog("📂 [FP-EXT] Shared defaults keys: %@", keys.joined(separator: ", "))
            Self.debugLog("UserDefaults keys: \(keys.joined(separator: ", "))")
        } else {
            NSLog("❌ [FP-EXT] Cannot access shared UserDefaults!")
            Self.debugLog("ERROR: Cannot access shared UserDefaults!")
        }
        
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
    
    /// Write debug info to shared container
    private static func debugLog(_ message: String) {
        let groupId = FileProviderDomainManager.appGroupIdentifier
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupId) else { return }
        
        let logFile = containerURL.appendingPathComponent("fileprovider_debug.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(timestamp)] ConnectionsEnumerator: \(message)\n"
        
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
    
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        // For connections list, we don't track incremental changes.
        // Just report no changes - iOS will re-enumerate when needed.
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }
    
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        // Return nil to force fresh enumeration on each visit.
        // Connection list can change when user adds/removes connections.
        completionHandler(nil)
    }
}

/// Enumerates remote files/folders - always fetches fresh data
class RemoteEnumerator: NSObject, NSFileProviderEnumerator {
    let connectionId: String
    let path: String
    let domain: NSFileProviderDomain
    let workingSet: WorkingSet
    
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
    
    init(connectionId: String, path: String, domain: NSFileProviderDomain, workingSet: WorkingSet) {
        self.connectionId = connectionId
        self.path = path
        self.domain = domain
        self.workingSet = workingSet
    }
    
    func invalidate() {
        // Unregister from active folders when enumerator is invalidated
        Task {
            await workingSet.unregisterActiveFolder(connectionId: connectionId, path: path)
        }
    }
    
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        NSLog("📂 [FP-EXT] Enumerating remote path: %@ for conn: %@", path, connectionId)
        Self.debugLog("enumerateItems START: path=\(path), parentId=\(parentId)")
        
        // Register this folder as active for change detection polling
        NSLog("📂 [FP-EXT] Registering active folder: %@ (conn: %@)", path, connectionId)
        Task {
            await workingSet.registerActiveFolder(connectionId: connectionId, path: path, identifier: itemIdentifier)
            let count = await workingSet.activeFolders.count
            NSLog("📂 [FP-EXT] After registration, active folder count: %d", count)
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
        Self.debugLog("Cache updated")
        
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
    
    private static func debugLog(_ message: String) {
        let groupId = FileProviderDomainManager.appGroupIdentifier
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupId) else { return }
        
        let logFile = containerURL.appendingPathComponent("fileprovider_debug.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(timestamp)] RemoteEnumerator: \(message)\n"
        
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
    
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        // For remote folders, we always want fresh data.
        // Return syncAnchorExpired to force iOS to call enumerateItems() again.
        NSLog("📂 [FP-EXT] RemoteEnumerator.enumerateChanges - returning syncAnchorExpired")
        Self.debugLog("enumerateChanges: returning syncAnchorExpired to force re-enumeration")
        observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
    }
    
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        // Return a unique timestamp anchor each time.
        // This tells iOS our state has changed, which triggers enumerateChanges().
        // Since enumerateChanges returns syncAnchorExpired, iOS will call enumerateItems().
        let timestamp = Date().timeIntervalSince1970
        let anchorData = "remote-\(timestamp)".data(using: .utf8)!
        let anchor = NSFileProviderSyncAnchor(anchorData)
        NSLog("📂 [FP-EXT] RemoteEnumerator.currentSyncAnchor: %f", timestamp)
        Self.debugLog("currentSyncAnchor: returning timestamp \(timestamp)")
        completionHandler(anchor)
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
}
