//
//  ConnectionStorage.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import Combine
import Foundation
import os
import TableProConnectionLibrary
import TableProPluginKit
import TableProSyncTransport

/// Service for persisting database connections
@MainActor
final class ConnectionStorage {
    static let shared = ConnectionStorage()
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionStorage")

    private let connectionsKey = "com.TablePro.connections"
    private let migratedToFileKey = "com.TablePro.connectionsMigratedToFile"
    private let defaults: UserDefaults
    private let syncTracker: SyncChangeTracker
    private let appSettingsProvider: () -> AppSettingsStorage

    /// In-memory cache to avoid re-decoding JSON from file on every access
    private var cachedConnections: [DatabaseConnection]?

    private(set) var lastLoadFailed = false

    /// Whether the file on disk is the one TablePro last wrote. False once it has been edited by
    /// something else, which is the signal to refuse to run a connection's password source.
    var storeIsTrusted: Bool { file.isTrusted }

    private let file: IntegrityStampedFileStore<StoredConnection>
    private var fileURL: URL { file.fileURL }

    private let keychain: any KeychainStoring

    private let appEventsProvider: () -> AppEvents

    init(
        fileURL: URL = ConnectionStorage.defaultFileURL(),
        userDefaults: UserDefaults = .standard,
        syncTracker: SyncChangeTracker = .shared,
        appSettings: @escaping @autoclosure () -> AppSettingsStorage = .shared,
        keychain: any KeychainStoring = AppStorageEnvironment.shared.keychain,
        appEvents: @escaping @autoclosure () -> AppEvents = .shared,
        integrity: ConnectionStoreIntegrity = .shared
    ) {
        self.file = IntegrityStampedFileStore(
            fileURL: fileURL,
            label: "connections.json",
            logger: Self.logger,
            userSaveEstablishesTrust: true,
            integrity: integrity
        )
        self.defaults = userDefaults
        self.syncTracker = syncTracker
        self.appSettingsProvider = appSettings
        self.keychain = keychain
        self.appEventsProvider = appEvents

        migrateFromUserDefaultsIfNeeded()
    }

    nonisolated static func defaultFileURL() -> URL {
        let appSupport = AppStorageEnvironment.shared.applicationSupportRoot
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

        guard let storedConnections = file.load() else {
            lastLoadFailed = true
            return []
        }
        lastLoadFailed = false

        let connections = storedConnections.map { stored in
            stored.toConnection()
        }

        let migrated = Self.numberingUnrankedGroups(connections)
        if migrated != connections {
            if storeIsTrusted {
                saveConnections(migrated)
            }
            cachedConnections = migrated
            return migrated
        }

        cachedConnections = connections
        return connections
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
        guard file.save(connections.map { StoredConnection(from: $0) }) else { return false }
        cachedConnections = nil
        return true
    }

    /// Invalidate the in-memory cache so the next load reads fresh from UserDefaults.
    func invalidateCache() {
        cachedConnections = nil
    }

    /// Add a new connection at the end of its group
    func addConnection(_ connection: DatabaseConnection, password: String? = nil) {
        var connections = loadConnections()
        var placed = connection
        placed.sortOrder = Self.nextSortOrder(in: connections, groupId: connection.groupId)
        connections.append(placed)
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

    static func nextSortOrder(in connections: [DatabaseConnection], groupId: UUID?) -> Int {
        LibraryOrdering.nextSortOrder(after: connections.filter { $0.groupId == groupId }.map(\.sortOrder))
    }

    static func numberingUnrankedGroups(_ connections: [DatabaseConnection]) -> [DatabaseConnection] {
        var numbered = connections
        let indicesByGroup = Dictionary(grouping: connections.indices) { connections[$0].groupId }
        for indices in indicesByGroup.values
            where indices.count > 1 && indices.allSatisfy({ connections[$0].sortOrder == 0 }) {
            let displayed = indices.sorted {
                LibrarySorting.connectionPrecedes(connections[$0], connections[$1], mode: .manual, lastConnected: [:])
            }
            for (rank, index) in displayed.enumerated() {
                numbered[index].sortOrder = rank
            }
        }
        return numbered
    }

    @discardableResult
    func mutateConnections(ids: Set<UUID>, _ mutate: (inout DatabaseConnection) -> Void) -> Bool {
        guard !ids.isEmpty else { return true }
        var connections = loadConnections()
        var changed: [DatabaseConnection] = []
        for index in connections.indices where ids.contains(connections[index].id) {
            let original = connections[index]
            mutate(&connections[index])
            if connections[index] != original {
                changed.append(connections[index])
            }
        }
        guard !changed.isEmpty else { return true }
        guard saveConnections(connections) else {
            Self.logger.error("Aborted mutateConnections: persistence failed for \(changed.count, privacy: .public) connection(s)")
            return false
        }
        let dirtyIds = changed
            .filter { !$0.localOnly && !$0.isSample }
            .map { $0.id.uuidString }
        syncTracker.markDirty(.connection, ids: dirtyIds)
        appEventsProvider().connectionUpdated.send(changed.count == 1 ? changed.first?.id : nil)
        return true
    }

    @discardableResult
    func moveConnections(
        _ ids: [UUID],
        toGroup groupId: UUID?,
        before: UUID?,
        validGroupIds: Set<UUID>
    ) -> Bool {
        let connections = loadConnections()
        var seen: Set<UUID> = []
        let moving = ids.filter { id in connections.contains { $0.id == id } && seen.insert(id).inserted }
        guard !moving.isEmpty else { return true }
        let movingSet = Set(moving)

        let siblings = LibrarySorting.sorted(
            connections.filter { connection in
                guard !movingSet.contains(connection.id) else { return false }
                let effectiveGroup = connection.groupId.flatMap { validGroupIds.contains($0) ? $0 : nil }
                return effectiveGroup == groupId
            },
            mode: .manual
        )

        let ranks: [UUID: Int]
        if let before, siblings.contains(where: { $0.id == before }) {
            ranks = LibraryOrdering.ranks(
                for: LibraryOrdering.reordered(siblings.map(\.id), moving: moving, before: before)
            )
        } else {
            let start = LibraryOrdering.nextSortOrder(after: siblings.map(\.sortOrder))
            ranks = Dictionary(uniqueKeysWithValues: moving.enumerated().map { ($0.element, start + $0.offset) })
        }

        return mutateConnections(ids: Set(ranks.keys)) { connection in
            if movingSet.contains(connection.id) {
                connection.groupId = groupId
            }
            if let rank = ranks[connection.id] {
                connection.sortOrder = rank
            }
        }
    }

    @discardableResult
    func removeTagId(_ tagId: UUID) -> Bool {
        let affected = loadConnections()
            .filter { $0.tagIds.contains(tagId) }
            .map { connection -> DatabaseConnection in
                var updated = connection
                updated.tagIds.removeAll { $0 == tagId }
                return updated
            }
        return updateConnections(affected)
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

        guard connections[index].preferredSafeModeLevel != level else { return true }

        connections[index].preferredSafeModeLevel = level
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
    @discardableResult
    func deleteConnection(_ connection: DatabaseConnection) -> Bool {
        var connections = loadConnections()
        connections.removeAll { $0.id == connection.id }
        guard saveConnections(connections) else {
            Self.logger.error("Aborted deleteConnection: persistence failed for \(connection.id, privacy: .public)")
            return false
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
        deleteCloudSQLProxyServiceAccountKey(for: connection.id)
        deleteSOCKSProxyPassword(for: connection.id)

        let secureFieldIds = Self.secureFieldIds(for: connection.type)
        deleteAllPluginSecureFields(for: connection.id, fieldIds: secureFieldIds)

        ConnectionLocalState.purge(
            connectionIds: [connection.id],
            origin: .local,
            appSettings: appSettingsProvider()
        )
        return true
    }

    /// Batch-delete multiple connections and clean up their Keychain entries
    @discardableResult
    func deleteConnections(_ connectionsToDelete: [DatabaseConnection]) -> Bool {
        let idsToDelete = Set(connectionsToDelete.map(\.id))
        var all = loadConnections()
        all.removeAll { idsToDelete.contains($0.id) }
        guard saveConnections(all) else {
            Self.logger.error("Aborted deleteConnections: persistence failed for \(idsToDelete.count, privacy: .public) connection(s)")
            return false
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
            deleteCloudSQLProxyServiceAccountKey(for: conn.id)
            deleteSOCKSProxyPassword(for: conn.id)
            let fields = Self.secureFieldIds(for: conn.type)
            deleteAllPluginSecureFields(for: conn.id, fieldIds: fields)
        }
        ConnectionLocalState.purge(
            connectionIds: idsToDelete,
            origin: .local,
            appSettings: appSettingsProvider()
        )
        return true
    }

    /// Duplicate a connection with a new UUID and "(Copy)" suffix, placed right after its source.
    /// Copies all passwords from source connection to the duplicate. Returns nil when the copy
    /// could not be saved.
    func duplicateConnection(_ connection: DatabaseConnection) -> DatabaseConnection? {
        let newId = UUID()

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
            tagIds: connection.tagIds,
            groupId: connection.groupId,
            sshProfileId: connection.sshProfileId,
            sshTunnelMode: connection.sshTunnelMode,
            credentialMode: connection.credentialMode,
            cloudflareTunnelMode: connection.cloudflareTunnelMode,
            cloudSQLProxyMode: connection.cloudSQLProxyMode,
            socksProxyMode: connection.socksProxyMode,
            tunnelCommandMode: connection.tunnelCommandMode,
            safeModeLevel: connection.preferredSafeModeLevel,
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

        var connections = loadConnections()
        let siblings = LibrarySorting.sorted(connections.filter { $0.groupId == connection.groupId }, mode: .manual)
        let sourceIndex = siblings.firstIndex { $0.id == connection.id }
        let following = sourceIndex.flatMap { index in
            siblings.indices.contains(index + 1) ? siblings[index + 1].id : nil
        }
        let ranks = LibraryOrdering.ranks(
            for: LibraryOrdering.reordered(siblings.map(\.id), moving: [newId], before: following)
        )
        var renumbered: [DatabaseConnection] = []
        for index in connections.indices {
            guard let rank = ranks[connections[index].id], connections[index].sortOrder != rank else { continue }
            connections[index].sortOrder = rank
            renumbered.append(connections[index])
        }
        var placedDuplicate = duplicate
        placedDuplicate.sortOrder = ranks[newId] ?? Self.nextSortOrder(in: connections, groupId: connection.groupId)
        connections.append(placedDuplicate)
        guard saveConnections(connections) else {
            Self.logger.error("Aborted duplicateConnection: persistence failed for \(duplicate.id, privacy: .public)")
            return nil
        }
        let dirtyIds = ([placedDuplicate] + renumbered)
            .filter { !$0.localOnly && !$0.isSample }
            .map { $0.id.uuidString }
        syncTracker.markDirty(.connection, ids: dirtyIds)

        /// A duplicate that shares a credential profile takes the link, not a copy of the secret.
        /// Copying it would put the connection straight back into the N-copies-of-one-password
        /// shape the profile exists to remove.
        if connection.credentialMode == .inline,
           !connection.promptForPassword,
           let password = loadPassword(for: connection.id) {
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
        if let cloudflareTokenId = loadCloudflareTokenId(for: connection.id) {
            saveCloudflareTokenId(cloudflareTokenId, for: newId)
        }
        if let cloudflareTokenSecret = loadCloudflareTokenSecret(for: connection.id) {
            saveCloudflareTokenSecret(cloudflareTokenSecret, for: newId)
        }
        if let serviceAccountKey = loadCloudSQLProxyServiceAccountKey(for: connection.id) {
            saveCloudSQLProxyServiceAccountKey(serviceAccountKey, for: newId)
        }
        if let socksProxyPassword = loadSOCKSProxyPassword(for: connection.id) {
            saveSOCKSProxyPassword(socksProxyPassword, for: newId)
        }

        let secureFieldIds = Self.secureFieldIds(for: connection.type)
        for fieldId in secureFieldIds {
            if let value = loadPluginSecureField(fieldId: fieldId, for: connection.id) {
                savePluginSecureField(value, fieldId: fieldId, for: newId)
            }
        }
        LoadableExtensionApprovalStore.shared.copyApprovals(from: connection.id, to: newId)

        appEventsProvider().connectionUpdated.send(nil)
        return placedDuplicate
    }

    // MARK: - Keychain (Password Storage)

    @discardableResult
    func savePassword(_ password: String, for connectionId: UUID) -> Bool {
        let key = "com.TablePro.password.\(connectionId.uuidString)"
        return keychain.writeString(password, forKey: key)
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

    @discardableResult
    func saveSSHPassword(_ password: String, for connectionId: UUID) -> Bool {
        let key = "com.TablePro.sshpassword.\(connectionId.uuidString)"
        return keychain.writeString(password, forKey: key)
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

    @discardableResult
    func saveKeyPassphrase(_ passphrase: String, for connectionId: UUID) -> Bool {
        let key = "com.TablePro.keypassphrase.\(connectionId.uuidString)"
        return keychain.writeString(passphrase, forKey: key)
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

    @discardableResult
    func savePluginSecureField(_ value: String, fieldId: String, for connectionId: UUID) -> Bool {
        let key = "com.TablePro.plugin.\(fieldId).\(connectionId.uuidString)"
        return keychain.writeString(value, forKey: key)
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

    @discardableResult
    func saveTOTPSecret(_ secret: String, for connectionId: UUID) -> Bool {
        let key = "com.TablePro.totpsecret.\(connectionId.uuidString)"
        return keychain.writeString(secret, forKey: key)
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

    // MARK: - Cloud SQL Auth Proxy Credential Storage

    func saveCloudSQLProxyServiceAccountKey(_ key: String, for connectionId: UUID) {
        let storageKey = "com.TablePro.cloudsqlproxyserviceaccountkey.\(connectionId.uuidString)"
        keychain.writeString(key, forKey: storageKey)
    }

    func loadCloudSQLProxyServiceAccountKey(for connectionId: UUID) -> String? {
        let storageKey = "com.TablePro.cloudsqlproxyserviceaccountkey.\(connectionId.uuidString)"
        return resolveString(.init(label: "Cloud SQL service account key", connectionId: connectionId), forKey: storageKey)
    }

    func deleteCloudSQLProxyServiceAccountKey(for connectionId: UUID) {
        let storageKey = "com.TablePro.cloudsqlproxyserviceaccountkey.\(connectionId.uuidString)"
        keychain.delete(forKey: storageKey)
    }

    // MARK: - SOCKS Proxy Password Storage

    func saveSOCKSProxyPassword(_ password: String, for connectionId: UUID) {
        let key = "com.TablePro.socksproxypassword.\(connectionId.uuidString)"
        keychain.writeString(password, forKey: key)
    }

    func loadSOCKSProxyPassword(for connectionId: UUID) -> String? {
        let key = "com.TablePro.socksproxypassword.\(connectionId.uuidString)"
        return resolveString(.init(label: "SOCKS proxy password", connectionId: connectionId), forKey: key)
    }

    func deleteSOCKSProxyPassword(for connectionId: UUID) {
        let key = "com.TablePro.socksproxypassword.\(connectionId.uuidString)"
        keychain.delete(forKey: key)
    }

    // MARK: - Stored Secret State

    /// What a keychain read actually said, which `loadPassword` and its siblings collapse to nil.
    ///
    /// The connection form prefills its secret fields from the keychain, so an empty field on save
    /// means the user cleared it and the stored secret should go with it. That inference only holds
    /// when the read succeeded: a locked, cancelled or otherwise unreadable keychain prefills
    /// nothing either, and deleting on that would destroy a secret the user never touched.
    enum StoredSecretState: Equatable {
        case stored
        case absent
        case unreadable
    }

    func passwordState(for connectionId: UUID) -> StoredSecretState {
        secretState(forKey: "com.TablePro.password.\(connectionId.uuidString)")
    }

    func sshPasswordState(for connectionId: UUID) -> StoredSecretState {
        secretState(forKey: "com.TablePro.sshpassword.\(connectionId.uuidString)")
    }

    func keyPassphraseState(for connectionId: UUID) -> StoredSecretState {
        secretState(forKey: "com.TablePro.keypassphrase.\(connectionId.uuidString)")
    }

    private func secretState(forKey key: String) -> StoredSecretState {
        switch keychain.readStringResult(forKey: key) {
        case .found(let value):
            return value.isEmpty ? .absent : .stored
        case .notFound:
            return .absent
        case .locked, .userCancelled, .authFailed, .error:
            return .unreadable
        }
    }

    private struct SecretContext {
        let label: String
        let connectionId: UUID
    }

    private func resolveString(_ context: SecretContext, forKey key: String) -> String? {
        keychain.readStringResult(forKey: key)
            .value(label: "\(context.label) (connId=\(context.connectionId.uuidString))", logger: Self.logger)
    }

    // MARK: - Plugin Secure Field Migration

    private static func secureFieldIds(for databaseType: DatabaseType) -> [String] {
        PluginManager.shared.secureConnectionFieldIds(for: databaseType)
    }

    func migratePluginSecureFieldsIfNeeded() {
        let migrationKey = "com.TablePro.pluginSecureFieldsMigrated"
        guard !defaults.bool(forKey: migrationKey) else { return }
        defer { defaults.set(true, forKey: migrationKey) }

        var connections = loadConnections()
        var changed = false

        for index in connections.indices {
            let secureFieldIds = Self.secureFieldIds(for: connections[index].type)
            for fieldId in secureFieldIds {
                if let value = connections[index].additionalFields[fieldId], !value.isEmpty {
                    savePluginSecureField(value, fieldId: fieldId, for: connections[index].id)
                    connections[index].additionalFields.removeValue(forKey: fieldId)
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
