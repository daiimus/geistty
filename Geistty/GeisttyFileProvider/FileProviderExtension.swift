//
//  FileProviderExtension.swift
//  GeisttyFileProvider
//
//  NSFileProviderReplicatedExtension implementation for SFTP access via Files.app
//
//  Architecture:
//  - One domain per saved SSH connection (server appears in Files sidebar)
//  - Domain identifier format: "sftp-<connection-uuid>"
//  - Credentials shared via App Group keychain
//  - Uses SFTPClient for all remote operations
//

import FileProvider
import os.log

private let logger = Logger(subsystem: "com.geistty.fileprovider", category: "Extension")

/// Main File Provider extension class
/// Implements NSFileProviderReplicatedExtension for SFTP remote file access
class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    
    // MARK: - Properties
    
    /// The domain this extension instance manages (one per SSH connection)
    let domain: NSFileProviderDomain
    
    /// SFTP client for remote operations
    private var sftpClient: SFTPClient?
    
    /// Connection info extracted from domain
    private var connectionInfo: ConnectionInfo?
    
    /// File manager for working with local files
    private let fileManager = FileManager.default
    
    /// Manager for this domain
    private lazy var manager: NSFileProviderManager? = {
        NSFileProviderManager(for: domain)
    }()
    
    // MARK: - Initialization
    
    /// Creates a file provider for the specified domain
    /// Each domain represents one SSH connection/server
    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        
        logger.info("📂 FileProviderExtension init for domain: \(domain.identifier.rawValue)")
        
        // Parse connection info from domain identifier
        // Format: "sftp-<host>-<port>-<username>"
        self.connectionInfo = ConnectionInfo(domainIdentifier: domain.identifier.rawValue)
        
        if let info = connectionInfo {
            logger.info("📂 Connection: \(info.username)@\(info.host):\(info.port)")
        }
    }
    
    /// Cleanup before deallocation
    func invalidate() {
        logger.info("📂 FileProviderExtension invalidate for domain: \(domain.identifier.rawValue)")
        
        // Disconnect SFTP if connected
        Task {
            await sftpClient?.disconnect()
            sftpClient = nil
        }
    }
    
    // MARK: - NSFileProviderReplicatedExtension Required Methods
    
    /// Returns metadata for a single item
    func item(for identifier: NSFileProviderItemIdentifier,
              request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        
        logger.debug("📂 item(for: \(identifier.rawValue))")
        
        let progress = Progress(totalUnitCount: 1)
        
        Task {
            do {
                let client = try await ensureConnected()
                
                // Handle root container specially
                if identifier == .rootContainer {
                    let item = FileProviderItem.rootContainer(domain: domain)
                    completionHandler(item, nil)
                    progress.completedUnitCount = 1
                    return
                }
                
                // For other items, identifier is the remote path
                let remotePath = pathFromIdentifier(identifier)
                let attrs = try await client.stat(remotePath)
                let item = FileProviderItem(attributes: attrs, path: remotePath, parentPath: parentPath(of: remotePath))
                
                completionHandler(item, nil)
            } catch {
                logger.error("📂 item(for:) error: \(error.localizedDescription)")
                completionHandler(nil, error)
            }
            progress.completedUnitCount = 1
        }
        
        return progress
    }
    
    /// Downloads the contents of a file
    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        
        logger.info("📂 fetchContents(for: \(itemIdentifier.rawValue))")
        
        let progress = Progress(totalUnitCount: 100)
        
        Task {
            do {
                let client = try await ensureConnected()
                let remotePath = pathFromIdentifier(itemIdentifier)
                
                // Create temporary file for download
                let tempURL = fileManager.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathComponent((remotePath as NSString).lastPathComponent)
                
                try fileManager.createDirectory(at: tempURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                
                // Download file
                let data = try await client.readFile(remotePath) { current, total in
                    if total > 0 {
                        progress.completedUnitCount = Int64(Double(current) / Double(total) * 100)
                    }
                }
                
                try data.write(to: tempURL)
                
                // Get updated metadata
                let attrs = try await client.stat(remotePath)
                let item = FileProviderItem(attributes: attrs, path: remotePath, parentPath: parentPath(of: remotePath))
                
                logger.info("📂 Downloaded \(data.count) bytes to \(tempURL.path)")
                completionHandler(tempURL, item, nil)
                
            } catch {
                logger.error("📂 fetchContents error: \(error.localizedDescription)")
                completionHandler(nil, nil, error)
            }
            progress.completedUnitCount = 100
        }
        
        return progress
    }
    
    /// Creates a new item (file or directory) on the remote server
    func createItem(basedOn itemTemplate: NSFileProviderItem,
                    fields: NSFileProviderItemFields,
                    contents url: URL?,
                    options: NSFileProviderCreateItemOptions,
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        
        logger.info("📂 createItem: \(itemTemplate.filename) in \(itemTemplate.parentItemIdentifier.rawValue)")
        
        let progress = Progress(totalUnitCount: 100)
        
        Task {
            do {
                let client = try await ensureConnected()
                let parentPath = pathFromIdentifier(itemTemplate.parentItemIdentifier)
                let remotePath = (parentPath as NSString).appendingPathComponent(itemTemplate.filename)
                
                if itemTemplate.contentType == .folder {
                    // Create directory
                    try await client.mkdir(remotePath)
                    logger.info("📂 Created directory: \(remotePath)")
                } else if let localURL = url {
                    // Upload file
                    let data = try Data(contentsOf: localURL)
                    try await client.writeFile(remotePath, data: data) { current, total in
                        if total > 0 {
                            progress.completedUnitCount = Int64(Double(current) / Double(total) * 100)
                        }
                    }
                    logger.info("📂 Uploaded file: \(remotePath) (\(data.count) bytes)")
                }
                
                // Get the created item's metadata
                let attrs = try await client.stat(remotePath)
                let item = FileProviderItem(attributes: attrs, path: remotePath, parentPath: parentPath)
                
                completionHandler(item, [], false, nil)
                
            } catch {
                logger.error("📂 createItem error: \(error.localizedDescription)")
                completionHandler(nil, [], false, error)
            }
            progress.completedUnitCount = 100
        }
        
        return progress
    }
    
    /// Modifies an existing item (rename, move, update contents)
    func modifyItem(_ item: NSFileProviderItem,
                    baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields,
                    contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions,
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        
        logger.info("📂 modifyItem: \(item.itemIdentifier.rawValue), fields: \(changedFields)")
        
        let progress = Progress(totalUnitCount: 100)
        
        Task {
            do {
                let client = try await ensureConnected()
                var remotePath = pathFromIdentifier(item.itemIdentifier)
                
                // Handle rename/move
                if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                    let newParentPath = pathFromIdentifier(item.parentItemIdentifier)
                    let newPath = (newParentPath as NSString).appendingPathComponent(item.filename)
                    
                    if newPath != remotePath {
                        try await client.rename(from: remotePath, to: newPath)
                        logger.info("📂 Renamed: \(remotePath) → \(newPath)")
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
                    logger.info("📂 Updated contents: \(remotePath) (\(data.count) bytes)")
                }
                
                // Get updated metadata
                let attrs = try await client.stat(remotePath)
                let resultItem = FileProviderItem(attributes: attrs, path: remotePath, parentPath: parentPath(of: remotePath))
                
                completionHandler(resultItem, [], false, nil)
                
            } catch {
                logger.error("📂 modifyItem error: \(error.localizedDescription)")
                completionHandler(nil, [], false, error)
            }
            progress.completedUnitCount = 100
        }
        
        return progress
    }
    
    /// Deletes an item from the remote server
    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions,
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        
        logger.info("📂 deleteItem: \(identifier.rawValue)")
        
        let progress = Progress(totalUnitCount: 1)
        
        Task {
            do {
                let client = try await ensureConnected()
                let remotePath = pathFromIdentifier(identifier)
                
                // delete() handles both files and directories (recursive)
                try await client.delete(remotePath)
                logger.info("📂 Deleted: \(remotePath)")
                
                completionHandler(nil)
            } catch {
                logger.error("📂 deleteItem error: \(error.localizedDescription)")
                completionHandler(error)
            }
            progress.completedUnitCount = 1
        }
        
        return progress
    }
    
    // MARK: - NSFileProviderEnumerating
    
    /// Returns an enumerator for the specified container
    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        
        logger.info("📂 enumerator(for: \(containerItemIdentifier.rawValue))")
        
        // Working set enumerator - return items that should sync
        if containerItemIdentifier == .workingSet {
            return FileProviderEnumerator(
                path: "/",
                domain: domain,
                connectionInfo: connectionInfo,
                isWorkingSet: true
            )
        }
        
        // Root or directory enumerator
        let path: String
        if containerItemIdentifier == .rootContainer {
            path = "/"
        } else {
            path = pathFromIdentifier(containerItemIdentifier)
        }
        
        return FileProviderEnumerator(
            path: path,
            domain: domain,
            connectionInfo: connectionInfo,
            isWorkingSet: false
        )
    }
    
    // MARK: - Connection Management
    
    /// Ensures we have an active SFTP connection, connecting if necessary
    private func ensureConnected() async throws -> SFTPClient {
        if let client = sftpClient, await client.isConnected {
            return client
        }
        
        guard let info = connectionInfo else {
            throw NSFileProviderError(.serverUnreachable)
        }
        
        logger.info("📂 Connecting to \(info.host):\(info.port)...")
        
        // Get credentials from shared App Group keychain
        let password = Self.getSharedPassword(for: info.host, username: info.username)
        
        // TODO: Look up SSH key name from saved profile, for now try common names
        let sshKey = Self.getSharedSSHKey(named: "id_ed25519") 
            ?? Self.getSharedSSHKey(named: "id_rsa")
        
        guard password != nil || sshKey != nil else {
            logger.error("📂 No credentials found for \(info.username)@\(info.host)")
            throw NSFileProviderError(.notAuthenticated)
        }
        
        // Create SSH connection and SFTP client
        // TODO: Full NIOSSHConnection integration
        // For now, we'll need to establish the connection here
        
        let client = SFTPClient()
        
        // Connect via NIOSSHConnection
        // This requires the SSH connection code to be available in the extension
        // try await client.connect(
        //     host: info.host,
        //     port: info.port,
        //     username: info.username,
        //     password: password,
        //     privateKey: sshKey
        // )
        
        // Store for reuse
        self.sftpClient = client
        
        return client
    }
    
    // MARK: - Path Utilities
    
    /// Converts a file provider item identifier to a remote path
    private func pathFromIdentifier(_ identifier: NSFileProviderItemIdentifier) -> String {
        if identifier == .rootContainer {
            return "/"
        }
        // Item identifiers are base64-encoded paths
        if let data = Data(base64Encoded: identifier.rawValue),
           let path = String(data: data, encoding: .utf8) {
            return path
        }
        // Fallback: raw value is the path
        return identifier.rawValue
    }
    
    /// Gets the parent path of a given path
    private func parentPath(of path: String) -> String {
        return (path as NSString).deletingLastPathComponent
    }
}

// MARK: - Connection Info

/// Parsed connection info from domain identifier
struct ConnectionInfo {
    let host: String
    let port: Int
    let username: String
    
    /// Parse from domain identifier format: "sftp-<host>-<port>-<username>"
    init?(domainIdentifier: String) {
        let parts = domainIdentifier.split(separator: "-")
        guard parts.count >= 4, parts[0] == "sftp" else {
            return nil
        }
        
        // Host may contain dashes, so username is last, port is second-to-last
        self.username = String(parts.last!)
        self.port = Int(parts[parts.count - 2]) ?? 22
        self.host = parts[1..<(parts.count - 2)].joined(separator: "-")
    }
}

// MARK: - Shared Keychain

/// Access to shared keychain credentials via App Group
/// This requires the KeychainManager from the main app to be compiled into the extension target
extension FileProviderExtension {
    
    /// Get password from shared App Group keychain
    static func getSharedPassword(for host: String, username: String) -> String? {
        do {
            return try KeychainManager.sharedForExtension.getPassword(for: host, username: username)
        } catch {
            logger.debug("📂 No password in shared keychain for \(username)@\(host)")
            return nil
        }
    }
    
    /// Get SSH key from shared App Group keychain
    static func getSharedSSHKey(named name: String) -> Data? {
        do {
            return try KeychainManager.sharedForExtension.getSSHKey(name: name)
        } catch {
            logger.debug("📂 No SSH key '\(name)' in shared keychain")
            return nil
        }
    }
}
