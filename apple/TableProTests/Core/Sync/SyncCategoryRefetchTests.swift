import CloudKit
import Foundation
@testable import TablePro
import TableProSyncTransport
import TableProTestSupport
import Testing

@MainActor
struct SyncCategoryRefetchTests {
    private let environment: SyncTestEnvironment

    init() throws {
        environment = try SyncTestEnvironment(label: "sync-category-refetch")
    }

    @Test("Every category on reads what the build reads, and a category off drops its record types")
    func readableContentFollowsTheCategories() {
        var settings = SyncSettings.default
        #expect(SyncCoordinator.readableContent(for: settings) == SyncCoordinator.readableContent)

        settings.syncSQLFavorites = false
        settings.syncSettings = false
        let content = SyncCoordinator.readableContent(for: settings)

        #expect(!content.contains(SyncRecordType.favorite.rawValue))
        #expect(!content.contains(SyncRecordType.favoriteFolder.rawValue))
        #expect(!content.contains(SyncRecordType.settings.rawValue))
        #expect(!content.contains(SyncCoordinator.themeContentKind))
        #expect(!content.contains(SyncCoordinator.formatterContentKind))
        #expect(!content.contains(SyncCoordinator.valueColorsContentKind))
        #expect(content.contains(SyncRecordType.connection.rawValue))
    }

    @Test("A Mac upgraded from a build that skipped value colors records fetches the zone once")
    func upgradeRefetchesSkippedValueColorsRecords() throws {
        let pool = EphemeralDefaultsPool()
        let metadata = SyncMetadataStorage(userDefaults: try pool.make().defaults)
        var older = SyncCoordinator.readableContent
        older.remove(SyncCoordinator.valueColorsContentKind)
        _ = metadata.adoptReadableRecordTypes(older)

        #expect(SyncCoordinator.readableContent(for: .default).contains(SyncCoordinator.valueColorsContentKind))
        #expect(metadata.adoptReadableRecordTypes(SyncCoordinator.readableContent))
        #expect(!metadata.adoptReadableRecordTypes(SyncCoordinator.readableContent))
    }

    @Test("Turning Saved Queries on fetches the zone once and brings back a query saved elsewhere while it was off")
    func turningACategoryOnRefetches() async throws {
        let favorite = SQLFavorite(name: "Revenue", query: "SELECT 1")
        let server = ZoneServer(
            zoneID: SyncTestEnvironment.zoneID,
            records: [SyncRecordMapper.toCKRecord(sqlFavorite: favorite, in: SyncTestEnvironment.zoneID)],
            token: try Self.makeChangeToken()
        )
        _ = environment.metadata.adoptReadableRecordTypes(
            SyncCoordinator.readableContent(for: saveSync(savedQueries: false))
        )
        let coordinator = makeCoordinator(server: server)

        #expect(await coordinator.runSyncCycle() == nil)
        #expect(await environment.favorites.fetchFavorite(id: favorite.id) == nil)
        #expect(environment.metadata.loadToken() != nil)

        saveSync(savedQueries: true)
        #expect(await coordinator.runSyncCycle() == nil)
        #expect(await environment.favorites.fetchFavorite(id: favorite.id)?.name == "Revenue")

        #expect(await coordinator.runSyncCycle() == nil)
        let pulls = await server.pulls
        #expect(pulls == [.full, .full, .delta])
    }

    @Test("A saved query deleted elsewhere while Saved Queries was off is removed when the category turns back on")
    func deletionMadeWhileACategoryWasOffIsApplied() async throws {
        let deleted = SQLFavorite(name: "Revenue", query: "SELECT 1")
        let kept = SQLFavorite(name: "Churn", query: "SELECT 2")
        let zoneID = SyncTestEnvironment.zoneID
        let deletedRecord = SyncRecordMapper.toCKRecord(sqlFavorite: deleted, in: zoneID)
        let server = ZoneServer(
            zoneID: zoneID,
            records: [deletedRecord, SyncRecordMapper.toCKRecord(sqlFavorite: kept, in: zoneID)],
            token: try Self.makeChangeToken()
        )
        _ = environment.metadata.adoptReadableRecordTypes(
            SyncCoordinator.readableContent(for: saveSync(savedQueries: true))
        )
        let coordinator = makeCoordinator(server: server)

        #expect(await coordinator.runSyncCycle() == nil)
        #expect(await environment.favorites.fetchFavorite(id: deleted.id) != nil)

        saveSync(savedQueries: false)
        await server.delete(deletedRecord.recordID)
        #expect(await coordinator.runSyncCycle() == nil)
        #expect(await environment.favorites.fetchFavorite(id: deleted.id) != nil)

        saveSync(savedQueries: true)
        #expect(await coordinator.runSyncCycle() == nil)

        #expect(await environment.favorites.fetchFavorite(id: deleted.id) == nil)
        #expect(await environment.favorites.fetchFavorite(id: kept.id)?.name == "Churn")
        #expect(environment.metadata.deferredDeletions.isEmpty)
    }

    @Test("A saved query edited here after it was deleted elsewhere is kept when the category turns back on")
    func editedRecordSurvivesALateDeletion() async throws {
        let favorite = SQLFavorite(name: "Revenue", query: "SELECT 1")
        let record = SyncRecordMapper.toCKRecord(sqlFavorite: favorite, in: SyncTestEnvironment.zoneID)
        let coordinator = environment.makeCoordinator(transport: ScriptedSyncTransport(zoneID: SyncTestEnvironment.zoneID))
        let on = Self.syncSettings(savedQueries: true)
        let deletion = PullResult(changedRecords: [], deletedRecordIDs: [record.recordID], newToken: nil)

        #expect(await coordinator.applyPullResult(pull([record]), settings: on))
        #expect(await coordinator.applyPullResult(deletion, settings: Self.syncSettings(savedQueries: false)))
        environment.tracker.markDirty(.favorite, id: favorite.id.uuidString)
        #expect(await coordinator.applyPullResult(pull([]), settings: on))

        #expect(await environment.favorites.fetchFavorite(id: favorite.id) != nil)
        #expect(environment.metadata.deferredDeletions.isEmpty)
    }

    @Test("A saved query saved again on the server after its deletion is kept")
    func recordSavedAgainSurvivesALateDeletion() async throws {
        let favorite = SQLFavorite(name: "Revenue", query: "SELECT 1")
        let record = SyncRecordMapper.toCKRecord(sqlFavorite: favorite, in: SyncTestEnvironment.zoneID)
        let coordinator = environment.makeCoordinator(transport: ScriptedSyncTransport(zoneID: SyncTestEnvironment.zoneID))
        let on = Self.syncSettings(savedQueries: true)
        let deletion = PullResult(changedRecords: [], deletedRecordIDs: [record.recordID], newToken: nil)

        #expect(await coordinator.applyPullResult(pull([record]), settings: on))
        #expect(await coordinator.applyPullResult(deletion, settings: Self.syncSettings(savedQueries: false)))
        #expect(await coordinator.applyPullResult(pull([record]), settings: on))
        #expect(await coordinator.applyPullResult(pull([]), settings: on))

        #expect(await environment.favorites.fetchFavorite(id: favorite.id) != nil)
    }

    @Test("A credential profile deleted elsewhere while its category was off is never deleted late")
    func profileIsNeverDeletedLate() async throws {
        let recordID = SyncRecordMapper.recordID(type: .credentialProfile, id: UUID().uuidString, in: SyncTestEnvironment.zoneID)
        let coordinator = environment.makeCoordinator(transport: ScriptedSyncTransport(zoneID: SyncTestEnvironment.zoneID))
        var off = SyncSettings.default
        off.syncCredentialProfiles = false
        let deletion = PullResult(changedRecords: [], deletedRecordIDs: [recordID], newToken: nil)

        #expect(await coordinator.applyPullResult(deletion, settings: off))
        #expect(environment.metadata.deferredDeletions == [recordID.recordName])

        let due = coordinator.deferredDeletions(dueIn: pull([]), settings: .default, zoneID: SyncTestEnvironment.zoneID)
        #expect(due.due.isEmpty)
        #expect(due.settled == [recordID.recordName])
    }

    private func pull(_ records: [CKRecord]) -> PullResult {
        PullResult(changedRecords: records, deletedRecordIDs: [], newToken: nil)
    }

    @Test("Saved Queries off keeps the change token at launch and at the next launch")
    func categoryOffKeepsTheTokenAcrossRelaunch() async throws {
        #expect(environment.connections.saveConnections([DatabaseConnection(name: "Local")]))
        _ = environment.metadata.adoptReadableRecordTypes(SyncCoordinator.readableContent)
        let token = try Self.makeChangeToken()
        environment.metadata.saveToken(token)
        saveSync(savedQueries: false)
        let server = ZoneServer(zoneID: SyncTestEnvironment.zoneID, records: [], token: token)

        let coordinator = makeCoordinator(server: server)
        coordinator.start()
        #expect(environment.metadata.loadToken() != nil)
        try await waitUntil { await server.pulls.count >= 1 && coordinator.syncStatus != .syncing }

        let relaunched = makeCoordinator(server: server)
        relaunched.start()
        #expect(environment.metadata.loadToken() != nil)
        try await waitUntil { await server.pulls.count >= 2 && relaunched.syncStatus != .syncing }

        let pulls = await server.pulls
        #expect(!pulls.contains(.full))
        #expect(environment.metadata.loadToken() != nil)
    }

    @Test("Saved Queries turned off during a download keeps what that download brought, so turning it on loses nothing")
    func categoryTurnedOffMidPullKeepsTheBatch() async throws {
        let favorite = SQLFavorite(name: "Revenue", query: "SELECT 1")
        let token = try Self.makeChangeToken()
        _ = environment.metadata.adoptReadableRecordTypes(
            SyncCoordinator.readableContent(for: saveSync(savedQueries: true))
        )
        environment.metadata.saveToken(token)
        let turnedOff = Self.syncSettings(savedQueries: false)
        let storage = AppSettingsStorage(userDefaults: environment.defaults)
        let server = ZoneServer(
            zoneID: SyncTestEnvironment.zoneID,
            records: [],
            token: token,
            firstDelta: [SyncRecordMapper.toCKRecord(sqlFavorite: favorite, in: SyncTestEnvironment.zoneID)],
            duringPull: { storage.saveSync(turnedOff) }
        )
        let coordinator = makeCoordinator(server: server)

        #expect(await coordinator.runSyncCycle() == nil)
        saveSync(savedQueries: true)
        #expect(await coordinator.runSyncCycle() == nil)

        #expect(await environment.favorites.fetchFavorite(id: favorite.id)?.name == "Revenue")
    }

    @discardableResult
    private func saveSync(savedQueries: Bool) -> SyncSettings {
        let settings = Self.syncSettings(savedQueries: savedQueries)
        AppSettingsStorage(userDefaults: environment.defaults).saveSync(settings)
        return settings
    }

    private static func syncSettings(savedQueries: Bool) -> SyncSettings {
        var settings = SyncSettings.default
        settings.enabled = true
        settings.syncSQLFavorites = savedQueries
        return settings
    }

    private func makeCoordinator(server: ZoneServer) -> SyncCoordinator {
        let base = environment.makeCoordinator(transport: ScriptedSyncTransport(zoneID: SyncTestEnvironment.zoneID))
        let columnLayouts = environment.columnLayouts
        return SyncCoordinator(
            services: base.services,
            recordCache: environment.recordCache,
            transport: server,
            makeNetworkMonitor: { nil },
            columnLayouts: columnLayouts,
            licenseGate: { nil }
        )
    }

    private static func makeChangeToken() throws -> CKServerChangeToken {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.setClassName("CKServerChangeToken", for: CategoryRefetchChangeTokenArchive.self)
        archiver.encode(CategoryRefetchChangeTokenArchive(), forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: archiver.encodedData)
        return try #require(token)
    }
}

// A delta holds only what is new since the token, as CloudKit answers: `firstDelta` once, then nothing.
private actor ZoneServer: SyncTransport {
    enum Pull: Equatable {
        case full
        case delta
    }

    let currentZoneID: CKRecordZone.ID
    private var zoneRecords: [CKRecord]
    private var undeliveredDeletions: [CKRecord.ID] = []
    private let token: CKServerChangeToken
    private var firstDelta: [CKRecord]
    private let duringPull: @Sendable () -> Void
    private(set) var pulls: [Pull] = []

    init(
        zoneID: CKRecordZone.ID,
        records: [CKRecord],
        token: CKServerChangeToken,
        firstDelta: [CKRecord] = [],
        duringPull: @escaping @Sendable () -> Void = {}
    ) {
        currentZoneID = zoneID
        zoneRecords = records
        self.token = token
        self.firstDelta = firstDelta
        self.duringPull = duringPull
    }

    func delete(_ recordID: CKRecord.ID) {
        zoneRecords.removeAll { $0.recordID == recordID }
        undeliveredDeletions.append(recordID)
    }

    func accountStatus() async throws -> CKAccountStatus {
        .available
    }

    func currentAccountId() async throws -> String {
        ScriptedSyncTransport.accountId
    }

    func ensureZoneExists() async throws {}

    func push(records: [CKRecord], deletions: [CKRecord.ID]) async throws -> PushOutcome {
        var outcome = PushOutcome()
        for record in records {
            outcome.recordSave(record)
        }
        for recordID in deletions {
            outcome.recordDeletion(recordID)
        }
        return outcome
    }

    func fetch(recordIDs: [CKRecord.ID]) async throws -> [CKRecord.ID: CKRecord] {
        [:]
    }

    func pull(since token: CKServerChangeToken?) async throws -> PullResult {
        pulls.append(token == nil ? .full : .delta)
        duringPull()
        guard token != nil else {
            undeliveredDeletions = []
            return PullResult(changedRecords: zoneRecords, deletedRecordIDs: [], newToken: self.token)
        }
        defer {
            firstDelta = []
            undeliveredDeletions = []
        }
        return PullResult(changedRecords: firstDelta, deletedRecordIDs: undeliveredDeletions, newToken: self.token)
    }
}

@objc(SyncCategoryRefetchTestsChangeTokenArchive)
private final class CategoryRefetchChangeTokenArchive: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    override init() {
        super.init()
    }

    required init?(coder: NSCoder) {
        super.init()
    }

    func encode(with coder: NSCoder) {}
}
