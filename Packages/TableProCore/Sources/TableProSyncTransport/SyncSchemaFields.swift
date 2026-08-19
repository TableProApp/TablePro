import Foundation

public enum ConnectionGroupSyncField: String, SyncSchemaField {
    case groupId
    case name
    case color
    case parentId
    case sortOrder
    case modifiedAtLocal
    case schemaVersion

    public static let verifiedInProduction: Set<Self> = [
        .groupId, .name, .color, .parentId, .sortOrder, .modifiedAtLocal, .schemaVersion
    ]
}

public enum ConnectionTagSyncField: String, SyncSchemaField {
    case tagId
    case name
    case color
    case isPreset
    case modifiedAtLocal
    case schemaVersion

    public static let verifiedInProduction: Set<Self> = [
        .tagId, .name, .color, .isPreset, .modifiedAtLocal, .schemaVersion
    ]
}

public enum AppSettingsSyncField: String, SyncSchemaField {
    case category
    case settingsJson
    case modifiedAtLocal
    case schemaVersion

    public static let verifiedInProduction: Set<Self> = [
        .category, .settingsJson, .modifiedAtLocal, .schemaVersion
    ]
}

public enum FavoriteTableSyncField: String, SyncSchemaField {
    case connectionId
    case name
    case database
    case schema
    case modifiedAtLocal
    case schemaVersion

    public static let verifiedInProduction: Set<Self> = [
        .connectionId, .name, .database, .schema, .modifiedAtLocal, .schemaVersion
    ]
}

public enum SQLFavoriteSyncField: String, SyncSchemaField {
    case favoriteId
    case name
    case query
    case keyword
    case folderId
    case connectionId
    case sortOrder
    case createdAt
    case updatedAt
    case modifiedAtLocal
    case schemaVersion

    public static let verifiedInProduction: Set<Self> = [
        .favoriteId, .name, .query, .keyword, .folderId, .connectionId,
        .sortOrder, .createdAt, .updatedAt, .modifiedAtLocal, .schemaVersion
    ]
}

public enum SQLFavoriteFolderSyncField: String, SyncSchemaField {
    case folderId
    case name
    case parentId
    case connectionId
    case sortOrder
    case createdAt
    case updatedAt
    case modifiedAtLocal
    case schemaVersion

    public static let verifiedInProduction: Set<Self> = [
        .folderId, .name, .parentId, .connectionId,
        .sortOrder, .createdAt, .updatedAt, .modifiedAtLocal, .schemaVersion
    ]
}

public enum SSHProfileSyncField: String, SyncSchemaField {
    case profileId
    case name
    case host
    case port
    case username
    case authMethod
    case privateKeyPath
    case agentSocketPath
    case jumpHostsJson
    case totpMode
    case totpAlgorithm
    case totpDigits
    case totpPeriod
    case modifiedAtLocal
    case schemaVersion

    public static let verifiedInProduction: Set<Self> = [
        .profileId, .name, .host, .port, .username, .authMethod,
        .privateKeyPath, .agentSocketPath, .jumpHostsJson,
        .totpMode, .totpAlgorithm, .totpDigits, .totpPeriod,
        .modifiedAtLocal, .schemaVersion
    ]
}
