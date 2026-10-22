//
//  SyncRecordMapper.swift
//  TablePro
//
//  Maps between local models and CKRecord for CloudKit sync
//

import CloudKit
import Foundation
import os
import TableProConnectionLibrary
import TableProImport
import TableProPluginKit
import TableProSSHConfig
import TableProSSHTransport
import TableProSyncTransport

enum SyncDecodeError: Error, LocalizedError {
    case missingRequiredField(String)
    case decodeFailure(field: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .missingRequiredField(let field):
            return "Sync record missing required field: \(field)"
        case .decodeFailure(let field, let underlying):
            return "Sync record decode failed for \(field): \(underlying.localizedDescription)"
        }
    }
}

/// Pure-function mapper between local models and CKRecord
struct SyncRecordMapper {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SyncRecordMapper")
    // Unsorted keys come out in another order on each encode, and a merge compares fields by their bytes.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()
    private static let decoder = JSONDecoder()

    /// Current schema version stamped on every record
    static let schemaVersion: Int64 = 1

    // MARK: - Record Name Helpers

    static func recordID(type: SyncRecordType, id: String, in zone: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: type.recordName(for: id), zoneID: zone)
    }

    /// The record a push writes into: the one the server last gave us when we still hold it, and a
    /// new one otherwise.
    ///
    /// A base is how a mapper merges into what the server holds rather than restating it, so the
    /// fields it was not asked about keep their values. It is not how a field is cleared: that is
    /// `SyncRecordFields.AbsentValueWrite`, which a mapper building the whole record from the local
    /// model sets to `.clear` so an emptied field is emptied everywhere.
    static func record(
        type: SyncRecordType,
        id: String,
        in zone: CKRecordZone.ID,
        base: CKRecord?
    ) -> CKRecord {
        let recordID = recordID(type: type, id: id, in: zone)
        if let base, base.recordID == recordID { return base }
        return CKRecord(recordType: type.rawValue, recordID: recordID)
    }

    static func parse(recordName: String) -> (type: SyncRecordType, id: String)? {
        SyncRecordType.parse(recordName: recordName)
    }

    /// Maps every record the push is about to send back onto the local identifier it was built
    /// from. `SyncRecordType.recordName(for:)` shortens an identifier that would take the name
    /// past CloudKit's limit, so a saved record cannot be read back through `parse(recordName:)`
    /// without clearing the wrong dirty entry and pushing the same record on every sync forever.
    static func identities(
        for localIds: [SyncRecordType: Set<String>],
        in zone: CKRecordZone.ID
    ) -> [CKRecord.ID: SyncRecordIdentity] {
        var identities: [CKRecord.ID: SyncRecordIdentity] = [:]
        for (type, ids) in localIds {
            for id in ids {
                identities[recordID(type: type, id: id, in: zone)] = SyncRecordIdentity(type: type, id: id)
            }
        }
        return identities
    }

    // MARK: - Connection

    // Optional fields are written even when empty: a key the record never names keeps the server's
    // value, so an emptied group, tag or AI rule came back on the next pull.
    static func toCKRecord(
        _ connection: DatabaseConnection,
        in zone: CKRecordZone.ID,
        base: CKRecord? = nil
    ) -> CKRecord {
        let record = record(type: .connection, id: connection.id.uuidString, in: zone, base: base)

        let fields = record.fields(ConnectionSyncField.self, absentValues: record === base ? .leave : .clear)
        fields[.connectionId] = connection.id.uuidString
        fields[.name] = connection.name
        fields[.host] = connection.host
        fields[.port] = Int64(connection.port)
        fields[.database] = connection.database
        fields[.username] = connection.username
        fields[.type] = connection.type.rawValue
        fields[.color] = connection.color.rawValue
        fields[.iconName] = LibrarySymbolCatalog.normalizedName(connection.iconName)
        fields[.safeModeLevel] = connection.preferredSafeModeLevel.rawValue
        // Older readers still read `isReadOnly` when `safeModeLevel` is absent.
        fields[.isReadOnly] = Int64(connection.preferredSafeModeLevel == .readOnly ? 1 : 0)
        fields[.modifiedAtLocal] = Date()
        fields[.schemaVersion] = schemaVersion
        fields[.sortOrder] = Int64(connection.sortOrder)
        fields[.isFavorite] = Int64(connection.isFavorite ? 1 : 0)
        fields[.queryTimeoutSeconds] = validQueryTimeout(connection.queryTimeoutSeconds).map { Int64($0) }

        let tagIdStrings = connection.tagIds.map(\.uuidString)
        fields[.tagIds] = tagIdStrings.isEmpty ? nil : tagIdStrings
        // Cleared with `tagIds`, because a record with no `tagIds` is read through this one.
        fields[.tagId] = tagIdStrings.first
        fields[.groupId] = connection.groupId?.uuidString
        fields[.aiPolicy] = connection.aiPolicy?.rawValue ?? unrecognizedAIPolicy(in: fields)
        fields[.aiRules] = connection.aiRules.flatMap { $0.isEmpty ? nil : $0 }
        fields[.aiAlwaysAllowedTools] = connection.aiAlwaysAllowedTools.isEmpty
            ? nil
            : Array(connection.aiAlwaysAllowedTools).sorted()
        fields[.redisDatabase] = connection.redisDatabase.map { Int64($0) }
        fields[.startupCommands] = connection.startupCommands.flatMap { $0.isEmpty ? nil : $0 }
        fields[.sshProfileId] = connection.sshProfileId?.uuidString
        // Only a change is written: a route another build wrote stays, and a record built without the
        // server's copy names no route, so a push after the cache was dropped cannot clear another Mac's.
        if connection.sshRoute != Self.sshRoute(in: fields) {
            fields[.sshRouteJson] = connection.sshRoute?.encoded()
        }

        // Encode complex structs as JSON Data — contract device-local paths
        // to portable ~/… form so they resolve correctly on other devices.
        // Note: sshTunnelMode is intentionally NOT synced — it is re-derived
        // on decode from sshConfig + sshProfileId. If adding sshTunnelMode to
        // the sync schema in the future, apply path contraction to its snapshot.
        // cloudflareTunnelMode, cloudSQLProxyMode, socksProxyMode and
        // tunnelCommandMode are also NOT synced: they are device-local runtime
        // config, their secrets live in the Keychain, and a tunnel command names a
        // process that only exists on the Mac it was written on.
        // passwordSource is also NOT synced: its file path, env var, or command
        // is device-local and may not exist or resolve on another Mac.
        do {
            let sshData = try encoder.encode(Self.makePortable(connection.sshConfig))
            fields[.sshConfigJson] = sshData
        } catch {
            logger.warning("Failed to encode SSH config for sync: \(error.localizedDescription)")
        }
        do {
            let sslData = try encoder.encode(Self.makePortable(connection.sslConfig))
            fields[.sslConfigJson] = sslData
        } catch {
            logger.warning("Failed to encode SSL config for sync: \(error.localizedDescription)")
        }
        let syncedAdditionalFields = syncedAdditionalFields(for: connection)
        if !syncedAdditionalFields.isEmpty {
            do {
                let fieldsData = try encoder.encode(syncedAdditionalFields)
                fields[.additionalFieldsJson] = fieldsData
            } catch {
                logger.warning("Failed to encode additional fields for sync: \(error.localizedDescription)")
            }
        } else {
            fields[.additionalFieldsJson] = nil
        }

        return record
    }

    static func toConnection(_ record: CKRecord) throws -> DatabaseConnection {
        let fields = record.fields(ConnectionSyncField.self)
        guard let connectionIdString = fields[.connectionId] as? String,
              let connectionId = UUID(uuidString: connectionIdString)
        else {
            throw SyncDecodeError.missingRequiredField("connectionId")
        }
        guard let name = fields[.name] as? String else {
            throw SyncDecodeError.missingRequiredField("name")
        }
        guard let typeRawValue = fields[.type] as? String else {
            throw SyncDecodeError.missingRequiredField("type")
        }

        let host = fields[.host] as? String ?? "localhost"
        let port = (fields[.port] as? Int64).map { Int($0) } ?? 0
        let database = fields[.database] as? String ?? ""
        let username = fields[.username] as? String ?? ""
        // Older iOS builds wrote the colour as hex to `colorTag`.
        let colorRaw = fields[.color] as? String
            ?? fields[.colorTag] as? String
            ?? ConnectionColor.none.rawValue
        let isReadOnly = (fields[.isReadOnly] as? Int64 ?? 0) != 0
        let safeModeLevel = SafeModeLevel(wireValue: fields[.safeModeLevel] as? String, isReadOnly: isReadOnly)
        let tagIds: [UUID]
        if let rawIds = fields[.tagIds] as? [String], !rawIds.isEmpty {
            tagIds = rawIds.compactMap { UUID(uuidString: $0) }
        } else if let single = (fields[.tagId] as? String).flatMap({ UUID(uuidString: $0) }) {
            tagIds = [single]
        } else {
            tagIds = []
        }
        let groupId = (fields[.groupId] as? String).flatMap { UUID(uuidString: $0) }
        let aiPolicyRaw = fields[.aiPolicy] as? String
        let aiRulesRaw = fields[.aiRules] as? String
        let aiAlwaysAllowedToolsArray = fields[.aiAlwaysAllowedTools] as? [String] ?? []
        let redisDatabase = (fields[.redisDatabase] as? Int64).map { Int($0) }
        let startupCommands = fields[.startupCommands] as? String
        let sortOrder = (fields[.sortOrder] as? Int64).map { Int($0) } ?? 0
        let isFavorite = (fields[.isFavorite] as? Int64 ?? 0) != 0
        let sshProfileId = (fields[.sshProfileId] as? String).flatMap { UUID(uuidString: $0) }
        let queryTimeoutSeconds = (fields[.queryTimeoutSeconds] as? Int64).map { Int($0) }

        var sshConfig = SSHConfiguration()
        if let sshData = fields[.sshConfigJson] as? Data {
            do {
                sshConfig = try decoder.decode(SSHConfiguration.self, from: sshData)
            } catch {
                throw SyncDecodeError.decodeFailure(field: "sshConfigJson", underlying: error)
            }
            Self.expandPaths(&sshConfig)
        }

        let connectionType = DatabaseType(rawValue: typeRawValue)
        var sslConfig = SSLConfiguration(mode: connectionType.defaultSSLMode)
        if let sslData = fields[.sslConfigJson] as? Data {
            do {
                sslConfig = try decoder.decode(SSLConfiguration.self, from: sslData)
            } catch {
                throw SyncDecodeError.decodeFailure(field: "sslConfigJson", underlying: error)
            }
            Self.expandPaths(&sslConfig)
        }

        var additionalFields: [String: String]?
        if let fieldsData = fields[.additionalFieldsJson] as? Data {
            do {
                additionalFields = try decoder.decode([String: String].self, from: fieldsData)
            } catch {
                throw SyncDecodeError.decodeFailure(field: "additionalFieldsJson", underlying: error)
            }
        }
        var normalizedAdditionalFields = additionalFields ?? [:]
        let legacyConnectTimeout = normalizedAdditionalFields
            .removeValue(forKey: DatabaseConnection.connectTimeoutSecondsKey)
            .flatMap(Int.init)
        let legacyQueryTimeout = normalizedAdditionalFields
            .removeValue(forKey: DatabaseConnection.queryTimeoutSecondsKey)
            .flatMap(Int.init)

        var connection = DatabaseConnection(
            id: connectionId,
            name: name,
            host: host,
            port: port,
            database: database,
            username: username,
            type: connectionType,
            sshConfig: sshConfig,
            sslConfig: sslConfig,
            color: ConnectionColor(storedValue: colorRaw),
            iconName: LibrarySymbolCatalog.normalizedName(fields[.iconName] as? String),
            tagIds: tagIds,
            groupId: groupId,
            sshProfileId: sshProfileId,
            safeModeLevel: safeModeLevel,
            aiPolicy: aiPolicyRaw.flatMap { AIConnectionPolicy(rawValue: $0) },
            aiRules: aiRulesRaw,
            aiAlwaysAllowedTools: Set(aiAlwaysAllowedToolsArray),
            redisDatabase: redisDatabase,
            startupCommands: startupCommands,
            sortOrder: sortOrder,
            isFavorite: isFavorite,
            additionalFields: normalizedAdditionalFields
        )
        if let connectTimeoutSeconds = validConnectTimeout(legacyConnectTimeout) {
            connection.connectTimeoutSeconds = connectTimeoutSeconds
        }
        if let queryTimeoutSeconds = validQueryTimeout(queryTimeoutSeconds ?? legacyQueryTimeout) {
            connection.queryTimeoutSeconds = queryTimeoutSeconds
        }
        connection.sshRoute = sshRoute(in: fields)
        return connection
    }

    private static func sshRoute(in fields: SyncRecordFields<ConnectionSyncField>) -> PublishedSSHRoute? {
        (fields[.sshRouteJson] as? Data).flatMap(PublishedSSHRoute.decoded(from:))
    }

    // Only the Mac that published a route clears it, so a copy cached before this build read the
    // field does not wipe the route another Mac published.
    static func keepingForeignRoute(
        of connection: DatabaseConnection,
        in base: CKRecord?,
        publisher: UUID
    ) -> DatabaseConnection {
        guard connection.sshRoute == nil,
              let route = base.flatMap({ sshRoute(in: $0.fields(ConnectionSyncField.self)) }),
              route.publisher != publisher
        else { return connection }
        var kept = connection
        kept.sshRoute = route
        return kept
    }

    // `base` is left untouched, so the edit is what the push changes on the server's copy, and the
    // base read and written again keeps a value only iOS spells differently out of the edit.
    static func connectionEdit(
        _ connection: DatabaseConnection,
        in zone: CKRecordZone.ID,
        base: CKRecord?,
        publisher: UUID
    ) -> SyncRecordEdit {
        let kept = keepingForeignRoute(of: connection, in: base, publisher: publisher)
        let record = toCKRecord(kept, in: zone, base: base?.copy() as? CKRecord)
        let baseAsWritten = base.flatMap { try? toConnection($0) }.map { toCKRecord($0, in: zone) }
        return SyncRecordEdit(ConnectionSyncField.self, record: record, base: base, baseAsWritten: baseAsWritten) { merged, server in
            settleRoute(in: merged, server: server, publisher: publisher)
        }
    }

    // An edit judged its route against an older copy, so the route lands on the server's by the rules a dial uses.
    static func settleRoute(in merged: CKRecord, server: CKRecord, publisher: UUID) {
        let mergedFields = merged.fields(ConnectionSyncField.self)
        let serverFields = server.fields(ConnectionSyncField.self)
        let current = sshRoute(in: serverFields)
        guard rebasedRoute(wanted: sshRoute(in: mergedFields), server: current, publisher: publisher) == current else { return }
        mergedFields[.sshRouteJson] = serverFields[.sshRouteJson]
    }

    static func rebasedRoute(
        wanted: PublishedSSHRoute?,
        server: PublishedSSHRoute?,
        publisher: UUID
    ) -> PublishedSSHRoute? {
        guard let server else { return wanted }
        guard let wanted else { return server.publisher == publisher ? nil : server }
        return server.leadsToSameHosts(as: wanted) ? server : wanted
    }

    /// A policy a newer release added reads as nil on this Mac. Writing that nil back would clear
    /// the other device's choice the next time this Mac saves any other change to the connection.
    private static func unrecognizedAIPolicy(in fields: SyncRecordFields<ConnectionSyncField>) -> String? {
        (fields[.aiPolicy] as? String).flatMap { AIConnectionPolicy(rawValue: $0) == nil ? $0 : nil }
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
        value.flatMap { (1 ... 600).contains($0) ? $0 : nil }
    }

    private static func validQueryTimeout(_ value: Int?) -> Int? {
        value.flatMap { DatabaseConnection.queryTimeoutSecondsRange.contains($0) ? $0 : nil }
    }

    // MARK: - Connection Group

    // `parentId` and `iconName` are written even when empty, or a group moved to the top level keeps its old parent.
    static func toCKRecord(_ group: ConnectionGroup, in zone: CKRecordZone.ID, base: CKRecord? = nil) -> CKRecord {
        let record = record(type: .group, id: group.id.uuidString, in: zone, base: base)

        let fields = record.fields(ConnectionGroupSyncField.self, absentValues: record === base ? .leave : .clear)
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

    static func toGroup(_ record: CKRecord) -> ConnectionGroup? {
        let fields = record.fields(ConnectionGroupSyncField.self)
        guard let groupIdString = fields[.groupId] as? String,
              let groupId = UUID(uuidString: groupIdString),
              let name = fields[.name] as? String
        else {
            logger.warning("Failed to decode group from CKRecord: missing required fields")
            return nil
        }

        let colorRaw = fields[.color] as? String ?? ConnectionColor.none.rawValue
        let parentId = (fields[.parentId] as? String).flatMap { UUID(uuidString: $0) }
        let sortOrder = (fields[.sortOrder] as? Int64).map { Int($0) } ?? 0

        return ConnectionGroup(
            id: groupId,
            name: name,
            color: ConnectionColor(rawValue: colorRaw) ?? .none,
            iconName: LibrarySymbolCatalog.normalizedName(fields[.iconName] as? String),
            parentId: parentId,
            sortOrder: sortOrder
        )
    }

    // MARK: - Connection Tag

    static func toCKRecord(_ tag: ConnectionTag, in zone: CKRecordZone.ID, base: CKRecord? = nil) -> CKRecord {
        let record = record(type: .tag, id: tag.id.uuidString, in: zone, base: base)

        let fields = record.fields(ConnectionTagSyncField.self)
        fields[.tagId] = tag.id.uuidString
        fields[.name] = tag.name
        fields[.isPreset] = Int64(tag.isPreset ? 1 : 0)
        fields[.color] = tag.color.rawValue
        fields[.modifiedAtLocal] = Date()
        fields[.schemaVersion] = schemaVersion

        return record
    }

    static func toTag(_ record: CKRecord) -> ConnectionTag? {
        let fields = record.fields(ConnectionTagSyncField.self)
        guard let tagIdString = fields[.tagId] as? String,
              let tagId = UUID(uuidString: tagIdString),
              let name = fields[.name] as? String
        else {
            logger.warning("Failed to decode tag from CKRecord: missing required fields")
            return nil
        }

        let isPreset = (fields[.isPreset] as? Int64 ?? 0) != 0
        let colorRaw = fields[.color] as? String ?? ConnectionColor.gray.rawValue

        return ConnectionTag(
            id: tagId,
            name: name,
            isPreset: isPreset,
            color: ConnectionColor(rawValue: colorRaw) ?? .gray
        )
    }

    // MARK: - App Settings

    static func toCKRecord(
        category: String,
        settingsData: Data,
        in zone: CKRecordZone.ID,
        base: CKRecord? = nil
    ) -> CKRecord {
        let record = record(type: .settings, id: category, in: zone, base: base)

        let fields = record.fields(AppSettingsSyncField.self)
        fields[.category] = category
        fields[.settingsJson] = settingsData
        fields[.modifiedAtLocal] = Date()
        fields[.schemaVersion] = schemaVersion

        return record
    }

    static func settingsEdit(
        category: String,
        settingsData: Data,
        in zone: CKRecordZone.ID,
        base: CKRecord?
    ) -> SyncRecordEdit {
        let record = toCKRecord(category: category, settingsData: settingsData, in: zone, base: base?.copy() as? CKRecord)
        let baseData = base.flatMap(Self.settingsData(from:))
        return SyncRecordEdit(AppSettingsSyncField.self, record: record, base: base) { merged, server in
            guard let document = SyncJSONMerge.document(
                base: baseData,
                local: settingsData,
                server: Self.settingsData(from: server)
            ) else { return }
            merged.fields(AppSettingsSyncField.self)[.settingsJson] = document
        }
    }

    static func settingsCategory(from record: CKRecord) -> String? {
        record.fields(AppSettingsSyncField.self)[.category] as? String
    }

    static func settingsData(from record: CKRecord) -> Data? {
        record.fields(AppSettingsSyncField.self)[.settingsJson] as? Data
    }

    // MARK: - Table Favorite

    static func toCKRecord(favoriteEntry entry: FavoriteTablesStorage.FavoriteEntry, in zone: CKRecordZone.ID) -> CKRecord {
        toCKRecord(favoriteEntry: entry, recordId: FavoriteTablesStorage.syncId(for: entry), in: zone)
    }

    static func toCKRecord(
        favoriteEntry entry: FavoriteTablesStorage.FavoriteEntry,
        recordId favoriteId: String,
        in zone: CKRecordZone.ID,
        base: CKRecord? = nil
    ) -> CKRecord {
        let record = record(type: .tableFavorite, id: favoriteId, in: zone, base: base)

        let fields = record.fields(FavoriteTableSyncField.self)
        fields[.connectionId] = entry.connectionId.uuidString
        fields[.name] = entry.name
        if let database = entry.database {
            fields[.database] = database
        }
        if let schema = entry.schema {
            fields[.schema] = schema
        }
        fields[.modifiedAtLocal] = Date()
        fields[.schemaVersion] = schemaVersion

        return record
    }

    static func favoriteEntry(from record: CKRecord) throws -> FavoriteTablesStorage.FavoriteEntry {
        let fields = record.fields(FavoriteTableSyncField.self)
        guard let name = fields[.name] as? String, !name.isEmpty else {
            throw SyncDecodeError.missingRequiredField("name")
        }
        guard let connectionIdString = fields[.connectionId] as? String,
              let connectionId = UUID(uuidString: connectionIdString) else {
            throw SyncDecodeError.missingRequiredField("connectionId")
        }
        let database = fields[.database] as? String
        let schema = fields[.schema] as? String
        return FavoriteTablesStorage.FavoriteEntry(
            connectionId: connectionId,
            database: database,
            schema: schema,
            name: name
        )
    }

    // MARK: - Favorite Database

    static func toCKRecord(
        favoriteDatabase entry: FavoriteDatabaseEntry,
        in zone: CKRecordZone.ID,
        base: CKRecord? = nil
    ) -> CKRecord {
        let record = record(type: .favoriteDatabase, id: FavoriteDatabasesStorage.syncId(for: entry), in: zone, base: base)

        let fields = record.fields(FavoriteDatabaseSyncField.self)
        fields[.connectionId] = entry.connectionId.uuidString
        fields[.database] = entry.database
        fields[.environment] = entry.environment.rawValue
        fields[.modifiedAtLocal] = Date()
        fields[.schemaVersion] = schemaVersion

        return record
    }

    /// An environment this build does not know decodes to `.unassigned` rather than throwing, so a
    /// device on an older version keeps the favorite instead of dropping the whole record.
    static func favoriteDatabase(from record: CKRecord) throws -> FavoriteDatabaseEntry {
        let fields = record.fields(FavoriteDatabaseSyncField.self)
        guard let database = fields[.database] as? String, !database.isEmpty else {
            throw SyncDecodeError.missingRequiredField("database")
        }
        guard let connectionIdString = fields[.connectionId] as? String,
              let connectionId = UUID(uuidString: connectionIdString) else {
            throw SyncDecodeError.missingRequiredField("connectionId")
        }
        let environment = (fields[.environment] as? String)
            .flatMap(FavoriteDatabaseEnvironment.init(rawValue:)) ?? .unassigned
        return FavoriteDatabaseEntry(
            connectionId: connectionId,
            database: database,
            environment: environment
        )
    }

    // MARK: - SQL Favorite

    // Optional fields are written even when empty, or a query marked Global kept its old connection (#3045).
    static func toCKRecord(sqlFavorite favorite: SQLFavorite, in zone: CKRecordZone.ID, base: CKRecord? = nil) -> CKRecord {
        let record = record(type: .favorite, id: favorite.id.uuidString, in: zone, base: base)

        let fields = record.fields(SQLFavoriteSyncField.self, absentValues: record === base ? .leave : .clear)
        fields[.favoriteId] = favorite.id.uuidString
        fields[.name] = favorite.name
        fields[.query] = favorite.query
        fields[.keyword] = favorite.keyword
        fields[.folderId] = favorite.folderId?.uuidString
        fields[.connectionId] = favorite.connectionId?.uuidString
        fields[.sortOrder] = Int64(favorite.sortOrder)
        fields[.createdAt] = favorite.createdAt
        fields[.updatedAt] = favorite.updatedAt
        fields[.modifiedAtLocal] = Date()
        fields[.schemaVersion] = schemaVersion

        return record
    }

    static func sqlFavorite(from record: CKRecord) throws -> SQLFavorite {
        let fields = record.fields(SQLFavoriteSyncField.self)
        guard let idString = fields[.favoriteId] as? String, let id = UUID(uuidString: idString) else {
            throw SyncDecodeError.missingRequiredField("favoriteId")
        }
        guard let name = fields[.name] as? String else {
            throw SyncDecodeError.missingRequiredField("name")
        }
        guard let query = fields[.query] as? String else {
            throw SyncDecodeError.missingRequiredField("query")
        }
        return SQLFavorite(
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

    // MARK: - SQL Favorite Folder

    // Optional fields are written even when empty, as for a query.
    static func toCKRecord(
        sqlFavoriteFolder folder: SQLFavoriteFolder,
        in zone: CKRecordZone.ID,
        base: CKRecord? = nil
    ) -> CKRecord {
        let record = record(type: .favoriteFolder, id: folder.id.uuidString, in: zone, base: base)

        let fields = record.fields(SQLFavoriteFolderSyncField.self, absentValues: record === base ? .leave : .clear)
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

    static func sqlFavoriteFolder(from record: CKRecord) throws -> SQLFavoriteFolder {
        let fields = record.fields(SQLFavoriteFolderSyncField.self)
        guard let idString = fields[.folderId] as? String, let id = UUID(uuidString: idString) else {
            throw SyncDecodeError.missingRequiredField("folderId")
        }
        guard let name = fields[.name] as? String else {
            throw SyncDecodeError.missingRequiredField("name")
        }
        return SQLFavoriteFolder(
            id: id,
            name: name,
            parentId: (fields[.parentId] as? String).flatMap(UUID.init(uuidString:)),
            connectionId: (fields[.connectionId] as? String).flatMap(UUID.init(uuidString:)),
            sortOrder: Int(fields[.sortOrder] as? Int64 ?? 0),
            createdAt: fields[.createdAt] as? Date,
            updatedAt: fields[.updatedAt] as? Date
        )
    }

    // MARK: - Table Folder

    // `schema` is written even when empty, or a folder moved to a database with no schema keeps the old one.
    static func toCKRecord(tableFolder folder: TableFolder, in zone: CKRecordZone.ID, base: CKRecord? = nil) -> CKRecord {
        let record = record(type: .tableFolder, id: folder.id.uuidString, in: zone, base: base)

        let fields = record.fields(TableFolderSyncField.self, absentValues: record === base ? .leave : .clear)
        fields[.folderId] = folder.id.uuidString
        fields[.connectionId] = folder.scope.connectionId.uuidString
        fields[.database] = folder.scope.database
        fields[.schema] = folder.scope.schema
        fields[.name] = folder.name
        fields[.createdAt] = folder.createdAt
        fields[.updatedAt] = folder.updatedAt
        fields[.modifiedAtLocal] = Date()
        fields[.schemaVersion] = schemaVersion

        return record
    }

    static func tableFolder(from record: CKRecord) throws -> TableFolder {
        let fields = record.fields(TableFolderSyncField.self)
        guard let idString = fields[.folderId] as? String, let id = UUID(uuidString: idString) else {
            throw SyncDecodeError.missingRequiredField("folderId")
        }
        guard let name = fields[.name] as? String else {
            throw SyncDecodeError.missingRequiredField("name")
        }
        let scope = try tableFolderScope(
            connectionId: fields[.connectionId] as? String,
            database: fields[.database] as? String,
            schema: fields[.schema] as? String
        )
        let createdAt = fields[.createdAt] as? Date ?? Date()
        return TableFolder(
            id: id,
            scope: scope,
            name: name,
            createdAt: createdAt,
            updatedAt: fields[.updatedAt] as? Date ?? createdAt
        )
    }

    static func toCKRecord(tableFolderItem item: TableFolderItem, in zone: CKRecordZone.ID, base: CKRecord? = nil) -> CKRecord {
        let record = record(type: .tableFolderItem, id: item.syncId, in: zone, base: base)

        let fields = record.fields(TableFolderItemSyncField.self, absentValues: record === base ? .leave : .clear)
        fields[.connectionId] = item.scope.connectionId.uuidString
        fields[.database] = item.scope.database
        fields[.schema] = item.scope.schema
        fields[.name] = item.name
        fields[.folderId] = item.folderId.uuidString
        fields[.modifiedAtLocal] = Date()
        fields[.schemaVersion] = schemaVersion

        return record
    }

    static func tableFolderItem(from record: CKRecord) throws -> TableFolderItem {
        let fields = record.fields(TableFolderItemSyncField.self)
        guard let name = fields[.name] as? String, !name.isEmpty else {
            throw SyncDecodeError.missingRequiredField("name")
        }
        guard let folderIdString = fields[.folderId] as? String,
              let folderId = UUID(uuidString: folderIdString) else {
            throw SyncDecodeError.missingRequiredField("folderId")
        }
        let scope = try tableFolderScope(
            connectionId: fields[.connectionId] as? String,
            database: fields[.database] as? String,
            schema: fields[.schema] as? String
        )
        return TableFolderItem(scope: scope, name: name, folderId: folderId)
    }

    private static func tableFolderScope(
        connectionId: String?,
        database: String?,
        schema: String?
    ) throws -> DatabaseScope {
        guard let connectionId = connectionId.flatMap(UUID.init(uuidString:)) else {
            throw SyncDecodeError.missingRequiredField("connectionId")
        }
        return DatabaseScope(connectionId: connectionId, database: database ?? "", schema: schema)
    }

    // MARK: - SSH Profile

    static func toCKRecord(_ profile: SSHProfile, in zone: CKRecordZone.ID, base: CKRecord? = nil) -> CKRecord {
        let record = record(type: .sshProfile, id: profile.id.uuidString, in: zone, base: base)

        let fields = record.fields(SSHProfileSyncField.self, absentValues: record === base ? .leave : .clear)
        fields[.profileId] = profile.id.uuidString
        fields[.name] = profile.name
        fields[.host] = profile.host
        fields[.port] = profile.port.map { Int64($0) }
        fields[.username] = profile.username
        fields[.authMethod] = profile.authMethod.rawValue
        fields[.privateKeyPath] = PathPortability.contractHome(profile.privateKeyPath)
        fields[.agentSocketPath] = PathPortability.contractHome(profile.agentSocketPath)
        fields[.totpMode] = profile.totpMode.rawValue
        fields[.totpAlgorithm] = profile.totpAlgorithm.rawValue
        fields[.totpDigits] = Int64(profile.totpDigits)
        fields[.totpPeriod] = Int64(profile.totpPeriod)
        fields[.modifiedAtLocal] = Date()
        fields[.schemaVersion] = schemaVersion

        if profile.jumpHosts.isEmpty {
            fields[.jumpHostsJson] = nil
        } else {
            do {
                let portableJumpHosts = Self.makePortable(profile.jumpHosts)
                fields[.jumpHostsJson] = try encoder.encode(portableJumpHosts)
            } catch {
                logger.warning("Failed to encode jump hosts for sync: \(error.localizedDescription)")
            }
        }

        return record
    }

    static func toSSHProfile(_ record: CKRecord) throws -> SSHProfile {
        let fields = record.fields(SSHProfileSyncField.self)
        guard let profileIdString = fields[.profileId] as? String,
              let profileId = UUID(uuidString: profileIdString)
        else {
            throw SyncDecodeError.missingRequiredField("profileId")
        }
        guard let name = fields[.name] as? String else {
            throw SyncDecodeError.missingRequiredField("name")
        }

        let host = fields[.host] as? String ?? ""
        let port = (fields[.port] as? Int64).map { Int($0) }
        let username = fields[.username] as? String ?? ""
        let authMethodRaw = fields[.authMethod] as? String ?? SSHAuthMethod.password.rawValue
        let privateKeyPath = PathPortability.expandHome(fields[.privateKeyPath] as? String ?? "")
        let agentSocketPath = PathPortability.expandHome(fields[.agentSocketPath] as? String ?? "")
        let totpModeRaw = fields[.totpMode] as? String ?? TOTPMode.none.rawValue
        let totpAlgorithmRaw = fields[.totpAlgorithm] as? String ?? TOTPAlgorithm.sha1.rawValue
        let totpDigits = (fields[.totpDigits] as? Int64).map { Int($0) } ?? 6
        let totpPeriod = (fields[.totpPeriod] as? Int64).map { Int($0) } ?? 30

        var jumpHosts: [SSHJumpHost] = []
        if let jumpHostsData = fields[.jumpHostsJson] as? Data {
            do {
                jumpHosts = try decoder.decode([SSHJumpHost].self, from: jumpHostsData)
            } catch {
                throw SyncDecodeError.decodeFailure(field: "jumpHostsJson", underlying: error)
            }
            Self.expandPaths(&jumpHosts)
        }

        return SSHProfile(
            id: profileId,
            name: name,
            host: host,
            port: port,
            username: username,
            authMethod: SSHAuthMethod(rawValue: authMethodRaw) ?? .password,
            privateKeyPath: privateKeyPath,
            agentSocketPath: agentSocketPath,
            jumpHosts: jumpHosts,
            totpMode: TOTPMode(rawValue: totpModeRaw) ?? .none,
            totpAlgorithm: TOTPAlgorithm(rawValue: totpAlgorithmRaw) ?? .sha1,
            totpDigits: totpDigits,
            totpPeriod: totpPeriod
        )
    }

    // MARK: - Credential Profile

    // No password, and no `.source` payload: it can name a shell command this Mac never agreed to run.
    static func toCKRecord(_ profile: CredentialProfile, in zone: CKRecordZone.ID, base: CKRecord? = nil) -> CKRecord {
        let record = record(type: .credentialProfile, id: profile.id.uuidString, in: zone, base: base)

        let fields = record.fields(CredentialProfileSyncField.self, absentValues: record === base ? .leave : .clear)
        fields[.profileId] = profile.id.uuidString
        fields[.name] = profile.name
        fields[.username] = profile.username
        fields[.passwordMode] = portablePasswordMode(profile.passwordMode)
        fields[.sortOrder] = Int64(profile.sortOrder)
        fields[.modifiedAtLocal] = Date()
        fields[.schemaVersion] = schemaVersion

        if profile.secureFieldIds.isEmpty {
            fields[.secureFieldIdsJson] = nil
        } else {
            do {
                fields[.secureFieldIdsJson] = try encoder.encode(profile.secureFieldIds)
            } catch {
                logger.warning("Failed to encode credential profile field ids for sync: \(error.localizedDescription)")
            }
        }

        return record
    }

    static func toCredentialProfile(_ record: CKRecord) throws -> CredentialProfile {
        let fields = record.fields(CredentialProfileSyncField.self)
        guard let profileIdString = fields[.profileId] as? String,
              let profileId = UUID(uuidString: profileIdString)
        else {
            throw SyncDecodeError.missingRequiredField("profileId")
        }
        guard let name = fields[.name] as? String else {
            throw SyncDecodeError.missingRequiredField("name")
        }

        var secureFieldIds: [String] = []
        if let data = fields[.secureFieldIdsJson] as? Data {
            do {
                secureFieldIds = try decoder.decode([String].self, from: data)
            } catch {
                throw SyncDecodeError.decodeFailure(field: "secureFieldIdsJson", underlying: error)
            }
        }

        return CredentialProfile(
            id: profileId,
            name: name,
            username: fields[.username] as? String ?? "",
            passwordMode: passwordMode(fromPortable: fields[.passwordMode] as? String),
            secureFieldIds: secureFieldIds,
            sortOrder: Int(fields[.sortOrder] as? Int64 ?? 0)
        )
    }

    static func portablePasswordModeForTesting(_ mode: CredentialPasswordMode) -> String {
        portablePasswordMode(mode)
    }

    private static func portablePasswordMode(_ mode: CredentialPasswordMode) -> String {
        switch mode {
        case .stored: "stored"
        case .prompt, .source: "prompt"
        case .pgpass: "pgpass"
        }
    }

    private static func passwordMode(fromPortable raw: String?) -> CredentialPasswordMode {
        switch raw {
        case "pgpass": .pgpass
        case "prompt": .prompt
        default: .stored
        }
    }

    // MARK: - Path Portability
    // Contract device-local paths to portable ~/… form before pushing to iCloud,
    // expand them back to device-local form when pulling, the same rule connection files use.

    private static func makePortable(_ ssh: SSHConfiguration) -> SSHConfiguration {
        var config = ssh
        config.privateKeyPath = PathPortability.contractHome(config.privateKeyPath)
        config.agentSocketPath = PathPortability.contractHome(config.agentSocketPath)
        config.jumpHosts = makePortable(config.jumpHosts)
        return config
    }

    private static func expandPaths(_ ssh: inout SSHConfiguration) {
        ssh.privateKeyPath = PathPortability.expandHome(ssh.privateKeyPath)
        ssh.agentSocketPath = PathPortability.expandHome(ssh.agentSocketPath)
        expandPaths(&ssh.jumpHosts)
    }

    private static func makePortable(_ ssl: SSLConfiguration) -> SSLConfiguration {
        var config = ssl
        config.caCertificatePath = PathPortability.contractHome(config.caCertificatePath)
        config.clientCertificatePath = PathPortability.contractHome(config.clientCertificatePath)
        config.clientKeyPath = PathPortability.contractHome(config.clientKeyPath)
        return config
    }

    private static func expandPaths(_ ssl: inout SSLConfiguration) {
        ssl.caCertificatePath = PathPortability.expandHome(ssl.caCertificatePath)
        ssl.clientCertificatePath = PathPortability.expandHome(ssl.clientCertificatePath)
        ssl.clientKeyPath = PathPortability.expandHome(ssl.clientKeyPath)
    }

    private static func makePortable(_ jumpHosts: [SSHJumpHost]) -> [SSHJumpHost] {
        jumpHosts.map { host in
            var h = host
            h.privateKeyPath = PathPortability.contractHome(h.privateKeyPath)
            return h
        }
    }

    private static func expandPaths(_ jumpHosts: inout [SSHJumpHost]) {
        jumpHosts = jumpHosts.map { host in
            var h = host
            h.privateKeyPath = PathPortability.expandHome(h.privateKeyPath)
            return h
        }
    }
}
