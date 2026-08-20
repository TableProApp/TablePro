//
//  SyncRecordMapper.swift
//  TablePro
//
//  Maps between local models and CKRecord for CloudKit sync
//

import CloudKit
import Foundation
import os
import TableProImport
import TableProPluginKit
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
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// Current schema version stamped on every record
    static let schemaVersion: Int64 = 1

    // MARK: - Record Name Helpers

    static func recordID(type: SyncRecordType, id: String, in zone: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: type.recordName(for: id), zoneID: zone)
    }

    static func parse(recordName: String) -> (type: SyncRecordType, id: String)? {
        SyncRecordType.parse(recordName: recordName)
    }

    // MARK: - Connection

    static func toCKRecord(
        _ connection: DatabaseConnection,
        in zone: CKRecordZone.ID,
        base: CKRecord? = nil
    ) -> CKRecord {
        let recordID = recordID(type: .connection, id: connection.id.uuidString, in: zone)
        let record: CKRecord
        if let base, base.recordID == recordID {
            record = base
        } else {
            record = CKRecord(recordType: SyncRecordType.connection.rawValue, recordID: recordID)
        }

        let fields = record.fields(ConnectionSyncField.self)
        fields[.connectionId] = connection.id.uuidString
        fields[.name] = connection.name
        fields[.host] = connection.host
        fields[.port] = Int64(connection.port)
        fields[.database] = connection.database
        fields[.username] = connection.username
        fields[.type] = connection.type.rawValue
        fields[.color] = connection.color.rawValue
        fields[.safeModeLevel] = connection.safeModeLevel.rawValue
        fields[.modifiedAtLocal] = Date()
        fields[.schemaVersion] = schemaVersion
        fields[.sortOrder] = Int64(connection.sortOrder)
        fields[.isFavorite] = Int64(connection.isFavorite ? 1 : 0)

        if !connection.tagIds.isEmpty {
            let tagIdStrings = connection.tagIds.map { $0.uuidString }
            fields[.tagIds] = tagIdStrings
            fields[.tagId] = tagIdStrings[0]
        }
        if let groupId = connection.groupId {
            fields[.groupId] = groupId.uuidString
        }
        if let aiPolicy = connection.aiPolicy {
            fields[.aiPolicy] = aiPolicy.rawValue
        }
        if let aiRules = connection.aiRules, !aiRules.isEmpty {
            fields[.aiRules] = aiRules
        }
        if !connection.aiAlwaysAllowedTools.isEmpty {
            fields[.aiAlwaysAllowedTools] = Array(connection.aiAlwaysAllowedTools).sorted()
        }
        if let redisDatabase = connection.redisDatabase {
            fields[.redisDatabase] = Int64(redisDatabase)
        }
        if let startupCommands = connection.startupCommands {
            fields[.startupCommands] = startupCommands
        }
        if let sshProfileId = connection.sshProfileId {
            fields[.sshProfileId] = sshProfileId.uuidString
        }

        // Encode complex structs as JSON Data — contract device-local paths
        // to portable ~/… form so they resolve correctly on other devices.
        // Note: sshTunnelMode is intentionally NOT synced — it is re-derived
        // on decode from sshConfig + sshProfileId. If adding sshTunnelMode to
        // the sync schema in the future, apply path contraction to its snapshot.
        // cloudflareTunnelMode, cloudSQLProxyMode, and socksProxyMode are also NOT
        // synced: they are device-local runtime config and their secrets live in
        // the Keychain.
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
        if !connection.additionalFields.isEmpty {
            do {
                let fieldsData = try encoder.encode(connection.additionalFields)
                fields[.additionalFieldsJson] = fieldsData
            } catch {
                logger.warning("Failed to encode additional fields for sync: \(error.localizedDescription)")
            }
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
        let colorRaw = fields[.color] as? String ?? ConnectionColor.none.rawValue
        let isReadOnly = (fields[.isReadOnly] as? Int64 ?? 0) != 0
        let safeModeLevel = Self.safeModeLevel(fromWire: fields[.safeModeLevel] as? String, isReadOnly: isReadOnly)
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

        return DatabaseConnection(
            id: connectionId,
            name: name,
            host: host,
            port: port,
            database: database,
            username: username,
            type: connectionType,
            sshConfig: sshConfig,
            sslConfig: sslConfig,
            color: ConnectionColor(rawValue: colorRaw) ?? .none,
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
            additionalFields: additionalFields
        )
    }

    static func safeModeLevel(fromWire raw: String?, isReadOnly: Bool) -> SafeModeLevel {
        guard let raw else { return isReadOnly ? .readOnly : .silent }
        if let level = SafeModeLevel(rawValue: raw) { return level }
        switch raw {
        case "off": return .silent
        case "confirmWrites": return .alert
        default: return isReadOnly ? .readOnly : .alert
        }
    }

    // MARK: - Connection Group

    static func toCKRecord(_ group: ConnectionGroup, in zone: CKRecordZone.ID) -> CKRecord {
        let recordID = recordID(type: .group, id: group.id.uuidString, in: zone)
        let record = CKRecord(recordType: SyncRecordType.group.rawValue, recordID: recordID)

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
            parentId: parentId,
            sortOrder: sortOrder
        )
    }

    // MARK: - Connection Tag

    static func toCKRecord(_ tag: ConnectionTag, in zone: CKRecordZone.ID) -> CKRecord {
        let recordID = recordID(type: .tag, id: tag.id.uuidString, in: zone)
        let record = CKRecord(recordType: SyncRecordType.tag.rawValue, recordID: recordID)

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
        in zone: CKRecordZone.ID
    ) -> CKRecord {
        let recordID = recordID(type: .settings, id: category, in: zone)
        let record = CKRecord(recordType: SyncRecordType.settings.rawValue, recordID: recordID)

        let fields = record.fields(AppSettingsSyncField.self)
        fields[.category] = category
        fields[.settingsJson] = settingsData
        fields[.modifiedAtLocal] = Date()
        fields[.schemaVersion] = schemaVersion

        return record
    }

    static func settingsCategory(from record: CKRecord) -> String? {
        record.fields(AppSettingsSyncField.self)[.category] as? String
    }

    static func settingsData(from record: CKRecord) -> Data? {
        record.fields(AppSettingsSyncField.self)[.settingsJson] as? Data
    }

    // MARK: - Table Favorite

    static func toCKRecord(favoriteEntry entry: FavoriteTablesStorage.FavoriteEntry, in zone: CKRecordZone.ID) -> CKRecord {
        let favoriteId = FavoriteTablesStorage.syncId(for: entry)
        let recordID = recordID(type: .tableFavorite, id: favoriteId, in: zone)
        let record = CKRecord(recordType: SyncRecordType.tableFavorite.rawValue, recordID: recordID)

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

    static func toCKRecord(favoriteDatabase entry: FavoriteDatabaseEntry, in zone: CKRecordZone.ID) -> CKRecord {
        let favoriteId = FavoriteDatabasesStorage.syncId(for: entry)
        let recordID = recordID(type: .favoriteDatabase, id: favoriteId, in: zone)
        let record = CKRecord(recordType: SyncRecordType.favoriteDatabase.rawValue, recordID: recordID)

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

    static func toCKRecord(sqlFavorite favorite: SQLFavorite, in zone: CKRecordZone.ID) -> CKRecord {
        let recordID = recordID(type: .favorite, id: favorite.id.uuidString, in: zone)
        let record = CKRecord(recordType: SyncRecordType.favorite.rawValue, recordID: recordID)

        let fields = record.fields(SQLFavoriteSyncField.self)
        fields[.favoriteId] = favorite.id.uuidString
        fields[.name] = favorite.name
        fields[.query] = favorite.query
        if let keyword = favorite.keyword {
            fields[.keyword] = keyword
        }
        if let folderId = favorite.folderId {
            fields[.folderId] = folderId.uuidString
        }
        if let connectionId = favorite.connectionId {
            fields[.connectionId] = connectionId.uuidString
        }
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

    static func toCKRecord(sqlFavoriteFolder folder: SQLFavoriteFolder, in zone: CKRecordZone.ID) -> CKRecord {
        let recordID = recordID(type: .favoriteFolder, id: folder.id.uuidString, in: zone)
        let record = CKRecord(recordType: SyncRecordType.favoriteFolder.rawValue, recordID: recordID)

        let fields = record.fields(SQLFavoriteFolderSyncField.self)
        fields[.folderId] = folder.id.uuidString
        fields[.name] = folder.name
        if let parentId = folder.parentId {
            fields[.parentId] = parentId.uuidString
        }
        if let connectionId = folder.connectionId {
            fields[.connectionId] = connectionId.uuidString
        }
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

    // MARK: - SSH Profile

    static func toCKRecord(_ profile: SSHProfile, in zone: CKRecordZone.ID) -> CKRecord {
        let recordID = recordID(type: .sshProfile, id: profile.id.uuidString, in: zone)
        let record = CKRecord(recordType: SyncRecordType.sshProfile.rawValue, recordID: recordID)

        let fields = record.fields(SSHProfileSyncField.self)
        fields[.profileId] = profile.id.uuidString
        fields[.name] = profile.name
        fields[.host] = profile.host
        if let port = profile.port {
            fields[.port] = Int64(port)
        }
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

        if !profile.jumpHosts.isEmpty {
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

    // MARK: - Path Portability
    // Contract device-local paths to portable ~/… form before pushing to iCloud,
    // expand them back to device-local form when pulling. Matches the proven
    // pattern in ConnectionExportService.

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
