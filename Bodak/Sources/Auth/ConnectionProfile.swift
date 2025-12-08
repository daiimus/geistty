//
//  ConnectionProfile.swift
//  Bodak
//
//  Model for saved SSH connection profiles
//

import Foundation
import SwiftUI

/// Authentication method for SSH connections
enum AuthMethod: String, Codable, CaseIterable, Identifiable {
    case password = "password"
    case sshKey = "ssh_key"
    case passwordManager = "password_manager"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .password: return "Password"
        case .sshKey: return "SSH Key"
        case .passwordManager: return "Password Manager"
        }
    }
    
    var icon: String {
        switch self {
        case .password: return "key.fill"
        case .sshKey: return "lock.shield.fill"
        case .passwordManager: return "lock.rectangle.stack.fill"
        }
    }
}

/// Password manager provider
enum PasswordManagerProvider: String, Codable, CaseIterable, Identifiable {
    case icloudKeychain = "icloud_keychain"
    case onePassword = "1password"
    case lastPass = "lastpass"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .icloudKeychain: return "iCloud Keychain"
        case .onePassword: return "1Password"
        case .lastPass: return "LastPass"
        }
    }
    
    var icon: String {
        switch self {
        case .icloudKeychain: return "icloud.fill"
        case .onePassword: return "1.circle.fill"
        case .lastPass: return "l.circle.fill"
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
    
    // For password manager
    var passwordManagerProvider: PasswordManagerProvider?
    
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
        authMethod: AuthMethod = .password,
        sshKeyName: String? = nil,
        passwordManagerProvider: PasswordManagerProvider? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.sshKeyName = sshKeyName
        self.passwordManagerProvider = passwordManagerProvider
        self.createdAt = Date()
        self.lastConnectedAt = nil
        self.isFavorite = false
        self.colorTag = nil
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

/// Manages saved connection profiles
class ConnectionProfileManager: ObservableObject {
    
    /// Shared instance
    static let shared = ConnectionProfileManager()
    
    /// Published list of profiles
    @Published var profiles: [ConnectionProfile] = []
    
    /// Storage key
    private let storageKey = "connection_profiles"
    
    private init() {
        loadProfiles()
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
        saveProfiles()
    }
    
    /// Delete profiles by ID
    func deleteProfiles(at offsets: IndexSet) {
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
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ConnectionProfile].self, from: data) else {
            profiles = []
            return
        }
        profiles = decoded
    }
    
    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
    
    // MARK: - iCloud Sync (placeholder for future implementation)
    
    /// Enable iCloud sync for profiles
    func enableiCloudSync() {
        // TODO: Implement using NSUbiquitousKeyValueStore or CloudKit
    }
}
