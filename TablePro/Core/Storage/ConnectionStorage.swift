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
    private let defaults: UserDefaults
    private let syncTracker: SyncChangeTracker
    private let appSettingsProvider: () -> AppSettingsStorage
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// In-memory cache to avoid re-decoding JSON from file on every access
    private var cachedConnections: [DatabaseConnection]?

    private let fileURL: URL

    private let keychain: any KeychainStoring

    init(
        fileURL: URL = ConnectionStorage.defaultFileURL(),
        userDefaults: UserDefaults = .standard,
        syncTracker: SyncChangeTracker = .shared,
        appSettings: @escaping @autoclosure () -> AppSettingsStorage = .shared,
        keychain: any KeychainStoring = KeychainHelper.shared
    ) {
        self.fileURL = fileURL
        self.defaults = userDefaults
        self.syncTracker = syncTracker
        self.appSettingsProvider = appSettings
        self.keychain = keychain

        migrateFromUserDefaultsIfNeeded()
    }

    nonisolated static func defaultFileURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("TablePro", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("connections.json")
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

    func loadConnection(id: UUID) -> DatabaseConnection? {
        loadConnections().first { $0.id == id }
    }

    /// Save all connections. Returns `true` if persisted, `false` if encoding or
    /// the atomic write failed. Callers that mutate dependent state (sync tracker,
    /// keychain entries) MUST check the return value and abort on `false`.
    /// Continuing on a failed save can nuke a user's password while leaving the
    /// connection record on disk, then have the next sync delete the record from
    /// iCloud too.
    @discardableResult
    func saveConnections(_ connections: [DatabaseConnection]) -> Bool {
        let storedConnections = connections.map { StoredConnection(from: $0) }

        do {
            let data = try encoder.encode(storedConnections)
            try data.write(to: fileURL, options: .atomic)
            cachedConnections = nil
            return true
        } catch {
            Self.logger.error("Failed to save connections: \(error)")
            return false
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
        guard saveConnections(connections) else {
            Self.logger.error("Aborted addConnection: persistence failed for \(connection.id, privacy: .public)")
            return
        }
        if !connection.localOnly && !connection.isSample {
            syncTracker.markDirty(.connection, id: connection.id.uuidString)
        }

        if let password = password, !password.isEmpty {
            savePassword(password, for: connection.id)
        }
    }

    /// Update an existing connection
    func updateConnection(_ connection: DatabaseConnection, password: String? = nil) {
        var connections = loadConnections()
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index] = connection
            guard saveConnections(connections) else {
                Self.logger.error("Aborted updateConnection: persistence failed for \(connection.id, privacy: .public)")
                return
            }
            if !connection.localOnly && !connection.isSample {
                syncTracker.markDirty(.connection, id: connection.id.uuidString)
            }

            if let password = password {
                if password.isEmpty {
                    deletePassword(for: connection.id)
                } else {
                    savePassword(password, for: connection.id)
                }
            }
        }
    }

    /// Update multiple connections in a single file write, marking each dirty for sync.
    @discardableResult
    func updateConnections(_ updates: [DatabaseConnection]) -> Bool {
        guard !updates.isEmpty else { return true }
        var connections = loadConnections()
        let updatesById = Dictionary(updates.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var didMutate = false
        for index in connections.indices {
            if let replacement = updatesById[connections[index].id] {
                connections[index] = replacement
                didMutate = true
            }
        }
        guard didMutate, saveConnections(connections) else {
            return false
        }
        let dirtyIds = updatesById.values
            .filter { !$0.localOnly && !$0.isSample }
            .map { $0.id.uuidString }
        syncTracker.markDirty(.connection, ids: dirtyIds)
        return true
    }

    @discardableResult
    func updateSafeModeLevel(_ level: SafeModeLevel, for connectionId: UUID) -> Bool {
        var connections = loadConnections()
        guard let index = connections.firstIndex(where: { $0.id == connectionId }) else {
            Self.logger.notice(
                "Skipped updateSafeModeLevel: connection not found for \(connectionId, privacy: .public)"
            )
            return false
        }

        guard connections[index].safeModeLevel != level else { return true }

        connections[index].safeModeLevel = level
        guard saveConnections(connections) else {
            Self.logger.error(
                "Aborted updateSafeModeLevel: persistence failed for \(connectionId, privacy: .public)"
            )
            return false
        }

        let updatedConnection = connections[index]
        if !updatedConnection.localOnly && !updatedConnection.isSample {
            syncTracker.markDirty(.connection, id: updatedConnection.id.uuidString)
        }

        return true
    }

    /// Delete a connection
    func deleteConnection(_ connection: DatabaseConnection) {
        var connections = loadConnections()
        connections.removeAll { $0.id == connection.id }
        guard saveConnections(connections) else {
            Self.logger.error("Aborted deleteConnection: persistence failed for \(connection.id, privacy: .public)")
            return
        }
        if !connection.localOnly && !connection.isSample {
            syncTracker.markDeleted(.connection, id: connection.id.uuidString)
        }
        deletePassword(for: connection.id)
        deleteSSHPassword(for: connection.id)
        deleteKeyPassphrase(for: connection.id)
        deleteSSLClientKeyPassphrase(for: connection.id)
        deleteTOTPSecret(for: connection.id)
        deleteCloudflareTokenId(for: connection.id)
        deleteCloudflareTokenSecret(for: connection.id)

        let secureFieldIds = Self.secureFieldIds(for: connection.type)
        deleteAllPluginSecureFields(for: connection.id, fieldIds: secureFieldIds)

        let appSettings = appSettingsProvider()
        appSettings.saveLastDatabase(nil, for: connection.id)
        appSettings.saveLastSchema(nil, for: connection.id)

        FavoriteTablesStorage.shared.removeFavorites(for: connection.id)
    }

    /// Batch-delete multiple connections and clean up their Keychain entries
    func deleteConnections(_ connectionsToDelete: [DatabaseConnection]) {
        let idsToDelete = Set(connectionsToDelete.map(\.id))
        var all = loadConnections()
        all.removeAll { idsToDelete.contains($0.id) }
        guard saveConnections(all) else {
            Self.logger.error("Aborted deleteConnections: persistence failed for \(idsToDelete.count, privacy: .public) connection(s)")
            return
        }
        for conn in connectionsToDelete where !conn.localOnly && !conn.isSample {
            syncTracker.markDeleted(.connection, id: conn.id.uuidString)
        }
        for conn in connectionsToDelete {
            deletePassword(for: conn.id)
            deleteSSHPassword(for: conn.id)
            deleteKeyPassphrase(for: conn.id)
            deleteSSLClientKeyPassphrase(for: conn.id)
            deleteTOTPSecret(for: conn.id)
            deleteCloudflareTokenId(for: conn.id)
            deleteCloudflareTokenSecret(for: conn.id)
            let fields = Self.secureFieldIds(for: conn.type)
            deleteAllPluginSecureFields(for: conn.id, fieldIds: fields)
            let appSettings = appSettingsProvider()
            appSettings.saveLastDatabase(nil, for: conn.id)
            appSettings.saveLastSchema(nil, for: conn.id)
            FavoriteTablesStorage.shared.removeFavorites(for: conn.id)
        }
    }

    /// Duplicate a connection with a new UUID and "(Copy)" suffix
    /// Copies all passwords from source connection to the duplicate
    func duplicateConnection(_ connection: DatabaseConnection) -> DatabaseConnection {
        let newId = UUID()

        // Create duplicate with new ID and "(Copy)" suffix
        let duplicate = DatabaseConnection(
            id: newId,
            name: String(format: String(localized: "%@ (Copy)"), connection.name),
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
            sshTunnelMode: connection.sshTunnelMode,
            safeModeLevel: connection.safeModeLevel,
            aiPolicy: connection.aiPolicy,
            aiRules: connection.aiRules,
            aiAlwaysAllowedTools: connection.aiAlwaysAllowedTools,
            redisDatabase: connection.redisDatabase,
            startupCommands: connection.startupCommands,
            sortOrder: connection.sortOrder,
            localOnly: connection.localOnly,
            passwordSource: connection.passwordSource,
            additionalFields: connection.additionalFields.isEmpty ? nil : connection.additionalFields
        )

        // Save the duplicate connection
        var connections = loadConnections()
        connections.append(duplicate)
        guard saveConnections(connections) else {
            Self.logger.error("Aborted duplicateConnection: persistence failed for \(duplicate.id, privacy: .public)")
            return duplicate
        }
        if !duplicate.localOnly {
            syncTracker.markDirty(.connection, id: duplicate.id.uuidString)
        }

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
        if let sslKeyPassphrase = loadSSLClientKeyPassphrase(for: connection.id) {
            saveSSLClientKeyPassphrase(sslKeyPassphrase, for: newId)
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
        keychain.writeString(password, forKey: key)
    }

    func loadPassword(for connectionId: UUID) -> String? {
        let key = "com.TablePro.password.\(connectionId.uuidString)"
        return resolveString(.init(label: "Database password", connectionId: connectionId), forKey: key)
    }

    func deletePassword(for connectionId: UUID) {
        let key = "com.TablePro.password.\(connectionId.uuidString)"
        keychain.delete(forKey: key)
    }

    // MARK: - SSH Password Storage

    func saveSSHPassword(_ password: String, for connectionId: UUID) {
        let key = "com.TablePro.sshpassword.\(connectionId.uuidString)"
        keychain.writeString(password, forKey: key)
    }

    func loadSSHPassword(for connectionId: UUID) -> String? {
        let key = "com.TablePro.sshpassword.\(connectionId.uuidString)"
        return resolveString(.init(label: "SSH password", connectionId: connectionId), forKey: key)
    }

    func deleteSSHPassword(for connectionId: UUID) {
        let key = "com.TablePro.sshpassword.\(connectionId.uuidString)"
        keychain.delete(forKey: key)
    }

    // MARK: - Key Passphrase Storage

    func saveKeyPassphrase(_ passphrase: String, for connectionId: UUID) {
        let key = "com.TablePro.keypassphrase.\(connectionId.uuidString)"
        keychain.writeString(passphrase, forKey: key)
    }

    func loadKeyPassphrase(for connectionId: UUID) -> String? {
        let key = "com.TablePro.keypassphrase.\(connectionId.uuidString)"
        return resolveString(.init(label: "Key passphrase", connectionId: connectionId), forKey: key)
    }

    func deleteKeyPassphrase(for connectionId: UUID) {
        let key = "com.TablePro.keypassphrase.\(connectionId.uuidString)"
        keychain.delete(forKey: key)
    }

    // MARK: - SSL Client Key Passphrase Storage

    func saveSSLClientKeyPassphrase(_ passphrase: String, for connectionId: UUID) {
        let key = "com.TablePro.sslkeypassphrase.\(connectionId.uuidString)"
        keychain.writeString(passphrase, forKey: key)
    }

    func loadSSLClientKeyPassphrase(for connectionId: UUID) -> String? {
        let key = "com.TablePro.sslkeypassphrase.\(connectionId.uuidString)"
        return resolveString(.init(label: "SSL client key passphrase", connectionId: connectionId), forKey: key)
    }

    func deleteSSLClientKeyPassphrase(for connectionId: UUID) {
        let key = "com.TablePro.sslkeypassphrase.\(connectionId.uuidString)"
        keychain.delete(forKey: key)
    }

    // MARK: - Plugin Secure Field Storage

    func savePluginSecureField(_ value: String, fieldId: String, for connectionId: UUID) {
        let key = "com.TablePro.plugin.\(fieldId).\(connectionId.uuidString)"
        keychain.writeString(value, forKey: key)
    }

    func loadPluginSecureField(fieldId: String, for connectionId: UUID) -> String? {
        let key = "com.TablePro.plugin.\(fieldId).\(connectionId.uuidString)"
        return resolveString(.init(label: "Plugin field \(fieldId)", connectionId: connectionId), forKey: key)
    }

    func deletePluginSecureField(fieldId: String, for connectionId: UUID) {
        let key = "com.TablePro.plugin.\(fieldId).\(connectionId.uuidString)"
        keychain.delete(forKey: key)
    }

    func deleteAllPluginSecureFields(for connectionId: UUID, fieldIds: [String]) {
        for fieldId in fieldIds {
            deletePluginSecureField(fieldId: fieldId, for: connectionId)
        }
    }

    // MARK: - TOTP Secret Storage

    func saveTOTPSecret(_ secret: String, for connectionId: UUID) {
        let key = "com.TablePro.totpsecret.\(connectionId.uuidString)"
        keychain.writeString(secret, forKey: key)
    }

    func loadTOTPSecret(for connectionId: UUID) -> String? {
        let key = "com.TablePro.totpsecret.\(connectionId.uuidString)"
        return resolveString(.init(label: "TOTP secret", connectionId: connectionId), forKey: key)
    }

    func deleteTOTPSecret(for connectionId: UUID) {
        let key = "com.TablePro.totpsecret.\(connectionId.uuidString)"
        keychain.delete(forKey: key)
    }

    // MARK: - Cloudflare Service Token Storage

    func saveCloudflareTokenId(_ tokenId: String, for connectionId: UUID) {
        let key = "com.TablePro.cloudflaretokenid.\(connectionId.uuidString)"
        keychain.writeString(tokenId, forKey: key)
    }

    func loadCloudflareTokenId(for connectionId: UUID) -> String? {
        let key = "com.TablePro.cloudflaretokenid.\(connectionId.uuidString)"
        return resolveString(.init(label: "Cloudflare token ID", connectionId: connectionId), forKey: key)
    }

    func deleteCloudflareTokenId(for connectionId: UUID) {
        let key = "com.TablePro.cloudflaretokenid.\(connectionId.uuidString)"
        keychain.delete(forKey: key)
    }

    func saveCloudflareTokenSecret(_ tokenSecret: String, for connectionId: UUID) {
        let key = "com.TablePro.cloudflaretokensecret.\(connectionId.uuidString)"
        keychain.writeString(tokenSecret, forKey: key)
    }

    func loadCloudflareTokenSecret(for connectionId: UUID) -> String? {
        let key = "com.TablePro.cloudflaretokensecret.\(connectionId.uuidString)"
        return resolveString(.init(label: "Cloudflare token secret", connectionId: connectionId), forKey: key)
    }

    func deleteCloudflareTokenSecret(for connectionId: UUID) {
        let key = "com.TablePro.cloudflaretokensecret.\(connectionId.uuidString)"
        keychain.delete(forKey: key)
    }

    private struct SecretContext {
        let label: String
        let connectionId: UUID
    }

    private func resolveString(_ context: SecretContext, forKey key: String) -> String? {
        let label = context.label
        let connId = context.connectionId.uuidString
        switch keychain.readStringResult(forKey: key) {
        case .found(let value):
            return value
        case .notFound:
            return nil
        case .locked:
            Self.logger.warning("\(label, privacy: .public) unavailable: Keychain locked (connId=\(connId, privacy: .public))")
            return nil
        case .userCancelled:
            Self.logger.notice("\(label, privacy: .public) prompt cancelled (connId=\(connId, privacy: .public))")
            return nil
        case .authFailed:
            Self.logger.warning("\(label, privacy: .public) auth failed (connId=\(connId, privacy: .public))")
            return nil
        case .error(let status):
            Self.logger.error("\(label, privacy: .public) read error \(status) (connId=\(connId, privacy: .public))")
            return nil
        }
    }

    // MARK: - Plugin Secure Field Migration

    private static func secureFieldIds(for databaseType: DatabaseType) -> [String] {
        (PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .connection.additionalConnectionFields ?? [])
            .filter(\.isSecure).map(\.id)
    }

    func migratePluginSecureFieldsIfNeeded() {
        let migrationKey = "com.TablePro.pluginSecureFieldsMigrated"
        guard !defaults.bool(forKey: migrationKey) else { return }
        defer { defaults.set(true, forKey: migrationKey) }

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
            if !saveConnections(connections) {
                Self.logger.error("Failed to persist plugin secure field migration; will retry on next launch")
            }
        }
    }
}

