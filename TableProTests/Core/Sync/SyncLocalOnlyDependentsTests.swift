import CloudKit
import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

@MainActor
struct SyncLocalOnlyDependentsTests {
    enum KeptOffICloud: CaseIterable {
        case localOnly
        case sample
    }

    @MainActor
    private struct Dependents {
        let tableFavorite: FavoriteTablesStorage.FavoriteEntry
        let databaseFavorite: FavoriteDatabaseEntry
        let savedQuery: SQLFavorite
        let folder: SQLFavoriteFolder
        let layoutKey: ColumnLayoutTableKey

        var tableFavoriteId: String { FavoriteTablesStorage.syncId(for: tableFavorite) }
        var databaseFavoriteId: String { FavoriteDatabasesStorage.syncId(for: databaseFavorite) }
        var layoutCategory: String { FileColumnLayoutPersister.syncCategory(for: layoutKey.storageKey) }

        var recordIDs: Set<CKRecord.ID> {
            [
                SyncLocalOnlyDependentsTests.recordID(.tableFavorite, tableFavoriteId),
                SyncLocalOnlyDependentsTests.recordID(.favoriteDatabase, databaseFavoriteId),
                SyncLocalOnlyDependentsTests.recordID(.favorite, savedQuery.id.uuidString),
                SyncLocalOnlyDependentsTests.recordID(.favoriteFolder, folder.id.uuidString),
                SyncLocalOnlyDependentsTests.recordID(.settings, layoutCategory)
            ]
        }
    }

    private static let zoneID = SyncTestEnvironment.zoneID

    private let environment: SyncTestEnvironment

    init() throws {
        environment = try SyncTestEnvironment(label: "sync-local-only-dependents")
    }

    private var tracker: SyncChangeTracker { environment.tracker }
    private var metadata: SyncMetadataStorage { environment.metadata }

    private static func recordID(_ type: SyncRecordType, _ id: String) -> CKRecord.ID {
        SyncRecordMapper.recordID(type: type, id: id, in: zoneID)
    }

    private func addConnection(_ keptOff: KeptOffICloud? = nil) -> DatabaseConnection {
        var connection = TestFixtures.makeConnection()
        connection.localOnly = keptOff == .localOnly
        connection.isSample = keptOff == .sample
        environment.connections.addConnection(connection)
        return connection
    }

    private func layoutKey(_ connectionId: UUID, table: String = "orders") -> ColumnLayoutTableKey {
        ColumnLayoutTableKey(connectionId: connectionId, databaseName: "shop", schemaName: "public", tableName: table)
    }

    private func saveLayout(_ key: ColumnLayoutTableKey) {
        var layout = ColumnLayoutState()
        layout.columnWidths = ["id": 80]
        environment.columnLayouts.save(layout, for: key)
    }

    private func addDependents(of connectionId: UUID) async -> Dependents {
        let dependents = Dependents(
            tableFavorite: FavoriteTablesStorage.FavoriteEntry(
                connectionId: connectionId, database: "shop", schema: "public", name: "orders"
            ),
            databaseFavorite: FavoriteDatabaseEntry(
                connectionId: connectionId, database: "shop", environment: .production
            ),
            savedQuery: SQLFavorite(name: "Revenue", query: "SELECT 1", connectionId: connectionId),
            folder: SQLFavoriteFolder(name: "Reports", connectionId: connectionId),
            layoutKey: layoutKey(connectionId)
        )
        environment.favoriteTables.addFavorite(name: "orders", schema: "public", database: "shop", connectionId: connectionId)
        environment.favoriteDatabases.setFavorite(database: "shop", environment: .production, connectionId: connectionId)
        #expect(await environment.favorites.addFavorite(dependents.savedQuery))
        #expect(await environment.favorites.addFolder(dependents.folder))
        saveLayout(dependents.layoutKey)
        return dependents
    }

    private func expectMarked(_ dependents: Dependents) {
        #expect(tracker.dirtyRecords(for: .tableFavorite).contains(dependents.tableFavoriteId))
        #expect(tracker.dirtyRecords(for: .favoriteDatabase).contains(dependents.databaseFavoriteId))
        #expect(tracker.dirtyRecords(for: .favorite).contains(dependents.savedQuery.id.uuidString))
        #expect(tracker.dirtyRecords(for: .favoriteFolder).contains(dependents.folder.id.uuidString))
        #expect(tracker.dirtyRecords(for: .settings).contains(dependents.layoutCategory))
    }

    private func runCycle(_ transport: ScriptedSyncTransport) async -> SyncError? {
        await environment.makeCoordinator(transport: transport).runSyncCycle()
    }

    private static func isolatedQueryHistory() -> QueryHistoryManager {
        QueryHistoryManager(
            storage: QueryHistoryStorage(
                databaseURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("tablepro-tests")
                    .appendingPathComponent("local-only-purge-\(UUID().uuidString).db"),
                removeDatabaseOnDeinit: true
            ),
            isCapturePaused: { false }
        )
    }

    // MARK: - Push

    @Test(
        "A connection kept off iCloud keeps its favorites, saved queries, folders and layouts off it, marks held",
        arguments: KeptOffICloud.allCases
    )
    func keptOffConnectionHoldsItsDependents(_ keptOff: KeptOffICloud) async {
        let connection = addConnection(keptOff)
        let dependents = await addDependents(of: connection.id)
        let transport = ScriptedSyncTransport(zoneID: Self.zoneID)

        let failure = await runCycle(transport)

        #expect(failure == nil)
        #expect(await transport.pushedRecords.isEmpty)
        #expect(await transport.pushedDeletions.isEmpty)
        expectMarked(dependents)
    }

    @Test("A synced connection's favorites, saved queries, folders and layouts go up and their marks clear")
    func syncedConnectionPushesItsDependents() async {
        let connection = addConnection()
        let dependents = await addDependents(of: connection.id)
        let transport = ScriptedSyncTransport(zoneID: Self.zoneID)

        let failure = await runCycle(transport)

        #expect(failure == nil)
        #expect(Set(await transport.pushedRecords.map(\.recordID)).isSuperset(of: dependents.recordIDs))
        #expect(tracker.dirtyRecords(for: .tableFavorite).isEmpty)
        #expect(tracker.dirtyRecords(for: .favoriteDatabase).isEmpty)
        #expect(tracker.dirtyRecords(for: .favorite).isEmpty)
        #expect(tracker.dirtyRecords(for: .favoriteFolder).isEmpty)
        #expect(tracker.dirtyRecords(for: .settings).isEmpty)
    }

    @Test("Deletions of a Local only connection's favorites, saved queries, folders and layouts are held")
    func localOnlyDeletionsAreHeld() async {
        let connection = addConnection(.localOnly)
        let dependents = await addDependents(of: connection.id)
        environment.favoriteTables.removeFavorite(name: "orders", schema: "public", database: "shop", connectionId: connection.id)
        environment.favoriteDatabases.removeFavorite(database: "shop", connectionId: connection.id)
        #expect(await environment.favorites.deleteFavorite(id: dependents.savedQuery.id))
        #expect(await environment.favorites.deleteFolder(id: dependents.folder.id))
        environment.columnLayouts.clear(for: dependents.layoutKey)
        let transport = ScriptedSyncTransport(zoneID: Self.zoneID)

        let failure = await runCycle(transport)

        #expect(failure == nil)
        #expect(await transport.pushedDeletions.isEmpty)
        #expect(tracker.tombstonedIds(for: .tableFavorite) == [dependents.tableFavoriteId])
        #expect(tracker.tombstonedIds(for: .favoriteDatabase) == [dependents.databaseFavoriteId])
        #expect(tracker.tombstonedIds(for: .favorite) == [dependents.savedQuery.id.uuidString])
        #expect(tracker.tombstonedIds(for: .favoriteFolder) == [dependents.folder.id.uuidString])
        #expect(tracker.tombstonedIds(for: .settings) == [dependents.layoutCategory])
    }

    @Test("Putting a connection back in sync sends the edits and deletions held while it was Local only")
    func reincludedConnectionReleasesHeldWork() async {
        let connection = addConnection(.localOnly)
        let kept = await addDependents(of: connection.id)
        environment.favoriteTables.addFavorite(name: "gone", schema: "public", database: "shop", connectionId: connection.id)
        environment.favoriteTables.removeFavorite(name: "gone", schema: "public", database: "shop", connectionId: connection.id)
        let removedId = FavoriteTablesStorage.syncId(for: FavoriteTablesStorage.FavoriteEntry(
            connectionId: connection.id, database: "shop", schema: "public", name: "gone"
        ))
        #expect(await runCycle(ScriptedSyncTransport(zoneID: Self.zoneID)) == nil)
        #expect(environment.connections.mutateConnections(ids: [connection.id]) { $0.localOnly = false })
        let transport = ScriptedSyncTransport(zoneID: Self.zoneID)

        let failure = await runCycle(transport)

        #expect(failure == nil)
        #expect(Set(await transport.pushedRecords.map(\.recordID)).isSuperset(of: kept.recordIDs))
        #expect(await transport.pushedDeletions == [Self.recordID(.tableFavorite, removedId)])
        #expect(tracker.tombstonedIds(for: .tableFavorite).isEmpty)
    }

    @Test("A deletion recorded before deletions had owners still goes up")
    func legacyOwnerlessTombstoneStillPushes() async {
        metadata.addTombstone("legacy", type: .tableFavorite)
        let transport = ScriptedSyncTransport(zoneID: Self.zoneID)

        let failure = await runCycle(transport)

        #expect(failure == nil)
        #expect(await transport.pushedDeletions == [Self.recordID(.tableFavorite, "legacy")])
    }

    @Test("An unreadable connection list holds every record that belongs to a connection and sends the rest")
    func unreadableConnectionStoreHoldsOwnedRecords() async throws {
        let connection = addConnection()
        environment.favoriteTables.addFavorite(name: "orders", schema: nil, database: "shop", connectionId: connection.id)
        let global = SQLFavorite(name: "Everywhere", query: "SELECT 1")
        #expect(await environment.favorites.addFavorite(global))
        metadata.addTombstones(["owned"], type: .favoriteDatabase, owner: connection.id)
        try Data("not json".utf8).write(to: environment.directory.appendingPathComponent("connections.json"))
        environment.connections.invalidateCache()
        let transport = ScriptedSyncTransport(zoneID: Self.zoneID)

        let failure = await runCycle(transport)

        #expect(failure == nil)
        #expect(await transport.pushedRecords.map(\.recordID) == [Self.recordID(.favorite, global.id.uuidString)])
        #expect(await transport.pushedDeletions.isEmpty)
        #expect(tracker.dirtyRecords(for: .tableFavorite).count == 1)
        #expect(tracker.tombstonedIds(for: .favoriteDatabase) == ["owned"])
    }

    @Test("A connection edit still goes up when the push could not tell which connections are kept off iCloud")
    func connectionEditSurvivesUnknownOwners() async {
        let connection = addConnection()
        let coordinator = environment.makeCoordinator(transport: ScriptedSyncTransport(zoneID: Self.zoneID))
        let boundary = SyncBoundary(includedTypes: Set(SyncRecordType.allCases), excludedConnectionIds: nil)

        let batch = await coordinator.collectPushBatch(
            snapshot: tracker.editSnapshot(), boundary: boundary, zoneID: Self.zoneID
        )

        #expect(batch.records.map(\.recordID) == [Self.recordID(.connection, connection.id.uuidString)])
        #expect(tracker.dirtyRecords(for: .connection) == [connection.id.uuidString])
    }

    // MARK: - Column layout deletions

    @Test("A column layout cleared on a synced connection sends its deletion")
    func clearedLayoutSendsItsDeletion() async {
        let connection = addConnection()
        let key = layoutKey(connection.id)
        saveLayout(key)
        #expect(await runCycle(ScriptedSyncTransport(zoneID: Self.zoneID)) == nil)
        environment.columnLayouts.clear(for: key)
        let transport = ScriptedSyncTransport(zoneID: Self.zoneID)

        let failure = await runCycle(transport)

        let category = FileColumnLayoutPersister.syncCategory(for: key.storageKey)
        #expect(failure == nil)
        #expect(await transport.pushedDeletions == [Self.recordID(.settings, category)])
        #expect(tracker.tombstonedIds(for: .settings).isEmpty)
    }

    @Test("A layout deletion left over for a layout this Mac still holds is dropped rather than sent")
    func staleLayoutTombstoneIsDropped() async {
        let connection = addConnection()
        let key = layoutKey(connection.id)
        saveLayout(key)
        #expect(await runCycle(ScriptedSyncTransport(zoneID: Self.zoneID)) == nil)
        let category = FileColumnLayoutPersister.syncCategory(for: key.storageKey)
        metadata.addTombstone(category, type: .settings)
        let transport = ScriptedSyncTransport(zoneID: Self.zoneID)

        let failure = await runCycle(transport)

        #expect(failure == nil)
        #expect(await transport.pushedDeletions.isEmpty)
        #expect(tracker.tombstonedIds(for: .settings).isEmpty)
        #expect(environment.columnLayouts.load(for: key) != nil)
    }

    @Test("A layout this Mac is deleting is not brought back by a pull before the deletion goes up")
    func pulledLayoutWaitingOnItsDeletionStaysDeleted() async throws {
        let connection = addConnection()
        let key = layoutKey(connection.id)
        saveLayout(key)
        let category = FileColumnLayoutPersister.syncCategory(for: key.storageKey)
        let remote = SyncRecordMapper.toCKRecord(
            category: category,
            settingsData: Data(#"{"columnWidths":{"id":120}}"#.utf8),
            in: Self.zoneID
        )
        environment.columnLayouts.clear(for: key)
        let coordinator = environment.makeCoordinator(transport: ScriptedSyncTransport(zoneID: Self.zoneID))

        let acknowledged = await coordinator.applyPullResult(
            PullResult(changedRecords: [remote], deletedRecordIDs: [], newToken: nil)
        )
        let transport = ScriptedSyncTransport(zoneID: Self.zoneID)
        let failure = await runCycle(transport)

        #expect(acknowledged)
        #expect(failure == nil)
        #expect(environment.columnLayouts.load(for: key) == nil)
        #expect(await transport.pushedDeletions == [Self.recordID(.settings, category)])
    }

    @Test("A layout deletion from another Mac that cannot be written here is not acknowledged")
    func unwritableLayoutDeletionIsNotAcknowledged() async throws {
        let connection = addConnection()
        let removed = layoutKey(connection.id)
        let kept = layoutKey(connection.id, table: "customers")
        saveLayout(removed)
        saveLayout(kept)
        let directory = environment.directory.appendingPathComponent("ColumnLayout", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        let coordinator = environment.makeCoordinator(transport: ScriptedSyncTransport(zoneID: Self.zoneID))

        let acknowledged = await coordinator.applyPullResult(PullResult(
            changedRecords: [],
            deletedRecordIDs: [Self.recordID(.settings, FileColumnLayoutPersister.syncCategory(for: removed.storageKey))],
            newToken: nil
        ))

        #expect(!acknowledged)
        #expect(environment.columnLayouts.load(for: removed) != nil)
        #expect(tracker.dirtyRecords(for: .settings).contains(FileColumnLayoutPersister.syncCategory(for: removed.storageKey)))
    }

    @Test("A layout clear that cannot be written leaves the layout and records no deletion")
    func unwritableLayoutClearRecordsNoDeletion() throws {
        let connection = addConnection()
        let cleared = layoutKey(connection.id)
        saveLayout(cleared)
        saveLayout(layoutKey(connection.id, table: "customers"))
        let directory = environment.directory.appendingPathComponent("ColumnLayout", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }

        environment.columnLayouts.clear(for: cleared)

        #expect(environment.columnLayouts.load(for: cleared) != nil)
        #expect(tracker.tombstonedIds(for: .settings).isEmpty)
    }

    // MARK: - Deleting the connection

    @Test("Deleting a Local only connection removes its dependents without a trace in iCloud sync")
    func localOnlyPurgeLeavesNoTombstones() async throws {
        let connection = addConnection(.localOnly)
        let dependents = await addDependents(of: connection.id)
        environment.favoriteTables.addFavorite(name: "gone", schema: nil, database: "shop", connectionId: connection.id)
        environment.favoriteTables.removeFavorite(name: "gone", schema: nil, database: "shop", connectionId: connection.id)
        #expect(tracker.tombstonedIds(for: .tableFavorite).count == 1)
        #expect(environment.connections.saveConnections([]))
        let history = Self.isolatedQueryHistory()

        ConnectionLocalState.purge(
            connectionIds: [connection.id],
            origin: .localOnly,
            tableScopedStores: [environment.columnLayouts],
            favoriteTables: environment.favoriteTables,
            favoriteDatabases: environment.favoriteDatabases,
            sqlFavorites: environment.favorites,
            queryHistory: history,
            syncTracker: tracker
        )
        await ConnectionLocalState.purgeAsyncStores(
            [connection.id], origin: .localOnly, sqlFavorites: environment.favorites, queryHistory: history,
            syncTracker: tracker
        )
        let transport = ScriptedSyncTransport(zoneID: Self.zoneID)
        let failure = await runCycle(transport)

        #expect(failure == nil)
        #expect(await transport.pushedRecords.isEmpty)
        #expect(await transport.pushedDeletions.isEmpty)
        #expect(await environment.favorites.fetchFavorite(id: dependents.savedQuery.id) == nil)
        #expect(environment.favoriteTables.favorites(for: connection.id).isEmpty)
        #expect(tracker.ownersKeptOffSync.isEmpty)
        for type in SyncRecordType.allCases {
            #expect(tracker.tombstonedIds(for: type).isEmpty, "\(type.rawValue)")
            #expect(tracker.dirtyRecords(for: type).isEmpty, "\(type.rawValue)")
        }
    }

    @Test("A deleted Local only connection stays out of iCloud until its saved queries are gone")
    func deletedLocalOnlyOwnerStaysExcludedUntilItsSavedQueriesAreGone() async {
        let connection = addConnection(.localOnly)
        let savedQuery = SQLFavorite(name: "Revenue", query: "SELECT 1", connectionId: connection.id)
        #expect(await environment.favorites.addFavorite(savedQuery))
        #expect(environment.connections.saveConnections([]))
        let coordinator = environment.makeCoordinator(transport: ScriptedSyncTransport(zoneID: Self.zoneID))
        let history = Self.isolatedQueryHistory()

        ConnectionLocalState.purge(
            connectionIds: [connection.id],
            origin: .localOnly,
            tableScopedStores: [],
            favoriteTables: environment.favoriteTables,
            favoriteDatabases: environment.favoriteDatabases,
            sqlFavorites: environment.favorites,
            queryHistory: history,
            syncTracker: tracker
        )

        #expect(tracker.ownersKeptOffSync == [connection.id])
        #expect(!coordinator.syncBoundary(settings: .default).includes(.favorite, owner: connection.id))

        await ConnectionLocalState.purgeAsyncStores(
            [connection.id], origin: .localOnly, sqlFavorites: environment.favorites, queryHistory: history,
            syncTracker: tracker
        )

        #expect(await environment.favorites.fetchFavorite(id: savedQuery.id) == nil)
        #expect(tracker.ownersKeptOffSync.isEmpty)
    }

    @Test("Deleting a Local only connection forgets the deletions held for it, and a synced one keeps them")
    func connectionDeleteDiscardsOnlyALocalOnlyOwnersTombstones() {
        let localOnly = addConnection(.localOnly)
        let synced = addConnection()
        metadata.addTombstones(["held"], type: .tableFavorite, owner: localOnly.id)
        metadata.addTombstones(["pending"], type: .tableFavorite, owner: synced.id)
        metadata.addTombstone(
            FileColumnLayoutPersister.syncCategory(for: layoutKey(localOnly.id).storageKey),
            type: .settings
        )

        #expect(environment.connections.deleteConnection(localOnly))
        #expect(tracker.tombstonedIds(for: .tableFavorite) == ["pending"])
        #expect(tracker.tombstonedIds(for: .settings).isEmpty)
        #expect(tracker.tombstonedIds(for: .connection).isEmpty)

        #expect(environment.connections.deleteConnections([synced]))
        #expect(tracker.tombstonedIds(for: .tableFavorite) == ["pending"])
        #expect(tracker.tombstonedIds(for: .connection) == [synced.id.uuidString])
    }

    // MARK: - Pruning

    @Test("Pruning keeps a month-old deletion held for a Local only connection and drops a pushable one")
    func pruningKeepsHeldTombstones() throws {
        let localOnly = addConnection(.localOnly)
        let synced = addConnection()
        let fortyDaysAgo = Date(timeIntervalSinceNow: -60 * 60 * 24 * 40)
        let tombstones = [
            Tombstone(id: "held", deletedAt: fortyDaysAgo, owner: localOnly.id),
            Tombstone(id: "expired", deletedAt: fortyDaysAgo, owner: synced.id),
            Tombstone(id: "recent", deletedAt: Date(), owner: synced.id)
        ]
        metadata.userDefaults.set(
            try JSONEncoder().encode(tombstones),
            forKey: "com.TablePro.sync.tombstones.\(SyncRecordType.tableFavorite.rawValue)"
        )
        let coordinator = environment.makeCoordinator(transport: ScriptedSyncTransport(zoneID: Self.zoneID))

        coordinator.pruneTombstones(within: coordinator.syncBoundary(settings: SyncSettings.default))

        #expect(tracker.tombstonedIds(for: .tableFavorite) == ["held", "recent"])
    }

    @Test("A deletion held when the push ran is not pruned by a connection put back in sync during the cycle")
    func heldTombstoneSurvivesAScopeChangeMidCycle() async throws {
        let connection = addConnection(.localOnly)
        let fortyDaysAgo = Date(timeIntervalSinceNow: -60 * 60 * 24 * 40)
        metadata.userDefaults.set(
            try JSONEncoder().encode([Tombstone(id: "held", deletedAt: fortyDaysAgo, owner: connection.id)]),
            forKey: "com.TablePro.sync.tombstones.\(SyncRecordType.tableFavorite.rawValue)"
        )
        let global = SQLFavorite(name: "Everywhere", query: "SELECT 1")
        #expect(await environment.favorites.addFavorite(global))
        let connections = environment.connections
        let transport = ScriptedSyncTransport(
            zoneID: Self.zoneID,
            duringPush: { _ = connections.mutateConnections(ids: [connection.id]) { $0.localOnly = false } }
        )

        let failure = await runCycle(transport)

        #expect(failure == nil)
        #expect(await transport.pushedDeletions.isEmpty)
        #expect(tracker.tombstonedIds(for: .tableFavorite) == ["held"])
    }

    // MARK: - Remote deletions

    @Test("A database favorite removed on another Mac is removed here and takes its mark with it")
    func remoteDatabaseFavoriteDeletionIsApplied() async {
        let connection = addConnection()
        environment.favoriteDatabases.setFavorite(database: "shop", environment: .production, connectionId: connection.id)
        environment.favoriteDatabases.setFavorite(database: "kept", environment: .testing, connectionId: connection.id)
        let removed = FavoriteDatabaseEntry(connectionId: connection.id, database: "shop", environment: .production)
        let coordinator = environment.makeCoordinator(transport: ScriptedSyncTransport(zoneID: Self.zoneID))

        let acknowledged = await coordinator.applyPullResult(PullResult(
            changedRecords: [],
            deletedRecordIDs: [Self.recordID(.favoriteDatabase, FavoriteDatabasesStorage.syncId(for: removed))],
            newToken: nil
        ))

        #expect(acknowledged)
        #expect(environment.favoriteDatabases.favorites(for: connection.id).map(\.database) == ["kept"])
        #expect(!tracker.dirtyRecords(for: .favoriteDatabase).contains(FavoriteDatabasesStorage.syncId(for: removed)))
        #expect(tracker.tombstonedIds(for: .favoriteDatabase).isEmpty)
    }

    @Test("Column layouts removed on another Mac are removed here, a digest-named one included")
    func remoteColumnLayoutDeletionsAreApplied() async {
        let connection = addConnection()
        let short = layoutKey(connection.id)
        let long = layoutKey(connection.id, table: String(repeating: "t", count: 300))
        let kept = layoutKey(connection.id, table: "customers")
        [short, long, kept].forEach(saveLayout)
        let longRecordID = Self.recordID(.settings, FileColumnLayoutPersister.syncCategory(for: long.storageKey))
        #expect(longRecordID.recordName.contains(SyncRecordName.digestPrefix))
        let coordinator = environment.makeCoordinator(transport: ScriptedSyncTransport(zoneID: Self.zoneID))

        let acknowledged = await coordinator.applyPullResult(PullResult(
            changedRecords: [],
            deletedRecordIDs: [
                Self.recordID(.settings, FileColumnLayoutPersister.syncCategory(for: short.storageKey)),
                longRecordID
            ],
            newToken: nil
        ))

        #expect(acknowledged)
        #expect(environment.columnLayouts.load(for: short) == nil)
        #expect(environment.columnLayouts.load(for: long) == nil)
        #expect(environment.columnLayouts.load(for: kept) != nil)
        #expect(tracker.dirtyRecords(for: .settings) == [FileColumnLayoutPersister.syncCategory(for: kept.storageKey)])
        #expect(tracker.tombstonedIds(for: .settings).isEmpty)
    }

    @Test("Database favorite and column layout deletions from another Mac wait while their category is off")
    func remoteDeletionsFollowTheirCategory() async {
        let connection = addConnection()
        environment.favoriteDatabases.setFavorite(database: "shop", environment: .production, connectionId: connection.id)
        let key = layoutKey(connection.id)
        saveLayout(key)
        var settings = SyncSettings.default
        settings.syncDatabaseFavorites = false
        settings.syncSettings = false
        AppSettingsStorage(userDefaults: environment.defaults).saveSync(settings)
        let entry = FavoriteDatabaseEntry(connectionId: connection.id, database: "shop", environment: .production)
        let coordinator = environment.makeCoordinator(transport: ScriptedSyncTransport(zoneID: Self.zoneID))

        let acknowledged = await coordinator.applyPullResult(PullResult(
            changedRecords: [],
            deletedRecordIDs: [
                Self.recordID(.favoriteDatabase, FavoriteDatabasesStorage.syncId(for: entry)),
                Self.recordID(.settings, FileColumnLayoutPersister.syncCategory(for: key.storageKey))
            ],
            newToken: nil
        ))

        #expect(acknowledged)
        #expect(environment.favoriteDatabases.favorites(for: connection.id).count == 1)
        #expect(environment.columnLayouts.load(for: key) != nil)
    }

    // MARK: - Owners

    @Test("Every store that deletes something belonging to a connection records the connection as its owner")
    func dependentStoresRecordTheirOwner() async {
        let connection = addConnection()
        let dependents = await addDependents(of: connection.id)
        let second = SQLFavorite(name: "Second", query: "SELECT 2", connectionId: connection.id)
        let global = SQLFavorite(name: "Global", query: "SELECT 3")
        #expect(await environment.favorites.addFavorite(second))
        #expect(await environment.favorites.addFavorite(global))
        environment.favoriteTables.addFavorite(name: "a|b", schema: "public", database: "shop", connectionId: connection.id)
        let piped = FavoriteTablesStorage.FavoriteEntry(
            connectionId: connection.id, database: "shop", schema: "public", name: "a|b"
        )

        environment.favoriteTables.removeFavorites(for: connection.id)
        environment.favoriteDatabases.removeFavorites(for: connection.id)
        #expect(await environment.favorites.deleteFavorite(id: dependents.savedQuery.id))
        await environment.favorites.deleteFavorites(ids: [second.id, global.id])
        #expect(await environment.favorites.deleteFolder(id: dependents.folder.id))
        environment.columnLayouts.clear(for: dependents.layoutKey)

        let owners = { (type: SyncRecordType) in
            Dictionary(uniqueKeysWithValues: metadata.tombstones(for: type).map { ($0.id, $0.owner) })
        }
        var tableFavoriteIds = [dependents.tableFavoriteId, FavoriteTablesStorage.syncId(for: piped)]
        tableFavoriteIds += [FavoriteTablesStorage.legacyAlias(of: piped)].compactMap { $0 }
        #expect(owners(.tableFavorite) == Dictionary(uniqueKeysWithValues: tableFavoriteIds.map { ($0, connection.id) }))
        #expect(owners(.favoriteDatabase) == [dependents.databaseFavoriteId: connection.id])
        #expect(owners(.favorite) == [
            dependents.savedQuery.id.uuidString: connection.id,
            second.id.uuidString: connection.id,
            global.id.uuidString: UUID?.none
        ])
        #expect(owners(.favoriteFolder) == [dependents.folder.id.uuidString: connection.id])
        #expect(owners(.settings) == [dependents.layoutCategory: connection.id])
    }
}
