import CloudKit
import Foundation
@testable import TablePro
import TableProImport
import TableProSyncTransport
import Testing

@MainActor
struct SyncUnreadableCopiesTests {
    private static let zoneID = SyncTestEnvironment.zoneID

    private let environment: SyncTestEnvironment
    private let kept = TestFixtures.makeConnection(name: "Kept")
    private let unreadableId = UUID()

    init() throws {
        environment = try SyncTestEnvironment(label: "sync-unreadable-copies")
    }

    private var fileURL: URL {
        environment.directory.appendingPathComponent("connections.json")
    }

    private var recordID: CKRecord.ID {
        SyncRecordMapper.recordID(type: .connection, id: unreadableId.uuidString, in: Self.zoneID)
    }

    private var recordName: String {
        SyncRecordType.connection.recordName(for: unreadableId.uuidString)
    }

    private var unreadableJSON: String {
        #"{"id":"\#(unreadableId.uuidString)","name":"From a newer build","shape":2}"#
    }

    // Written before anything saves, so the store adopts the file and keeps the record it cannot read.
    private func writeLibrary(standing: SyncStanding) throws {
        let stored = try String(decoding: JSONEncoder().encode(StoredConnection(from: kept)), as: UTF8.self)
        try Data("[\(stored),\(unreadableJSON)]".utf8).write(to: fileURL)
        switch standing {
        case .syncs:
            environment.metadata.recordConnectionStanding(syncing: [unreadableId], keptOff: [], unreadable: [])
        case .keptOff:
            environment.metadata.recordConnectionStanding(syncing: [], keptOff: [unreadableId], unreadable: [])
        case .unknown:
            break
        }
        environment.connections.invalidateCache()
        #expect(environment.connections.unreadableConnectionIds == [unreadableId])
    }

    private func rows() throws -> [NSDictionary] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [NSDictionary])
    }

    private func unreadableRow() throws -> NSDictionary? {
        try rows().first { $0["id"] as? String == unreadableId.uuidString }
    }

    private var original: NSDictionary? {
        try? JSONSerialization.jsonObject(with: Data(unreadableJSON.utf8)) as? NSDictionary
    }

    private func pull(changed: [CKRecord] = [], deleted: [CKRecord.ID] = []) -> PullResult {
        PullResult(changedRecords: changed, deletedRecordIDs: deleted, newToken: nil)
    }

    private func remoteRecord(named name: String) -> CKRecord {
        SyncRecordMapper.toCKRecord(TestFixtures.makeConnection(id: unreadableId, name: name), in: Self.zoneID)
    }

    @Test("A deletion from iCloud removes a connection this Mac cannot read when its standing says it syncs")
    func deletionRemovesAnUnreadableSyncedConnection() async throws {
        try writeLibrary(standing: .syncs)
        let coordinator = environment.makeCoordinator(transport: ScriptedSyncTransport(zoneID: Self.zoneID))

        #expect(await coordinator.applyPullResult(pull(deleted: [recordID]), settings: .default))

        #expect(try rows().compactMap { $0["id"] as? String } == [kept.id.uuidString])
        #expect(environment.connections.unreadableConnectionIds.isEmpty)
    }

    @Test("A Local only connection this Mac cannot read stays as it was when iCloud deletes its id")
    func deletionLeavesAnUnreadableLocalOnlyConnection() async throws {
        try writeLibrary(standing: .keptOff)
        let coordinator = environment.makeCoordinator(transport: ScriptedSyncTransport(zoneID: Self.zoneID))

        #expect(await coordinator.applyPullResult(pull(deleted: [recordID]), settings: .default))

        #expect(try unreadableRow() == original)
        #expect(environment.metadata.deletionsHeldForUnreadableCopies.isEmpty)
    }

    @Test("A deletion waits for a build that reads the copy when no standing was recorded")
    func deletionWaitsWithoutStanding() async throws {
        try writeLibrary(standing: .unknown)
        let coordinator = environment.makeCoordinator(transport: ScriptedSyncTransport(zoneID: Self.zoneID))

        #expect(await coordinator.applyPullResult(pull(deleted: [recordID]), settings: .default))

        #expect(try unreadableRow() == original)
        #expect(environment.metadata.deletionsHeldForUnreadableCopies == [recordName])
    }

    @Test("A change from iCloud never writes over a connection this Mac cannot read: it is held and kept out of the cache")
    func changeIsHeld() async throws {
        try writeLibrary(standing: .syncs)
        let coordinator = environment.makeCoordinator(transport: ScriptedSyncTransport(zoneID: Self.zoneID))

        #expect(await coordinator.applyPullResult(pull(changed: [remoteRecord(named: "Renamed elsewhere")]), settings: .default))

        #expect(try rows().count == 2)
        #expect(try unreadableRow() == original)
        #expect(environment.metadata.changesHeldForUnreadableCopies == [recordName])
        #expect(environment.recordCache.record(for: recordID) == nil)
    }

    @Test("A build that reads the copy back fetches the held record by id and takes the change")
    func readableCopyTakesTheHeldChange() async throws {
        try writeLibrary(standing: .syncs)
        let changed = remoteRecord(named: "Renamed elsewhere")
        let transport = ScriptedSyncTransport(zoneID: Self.zoneID)
        let coordinator = environment.makeCoordinator(transport: transport)
        #expect(await coordinator.applyPullResult(pull(changed: [changed]), settings: .default))
        #expect(try unreadableRow() == original)

        let readBack = TestFixtures.makeConnection(id: unreadableId, name: "Read by a newer build")
        try JSONEncoder().encode([StoredConnection(from: kept), StoredConnection(from: readBack)]).write(to: fileURL)
        environment.connections.invalidateCache()
        await transport.serveOnFetch(changed)

        #expect(await coordinator.runSyncCycle() == nil)

        #expect(environment.connections.loadConnection(id: unreadableId)?.name == "Renamed elsewhere")
        #expect(environment.metadata.changesHeldForUnreadableCopies.isEmpty)
        #expect(environment.recordCache.record(for: recordID) != nil)
    }

    // The deletion was held while the copy had no standing; the copy reads now.
    private func holdDeletionThenReadBack() async throws -> SyncCoordinator {
        try writeLibrary(standing: .unknown)
        let coordinator = environment.makeCoordinator(transport: ScriptedSyncTransport(zoneID: Self.zoneID))
        #expect(await coordinator.applyPullResult(pull(deleted: [recordID]), settings: .default))
        let readBack = TestFixtures.makeConnection(id: unreadableId, name: "Read by a newer build")
        try JSONEncoder().encode([StoredConnection(from: kept), StoredConnection(from: readBack)]).write(to: fileURL)
        environment.connections.invalidateCache()
        return coordinator
    }

    @Test("A held deletion applies once its copy reads")
    func heldDeletionAppliesOnceReadable() async throws {
        let coordinator = try await holdDeletionThenReadBack()

        #expect(await coordinator.applyPullResult(pull(), settings: .default))

        #expect(environment.connections.loadConnection(id: unreadableId) == nil)
        #expect(environment.metadata.deletionsHeldForUnreadableCopies.isEmpty)
    }

    @Test("A held deletion settles unapplied when the zone still lists the record, even one the pull could not read")
    func heldDeletionYieldsToARecordTheZoneStillHolds() async throws {
        let coordinator = try await holdDeletionThenReadBack()
        let listed = PullResult(changedRecords: [], deletedRecordIDs: [], newToken: nil, unreadRecordIDs: [recordID])

        #expect(await coordinator.applyPullResult(listed, settings: .default))

        #expect(environment.connections.loadConnection(id: unreadableId) != nil)
        #expect(environment.metadata.deletionsHeldForUnreadableCopies.isEmpty)
    }

    @Test("A held deletion of a category this Mac does not sync now stays held")
    func heldDeletionWaitsWhileItsCategoryIsOff() async throws {
        let coordinator = try await holdDeletionThenReadBack()
        var settings = SyncSettings.default
        settings.syncConnections = false

        #expect(await coordinator.applyPullResult(pull(), settings: settings))

        #expect(environment.connections.loadConnection(id: unreadableId) != nil)
        #expect(environment.metadata.deletionsHeldForUnreadableCopies == [recordName])
    }

    @Test("The upload mark of a connection this Mac cannot read waits for a build that can push it")
    func uploadMarkIsHeld() async throws {
        try writeLibrary(standing: .syncs)
        environment.tracker.markDirty(.connection, id: unreadableId.uuidString)
        let coordinator = environment.makeCoordinator(transport: ScriptedSyncTransport(zoneID: Self.zoneID))

        let batch = await coordinator.collectPushBatch(
            snapshot: environment.tracker.editSnapshot(),
            boundary: coordinator.syncBoundary(settings: .default),
            zoneID: Self.zoneID
        )

        #expect(batch.records.isEmpty)
        #expect(environment.tracker.dirtyRecords(for: .connection).contains(unreadableId.uuidString))
    }

    @Test("An import with the id of a connection this Mac cannot read leaves it alone")
    func importLeavesAnUnreadableId() throws {
        try writeLibrary(standing: .syncs)

        let write = environment.connections.applyImport(
            adding: [TestFixtures.makeConnection(id: unreadableId, name: "Imported")],
            replacing: []
        )

        #expect(write?.added.isEmpty ?? true)
        #expect(try unreadableRow() == original)
    }
}
