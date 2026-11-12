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
import TableProImport
import TableProPluginKit
import TableProSSHTransport
import TableProSyncTransport

@MainActor
final class ConnectionStorage {
    static let shared = ConnectionStorage()
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionStorage")

    private let connectionsKey = "com.TablePro.connections"
    private let migratedToFileKey = "com.TablePro.connectionsMigratedToFile"
    private let defaults: UserDefaults
    private static let sshRoutePublisherKey = "com.TablePro.sshRoutePublisherId"
    private let syncTracker: SyncChangeTracker
    private let appSettingsProvider: () -> AppSettingsStorage

    private var cachedConnections: [DatabaseConnection]?

    private(set) var lastLoadFailed = false
    private(set) var fileReadCount = 0
    private(set) var fileWriteCount = 0

    /// Whether the file on disk is the one TablePro last wrote. False once it has been edited by
    /// something else, which is the signal to refuse to run a connection's password source.
    var storeIsTrusted: Bool { file.isTrusted }

    private let file: IntegrityStampedFileStore<StoredConnection>
    private var fileURL: URL { file.fileURL }

    private let keychain: any KeychainStoring

    private let appEventsProvider: () -> AppEvents

    init(
        fileURL: URL = ConnectionStorage.defaultFileURL(),
        userDefaults: UserDefaults = AppStorageEnvironment.shared.defaults,
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

    func loadConnections() -> [DatabaseConnection] {
        if let cached = cachedConnections { return cached }

        fileReadCount += 1
        guard let storedConnections = file.load() else {
            lastLoadFailed = true
            return []
        }
        lastLoadFailed = false

        let connections = storedConnections.map { stored in
            stored.toConnection()
        }

        let migrated = Self.numberingUnrankedGroups(connections)
        if migrated != connections, storeIsTrusted {
            persist(migrated)
        }
        cachedConnections = migrated
        return migrated
    }

    func loadConnection(id: UUID) -> DatabaseConnection? {
        loadConnections().first { $0.id == id }
    }

    /// Loads first, so the answer does not depend on whether anything has read the file yet.
    var isLibraryUnreadable: Bool {
        _ = loadConnections()
        return lastLoadFailed
    }

    /// Callers that mutate dependent state (sync tracker, keychain entries) must abort on `false`:
    /// continuing can delete a password while the record stays on disk. Refuses while the file on
    /// disk could not be read, because every write replaces the whole list.
    /// `byUser` false keeps a store that failed its integrity check untrusted, since a write the
    /// app makes on its own (a sync pull, a route a connect recorded) is not the user re-saving it.
    @discardableResult
    func saveConnections(_ connections: [DatabaseConnection], byUser: Bool = true) -> Bool {
        let previous = loadConnections()
        guard !lastLoadFailed else {
            Self.logger.error("Refused to save over connections.json: it could not be read")
            return false
        }
        guard persist(connections, byUser: byUser) else { return false }
        moveSecretsWhoseScopeChanged(from: previous, to: connections)
        return true
    }

    @discardableResult
    private func persist(_ connections: [DatabaseConnection], byUser: Bool = true) -> Bool {
        guard file.save(connections.map { StoredConnection(from: $0) }, byUser: byUser) else { return false }
        fileWriteCount += 1
        cachedConnections = nil
        return true
    }

    func invalidateCache() {
        cachedConnections = nil
    }

    @discardableResult
    func addConnection(_ connection: DatabaseConnection, password: String? = nil) -> Bool {
        var connections = loadConnections()
        var placed = connection
        placed.sortOrder = Self.nextSortOrder(in: connections, groupId: connection.groupId)
        connections.append(placed)
        guard saveConnections(connections) else {
            Self.logger.error("Aborted addConnection: persistence failed for \(connection.id, privacy: .public)")
            return false
        }
        if connection.participatesInSync {
            syncTracker.markDirty(.connection, id: connection.id.uuidString)
        }

        if let password = password, !password.isEmpty {
            savePassword(password, for: connection.id)
        }
        return true
    }

    // A replace keeps the stored row's device-local state, except a credential profile the import
    // created and a tunnel command the user agreed to import. A replace whose row is gone is not written.
    func applyImport(adding: [DatabaseConnection], replacing: [DatabaseConnection]) -> ConnectionImportWrite? {
        var connections = loadConnections()
        guard !lastLoadFailed else {
            Self.logger.error("Refused import: connections.json could not be read")
            return nil
        }

        var replaced: [DatabaseConnection] = []
        for incoming in replacing {
            guard let index = connections.firstIndex(where: { $0.id == incoming.id }) else { continue }
            let stored = connections[index]
            var updated = incoming.adoptingDeviceLocalState(from: stored)
            updated.origin = .imported
            if incoming.credentialMode.profileId != nil {
                updated.credentialMode = incoming.credentialMode
            }
            if incoming.isTunnelCommandEnabled {
                updated.tunnelCommandMode = incoming.tunnelCommandMode
            }
            // A file carries no route, and readers drop the stored one once it no longer describes the tunnel.
            updated.sshRoute = stored.sshRoute
            // A saved import brings no sign-in with this Mac's credentials, scripts or fields this build does not know, so
            // the row keeps its own.
            for (key, value) in stored.additionalFields where ConnectionFieldCatalog.survivesReplace(key) {
                updated.additionalFields[key] = value
            }
            updated.sortOrder = stored.groupId == updated.groupId
                ? stored.sortOrder
                : Self.nextSortOrder(in: connections, groupId: updated.groupId)
            connections[index] = updated
            replaced.removeAll { $0.id == updated.id }
            replaced.append(updated)
        }

        var knownIds = Set(connections.map(\.id))
        var added: [DatabaseConnection] = []
        for incoming in adding {
            guard knownIds.insert(incoming.id).inserted else { continue }
            var placed = incoming
            placed.origin = .imported
            placed.sortOrder = Self.nextSortOrder(in: connections, groupId: incoming.groupId)
            connections.append(placed)
            added.append(placed)
        }

        guard !added.isEmpty || !replaced.isEmpty else {
            return ConnectionImportWrite(added: [], replaced: [])
        }
        guard saveConnections(connections) else {
            Self.logger.error("Aborted import: persistence failed for \(added.count + replaced.count, privacy: .public) connection(s)")
            return nil
        }
        let dirtyIds = (replaced + added)
            .filter(\.participatesInSync)
            .map { $0.id.uuidString }
        syncTracker.markDirty(.connection, ids: dirtyIds)
        appEventsProvider().connectionUpdated.send(nil)
        return ConnectionImportWrite(added: added.map(\.id), replaced: replaced.map(\.id))
    }

    func updateConnection(_ connection: DatabaseConnection, password: String? = nil) {
        var connections = loadConnections()
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index] = connection
            guard saveConnections(connections) else {
                Self.logger.error("Aborted updateConnection: persistence failed for \(connection.id, privacy: .public)")
                return
            }
            if connection.participatesInSync {
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
            .filter(\.participatesInSync)
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
    func mutateConnections(
        ids: Set<UUID>,
        byUser: Bool = true,
        _ mutate: (inout DatabaseConnection) -> Void
    ) -> Bool {
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
        guard saveConnections(connections, byUser: byUser) else {
            Self.logger.error("Aborted mutateConnections: persistence failed for \(changed.count, privacy: .public) connection(s)")
            return false
        }
        let dirtyIds = changed
            .filter(\.participatesInSync)
            .map { $0.id.uuidString }
        syncTracker.markDirty(.connection, ids: dirtyIds)
        appEventsProvider().connectionUpdated.send(changed.count == 1 ? changed.first?.id : nil)
        return true
    }

    var sshRoutePublisherId: UUID {
        if let stored = defaults.string(forKey: Self.sshRoutePublisherKey).flatMap(UUID.init(uuidString:)) {
            return stored
        }
        let id = UUID()
        defaults.set(id.uuidString, forKey: Self.sshRoutePublisherKey)
        return id
    }

    // `refresh` brings a profile-linked connection up to its profile first, so the record carries
    // the settings the route was dialed from even when the profile's own fan-out never landed.
    @discardableResult
    func recordDialedSSHRoute(
        _ dialed: DialedSSHRoute,
        for connectionId: UUID,
        refresh: (DatabaseConnection) -> DatabaseConnection
    ) -> Bool {
        let publisher = sshRoutePublisherId
        return mutateConnections(ids: [connectionId], byUser: false) { connection in
            let current = refresh(connection)
            guard current.resolvedSSHConfig.publishedRouteInput == dialed.input else { return }
            connection = current
            connection.sshRoute = dialed.routeToStore(replacing: connection.sshRoute, publisher: publisher)
        }
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
        if updatedConnection.participatesInSync {
            syncTracker.markDirty(.connection, id: updatedConnection.id.uuidString)
        }

        return true
    }

    @discardableResult
    func deleteConnection(_ connection: DatabaseConnection) -> Bool {
        var connections = loadConnections()
        connections.removeAll { $0.id == connection.id }
        guard saveConnections(connections) else {
            Self.logger.error("Aborted deleteConnection: persistence failed for \(connection.id, privacy: .public)")
            return false
        }
        if connection.participatesInSync {
            syncTracker.markDeleted(.connection, id: connection.id.uuidString)
        }
        let origin: ConnectionLocalState.Origin = connection.participatesInSync ? .local : .localOnly
        deleteSecrets(of: [connection], origin: origin)
        ConnectionLocalState.purge(
            connectionIds: [connection.id],
            origin: origin,
            appSettings: appSettingsProvider(),
            syncTracker: syncTracker
        )
        return true
    }

    @discardableResult
    func deleteConnections(_ connectionsToDelete: [DatabaseConnection]) -> Bool {
        let idsToDelete = Set(connectionsToDelete.map(\.id))
        var all = loadConnections()
        all.removeAll { idsToDelete.contains($0.id) }
        guard saveConnections(all) else {
            Self.logger.error("Aborted deleteConnections: persistence failed for \(idsToDelete.count, privacy: .public) connection(s)")
            return false
        }
        for conn in connectionsToDelete where conn.participatesInSync {
            syncTracker.markDeleted(.connection, id: conn.id.uuidString)
        }
        let syncedIds = Set(connectionsToDelete.filter(\.participatesInSync).map(\.id))
        deleteSecrets(of: connectionsToDelete.filter { syncedIds.contains($0.id) }, origin: .local)
        deleteSecrets(of: connectionsToDelete.filter { !syncedIds.contains($0.id) }, origin: .localOnly)
        ConnectionLocalState.purge(
            connectionIds: syncedIds,
            origin: .local,
            appSettings: appSettingsProvider(),
            syncTracker: syncTracker
        )
        ConnectionLocalState.purge(
            connectionIds: idsToDelete.subtracting(syncedIds),
            origin: .localOnly,
            appSettings: appSettingsProvider(),
            syncTracker: syncTracker
        )
        return true
    }

    /// The copy is the user's own new connection, so it starts unfavorited and is never a sample.
    /// Every other property carries, External Access too: a Read Only copy of a Blocked connection
    /// would be open to MCP clients with the source's passwords.
    func duplicateConnection(_ connection: DatabaseConnection) -> DatabaseConnection? {
        let newId = UUID()

        var duplicate = DatabaseConnection(
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
            iconName: connection.iconName,
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
            externalAccess: connection.externalAccess,
            redisDatabase: connection.redisDatabase,
            startupCommands: connection.startupCommands,
            sortOrder: connection.sortOrder,
            localOnly: connection.localOnly,
            passwordSource: connection.passwordSource,
            additionalFields: connection.additionalFields.isEmpty ? nil : connection.additionalFields
        )
        duplicate.sshRoute = connection.sshRoute
        duplicate.origin = connection.origin

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
            .filter(\.participatesInSync)
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
        for store in ConnectionApprovalStore.all {
            store.copyApprovals(from: connection.id, to: newId)
        }

        appEventsProvider().connectionUpdated.send(nil)
        return placedDuplicate
    }

    // MARK: - Keychain (Password Storage)

    @discardableResult
    func savePassword(_ password: String, for connectionId: UUID) -> Bool {
        let key = "com.TablePro.password.\(connectionId.uuidString)"
        return writeSecret(password, forKey: key, connectionId: connectionId)
    }

    func loadPassword(for connectionId: UUID) -> String? {
        let key = "com.TablePro.password.\(connectionId.uuidString)"
        return resolveString(.init(label: "Database password", connectionId: connectionId), forKey: key)
    }

    func deletePassword(for connectionId: UUID) {
        let key = "com.TablePro.password.\(connectionId.uuidString)"
        deleteSecret(forKey: key, connectionId: connectionId)
    }

    // MARK: - SSH Password Storage

    @discardableResult
    func saveSSHPassword(_ password: String, for connectionId: UUID) -> Bool {
        let key = "com.TablePro.sshpassword.\(connectionId.uuidString)"
        return writeSecret(password, forKey: key, connectionId: connectionId)
    }

    func loadSSHPassword(for connectionId: UUID) -> String? {
        let key = "com.TablePro.sshpassword.\(connectionId.uuidString)"
        return resolveString(.init(label: "SSH password", connectionId: connectionId), forKey: key)
    }

    func deleteSSHPassword(for connectionId: UUID) {
        let key = "com.TablePro.sshpassword.\(connectionId.uuidString)"
        deleteSecret(forKey: key, connectionId: connectionId)
    }

    // MARK: - Key Passphrase Storage

    @discardableResult
    func saveKeyPassphrase(_ passphrase: String, for connectionId: UUID) -> Bool {
        let key = "com.TablePro.keypassphrase.\(connectionId.uuidString)"
        return writeSecret(passphrase, forKey: key, connectionId: connectionId)
    }

    func loadKeyPassphrase(for connectionId: UUID) -> String? {
        let key = "com.TablePro.keypassphrase.\(connectionId.uuidString)"
        return resolveString(.init(label: "Key passphrase", connectionId: connectionId), forKey: key)
    }

    func deleteKeyPassphrase(for connectionId: UUID) {
        let key = "com.TablePro.keypassphrase.\(connectionId.uuidString)"
        deleteSecret(forKey: key, connectionId: connectionId)
    }

    // MARK: - SSL Client Key Passphrase Storage

    @discardableResult
    func saveSSLClientKeyPassphrase(_ passphrase: String, for connectionId: UUID) -> Bool {
        let key = "com.TablePro.sslkeypassphrase.\(connectionId.uuidString)"
        return writeSecret(passphrase, forKey: key, connectionId: connectionId)
    }

    func loadSSLClientKeyPassphrase(for connectionId: UUID) -> String? {
        let key = "com.TablePro.sslkeypassphrase.\(connectionId.uuidString)"
        return resolveString(.init(label: "SSL client key passphrase", connectionId: connectionId), forKey: key)
    }

    func deleteSSLClientKeyPassphrase(for connectionId: UUID) {
        let key = "com.TablePro.sslkeypassphrase.\(connectionId.uuidString)"
        deleteSecret(forKey: key, connectionId: connectionId)
    }

    // MARK: - Plugin Secure Field Storage

    @discardableResult
    func savePluginSecureField(_ value: String, fieldId: String, for connectionId: UUID) -> Bool {
        let key = "com.TablePro.plugin.\(fieldId).\(connectionId.uuidString)"
        return writeSecret(value, forKey: key, connectionId: connectionId)
    }

    func loadPluginSecureField(fieldId: String, for connectionId: UUID) -> String? {
        let key = "com.TablePro.plugin.\(fieldId).\(connectionId.uuidString)"
        return resolveString(.init(label: "Plugin field \(fieldId)", connectionId: connectionId), forKey: key)
    }

    func deletePluginSecureField(fieldId: String, for connectionId: UUID) {
        let key = "com.TablePro.plugin.\(fieldId).\(connectionId.uuidString)"
        deleteSecret(forKey: key, connectionId: connectionId)
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
        return writeSecret(secret, forKey: key, connectionId: connectionId)
    }

    func loadTOTPSecret(for connectionId: UUID) -> String? {
        let key = "com.TablePro.totpsecret.\(connectionId.uuidString)"
        return resolveString(.init(label: "TOTP secret", connectionId: connectionId), forKey: key)
    }

    func deleteTOTPSecret(for connectionId: UUID) {
        let key = "com.TablePro.totpsecret.\(connectionId.uuidString)"
        deleteSecret(forKey: key, connectionId: connectionId)
    }

    // MARK: - Cloudflare Service Token Storage

    func saveCloudflareTokenId(_ tokenId: String, for connectionId: UUID) {
        let key = "com.TablePro.cloudflaretokenid.\(connectionId.uuidString)"
        writeSecret(tokenId, forKey: key, connectionId: connectionId)
    }

    func loadCloudflareTokenId(for connectionId: UUID) -> String? {
        let key = "com.TablePro.cloudflaretokenid.\(connectionId.uuidString)"
        return resolveString(.init(label: "Cloudflare token ID", connectionId: connectionId), forKey: key)
    }

    func deleteCloudflareTokenId(for connectionId: UUID) {
        let key = "com.TablePro.cloudflaretokenid.\(connectionId.uuidString)"
        deleteSecret(forKey: key, connectionId: connectionId)
    }

    func saveCloudflareTokenSecret(_ tokenSecret: String, for connectionId: UUID) {
        let key = "com.TablePro.cloudflaretokensecret.\(connectionId.uuidString)"
        writeSecret(tokenSecret, forKey: key, connectionId: connectionId)
    }

    func loadCloudflareTokenSecret(for connectionId: UUID) -> String? {
        let key = "com.TablePro.cloudflaretokensecret.\(connectionId.uuidString)"
        return resolveString(.init(label: "Cloudflare token secret", connectionId: connectionId), forKey: key)
    }

    func deleteCloudflareTokenSecret(for connectionId: UUID) {
        let key = "com.TablePro.cloudflaretokensecret.\(connectionId.uuidString)"
        deleteSecret(forKey: key, connectionId: connectionId)
    }

    // MARK: - Cloud SQL Auth Proxy Credential Storage

    func saveCloudSQLProxyServiceAccountKey(_ key: String, for connectionId: UUID) {
        let storageKey = "com.TablePro.cloudsqlproxyserviceaccountkey.\(connectionId.uuidString)"
        writeSecret(key, forKey: storageKey, connectionId: connectionId)
    }

    func loadCloudSQLProxyServiceAccountKey(for connectionId: UUID) -> String? {
        let storageKey = "com.TablePro.cloudsqlproxyserviceaccountkey.\(connectionId.uuidString)"
        return resolveString(.init(label: "Cloud SQL service account key", connectionId: connectionId), forKey: storageKey)
    }

    func deleteCloudSQLProxyServiceAccountKey(for connectionId: UUID) {
        let storageKey = "com.TablePro.cloudsqlproxyserviceaccountkey.\(connectionId.uuidString)"
        deleteSecret(forKey: storageKey, connectionId: connectionId)
    }

    // MARK: - SOCKS Proxy Password Storage

    func saveSOCKSProxyPassword(_ password: String, for connectionId: UUID) {
        let key = "com.TablePro.socksproxypassword.\(connectionId.uuidString)"
        writeSecret(password, forKey: key, connectionId: connectionId)
    }

    func loadSOCKSProxyPassword(for connectionId: UUID) -> String? {
        let key = "com.TablePro.socksproxypassword.\(connectionId.uuidString)"
        return resolveString(.init(label: "SOCKS proxy password", connectionId: connectionId), forKey: key)
    }

    func deleteSOCKSProxyPassword(for connectionId: UUID) {
        let key = "com.TablePro.socksproxypassword.\(connectionId.uuidString)"
        deleteSecret(forKey: key, connectionId: connectionId)
    }

    // MARK: - Secret Scope

    private static let secretKinds = [
        "password", "sshpassword", "keypassphrase", "sslkeypassphrase", "totpsecret",
        "cloudflaretokenid", "cloudflaretokensecret", "cloudsqlproxyserviceaccountkey", "socksproxypassword"
    ]
    private static let localOnlySecretsMigratedKey = "com.TablePro.localOnlySecretsKeptOnDevice"
    private static let pendingSyncedCopyRemovalsKey = "com.TablePro.localOnlySyncedCopiesPendingRemoval"

    private func secretKeys(for connection: DatabaseConnection) -> [String] {
        let id = connection.id.uuidString
        var fieldIds = Self.secureFieldIds(for: connection.type)
        if !fieldIds.contains(ConnectionSecretOptions.mongoSessionTokenFieldId) {
            fieldIds.append(ConnectionSecretOptions.mongoSessionTokenFieldId)
        }
        return Self.secretKinds.map { "com.TablePro.\($0).\(id)" }
            + fieldIds.map { "com.TablePro.plugin.\($0).\(id)" }
    }

    // Removing an iCloud Keychain item removes it from every device, so only a delete the other devices follow does.
    // One from another device leaves it to that device. A Local only delete cannot tell whether another device still
    // syncs the row, so it keeps it.
    func deleteSecrets(of connections: [DatabaseConnection], origin: ConnectionLocalState.Origin) {
        for connection in connections {
            for key in secretKeys(for: connection) {
                if origin.leavesTombstones {
                    deleteSecret(forKey: key, connectionId: connection.id)
                } else {
                    keychain.delete(forKey: key, deviceOnly: true)
                }
            }
        }
    }

    private func keepsSecretsOnDevice(_ connectionId: UUID) -> Bool {
        loadConnection(id: connectionId).map { !$0.participatesInSync } ?? false
    }

    private func readsOwnItemFirst(_ connectionId: UUID) -> Bool {
        if let staging, staging.connectionId == connectionId {
            return staging.deviceOnly
        }
        return keepsSecretsOnDevice(connectionId)
    }

    @discardableResult
    private func writeSecret(_ value: String, forKey key: String, connectionId: UUID) -> Bool {
        let staged = staging?.connectionId == connectionId
        // Writing it again would date the item as a new save, and a newer copy on another device would lose to it.
        if staged, staging?.loaded[key] == value {
            staging?.edits.deletedKeys.removeAll { $0 == key }
            return true
        }
        let deviceOnly = staged ? staging?.deviceOnly ?? false : keepsSecretsOnDevice(connectionId)
        let written = keychain.writeString(value, forKey: key, deviceOnly: deviceOnly)
        if staged {
            staging?.edits.deletedKeys.removeAll { $0 == key }
            if !written {
                staging?.edits.writeFailed = true
            }
        }
        return written
    }

    private func deleteSecret(forKey key: String, connectionId: UUID) {
        guard let current = staging, current.connectionId == connectionId else {
            keychain.delete(forKey: key)
            return
        }
        guard !current.keptKeys.contains(key), !current.edits.deletedKeys.contains(key) else { return }
        staging?.edits.deletedKeys.append(key)
    }

    // Rewrites each stored secret into the scope the connection now has. removingSyncedCopy then removes the iCloud
    // Keychain copy, from every device, but only of a secret this Mac now holds itself. False when a secret could not
    // be read or written.
    @discardableResult
    private func rewriteSecrets(
        of connection: DatabaseConnection,
        readingOwnItemFirst: Bool,
        deviceOnly: Bool,
        removingSyncedCopy: Bool = false
    ) -> Bool {
        var complete = true
        for key in secretKeys(for: connection) {
            switch keychain.readStringResult(forKey: key, deviceOnly: readingOwnItemFirst) {
            case .found(let value):
                guard keychain.writeString(value, forKey: key, deviceOnly: deviceOnly) else {
                    complete = false
                    continue
                }
                if removingSyncedCopy, !keychain.removeSyncedCopy(forKey: key) {
                    Self.logger.warning("A Local only secret kept its iCloud Keychain copy: \(key, privacy: .public)")
                    notePendingSyncedCopyRemoval(key, connectionId: connection.id)
                }
            case .notFound:
                break
            case .locked, .userCancelled, .authFailed, .error:
                complete = false
            }
        }
        return complete
    }

    // Each direction reads the value the connection was using, so the toggle never changes a secret. Becoming Local
    // only also takes the secrets off iCloud Keychain, so the other devices ask for them again.
    private func moveSecretsWhoseScopeChanged(from previous: [DatabaseConnection], to current: [DatabaseConnection]) {
        let wasSynced = Dictionary(
            previous.map { ($0.id, $0.participatesInSync) },
            uniquingKeysWith: { first, _ in first }
        )
        for connection in current {
            guard let synced = wasSynced[connection.id], synced != connection.participatesInSync else { continue }
            rewriteSecrets(of: connection, readingOwnItemFirst: !synced, deviceOnly: synced, removingSyncedCopy: synced)
        }
    }

    private func notePendingSyncedCopyRemoval(_ key: String, connectionId: UUID) {
        var pending = defaults.dictionary(forKey: Self.pendingSyncedCopyRemovalsKey) as? [String: String] ?? [:]
        pending[key] = connectionId.uuidString
        defaults.set(pending, forKey: Self.pendingSyncedCopyRemovalsKey)
    }

    // A removal the user was promised and the keychain refused is tried again at launch, while the connection is
    // still Local only. One that is back in sync, or gone, wants its synced copy kept or already removed it.
    func removePendingSyncedCopies() {
        guard let pending = defaults.dictionary(forKey: Self.pendingSyncedCopyRemovalsKey) as? [String: String],
              !pending.isEmpty else { return }
        let connections = loadConnections()
        guard !lastLoadFailed else { return }
        let byId = Dictionary(connections.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        var remaining: [String: String] = [:]
        for (key, idString) in pending {
            guard let connection = byId[idString], !connection.participatesInSync else { continue }
            if !keychain.removeSyncedCopy(forKey: key) {
                remaining[key] = idString
            }
        }
        if remaining.isEmpty {
            defaults.removeObject(forKey: Self.pendingSyncedCopyRemovalsKey)
        } else {
            defaults.set(remaining, forKey: Self.pendingSyncedCopyRemovalsKey)
        }
    }

    // Builds before this one wrote a Local only connection's secrets wherever the password sync setting pointed. Only
    // copied: the user saw no note saying the other devices lose them.
    func keepLocalOnlySecretsOnDeviceIfNeeded() {
        removePendingSyncedCopies()
        guard !defaults.bool(forKey: Self.localOnlySecretsMigratedKey) else { return }
        let connections = loadConnections()
        guard !lastLoadFailed else { return }
        var complete = true
        for connection in connections where !connection.participatesInSync {
            let knowsFields = Self.knowsSecureFields(of: connection.type)
            if !rewriteSecrets(of: connection, readingOwnItemFirst: true, deviceOnly: true) || !knowsFields {
                complete = false
            }
        }
        if complete {
            defaults.set(true, forKey: Self.localOnlySecretsMigratedKey)
        } else {
            Self.logger.notice("Not every Local only secret has a copy on this Mac yet; retrying next launch")
        }
    }

    // MARK: - Staged Secret Edits

    struct StagedSecretEdits {
        fileprivate(set) var deletedKeys: [String] = []
        fileprivate(set) var writeFailed = false
    }

    private struct SecretStaging {
        let connectionId: UUID
        let deviceOnly: Bool
        let keptKeys: Set<String>
        let loaded: [String: String]
        var edits = StagedSecretEdits()
    }

    private var staging: SecretStaging?

    private var unreadableSecretsSeen: Set<String>?
    private var loadedSecretsSeen: [String: String]?

    struct SecretReads {
        var unreadable: Set<String> = []
        var loaded: [String: String] = [:]
    }

    // The keys a read inside `body` could not read. A form runs its prefill here, so the field left empty and the
    // key it must not clear come from one read.
    func recordingUnreadableSecrets(_ body: () -> Void) -> Set<String> {
        recordingSecretReads(body).unreadable
    }

    // Also the values the reads found, so a save can leave alone what the form loaded and did not change.
    func recordingSecretReads(_ body: () -> Void) -> SecretReads {
        let outerUnreadable = unreadableSecretsSeen
        let outerLoaded = loadedSecretsSeen
        unreadableSecretsSeen = []
        loadedSecretsSeen = [:]
        body()
        let reads = SecretReads(unreadable: unreadableSecretsSeen ?? [], loaded: loadedSecretsSeen ?? [:])
        unreadableSecretsSeen = outerUnreadable.map { $0.union(reads.unreadable) }
        loadedSecretsSeen = outerLoaded.map { $0.merging(reads.loaded) { _, inner in inner } }
        return reads
    }

    // Inside `body`, this connection's secret writes take `deviceOnly` and report a failure, and its deletes wait
    // for `applyStagedDeletions`, which the caller runs once the record is on disk. A key in `keeping` is never deleted,
    // and a write of the value `unchanged` holds for its key is skipped.
    func stagingSecretEdits(
        for connectionId: UUID,
        deviceOnly: Bool,
        keeping keptKeys: Set<String> = [],
        unchanged loaded: [String: String] = [:],
        _ body: () -> Void
    ) -> StagedSecretEdits {
        let outer = staging
        staging = SecretStaging(connectionId: connectionId, deviceOnly: deviceOnly, keptKeys: keptKeys, loaded: loaded)
        body()
        let edits = staging?.edits ?? StagedSecretEdits()
        staging = outer
        return edits
    }

    func applyStagedDeletions(_ edits: StagedSecretEdits) {
        for key in edits.deletedKeys {
            keychain.delete(forKey: key)
        }
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
        secretState(forKey: "com.TablePro.password.\(connectionId.uuidString)", connectionId: connectionId)
    }

    func sshPasswordState(for connectionId: UUID) -> StoredSecretState {
        secretState(forKey: "com.TablePro.sshpassword.\(connectionId.uuidString)", connectionId: connectionId)
    }

    func keyPassphraseState(for connectionId: UUID) -> StoredSecretState {
        secretState(forKey: "com.TablePro.keypassphrase.\(connectionId.uuidString)", connectionId: connectionId)
    }

    private func secretState(forKey key: String, connectionId: UUID) -> StoredSecretState {
        switch readSecret(forKey: key, connectionId: connectionId) {
        case .found(let value):
            return value.isEmpty ? .absent : .stored
        case .notFound:
            return .absent
        case .locked, .userCancelled, .authFailed, .error:
            return .unreadable
        }
    }

    private func readSecret(forKey key: String, connectionId: UUID) -> KeychainStringResult {
        let result = keychain.readStringResult(forKey: key, deviceOnly: readsOwnItemFirst(connectionId))
        switch result {
        case .found(let value):
            loadedSecretsSeen?[key] = value
        case .notFound:
            break
        case .locked, .userCancelled, .authFailed, .error:
            unreadableSecretsSeen?.insert(key)
        }
        return result
    }

    private struct SecretContext {
        let label: String
        let connectionId: UUID
    }

    private func resolveString(_ context: SecretContext, forKey key: String) -> String? {
        readSecret(forKey: key, connectionId: context.connectionId)
            .value(label: "\(context.label) (connId=\(context.connectionId.uuidString))", logger: Self.logger)
    }

    // MARK: - Plugin Secure Field Migration

    private static func secureFieldIds(for databaseType: DatabaseType) -> [String] {
        PluginManager.shared.secureConnectionFieldIds(for: databaseType)
    }

    // A plugin that is not registered yet has secure fields nothing here can name.
    private static func knowsSecureFields(of databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(for: databaseType) != nil
    }

    // Not the key older builds read: they set it on every exit, including runs that moved nothing.
    private static let pluginSecureFieldsMovedKey = "com.TablePro.pluginSecureFieldsMovedToKeychain"

    // Done only once every connection's secure fields could be named and each value reached the Keychain. A field
    // leaves the record only after its own write, and a file edited outside TablePro moves nothing.
    func migratePluginSecureFieldsIfNeeded() {
        guard !defaults.bool(forKey: Self.pluginSecureFieldsMovedKey) else { return }
        var connections = loadConnections()
        guard !lastLoadFailed, storeIsTrusted else {
            Self.logger.notice("Plugin secure fields not moved: connections.json is unreadable or changed outside TablePro; retrying next launch")
            return
        }

        var complete = true
        var changed = false
        for index in connections.indices {
            let connection = connections[index]
            if !Self.knowsSecureFields(of: connection.type) {
                complete = false
            }
            for fieldId in Self.secureFieldIds(for: connection.type) {
                guard let value = connection.additionalFields[fieldId], !value.isEmpty else { continue }
                guard holdPluginSecureFieldInKeychain(value, fieldId: fieldId, for: connection.id) else {
                    complete = false
                    continue
                }
                connections[index].additionalFields.removeValue(forKey: fieldId)
                changed = true
            }
        }

        if changed, !saveConnections(connections, byUser: false) {
            complete = false
        }
        if complete {
            defaults.set(true, forKey: Self.pluginSecureFieldsMovedKey)
        } else {
            Self.logger.notice("Not every plugin secure field has moved to the Keychain yet; retrying next launch")
        }
    }

    // A stored item wins: with password sync on it can be a newer value another device saved, which the plain-text
    // copy here would overwrite everywhere. The plain-text value is written only where no item exists.
    private func holdPluginSecureFieldInKeychain(_ value: String, fieldId: String, for connectionId: UUID) -> Bool {
        let key = "com.TablePro.plugin.\(fieldId).\(connectionId.uuidString)"
        switch readSecret(forKey: key, connectionId: connectionId) {
        case .found(let stored) where !stored.isEmpty:
            return true
        case .found, .notFound:
            return savePluginSecureField(value, fieldId: fieldId, for: connectionId)
        case .locked, .userCancelled, .authFailed, .error:
            return false
        }
    }

    // MARK: - MongoDB Connection-String Secrets

    // Import from URL once kept these as plain options, which exports, links, the team library and sync carry. Runs
    // every launch, so a row an older build wrote is moved too.
    func moveMongoURISecretsToKeychain() {
        let connections = loadConnections()
        guard !lastLoadFailed else { return }
        var cleaned: [UUID: [String: String]] = [:]
        for connection in connections {
            let kept = keepingMongoURISecretsInKeychain(connection)
            if kept.additionalFields != connection.additionalFields {
                cleaned[connection.id] = kept.additionalFields
            }
        }
        guard !cleaned.isEmpty else { return }
        let moved = mutateConnections(ids: Set(cleaned.keys), byUser: false) { connection in
            connection.additionalFields = cleaned[connection.id] ?? connection.additionalFields
        }
        if !moved {
            Self.logger.error("Could not remove MongoDB connection-string secrets from connections.json; retrying next launch")
        }
    }

    // The Keychain write comes first: a field whose write fails stays in the record rather than being lost. A value
    // already in the Keychain wins, since a legacy record an older build syncs can carry a stale copy.
    func keepingMongoURISecretsInKeychain(_ connection: DatabaseConnection) -> DatabaseConnection {
        var kept = connection
        let id = connection.id
        let tokenId = ConnectionSecretOptions.mongoSessionTokenFieldId
        let holdsToken = { [self] (token: String) in
            !(loadPluginSecureField(fieldId: tokenId, for: id) ?? "").isEmpty
                || savePluginSecureField(token, fieldId: tokenId, for: id)
        }
        for (key, value) in connection.additionalFields where ConnectionSecretOptions.isSecret(key: key, value: value) {
            guard let option = ConnectionSecretOptions.mongoOption(in: key) else {
                if holdsToken(value) {
                    kept.additionalFields[key] = nil
                }
                continue
            }
            if ConnectionSecretOptions.isMongoKeyPassphrase(option: option) {
                if !(loadSSLClientKeyPassphrase(for: id) ?? "").isEmpty || saveSSLClientKeyPassphrase(value, for: id) {
                    kept.additionalFields[key] = nil
                }
            } else if ConnectionSecretOptions.isMongoMechanismProperties(option: option) {
                let split = ConnectionSecretOptions.splitSessionToken(from: value)
                if let token = split.sessionToken, holdsToken(token) {
                    kept.additionalFields[key] = split.remaining
                }
            } else {
                kept.additionalFields[key] = nil
            }
        }
        return kept
    }
}
