//
//  SFTPClientProtocol.swift
//  Geistty
//
//  Protocol abstraction for SFTP operations, enabling dependency injection and testing.
//
//  The real SFTPClient conforms to this protocol, and MockSFTPClient provides
//  a testable implementation that returns predictable data without network access.
//

import Foundation

/// Protocol defining the SFTP client interface for file operations
/// 
/// This allows injecting a mock implementation for testing without network access.
protocol SFTPClientProtocol: Actor {
    /// Check if connected to SFTP server
    var isConnected: Bool { get }
    
    /// List contents of a directory
    /// - Parameter path: The remote path to list
    /// - Returns: Array of file attributes for items in the directory
    func listDirectory(_ path: String) async throws -> [SFTPFileAttributes]
    
    /// Get file attributes for a specific path
    /// - Parameter path: The remote path
    /// - Returns: File attributes (throws if not found)
    func stat(_ path: String) async throws -> SFTPFileAttributes
    
    /// Read file contents
    /// - Parameters:
    ///   - path: The remote path
    ///   - progress: Optional progress callback
    /// - Returns: File data
    func readFile(_ path: String, progress: SFTPProgressCallback?) async throws -> Data
}

// MARK: - SFTPClient Conformance

extension SFTPClient: SFTPClientProtocol {
    // SFTPClient already implements all required methods
    // This extension just declares conformance
}
