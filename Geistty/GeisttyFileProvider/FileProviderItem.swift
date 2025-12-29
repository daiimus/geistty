//
//  FileProviderItem.swift
//  GeisttyFileProvider
//
//  NSFileProviderItem implementation wrapping SFTPFileAttributes
//

import FileProvider
import UniformTypeIdentifiers

/// Represents a file or directory item in the File Provider
/// Wraps SFTPFileAttributes with the metadata Files.app needs
class FileProviderItem: NSObject, NSFileProviderItem {
    
    // MARK: - Properties
    
    /// The remote file attributes
    private let attributes: SFTPFileAttributes?
    
    /// Remote path on server
    private let remotePath: String
    
    /// Parent directory path
    private let parentPath: String
    
    /// Whether this is the root container
    private let isRoot: Bool
    
    /// Domain for root items
    private let domain: NSFileProviderDomain?
    
    // MARK: - Initialization
    
    /// Create from SFTP attributes
    init(attributes: SFTPFileAttributes, path: String, parentPath: String) {
        self.attributes = attributes
        self.remotePath = path
        self.parentPath = parentPath
        self.isRoot = false
        self.domain = nil
        super.init()
    }
    
    /// Create root container item
    static func rootContainer(domain: NSFileProviderDomain) -> FileProviderItem {
        let item = FileProviderItem(isRoot: true, domain: domain)
        return item
    }
    
    private init(isRoot: Bool, domain: NSFileProviderDomain) {
        self.attributes = nil
        self.remotePath = "/"
        self.parentPath = ""
        self.isRoot = true
        self.domain = domain
        super.init()
    }
    
    // MARK: - NSFileProviderItem Required Properties
    
    /// Unique identifier for this item
    /// For root, use .rootContainer
    /// For others, base64 encode the remote path
    var itemIdentifier: NSFileProviderItemIdentifier {
        if isRoot {
            return .rootContainer
        }
        
        let encoded = remotePath.data(using: .utf8)?.base64EncodedString() ?? remotePath
        return NSFileProviderItemIdentifier(encoded)
    }
    
    /// Parent item identifier
    var parentItemIdentifier: NSFileProviderItemIdentifier {
        if isRoot || parentPath == "/" || parentPath.isEmpty {
            return .rootContainer
        }
        
        let encoded = parentPath.data(using: .utf8)?.base64EncodedString() ?? parentPath
        return NSFileProviderItemIdentifier(encoded)
    }
    
    /// Filename to display
    var filename: String {
        if isRoot {
            return domain?.displayName ?? "Remote Files"
        }
        return attributes?.name ?? (remotePath as NSString).lastPathComponent
    }
    
    /// Content type (folder or file type based on extension)
    var contentType: UTType {
        if isRoot || (attributes?.isDirectory ?? false) {
            return .folder
        }
        
        // Determine type from extension
        let ext = (filename as NSString).pathExtension.lowercased()
        if let type = UTType(filenameExtension: ext) {
            return type
        }
        
        return .data
    }
    
    /// Capabilities - what operations are allowed
    var capabilities: NSFileProviderItemCapabilities {
        if isRoot {
            return [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems]
        }
        
        if attributes?.isDirectory ?? false {
            return [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems,
                    .allowsDeleting, .allowsRenaming, .allowsReparenting]
        }
        
        return [.allowsReading, .allowsWriting, .allowsDeleting,
                .allowsRenaming, .allowsReparenting]
    }
    
    // MARK: - Optional Properties
    
    /// File size in bytes
    var documentSize: NSNumber? {
        guard let attrs = attributes, !attrs.isDirectory else { return nil }
        return NSNumber(value: attrs.size)
    }
    
    /// Creation date (we don't have this from SFTP, use modification date)
    var creationDate: Date? {
        return attributes?.modificationDate
    }
    
    /// Modification date
    var contentModificationDate: Date? {
        return attributes?.modificationDate
    }
    
    /// Item version for conflict detection
    var itemVersion: NSFileProviderItemVersion {
        // Use modification time and size as version
        let contentVersion: Data
        if let attrs = attributes {
            let versionString = "\(attrs.size)-\(attrs.modificationDate?.timeIntervalSince1970 ?? 0)"
            contentVersion = versionString.data(using: .utf8) ?? Data()
        } else {
            contentVersion = Data()
        }
        
        return NSFileProviderItemVersion(
            contentVersion: contentVersion,
            metadataVersion: contentVersion
        )
    }
    
    /// Symlink target (if this is a symlink)
    var symlinkTargetPath: String? {
        guard attributes?.isSymlink ?? false else { return nil }
        // We don't track symlink targets currently
        // Would need to call readlink() in SFTP
        return nil
    }
}

// MARK: - Identifier Helpers

extension NSFileProviderItemIdentifier {
    /// Decode path from identifier
    var decodedPath: String? {
        if self == .rootContainer {
            return "/"
        }
        
        guard let data = Data(base64Encoded: rawValue),
              let path = String(data: data, encoding: .utf8) else {
            return rawValue
        }
        
        return path
    }
}
