//
//  ConnectionEditorStoreFixture.swift
//  TableProTests
//

import Foundation
import TableProConnectionLibrary

@testable import TablePro

final class RecordingKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: String] = [:]
    private var writes = 0
    private var refusesWrites = false

    var writeCount: Int {
        lock.withLock { writes }
    }

    var keys: [String] {
        lock.withLock { Array(store.keys) }
    }

    func refuseWrites(_ refuse: Bool) {
        lock.withLock { refusesWrites = refuse }
    }

    func resetWriteCount() {
        lock.withLock { writes = 0 }
    }

    func value(forKey key: String) -> String? {
        lock.withLock { store[key] }
    }

    @discardableResult
    func writeString(_ value: String, forKey key: String) -> Bool {
        lock.withLock {
            writes += 1
            guard !refusesWrites else { return false }
            store[key] = value
            return true
        }
    }

    func readStringResult(forKey key: String) -> KeychainStringResult {
        lock.withLock {
            guard let value = store[key] else { return .notFound }
            return .found(value)
        }
    }

    func delete(forKey key: String) {
        lock.withLock { store[key] = nil }
    }
}

private struct NoManagedPolicy: ManagedPolicyReading {
    func string(_ policy: ManagedPolicy) -> String? { nil }
}

@MainActor
final class ConnectionEditorStoreFixture {
    let directory: URL
    let suite: EphemeralDefaults
    let keychain = RecordingKeychain()
    let events = AppEvents()
    let storage: ConnectionStorage
    let groups: GroupStorage
    let projects: ProjectStorage
    let scope: ConnectionScope
    let sshProfiles: SSHProfileStorage
    let credentialProfiles: CredentialProfileStorage
    let recents: RecentConnectionsStore
    let listPreferences: ConnectionListPreferences
    let services: AppServices
    let envVarApprovals: ConnectionApprovalStore
    let localCredentialApprovals: ConnectionApprovalStore

    // `storageKeychain` stands in for `keychain` where a test needs the Keychain's scopes or unreadable items.
    init(storageKeychain: (any KeychainStoring)? = nil) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-editor-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = try EphemeralDefaults()
        let defaults = suite.defaults
        let recording = keychain
        let keychain: any KeychainStoring = storageKeychain ?? recording
        let events = events
        let storage = ConnectionStorage(
            fileURL: directory.appendingPathComponent("connections.json"),
            userDefaults: defaults,
            keychain: keychain,
            appEvents: events
        )
        self.storage = storage
        let groups = GroupStorage(userDefaults: defaults, connectionStorage: storage, appEvents: events)
        self.groups = groups
        let projects = ProjectStorage(
            userDefaults: defaults,
            connectionStorage: storage,
            groupStorage: groups,
            appEvents: events
        )
        self.projects = projects
        scope = ConnectionScope(
            userDefaults: defaults,
            connectionStorage: storage,
            groupStorage: groups,
            projectStorage: projects,
            appEvents: events
        )
        sshProfiles = SSHProfileStorage(userDefaults: defaults, keychain: keychain, connectionStorage: storage)
        credentialProfiles = CredentialProfileStorage(
            fileURL: directory.appendingPathComponent("credentialProfiles.json"),
            keychain: keychain,
            connectionStorage: storage
        )
        let sshProfiles = sshProfiles
        let dialed: @MainActor (DatabaseConnection) -> ConnectionDestination = { connection in
            sshProfiles.refreshingLinkedProfile(connection).destination
        }
        envVarApprovals = ConnectionApprovalStore(
            kind: .envVarReferences, defaults: defaults, savedConnections: { [] }, dialedDestination: dialed
        )
        localCredentialApprovals = ConnectionApprovalStore(
            kind: .localCredentials, defaults: defaults, savedConnections: { [] }, dialedDestination: dialed
        )
        recents = RecentConnectionsStore(defaults: defaults, appEvents: events)
        listPreferences = ConnectionListPreferences(defaults: defaults, appEvents: events)
        let live = AppServices.live
        services = AppServices(
            appEvents: events,
            appSettings: live.appSettings,
            appSettingsStorage: live.appSettingsStorage,
            connectionStorage: storage,
            databaseManager: live.databaseManager,
            pluginManager: live.pluginManager,
            schemaService: live.schemaService,
            schemaRefreshService: live.schemaRefreshService,
            schemaProviderRegistry: live.schemaProviderRegistry,
            catalogChangeService: live.catalogChangeService,
            sqlFavoriteManager: live.sqlFavoriteManager,
            favoriteTablesStorage: live.favoriteTablesStorage,
            favoriteDatabasesStorage: live.favoriteDatabasesStorage,
            tableFolderStorage: live.tableFolderStorage,
            aiChatStorage: live.aiChatStorage,
            aiKeyStorage: live.aiKeyStorage,
            aiAccessApprovals: live.aiAccessApprovals,
            groupStorage: groups,
            tagStorage: live.tagStorage,
            sshProfileStorage: sshProfiles,
            credentialProfileStorage: credentialProfiles,
            featureAccess: live.featureAccess,
            syncMetadataStorage: live.syncMetadataStorage,
            favoritesExpansionState: live.favoritesExpansionState,
            linkedFolderWatcher: live.linkedFolderWatcher,
            queryHistoryManager: live.queryHistoryManager,
            dateFormattingService: live.dateFormattingService,
            copilotService: live.copilotService,
            mcpServerManager: live.mcpServerManager,
            syncTracker: live.syncTracker,
            welcomeRouter: live.welcomeRouter,
            telemetry: live.telemetry
        )
    }

    deinit {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }

    func makeStore(_ request: ConnectionEditorStore.Request) -> ConnectionEditorStore {
        ConnectionEditorStore(
            request: request,
            services: services,
            recentConnections: recents,
            listPreferences: listPreferences,
            managedPolicy: NoManagedPolicy(),
            approvalStores: [envVarApprovals, localCredentialApprovals],
            scope: scope
        )
    }

    @discardableResult
    func seed(_ connections: [DatabaseConnection]) -> Bool {
        storage.saveConnections(connections)
    }

    func makeLibraryReadOnly(_ readOnly: Bool) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: readOnly ? 0o555 : 0o755],
            ofItemAtPath: directory.path
        )
        storage.invalidateCache()
    }

    func secretKeys(for id: UUID) -> [String] {
        keychain.keys.filter { $0.hasSuffix(id.uuidString) }
    }
}
