//
//  SFTPClient.swift
//  Bodak
//
//  SFTP client for file operations over SSH
//
//  Note: For full Files.app integration, this requires:
//  1. A File Provider Extension target with NSFileProviderExtension
//  2. SFTP subsystem support in libssh2 (CSSH module may need updates)
//  3. Domain registration for each saved connection
//
//  Current implementation provides the API structure for future development.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.bodak", category: "SFTP")

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
    
    /// Create a sample file attribute for testing/demo
    static func sample(name: String, isDirectory: Bool = false, size: UInt64 = 0) -> SFTPFileAttributes {
        SFTPFileAttributes(
            name: name,
            size: size,
            permissions: isDirectory ? 0o755 : 0o644,
            modificationDate: Date(),
            isDirectory: isDirectory,
            isSymlink: false
        )
    }
}

/// Error types for SFTP operations
enum SFTPError: LocalizedError {
    case notConnected
    case notImplemented
    case connectionFailed(String)
    case authenticationFailed
    case commandFailed(String)
    case parseError(String)
    case fileNotFound(String)
    case permissionDenied(String)
    
    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to SSH server"
        case .notImplemented: return "SFTP subsystem not yet implemented. File Provider extension required for Files.app integration."
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .authenticationFailed: return "Authentication failed"
        case .commandFailed(let msg): return "Command failed: \(msg)"
        case .parseError(let msg): return "Parse error: \(msg)"
        case .fileNotFound(let path): return "File not found: \(path)"
        case .permissionDenied(let path): return "Permission denied: \(path)"
        }
    }
}

/// Progress callback for file transfers
typealias SFTPProgressCallback = (Int64, Int64) -> Void

/// SFTP client for file operations over SSH
///
/// This is a placeholder implementation. Full SFTP support requires:
/// - Adding SFTP subsystem bindings to the CSSH module
/// - Creating a FileProvider extension for Files.app integration
/// - Implementing proper streaming for large file transfers
actor SFTPClient {
    private var currentPath: String = "/"
    private var isConnected = false
    
    // Connection info
    private var host: String = ""
    private var port: Int = 22
    private var username: String = ""
    
    init() {}
    
    /// Connect to SSH server (placeholder - stores connection info)
    func connect(host: String, port: Int, username: String, password: String) async throws {
        self.host = host
        self.port = port
        self.username = username
        
        logger.info("🔗 SFTP connect requested to \(host):\(port)")
        logger.warning("⚠️ SFTP subsystem not yet implemented - Files.app integration requires FileProvider extension")
        
        // For now, mark as "connected" to allow UI testing
        isConnected = true
        currentPath = "/home/\(username)"
    }
    
    /// Connect using SSH key authentication (placeholder)
    func connect(host: String, port: Int, username: String, privateKey: Data, publicKey: Data?, passphrase: String?) async throws {
        self.host = host
        self.port = port
        self.username = username
        
        logger.info("🔗 SFTP connect with key requested to \(host):\(port)")
        logger.warning("⚠️ SFTP subsystem not yet implemented")
        
        isConnected = true
        currentPath = "/home/\(username)"
    }
    
    /// Disconnect from server
    func disconnect() {
        logger.info("🔌 SFTP disconnecting")
        isConnected = false
    }
    
    // MARK: - Directory Operations
    
    /// List contents of a directory (returns demo data)
    func listDirectory(_ path: String) async throws -> [SFTPFileAttributes] {
        guard isConnected else { throw SFTPError.notConnected }
        
        let fullPath = resolvePath(path)
        logger.info("📂 Listing directory: \(fullPath) (demo mode)")
        
        // Return demo data for UI testing
        return [
            .sample(name: "Documents", isDirectory: true),
            .sample(name: "Downloads", isDirectory: true),
            .sample(name: ".ssh", isDirectory: true),
            .sample(name: ".bashrc", size: 3771),
            .sample(name: ".profile", size: 807),
            .sample(name: "notes.txt", size: 2048),
        ]
    }
    
    /// Get file/directory attributes
    func stat(_ path: String) async throws -> SFTPFileAttributes {
        guard isConnected else { throw SFTPError.notConnected }
        
        let fullPath = resolvePath(path)
        let name = (fullPath as NSString).lastPathComponent
        
        return .sample(name: name, isDirectory: name.hasPrefix(".") == false && !name.contains("."))
    }
    
    /// Create a directory
    func mkdir(_ path: String, mode: Int32 = 0o755) async throws {
        guard isConnected else { throw SFTPError.notConnected }
        logger.info("📁 mkdir: \(resolvePath(path)) (not implemented)")
        throw SFTPError.notImplemented
    }
    
    /// Remove a directory
    func rmdir(_ path: String) async throws {
        guard isConnected else { throw SFTPError.notConnected }
        logger.info("🗑️ rmdir: \(resolvePath(path)) (not implemented)")
        throw SFTPError.notImplemented
    }
    
    // MARK: - File Operations
    
    /// Read a file's contents
    func readFile(_ path: String, progress: SFTPProgressCallback? = nil) async throws -> Data {
        guard isConnected else { throw SFTPError.notConnected }
        logger.info("📖 readFile: \(resolvePath(path)) (not implemented)")
        throw SFTPError.notImplemented
    }
    
    /// Write data to a file
    func writeFile(_ path: String, data: Data, progress: SFTPProgressCallback? = nil) async throws {
        guard isConnected else { throw SFTPError.notConnected }
        logger.info("📝 writeFile: \(resolvePath(path)) (not implemented)")
        throw SFTPError.notImplemented
    }
    
    /// Delete a file
    func unlink(_ path: String) async throws {
        guard isConnected else { throw SFTPError.notConnected }
        logger.info("🗑️ unlink: \(resolvePath(path)) (not implemented)")
        throw SFTPError.notImplemented
    }
    
    /// Rename/move a file
    func rename(from oldPath: String, to newPath: String) async throws {
        guard isConnected else { throw SFTPError.notConnected }
        logger.info("📦 rename: \(resolvePath(oldPath)) -> \(resolvePath(newPath)) (not implemented)")
        throw SFTPError.notImplemented
    }
    
    /// Get the real/canonical path
    func getRealPath(_ path: String) async throws -> String {
        guard isConnected else { throw SFTPError.notConnected }
        return resolvePath(path)
    }
    
    /// Get current working directory
    func pwd() -> String {
        return currentPath
    }
    
    /// Change current working directory
    func cd(_ path: String) async throws {
        guard isConnected else { throw SFTPError.notConnected }
        currentPath = resolvePath(path)
        logger.info("📂 Changed directory to: \(currentPath)")
    }
    
    // MARK: - Path Helpers
    
    private func resolvePath(_ path: String) -> String {
        if path.hasPrefix("/") {
            return path
        } else if path.hasPrefix("~") {
            return "/home/\(username)" + path.dropFirst()
        } else {
            return (currentPath as NSString).appendingPathComponent(path)
        }
    }
}


