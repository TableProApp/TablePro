import Foundation
import TableProSyncTransport

// Which provider syncs this Mac's personal data (core ADR 0054, Providers), spelled as `PersonalSyncProvider` spells it.
internal enum SyncProviderSetting: String, Codable, CaseIterable, Sendable {
    case off
    case iCloud = "icloud"
    case tableproSync = "tablepro-sync"
}

struct SyncSettings: Codable, Equatable {
    var provider: SyncProviderSetting
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

    // iCloud on, as every earlier build reads it, so a build that predates the provider sees TablePro Sync as iCloud off.
    var enabled: Bool {
        get { provider == .iCloud }
        set {
            if newValue {
                provider = .iCloud
            } else if provider == .iCloud {
                provider = .off
            }
        }
    }

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
        self.provider = enabled ? .iCloud : .off
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

    private enum CodingKeys: String, CodingKey {
        case enabled, provider, syncConnections, syncGroupsAndTags, syncSettings, syncPasswords, syncSSHProfiles
        case syncCredentialProfiles, syncTableFavorites, syncDatabaseFavorites, syncSQLFavorites, syncTableFolders
    }

    // `enabled` wins over the provider: an earlier build that turned iCloud on wrote no provider, or kept a stale one.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.default
        let iCloud = container.decodeSetting(.enabled, default: fallback.enabled)
        let stored: SyncProviderSetting? = container.decodeSetting(.provider)
        provider = iCloud ? .iCloud : (stored == .tableproSync ? .tableproSync : .off)
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

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(provider, forKey: .provider)
        try container.encode(syncConnections, forKey: .syncConnections)
        try container.encode(syncGroupsAndTags, forKey: .syncGroupsAndTags)
        try container.encode(syncSettings, forKey: .syncSettings)
        try container.encode(syncPasswords, forKey: .syncPasswords)
        try container.encode(syncSSHProfiles, forKey: .syncSSHProfiles)
        try container.encode(syncCredentialProfiles, forKey: .syncCredentialProfiles)
        try container.encode(syncTableFavorites, forKey: .syncTableFavorites)
        try container.encode(syncDatabaseFavorites, forKey: .syncDatabaseFavorites)
        try container.encode(syncSQLFavorites, forKey: .syncSQLFavorites)
        try container.encode(syncTableFolders, forKey: .syncTableFolders)
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

    // Whether a secret saved now goes to iCloud Keychain.
    var syncsPasswords: Bool {
        enabled && syncConnections && syncPasswords
    }

    // Passwords ride on connection records, so turning Connections off turns them off in the same write.
    func settingConnections(_ on: Bool) -> SyncSettings {
        var copy = self
        copy.syncConnections = on
        if !on {
            copy.syncPasswords = false
        }
        return copy
    }
}

internal extension SyncSettings {
    func syncs(_ type: SyncRecordType) -> Bool {
        switch type {
        case .connection: syncConnections
        case .group, .tag, .project: syncGroupsAndTags
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
