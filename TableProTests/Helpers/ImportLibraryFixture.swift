//
//  ImportLibraryFixture.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProImport
import TableProSyncTransport

@MainActor
final class ImportLibraryFixture {
    enum Damage: Hashable {
        case connections
        case groups
        case tags
        case profiles
        case favorites
    }

    let directory: URL
    let keychain: InMemoryKeychain
    let appEvents: AppEvents
    let metadata: SyncMetadataStorage
    let connections: ConnectionStorage
    let groups: GroupStorage
    let tags: TagStorage
    let profiles: CredentialProfileStorage
    let sshProfiles: SSHProfileStorage
    let favorites: SQLFavoriteManager

    private let suiteNames: [String]

    init(damage: Set<Damage> = []) throws {
        let unique = UUID().uuidString
        let keychain = InMemoryKeychain()
        let events = AppEvents()
        self.keychain = keychain
        self.appEvents = events
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("import-library-\(unique)", isDirectory: true)
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let syncSuite = "com.TablePro.tests.ImportLibrary.sync.\(unique)"
        let storeSuite = "com.TablePro.tests.ImportLibrary.store.\(unique)"
        suiteNames = [syncSuite, storeSuite]
        guard let syncDefaults = UserDefaults(suiteName: syncSuite),
              let defaults = UserDefaults(suiteName: storeSuite) else {
            throw CocoaError(.featureUnsupported)
        }
        let metadata = SyncMetadataStorage(userDefaults: syncDefaults)
        self.metadata = metadata
        let tracker = SyncChangeTracker(metadataStorage: metadata)
        let integrity = ConnectionStoreIntegrity(keySource: StoredIntegrityKeySource(store: keychain))

        let connectionsURL = directory.appendingPathComponent("connections.json")
        let profilesURL = directory.appendingPathComponent("credentialProfiles.json")
        let favoritesURL = damage.contains(.favorites)
            ? URL(fileURLWithPath: "/dev/null/sql_favorites.db")
            : directory.appendingPathComponent("sql_favorites.db")
        if damage.contains(.connections) {
            try Data("not json".utf8).write(to: connectionsURL)
        }
        if damage.contains(.profiles) {
            try Data("not json".utf8).write(to: profilesURL)
        }
        if damage.contains(.groups) {
            defaults.set(Data("not json".utf8), forKey: "com.TablePro.groups")
        }
        if damage.contains(.tags) {
            defaults.set(Data("not json".utf8), forKey: "com.TablePro.tags")
        }

        let connectionStorage = ConnectionStorage(
            fileURL: connectionsURL,
            userDefaults: defaults,
            syncTracker: tracker,
            keychain: keychain,
            appEvents: events,
            integrity: integrity
        )
        connections = connectionStorage
        groups = GroupStorage(
            userDefaults: defaults,
            syncTracker: tracker,
            connectionStorage: connectionStorage,
            appEvents: events
        )
        tags = TagStorage(userDefaults: defaults, syncTracker: tracker, appEvents: events)
        profiles = CredentialProfileStorage(
            fileURL: profilesURL,
            keychain: keychain,
            syncTracker: tracker,
            connectionStorage: connectionStorage,
            integrity: integrity
        )
        sshProfiles = SSHProfileStorage(
            userDefaults: defaults,
            keychain: keychain,
            syncTracker: tracker,
            connectionStorage: connectionStorage
        )
        favorites = SQLFavoriteManager(
            storage: SQLFavoriteStorage(databaseURL: favoritesURL, removeDatabaseOnDeinit: !damage.contains(.favorites)),
            syncTracker: tracker,
            appEvents: events
        )
    }

    var store: MacImportLibraryStore {
        MacImportLibraryStore(
            connections: connections,
            groups: groups,
            tags: tags,
            profiles: profiles,
            sshProfiles: sshProfiles,
            favorites: favorites
        )
    }

    var exporter: ConnectionBundleExporter {
        ConnectionBundleExporter(
            connections: connections,
            groups: groups,
            tags: tags,
            profiles: profiles,
            sshProfiles: sshProfiles,
            favorites: favorites,
            appVersion: "Tests"
        )
    }

    static func environment(registeredTypeIds: Set<String> = ["MySQL", "PostgreSQL", "Redis"]) -> ImportEnvironment {
        ImportEnvironment(
            rules: ImportRules(
                maximumGroupDepth: ConnectionGroup.maxNestingDepth,
                supportsSavedQueries: true,
                supportsCredentialProfiles: true
            ),
            registeredTypeIds: registeredTypeIds,
            fileExists: { _ in true }
        )
    }

    func importDefaults(
        of bundle: ConnectionBundle,
        makeId: () -> UUID = UUID.init
    ) async throws -> ImportOutcome {
        let preview = ConnectionImportAnalyzer.analyze(
            CollectedImport(bundle: bundle, source: .file(name: "Shared.tablepro")),
            library: try await store.snapshot(),
            environment: Self.environment()
        )
        let plan = ImportPlanner.plan(preview, selection: ImportSelection.defaults(for: preview), makeId: makeId)
        return await ImportApplier.apply(plan, library: store, savedQueries: favorites)
    }

    func cleanUp() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
        for suite in suiteNames {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
    }
}
