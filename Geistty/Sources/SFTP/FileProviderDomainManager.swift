//
//  FileProviderDomainManager.swift
//  Geistty
//
//  Manages File Provider domains for SSH connections
//
//  Each saved SSH connection gets its own domain that appears
//  in the Files.app sidebar. This class handles domain registration
//  and removal.
//

import FileProvider
import os.log

private let logger = Logger(subsystem: "com.geistty", category: "FileProviderDomain")

/// Manages File Provider domains for SSH connections
/// Each domain represents one SSH server and appears in Files.app sidebar
@MainActor
class FileProviderDomainManager: ObservableObject {
    
    /// Shared instance
    static let shared = FileProviderDomainManager()
    
    /// Currently registered domains (domain ID -> display name)
    @Published private(set) var registeredDomains: [String: String] = [:]
    
    private init() {
        // Load existing domains on init
        Task {
            await refreshDomains()
        }
    }
    
    /// Creates a domain identifier from connection info
    /// Format: "sftp-<host>-<port>-<username>"
    static func domainIdentifier(host: String, port: Int, username: String) -> String {
        return "sftp-\(host)-\(port)-\(username)"
    }
    
    /// Creates a display name for the domain
    static func displayName(host: String, username: String) -> String {
        return "\(username)@\(host)"
    }
    
    /// Registers a new File Provider domain for an SSH connection
    /// - Parameters:
    ///   - host: SSH server hostname
    ///   - port: SSH port (default 22)
    ///   - username: SSH username
    /// - Returns: The registered domain identifier
    @discardableResult
    func registerDomain(host: String, port: Int = 22, username: String) async throws -> String {
        let identifier = Self.domainIdentifier(host: host, port: port, username: username)
        let displayName = Self.displayName(host: host, username: username)
        
        // Check if already registered
        if registeredDomains[identifier] != nil {
            logger.info("📂 Domain already registered: \(identifier)")
            return identifier
        }
        
        let domainId = NSFileProviderDomainIdentifier(rawValue: identifier)
        let domain = NSFileProviderDomain(identifier: domainId, displayName: displayName)
        
        logger.info("📂 Registering File Provider domain: \(identifier)")
        
        do {
            try await NSFileProviderManager.add(domain)
            registeredDomains[identifier] = displayName
            logger.info("✅ Domain registered: \(displayName)")
            return identifier
        } catch {
            logger.error("❌ Failed to register domain: \(error.localizedDescription)")
            throw error
        }
    }
    
    /// Removes a File Provider domain
    /// - Parameter identifier: The domain identifier to remove
    func removeDomain(identifier: String) async throws {
        let domainId = NSFileProviderDomainIdentifier(rawValue: identifier)
        
        // Find the domain
        let domains = try await NSFileProviderManager.domains()
        guard let domain = domains.first(where: { $0.identifier == domainId }) else {
            logger.warning("📂 Domain not found for removal: \(identifier)")
            registeredDomains.removeValue(forKey: identifier)
            return
        }
        
        logger.info("📂 Removing File Provider domain: \(identifier)")
        
        do {
            try await NSFileProviderManager.remove(domain)
            registeredDomains.removeValue(forKey: identifier)
            logger.info("✅ Domain removed: \(identifier)")
        } catch {
            logger.error("❌ Failed to remove domain: \(error.localizedDescription)")
            throw error
        }
    }
    
    /// Removes a domain for a specific connection
    func removeDomain(host: String, port: Int = 22, username: String) async throws {
        let identifier = Self.domainIdentifier(host: host, port: port, username: username)
        try await removeDomain(identifier: identifier)
    }
    
    /// Refreshes the list of registered domains
    func refreshDomains() async {
        do {
            let domains = try await NSFileProviderManager.domains()
            var newDomains: [String: String] = [:]
            
            for domain in domains {
                let id = domain.identifier.rawValue
                // Only track our SFTP domains
                if id.hasPrefix("sftp-") {
                    newDomains[id] = domain.displayName
                }
            }
            
            registeredDomains = newDomains
            logger.info("📂 Refreshed domains: \(newDomains.count) SFTP domains found")
        } catch {
            logger.error("📂 Failed to refresh domains: \(error.localizedDescription)")
        }
    }
    
    /// Checks if a domain is registered for a connection
    func isDomainRegistered(host: String, port: Int = 22, username: String) -> Bool {
        let identifier = Self.domainIdentifier(host: host, port: port, username: username)
        return registeredDomains[identifier] != nil
    }
    
    /// Signals that the contents of a domain need to be refreshed
    func signalEnumeratorChanged(host: String, port: Int = 22, username: String) async {
        let identifier = Self.domainIdentifier(host: host, port: port, username: username)
        let domainId = NSFileProviderDomainIdentifier(rawValue: identifier)
        
        guard let manager = NSFileProviderManager(for: NSFileProviderDomain(identifier: domainId, displayName: "")) else {
            logger.warning("📂 No manager for domain: \(identifier)")
            return
        }
        
        do {
            try await manager.signalEnumerator(for: .workingSet)
            logger.debug("📂 Signaled enumerator change for: \(identifier)")
        } catch {
            logger.error("📂 Failed to signal enumerator: \(error.localizedDescription)")
        }
    }
}
