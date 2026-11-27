import CloudKit
import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

@MainActor
struct SyncSavedQueriesRefillTests {
    private static let zoneID = SyncTestEnvironment.zoneID

    private let environment: SyncTestEnvironment

    init() throws {
        environment = try SyncTestEnvironment(label: "sync-saved-queries-refill")
        var settings = SyncSettings.default
        settings.enabled = true
        AppSettingsStorage(userDefaults: environment.defaults).saveSync(settings)
        _ = environment.metadata.adoptReadableRecordTypes(SyncCoordinator.readableContent(for: settings))
    }

    @Test("A damaged saved queries store is refilled by a full fetch although a sync token is stored")
    func damagedStoreIsRefilledByAFullFetch() async throws {
        let favorite = SQLFavorite(name: "Revenue", query: "SELECT 1")
        let token = try Self.makeChangeToken()
        environment.metadata.saveToken(token)
        let server = RefillZoneServer(zoneID: Self.zoneID, records: [Self.record(favorite)], token: token)
        let damaged = try damagedFavorites()
        let coordinator = makeCoordinator(transport: server, favorites: damaged)

        #expect(await coordinator.runSyncCycle() == nil)

        #expect(await server.pulls == [.full])
        #expect(await damaged.fetchFavorite(id: favorite.id)?.name == "Revenue")
        #expect(await damaged.isAwaitingSyncRefill() == false)

        #expect(await coordinator.runSyncCycle() == nil)
        #expect(await server.pulls == [.full, .delta])
    }

    @Test("A saved query deleted and then edited again before the damage comes back instead of being deleted everywhere")
    func restoredSavedQuerySurvivesTheRefill() async throws {
        let restored = SQLFavorite(name: "Revenue", query: "SELECT 1")
        let id = restored.id.uuidString
        environment.tracker.markDeleted(.favorite, id: id)
        environment.tracker.markDirty(.favorite, id: id)
        let token = try Self.makeChangeToken()
        environment.metadata.saveToken(token)
        let server = RefillZoneServer(zoneID: Self.zoneID, records: [Self.record(restored)], token: token)
        let damaged = try damagedFavorites()
        let coordinator = makeCoordinator(transport: server, favorites: damaged)

        #expect(await coordinator.runSyncCycle() == nil)
        #expect(await coordinator.runSyncCycle() == nil)

        #expect(await server.pushedDeletionNames.isEmpty)
        #expect(await damaged.fetchFavorite(id: restored.id)?.name == "Revenue")
    }

    @Test("A full fetch that left a saved query unread keeps the refill going until a fetch delivers it")
    func unreadSavedQueryKeepsTheRefill() async throws {
        let delivered = SQLFavorite(name: "Revenue", query: "SELECT 1")
        let late = SQLFavorite(name: "Churn", query: "SELECT 2")
        let token = try Self.makeChangeToken()
        environment.metadata.saveToken(token)
        let server = RefillZoneServer(
            zoneID: Self.zoneID,
            records: [Self.record(delivered)],
            token: token,
            unread: [Self.record(late).recordID]
        )
        let damaged = try damagedFavorites()
        let coordinator = makeCoordinator(transport: server, favorites: damaged)

        #expect(await coordinator.runSyncCycle() == nil)
        #expect(await damaged.isAwaitingSyncRefill())

        await server.serve([Self.record(delivered), Self.record(late)], unread: [])
        #expect(await coordinator.runSyncCycle() == nil)

        #expect(await server.pulls == [.full, .full])
        #expect(await damaged.isAwaitingSyncRefill() == false)
        #expect(await damaged.fetchFavorite(id: late.id)?.name == "Churn")
    }

    private func damagedFavorites() throws -> SQLFavoriteManager {
        let url = environment.directory.appendingPathComponent("damaged-sql_favorites.db")
        try Data(repeating: 0x2A, count: 4_096).write(to: url)
        return SQLFavoriteManager(
            storage: SQLFavoriteStorage(databaseURL: url, removeDatabaseOnDeinit: true),
            syncTracker: environment.tracker
        )
    }

    private func makeCoordinator(transport: any SyncTransport, favorites: SQLFavoriteManager) -> SyncCoordinator {
        let base = environment.makeCoordinator(transport: ScriptedSyncTransport(zoneID: Self.zoneID), favorites: favorites)
        return SyncCoordinator(
            services: base.services,
            recordCache: environment.recordCache,
            transport: transport,
            makeNetworkMonitor: { nil },
            columnLayouts: environment.columnLayouts,
            licenseGate: { nil },
            pushRegistrar: .inert
        )
    }

    private static func record(_ favorite: SQLFavorite) -> CKRecord {
        SyncRecordMapper.toCKRecord(sqlFavorite: favorite, in: zoneID)
    }

    private static func makeChangeToken() throws -> CKServerChangeToken {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.setClassName("CKServerChangeToken", for: RefillChangeTokenArchive.self)
        archiver.encode(RefillChangeTokenArchive(), forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: archiver.encodedData)
        return try #require(token)
    }
}

// Serves every record on a full fetch and nothing on a delta, and records what was asked and pushed.
private actor RefillZoneServer: SyncTransport {
    enum Pull: Equatable {
        case full
        case delta
    }

    let currentZoneID: CKRecordZone.ID
    private var records: [CKRecord]
    private var unread: [CKRecord.ID]
    private let token: CKServerChangeToken
    private(set) var pulls: [Pull] = []
    private(set) var pushedDeletionNames: [String] = []

    init(zoneID: CKRecordZone.ID, records: [CKRecord], token: CKServerChangeToken, unread: [CKRecord.ID] = []) {
        currentZoneID = zoneID
        self.records = records
        self.token = token
        self.unread = unread
    }

    func serve(_ records: [CKRecord], unread: [CKRecord.ID]) {
        self.records = records
        self.unread = unread
    }

    func accountStatus() async throws -> CKAccountStatus {
        .available
    }

    func currentAccountId() async throws -> String {
        ScriptedSyncTransport.accountId
    }

    func ensureZoneExists() async throws {}

    func saveSubscription() async throws {}

    func push(records: [CKRecord], deletions: [CKRecord.ID]) async throws -> PushOutcome {
        var outcome = PushOutcome()
        for record in records {
            outcome.recordSave(record)
        }
        for recordID in deletions {
            pushedDeletionNames.append(recordID.recordName)
            outcome.recordDeletion(recordID)
        }
        return outcome
    }

    func fetch(recordIDs: [CKRecord.ID]) async throws -> [CKRecord.ID: CKRecord] {
        [:]
    }

    func pull(since token: CKServerChangeToken?) async throws -> PullResult {
        guard token != nil else {
            pulls.append(.full)
            return PullResult(changedRecords: records, deletedRecordIDs: [], newToken: self.token, unreadRecordIDs: unread)
        }
        pulls.append(.delta)
        return PullResult(changedRecords: [], deletedRecordIDs: [], newToken: self.token)
    }
}

@objc(SyncSavedQueriesRefillTestsChangeTokenArchive)
private final class RefillChangeTokenArchive: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    override init() {
        super.init()
    }

    required init?(coder: NSCoder) {
        super.init()
    }

    func encode(with coder: NSCoder) {}
}
