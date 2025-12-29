//
//  FileProviderEnumerator.swift
//  GeisttyFileProvider
//
//  NSFileProviderEnumerator implementation for listing directory contents
//

import FileProvider
import os.log

private let logger = Logger(subsystem: "com.geistty.fileprovider", category: "Enumerator")

/// Enumerates items in a directory from the remote SFTP server
class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    
    // MARK: - Properties
    
    /// Remote directory path to enumerate
    private let path: String
    
    /// Domain this enumerator belongs to
    private let domain: NSFileProviderDomain
    
    /// Connection info for SFTP
    private let connectionInfo: ConnectionInfo?
    
    /// Whether this is the working set enumerator
    private let isWorkingSet: Bool
    
    /// SFTP client for remote operations
    private var sftpClient: SFTPClient?
    
    /// Anchor for change tracking
    private var currentAnchor: NSFileProviderSyncAnchor = NSFileProviderSyncAnchor(Data())
    
    // MARK: - Initialization
    
    init(path: String, domain: NSFileProviderDomain, connectionInfo: ConnectionInfo?, isWorkingSet: Bool) {
        self.path = path
        self.domain = domain
        self.connectionInfo = connectionInfo
        self.isWorkingSet = isWorkingSet
        super.init()
        
        logger.info("📂 Enumerator created for path: \(path) (workingSet: \(isWorkingSet))")
    }
    
    // MARK: - NSFileProviderEnumerator
    
    /// Called when the system no longer needs this enumerator
    func invalidate() {
        logger.debug("📂 Enumerator invalidated for path: \(path)")
        
        Task {
            await sftpClient?.disconnect()
            sftpClient = nil
        }
    }
    
    /// Enumerate all items in the directory
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        logger.info("📂 enumerateItems for path: \(path), page: \(page.rawValue.base64EncodedString())")
        
        Task {
            do {
                // Working set returns nothing for now (no offline support yet)
                if isWorkingSet {
                    observer.finishEnumerating(upTo: nil)
                    return
                }
                
                let client = try await ensureConnected()
                
                // List directory contents
                let items = try await client.listDirectory(path)
                
                // Convert to FileProviderItems
                let providerItems: [NSFileProviderItem] = items.map { attrs in
                    let itemPath = (path as NSString).appendingPathComponent(attrs.name)
                    return FileProviderItem(attributes: attrs, path: itemPath, parentPath: path)
                }
                
                logger.info("📂 Enumerated \(providerItems.count) items in \(path)")
                
                // Return all items (no pagination for SFTP)
                observer.didEnumerate(providerItems)
                observer.finishEnumerating(upTo: nil)
                
            } catch {
                logger.error("📂 enumerateItems error: \(error.localizedDescription)")
                observer.finishEnumeratingWithError(error)
            }
        }
    }
    
    /// Enumerate changes since the given sync anchor
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        logger.info("📂 enumerateChanges from anchor: \(anchor.rawValue.base64EncodedString())")
        
        // For SFTP, we don't have change notifications from the server
        // Just report no changes and return the same anchor
        // A full re-enumeration will be triggered when the user navigates
        
        observer.finishEnumeratingChanges(upTo: currentAnchor, moreComing: false)
    }
    
    /// Return the current sync anchor
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        // Use current timestamp as anchor
        let timestamp = Date().timeIntervalSince1970
        let anchorData = "\(timestamp)".data(using: .utf8) ?? Data()
        currentAnchor = NSFileProviderSyncAnchor(anchorData)
        
        completionHandler(currentAnchor)
    }
    
    // MARK: - Connection
    
    /// Ensures we have an active SFTP connection
    private func ensureConnected() async throws -> SFTPClient {
        if let client = sftpClient, client.isConnected {
            return client
        }
        
        guard let info = connectionInfo else {
            throw NSFileProviderError(.serverUnreachable)
        }
        
        logger.info("📂 Connecting to \(info.host):\(info.port) for enumeration...")
        
        // TODO: Implement actual connection with NIOSSHConnection
        // For now, create a placeholder
        let client = SFTPClient()
        
        self.sftpClient = client
        
        return client
    }
}
