import Combine
import Foundation
import os
@testable import TablePro
import TableProFFI
import TableProSyncTransport
import TableProTestSupport
import Testing

private final class EventLog: @unchecked Sendable {
    private let events = OSAllocatedUnfairLock(uncheckedState: [String]())

    func append(_ event: String) {
        events.withLockUnchecked { $0.append(event) }
    }

    var all: [String] {
        events.withLockUnchecked { $0 }
    }
}

private struct NoServiceOpen: Error {}

// How the service a pass runs on came to be open (E2E F17, F18 and S14).
enum OpenedService: String, CaseIterable, CustomTestStringConvertible {
    case onTableProSync
    case onICloud
    case movedFromOff
    case movedFromICloud
    case signedInAgain
    case relaunched

    var testDescription: String { rawValue }
}

extension SyncPulledStores {
    static var none: SyncPulledStores {
        SyncPulledStores(
            library: {},
            savedQueries: {},
            favoriteTables: {},
            favoriteDatabases: {},
            tableFolders: {},
            history: {}
        )
    }
}

// The app's `SyncEngineHost` over fake services, followed as the app follows it. Each open gives a new service.
@MainActor
private final class PassHarness {
    let log = EventLog()
    let signIns = PassthroughSubject<Void, Never>()
    private(set) var host: SyncEngineHost!
    private(set) var follower: SyncPassFollower!
    private(set) var opened: [FakeSyncEngine] = []
    // The next open waits at the gate.
    var openGate: AsyncGate?
    // Each open's service finishes a pass and signals it before the open returns, as the core's launch pass can.
    var passesWhileOpening = false
    private var signals = 0
    private var watching: AnyCancellable?
    private var listeners: [any SyncListener] = []
    private var passAt: Int64 = 1_764_000_000_000
    private(set) var reads = 0
    // The pass of the service open when the stores were last read.
    private(set) var readPass: Int64?
    private let stores: SyncPulledStores

    init(_ stores: SyncPulledStores) {
        self.stores = stores
        launch()
    }

    // A new run of the app: its own host and follower, over the same stores.
    func launch() {
        let log = log
        host = SyncEngineHost(
            transport: CloudKitCoreTransport(database: FakeCloudKitDatabase()),
            signInChanges: signIns.eraseToAnyPublisher(),
            open: { [unowned self] provider, listener in
                if let gate = openGate {
                    openGate = nil
                    await gate.wait()
                }
                let engine = FakeSyncEngine()
                engine.update { state in
                    state.info.provider = provider
                    state.flush = { log.append("closed \(provider)") }
                }
                log.append("opened \(provider)")
                opened.append(engine)
                listeners.append(listener)
                if passesWhileOpening {
                    passAt += 1_000
                    let finished = passAt
                    engine.update { $0.info.lastPassMs = finished }
                    let before = signals
                    listener.statusChanged()
                    try await waitUntil { self.signals > before }
                }
                return engine
            }
        )
        watching = host.statusChanges.sink { [unowned self] in signals += 1 }
        var counted = stores
        let library = stores.library
        counted.library = { [unowned self] in
            reads += 1
            readPass = currentPass
            library()
        }
        follower = SyncPassFollower()
        follower.start(host: host, stores: counted)
    }

    var currentPass: Int64? {
        host.openedEngine(for: .off)?.status().lastPassMs
    }

    func open(_ service: OpenedService) async throws {
        switch service {
        case .onTableProSync:
            _ = try await host.engine(for: .tableproSync)
        case .onICloud:
            _ = try await host.engine(for: .icloud)
        case .movedFromOff:
            _ = try await host.engine(for: .off)
            _ = try await host.engine(for: .tableproSync)
        case .movedFromICloud:
            _ = try await host.engine(for: .icloud)
            _ = try await host.engine(for: .tableproSync)
        case .signedInAgain:
            _ = try await host.engine(for: .tableproSync)
            signIns.send()
            try await waitUntil { self.opened.count == 2 && self.host.openedEngine(for: .off) === self.opened.last }
        case .relaunched:
            _ = try await host.engine(for: .tableproSync)
            try await pass()
            launch()
            _ = try await host.engine(for: .tableproSync)
        }
    }

    // A pass of the service open now: it wrote what `write` writes, then reports as the core does.
    func pass(writing write: () async throws -> Void = {}) async throws {
        try await write()
        guard let engine = host.openedEngine(for: .off) as? FakeSyncEngine, let listener = listeners.last else {
            throw NoServiceOpen()
        }
        passAt += 1_000
        let finished = passAt
        engine.update { $0.info.lastPassMs = finished }
        let before = reads
        listener.statusChanged()
        try await waitUntil { self.reads > before }
        await follower.readsFinished()
    }
}

@MainActor
struct SyncPassFollowerTests {
    @Test("Each finished pass reads every store once, the library first; a status change with no new pass reads none")
    func eachPassReadsEveryStoreOnce() async throws {
        let changes = PassthroughSubject<Void, Never>()
        var pass: Int64?
        var reads: [String] = []
        let stores = SyncPulledStores(
            library: { reads.append("library") },
            savedQueries: { reads.append("savedQueries") },
            favoriteTables: { reads.append("favoriteTables") },
            favoriteDatabases: { reads.append("favoriteDatabases") },
            tableFolders: { reads.append("tableFolders") },
            history: { reads.append("history") }
        )
        let follower = SyncPassFollower()
        follower.start(changes: changes.eraseToAnyPublisher(), lastPass: { pass }, stores: stores)

        changes.send()
        pass = 1
        changes.send()
        changes.send()
        try await waitUntil { reads.count == 6 }
        await follower.readsFinished()
        #expect(reads == ["library", "savedQueries", "favoriteTables", "favoriteDatabases", "tableFolders", "history"])

        pass = 2
        changes.send()
        try await waitUntil { reads.count == 12 }
        await follower.readsFinished()
        #expect(reads.count == 12)
    }

    @Test("Passes that end while the stores are read are read once more after, not once each")
    func passesDuringAReadReadOnceMore() async throws {
        let changes = PassthroughSubject<Void, Never>()
        var pass: Int64 = 1
        var libraryReads = 0
        let gate = AsyncGate()
        var stores = SyncPulledStores.none
        stores.library = { libraryReads += 1 }
        stores.history = { await gate.wait() }
        let follower = SyncPassFollower()
        follower.start(changes: changes.eraseToAnyPublisher(), lastPass: { pass }, stores: stores)

        changes.send()
        await gate.arrived(1)
        pass = 2
        changes.send()
        pass = 3
        changes.send()
        await gate.open()
        await follower.readsFinished()

        #expect(libraryReads == 2)
    }

    @Test("A pass of the service open now reads the stores, however that service came to be open", arguments: OpenedService.allCases)
    func everyOpenedServiceIsFollowed(_ service: OpenedService) async throws {
        let harness = PassHarness(.none)
        try await harness.open(service)
        let before = harness.reads

        try await harness.pass()

        #expect(harness.reads == before + 1)
    }

    @Test("A pass that ends while its service is still opening is read once the service is in place", arguments: OpenedService.allCases)
    func passWhileOpeningIsRead(_ service: OpenedService) async throws {
        let harness = PassHarness(.none)
        harness.passesWhileOpening = true

        try await harness.open(service)

        try await waitUntil { harness.currentPass != nil && harness.readPass == harness.currentPass }
    }

    @Test("A service for another provider takes the open one's place: a caller meanwhile waits for it, never the old one")
    func anotherProvidersServiceReplacesTheOpenOne() async throws {
        let harness = PassHarness(.none)
        let off = try await harness.host.engine(for: .off)
        let gate = AsyncGate()
        harness.openGate = gate

        let opening = Task { try await harness.host.engine(for: .tableproSync) }
        await gate.arrived(1)
        let handedOut = harness.host.openedEngine(for: .off)
        let meanwhile = Task { try await harness.host.accountScopesEngine() }
        try await waitUntil { harness.log.all.contains("closed off") }
        await gate.open()
        let moved = try await opening.value
        let scopes = try await meanwhile.value

        #expect(handedOut == nil)
        #expect(moved !== off)
        #expect(scopes === moved)
        #expect(harness.log.all.filter { $0.hasPrefix("opened") } == ["opened off", "opened tableproSync"])
    }
}

// What a pull wrote into the core reaches what the app shows, after one pass, without a relaunch.
@MainActor
struct SyncPulledStoresTests {
    @Test("A pulled connection, group, tag, project and SSH and credential profile reach their lists", arguments: OpenedService.allCases)
    func library(_ service: OpenedService) async throws {
        let fixture = try CoreLibraryFixture()
        let storage = fixture.launch()
        let alpha = DatabaseConnection(name: "alpha", host: "alpha.example.com", port: 5_432, type: .postgresql)
        #expect(storage.addConnection(alpha))
        #expect(fixture.sshProfiles(storage).addProfile(
            SSHProfile(name: "Bastion", host: "bastion.example.com", port: 22, username: "deploy")
        ))
        #expect(fixture.credentialProfiles(storage).addProfile(
            CredentialProfile(name: "Reader", username: "app_reader", passwordMode: .stored)
        ))
        var told = 0
        let watching = fixture.events.connectionUpdated.sink { _ in told += 1 }
        defer { watching.cancel() }
        var stores = SyncPulledStores.none
        stores.library = { storage.readCoreWrites() }
        let harness = PassHarness(stores)
        try await harness.open(service)
        let toldBefore = told

        try await harness.pass {
            let library = try fixture.coreLibrary(reporting: true)
            _ = try await library.createProject(name: "E2E project", color: nil)
            _ = try await library.createGroup(name: "Pulled group", parentId: nil, projectId: nil)
            _ = try await library.createTag(name: "pulled", color: "orange")
            _ = try await library.duplicate(id: alpha.id.uuidString, name: "Pulled copy")
            try await fixture.writeAsTheCore { contents in
                contents.sshProfiles[0].name = "Pulled bastion"
                contents.credentialProfiles[0].name = "Pulled reader"
            }
        }

        #expect(fixture.projects(storage).loadProjects().map(\.name) == ["E2E project"])
        #expect(fixture.groups(storage).loadGroups().contains { $0.name == "Pulled group" })
        #expect(fixture.tags(storage).loadTags().contains { $0.name == "pulled" })
        #expect(storage.loadConnections().contains { $0.name == "Pulled copy" })
        #expect(fixture.sshProfiles(storage).loadProfiles().map(\.name) == ["Pulled bastion"])
        #expect(fixture.credentialProfiles(storage).loadProfiles().map(\.name) == ["Pulled reader"])
        #expect(told > toldBefore)
    }

    @Test("A pulled saved query and folder reach sql_favorites.db, and the Favorites sidebar is told", arguments: OpenedService.allCases)
    func savedQueries(_ service: OpenedService) async throws {
        let fixture = try CoreMirrorFixture()
        let storage = SQLFavoriteStorage(databaseURL: fixture.url("sql_favorites.db"))
        let events = AppEvents()
        let manager = SQLFavoriteManager(
            storage: storage,
            syncJournal: SyncHostJournal(),
            appEvents: events,
            core: fixture.core,
            mirrorDefaults: try fixture.pool.make().defaults
        )
        let connectionId = UUID()
        #expect(await storage.addFavorite(SQLFavorite(name: "Mine", query: "SELECT 1", connectionId: connectionId)))
        await manager.pushToCore()
        var told = 0
        let watching = events.sqlFavoritesDidUpdate.sink { _ in told += 1 }
        defer { watching.cancel() }
        var stores = SyncPulledStores.none
        stores.savedQueries = { _ = await manager.pushToCore() }
        let harness = PassHarness(stores)
        try await harness.open(service)
        let toldBefore = told
        let folderId = UUID()
        let queryId = UUID()

        try await harness.pass {
            _ = try await fixture.core.savedQueries().writeRecords(write: SavedQueryRecordWrite(
                queries: [SavedQueryRecord(
                    id: queryId.uuidString,
                    name: "Pulled",
                    sql: "SELECT 'pulled'",
                    keyword: nil,
                    connectionId: connectionId.uuidString,
                    connectionName: "",
                    folderId: folderId.uuidString,
                    order: 1,
                    createdAtMs: 1_764_000_000_000,
                    updatedAtMs: 1_764_000_000_000
                )],
                folders: [SavedQueryFolderRecord(
                    id: folderId.uuidString,
                    name: "Pulled folder",
                    connectionId: connectionId.uuidString,
                    parentId: nil,
                    order: 0,
                    createdAtMs: 1_764_000_000_000,
                    updatedAtMs: 1_764_000_000_000
                )],
                removedQueries: [],
                removedFolders: []
            ))
        }

        #expect(await storage.fetchFavorite(id: queryId)?.name == "Pulled")
        #expect(await storage.fetchFavorite(id: queryId)?.folderId == folderId)
        #expect(told > toldBefore)
    }

    @Test("Pulled favourite tables, favourite databases and table folders reach their stores, which say so", arguments: OpenedService.allCases)
    func favouritesAndTableFolders(_ service: OpenedService) async throws {
        let fixture = try CoreMirrorFixture()
        let connectionId = UUID()
        let tables = FavoriteTablesStorage(userDefaults: try fixture.pool.make().defaults, syncJournal: SyncHostJournal(), core: fixture.core)
        let databases = FavoriteDatabasesStorage(defaults: try fixture.pool.make().defaults, syncJournal: SyncHostJournal(), core: fixture.core)
        let center = NotificationCenter()
        let folders = TableFolderStorage(
            defaults: try fixture.pool.make().defaults,
            syncJournal: SyncHostJournal(),
            notificationCenter: center,
            core: fixture.core,
            mirrorDefaults: try fixture.pool.make().defaults
        )
        let scope = DatabaseScope(connectionId: connectionId, database: "shop", schema: nil)
        tables.addFavorite(name: "orders", schema: nil, database: "shop", connectionId: connectionId)
        databases.setFavorite(database: "shop", environment: .production, connectionId: connectionId)
        _ = folders.createFolder(named: "Billing", in: scope)
        await tables.coreMirror?.push()
        await databases.coreMirror?.push()
        await folders.coreMirror?.push()
        var told: Set<String> = []
        let watching = [
            NotificationCenter.default.publisher(for: .favoriteTablesDidChange, object: tables).sink { _ in told.insert("tables") },
            NotificationCenter.default.publisher(for: .favoriteDatabasesDidChange, object: databases).sink { _ in told.insert("databases") },
            center.publisher(for: .tableFoldersDidChange).sink { _ in told.insert("folders") },
        ]
        defer { watching.forEach { $0.cancel() } }
        var stores = SyncPulledStores.none
        stores.favoriteTables = { _ = await tables.coreMirror?.push() }
        stores.favoriteDatabases = { _ = await databases.coreMirror?.push() }
        stores.tableFolders = { _ = await folders.coreMirror?.push() }
        let harness = PassHarness(stores)
        try await harness.open(service)
        told = []

        try await harness.pass {
            _ = try await fixture.core.favourites().writeRecords(write: FavouriteRecordWrite(
                tables: [FavouriteTableRecord(connectionId: connectionId.uuidString, database: "shop", schema: "", name: "invoices")],
                databases: [FavouriteDatabaseRecord(connectionId: connectionId.uuidString, database: "audit", environment: .testing)],
                removedTables: [],
                removedDatabases: []
            ))
            _ = try await fixture.core.tableFolders().writeRecords(write: TableFolderRecordWrite(
                folders: [TableFolderRecord(
                    id: UUID().uuidString,
                    connectionId: connectionId.uuidString,
                    database: "shop",
                    schema: "",
                    name: "Reports",
                    createdAtMs: 1_764_000_000_000,
                    updatedAtMs: 1_764_000_000_000
                )],
                items: [],
                removedFolders: [],
                removedItems: []
            ))
        }

        #expect(tables.loadFavorites().map(\.name).sorted() == ["invoices", "orders"])
        #expect(databases.loadFavorites().map(\.database).sorted() == ["audit", "shop"])
        #expect(folders.layout(in: scope).folders.map { $0.name } == ["Billing", "Reports"])
        #expect(told == ["tables", "databases", "folders"])
    }

    @Test("A pulled history run reaches query_history.db, and the History pane is told", arguments: OpenedService.allCases)
    func history(_ service: OpenedService) async throws {
        let fixture = try CoreMirrorFixture()
        let storage = QueryHistoryStorage(databaseURL: fixture.url("query_history.db"))
        let told = OSAllocatedUnfairLock(initialState: 0)
        let mirror = QueryHistoryCoreMirror(
            storage: storage,
            database: fixture.core,
            connectionNames: { _ in [:] },
            changed: { told.withLock { $0 += 1 } }
        )
        await mirror.push()
        var stores = SyncPulledStores.none
        stores.history = { await mirror.pushSoon() }
        let harness = PassHarness(stores)
        try await harness.open(service)
        let toldBefore = told.withLock { $0 }
        let runId = UUID()

        try await harness.pass {
            _ = try await fixture.core.history().putEntries(entries: [HistoryEntryRecord(
                recordId: runId.uuidString,
                sql: "SELECT 'pulled'",
                driverId: DatabaseType.postgresql.rawValue,
                connectionId: UUID().uuidString,
                connectionName: "shop",
                executedAtMs: 1_764_000_000_000,
                durationMs: 40,
                rowsAffected: 7,
                outcome: .succeeded,
                details: HistoryRunDetails(
                    database: "shop",
                    schema: nil,
                    source: nil,
                    statementType: nil,
                    firstRowMs: nil,
                    serverMs: nil,
                    fingerprint: nil
                )
            )])
        }

        #expect(await storage.entryIds() == [runId])
        #expect(told.withLock { $0 } > toldBefore)
    }
}
