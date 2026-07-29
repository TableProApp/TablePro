import CloudKit
import Foundation
import os

import TableProModels

public enum SyncRecordMapper {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SyncRecordMapper")
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    private static let schemaVersion: Int64 = 1

    // MARK: - Record Name Helpers

    public static func recordID(type: SyncRecordType, id: String, in zone: CKRecordZone.ID) -> CKRecord.ID {
        let recordName: String
        switch type {
        case .connection: recordName = "Connection_\(id)"
        case .group: recordName = "Group_\(id)"
        case .tag: recordName = "Tag_\(id)"
        }
        return CKRecord.ID(recordName: recordName, zoneID: zone)
    }

    // MARK: - Connection -> CKRecord

    public static func toRecord(_ connection: DatabaseConnection, zoneID: CKRecordZone.ID) -> CKRecord {
        let id = recordID(type: .connection, id: connection.id.uuidString, in: zoneID)
        let record = CKRecord(recordType: SyncRecordType.connection.rawValue, recordID: id)

        record["connectionId"] = connection.id.uuidString as CKRecordValue
        record["name"] = connection.name as CKRecordValue
        record["host"] = connection.host as CKRecordValue
        record["port"] = Int64(connection.port) as CKRecordValue
        record["database"] = connection.database as CKRecordValue
        record["username"] = connection.username as CKRecordValue
        record["type"] = connection.type.rawValue as CKRecordValue
        record["sortOrder"] = Int64(connection.sortOrder) as CKRecordValue
        record["isReadOnly"] = Int64(connection.isReadOnly ? 1 : 0) as CKRecordValue
        record["safeModeLevel"] = connection.safeModeLevel.rawValue as CKRecordValue
        record["sshEnabled"] = Int64(connection.sshEnabled ? 1 : 0) as CKRecordValue
        record["sslEnabled"] = Int64(connection.sslEnabled ? 1 : 0) as CKRecordValue

        if let colorTag = connection.colorTag {
            record["color"] = colorTag as CKRecordValue
            record["colorTag"] = colorTag as CKRecordValue
        }
        if let groupId = connection.groupId {
            record["groupId"] = groupId.uuidString as CKRecordValue
        }
        if !connection.tagIds.isEmpty {
            let tagIdStrings = connection.tagIds.map { $0.uuidString }
            record["tagIds"] = tagIdStrings as CKRecordValue
            record["tagId"] = tagIdStrings[0] as CKRecordValue
        }
        if let queryTimeout = connection.queryTimeoutSeconds {
            record["queryTimeoutSeconds"] = Int64(queryTimeout) as CKRecordValue
        }

        if let sshConfig = connection.sshConfiguration {
            do {
                var syncSafe = sshConfig
                syncSafe.privateKeyData = nil
                let data = try encoder.encode(syncSafe)
                record["sshConfigJson"] = data as CKRecordValue
            } catch {
                logger.warning("Failed to encode SSH config for sync: \(error.localizedDescription)")
            }
        }

        if let sslConfig = connection.sslConfiguration {
            do {
                let data = try encoder.encode(sslConfig)
                record["sslConfigJson"] = data as CKRecordValue
            } catch {
                logger.warning("Failed to encode SSL config for sync: \(error.localizedDescription)")
            }
        }

        if !connection.additionalFields.isEmpty {
            do {
                let data = try encoder.encode(connection.additionalFields)
                record["additionalFieldsJson"] = data as CKRecordValue
            } catch {
                logger.warning("Failed to encode additional fields for sync: \(error.localizedDescription)")
            }
        }

        record["modifiedAtLocal"] = Date() as CKRecordValue
        record["schemaVersion"] = schemaVersion as CKRecordValue

        return record
    }

    // MARK: - CKRecord -> Connection

    public static func toConnection(_ record: CKRecord) -> DatabaseConnection? {
        guard let idString = record["connectionId"] as? String,
              let id = UUID(uuidString: idString),
              let name = record["name"] as? String,
              let typeRaw = record["type"] as? String
        else {
            logger.warning("Failed to decode connection from CKRecord: missing required fields")
            return nil
        }

        let host = record["host"] as? String ?? "127.0.0.1"
        let port = (record["port"] as? Int64).map { Int($0) } ?? 3306
        let database = record["database"] as? String ?? ""
        let username = record["username"] as? String ?? ""
        let colorTag = record["color"] as? String ?? record["colorTag"] as? String
        let groupId = (record["groupId"] as? String).flatMap { UUID(uuidString: $0) }
        let tagIds: [UUID]
        if let rawIds = record["tagIds"] as? [String], !rawIds.isEmpty {
            tagIds = rawIds.compactMap { UUID(uuidString: $0) }
        } else if let single = (record["tagId"] as? String).flatMap({ UUID(uuidString: $0) }) {
            tagIds = [single]
        } else {
            tagIds = []
        }
        let sortOrder = (record["sortOrder"] as? Int64).map { Int($0) } ?? 0
        let isReadOnly = (record["isReadOnly"] as? Int64 ?? 0) != 0
        let safeModeLevel = safeModeLevel(fromWire: record["safeModeLevel"] as? String, isReadOnly: isReadOnly)
        let queryTimeout = (record["queryTimeoutSeconds"] as? Int64).map { Int($0) }
        var sshConfig: SSHConfiguration?
        if let sshData = record["sshConfigJson"] as? Data {
            sshConfig = try? decoder.decode(SSHConfiguration.self, from: sshData)
        }

        // macOS stores SSH enabled inside sshConfigJson ("enabled" field),
        // not as a top-level CKRecord field. Fall back to checking the JSON.
        let sshEnabled: Bool
        if let explicit = record["sshEnabled"] as? Int64 {
            sshEnabled = explicit != 0
        } else if let sshData = record["sshConfigJson"] as? Data,
                  let json = try? JSONSerialization.jsonObject(with: sshData) as? [String: Any] {
            sshEnabled = json["enabled"] as? Bool ?? (sshConfig != nil && !(sshConfig?.host.isEmpty ?? true))
        } else {
            sshEnabled = false
        }

        let sslEnabled = (record["sslEnabled"] as? Int64 ?? 0) != 0

        var sslConfig: SSLConfiguration?
        if let sslData = record["sslConfigJson"] as? Data {
            sslConfig = try? decoder.decode(SSLConfiguration.self, from: sslData)
        }

        var additionalFields: [String: String] = [:]
        if let fieldsData = record["additionalFieldsJson"] as? Data {
            additionalFields = (try? decoder.decode([String: String].self, from: fieldsData)) ?? [:]
        }

        return DatabaseConnection(
            id: id,
            name: name,
            type: DatabaseType(rawValue: typeRaw),
            host: host,
            port: port,
            username: username,
            database: database,
            colorTag: colorTag,
            isReadOnly: isReadOnly,
            safeModeLevel: safeModeLevel,
            queryTimeoutSeconds: queryTimeout,
            additionalFields: additionalFields,
            sshEnabled: sshEnabled,
            sshConfiguration: sshConfig,
            sslEnabled: sslEnabled,
            sslConfiguration: sslConfig,
            groupId: groupId,
            tagIds: tagIds,
            sortOrder: sortOrder
        )
    }

    private static func safeModeLevel(fromWire raw: String?, isReadOnly: Bool) -> SafeModeLevel {
        guard let raw else { return isReadOnly ? .readOnly : .off }
        if let level = SafeModeLevel(rawValue: raw) { return level }
        switch raw {
        case "silent": return .off
        case "alert", "alertFull", "safeMode", "safeModeFull": return .confirmWrites
        default: return isReadOnly ? .readOnly : .off
        }
    }

    // MARK: - Update Existing CKRecord (preserves macOS-only fields)

    public static func updateRecord(_ record: CKRecord, with connection: DatabaseConnection) {
        record["connectionId"] = connection.id.uuidString as CKRecordValue
        record["name"] = connection.name as CKRecordValue
        record["host"] = connection.host as CKRecordValue
        record["port"] = Int64(connection.port) as CKRecordValue
        record["database"] = connection.database as CKRecordValue
        record["username"] = connection.username as CKRecordValue
        record["type"] = connection.type.rawValue as CKRecordValue
        record["sortOrder"] = Int64(connection.sortOrder) as CKRecordValue
        record["isReadOnly"] = Int64(connection.isReadOnly ? 1 : 0) as CKRecordValue
        record["safeModeLevel"] = connection.safeModeLevel.rawValue as CKRecordValue
        record["sshEnabled"] = Int64(connection.sshEnabled ? 1 : 0) as CKRecordValue
        record["sslEnabled"] = Int64(connection.sslEnabled ? 1 : 0) as CKRecordValue

        if let colorTag = connection.colorTag {
            record["color"] = colorTag as CKRecordValue
            record["colorTag"] = colorTag as CKRecordValue
        } else {
            record["color"] = nil
            record["colorTag"] = nil
        }

        if let groupId = connection.groupId {
            record["groupId"] = groupId.uuidString as CKRecordValue
        } else {
            record["groupId"] = nil
        }

        if !connection.tagIds.isEmpty {
            let tagIdStrings = connection.tagIds.map { $0.uuidString }
            record["tagIds"] = tagIdStrings as CKRecordValue
            record["tagId"] = tagIdStrings[0] as CKRecordValue
        } else {
            record["tagIds"] = nil
            record["tagId"] = nil
        }

        if let queryTimeout = connection.queryTimeoutSeconds {
            record["queryTimeoutSeconds"] = Int64(queryTimeout) as CKRecordValue
        } else {
            record["queryTimeoutSeconds"] = nil
        }

        if let sshConfig = connection.sshConfiguration {
            var syncSafe = sshConfig
            syncSafe.privateKeyData = nil
            if let data = try? encoder.encode(syncSafe) {
                record["sshConfigJson"] = data as CKRecordValue
            }
        } else {
            record["sshConfigJson"] = nil
        }

        if let sslConfig = connection.sslConfiguration {
            if let data = try? encoder.encode(sslConfig) {
                record["sslConfigJson"] = data as CKRecordValue
            }
        } else {
            record["sslConfigJson"] = nil
        }

        if !connection.additionalFields.isEmpty {
            if let data = try? encoder.encode(connection.additionalFields) {
                record["additionalFieldsJson"] = data as CKRecordValue
            }
        } else {
            record["additionalFieldsJson"] = nil
        }

        record["modifiedAtLocal"] = Date() as CKRecordValue
    }

    // MARK: - Group -> CKRecord

    public static func toRecord(_ group: ConnectionGroup, zoneID: CKRecordZone.ID) -> CKRecord {
        let id = recordID(type: .group, id: group.id.uuidString, in: zoneID)
        let record = CKRecord(recordType: SyncRecordType.group.rawValue, recordID: id)

        record["groupId"] = group.id.uuidString as CKRecordValue
        record["name"] = group.name as CKRecordValue
        record["color"] = group.color.rawValue as CKRecordValue
        if let parentId = group.parentId {
            record["parentId"] = parentId.uuidString as CKRecordValue
        }
        record["sortOrder"] = Int64(group.sortOrder) as CKRecordValue
        record["modifiedAtLocal"] = Date() as CKRecordValue
        record["schemaVersion"] = schemaVersion as CKRecordValue

        return record
    }

    // MARK: - CKRecord -> Group

    public static func toGroup(_ record: CKRecord) -> ConnectionGroup? {
        guard let idStr = record["groupId"] as? String,
              let id = UUID(uuidString: idStr),
              let name = record["name"] as? String
        else {
            logger.warning("Failed to decode group from CKRecord: missing required fields")
            return nil
        }

        let sortOrder = (record["sortOrder"] as? Int64).map { Int($0) } ?? 0
        let color = (record["color"] as? String).flatMap { ConnectionColor(rawValue: $0) } ?? .none
        let parentId = (record["parentId"] as? String).flatMap { UUID(uuidString: $0) }

        return ConnectionGroup(id: id, name: name, sortOrder: sortOrder, color: color, parentId: parentId)
    }

    // MARK: - Update Existing CKRecord with Group

    public static func updateRecord(_ record: CKRecord, with group: ConnectionGroup) {
        record["groupId"] = group.id.uuidString as CKRecordValue
        record["name"] = group.name as CKRecordValue
        record["color"] = group.color.rawValue as CKRecordValue
        if let parentId = group.parentId {
            record["parentId"] = parentId.uuidString as CKRecordValue
        } else {
            record["parentId"] = nil
        }
        record["sortOrder"] = Int64(group.sortOrder) as CKRecordValue
        record["modifiedAtLocal"] = Date() as CKRecordValue
    }

    // MARK: - Tag -> CKRecord

    public static func toRecord(_ tag: ConnectionTag, zoneID: CKRecordZone.ID) -> CKRecord {
        let id = recordID(type: .tag, id: tag.id.uuidString, in: zoneID)
        let record = CKRecord(recordType: SyncRecordType.tag.rawValue, recordID: id)

        record["tagId"] = tag.id.uuidString as CKRecordValue
        record["name"] = tag.name as CKRecordValue
        record["isPreset"] = Int64(tag.isPreset ? 1 : 0) as CKRecordValue
        record["color"] = tag.color.rawValue as CKRecordValue
        record["modifiedAtLocal"] = Date() as CKRecordValue
        record["schemaVersion"] = schemaVersion as CKRecordValue

        return record
    }

    // MARK: - CKRecord -> Tag

    public static func toTag(_ record: CKRecord) -> ConnectionTag? {
        guard let tagIdStr = record["tagId"] as? String,
              let tagId = UUID(uuidString: tagIdStr),
              let name = record["name"] as? String
        else {
            logger.warning("Failed to decode tag from CKRecord: missing required fields")
            return nil
        }

        let isPreset = (record["isPreset"] as? Int64 ?? 0) != 0
        let color = (record["color"] as? String).flatMap { ConnectionColor(rawValue: $0) } ?? .gray

        return ConnectionTag(id: tagId, name: name, isPreset: isPreset, color: color)
    }

    // MARK: - Update Existing CKRecord with Tag

    public static func updateRecord(_ record: CKRecord, with tag: ConnectionTag) {
        record["tagId"] = tag.id.uuidString as CKRecordValue
        record["name"] = tag.name as CKRecordValue
        record["isPreset"] = Int64(tag.isPreset ? 1 : 0) as CKRecordValue
        record["color"] = tag.color.rawValue as CKRecordValue
        record["modifiedAtLocal"] = Date() as CKRecordValue
    }
}
