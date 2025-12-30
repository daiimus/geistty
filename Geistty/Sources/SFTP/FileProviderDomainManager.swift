//
//  FileProviderDomainManager.swift
//  Geistty
//
//  Manages the single File Provider domain for Geistty.
//
//  Architecture (Shellfish-style):
//  - ONE domain "Geistty" appears in Files.app sidebar
//  - Inside, each enabled connection appears as a folder
//  - Browsing into a connection folder shows remote files
//

import FileProvider
import os.log

private let logger = Logger(subsystem: "com.geistty", category: "FileProviderDomain")

/// Manages the single Geistty File Provider domain
/// Connections with Files integration enabled appear as folders inside
@MainActor
class FileProviderDomainManager: ObservableObject {
    
    /// Shared instance
    static let shared = FileProviderDomainManager()
    
    /// The single domain identifier for Geistty
    nonisolated static let domainIdentifier = "geistty"
    
    /// Whether the domain is registered
    @Published private(set) var isDomainRegistered = false
    
    /// App Group identifier for shared storage with extension
    nonisolated static let appGroupIdentifier = "group.com.geistty.fileprovider"
    
    /// Key for connection list in shared UserDefaults
    nonisolated private static let connectionsKey = "fileprovider_connections"
    
    private init() {
        Task {
            await refreshDomainStatus()
        }
    }
    
    // MARK: - Domain Management
    
    /// Ensures the Geistty domain is registered
    func ensureDomainRegistered() async throws {
        if isDomainRegistered {
            return
        }
        
        let domainId = NSFileProviderDomainIdentifier(rawValue: Self.domainIdentifier)
        let domain = NSFileProviderDomain(identifier: domainId, displayName: "Geistty")
        
        logger.info("📂 Registering Geistty File Provider domain")
        
        do {
            try await NSFileProviderManager.add(domain)
            isDomainRegistered = true
            logger.info("✅ Geistty domain registered")
        } catch {
            // Domain might already exist - check if it's registered
            let domains = try? await NSFileProviderManager.domains()
            if domains?.contains(where: { $0.identifier == domainId }) == true {
                isDomainRegistered = true
                logger.info("📂 Domain already registered")
            } else {
                throw error
            }
        }
    }
    
    /// Removes the Geistty domain (called when no connections have Files integration)
    func removeDomain() async throws {
        let domainId = NSFileProviderDomainIdentifier(rawValue: Self.domainIdentifier)
        
        let domains = try await NSFileProviderManager.domains()
        guard let domain = domains.first(where: { $0.identifier == domainId }) else {
            isDomainRegistered = false
            return
        }
        
        try await NSFileProviderManager.remove(domain)
        isDomainRegistered = false
        logger.info("📂 Geistty domain removed")
    }
    
    /// Refreshes domain registration status
    func refreshDomainStatus() async {
        do {
            let domains = try await NSFileProviderManager.domains()
            isDomainRegistered = domains.contains { $0.identifier.rawValue == Self.domainIdentifier }
        } catch {
            logger.error("📂 Failed to check domain status: \(error.localizedDescription)")
        }
    }
    
    /// Removes legacy domains from previous implementation
    /// Call this on app launch to clean up old per-connection domains
    static func cleanupLegacyDomains() {
        Task {
            do {
                let domains = try await NSFileProviderManager.domains()
                
                for domain in domains {
                    // Keep only the new "geistty" domain, remove any legacy domains
                    // Legacy domains had format like "sftp_host_port_user"
                    if domain.identifier.rawValue != domainIdentifier {
                        logger.info("📂 Removing legacy domain: \(domain.identifier.rawValue)")
                        try await NSFileProviderManager.remove(domain)
                    }
                }
            } catch {
                logger.error("📂 Failed to cleanup legacy domains: \(error.localizedDescription)")
            }
        }
    }
    
    /// Signals that the root content changed (connection added/removed)
    func signalRootChanged() async {
        let domainId = NSFileProviderDomainIdentifier(rawValue: Self.domainIdentifier)
        let domain = NSFileProviderDomain(identifier: domainId, displayName: "Geistty")
        
        guard let manager = NSFileProviderManager(for: domain) else {
            return
        }
        
        do {
            try await manager.signalEnumerator(for: .rootContainer)
            logger.debug("📂 Signaled root enumerator change")
        } catch {
            logger.error("📂 Failed to signal change: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Connection Management (stored in shared UserDefaults)
    
    /// Connection info stored for File Provider access
    struct FileProviderConnection: Codable, Identifiable {
        let id: String  // Profile UUID
        let name: String
        let host: String
        let port: Int
        let username: String
        let authMethod: String  // "ssh_key" or "password"
        let sshKeyName: String?
        let sshKeyData: String?  // Base64-encoded
        let password: String?
    }
    
    /// Gets shared UserDefaults
    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: Self.appGroupIdentifier)
    }
    
    /// Adds or updates a connection for File Provider access
    func addConnection(
        profileId: String,
        name: String,
        host: String,
        port: Int,
        username: String,
        authMethod: String,
        sshKeyName: String?
    ) async {
        guard let defaults = sharedDefaults else {
            logger.error("📂 Cannot access shared UserDefaults")
            return
        }
        
        // Get credentials from keychain
        var sshKeyData: String?
        var password: String?
        
        logger.info("📂 Adding connection: \(name), authMethod: \(authMethod)")
        
        if authMethod == "ssh_key", let keyName = sshKeyName {
            logger.info("📂 Looking for SSH key: \(keyName)")
            if let data = try? KeychainManager.shared.getSSHKey(name: keyName) {
                sshKeyData = data.base64EncodedString()
                logger.info("📂 Got SSH key '\(keyName)' for File Provider (\(data.count) bytes)")
            } else {
                logger.error("❌ Failed to get SSH key '\(keyName)' from keychain")
            }
        } else if authMethod == "password" {
            logger.info("📂 Looking for password for \(username)@\(host)")
            if let pwd = try? KeychainManager.shared.getPassword(for: host, username: username) {
                password = pwd
                logger.info("📂 Got password for File Provider")
            } else {
                logger.error("❌ Failed to get password from keychain for \(username)@\(host)")
            }
        }
        
        // Log credential status
        logger.info("📂 Credentials: sshKeyData=\(sshKeyData != nil), password=\(password != nil)")
        
        let connection = FileProviderConnection(
            id: profileId,
            name: name,
            host: host,
            port: port,
            username: username,
            authMethod: authMethod,
            sshKeyName: sshKeyName,
            sshKeyData: sshKeyData,
            password: password
        )
        
        // Load existing, update, save
        var connections = loadConnections()
        connections[profileId] = connection
        saveConnections(connections)
        
        // Ensure domain is registered and signal change
        do {
            try await ensureDomainRegistered()
            await signalRootChanged()
        } catch {
            logger.error("📂 Failed to register domain: \(error.localizedDescription)")
        }
        
        logger.info("📂 Added connection: \(name)")
    }
    
    /// Removes a connection from File Provider
    func removeConnection(profileId: String) async {
        guard let defaults = sharedDefaults else { return }
        
        var connections = loadConnections()
        connections.removeValue(forKey: profileId)
        saveConnections(connections)
        
        // If no connections left, remove the domain entirely
        if connections.isEmpty {
            do {
                try await removeDomain()
            } catch {
                logger.error("📂 Failed to remove domain: \(error.localizedDescription)")
            }
        } else {
            await signalRootChanged()
        }
        
        logger.info("📂 Removed connection: \(profileId)")
    }
    
    /// Loads all connections from shared storage
    private func loadConnections() -> [String: FileProviderConnection] {
        guard let defaults = sharedDefaults,
              let data = defaults.data(forKey: Self.connectionsKey),
              let connections = try? JSONDecoder().decode([String: FileProviderConnection].self, from: data) else {
            return [:]
        }
        return connections
    }
    
    /// Saves connections to shared storage
    private func saveConnections(_ connections: [String: FileProviderConnection]) {
        guard let defaults = sharedDefaults,
              let data = try? JSONEncoder().encode(connections) else {
            return
        }
        defaults.set(data, forKey: Self.connectionsKey)
        defaults.synchronize()
    }
    
    /// Gets all connections (for File Provider extension to enumerate)
    /// This is nonisolated because it only reads from shared UserDefaults
    nonisolated static func getConnections() -> [FileProviderConnection] {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let data = defaults.data(forKey: connectionsKey),
              let connections = try? JSONDecoder().decode([String: FileProviderConnection].self, from: data) else {
            return []
        }
        return Array(connections.values)
    }
    
    /// Gets a specific connection by ID
    /// This is nonisolated because it only reads from shared UserDefaults
    nonisolated static func getConnection(id: String) -> FileProviderConnection? {
        NSLog("📂 [FP-DM] getConnection(id: %@)", id)
        
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            NSLog("❌ [FP-DM] Cannot access shared UserDefaults")
            return nil
        }
        
        guard let data = defaults.data(forKey: connectionsKey) else {
            NSLog("❌ [FP-DM] No data for key: %@", connectionsKey)
            return nil
        }
        
        guard let connections = try? JSONDecoder().decode([String: FileProviderConnection].self, from: data) else {
            NSLog("❌ [FP-DM] Failed to decode connections")
            return nil
        }
        
        NSLog("📂 [FP-DM] Found %d connections, looking for id: %@", connections.count, id)
        NSLog("📂 [FP-DM] Available IDs: %@", connections.keys.joined(separator: ", "))
        
        if let conn = connections[id] {
            NSLog("📂 [FP-DM] Found connection: %@", conn.name)
            return conn
        } else {
            NSLog("❌ [FP-DM] Connection not found for id: %@", id)
            return nil
        }
    }
    
    /// Reads debug log from File Provider extension (for debugging)
    nonisolated static func readExtensionDebugLog() -> String? {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return nil
        }
        let logFile = containerURL.appendingPathComponent("fileprovider_debug.log")
        return try? String(contentsOf: logFile, encoding: .utf8)
    }
    
    /// Clears the extension debug log
    nonisolated static func clearExtensionDebugLog() {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return
        }
        let logFile = containerURL.appendingPathComponent("fileprovider_debug.log")
        try? FileManager.default.removeItem(at: logFile)
    }
}
