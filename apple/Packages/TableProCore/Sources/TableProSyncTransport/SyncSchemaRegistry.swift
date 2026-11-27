import CloudKit
import Foundation

public extension SyncRecordType {
    static let verifiedInProduction: Set<SyncRecordType> = [
        .connection, .group, .tag, .settings,
        .favorite, .favoriteFolder, .tableFavorite, .sshProfile, .credentialProfile,
        .favoriteDatabase, .tableFolder, .tableFolderItem
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
        case .favoriteDatabase: return FavoriteDatabaseSyncField.declaredKeys
        case .sshProfile: return SSHProfileSyncField.declaredKeys
        case .credentialProfile: return CredentialProfileSyncField.declaredKeys
        case .tableFolder: return TableFolderSyncField.declaredKeys
        case .tableFolderItem: return TableFolderItemSyncField.declaredKeys
        case .project: return ConnectionProjectSyncField.declaredKeys
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
        case .favoriteDatabase: return FavoriteDatabaseSyncField.writableKeys
        case .sshProfile: return SSHProfileSyncField.writableKeys
        case .credentialProfile: return CredentialProfileSyncField.writableKeys
        case .tableFolder: return TableFolderSyncField.writableKeys
        case .tableFolderItem: return TableFolderItemSyncField.writableKeys
        case .project: return ConnectionProjectSyncField.writableKeys
        }
    }
}

// The record types and fields a push may write. A coordinator and its mappers take one, so a test can stand in
// a schema Production does not hold yet.
public struct SyncWritableSchema: Sendable {
    private let writesField: @Sendable (any SyncSchemaField) -> Bool
    private let writesType: @Sendable (SyncRecordType) -> Bool

    public init(
        field: @escaping @Sendable (any SyncSchemaField) -> Bool,
        type: @escaping @Sendable (SyncRecordType) -> Bool
    ) {
        writesField = field
        writesType = type
    }

    public static let production = SyncWritableSchema(field: { $0.isWritable }, type: { $0.isWritable })

    public func writes(_ field: some SyncSchemaField) -> Bool {
        writesField(field)
    }

    public func writes(_ type: SyncRecordType) -> Bool {
        writesType(type)
    }

    public var writableTypes: Set<SyncRecordType> {
        Set(SyncRecordType.allCases.filter(writesType))
    }

    // False until the project type and both membership fields are writable. While it is false a pull carries
    // no membership, so each device keeps its own.
    public var writesProjects: Bool {
        writes(SyncRecordType.project)
            && writes(ConnectionSyncField.projectId)
            && writes(ConnectionGroupSyncField.projectId)
    }
}

public enum SyncSchemaGate {
    public static var isProjectSyncWritable: Bool {
        SyncWritableSchema.production.writesProjects
    }

    // Named only while a pull reads membership: a pull that leaves the field out still moves the token past
    // it, so the first pull that reads it must see the set grow and fetch the zone once.
    public static func membershipContentKinds(
        readsProjects: Bool,
        connections: Bool = true,
        groups: Bool = true
    ) -> Set<String> {
        guard readsProjects else { return [] }
        var kinds: Set<String> = []
        if connections { kinds.insert(ConnectionSyncField.projectContentKind) }
        if groups { kinds.insert(ConnectionGroupSyncField.projectContentKind) }
        return kinds
    }

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
