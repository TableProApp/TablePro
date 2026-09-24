import CloudKit
import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

@MainActor
@Suite("Sync coordinator push and pull cycle")
struct SyncCoordinatorEchoTests {
    private static let zoneID = CKRecordZone.ID(
        zoneName: CloudKitSyncEngine.zoneName,
        ownerName: CKCurrentUserDefaultName
    )

    private let unique = UUID().uuidString
    private let keychain = InMemoryKeychain()
    private let directory: URL
    private let defaults: UserDefaults
    private let metadata: SyncMetadataStorage
    private let tracker: SyncChangeTracker
    private let recordCache: SyncRecordCache
    private let connections: ConnectionStorage
    private let groups: GroupStorage
    private let tags: TagStorage
    private let favoriteDatabases: FavoriteDatabasesStorage
    private let columnLayouts: FileColumnLayoutPersister
    private let favorites: SQLFavoriteManager

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("sync-echo-\(unique)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = try #require(UserDefaults(suiteName: "com.TablePro.tests.SyncEcho.\(unique)"))
        metadata = SyncMetadataStorage(
            userDefaults: try #require(UserDefaults(suiteName: "com.TablePro.tests.SyncEcho.sync.\(unique)"))
        )
        tracker = SyncChangeTracker(metadataStorage: metadata)
        recordCache = SyncRecordCache(
            directory: directory.appendingPathComponent("SyncRecordCache", isDirectory: true),
            defaults: nil
        )
        let connectionStore = ConnectionStorage(
            fileURL: directory.appendingPathComponent("connections.json"),
            userDefaults: defaults,
            syncTracker: tracker,
            keychain: keychain,
            integrity: ConnectionStoreIntegrity(keySource: StoredIntegrityKeySource(store: keychain))
        )
        connections = connectionStore
        groups = GroupStorage(
            userDefaults: defaults,
            syncTracker: tracker,
            connectionStorage: connectionStore,
            appEvents: AppEvents()
        )
        tags = TagStorage(userDefaults: defaults, syncTracker: tracker, appEvents: AppEvents())
        favoriteDatabases = FavoriteDatabasesStorage(defaults: defaults, syncTracker: tracker)
        columnLayouts = FileColumnLayoutPersister(
            storageDirectory: directory.appendingPathComponent("ColumnLayout", isDirectory: true),
            defaults: defaults,
            syncTracker: tracker
        )
        favorites = SQLFavoriteManager(
            storage: SQLFavoriteStorage(
                databaseURL: directory.appendingPathComponent("sql_favorites.db"),
                removeDatabaseOnDeinit: true
            ),
            syncTracker: tracker
        )
    }

    @Test("A tag edited while its push is in flight keeps the edit, and a sibling's remote change still lands")
    func tagEditedDuringPushSurvivesItsEcho() async throws {
        let edited = ConnectionTag(name: "staging", color: .orange)
        let sibling = ConnectionTag(name: "qa", color: .blue)
        try tags.addTag(edited)
        try tags.addTag(sibling)
        var remoteSibling = sibling
        remoteSibling.name = "quality"
        let remoteSiblingRecord = SyncRecordMapper.toCKRecord(remoteSibling, in: Self.zoneID)
        let tagStorage = tags
        let transport = ScriptedSyncTransport(
            zoneID: Self.zoneID,
            duringPush: {
                let renamed = tagStorage.loadTags().map { tag -> ConnectionTag in
                    guard tag.id == edited.id else { return tag }
                    var changed = tag
                    changed.name = "stage"
                    return changed
                }
                tagStorage.saveTags(renamed)
            },
            pulled: { pushed in
                PullResult(
                    changedRecords: pushed.filter { $0.recordID != remoteSiblingRecord.recordID } + [remoteSiblingRecord],
                    deletedRecordIDs: [],
                    newToken: nil
                )
            }
        )

        let failure = await makeCoordinator(transport: transport).runSyncCycle()

        #expect(failure == nil)
        #expect(tags.tag(for: edited.id)?.name == "stage")
        #expect(tracker.dirtyRecords(for: .tag).contains(edited.id.uuidString))
        #expect(tags.tag(for: sibling.id)?.name == "quality")
        #expect(!tracker.dirtyRecords(for: .tag).contains(sibling.id.uuidString))
    }

    @Test("A saved query edited while its push is in flight keeps the edit and stays dirty")
    func savedQueryEditedDuringPushSurvivesItsEcho() async throws {
        let original = SQLFavorite(name: "Revenue", query: "SELECT 1")
        #expect(await favorites.addFavorite(original))
        var edited = original
        edited.query = "SELECT 2"
        let manager = favorites
        let transport = ScriptedSyncTransport(
            zoneID: Self.zoneID,
            duringPush: { _ = await manager.updateFavorite(edited) },
            pulled: { pushed in PullResult(changedRecords: pushed, deletedRecordIDs: [], newToken: nil) }
        )

        let failure = await makeCoordinator(transport: transport).runSyncCycle()

        #expect(failure == nil)
        #expect(await favorites.fetchFavorite(id: original.id)?.query == "SELECT 2")
        #expect(tracker.dirtyRecords(for: .favorite).contains(original.id.uuidString))
    }

    @Test("A record pushed and left alone is clean after the cycle")
    func untouchedPushedRecordIsClean() async throws {
        let tag = ConnectionTag(name: "staging")
        try tags.addTag(tag)
        let transport = ScriptedSyncTransport(
            zoneID: Self.zoneID,
            pulled: { pushed in PullResult(changedRecords: pushed, deletedRecordIDs: [], newToken: nil) }
        )

        let failure = await makeCoordinator(transport: transport).runSyncCycle()

        #expect(failure == nil)
        #expect(tracker.dirtyRecords(for: .tag).isEmpty)
        #expect(tags.tag(for: tag.id)?.name == "staging")
    }

    @Test("A pull with no push before it applies over a dirty tag as it always has")
    func pullWithoutPushApplies() async throws {
        let tag = ConnectionTag(name: "staging")
        try tags.addTag(tag)
        var remote = tag
        remote.name = "stage"

        let acknowledged = await makeCoordinator(transport: ScriptedSyncTransport(zoneID: Self.zoneID))
            .applyPullResult(
                PullResult(
                    changedRecords: [SyncRecordMapper.toCKRecord(remote, in: Self.zoneID)],
                    deletedRecordIDs: [],
                    newToken: nil
                )
            )

        #expect(acknowledged)
        #expect(tags.tag(for: tag.id)?.name == "stage")
    }

    @Test("A dirty tag the push could not save still takes the pull that follows")
    func rejectedRecordStillTakesPulls() async throws {
        let tag = ConnectionTag(name: "staging")
        try tags.addTag(tag)
        var remote = tag
        remote.name = "stage"
        let remoteRecord = SyncRecordMapper.toCKRecord(remote, in: Self.zoneID)
        let transport = ScriptedSyncTransport(
            zoneID: Self.zoneID,
            rejecting: [remoteRecord.recordID],
            pulled: { _ in PullResult(changedRecords: [remoteRecord], deletedRecordIDs: [], newToken: nil) }
        )

        let failure = await makeCoordinator(transport: transport).runSyncCycle()

        #expect(failure != nil)
        #expect(tags.tag(for: tag.id)?.name == "stage")
        #expect(tracker.dirtyRecords(for: .tag).contains(tag.id.uuidString))
    }

    @Test("A local-only connection's database favorite, never pushed, still takes a pull")
    func neverPushedDatabaseFavoriteTakesPulls() async throws {
        var connection = TestFixtures.makeConnection()
        connection.localOnly = true
        connections.addConnection(connection)
        favoriteDatabases.setFavorite(database: "orders", environment: .development, connectionId: connection.id)
        let remote = FavoriteDatabaseEntry(connectionId: connection.id, database: "orders", environment: .production)
        let remoteRecord = SyncRecordMapper.toCKRecord(favoriteDatabase: remote, in: Self.zoneID)
        let transport = ScriptedSyncTransport(
            zoneID: Self.zoneID,
            pulled: { _ in PullResult(changedRecords: [remoteRecord], deletedRecordIDs: [], newToken: nil) }
        )

        let failure = await makeCoordinator(transport: transport).runSyncCycle()

        #expect(failure == nil)
        #expect(await transport.pushedRecords.isEmpty)
        #expect(favoriteDatabases.favorites(for: connection.id).map(\.environment) == [.production])
    }

    @Test("A tag and a group deleted elsewhere take their local marks with them")
    func remoteDeletionsDiscardMarks() async throws {
        let tag = ConnectionTag(name: "staging")
        try tags.addTag(tag)
        let group = ConnectionGroup(name: "Clients")
        try groups.addGroup(group)
        let deletions = [
            SyncRecordMapper.recordID(type: .tag, id: tag.id.uuidString, in: Self.zoneID),
            SyncRecordMapper.recordID(type: .group, id: group.id.uuidString, in: Self.zoneID)
        ]

        let acknowledged = await makeCoordinator(transport: ScriptedSyncTransport(zoneID: Self.zoneID))
            .applyPullResult(PullResult(changedRecords: [], deletedRecordIDs: deletions, newToken: nil))

        #expect(acknowledged)
        #expect(tags.tag(for: tag.id) == nil)
        #expect(groups.group(for: group.id) == nil)
        #expect(!tracker.dirtyRecords(for: .tag).contains(tag.id.uuidString))
        #expect(!tracker.dirtyRecords(for: .group).contains(group.id.uuidString))
        #expect(metadata.tombstones(for: .tag).isEmpty)
        #expect(metadata.tombstones(for: .group).isEmpty)
    }

    @Test("A connection edited during its push merges its echo and keeps both edits")
    func connectionEchoMergesBothEdits() async throws {
        var connection = TestFixtures.makeConnection(name: "Primary")
        connection.port = 5_432
        connections.addConnection(connection)
        let connectionId = connection.id
        var remote = connection
        remote.port = 6_543
        let remoteRecord = SyncRecordMapper.toCKRecord(remote, in: Self.zoneID)
        let store = connections
        let transport = ScriptedSyncTransport(
            zoneID: Self.zoneID,
            duringPush: { _ = store.mutateConnections(ids: [connectionId]) { $0.name = "Renamed" } },
            pulled: { _ in PullResult(changedRecords: [remoteRecord], deletedRecordIDs: [], newToken: nil) }
        )

        let failure = await makeCoordinator(transport: transport).runSyncCycle()

        let merged = try #require(connections.loadConnection(id: connectionId))
        #expect(failure == nil)
        #expect(merged.name == "Renamed")
        #expect(merged.port == 6_543)
        #expect(tracker.dirtyRecords(for: .connection).contains(connectionId.uuidString))
    }

    @Test("A record held back as this Mac's own echo is not cached as the server's copy")
    func withheldEchoIsNotCached() async throws {
        let tag = ConnectionTag(name: "staging")
        try tags.addTag(tag)
        var serverCopy = tag
        serverCopy.name = "server"
        let serverRecord = SyncRecordMapper.toCKRecord(serverCopy, in: Self.zoneID)
        let tagStorage = tags
        let transport = ScriptedSyncTransport(
            zoneID: Self.zoneID,
            duringPush: { Self.rename(tag.id, to: "stage", in: tagStorage) },
            pulled: { _ in PullResult(changedRecords: [serverRecord], deletedRecordIDs: [], newToken: nil) }
        )

        let failure = await makeCoordinator(transport: transport).runSyncCycle()

        let cached = try #require(recordCache.record(for: serverRecord.recordID))
        #expect(failure == nil)
        #expect(tags.tag(for: tag.id)?.name == "stage")
        #expect(SyncRecordMapper.toTag(cached)?.name == "staging")
    }

    @Test("A notification pull that arrives mid-push waits for the cycle and applies no echo")
    func notificationDuringPushIsDeferred() async throws {
        let tag = ConnectionTag(name: "staging")
        try tags.addTag(tag)
        let tagStorage = tags
        let box = CoordinatorBox()
        let transport = ScriptedSyncTransport(
            zoneID: Self.zoneID,
            duringPush: {
                Self.rename(tag.id, to: "stage", in: tagStorage)
                await box.coordinator?.pullForRemoteNotification()
            },
            pulled: { pushed in PullResult(changedRecords: pushed, deletedRecordIDs: [], newToken: nil) }
        )
        let coordinator = makeCoordinator(transport: transport)
        box.coordinator = coordinator

        let failure = await coordinator.runSyncCycle()

        #expect(failure == nil)
        #expect(tags.tag(for: tag.id)?.name == "stage")
        #expect(tracker.dirtyRecords(for: .tag).contains(tag.id.uuidString))
        #expect(await transport.pullCount == 2)
    }

    @Test("A push cut short after saving some records still holds back their echoes and clears the rest")
    func interruptedPushStillGuardsEchoes() async throws {
        let tag = ConnectionTag(name: "staging")
        try tags.addTag(tag)
        let tagStorage = tags
        let transport = ScriptedSyncTransport(
            zoneID: Self.zoneID,
            interruption: CKError(.networkFailure),
            duringPush: { Self.rename(tag.id, to: "stage", in: tagStorage) },
            pulled: { pushed in PullResult(changedRecords: pushed, deletedRecordIDs: [], newToken: nil) }
        )

        let failure = await makeCoordinator(transport: transport).runSyncCycle()

        #expect(failure == .networkUnavailable)
        #expect(tags.tag(for: tag.id)?.name == "stage")
        #expect(tracker.dirtyRecords(for: .tag) == [tag.id.uuidString])
    }

    @Test("A dirty mark on a local-only connection is dropped rather than carried forever")
    func localOnlyConnectionMarkIsDropped() async {
        var connection = TestFixtures.makeConnection()
        connection.localOnly = true
        connections.addConnection(connection)
        tracker.markDirty(.connection, id: connection.id.uuidString)
        let transport = ScriptedSyncTransport(zoneID: Self.zoneID)

        let failure = await makeCoordinator(transport: transport).runSyncCycle()

        #expect(failure == nil)
        #expect(await transport.pushedRecords.isEmpty)
        #expect(!tracker.dirtyRecords(for: .connection).contains(connection.id.uuidString))
    }

    @Test("Marks with no record behind them are dropped once their stores read cleanly")
    func unreachableMarksAreDropped() async {
        let missingTag = UUID().uuidString
        let missingGroup = UUID().uuidString
        let missingConnection = UUID().uuidString
        let missingQuery = UUID().uuidString
        tracker.markDirty(.tag, id: missingTag)
        tracker.markDirty(.group, id: missingGroup)
        tracker.markDirty(.connection, id: missingConnection)
        tracker.markDirty(.favorite, id: missingQuery)

        let failure = await makeCoordinator(transport: ScriptedSyncTransport(zoneID: Self.zoneID)).runSyncCycle()

        #expect(failure == nil)
        #expect(!tracker.dirtyRecords(for: .tag).contains(missingTag))
        #expect(!tracker.dirtyRecords(for: .group).contains(missingGroup))
        #expect(!tracker.dirtyRecords(for: .connection).contains(missingConnection))
        #expect(!tracker.dirtyRecords(for: .favorite).contains(missingQuery))
    }

    @Test("A saved query mark survives a store that cannot be read")
    func unreadableStoreKeepsTheMark() async throws {
        let url = directory.appendingPathComponent("not-a-database.db")
        try Data(repeating: 0x2A, count: 4_096).write(to: url)
        let broken = SQLFavoriteManager(
            storage: SQLFavoriteStorage(databaseURL: url, removeDatabaseOnDeinit: true),
            syncTracker: tracker
        )
        let id = UUID().uuidString
        tracker.markDirty(.favorite, id: id)

        _ = await makeCoordinator(transport: ScriptedSyncTransport(zoneID: Self.zoneID), favorites: broken)
            .runSyncCycle()

        #expect(tracker.dirtyRecords(for: .favorite).contains(id))
    }

    @Test("A saved query edited while a pull applies keeps the edit and its mark, whichever runs first")
    func localEditRacingARemoteApplyIsKept() async throws {
        let original = SQLFavorite(name: "Revenue", query: "SELECT 1")
        #expect(await favorites.addFavorite(original))
        let echoGuard = SyncEchoGuard(
            snapshot: tracker.editSnapshot(),
            savedRecords: [
                SyncRecordMapper.recordID(type: .favorite, id: original.id.uuidString, in: Self.zoneID):
                    SyncRecordIdentity(type: .favorite, id: original.id.uuidString)
            ]
        )
        var edited = original
        edited.query = "SELECT 2"

        let manager = favorites
        async let edit = manager.updateFavorite(edited)
        async let apply = manager.applyRemote(RemoteSQLFavoriteBatch(favorites: [original]), echoGuard: echoGuard)
        let (editSaved, applied) = await (edit, apply)

        #expect(editSaved)
        #expect(applied != .failed)
        #expect(await favorites.fetchFavorite(id: original.id)?.query == "SELECT 2")
        #expect(tracker.dirtyRecords(for: .favorite).contains(original.id.uuidString))
    }

    @Test("A pull's copy of a saved query edited since the push is withheld")
    func remoteApplyAfterALocalEditIsWithheld() async throws {
        let original = SQLFavorite(name: "Revenue", query: "SELECT 1")
        #expect(await favorites.addFavorite(original))
        let echoGuard = SyncEchoGuard(
            snapshot: tracker.editSnapshot(),
            savedRecords: [
                SyncRecordMapper.recordID(type: .favorite, id: original.id.uuidString, in: Self.zoneID):
                    SyncRecordIdentity(type: .favorite, id: original.id.uuidString)
            ]
        )
        var edited = original
        edited.query = "SELECT 2"
        #expect(await favorites.updateFavorite(edited))

        let outcome = await favorites.applyRemote(RemoteSQLFavoriteBatch(favorites: [original]), echoGuard: echoGuard)

        #expect(outcome == .skipped)
        #expect(await favorites.fetchFavorite(id: original.id)?.query == "SELECT 2")
        #expect(tracker.dirtyRecords(for: .favorite).contains(original.id.uuidString))
    }

    private static func rename(_ id: UUID, to name: String, in storage: TagStorage) {
        let renamed = storage.loadTags().map { tag -> ConnectionTag in
            guard tag.id == id else { return tag }
            var changed = tag
            changed.name = name
            return changed
        }
        storage.saveTags(renamed)
    }

    private func makeCoordinator(
        transport: ScriptedSyncTransport,
        favorites: SQLFavoriteManager? = nil
    ) -> SyncCoordinator {
        let live = AppServices.live
        let services = AppServices(
            appEvents: AppEvents(),
            appSettings: live.appSettings,
            appSettingsStorage: AppSettingsStorage(userDefaults: defaults),
            connectionStorage: connections,
            databaseManager: live.databaseManager,
            pluginManager: live.pluginManager,
            schemaService: live.schemaService,
            schemaRefreshService: live.schemaRefreshService,
            schemaProviderRegistry: live.schemaProviderRegistry,
            catalogChangeService: live.catalogChangeService,
            sqlFavoriteManager: favorites ?? self.favorites,
            favoriteTablesStorage: FavoriteTablesStorage(userDefaults: defaults, syncTracker: tracker),
            favoriteDatabasesStorage: favoriteDatabases,
            aiChatStorage: live.aiChatStorage,
            aiKeyStorage: live.aiKeyStorage,
            aiAccessApprovals: live.aiAccessApprovals,
            groupStorage: groups,
            tagStorage: tags,
            sshProfileStorage: SSHProfileStorage(
                userDefaults: defaults,
                keychain: keychain,
                syncTracker: tracker,
                connectionStorage: connections
            ),
            credentialProfileStorage: CredentialProfileStorage(
                fileURL: directory.appendingPathComponent("credentialProfiles.json"),
                keychain: keychain,
                syncTracker: tracker,
                connectionStorage: connections,
                integrity: ConnectionStoreIntegrity(keySource: StoredIntegrityKeySource(store: keychain))
            ),
            licenseManager: live.licenseManager,
            syncMetadataStorage: metadata,
            favoritesExpansionState: live.favoritesExpansionState,
            linkedFolderWatcher: live.linkedFolderWatcher,
            queryHistoryManager: live.queryHistoryManager,
            dateFormattingService: live.dateFormattingService,
            copilotService: live.copilotService,
            mcpServerManager: live.mcpServerManager,
            syncTracker: tracker,
            themeEngine: live.themeEngine,
            welcomeRouter: live.welcomeRouter
        )
        return SyncCoordinator(
            services: services,
            recordCache: recordCache,
            transport: transport,
            columnLayouts: columnLayouts
        )
    }
}

@MainActor
private final class CoordinatorBox {
    var coordinator: SyncCoordinator?
}

private actor ScriptedSyncTransport: SyncTransport {
    let currentZoneID: CKRecordZone.ID
    private let rejectedRecordIDs: Set<CKRecord.ID>
    private let interruption: (any Error)?
    private let duringPush: @MainActor @Sendable () async -> Void
    private let pulled: @Sendable ([CKRecord]) -> PullResult
    private(set) var pushedRecords: [CKRecord] = []
    private(set) var pullCount = 0

    init(
        zoneID: CKRecordZone.ID,
        rejecting rejectedRecordIDs: Set<CKRecord.ID> = [],
        interruption: (any Error)? = nil,
        duringPush: @escaping @MainActor @Sendable () async -> Void = {},
        pulled: @escaping @Sendable ([CKRecord]) -> PullResult = { _ in
            PullResult(changedRecords: [], deletedRecordIDs: [], newToken: nil)
        }
    ) {
        self.currentZoneID = zoneID
        self.rejectedRecordIDs = rejectedRecordIDs
        self.interruption = interruption
        self.duringPush = duringPush
        self.pulled = pulled
    }

    func accountStatus() async throws -> CKAccountStatus {
        .available
    }

    func currentAccountId() async throws -> String {
        "tests"
    }

    func ensureZoneExists() async throws {}

    func push(records: [CKRecord], deletions: [CKRecord.ID]) async throws -> PushOutcome {
        pushedRecords.append(contentsOf: records)
        await duringPush()
        var outcome = PushOutcome()
        for record in records {
            guard rejectedRecordIDs.contains(record.recordID) else {
                outcome.recordSave(record)
                continue
            }
            outcome.recordFailure(
                SyncItemFailure(code: .serverRejectedRequest, serverRecord: nil, clientRecord: record, message: "Rejected"),
                for: record.recordID
            )
        }
        for recordID in deletions {
            outcome.recordDeletion(recordID)
        }
        if let interruption {
            throw SyncPushInterruption(completed: outcome, cause: interruption)
        }
        return outcome
    }

    func pull(since token: CKServerChangeToken?) async throws -> PullResult {
        pullCount += 1
        return pulled(pushedRecords)
    }
}
