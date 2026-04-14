//
//  ConnectionStorage.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import Foundation
import os
import TableProPluginKit

/// Service for persisting database connections
@MainActor
final class ConnectionStorage {
    static let shared = ConnectionStorage()
    private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionStorage")

    private let connectionsKey = "com.TablePro.connections"
    private let migratedToFileKey = "com.TablePro.connectionsMigratedToFile"
    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// In-memory cache to avoid re-decoding JSON from file on every access
    private var cachedConnections: [DatabaseConnection]?

    private let fileURL: URL

    private init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("TablePro", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("connections.json")

        migrateFromUserDefaultsIfNeeded()
    }

    /// One-time migration from UserDefaults to atomic file storage.
    private func migrateFromUserDefaultsIfNeeded() {
        guard !defaults.bool(forKey: migratedToFileKey),
              let data = defaults.data(forKey: connectionsKey) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
            defaults.set(true, forKey: migratedToFileKey)
            defaults.removeObject(forKey: connectionsKey)
            Self.logger.info("Migrated connections from UserDefaults to \(self.fileURL.path)")
        } catch {
            Self.logger.error("Failed to migrate connections to file: \(error)")
        }
    }

    // MARK: - Connection CRUD

    /// Load all saved connections
    func loadConnections() -> [DatabaseConnection] {
        if let cached = cachedConnections { return cached }

        guard let data = try? Data(contentsOf: fileURL) else {
            return []
        }

        do {
            let storedConnections = try decoder.decode([StoredConnection].self, from: data)

            let connections = storedConnections.map { stored in
                stored.toConnection()
            }

            // Migration: assign sortOrder from array position for pre-existing data
            if connections.count > 1 && connections.allSatisfy({ $0.sortOrder == 0 }) {
                var migrated = connections
                for i in migrated.indices { migrated[i].sortOrder = i }
                let migratedStored = migrated.map { StoredConnection(from: $0) }
                if let data = try? encoder.encode(migratedStored) {
                    try? data.write(to: fileURL, options: .atomic)
                }
                cachedConnections = migrated
                return migrated
            }

            cachedConnections = connections
            return connections
        } catch {
            Self.logger.error("Failed to load connections: \(error)")
            return []
        }
    }

    /// Save all connections
    func saveConnections(_ connections: [DatabaseConnection]) {
        let storedConnections = connections.map { StoredConnection(from: $0) }

        do {
            let data = try encoder.encode(storedConnections)
            try data.write(to: fileURL, options: .atomic)
            cachedConnections = nil
        } catch {
            Self.logger.error("Failed to save connections: \(error)")
        }
    }

    /// Invalidate the in-memory cache so the next load reads fresh from UserDefaults.
    func invalidateCache() {
        cachedConnections = nil
    }

    /// Add a new connection
    func addConnection(_ connection: DatabaseConnection, password: String? = nil) {
        var connections = loadConnections()
        connections.append(connection)
        saveConnections(connections)
        SyncChangeTracker.shared.markDirty(.connection, id: connection.id.uuidString)

        if let password = password, !password.isEmpty {
            savePassword(password, for: connection.id)
        }
    }

    /// Update an existing connection
    func updateConnection(_ connection: DatabaseConnection, password: String? = nil) {
        var connections = loadConnections()
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index] = connection
            saveConnections(connections)
            SyncChangeTracker.shared.markDirty(.connection, id: connection.id.uuidString)

            if let password = password {
                if password.isEmpty {
                    deletePassword(for: connection.id)
                } else {
                    savePassword(password, for: connection.id)
                }
            }
        }
    }

    /// Delete a connection
    func deleteConnection(_ connection: DatabaseConnection) {
        SyncChangeTracker.shared.markDeleted(.connection, id: connection.id.uuidString)
        var connections = loadConnections()
        connections.removeAll { $0.id == connection.id }
        saveConnections(connections)
        deletePassword(for: connection.id)
        deleteSSHPassword(for: connection.id)
        deleteKeyPassphrase(for: connection.id)
        deleteTOTPSecret(for: connection.id)

        let secureFieldIds = Self.secureFieldIds(for: connection.type)
        deleteAllPluginSecureFields(for: connection.id, fieldIds: secureFieldIds)
    }

    /// Batch-delete multiple connections and clean up their Keychain entries
    func deleteConnections(_ connectionsToDelete: [DatabaseConnection]) {
        for conn in connectionsToDelete {
            SyncChangeTracker.shared.markDeleted(.connection, id: conn.id.uuidString)
        }
        let idsToDelete = Set(connectionsToDelete.map(\.id))
        var all = loadConnections()
        all.removeAll { idsToDelete.contains($0.id) }
        saveConnections(all)
        for conn in connectionsToDelete {
            deletePassword(for: conn.id)
            deleteSSHPassword(for: conn.id)
            deleteKeyPassphrase(for: conn.id)
            deleteTOTPSecret(for: conn.id)
            let fields = Self.secureFieldIds(for: conn.type)
            deleteAllPluginSecureFields(for: conn.id, fieldIds: fields)
        }
    }

    /// Duplicate a connection with a new UUID and "(Copy)" suffix
    /// Copies all passwords from source connection to the duplicate
    func duplicateConnection(_ connection: DatabaseConnection) -> DatabaseConnection {
        let newId = UUID()

        // Create duplicate with new ID and "(Copy)" suffix
        let duplicate = DatabaseConnection(
            id: newId,
            name: "\(connection.name) (Copy)",
            host: connection.host,
            port: connection.port,
            database: connection.database,
            username: connection.username,
            type: connection.type,
            sshConfig: connection.sshConfig,
            sslConfig: connection.sslConfig,
            color: connection.color,
            tagId: connection.tagId,
            groupId: connection.groupId,
            sshProfileId: connection.sshProfileId,
            safeModeLevel: connection.safeModeLevel,
            aiPolicy: connection.aiPolicy,
            redisDatabase: connection.redisDatabase,
            startupCommands: connection.startupCommands,
            additionalFields: connection.additionalFields.isEmpty ? nil : connection.additionalFields
        )

        // Save the duplicate connection
        var connections = loadConnections()
        connections.append(duplicate)
        saveConnections(connections)
        SyncChangeTracker.shared.markDirty(.connection, id: duplicate.id.uuidString)

        // Copy all passwords from source to duplicate (skip DB password in prompt mode)
        if !connection.promptForPassword, let password = loadPassword(for: connection.id) {
            savePassword(password, for: newId)
        }
        if let sshPassword = loadSSHPassword(for: connection.id) {
            saveSSHPassword(sshPassword, for: newId)
        }
        if let keyPassphrase = loadKeyPassphrase(for: connection.id) {
            saveKeyPassphrase(keyPassphrase, for: newId)
        }
        if let totpSecret = loadTOTPSecret(for: connection.id) {
            saveTOTPSecret(totpSecret, for: newId)
        }

        let secureFieldIds = Self.secureFieldIds(for: connection.type)
        for fieldId in secureFieldIds {
            if let value = loadPluginSecureField(fieldId: fieldId, for: connection.id) {
                savePluginSecureField(value, fieldId: fieldId, for: newId)
            }
        }

        return duplicate
    }

    // MARK: - Keychain (Password Storage)

    func savePassword(_ password: String, for connectionId: UUID) {
        let key = "com.TablePro.password.\(connectionId.uuidString)"
        KeychainHelper.shared.saveString(password, forKey: key)
    }

    func loadPassword(for connectionId: UUID) -> String? {
        let key = "com.TablePro.password.\(connectionId.uuidString)"
        return KeychainHelper.shared.loadString(forKey: key)
    }

    func deletePassword(for connectionId: UUID) {
        let key = "com.TablePro.password.\(connectionId.uuidString)"
        KeychainHelper.shared.delete(key: key)
    }

    // MARK: - SSH Password Storage

    func saveSSHPassword(_ password: String, for connectionId: UUID) {
        let key = "com.TablePro.sshpassword.\(connectionId.uuidString)"
        KeychainHelper.shared.saveString(password, forKey: key)
    }

    func loadSSHPassword(for connectionId: UUID) -> String? {
        let key = "com.TablePro.sshpassword.\(connectionId.uuidString)"
        return KeychainHelper.shared.loadString(forKey: key)
    }

    func deleteSSHPassword(for connectionId: UUID) {
        let key = "com.TablePro.sshpassword.\(connectionId.uuidString)"
        KeychainHelper.shared.delete(key: key)
    }

    // MARK: - Key Passphrase Storage

    func saveKeyPassphrase(_ passphrase: String, for connectionId: UUID) {
        let key = "com.TablePro.keypassphrase.\(connectionId.uuidString)"
        KeychainHelper.shared.saveString(passphrase, forKey: key)
    }

    func loadKeyPassphrase(for connectionId: UUID) -> String? {
        let key = "com.TablePro.keypassphrase.\(connectionId.uuidString)"
        return KeychainHelper.shared.loadString(forKey: key)
    }

    func deleteKeyPassphrase(for connectionId: UUID) {
        let key = "com.TablePro.keypassphrase.\(connectionId.uuidString)"
        KeychainHelper.shared.delete(key: key)
    }

    // MARK: - Plugin Secure Field Storage

    func savePluginSecureField(_ value: String, fieldId: String, for connectionId: UUID) {
        let key = "com.TablePro.plugin.\(fieldId).\(connectionId.uuidString)"
        KeychainHelper.shared.saveString(value, forKey: key)
    }

    func loadPluginSecureField(fieldId: String, for connectionId: UUID) -> String? {
        let key = "com.TablePro.plugin.\(fieldId).\(connectionId.uuidString)"
        return KeychainHelper.shared.loadString(forKey: key)
    }

    func deletePluginSecureField(fieldId: String, for connectionId: UUID) {
        let key = "com.TablePro.plugin.\(fieldId).\(connectionId.uuidString)"
        KeychainHelper.shared.delete(key: key)
    }

    func deleteAllPluginSecureFields(for connectionId: UUID, fieldIds: [String]) {
        for fieldId in fieldIds {
            deletePluginSecureField(fieldId: fieldId, for: connectionId)
        }
    }

    // MARK: - TOTP Secret Storage

    func saveTOTPSecret(_ secret: String, for connectionId: UUID) {
        let key = "com.TablePro.totpsecret.\(connectionId.uuidString)"
        KeychainHelper.shared.saveString(secret, forKey: key)
    }

    func loadTOTPSecret(for connectionId: UUID) -> String? {
        let key = "com.TablePro.totpsecret.\(connectionId.uuidString)"
        return KeychainHelper.shared.loadString(forKey: key)
    }

    func deleteTOTPSecret(for connectionId: UUID) {
        let key = "com.TablePro.totpsecret.\(connectionId.uuidString)"
        KeychainHelper.shared.delete(key: key)
    }

    // MARK: - Plugin Secure Field Migration

    private static func secureFieldIds(for databaseType: DatabaseType) -> [String] {
        (PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .connection.additionalConnectionFields ?? [])
            .filter(\.isSecure).map(\.id)
    }

    func migratePluginSecureFieldsIfNeeded() {
        let migrationKey = "com.TablePro.pluginSecureFieldsMigrated"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: migrationKey) }

        var connections = loadConnections()
        var changed = false

        for index in connections.indices {
            let secureFields = (PluginMetadataRegistry.shared
                .snapshot(forTypeId: connections[index].type.pluginTypeId)?
                .connection.additionalConnectionFields ?? [])
                .filter(\.isSecure)
            for field in secureFields {
                if let value = connections[index].additionalFields[field.id], !value.isEmpty {
                    savePluginSecureField(value, fieldId: field.id, for: connections[index].id)
                    connections[index].additionalFields.removeValue(forKey: field.id)
                    changed = true
                }
            }
        }

        if changed {
            saveConnections(connections)
        }
    }
}

// MARK: - Stored Connection (Codable wrapper)

private struct StoredConnection: Codable {
    let id: UUID
    let name: String
    let host: String
    let port: Int
    let database: String
    let username: String
    let type: String

    // SSH Configuration
    let sshEnabled: Bool
    let sshHost: String
    let sshPort: Int
    let sshUsername: String
    let sshAuthMethod: String
    let sshPrivateKeyPath: String
    let sshUseSSHConfig: Bool
    let sshAgentSocketPath: String

    // SSL Configuration
    let sslMode: String
    let sslCaCertificatePath: String
    let sslClientCertificatePath: String
    let sslClientKeyPath: String

    // Color, Tag, and Group
    let color: String
    let tagId: String?
    let groupId: String?
    let sshProfileId: String?

    // Safe mode level
    let safeModeLevel: String

    // AI policy
    let aiPolicy: String?

    // MongoDB-specific
    let mongoAuthSource: String?
    let mongoReadPreference: String?
    let mongoWriteConcern: String?

    // Redis-specific
    let redisDatabase: Int?

    // MSSQL schema
    let mssqlSchema: String?

    // Oracle service name
    let oracleServiceName: String?

    // Startup commands
    let startupCommands: String?

    // Sort order for sync
    let sortOrder: Int

    // TOTP configuration
    let totpMode: String
    let totpAlgorithm: String
    let totpDigits: Int
    let totpPeriod: Int

    // Plugin-driven additional fields
    let additionalFields: [String: String]?

    init(from connection: DatabaseConnection) {
        self.id = connection.id
        self.name = connection.name
        self.host = connection.host
        self.port = connection.port
        self.database = connection.database
        self.username = connection.username
        self.type = connection.type.rawValue

        // SSH Configuration
        self.sshEnabled = connection.sshConfig.enabled
        self.sshHost = connection.sshConfig.host
        self.sshPort = connection.sshConfig.port
        self.sshUsername = connection.sshConfig.username
        self.sshAuthMethod = connection.sshConfig.authMethod.rawValue
        self.sshPrivateKeyPath = connection.sshConfig.privateKeyPath
        self.sshUseSSHConfig = connection.sshConfig.useSSHConfig
        self.sshAgentSocketPath = connection.sshConfig.agentSocketPath

        // TOTP configuration
        self.totpMode = connection.sshConfig.totpMode.rawValue
        self.totpAlgorithm = connection.sshConfig.totpAlgorithm.rawValue
        self.totpDigits = connection.sshConfig.totpDigits
        self.totpPeriod = connection.sshConfig.totpPeriod

        // SSL Configuration
        self.sslMode = connection.sslConfig.mode.rawValue
        self.sslCaCertificatePath = connection.sslConfig.caCertificatePath
        self.sslClientCertificatePath = connection.sslConfig.clientCertificatePath
        self.sslClientKeyPath = connection.sslConfig.clientKeyPath

        // Color, Tag, and Group
        self.color = connection.color.rawValue
        self.tagId = connection.tagId?.uuidString
        self.groupId = connection.groupId?.uuidString
        self.sshProfileId = connection.sshProfileId?.uuidString

        // Safe mode level
        self.safeModeLevel = connection.safeModeLevel.rawValue

        // AI policy
        self.aiPolicy = connection.aiPolicy?.rawValue

        // MongoDB-specific
        self.mongoAuthSource = connection.mongoAuthSource
        self.mongoReadPreference = connection.mongoReadPreference
        self.mongoWriteConcern = connection.mongoWriteConcern

        // Redis-specific
        self.redisDatabase = connection.redisDatabase

        // MSSQL schema
        self.mssqlSchema = connection.mssqlSchema

        // Oracle service name
        self.oracleServiceName = connection.oracleServiceName

        // Startup commands
        self.startupCommands = connection.startupCommands

        // Sort order
        self.sortOrder = connection.sortOrder

        // Plugin-driven additional fields
        self.additionalFields = connection.additionalFields.isEmpty ? nil : connection.additionalFields
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, database, username, type
        case sshEnabled, sshHost, sshPort, sshUsername, sshAuthMethod, sshPrivateKeyPath
        case sshUseSSHConfig, sshAgentSocketPath
        case totpMode, totpAlgorithm, totpDigits, totpPeriod
        case sslMode, sslCaCertificatePath, sslClientCertificatePath, sslClientKeyPath
        case color, tagId, groupId, sshProfileId
        case safeModeLevel
        case isReadOnly // Legacy key for migration reading only
        case aiPolicy
        case mongoAuthSource, mongoReadPreference, mongoWriteConcern, redisDatabase
        case mssqlSchema, oracleServiceName, startupCommands, sortOrder
        case additionalFields
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(database, forKey: .database)
        try container.encode(username, forKey: .username)
        try container.encode(type, forKey: .type)
        try container.encode(sshEnabled, forKey: .sshEnabled)
        try container.encode(sshHost, forKey: .sshHost)
        try container.encode(sshPort, forKey: .sshPort)
        try container.encode(sshUsername, forKey: .sshUsername)
        try container.encode(sshAuthMethod, forKey: .sshAuthMethod)
        try container.encode(sshPrivateKeyPath, forKey: .sshPrivateKeyPath)
        try container.encode(sshUseSSHConfig, forKey: .sshUseSSHConfig)
        try container.encode(sshAgentSocketPath, forKey: .sshAgentSocketPath)
        try container.encode(totpMode, forKey: .totpMode)
        try container.encode(totpAlgorithm, forKey: .totpAlgorithm)
        try container.encode(totpDigits, forKey: .totpDigits)
        try container.encode(totpPeriod, forKey: .totpPeriod)
        try container.encode(sslMode, forKey: .sslMode)
        try container.encode(sslCaCertificatePath, forKey: .sslCaCertificatePath)
        try container.encode(sslClientCertificatePath, forKey: .sslClientCertificatePath)
        try container.encode(sslClientKeyPath, forKey: .sslClientKeyPath)
        try container.encode(color, forKey: .color)
        try container.encodeIfPresent(tagId, forKey: .tagId)
        try container.encodeIfPresent(groupId, forKey: .groupId)
        try container.encodeIfPresent(sshProfileId, forKey: .sshProfileId)
        try container.encode(safeModeLevel, forKey: .safeModeLevel)
        try container.encodeIfPresent(aiPolicy, forKey: .aiPolicy)
        try container.encodeIfPresent(redisDatabase, forKey: .redisDatabase)
        try container.encodeIfPresent(startupCommands, forKey: .startupCommands)
        try container.encode(sortOrder, forKey: .sortOrder)
        try container.encodeIfPresent(additionalFields, forKey: .additionalFields)
    }

    // Custom decoder to handle migration from old format
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        database = try container.decode(String.self, forKey: .database)
        username = try container.decode(String.self, forKey: .username)
        type = try container.decode(String.self, forKey: .type)

        sshEnabled = try container.decode(Bool.self, forKey: .sshEnabled)
        sshHost = try container.decode(String.self, forKey: .sshHost)
        sshPort = try container.decode(Int.self, forKey: .sshPort)
        sshUsername = try container.decode(String.self, forKey: .sshUsername)
        sshAuthMethod = try container.decode(String.self, forKey: .sshAuthMethod)
        sshPrivateKeyPath = try container.decode(String.self, forKey: .sshPrivateKeyPath)
        sshUseSSHConfig = try container.decode(Bool.self, forKey: .sshUseSSHConfig)
        sshAgentSocketPath = try container.decodeIfPresent(String.self, forKey: .sshAgentSocketPath) ?? ""

        // TOTP configuration (migration: use defaults if missing)
        totpMode = try container.decodeIfPresent(String.self, forKey: .totpMode) ?? TOTPMode.none.rawValue
        totpAlgorithm = try container.decodeIfPresent(
            String.self, forKey: .totpAlgorithm
        ) ?? TOTPAlgorithm.sha1.rawValue
        let decodedDigits = try container.decodeIfPresent(Int.self, forKey: .totpDigits) ?? 6
        totpDigits = max(6, min(8, decodedDigits))
        let decodedPeriod = try container.decodeIfPresent(Int.self, forKey: .totpPeriod) ?? 30
        totpPeriod = max(15, min(120, decodedPeriod))

        // SSL Configuration (migration: use defaults if missing)
        sslMode = try container.decodeIfPresent(String.self, forKey: .sslMode) ?? SSLMode.disabled.rawValue
        sslCaCertificatePath = try container.decodeIfPresent(String.self, forKey: .sslCaCertificatePath) ?? ""
        sslClientCertificatePath = try container.decodeIfPresent(
            String.self, forKey: .sslClientCertificatePath
        ) ?? ""
        sslClientKeyPath = try container.decodeIfPresent(String.self, forKey: .sslClientKeyPath) ?? ""

        // Migration: use defaults if fields are missing
        color = try container.decodeIfPresent(String.self, forKey: .color) ?? ConnectionColor.none.rawValue
        tagId = try container.decodeIfPresent(String.self, forKey: .tagId)
        groupId = try container.decodeIfPresent(String.self, forKey: .groupId)
        sshProfileId = try container.decodeIfPresent(String.self, forKey: .sshProfileId)
        // Migration: read new safeModeLevel first, fall back to old isReadOnly boolean
        if let levelString = try container.decodeIfPresent(String.self, forKey: .safeModeLevel) {
            safeModeLevel = levelString
        } else {
            let wasReadOnly = try container.decodeIfPresent(Bool.self, forKey: .isReadOnly) ?? false
            safeModeLevel = wasReadOnly ? SafeModeLevel.readOnly.rawValue : SafeModeLevel.silent.rawValue
        }
        aiPolicy = try container.decodeIfPresent(String.self, forKey: .aiPolicy)
        mongoAuthSource = try container.decodeIfPresent(String.self, forKey: .mongoAuthSource)
        mongoReadPreference = try container.decodeIfPresent(String.self, forKey: .mongoReadPreference)
        mongoWriteConcern = try container.decodeIfPresent(String.self, forKey: .mongoWriteConcern)
        redisDatabase = try container.decodeIfPresent(Int.self, forKey: .redisDatabase)
        mssqlSchema = try container.decodeIfPresent(String.self, forKey: .mssqlSchema)
        oracleServiceName = try container.decodeIfPresent(String.self, forKey: .oracleServiceName)
        startupCommands = try container.decodeIfPresent(String.self, forKey: .startupCommands)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        additionalFields = try container.decodeIfPresent([String: String].self, forKey: .additionalFields)
    }

    func toConnection() -> DatabaseConnection {
        var sshConfig = SSHConfiguration(
            enabled: sshEnabled,
            host: sshHost,
            port: sshPort,
            username: sshUsername,
            authMethod: SSHAuthMethod(rawValue: sshAuthMethod) ?? .password,
            privateKeyPath: sshPrivateKeyPath,
            useSSHConfig: sshUseSSHConfig,
            agentSocketPath: sshAgentSocketPath
        )
        sshConfig.totpMode = TOTPMode(rawValue: totpMode) ?? .none
        sshConfig.totpAlgorithm = TOTPAlgorithm(rawValue: totpAlgorithm) ?? .sha1
        sshConfig.totpDigits = totpDigits
        sshConfig.totpPeriod = totpPeriod

        let sslConfig = SSLConfiguration(
            mode: SSLMode(rawValue: sslMode) ?? .disabled,
            caCertificatePath: sslCaCertificatePath,
            clientCertificatePath: sslClientCertificatePath,
            clientKeyPath: sslClientKeyPath
        )

        let parsedColor = ConnectionColor(rawValue: color) ?? .none
        let parsedTagId = tagId.flatMap { UUID(uuidString: $0) }
        let parsedGroupId = groupId.flatMap { UUID(uuidString: $0) }
        let parsedSSHProfileId = sshProfileId.flatMap { UUID(uuidString: $0) }
        let parsedAIPolicy = aiPolicy.flatMap { AIConnectionPolicy(rawValue: $0) }

        // Merge legacy named keys into additionalFields as fallback
        let mergedFields: [String: String]? = {
            var fields = additionalFields ?? [:]
            if fields["mongoAuthSource"] == nil, let v = mongoAuthSource { fields["mongoAuthSource"] = v }
            if fields["mongoReadPreference"] == nil, let v = mongoReadPreference {
                fields["mongoReadPreference"] = v
            }
            if fields["mongoWriteConcern"] == nil, let v = mongoWriteConcern {
                fields["mongoWriteConcern"] = v
            }
            if fields["mssqlSchema"] == nil, let v = mssqlSchema { fields["mssqlSchema"] = v }
            if fields["oracleServiceName"] == nil, let v = oracleServiceName {
                fields["oracleServiceName"] = v
            }
            return fields.isEmpty ? nil : fields
        }()

        return DatabaseConnection(
            id: id,
            name: name,
            host: host,
            port: port,
            database: database,
            username: username,
            type: DatabaseType(rawValue: type),
            sshConfig: sshConfig,
            sslConfig: sslConfig,
            color: parsedColor,
            tagId: parsedTagId,
            groupId: parsedGroupId,
            sshProfileId: parsedSSHProfileId,
            safeModeLevel: SafeModeLevel(rawValue: safeModeLevel) ?? .silent,
            aiPolicy: parsedAIPolicy,
            redisDatabase: redisDatabase,
            startupCommands: startupCommands,
            sortOrder: sortOrder,
            additionalFields: mergedFields
        )
    }
}
