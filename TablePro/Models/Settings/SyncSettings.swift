//
//  SyncSettings.swift
//  TablePro
//
//  User-configurable sync preferences
//

import Foundation
import TableProSyncTransport

/// User preferences for iCloud sync behavior
struct SyncSettings: Codable, Equatable {
    var enabled: Bool
    var syncConnections: Bool
    var syncGroupsAndTags: Bool
    var syncSettings: Bool
    var syncPasswords: Bool
    var syncSSHProfiles: Bool
    var syncCredentialProfiles: Bool
    var syncTableFavorites: Bool
    var syncDatabaseFavorites: Bool
    var syncSQLFavorites: Bool
    var syncTableFolders: Bool

    init(
        enabled: Bool,
        syncConnections: Bool,
        syncGroupsAndTags: Bool,
        syncSettings: Bool,
        syncPasswords: Bool = false,
        syncSSHProfiles: Bool = true,
        syncCredentialProfiles: Bool = true,
        syncTableFavorites: Bool = true,
        syncDatabaseFavorites: Bool = true,
        syncSQLFavorites: Bool = true,
        syncTableFolders: Bool = true
    ) {
        self.enabled = enabled
        self.syncConnections = syncConnections
        self.syncGroupsAndTags = syncGroupsAndTags
        self.syncSettings = syncSettings
        self.syncPasswords = syncPasswords
        self.syncSSHProfiles = syncSSHProfiles
        self.syncCredentialProfiles = syncCredentialProfiles
        self.syncTableFavorites = syncTableFavorites
        self.syncDatabaseFavorites = syncDatabaseFavorites
        self.syncSQLFavorites = syncSQLFavorites
        self.syncTableFolders = syncTableFolders
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        syncConnections = try container.decode(Bool.self, forKey: .syncConnections)
        syncGroupsAndTags = try container.decode(Bool.self, forKey: .syncGroupsAndTags)
        syncSettings = try container.decode(Bool.self, forKey: .syncSettings)
        syncPasswords = try container.decodeIfPresent(Bool.self, forKey: .syncPasswords) ?? false
        syncSSHProfiles = try container.decodeIfPresent(Bool.self, forKey: .syncSSHProfiles) ?? true
        syncCredentialProfiles = try container.decodeIfPresent(Bool.self, forKey: .syncCredentialProfiles) ?? true
        syncTableFavorites = try container.decodeIfPresent(Bool.self, forKey: .syncTableFavorites) ?? true
        syncDatabaseFavorites = try container.decodeIfPresent(Bool.self, forKey: .syncDatabaseFavorites) ?? true
        syncSQLFavorites = try container.decodeIfPresent(Bool.self, forKey: .syncSQLFavorites) ?? true
        syncTableFolders = try container.decodeIfPresent(Bool.self, forKey: .syncTableFolders) ?? true
    }

    static let `default` = SyncSettings(
        enabled: false,
        syncConnections: true,
        syncGroupsAndTags: true,
        syncSettings: true,
        syncPasswords: false,
        syncSSHProfiles: true,
        syncCredentialProfiles: true,
        syncTableFavorites: true,
        syncDatabaseFavorites: true,
        syncSQLFavorites: true,
        syncTableFolders: true
    )
}

internal extension SyncSettings {
    func syncs(_ type: SyncRecordType) -> Bool {
        switch type {
        case .connection: syncConnections
        case .group, .tag: syncGroupsAndTags
        case .settings: syncSettings
        case .sshProfile: syncSSHProfiles
        case .credentialProfile: syncCredentialProfiles
        case .tableFavorite: syncTableFavorites
        case .favoriteDatabase: syncDatabaseFavorites
        case .favorite, .favoriteFolder: syncSQLFavorites
        case .tableFolder, .tableFolderItem: syncTableFolders
        }
    }
}
