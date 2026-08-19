import CloudKit
import Foundation
import os

import TableProModels
import TableProSyncTransport

public enum SyncRecordMapper {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SyncRecordMapper")
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    private static let schemaVersion: Int64 = 1

    // MARK: - Record Name Helpers

    public static func recordID(type: SyncRecordType, id: String, in zone: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: type.recordName(for: id), zoneID: zone)
    }

    public static func parse(recordName: String) -> (type: SyncRecordType, id: String)? {
        SyncRecordType.parse(recordName: recordName)
    }

    // MARK: - Connection -> CKRecord

    public static func toRecord(_ connection: DatabaseConnection, zoneID: CKRecordZone.ID) -> CKRecord {
        let id = recordID(type: .connection, id: connection.id.uuidString, in: zoneID)
        let record = CKRecord(recordType: SyncRecordType.connection.rawValue, recordID: id)
        let fields = record.fields(ConnectionSyncField.self)

        fields[.connectionId] = connection.id.uuidString as CKRecordValue
        fields[.name] = connection.name as CKRecordValue
        fields[.host] = connection.host as CKRecordValue
        fields[.port] = Int64(connection.port) as CKRecordValue
        fields[.database] = connection.database as CKRecordValue
        fields[.username] = connection.username as CKRecordValue
        fields[.type] = connection.type.rawValue as CKRecordValue
        fields[.sortOrder] = Int64(connection.sortOrder) as CKRecordValue
        fields[.isReadOnly] = Int64(connection.isReadOnly ? 1 : 0) as CKRecordValue
        fields[.safeModeLevel] = connection.safeModeLevel.rawValue as CKRecordValue
        fields[.sshEnabled] = Int64(connection.sshEnabled ? 1 : 0) as CKRecordValue
        fields[.sslEnabled] = Int64(connection.sslEnabled ? 1 : 0) as CKRecordValue

        if let colorTag = connection.colorTag {
            fields[.colorTag] = colorTag as CKRecordValue
        }
        if let groupId = connection.groupId {
            fields[.groupId] = groupId.uuidString as CKRecordValue
        }
        if !connection.tagIds.isEmpty {
            let tagIdStrings = connection.tagIds.map { $0.uuidString }
            fields[.tagIds] = tagIdStrings as CKRecordValue
            fields[.tagId] = tagIdStrings[0] as CKRecordValue
        }
        if let queryTimeout = connection.queryTimeoutSeconds {
            fields[.queryTimeoutSeconds] = Int64(queryTimeout) as CKRecordValue
        }

        if let sshConfig = connection.sshConfiguration {
            do {
                var syncSafe = sshConfig
                syncSafe.privateKeyData = nil
                let data = try encoder.encode(syncSafe)
                fields[.sshConfigJson] = data as CKRecordValue
            } catch {
                logger.warning("Failed to encode SSH config for sync: \(error.localizedDescription)")
            }
        }

        if let sslConfig = connection.sslConfiguration {
            do {
                let data = try encoder.encode(sslConfig)
                fields[.sslConfigJson] = data as CKRecordValue
            } catch {
                logger.warning("Failed to encode SSL config for sync: \(error.localizedDescription)")
            }
        }

        if !connection.additionalFields.isEmpty {
            do {
                let data = try encoder.encode(connection.additionalFields)
                fields[.additionalFieldsJson] = data as CKRecordValue
            } catch {
                logger.warning("Failed to encode additional fields for sync: \(error.localizedDescription)")
            }
        }

        fields[.modifiedAtLocal] = Date() as CKRecordValue
        fields[.schemaVersion] = schemaVersion as CKRecordValue

        return record
    }

    // MARK: - CKRecord -> Connection

    public static func toConnection(_ record: CKRecord) -> DatabaseConnection? {
        let fields = record.fields(ConnectionSyncField.self)
        guard let idString = fields[.connectionId] as? String,
              let id = UUID(uuidString: idString),
              let name = fields[.name] as? String,
              let typeRaw = fields[.type] as? String
        else {
            logger.warning("Failed to decode connection from CKRecord: missing required fields")
            return nil
        }

        let host = fields[.host] as? String ?? "127.0.0.1"
        let port = (fields[.port] as? Int64).map { Int($0) } ?? 3306
        let database = fields[.database] as? String ?? ""
        let username = fields[.username] as? String ?? ""
        let colorTag = fields[.colorTag] as? String
        let groupId = (fields[.groupId] as? String).flatMap { UUID(uuidString: $0) }
        let tagIds: [UUID]
        if let rawIds = fields[.tagIds] as? [String], !rawIds.isEmpty {
            tagIds = rawIds.compactMap { UUID(uuidString: $0) }
        } else if let single = (fields[.tagId] as? String).flatMap({ UUID(uuidString: $0) }) {
            tagIds = [single]
        } else {
            tagIds = []
        }
        let sortOrder = (fields[.sortOrder] as? Int64).map { Int($0) } ?? 0
        let isReadOnly = (fields[.isReadOnly] as? Int64 ?? 0) != 0
        let safeModeLevel = safeModeLevel(fromWire: fields[.safeModeLevel] as? String, isReadOnly: isReadOnly)
        let queryTimeout = (fields[.queryTimeoutSeconds] as? Int64).map { Int($0) }
        var sshConfig: SSHConfiguration?
        if let sshData = fields[.sshConfigJson] as? Data {
            sshConfig = try? decoder.decode(SSHConfiguration.self, from: sshData)
        }

        // macOS stores SSH enabled inside sshConfigJson ("enabled" field),
        // not as a top-level CKRecord field. Fall back to checking the JSON.
        let sshEnabled: Bool
        if let explicit = fields[.sshEnabled] as? Int64 {
            sshEnabled = explicit != 0
        } else if let sshData = fields[.sshConfigJson] as? Data,
                  let json = try? JSONSerialization.jsonObject(with: sshData) as? [String: Any] {
            sshEnabled = json["enabled"] as? Bool ?? (sshConfig != nil && !(sshConfig?.host.isEmpty ?? true))
        } else {
            sshEnabled = false
        }

        let sslEnabled = (fields[.sslEnabled] as? Int64 ?? 0) != 0

        var sslConfig: SSLConfiguration?
        if let sslData = fields[.sslConfigJson] as? Data {
            sslConfig = try? decoder.decode(SSLConfiguration.self, from: sslData)
        }

        var additionalFields: [String: String] = [:]
        if let fieldsData = fields[.additionalFieldsJson] as? Data {
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
        let fields = record.fields(ConnectionSyncField.self)
        fields[.connectionId] = connection.id.uuidString as CKRecordValue
        fields[.name] = connection.name as CKRecordValue
        fields[.host] = connection.host as CKRecordValue
        fields[.port] = Int64(connection.port) as CKRecordValue
        fields[.database] = connection.database as CKRecordValue
        fields[.username] = connection.username as CKRecordValue
        fields[.type] = connection.type.rawValue as CKRecordValue
        fields[.sortOrder] = Int64(connection.sortOrder) as CKRecordValue
        fields[.isReadOnly] = Int64(connection.isReadOnly ? 1 : 0) as CKRecordValue
        fields[.safeModeLevel] = connection.safeModeLevel.rawValue as CKRecordValue
        fields[.sshEnabled] = Int64(connection.sshEnabled ? 1 : 0) as CKRecordValue
        fields[.sslEnabled] = Int64(connection.sslEnabled ? 1 : 0) as CKRecordValue
        fields[.colorTag] = connection.colorTag as CKRecordValue?
        fields[.groupId] = connection.groupId?.uuidString as CKRecordValue?

        if !connection.tagIds.isEmpty {
            let tagIdStrings = connection.tagIds.map { $0.uuidString }
            fields[.tagIds] = tagIdStrings as CKRecordValue
            fields[.tagId] = tagIdStrings[0] as CKRecordValue
        } else {
            fields[.tagIds] = nil
            fields[.tagId] = nil
        }

        fields[.queryTimeoutSeconds] = connection.queryTimeoutSeconds.map { Int64($0) } as CKRecordValue?

        if let sshConfig = connection.sshConfiguration {
            var syncSafe = sshConfig
            syncSafe.privateKeyData = nil
            if let data = try? encoder.encode(syncSafe) {
                fields[.sshConfigJson] = data as CKRecordValue
            }
        } else {
            fields[.sshConfigJson] = nil
        }

        if let sslConfig = connection.sslConfiguration {
            if let data = try? encoder.encode(sslConfig) {
                fields[.sslConfigJson] = data as CKRecordValue
            }
        } else {
            fields[.sslConfigJson] = nil
        }

        if !connection.additionalFields.isEmpty {
            if let data = try? encoder.encode(connection.additionalFields) {
                fields[.additionalFieldsJson] = data as CKRecordValue
            }
        } else {
            fields[.additionalFieldsJson] = nil
        }

        fields[.modifiedAtLocal] = Date() as CKRecordValue
    }

    // MARK: - Group -> CKRecord

    public static func toRecord(_ group: ConnectionGroup, zoneID: CKRecordZone.ID) -> CKRecord {
        let id = recordID(type: .group, id: group.id.uuidString, in: zoneID)
        let record = CKRecord(recordType: SyncRecordType.group.rawValue, recordID: id)

        let fields = record.fields(ConnectionGroupSyncField.self)
        fields[.groupId] = group.id.uuidString
        fields[.name] = group.name
        fields[.color] = group.color.rawValue
        if let parentId = group.parentId {
            fields[.parentId] = parentId.uuidString
        }
        fields[.sortOrder] = Int64(group.sortOrder)
        fields[.modifiedAtLocal] = Date()
        fields[.schemaVersion] = schemaVersion

        return record
    }

    // MARK: - CKRecord -> Group

    public static func toGroup(_ record: CKRecord) -> ConnectionGroup? {
        let fields = record.fields(ConnectionGroupSyncField.self)
        guard let idStr = fields[.groupId] as? String,
              let id = UUID(uuidString: idStr),
              let name = fields[.name] as? String
        else {
            logger.warning("Failed to decode group from CKRecord: missing required fields")
            return nil
        }

        let sortOrder = (fields[.sortOrder] as? Int64).map { Int($0) } ?? 0
        let color = (fields[.color] as? String).flatMap { ConnectionColor(rawValue: $0) } ?? .none
        let parentId = (fields[.parentId] as? String).flatMap { UUID(uuidString: $0) }

        return ConnectionGroup(id: id, name: name, sortOrder: sortOrder, color: color, parentId: parentId)
    }

    // MARK: - Update Existing CKRecord with Group

    public static func updateRecord(_ record: CKRecord, with group: ConnectionGroup) {
        let fields = record.fields(ConnectionGroupSyncField.self)
        fields[.groupId] = group.id.uuidString
        fields[.name] = group.name
        fields[.color] = group.color.rawValue
        fields[.parentId] = group.parentId?.uuidString
        fields[.sortOrder] = Int64(group.sortOrder)
        fields[.modifiedAtLocal] = Date()
    }

    // MARK: - Tag -> CKRecord

    public static func toRecord(_ tag: ConnectionTag, zoneID: CKRecordZone.ID) -> CKRecord {
        let id = recordID(type: .tag, id: tag.id.uuidString, in: zoneID)
        let record = CKRecord(recordType: SyncRecordType.tag.rawValue, recordID: id)

        let fields = record.fields(ConnectionTagSyncField.self)
        fields[.tagId] = tag.id.uuidString
        fields[.name] = tag.name
        fields[.isPreset] = Int64(tag.isPreset ? 1 : 0)
        fields[.color] = tag.color.rawValue
        fields[.modifiedAtLocal] = Date()
        fields[.schemaVersion] = schemaVersion

        return record
    }

    // MARK: - CKRecord -> Tag

    public static func toTag(_ record: CKRecord) -> ConnectionTag? {
        let fields = record.fields(ConnectionTagSyncField.self)
        guard let tagIdStr = fields[.tagId] as? String,
              let tagId = UUID(uuidString: tagIdStr),
              let name = fields[.name] as? String
        else {
            logger.warning("Failed to decode tag from CKRecord: missing required fields")
            return nil
        }

        let isPreset = (fields[.isPreset] as? Int64 ?? 0) != 0
        let color = (fields[.color] as? String).flatMap { ConnectionColor(rawValue: $0) } ?? .gray

        return ConnectionTag(id: tagId, name: name, isPreset: isPreset, color: color)
    }

    // MARK: - Update Existing CKRecord with Tag

    public static func updateRecord(_ record: CKRecord, with tag: ConnectionTag) {
        let fields = record.fields(ConnectionTagSyncField.self)
        fields[.tagId] = tag.id.uuidString
        fields[.name] = tag.name
        fields[.isPreset] = Int64(tag.isPreset ? 1 : 0)
        fields[.color] = tag.color.rawValue
        fields[.modifiedAtLocal] = Date()
    }
}
