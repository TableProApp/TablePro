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
        let fallback = Self.default
        enabled = container.decodeSetting(.enabled, default: fallback.enabled)
        syncConnections = container.decodeSetting(.syncConnections, default: fallback.syncConnections)
        syncGroupsAndTags = container.decodeSetting(.syncGroupsAndTags, default: fallback.syncGroupsAndTags)
        syncSettings = container.decodeSetting(.syncSettings, default: fallback.syncSettings)
        syncPasswords = container.decodeSetting(.syncPasswords, default: fallback.syncPasswords)
        syncSSHProfiles = container.decodeSetting(.syncSSHProfiles, default: fallback.syncSSHProfiles)
        syncCredentialProfiles = container.decodeSetting(.syncCredentialProfiles, default: fallback.syncCredentialProfiles)
        syncTableFavorites = container.decodeSetting(.syncTableFavorites, default: fallback.syncTableFavorites)
        syncDatabaseFavorites = container.decodeSetting(.syncDatabaseFavorites, default: fallback.syncDatabaseFavorites)
        syncSQLFavorites = container.decodeSetting(.syncSQLFavorites, default: fallback.syncSQLFavorites)
        syncTableFolders = container.decodeSetting(.syncTableFolders, default: fallback.syncTableFolders)
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
