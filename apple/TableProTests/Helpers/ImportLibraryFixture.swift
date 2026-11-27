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
    let journal: SyncJournalRecorder
    let connections: ConnectionStorage
    let groups: GroupStorage
    let tags: TagStorage
    let projects: ProjectStorage
    let profiles: CredentialProfileStorage
    let sshProfiles: SSHProfileStorage
    let favorites: SQLFavoriteManager

    private let storeSuite: EphemeralDefaults

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

        storeSuite = try EphemeralDefaults("ImportLibrary.store")
        let defaults = storeSuite.defaults
        let tracker = SyncJournalRecorder()
        journal = tracker
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
            syncJournal: tracker.journal,
            keychain: keychain,
            appEvents: events,
            integrity: integrity
        )
        connections = connectionStorage
        let groupStorage = GroupStorage(
            syncJournal: tracker.journal,
            connectionStorage: connectionStorage,
            appEvents: events
        )
        groups = groupStorage
        projects = ProjectStorage(
            syncJournal: tracker.journal,
            connectionStorage: connectionStorage,
            groupStorage: groupStorage,
            appEvents: events
        )
        tags = TagStorage(syncJournal: tracker.journal, connectionStorage: connectionStorage, appEvents: events)
        profiles = CredentialProfileStorage(
            fileURL: profilesURL,
            keychain: keychain,
            syncJournal: tracker.journal,
            connectionStorage: connectionStorage,
            integrity: integrity
        )
        sshProfiles = SSHProfileStorage(
            userDefaults: defaults,
            keychain: keychain,
            syncJournal: tracker.journal,
            connectionStorage: connectionStorage
        )
        favorites = SQLFavoriteManager(
            storage: SQLFavoriteStorage(databaseURL: favoritesURL, removeDatabaseOnDeinit: !damage.contains(.favorites)),
            syncJournal: tracker.journal,
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
            favorites: favorites,
            projects: projects
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
            appVersion: "Tests",
            projects: projects
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
        registeredTypeIds: Set<String> = ["MySQL", "PostgreSQL", "Redis"],
        targetProjectId: UUID? = nil,
        makeId: () -> UUID = UUID.init,
        choosing choose: (inout ImportSelection, ImportPreview) -> Void = { _, _ in }
    ) async throws -> ImportOutcome {
        let preview = ConnectionImportAnalyzer.analyze(
            CollectedImport(bundle: bundle, source: .file(name: "Shared.tablepro")),
            library: try await store.snapshot(),
            environment: Self.environment(registeredTypeIds: registeredTypeIds)
        )
        var selection = ImportSelection.defaults(for: preview)
        choose(&selection, preview)
        let plan = ImportPlanner.plan(
            preview,
            selection: selection,
            targetProjectId: targetProjectId,
            makeId: makeId
        )
        return await ImportApplier.apply(plan, library: store, savedQueries: favorites)
    }

    func cleanUp() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }
}
