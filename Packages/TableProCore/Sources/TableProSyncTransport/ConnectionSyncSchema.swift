import CloudKit
import Foundation

public enum ProductionSchemaState: Sendable {
    case verified
    case unverified
}

public enum ConnectionSyncField: String, CaseIterable, Sendable {
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

    public var key: String { rawValue }

    public var productionSchemaState: ProductionSchemaState {
        switch self {
        case .connectionId, .name, .host, .port, .database, .username, .type,
             .color, .colorTag, .safeModeLevel, .sortOrder, .groupId, .tagId,
             .isReadOnly, .sshEnabled, .sslEnabled,
             .sshConfigJson, .sslConfigJson, .additionalFieldsJson,
             .aiPolicy, .redisDatabase, .startupCommands, .sshProfileId,
             .modifiedAtLocal, .schemaVersion:
            return .verified
        default:
            return .unverified
        }
    }

    public var isWritable: Bool { productionSchemaState == .verified }

    public static var writableKeys: Set<String> {
        Set(allCases.filter(\.isWritable).map(\.key))
    }

    public static var declaredKeys: Set<String> {
        Set(allCases.map(\.key))
    }
}

public extension CKRecord {
    subscript(field: ConnectionSyncField) -> Any? {
        get { self[field.key] }
        set {
            guard field.isWritable else { return }
            self[field.key] = newValue as? any CKRecordValueProtocol
        }
    }
}
