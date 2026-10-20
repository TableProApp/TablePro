import CloudKit
import Foundation
import os

import TableProConnectionLibrary
import TableProModels
import TableProSyncTransport

public enum SyncRecordMapper {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SyncRecordMapper")
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    private static let schemaVersion: Int64 = 1

    // RedisDatabaseIndex.fieldName, which this module does not link.
    private static let redisDatabaseFieldKey = "redisDatabase"

    // MARK: - Record Name Helpers

    public static func recordID(type: SyncRecordType, id: String, in zone: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: type.recordName(for: id), zoneID: zone)
    }

    public static func parse(recordName: String) -> (type: SyncRecordType, id: String)? {
        SyncRecordType.parse(recordName: recordName)
    }

    // iOS wrote hex to `colorTag` before both apps converged on `color`.
    private static func color(from fields: SyncRecordFields<ConnectionSyncField>) -> ConnectionColor {
        if let stored = fields[.color] as? String {
            return ConnectionColor(storedValue: stored)
        }
        if let legacy = fields[.colorTag] as? String {
            return ConnectionColor(storedValue: legacy)
        }
        return .none
    }

    // MARK: - Connection -> CKRecord

    // Under `.changedKeys` only a named key reaches the server, so every field `updateRecord` would clear is named here too.
    public static func toRecord(_ connection: DatabaseConnection, zoneID: CKRecordZone.ID) -> CKRecord {
        let id = recordID(type: .connection, id: connection.id.uuidString, in: zoneID)
        let record = CKRecord(recordType: SyncRecordType.connection.rawValue, recordID: id)
        let fields = record.fields(ConnectionSyncField.self, absentValues: .clear)

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
        fields[.isFavorite] = Int64(connection.isFavorite ? 1 : 0) as CKRecordValue

        fields[.color] = connection.color.rawValue as CKRecordValue
        fields[.iconName] = LibrarySymbolCatalog.normalizedName(connection.iconName) as CKRecordValue?
        fields[.groupId] = connection.groupId?.uuidString as CKRecordValue?
        let tagIdStrings = connection.tagIds.map(\.uuidString)
        fields[.tagIds] = tagIdStrings.isEmpty ? nil : tagIdStrings as CKRecordValue
        fields[.tagId] = tagIdStrings.first as CKRecordValue?
        fields[.queryTimeoutSeconds] = validQueryTimeout(connection.queryTimeoutSeconds).map { Int64($0) } as CKRecordValue?

        if let sshConfig = macSSHConfiguration(of: connection) {
            do {
                let data = try encoder.encode(sshConfig)
                fields[.sshConfigJson] = data as CKRecordValue
            } catch {
                logger.warning("Failed to encode SSH config for sync: \(error.localizedDescription)")
            }
        } else {
            fields[.sshConfigJson] = nil
        }

        if let sslConfig = connection.sslConfiguration {
            do {
                let data = try encoder.encode(sslConfig)
                fields[.sslConfigJson] = data as CKRecordValue
            } catch {
                logger.warning("Failed to encode SSL config for sync: \(error.localizedDescription)")
            }
        } else {
            fields[.sslConfigJson] = nil
        }

        let syncedAdditionalFields = syncedAdditionalFields(for: connection)
        if !syncedAdditionalFields.isEmpty {
            do {
                let data = try encoder.encode(syncedAdditionalFields)
                fields[.additionalFieldsJson] = data as CKRecordValue
            } catch {
                logger.warning("Failed to encode additional fields for sync: \(error.localizedDescription)")
            }
        } else {
            fields[.additionalFieldsJson] = nil
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
        let port = (fields[.port] as? Int64).map { Int($0) } ?? 3_306
        let database = fields[.database] as? String ?? ""
        let username = fields[.username] as? String ?? ""
        let color = Self.color(from: fields)
        let iconName = LibrarySymbolCatalog.normalizedName(fields[.iconName] as? String)
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
        let isFavorite = (fields[.isFavorite] as? Int64 ?? 0) != 0
        let isReadOnly = (fields[.isReadOnly] as? Int64 ?? 0) != 0
        let safeModeLevel = storedSafeModeLevel(in: fields)
        let queryTimeout = (fields[.queryTimeoutSeconds] as? Int64).map { Int($0) }
        var sshConfig: SSHConfiguration?
        if let sshData = fields[.sshConfigJson] as? Data {
            sshConfig = try? decoder.decode(SSHConfiguration.self, from: sshData)
        }

        // Only iOS writes the top-level switches, so one stays behind after a Mac edit; the configurations decide below.
        let sshEnabled: Bool
        if let explicit = fields[.sshEnabled] as? Int64 {
            sshEnabled = explicit != 0
        } else {
            sshEnabled = sshConfig.map { !$0.host.isEmpty } ?? false
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
        // The Mac falls back to this field when the additional field is unset, so copying it in opens the same database.
        if DatabaseType(rawValue: typeRaw) == .redis, additionalFields[redisDatabaseFieldKey] == nil,
           let redisDatabase = fields[.redisDatabase] as? Int64 {
            additionalFields[redisDatabaseFieldKey] = String(redisDatabase)
        }
        let legacyConnectTimeout = additionalFields
            .removeValue(forKey: DatabaseConnection.connectTimeoutSecondsKey)
            .flatMap(Int.init)
        let legacyQueryTimeout = additionalFields
            .removeValue(forKey: DatabaseConnection.queryTimeoutSecondsKey)
            .flatMap(Int.init)

        var connection = DatabaseConnection(
            id: id,
            name: name,
            type: DatabaseType(rawValue: typeRaw),
            host: host,
            port: port,
            username: username,
            database: database,
            color: color,
            iconName: iconName,
            isReadOnly: isReadOnly,
            safeModeLevel: safeModeLevel,
            queryTimeoutSeconds: validQueryTimeout(queryTimeout ?? legacyQueryTimeout),
            additionalFields: additionalFields,
            sshEnabled: sshEnabled,
            sshConfiguration: sshConfig,
            sslEnabled: sslEnabled,
            sslConfiguration: sslConfig,
            groupId: groupId,
            tagIds: tagIds,
            sortOrder: sortOrder,
            isFavorite: isFavorite
        )
        connection.connectTimeoutSeconds = validConnectTimeout(legacyConnectTimeout)
        connection.adoptConfigurationSwitches()
        return connection
    }

    private static func storedSafeModeLevel(in fields: SyncRecordFields<ConnectionSyncField>) -> SafeModeLevel {
        SafeModeLevel(
            wireValue: fields[.safeModeLevel] as? String,
            isReadOnly: (fields[.isReadOnly] as? Int64 ?? 0) != 0
        )
    }

    // MARK: - Update Existing CKRecord (preserves macOS-only fields)

    public static func updateRecord(_ record: CKRecord, with connection: DatabaseConnection) {
        let fields = record.fields(ConnectionSyncField.self)
        let serverSafeModeLevel = storedSafeModeLevel(in: fields)
        fields[.connectionId] = connection.id.uuidString as CKRecordValue
        fields[.name] = connection.name as CKRecordValue
        fields[.host] = connection.host as CKRecordValue
        fields[.port] = Int64(connection.port) as CKRecordValue
        fields[.database] = connection.database as CKRecordValue
        fields[.username] = connection.username as CKRecordValue
        fields[.type] = connection.type.rawValue as CKRecordValue
        fields[.sortOrder] = Int64(connection.sortOrder) as CKRecordValue
        fields[.isReadOnly] = Int64(connection.isReadOnly ? 1 : 0) as CKRecordValue
        if connection.safeModeLevel != serverSafeModeLevel {
            fields[.safeModeLevel] = connection.safeModeLevel.rawValue as CKRecordValue
        }
        fields[.sshEnabled] = Int64(connection.sshEnabled ? 1 : 0) as CKRecordValue
        fields[.sslEnabled] = Int64(connection.sslEnabled ? 1 : 0) as CKRecordValue
        fields[.isFavorite] = Int64(connection.isFavorite ? 1 : 0) as CKRecordValue
        fields[.color] = connection.color.rawValue as CKRecordValue
        fields[.iconName] = LibrarySymbolCatalog.normalizedName(connection.iconName) as CKRecordValue?
        fields[.groupId] = connection.groupId?.uuidString as CKRecordValue?

        if !connection.tagIds.isEmpty {
            let tagIdStrings = connection.tagIds.map { $0.uuidString }
            fields[.tagIds] = tagIdStrings as CKRecordValue
            fields[.tagId] = tagIdStrings[0] as CKRecordValue
        } else {
            fields[.tagIds] = nil
            fields[.tagId] = nil
        }

        fields[.queryTimeoutSeconds] = validQueryTimeout(connection.queryTimeoutSeconds).map { Int64($0) } as CKRecordValue?

        if let sshConfig = macSSHConfiguration(of: connection) {
            if let data = try? encoder.encode(sshConfig) {
                fields[.sshConfigJson] = data as CKRecordValue
            }
        } else {
            fields[.sshConfigJson] = nil
        }

        if let sslConfig = connection.sslConfiguration {
            if !serverSSLMatches(fields[.sslConfigJson] as? Data, sslConfig),
               let data = try? encoder.encode(sslConfig) {
                fields[.sslConfigJson] = data as CKRecordValue
            }
        } else {
            fields[.sslConfigJson] = nil
        }

        let syncedAdditionalFields = syncedAdditionalFields(for: connection)
        if !syncedAdditionalFields.isEmpty {
            if let data = try? encoder.encode(syncedAdditionalFields) {
                fields[.additionalFieldsJson] = data as CKRecordValue
            }
        } else {
            fields[.additionalFieldsJson] = nil
        }

        fields[.modifiedAtLocal] = Date() as CKRecordValue
    }

    private static func serverSSLMatches(_ data: Data?, _ local: SSLConfiguration) -> Bool {
        guard let server = serverSSL(in: data) else { return false }
        return local.agrees(withServer: server)
    }

    // Nil for a blob an older iOS build wrote ("require", nil paths omitted): the Mac cannot read it, so it is rewritten.
    private static func serverSSL(in data: Data?) -> SSLConfiguration? {
        guard let data, SSLConfiguration.isMacWireForm(data) else { return nil }
        return try? decoder.decode(SSLConfiguration.self, from: data)
    }

    public static func serverSSL(in record: CKRecord) -> SSLConfiguration? {
        serverSSL(in: record.fields(ConnectionSyncField.self)[.sslConfigJson] as? Data)
    }

    // The Mac reads a missing `enabled` as off, and an import or an older iOS build leaves it out.
    private static func macSSHConfiguration(of connection: DatabaseConnection) -> SSHConfiguration? {
        guard var sshConfig = connection.sshConfiguration else { return nil }
        sshConfig.macEnabled = connection.sshEnabled
        return sshConfig
    }

    private static func syncedAdditionalFields(for connection: DatabaseConnection) -> [String: String] {
        var fields = connection.additionalFields
        fields.removeValue(forKey: DatabaseConnection.connectTimeoutSecondsKey)
        fields.removeValue(forKey: DatabaseConnection.queryTimeoutSecondsKey)
        if let connectTimeoutSeconds = validConnectTimeout(connection.connectTimeoutSeconds) {
            fields[DatabaseConnection.connectTimeoutSecondsKey] = String(connectTimeoutSeconds)
        }
        return fields
    }

    private static func validConnectTimeout(_ value: Int?) -> Int? {
        value.flatMap { DatabaseConnection.connectTimeoutSecondsRange.contains($0) ? $0 : nil }
    }

    private static func validQueryTimeout(_ value: Int?) -> Int? {
        value.flatMap { DatabaseConnection.queryTimeoutSecondsRange.contains($0) ? $0 : nil }
    }

    // MARK: - Group -> CKRecord

    public static func toRecord(_ group: ConnectionGroup, zoneID: CKRecordZone.ID) -> CKRecord {
        let id = recordID(type: .group, id: group.id.uuidString, in: zoneID)
        let record = CKRecord(recordType: SyncRecordType.group.rawValue, recordID: id)

        // Built whole from the local group, so an empty parent or icon is the user's choice and has
        // to reach the server, which keeps any key a `.changedKeys` push leaves unnamed.
        let fields = record.fields(ConnectionGroupSyncField.self, absentValues: .clear)
        fields[.groupId] = group.id.uuidString
        fields[.name] = group.name
        fields[.color] = group.color.rawValue
        fields[.iconName] = LibrarySymbolCatalog.normalizedName(group.iconName)
        fields[.parentId] = group.parentId?.uuidString
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
        let iconName = LibrarySymbolCatalog.normalizedName(fields[.iconName] as? String)
        let parentId = (fields[.parentId] as? String).flatMap { UUID(uuidString: $0) }

        return ConnectionGroup(
            id: id,
            name: name,
            sortOrder: sortOrder,
            color: color,
            iconName: iconName,
            parentId: parentId
        )
    }

    // MARK: - Update Existing CKRecord with Group

    public static func updateRecord(_ record: CKRecord, with group: ConnectionGroup) {
        let fields = record.fields(ConnectionGroupSyncField.self)
        fields[.groupId] = group.id.uuidString
        fields[.name] = group.name
        fields[.color] = group.color.rawValue
        fields[.iconName] = LibrarySymbolCatalog.normalizedName(group.iconName)
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

    // MARK: - Saved Query -> CKRecord

    // Built whole from the local query, so an emptied keyword, folder or connection is named and cleared on the server.
    public static func toRecord(_ query: SavedQuery, zoneID: CKRecordZone.ID) -> CKRecord {
        let id = recordID(type: .favorite, id: query.id.uuidString, in: zoneID)
        let record = CKRecord(recordType: SyncRecordType.favorite.rawValue, recordID: id)

        let fields = record.fields(SQLFavoriteSyncField.self, absentValues: .clear)
        fields[.favoriteId] = query.id.uuidString
        fields[.name] = query.name
        fields[.query] = query.query
        fields[.keyword] = query.keyword
        fields[.folderId] = query.folderId?.uuidString
        fields[.connectionId] = query.connectionId?.uuidString
        fields[.sortOrder] = Int64(query.sortOrder)
        fields[.createdAt] = query.createdAt
        fields[.updatedAt] = query.updatedAt
        fields[.modifiedAtLocal] = Date()
        fields[.schemaVersion] = schemaVersion

        return record
    }

    // MARK: - CKRecord -> Saved Query

    public static func toSavedQuery(_ record: CKRecord) -> SavedQuery? {
        let fields = record.fields(SQLFavoriteSyncField.self)
        guard let idString = fields[.favoriteId] as? String,
              let id = UUID(uuidString: idString),
              let name = fields[.name] as? String,
              let query = fields[.query] as? String
        else {
            logger.warning("Failed to decode saved query from CKRecord: missing required fields")
            return nil
        }

        return SavedQuery(
            id: id,
            name: name,
            query: query,
            keyword: fields[.keyword] as? String,
            folderId: (fields[.folderId] as? String).flatMap(UUID.init(uuidString:)),
            connectionId: (fields[.connectionId] as? String).flatMap(UUID.init(uuidString:)),
            sortOrder: Int(fields[.sortOrder] as? Int64 ?? 0),
            createdAt: fields[.createdAt] as? Date,
            updatedAt: fields[.updatedAt] as? Date
        )
    }

    // MARK: - Saved Query Folder -> CKRecord

    public static func toRecord(_ folder: SavedQueryFolder, zoneID: CKRecordZone.ID) -> CKRecord {
        let id = recordID(type: .favoriteFolder, id: folder.id.uuidString, in: zoneID)
        let record = CKRecord(recordType: SyncRecordType.favoriteFolder.rawValue, recordID: id)

        let fields = record.fields(SQLFavoriteFolderSyncField.self, absentValues: .clear)
        fields[.folderId] = folder.id.uuidString
        fields[.name] = folder.name
        fields[.parentId] = folder.parentId?.uuidString
        fields[.connectionId] = folder.connectionId?.uuidString
        fields[.sortOrder] = Int64(folder.sortOrder)
        fields[.createdAt] = folder.createdAt
        fields[.updatedAt] = folder.updatedAt
        fields[.modifiedAtLocal] = Date()
        fields[.schemaVersion] = schemaVersion

        return record
    }

    // MARK: - CKRecord -> Saved Query Folder

    public static func toSavedQueryFolder(_ record: CKRecord) -> SavedQueryFolder? {
        let fields = record.fields(SQLFavoriteFolderSyncField.self)
        guard let idString = fields[.folderId] as? String,
              let id = UUID(uuidString: idString),
              let name = fields[.name] as? String
        else {
            logger.warning("Failed to decode saved query folder from CKRecord: missing required fields")
            return nil
        }

        return SavedQueryFolder(
            id: id,
            name: name,
            parentId: (fields[.parentId] as? String).flatMap(UUID.init(uuidString:)),
            connectionId: (fields[.connectionId] as? String).flatMap(UUID.init(uuidString:)),
            sortOrder: Int(fields[.sortOrder] as? Int64 ?? 0),
            createdAt: fields[.createdAt] as? Date,
            updatedAt: fields[.updatedAt] as? Date
        )
    }
}
