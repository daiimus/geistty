//
//  SFTPClient.swift
//  Geistty
//
//  High-level SFTP client for file operations over SSH
//
//  This actor provides a simple async/await API for SFTP operations,
//  wrapping the low-level SFTPChannel protocol implementation.
//

import Foundation
import NIOCore
import os.log

private let logger = Logger(subsystem: "com.geistty", category: "SFTP")

/// SFTP file attributes
struct SFTPFileAttributes: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let size: UInt64
    let permissions: UInt32
    let modificationDate: Date?
    let isDirectory: Bool
    let isSymlink: Bool
    
    var permissionString: String {
        var result = isDirectory ? "d" : (isSymlink ? "l" : "-")
        let perms = [(0o400, "r"), (0o200, "w"), (0o100, "x"),
                     (0o040, "r"), (0o020, "w"), (0o010, "x"),
                     (0o004, "r"), (0o002, "w"), (0o001, "x")]
        for (mask, char) in perms {
            result += (permissions & UInt32(mask)) != 0 ? char : "-"
        }
        return result
    }
    
    var formattedSize: String {
        if isDirectory { return "--" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }
}

/// Error types for SFTP operations
enum SFTPError: LocalizedError {
    case notConnected
    case connectionFailed(String)
    case authenticationFailed
    case commandFailed(String)
    case parseError(String)
    case fileNotFound(String)
    case permissionDenied(String)
    case ioError(String)
    
    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to SSH server"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .authenticationFailed: return "Authentication failed"
        case .commandFailed(let msg): return "Command failed: \(msg)"
        case .parseError(let msg): return "Parse error: \(msg)"
        case .fileNotFound(let path): return "File not found: \(path)"
        case .permissionDenied(let path): return "Permission denied: \(path)"
        case .ioError(let msg): return "I/O error: \(msg)"
        }
    }
}

/// Progress callback for file transfers
typealias SFTPProgressCallback = (Int64, Int64) -> Void

/// SFTP client for file operations over SSH
///
/// Provides a high-level async/await API for common SFTP operations.
/// Uses SFTPChannel internally for the low-level protocol implementation.
actor SFTPClient {
    /// The underlying SFTP channel
    private var channel: SFTPChannel?
    
    /// Current working directory
    private var currentPath: String = "/"
    
    /// Connection info for display
    private var host: String = ""
    private var username: String = ""
    
    /// Connection state - tracks whether SFTP subsystem is open (set after successful connect)
    private var _isConnected: Bool = false
    
    /// Read buffer size (64KB)
    private let readBufferSize: UInt32 = 64 * 1024
    
    /// Write buffer size (64KB)
    private let writeBufferSize: Int = 64 * 1024
    
    init() {}
    
    /// Initialize with an existing SSH connection channel
    /// - Parameter parentChannel: The NIO channel from NIOSSHConnection
    init(parentChannel: Channel) {
        self.channel = SFTPChannel(parentChannel: parentChannel)
    }
    
    /// Set the parent channel for SFTP operations
    func setParentChannel(_ parentChannel: Channel) {
        self.channel = SFTPChannel(parentChannel: parentChannel)
        self._isConnected = false
    }
    
    /// Connect the SFTP subsystem
    func connect(host: String, username: String) async throws {
        self.host = host
        self.username = username
        
        guard let channel = channel else {
            throw SFTPError.notConnected
        }
        
        logger.info("📂 Connecting SFTP to \(host)...")
        try await channel.open()
        
        // Mark connected only after SFTP subsystem successfully opens
        self._isConnected = true
        
        // Get initial path (home directory)
        do {
            currentPath = try await channel.realpath(".")
            logger.info("📂 SFTP connected, home: \(self.currentPath)")
        } catch {
            currentPath = "/home/\(username)"
            logger.warning("📂 Could not resolve home, using: \(self.currentPath)")
        }
    }
    
    /// Disconnect from server
    func disconnect() async {
        logger.info("📂 Disconnecting SFTP")
        self._isConnected = false
        await channel?.close()
        channel = nil
    }
    
    /// Check if connected - verifies SFTP subsystem is actually open, not just object exists
    var isConnected: Bool {
        // Return our tracked state - set true only after channel.open() succeeds
        return _isConnected && channel != nil
    }
    
    // MARK: - Directory Operations
    
    /// List contents of a directory
    func listDirectory(_ path: String) async throws -> [SFTPFileAttributes] {
        guard let channel = channel else {
            throw SFTPError.notConnected
        }
        
        let fullPath = resolvePath(path)
        logger.info("📂 Listing: \(fullPath)")
        
        // Open directory
        let handle = try await channel.opendir(fullPath)
        defer {
            Task { try? await channel.close(handle: handle) }
        }
        
        // Read all entries
        var allItems: [SFTPFileAttributes] = []
        
        while true {
            let items = try await channel.readdir(handle: handle)
            if items.isEmpty { break }
            allItems.append(contentsOf: items)
        }
        
        // Sort: directories first, then by name
        allItems.sort { a, b in
            if a.isDirectory != b.isDirectory {
                return a.isDirectory
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        
        logger.info("📂 Found \(allItems.count) items in \(fullPath)")
        return allItems
    }
    
    /// Get file/directory attributes
    func stat(_ path: String) async throws -> SFTPFileAttributes {
        guard let channel = channel else {
            throw SFTPError.notConnected
        }
        
        let fullPath = resolvePath(path)
        return try await channel.stat(fullPath)
    }
    
    /// Create a directory
    func mkdir(_ path: String, mode: Int32 = 0o755) async throws {
        guard let channel = channel else {
            throw SFTPError.notConnected
        }
        
        let fullPath = resolvePath(path)
        logger.info("📁 Creating directory: \(fullPath)")
        try await channel.mkdir(fullPath, mode: UInt32(mode))
    }
    
    /// Remove a directory
    func rmdir(_ path: String) async throws {
        guard let channel = channel else {
            throw SFTPError.notConnected
        }
        
        let fullPath = resolvePath(path)
        logger.info("🗑️ Removing directory: \(fullPath)")
        try await channel.rmdir(fullPath)
    }
    
    // MARK: - File Operations
    
    /// Read a file's contents
    func readFile(_ path: String, progress: SFTPProgressCallback? = nil) async throws -> Data {
        guard let channel = channel else {
            throw SFTPError.notConnected
        }
        
        let fullPath = resolvePath(path)
        logger.info("📖 Reading file: \(fullPath)")
        
        // Get file size first
        let attrs = try await channel.stat(fullPath)
        let totalSize = Int64(attrs.size)
        
        // Open file for reading
        let handle = try await channel.open(fullPath, flags: .read)
        defer {
            Task { try? await channel.close(handle: handle) }
        }
        
        // Read in chunks
        var result = Data()
        var offset: UInt64 = 0
        
        while true {
            let chunk = try await channel.read(handle: handle, offset: offset, length: readBufferSize)
            if chunk.isEmpty { break }
            
            result.append(chunk)
            offset += UInt64(chunk.count)
            
            progress?(Int64(offset), totalSize)
        }
        
        logger.info("📖 Read \(result.count) bytes from \(fullPath)")
        return result
    }
    
    /// Write data to a file
    func writeFile(_ path: String, data: Data, progress: SFTPProgressCallback? = nil) async throws {
        guard let channel = channel else {
            throw SFTPError.notConnected
        }
        
        let fullPath = resolvePath(path)
        logger.info("📝 Writing file: \(fullPath) (\(data.count) bytes)")
        
        // Open file for writing (create/truncate)
        let flags: SFTPOpenFlags = [.write, .create, .truncate]
        let handle = try await channel.open(fullPath, flags: flags)
        defer {
            Task { try? await channel.close(handle: handle) }
        }
        
        // Write in chunks
        var offset: UInt64 = 0
        let totalSize = Int64(data.count)
        
        while offset < UInt64(data.count) {
            let end = min(Int(offset) + writeBufferSize, data.count)
            let chunk = data[Int(offset)..<end]
            
            try await channel.write(handle: handle, offset: offset, data: Data(chunk))
            offset = UInt64(end)
            
            progress?(Int64(offset), totalSize)
        }
        
        logger.info("📝 Wrote \(data.count) bytes to \(fullPath)")
    }
    
    /// Delete a file
    func unlink(_ path: String) async throws {
        guard let channel = channel else {
            throw SFTPError.notConnected
        }
        
        let fullPath = resolvePath(path)
        logger.info("🗑️ Deleting file: \(fullPath)")
        try await channel.remove(fullPath)
    }
    
    /// Rename/move a file
    func rename(from oldPath: String, to newPath: String) async throws {
        guard let channel = channel else {
            throw SFTPError.notConnected
        }
        
        let fromPath = resolvePath(oldPath)
        let toPath = resolvePath(newPath)
        logger.info("📦 Renaming: \(fromPath) -> \(toPath)")
        try await channel.rename(from: fromPath, to: toPath)
    }
    
    /// Get the real/canonical path
    func getRealPath(_ path: String) async throws -> String {
        guard let channel = channel else {
            throw SFTPError.notConnected
        }
        
        return try await channel.realpath(resolvePath(path))
    }
    
    /// Get current working directory
    func pwd() -> String {
        return currentPath
    }
    
    /// Change current working directory
    func cd(_ path: String) async throws {
        guard let channel = channel else {
            throw SFTPError.notConnected
        }
        
        let fullPath = resolvePath(path)
        
        // Verify it's a directory
        let attrs = try await channel.stat(fullPath)
        guard attrs.isDirectory else {
            throw SFTPError.commandFailed("Not a directory: \(fullPath)")
        }
        
        currentPath = try await channel.realpath(fullPath)
        logger.info("📂 Changed directory to: \(self.currentPath)")
    }
    
    // MARK: - Convenience Methods
    
    /// Download a file to local storage
    func downloadFile(_ remotePath: String, to localURL: URL, progress: SFTPProgressCallback? = nil) async throws {
        let data = try await readFile(remotePath, progress: progress)
        try data.write(to: localURL)
        logger.info("💾 Downloaded to: \(localURL.path)")
    }
    
    /// Upload a file from local storage
    func uploadFile(from localURL: URL, to remotePath: String, progress: SFTPProgressCallback? = nil) async throws {
        let data = try Data(contentsOf: localURL)
        try await writeFile(remotePath, data: data, progress: progress)
        logger.info("📤 Uploaded from: \(localURL.path)")
    }
    
    /// Delete a file or directory recursively
    func delete(_ path: String) async throws {
        guard let channel = channel else {
            throw SFTPError.notConnected
        }
        
        let fullPath = resolvePath(path)
        let attrs = try await channel.stat(fullPath)
        
        if attrs.isDirectory {
            // Delete contents first
            let items = try await listDirectory(fullPath)
            for item in items {
                let itemPath = (fullPath as NSString).appendingPathComponent(item.name)
                try await delete(itemPath)
            }
            try await rmdir(fullPath)
        } else {
            try await unlink(fullPath)
        }
    }
    
    // MARK: - Path Helpers
    
    private func resolvePath(_ path: String) -> String {
        if path.hasPrefix("/") {
            return path
        } else if path.hasPrefix("~") {
            return "/home/\(username)" + path.dropFirst()
        } else if path == "." {
            return currentPath
        } else if path == ".." {
            return (currentPath as NSString).deletingLastPathComponent
        } else {
            return (currentPath as NSString).appendingPathComponent(path)
        }
    }
}
