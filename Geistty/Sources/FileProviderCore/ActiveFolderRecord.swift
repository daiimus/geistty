//
//  ActiveFolderRecord.swift
//  Geistty
//
//  SwiftData model for tracking active folders that need polling.
//  These are folders the user has browsed that we should check for changes.
//

import Foundation
import SwiftData

/// An active folder that should be polled for changes
@Model
final class ActiveFolderRecord {
    
    /// Unique identifier: "conn:<connectionId>:path:<remotePath>"
    @Attribute(.unique)
    var folderIdentifier: String
    
    /// Connection profile ID
    var connectionId: String
    
    /// Remote path on the server
    var remotePath: String
    
    /// When this folder was last accessed
    var lastAccessed: Date
    
    /// When this folder was registered as active
    var registeredAt: Date
    
    init(connectionId: String, remotePath: String) {
        self.folderIdentifier = "conn:\(connectionId):path:\(remotePath)"
        self.connectionId = connectionId
        self.remotePath = remotePath
        self.lastAccessed = Date()
        self.registeredAt = Date()
    }
    
    /// Update last accessed time
    func touch() {
        lastAccessed = Date()
    }
}

// MARK: - Hashable

extension ActiveFolderRecord: Hashable {
    static func == (lhs: ActiveFolderRecord, rhs: ActiveFolderRecord) -> Bool {
        lhs.folderIdentifier == rhs.folderIdentifier
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(folderIdentifier)
    }
}

// MARK: - Debugging

extension ActiveFolderRecord: CustomStringConvertible {
    var description: String {
        "ActiveFolder(\(remotePath) @ \(connectionId))"
    }
}
