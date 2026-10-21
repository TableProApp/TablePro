import Foundation

public enum ConnectionSyncField: String, SyncSchemaField {
    case connectionId
    case name
    case host
    case port
    case database
    case username
    case type
    case color
    case colorTag
    case iconName
    case safeModeLevel
    case sortOrder
    case groupId
    case tagId
    case tagIds
    case isReadOnly
    case sshEnabled
    case sslEnabled
    case queryTimeoutSeconds
    case sshConfigJson
    case sslConfigJson
    case additionalFieldsJson
    case aiPolicy
    case aiRules
    case aiAlwaysAllowedTools
    case redisDatabase
    case startupCommands
    case sshProfileId
    case sshRouteJson
    case isFavorite
    case modifiedAtLocal
    case schemaVersion

    public static let verifiedInProduction: Set<Self> = [
        .connectionId, .name, .host, .port, .database, .username, .type,
        .color, .colorTag, .iconName, .safeModeLevel, .sortOrder, .groupId, .tagId, .tagIds,
        .isReadOnly, .sshEnabled, .sslEnabled, .queryTimeoutSeconds,
        .sshConfigJson, .sslConfigJson, .additionalFieldsJson,
        .aiPolicy, .aiRules, .aiAlwaysAllowedTools, .redisDatabase, .startupCommands,
        .sshProfileId, .sshRouteJson, .isFavorite, .modifiedAtLocal, .schemaVersion
    ]
}

public extension ConnectionSyncField {
    // In each app's readable content, so the first pull on this build fetches everything once and
    // reads the routes an older build cached without reading them.
    static let sshRouteContentKind = "\(SyncRecordType.connection.rawValue)/\(Self.sshRouteJson.rawValue).v1"
}
