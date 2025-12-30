//
//  FileProviderExtension.swift
//  GeisttyFileProvider
//
//  NSFileProviderReplicatedExtension implementation for SFTP access via Files.app
//
//  Architecture (Shellfish-style):
//  - ONE "Geistty" domain in Files.app sidebar
//  - Root shows connections with Files integration enabled as folders
//  - Each connection folder shows remote files via SFTP
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
            try await client.connect(host: conn.host, username: conn.username)
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
    
    // MARK: - Initialization
    
    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        NSLog("📂 [FP-EXT] FileProviderExtension init for domain: %@", domain.identifier.rawValue)
        
        // Debug: Write to shared container
        Self.debugLog("Extension init for domain: \(domain.identifier.rawValue)")
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
        // Disconnect all clients via shared manager
        Task {
            await SFTPConnectionManager.shared.disconnectAll()
        }
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
                completionHandler(nil, error)
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
                completionHandler(nil, nil, error)
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
                completionHandler(RemoteItem(connectionId: connId, path: remotePath, attributes: attrs), [], false, nil)
                
            } catch {
                NSLog("❌ [FP-EXT] createItem error: %@", error.localizedDescription)
                completionHandler(nil, [], false, error)
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
                completionHandler(RemoteItem(connectionId: connId, path: remotePath, attributes: attrs), [], false, nil)
                
            } catch {
                NSLog("❌ [FP-EXT] modifyItem error: %@", error.localizedDescription)
                completionHandler(nil, [], false, error)
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
                completionHandler(nil)
                
            } catch {
                NSLog("❌ [FP-EXT] deleteItem error: %@", error.localizedDescription)
                completionHandler(error)
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
            // Working set - return all connections
            return ConnectionsEnumerator()
        }
        
        if parsed.isRoot {
            // Root container - list connections
            return ConnectionsEnumerator()
        }
        
        if let connId = parsed.connectionId {
            // Connection or subfolder - list remote items
            let path = parsed.remotePath ?? "/"
            return RemoteEnumerator(connectionId: connId, path: path)
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
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }
    
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data()))
    }
}

/// Enumerates remote files/folders
class RemoteEnumerator: NSObject, NSFileProviderEnumerator {
    let connectionId: String
    let path: String
    
    init(connectionId: String, path: String) {
        self.connectionId = connectionId
        self.path = path
    }
    
    func invalidate() {}
    
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        NSLog("📂 [FP-EXT] Enumerating remote path: %@ for conn: %@", path, connectionId)
        
        Task {
            do {
                // Use shared connection manager for efficient connection reuse
                let client = try await SFTPConnectionManager.shared.getClient(for: connectionId)
                
                let entries = try await client.listDirectory(path)
                NSLog("📂 [FP-EXT] Found %d items in %@", entries.count, path)
                
                let items = entries.compactMap { entry -> RemoteItem? in
                    guard entry.name != "." && entry.name != ".." else { return nil }
                    let itemPath = (path as NSString).appendingPathComponent(entry.name)
                    return RemoteItem(connectionId: connectionId, path: itemPath, attributes: entry)
                }
                
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
                
            } catch {
                NSLog("❌ [FP-EXT] Enumerate error: %@", error.localizedDescription)
                observer.finishEnumeratingWithError(error)
            }
        }
    }
    
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }
    
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data()))
    }
}
