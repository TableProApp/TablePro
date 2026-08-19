import CloudKit
import Foundation

public extension SyncRecordType {
    static let verifiedInProduction: Set<SyncRecordType> = [
        .connection, .group, .tag, .settings,
        .favorite, .favoriteFolder, .tableFavorite, .sshProfile
    ]

    var productionSchemaState: ProductionSchemaState {
        Self.verifiedInProduction.contains(self) ? .verified : .unverified
    }

    var isWritable: Bool { productionSchemaState == .verified }

    var declaredFieldKeys: Set<String> {
        switch self {
        case .connection: return ConnectionSyncField.declaredKeys
        case .group: return ConnectionGroupSyncField.declaredKeys
        case .tag: return ConnectionTagSyncField.declaredKeys
        case .settings: return AppSettingsSyncField.declaredKeys
        case .favorite: return SQLFavoriteSyncField.declaredKeys
        case .favoriteFolder: return SQLFavoriteFolderSyncField.declaredKeys
        case .tableFavorite: return FavoriteTableSyncField.declaredKeys
        case .sshProfile: return SSHProfileSyncField.declaredKeys
        }
    }

    var writableFieldKeys: Set<String> {
        switch self {
        case .connection: return ConnectionSyncField.writableKeys
        case .group: return ConnectionGroupSyncField.writableKeys
        case .tag: return ConnectionTagSyncField.writableKeys
        case .settings: return AppSettingsSyncField.writableKeys
        case .favorite: return SQLFavoriteSyncField.writableKeys
        case .favoriteFolder: return SQLFavoriteFolderSyncField.writableKeys
        case .tableFavorite: return FavoriteTableSyncField.writableKeys
        case .sshProfile: return SSHProfileSyncField.writableKeys
        }
    }
}

public enum SyncSchemaGate {
    public static func publishable(records: [CKRecord]) -> [CKRecord] {
        records.filter { SyncRecordType(rawValue: $0.recordType)?.isWritable ?? false }
    }

    public static func publishable(deletions: [CKRecord.ID]) -> [CKRecord.ID] {
        deletions.filter { SyncRecordType.parse(recordName: $0.recordName)?.type.isWritable ?? false }
    }

    public static func withheldRecordTypes(in records: [CKRecord]) -> Set<String> {
        Set(records.map(\.recordType).filter { SyncRecordType(rawValue: $0)?.isWritable != true })
    }
}
