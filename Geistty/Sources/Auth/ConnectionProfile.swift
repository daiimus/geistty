//
//  ConnectionProfile.swift
//  Geistty
//
//  Model for saved SSH connection profiles with iCloud sync
//

import Foundation
import SwiftUI
import Combine
import os.log

private let logger = Logger(subsystem: "com.geistty", category: "ConnectionProfile")

/// Authentication method for SSH connections
///
/// Best practices for SSH authentication:
/// - **SSH Key** (preferred): More secure, no password to remember. Import .pem files from
///   Files app or generate keys directly in Geistty.
/// - **Password**: Enter manually at connection time. Optionally save in Keychain.
///
/// Note: Desktop SSH agent integrations (1Password, LastPass, etc.) are not available
/// on iOS. Import SSH keys into Geistty directly via Files, or generate them in-app.
enum AuthMethod: String, Codable, CaseIterable, Identifiable {
    case sshKey = "ssh_key"
    case password = "password"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .sshKey: return "SSH Key"
        case .password: return "Password"
        }
    }
    
    var description: String {
        switch self {
        case .sshKey: return "Import or generate an SSH key (recommended)"
        case .password: return "Password saved securely in Keychain"
        }
    }
    
    var icon: String {
        switch self {
        case .sshKey: return "key.horizontal.fill"
        case .password: return "textformat.abc"
        }
    }
}

/// A saved SSH connection profile
struct ConnectionProfile: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var authMethod: AuthMethod
    
    // For SSH key auth
    var sshKeyName: String?
    
    // Session options
    var useTmux: Bool  // Auto-attach to or create tmux session
    var tmuxSessionName: String?  // Custom tmux session name (nil = auto geistty-N)
    
    // Files.app integration
    var enableFilesIntegration: Bool  // Show this server in Files.app sidebar
    
    // Metadata
    var createdAt: Date
    var lastConnectedAt: Date?
    var isFavorite: Bool
    var colorTag: String?  // For visual organization
    
    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        authMethod: AuthMethod = .sshKey,
        sshKeyName: String? = nil,
        useTmux: Bool = false,
        tmuxSessionName: String? = nil,
        enableFilesIntegration: Bool = false
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.sshKeyName = sshKeyName
        self.useTmux = useTmux
        self.tmuxSessionName = tmuxSessionName
        self.enableFilesIntegration = enableFilesIntegration
        self.createdAt = Date()
        self.lastConnectedAt = nil
        self.isFavorite = false
        self.colorTag = nil
    }
    
    // Custom coding keys to handle migration from old profiles without tmux/filesIntegration fields
    enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, authMethod, sshKeyName
        case useTmux, tmuxSessionName, enableFilesIntegration
        case createdAt, lastConnectedAt, isFavorite, colorTag
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        authMethod = try container.decode(AuthMethod.self, forKey: .authMethod)
        sshKeyName = try container.decodeIfPresent(String.self, forKey: .sshKeyName)
        // Handle migration: default to false if not present
        useTmux = try container.decodeIfPresent(Bool.self, forKey: .useTmux) ?? false
        tmuxSessionName = try container.decodeIfPresent(String.self, forKey: .tmuxSessionName)
        enableFilesIntegration = try container.decodeIfPresent(Bool.self, forKey: .enableFilesIntegration) ?? false
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
        isFavorite = try container.decode(Bool.self, forKey: .isFavorite)
        colorTag = try container.decodeIfPresent(String.self, forKey: .colorTag)
    }
    
    /// Display string for the connection
    var displayString: String {
        if port == 22 {
            return "\(username)@\(host)"
        } else {
            return "\(username)@\(host):\(port)"
        }
    }
    
    /// Icon for the auth method
    var authIcon: String {
        authMethod.icon
    }
}

/// Manages saved connection profiles with iCloud sync
@MainActor
class ConnectionProfileManager: ObservableObject {
    
    /// Shared instance
    static let shared = ConnectionProfileManager()
    
    /// Published list of profiles
    @Published var profiles: [ConnectionProfile] = []
    
    /// iCloud sync enabled status
    @Published var iCloudSyncEnabled: Bool = false
    
    /// Storage keys
    private let localStorageKey = "connection_profiles"
    private let iCloudStorageKey = "connection_profiles"
    private let deletedProfilesKey = "deleted_profile_ids"
    
    /// iCloud key-value store
    private let iCloudStore = NSUbiquitousKeyValueStore.default
    
    /// Tombstone set — profile IDs that were intentionally deleted
    private var deletedProfileIds: Set<UUID> = []
    
    /// Cancellables for Combine
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        // Check if iCloud is available
        checkiCloudAvailability()
        
        // Load tombstones before profiles so merge can use them
        loadDeletedProfileIds()
        
        // Load profiles
        loadProfiles()
        
        // Set up iCloud change notification
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(iCloudStoreDidChange),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: iCloudStore
        )
        
        // Synchronize iCloud store
        iCloudStore.synchronize()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - iCloud Availability
    
    private func checkiCloudAvailability() {
        // Check if iCloud is available by trying to access the store
        // The store is always available but syncing only works with iCloud signed in
        iCloudSyncEnabled = FileManager.default.ubiquityIdentityToken != nil
    }
    
    // MARK: - iCloud Change Notification
    
    @objc private func iCloudStoreDidChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let changeReason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int else {
            return
        }
        
        // Handle different change reasons
        switch changeReason {
        case NSUbiquitousKeyValueStoreServerChange,
             NSUbiquitousKeyValueStoreInitialSyncChange:
            // External change - merge with local
            Task { @MainActor in
                self.mergeFromiCloud()
            }
        case NSUbiquitousKeyValueStoreQuotaViolationChange:
            logger.warning("iCloud storage quota exceeded")
        case NSUbiquitousKeyValueStoreAccountChange:
            // Account changed - reload
            Task { @MainActor in
                self.checkiCloudAvailability()
                self.loadProfiles()
            }
        default:
            break
        }
    }
    
    // MARK: - CRUD Operations
    
    /// Add a new profile
    func addProfile(_ profile: ConnectionProfile) {
        profiles.append(profile)
        saveProfiles()
    }
    
    /// Update an existing profile
    func updateProfile(_ profile: ConnectionProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
            saveProfiles()
        }
    }
    
    /// Delete a profile
    func deleteProfile(_ profile: ConnectionProfile) {
        profiles.removeAll { $0.id == profile.id }
        deletedProfileIds.insert(profile.id)
        saveDeletedProfileIds()
        saveProfiles()
    }
    
    /// Delete profiles by index set
    func deleteProfiles(at offsets: IndexSet) {
        // Record tombstones before removal so iCloud sync won't resurrect them
        for index in offsets {
            deletedProfileIds.insert(profiles[index].id)
        }
        saveDeletedProfileIds()
        profiles.remove(atOffsets: offsets)
        saveProfiles()
    }
    
    /// Mark a profile as recently connected
    func markConnected(_ profile: ConnectionProfile) {
        if var updated = profiles.first(where: { $0.id == profile.id }) {
            updated.lastConnectedAt = Date()
            updateProfile(updated)
        }
    }
    
    /// Toggle favorite status
    func toggleFavorite(_ profile: ConnectionProfile) {
        if var updated = profiles.first(where: { $0.id == profile.id }) {
            updated.isFavorite.toggle()
            updateProfile(updated)
        }
    }
    
    // MARK: - Queries
    
    /// Get favorite profiles
    var favorites: [ConnectionProfile] {
        profiles.filter { $0.isFavorite }
    }
    
    /// Get recently connected profiles
    var recents: [ConnectionProfile] {
        profiles
            .filter { $0.lastConnectedAt != nil }
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
    }
    
    /// Search profiles by name or host
    func search(_ query: String) -> [ConnectionProfile] {
        guard !query.isEmpty else { return profiles }
        let lowercased = query.lowercased()
        return profiles.filter {
            $0.name.lowercased().contains(lowercased) ||
            $0.host.lowercased().contains(lowercased) ||
            $0.username.lowercased().contains(lowercased)
        }
    }
    
    // MARK: - Persistence
    
    private func loadProfiles() {
        // Try loading from iCloud first if available
        if iCloudSyncEnabled, let data = iCloudStore.data(forKey: iCloudStorageKey),
           let decoded = try? JSONDecoder().decode([ConnectionProfile].self, from: data) {
            // Filter out tombstoned profiles — they were deleted locally but may
            // still exist in iCloud until the next sync pushes our deletion.
            profiles = decoded.filter { !deletedProfileIds.contains($0.id) }
            // Also save to local as backup
            saveToLocal(profiles)
            return
        }
        
        // Fall back to local storage
        guard let data = UserDefaults.standard.data(forKey: localStorageKey),
              let decoded = try? JSONDecoder().decode([ConnectionProfile].self, from: data) else {
            profiles = []
            return
        }
        profiles = decoded
        
        // If we loaded from local and iCloud is available, push to iCloud
        if iCloudSyncEnabled {
            saveToiCloud(profiles)
        }
    }
    
    private func saveProfiles() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        
        // Always save locally
        UserDefaults.standard.set(data, forKey: localStorageKey)
        
        // Save to iCloud if available
        if iCloudSyncEnabled {
            iCloudStore.set(data, forKey: iCloudStorageKey)
            iCloudStore.synchronize()
        }
    }
    
    private func saveToLocal(_ profiles: [ConnectionProfile]) {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: localStorageKey)
        }
    }
    
    private func saveToiCloud(_ profiles: [ConnectionProfile]) {
        if let data = try? JSONEncoder().encode(profiles) {
            iCloudStore.set(data, forKey: iCloudStorageKey)
            iCloudStore.synchronize()
        }
    }
    
    // MARK: - Tombstone Persistence
    
    private func loadDeletedProfileIds() {
        // Load from both local and iCloud, merge
        let localStrings = UserDefaults.standard.stringArray(forKey: deletedProfilesKey) ?? []
        let iCloudStrings = iCloudStore.array(forKey: deletedProfilesKey) as? [String] ?? []
        let all = Set(localStrings + iCloudStrings)
        deletedProfileIds = Set(all.compactMap { UUID(uuidString: $0) })
    }
    
    private func saveDeletedProfileIds() {
        let strings = deletedProfileIds.map { $0.uuidString }
        UserDefaults.standard.set(strings, forKey: deletedProfilesKey)
        if iCloudSyncEnabled {
            iCloudStore.set(strings, forKey: deletedProfilesKey)
            iCloudStore.synchronize()
        }
    }
    
    // MARK: - iCloud Merge
    
    /// Merge profiles from iCloud with local profiles
    /// Uses "last modified wins" strategy based on lastConnectedAt and createdAt.
    /// Respects tombstones: profiles deleted locally are not resurrected from iCloud.
    private func mergeFromiCloud() {
        guard let data = iCloudStore.data(forKey: iCloudStorageKey),
              let iCloudProfiles = try? JSONDecoder().decode([ConnectionProfile].self, from: data) else {
            return
        }
        
        // Also load remote tombstones
        let remoteTombstoneStrings = iCloudStore.array(forKey: deletedProfilesKey) as? [String] ?? []
        let remoteTombstones = Set(remoteTombstoneStrings.compactMap { UUID(uuidString: $0) })
        
        // Merge remote tombstones into local set
        deletedProfileIds.formUnion(remoteTombstones)
        
        // Remove locally-held profiles that were deleted on another device
        var mergedProfiles = profiles.filter { !remoteTombstones.contains($0.id) }
        
        for iCloudProfile in iCloudProfiles {
            // Skip profiles that were deleted locally
            guard !deletedProfileIds.contains(iCloudProfile.id) else { continue }
            
            if let localIndex = mergedProfiles.firstIndex(where: { $0.id == iCloudProfile.id }) {
                // Profile exists locally - use the one with more recent activity
                let localProfile = mergedProfiles[localIndex]
                let localDate = localProfile.lastConnectedAt ?? localProfile.createdAt
                let iCloudDate = iCloudProfile.lastConnectedAt ?? iCloudProfile.createdAt
                
                if iCloudDate > localDate {
                    mergedProfiles[localIndex] = iCloudProfile
                }
            } else {
                // New profile from iCloud
                mergedProfiles.append(iCloudProfile)
            }
        }
        
        profiles = mergedProfiles
        saveDeletedProfileIds()
        saveProfiles()
    }
    
    /// Force sync with iCloud (pull then push)
    func forceiCloudSync() {
        guard iCloudSyncEnabled else { return }
        
        iCloudStore.synchronize()
        mergeFromiCloud()
    }
    
    // NOTE: File Provider integration has been archived (Jan 2026)
    // See FILE_PROVIDER_LEARNINGS.md and branch archive/file-provider-jan-2026
    // The enableFilesIntegration property on ConnectionProfile is retained but unused.
}
