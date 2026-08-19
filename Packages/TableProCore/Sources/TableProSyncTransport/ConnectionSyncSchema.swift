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
    case isFavorite
    case modifiedAtLocal
    case schemaVersion

    public static let verifiedInProduction: Set<Self> = [
        .connectionId, .name, .host, .port, .database, .username, .type,
        .color, .colorTag, .safeModeLevel, .sortOrder, .groupId, .tagId, .tagIds,
        .isReadOnly, .sshEnabled, .sslEnabled, .queryTimeoutSeconds,
        .sshConfigJson, .sslConfigJson, .additionalFieldsJson,
        .aiPolicy, .aiRules, .aiAlwaysAllowedTools, .redisDatabase, .startupCommands,
        .sshProfileId, .isFavorite, .modifiedAtLocal, .schemaVersion
    ]
}
