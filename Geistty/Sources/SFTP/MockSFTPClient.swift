//
//  MockSFTPClient.swift
//  Geistty
//
//  Mock SFTP client for testing File Provider logic without network access.
//
//  This allows testing:
//  - Enumeration behavior
//  - MetadataStore population
//  - Anchor/change detection
//  - Working set management
//
//  Usage:
//    let mock = MockSFTPClient()
//    mock.setDirectoryContents("/", [
//        MockSFTPClient.file("test.txt", size: 100),
//        MockSFTPClient.directory("docs"),
//    ])
//    let entries = try await mock.listDirectory("/")
//

import Foundation

/// Mock SFTP client for testing
actor MockSFTPClient: SFTPClientProtocol {
    
    // MARK: - Test Configuration
    
    /// Simulated directory contents
    private var directoryContents: [String: [SFTPFileAttributes]] = [:]
    
    /// Simulated file data
    private var fileData: [String: Data] = [:]
    
    /// Track method calls for verification
    private(set) var listDirectoryCalls: [String] = []
    private(set) var statCalls: [String] = []
    private(set) var readFileCalls: [String] = []
    
    /// Simulated errors for specific paths
    private var errorPaths: [String: Error] = [:]
    
    /// Simulated latency (for testing async behavior)
    private var latencyMs: UInt64 = 0
    
    /// Connection state
    private var _isConnected: Bool = true
    
    // MARK: - Protocol Conformance
    
    var isConnected: Bool {
        _isConnected
    }
    
    func listDirectory(_ path: String) async throws -> [SFTPFileAttributes] {
        listDirectoryCalls.append(path)
        
        // Simulate latency
        if latencyMs > 0 {
            try await Task.sleep(nanoseconds: latencyMs * 1_000_000)
        }
        
        // Check for simulated errors
        if let error = errorPaths[path] {
            throw error
        }
        
        // Return configured contents, or empty array
        return directoryContents[path] ?? []
    }
    
    func stat(_ path: String) async throws -> SFTPFileAttributes {
        statCalls.append(path)
        
        if latencyMs > 0 {
            try await Task.sleep(nanoseconds: latencyMs * 1_000_000)
        }
        
        if let error = errorPaths[path] {
            throw error
        }
        
        // Look for the item in parent directory
        let parentPath = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        
        if let contents = directoryContents[parentPath],
           let item = contents.first(where: { $0.name == name }) {
            return item
        }
        
        throw SFTPError.fileNotFound(path)
    }
    
    func readFile(_ path: String, progress: SFTPProgressCallback? = nil) async throws -> Data {
        readFileCalls.append(path)
        
        if latencyMs > 0 {
            try await Task.sleep(nanoseconds: latencyMs * 1_000_000)
        }
        
        if let error = errorPaths[path] {
            throw error
        }
        
        if let data = fileData[path] {
            // Report progress if callback provided
            progress?(Int64(data.count), Int64(data.count))
            return data
        }
        
        throw SFTPError.fileNotFound(path)
    }
    
    // MARK: - Test Setup Methods
    
    /// Set directory contents for a path
    func setDirectoryContents(_ path: String, _ contents: [SFTPFileAttributes]) {
        directoryContents[path] = contents
    }
    
    /// Add a single entry to a directory
    func addEntry(_ path: String, _ entry: SFTPFileAttributes) {
        var contents = directoryContents[path] ?? []
        contents.append(entry)
        directoryContents[path] = contents
    }
    
    /// Remove an entry from a directory
    func removeEntry(_ dirPath: String, name: String) {
        directoryContents[dirPath]?.removeAll { $0.name == name }
    }
    
    /// Set file data for a path
    func setFileData(_ path: String, _ data: Data) {
        fileData[path] = data
    }
    
    /// Set an error for a specific path
    func setError(_ path: String, _ error: Error) {
        errorPaths[path] = error
    }
    
    /// Clear error for a path
    func clearError(_ path: String) {
        errorPaths.removeValue(forKey: path)
    }
    
    /// Set simulated latency in milliseconds
    func setLatency(_ ms: UInt64) {
        latencyMs = ms
    }
    
    /// Set connection state
    func setConnected(_ connected: Bool) {
        _isConnected = connected
    }
    
    /// Reset all state
    func reset() {
        directoryContents.removeAll()
        fileData.removeAll()
        errorPaths.removeAll()
        listDirectoryCalls.removeAll()
        statCalls.removeAll()
        readFileCalls.removeAll()
        latencyMs = 0
        _isConnected = true
    }
    
    // MARK: - Factory Methods for Test Data
    
    /// Create a file entry
    static func file(
        _ name: String,
        size: UInt64 = 0,
        permissions: UInt32 = 0o644,
        modificationDate: Date? = nil
    ) -> SFTPFileAttributes {
        SFTPFileAttributes(
            name: name,
            size: size,
            permissions: permissions,
            modificationDate: modificationDate ?? Date(),
            isDirectory: false,
            isSymlink: false
        )
    }
    
    /// Create a directory entry
    static func directory(
        _ name: String,
        permissions: UInt32 = 0o755,
        modificationDate: Date? = nil
    ) -> SFTPFileAttributes {
        SFTPFileAttributes(
            name: name,
            size: 4096,
            permissions: permissions,
            modificationDate: modificationDate ?? Date(),
            isDirectory: true,
            isSymlink: false
        )
    }
    
    /// Create a symlink entry
    static func symlink(
        _ name: String,
        permissions: UInt32 = 0o777
    ) -> SFTPFileAttributes {
        SFTPFileAttributes(
            name: name,
            size: 0,
            permissions: permissions,
            modificationDate: Date(),
            isDirectory: false,
            isSymlink: true
        )
    }
}

// MARK: - Test Scenarios

extension MockSFTPClient {
    
    /// Set up a typical home directory structure
    func setupTypicalHomeDirectory() {
        setDirectoryContents("/home/user", [
            MockSFTPClient.directory("Documents"),
            MockSFTPClient.directory("Downloads"),
            MockSFTPClient.directory(".ssh"),
            MockSFTPClient.file(".bashrc", size: 1024),
            MockSFTPClient.file(".profile", size: 512),
        ])
        
        setDirectoryContents("/home/user/Documents", [
            MockSFTPClient.file("readme.txt", size: 256),
            MockSFTPClient.file("notes.md", size: 1024),
            MockSFTPClient.directory("Projects"),
        ])
        
        setDirectoryContents("/home/user/Downloads", [
            MockSFTPClient.file("archive.zip", size: 1024 * 1024),
        ])
        
        setDirectoryContents("/home/user/.ssh", [
            MockSFTPClient.file("id_rsa", size: 1679, permissions: 0o600),
            MockSFTPClient.file("id_rsa.pub", size: 381, permissions: 0o644),
            MockSFTPClient.file("known_hosts", size: 2048),
        ])
    }
    
    /// Set up a scenario where files change between listings
    func setupChangingDirectory() {
        // Initial state
        setDirectoryContents("/data", [
            MockSFTPClient.file("file1.txt", size: 100),
            MockSFTPClient.file("file2.txt", size: 200),
        ])
    }
    
    /// Simulate a file being added (call after initial enumeration)
    func simulateFileAdded() {
        addEntry("/data", MockSFTPClient.file("file3.txt", size: 300))
    }
    
    /// Simulate a file being removed
    func simulateFileRemoved() {
        removeEntry("/data", name: "file1.txt")
    }
    
    /// Simulate a file being modified (size change)
    func simulateFileModified() {
        removeEntry("/data", name: "file2.txt")
        addEntry("/data", MockSFTPClient.file("file2.txt", size: 250, modificationDate: Date()))
    }
}
