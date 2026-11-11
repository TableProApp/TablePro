import CloudKit
import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

@MainActor
struct SyncFullFetchDeletionTests {
    private static let zoneID = SyncTestEnvironment.zoneID
    private static let createdAt = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private let environment: SyncTestEnvironment
    private let dates = CreationDates()

    init() throws {
        environment = try SyncTestEnvironment(label: "sync-full-fetch-deletion")
    }

    @Test("A saved query deleted elsewhere is removed when an expired token forces a full fetch")
    func expiredTokenFullFetchAppliesTheDeletion() async throws {
        let kept = SQLFavorite(name: "Churn", query: "SELECT 2")
        let deleted = SQLFavorite(name: "Revenue", query: "SELECT 1")
        let keptRecord = Self.record(kept)
        let deletedRecord = Self.record(deleted)
        dates.cached[keptRecord.recordID.recordName] = Self.createdAt
        dates.cached[deletedRecord.recordID.recordName] = Self.createdAt.addingTimeInterval(60)
        let settings = Self.syncSettings()
        AppSettingsStorage(userDefaults: environment.defaults).saveSync(settings)
        _ = environment.metadata.adoptReadableRecordTypes(SyncCoordinator.readableContent(for: settings))
        let server = ExpiringZoneServer(zoneID: Self.zoneID, records: [keptRecord, deletedRecord], token: try Self.makeChangeToken())
        let coordinator = makeCoordinator(transport: server)

        #expect(await coordinator.runSyncCycle() == nil)
        #expect(await environment.favorites.fetchFavorite(id: deleted.id) != nil)

        await server.serve([keptRecord])
        await server.expireToken()
        #expect(await coordinator.runSyncCycle() == nil)

        #expect(await server.pulls == [.full, .expired, .full])
        #expect(await environment.favorites.fetchFavorite(id: deleted.id) == nil)
        #expect(await environment.favorites.fetchFavorite(id: kept.id)?.name == "Churn")
    }

    @Test("A saved query this run pushed is kept when the full fetch after the push does not list it yet")
    func recordPushedThisRunSurvivesTheFullFetch() async throws {
        let kept = SQLFavorite(name: "Churn", query: "SELECT 2")
        let pushed = SQLFavorite(name: "Revenue", query: "SELECT 1")
        let keptRecord = Self.record(kept)
        let pushedName = Self.record(pushed).recordID.recordName
        dates.cached[keptRecord.recordID.recordName] = Self.createdAt
        dates.cached[pushedName] = Self.createdAt.addingTimeInterval(120)
        let settings = Self.syncSettings()
        AppSettingsStorage(userDefaults: environment.defaults).saveSync(settings)
        _ = environment.metadata.adoptReadableRecordTypes(SyncCoordinator.readableContent(for: settings))
        let server = ExpiringZoneServer(zoneID: Self.zoneID, records: [keptRecord], token: try Self.makeChangeToken())
        let coordinator = makeCoordinator(transport: server)
        #expect(await coordinator.runSyncCycle() == nil)

        #expect(await environment.favorites.addFavorite(pushed))
        await server.expireToken()
        #expect(await coordinator.runSyncCycle() == nil)

        let pushedNames = await server.pushedRecordNames
        #expect(pushedNames.contains(pushedName))
        #expect(await server.pulls == [.full, .expired, .full])
        #expect(!environment.tracker.dirtyRecords(for: .favorite).contains(pushed.id.uuidString))
        #expect(await environment.favorites.fetchFavorite(id: pushed.id) != nil)
        #expect(environment.recordCache.holdsRecord(named: pushedName))
    }

    @Test("A zone made again holds only newer records, so a record it lacks is not taken as deleted")
    func recreatedZoneDeletesNothing() async throws {
        let kept = SQLFavorite(name: "Churn", query: "SELECT 2")
        let notYetUploaded = SQLFavorite(name: "Revenue", query: "SELECT 1")
        let coordinator = try await seededCoordinator(with: [kept, notYetUploaded])
        let uploadedAgain = Self.record(kept)
        dates.served[ObjectIdentifier(uploadedAgain)] = Self.createdAt.addingTimeInterval(3_600)

        #expect(await coordinator.applyPullResult(Self.pull([uploadedAgain]), settings: Self.syncSettings(), isFullFetch: true))

        #expect(await environment.favorites.fetchFavorite(id: notYetUploaded.id) != nil)
        #expect(environment.recordCache.holdsRecord(named: Self.record(notYetUploaded).recordID.recordName))
    }

    @Test("A saved query edited here and missing from a full fetch is kept for its push")
    func editedRecordSurvivesTheFullFetch() async throws {
        let kept = SQLFavorite(name: "Churn", query: "SELECT 2")
        let edited = SQLFavorite(name: "Revenue", query: "SELECT 1")
        let coordinator = try await seededCoordinator(with: [kept, edited])
        environment.tracker.markDirty(.favorite, id: edited.id.uuidString)

        #expect(await coordinator.applyPullResult(Self.pull([Self.record(kept)]), settings: Self.syncSettings(), isFullFetch: true))

        #expect(await environment.favorites.fetchFavorite(id: edited.id) != nil)
    }

    @Test("A record a full fetch listed but could not read is kept, and the deletions the fetch proves still apply")
    func unreadRecordIsKeptAndDeletionsStillApply() async throws {
        let kept = SQLFavorite(name: "Churn", query: "SELECT 2")
        let unread = SQLFavorite(name: "Revenue", query: "SELECT 1")
        let deleted = SQLFavorite(name: "Retention", query: "SELECT 3")
        let coordinator = try await seededCoordinator(with: [kept, unread, deleted])
        let result = PullResult(
            changedRecords: [Self.record(kept)],
            deletedRecordIDs: [],
            newToken: nil,
            unreadRecordIDs: [Self.record(unread).recordID]
        )

        #expect(await coordinator.applyPullResult(result, settings: Self.syncSettings(), isFullFetch: true))

        #expect(await environment.favorites.fetchFavorite(id: kept.id) != nil)
        #expect(await environment.favorites.fetchFavorite(id: unread.id) != nil)
        #expect(await environment.favorites.fetchFavorite(id: deleted.id) == nil)
    }

    @Test("A delta is never read for what it does not list")
    func deltaDeletesNothing() async throws {
        let kept = SQLFavorite(name: "Churn", query: "SELECT 2")
        let other = SQLFavorite(name: "Revenue", query: "SELECT 1")
        let coordinator = try await seededCoordinator(with: [kept, other])

        #expect(await coordinator.applyPullResult(Self.pull([Self.record(kept)]), settings: Self.syncSettings()))

        #expect(await environment.favorites.fetchFavorite(id: other.id) != nil)
    }

    @Test("Only a cached copy created no earlier than the oldest fetched record is proven deleted")
    func proofNeedsACreationInsideTheFetchedZone() {
        let oldest = Self.createdAt
        let before = SyncFullFetchDeletions.Candidate(recordID: Self.recordID("before"), cachedCreation: oldest.addingTimeInterval(-1))
        let after = SyncFullFetchDeletions.Candidate(recordID: Self.recordID("after"), cachedCreation: oldest.addingTimeInterval(1))
        let undated = SyncFullFetchDeletions.Candidate(recordID: Self.recordID("undated"), cachedCreation: nil)
        let listed = SyncFullFetchDeletions.Candidate(recordID: Self.recordID("listed"), cachedCreation: oldest.addingTimeInterval(1))

        let proven = SyncFullFetchDeletions.proven(
            candidates: [before, after, undated, listed],
            fetchedNames: [Self.recordID("listed").recordName],
            fetchedCreations: [oldest.addingTimeInterval(5), oldest]
        )

        #expect(proven == [after.recordID])
    }

    @Test("A fetch with no dated record proves nothing")
    func emptyFetchProvesNothing() {
        let candidate = SyncFullFetchDeletions.Candidate(recordID: Self.recordID("gone"), cachedCreation: Self.createdAt)

        #expect(SyncFullFetchDeletions.proven(candidates: [candidate], fetchedNames: [], fetchedCreations: []).isEmpty)
    }

    private func seededCoordinator(with favorites: [SQLFavorite]) async throws -> SyncCoordinator {
        let coordinator = makeCoordinator(transport: ScriptedSyncTransport(zoneID: Self.zoneID))
        let records = favorites.map(Self.record)
        for (offset, record) in records.enumerated() {
            dates.cached[record.recordID.recordName] = Self.createdAt.addingTimeInterval(Double(offset * 60))
        }
        #expect(await coordinator.applyPullResult(Self.pull(records), settings: Self.syncSettings()))
        for favorite in favorites {
            #expect(await environment.favorites.fetchFavorite(id: favorite.id) != nil)
        }
        return coordinator
    }

    private func makeCoordinator(transport: any SyncTransport) -> SyncCoordinator {
        let base = environment.makeCoordinator(transport: ScriptedSyncTransport(zoneID: Self.zoneID))
        let dates = dates
        return SyncCoordinator(
            services: base.services,
            recordCache: environment.recordCache,
            transport: transport,
            makeNetworkMonitor: { nil },
            columnLayouts: environment.columnLayouts,
            licenseGate: { nil },
            recordCreationDate: { dates.date(for: $0) }
        )
    }

    private static func record(_ favorite: SQLFavorite) -> CKRecord {
        SyncRecordMapper.toCKRecord(sqlFavorite: favorite, in: zoneID)
    }

    private static func recordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    private static func pull(_ records: [CKRecord]) -> PullResult {
        PullResult(changedRecords: records, deletedRecordIDs: [], newToken: nil)
    }

    private static func syncSettings() -> SyncSettings {
        var settings = SyncSettings.default
        settings.enabled = true
        return settings
    }

    private static func makeChangeToken() throws -> CKServerChangeToken {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.setClassName("CKServerChangeToken", for: FullFetchChangeTokenArchive.self)
        archiver.encode(FullFetchChangeTokenArchive(), forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: archiver.encodedData)
        return try #require(token)
    }
}

// The creation time CloudKit stamps on a saved record, which a record built in a test does not carry.
@MainActor
private final class CreationDates {
    var cached: [String: Date] = [:]
    var served: [ObjectIdentifier: Date] = [:]

    func date(for record: CKRecord) -> Date? {
        served[ObjectIdentifier(record)] ?? cached[record.recordID.recordName]
    }
}

// Answers the stored token with an expiry once told to, as CloudKit does for a token it no longer keeps.
private actor ExpiringZoneServer: SyncTransport {
    enum Pull: Equatable {
        case full
        case delta
        case expired
    }

    let currentZoneID: CKRecordZone.ID
    private var records: [CKRecord]
    private let token: CKServerChangeToken
    private var tokenExpired = false
    private(set) var pulls: [Pull] = []
    private(set) var pushedRecordNames: [String] = []

    init(zoneID: CKRecordZone.ID, records: [CKRecord], token: CKServerChangeToken) {
        currentZoneID = zoneID
        self.records = records
        self.token = token
    }

    func serve(_ records: [CKRecord]) {
        self.records = records
    }

    func expireToken() {
        tokenExpired = true
    }

    func accountStatus() async throws -> CKAccountStatus {
        .available
    }

    func currentAccountId() async throws -> String {
        ScriptedSyncTransport.accountId
    }

    func ensureZoneExists() async throws {}

    // Saves without listing the record in the next fetch, as a fetch that lags the save would.
    func push(records: [CKRecord], deletions: [CKRecord.ID]) async throws -> PushOutcome {
        var outcome = PushOutcome()
        for record in records {
            pushedRecordNames.append(record.recordID.recordName)
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
        guard token != nil else {
            pulls.append(.full)
            tokenExpired = false
            return PullResult(changedRecords: records, deletedRecordIDs: [], newToken: self.token)
        }
        guard !tokenExpired else {
            pulls.append(.expired)
            throw CKError(.changeTokenExpired)
        }
        pulls.append(.delta)
        return PullResult(changedRecords: [], deletedRecordIDs: [], newToken: self.token)
    }
}

@objc(SyncFullFetchDeletionTestsChangeTokenArchive)
private final class FullFetchChangeTokenArchive: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    override init() {
        super.init()
    }

    required init?(coder: NSCoder) {
        super.init()
    }

    func encode(with coder: NSCoder) {}
}
