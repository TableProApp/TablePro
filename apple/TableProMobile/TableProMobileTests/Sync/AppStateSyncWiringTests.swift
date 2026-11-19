import CloudKit
import Foundation
@testable import TableProMobile
import TableProModels
import TableProSync
import TableProSyncTransport
import Testing

@MainActor
struct AppStateSyncWiringTests {
    private let fixture: AppStateFixture
    private let zoneID = CKRecordZone.ID(zoneName: "RecordingZone", ownerName: CKCurrentUserDefaultName)

    init() throws {
        fixture = try AppStateFixture()
    }

    private func makeSyncedState(transport: RecordingSyncTransport) -> AppState {
        let state = fixture.makeState(syncEnabled: true, transport: transport)
        state.connectSync()
        return state
    }

    @Test("A CloudKit notice downloads through the app's wiring only while sync is on")
    func noticeDownloadsOnlyWithSyncOn() async {
        let transport = RecordingSyncTransport()
        let state = makeSyncedState(transport: transport)
        state.onboarding.setSyncChoice(false)
        #expect(await state.syncFromBackground(.remoteChange) == false)
        #expect(await transport.pullCount == 0)

        state.onboarding.setSyncChoice(true)
        #expect(await state.syncFromBackground(.remoteChange))
        #expect(await transport.pullCount == 1)
    }

    @Test("A saved query whose connection this build cannot read stays on the device, even marked for upload")
    func unreadableOwnerKeepsItsQueriesLocal() async throws {
        let ownerId = UUID()
        try Data(#"[{"id":"\#(ownerId.uuidString)","name":"Unreadable","isSample":true}]"#.utf8)
            .write(to: fixture.connectionsFile)
        let transport = RecordingSyncTransport()
        let state = makeSyncedState(transport: transport)
        let owned = SavedQuery(name: "Owned", query: "SELECT 1", connectionId: ownerId)
        let global = SavedQuery(name: "Global", query: "SELECT 2")
        #expect(state.savedQueries.insert(owned))
        #expect(state.savedQueries.insert(global))
        #expect(!fixture.metadata.dirtyIds(for: .favorite).contains(owned.id.uuidString))
        fixture.metadata.markDirty(owned.id.uuidString, type: .favorite)

        await state.syncCoordinator.sync()

        let pushed = await transport.pushedRecords.compactMap(SyncRecordMapper.toSavedQuery).map(\.id)
        #expect(pushed == [global.id])
    }

    @Test("A pull leaves the saved queries of a connection this build cannot read as they are")
    func unreadableOwnerQueriesSurviveAPull() async throws {
        let ownerId = UUID()
        try Data(#"[{"id":"\#(ownerId.uuidString)","name":"Unreadable","localOnly":true}]"#.utf8)
            .write(to: fixture.connectionsFile)
        let owned = SavedQuery(name: "Owned", query: "SELECT 1", connectionId: ownerId)
        let deletion = SyncRecordMapper.recordID(type: .favorite, id: owned.id.uuidString, in: zoneID)
        let transport = RecordingSyncTransport(remoteDeletions: [deletion])
        let state = makeSyncedState(transport: transport)
        #expect(state.savedQueries.insert(owned))

        await state.syncCoordinator.sync()

        #expect(state.savedQueries.contents.queries.map { $0.id } == [owned.id])
    }

    // A connection in a shape this build cannot read, beside one it can, with the standing a build that read it left.
    private func writeUnreadableLibrary(_ unreadableId: UUID, standing: SyncStanding) throws -> NSDictionary {
        let kept = DatabaseConnection(name: "Kept", type: .postgresql)
        let keptJSON = try String(decoding: JSONEncoder().encode(kept), as: UTF8.self)
        let unreadableJSON = #"{"id":"\#(unreadableId.uuidString)","name":"From a newer build","shape":2}"#
        try Data("[\(keptJSON),\(unreadableJSON)]".utf8).write(to: fixture.connectionsFile)
        switch standing {
        case .syncs:
            fixture.metadata.recordConnectionStanding(syncing: [unreadableId], keptOff: [], unreadable: [])
        case .keptOff:
            fixture.metadata.recordConnectionStanding(syncing: [], keptOff: [unreadableId], unreadable: [])
        case .unknown:
            break
        }
        return try #require(try JSONSerialization.jsonObject(with: Data(unreadableJSON.utf8)) as? NSDictionary)
    }

    private func storedRow(_ id: UUID) throws -> NSDictionary? {
        let rows = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.connectionsFile)) as? [NSDictionary])
        return rows.first { $0["id"] as? String == id.uuidString }
    }

    @Test("A deletion from iCloud removes a connection this build cannot read when its standing says it syncs")
    func deletionRemovesAnUnreadableSyncedConnection() async throws {
        let id = UUID()
        _ = try writeUnreadableLibrary(id, standing: .syncs)
        let deletion = SyncRecordMapper.recordID(type: .connection, id: id.uuidString, in: zoneID)
        let state = makeSyncedState(transport: RecordingSyncTransport(remoteDeletions: [deletion]))

        await state.syncCoordinator.sync()

        #expect(try storedRow(id) == nil)
        #expect(state.unreadableCopies.connections.isEmpty)
        #expect(state.connections.map { $0.name } == ["Kept"])
    }

    @Test("A connection kept off iCloud stays as it was when a deletion names its id, even while unreadable")
    func deletionLeavesAnUnreadableKeptOffConnection() async throws {
        let id = UUID()
        let original = try writeUnreadableLibrary(id, standing: .keptOff)
        let deletion = SyncRecordMapper.recordID(type: .connection, id: id.uuidString, in: zoneID)
        let state = makeSyncedState(transport: RecordingSyncTransport(remoteDeletions: [deletion]))

        await state.syncCoordinator.sync()

        #expect(try storedRow(id) == original)
        #expect(fixture.metadata.deletionsHeldForUnreadableCopies.isEmpty)
    }

    @Test("A change from iCloud never writes over a connection this build cannot read, and a build that reads it takes the change")
    func heldChangeReachesTheBuildThatReadsIt() async throws {
        let id = UUID()
        let original = try writeUnreadableLibrary(id, standing: .syncs)
        let renamed = DatabaseConnection(id: id, name: "Renamed elsewhere", type: .postgresql)
        let transport = RecordingSyncTransport(
            remoteRecords: [SyncRecordMapper.toRecord(renamed, zoneID: zoneID)],
            newToken: try RecordingSyncTransport.makeChangeToken()
        )
        let state = makeSyncedState(transport: transport)

        await state.syncCoordinator.sync()

        #expect(try storedRow(id) == original)
        #expect(state.connections.map { $0.name } == ["Kept"])
        #expect(fixture.metadata.changesHeldForUnreadableCopies == [SyncRecordType.connection.recordName(for: id.uuidString)])

        let readBack = DatabaseConnection(id: id, name: "Read by a newer build", type: .postgresql)
        let kept = try #require(state.connections.first)
        try JSONEncoder().encode([kept, readBack]).write(to: fixture.connectionsFile)
        await transport.answerPulls(with: [])
        await transport.serveOnFetch(SyncRecordMapper.toRecord(renamed, zoneID: zoneID))
        let newerBuild = makeSyncedState(transport: transport)

        await newerBuild.syncCoordinator.sync()

        #expect(newerBuild.connections.first { $0.id == id }?.name == "Renamed elsewhere")
        #expect(fixture.metadata.changesHeldForUnreadableCopies.isEmpty)
        #expect(await transport.fetchedRecordIDs.map(\.recordName) == [SyncRecordType.connection.recordName(for: id.uuidString)])
    }

    @Test("A group this build cannot read keeps a change from iCloud held, and goes when iCloud deletes it")
    func unreadableGroupFollowsTheSameRules() async throws {
        let held = UUID()
        let deleted = UUID()
        let groupsFile = fixture.libraryDirectory.appendingPathComponent("groups.json")
        try Data(#"[{"id":"\#(held.uuidString)","name":7},{"id":"\#(deleted.uuidString)","name":8}]"#.utf8).write(to: groupsFile)
        let transport = RecordingSyncTransport(
            remoteRecords: [SyncRecordMapper.toRecord(ConnectionGroup(id: held, name: "Renamed"), zoneID: zoneID)],
            remoteDeletions: [SyncRecordMapper.recordID(type: .group, id: deleted.uuidString, in: zoneID)]
        )
        let state = makeSyncedState(transport: transport)

        await state.syncCoordinator.sync()

        let rows = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: groupsFile)) as? [NSDictionary])
        #expect(rows.compactMap { $0["id"] as? String } == [held.uuidString])
        #expect(rows.first?["name"] as? Int == 7)
    }

    @Test("A saved query made on the Mac reaches the saved queries and the file through the app's sync wiring")
    func pulledSavedQueryReachesTheLibrary() async {
        let folder = SavedQueryFolder(name: "Reports")
        let query = SavedQuery(name: "One", query: "SELECT 1", keyword: "one", folderId: folder.id)
        let transport = RecordingSyncTransport(remoteRecords: [
            SyncRecordMapper.toRecord(folder, zoneID: zoneID),
            SyncRecordMapper.toRecord(query, zoneID: zoneID)
        ])
        let state = makeSyncedState(transport: transport)

        await state.syncCoordinator.sync()

        #expect(state.savedQueries.contents == SavedQueryContents(queries: [query], folders: [folder]))
        let reloaded = fixture.makeState(syncEnabled: false).savedQueries.contents
        let reloadedIds = reloaded.queries.map(\.id)
        #expect(reloadedIds == [query.id])
        #expect(reloaded.queries.first?.folderId == folder.id)
    }

    @Test("A saved query made on iPhone is pushed through the app's sync wiring, and one the sample owns is not")
    func savedQueryIsPushed() async throws {
        let transport = RecordingSyncTransport()
        let state = makeSyncedState(transport: transport)
        let sampleId = try state.openSampleDatabase()
        let global = SavedQuery(name: "Global", query: "SELECT 1")
        let sampleQuery = SavedQuery(name: "Sample", query: "SELECT 2", connectionId: sampleId)
        #expect(state.savedQueries.insert(global))
        #expect(state.savedQueries.insert(sampleQuery))

        await state.syncCoordinator.sync()

        let pushed = await transport.pushedRecords.compactMap(SyncRecordMapper.toSavedQuery).map(\.id)
        #expect(pushed == [global.id])
        #expect(fixture.metadata.dirtyIds(for: .favorite).isEmpty)
    }

    @Test("A query edited on iPhone while the Mac moved it keeps both changes")
    func editKeepsThePulledMove() async throws {
        let folder = SavedQueryFolder(name: "Reports")
        let query = SavedQuery(name: "Old", query: "SELECT 1")
        let transport = RecordingSyncTransport()
        let state = makeSyncedState(transport: transport)
        #expect(state.savedQueries.insert(query))
        await state.syncCoordinator.sync()

        var moved = query
        moved.folderId = folder.id
        await transport.answerPulls(with: [
            SyncRecordMapper.toRecord(folder, zoneID: zoneID),
            SyncRecordMapper.toRecord(moved, zoneID: zoneID)
        ])
        await state.syncCoordinator.sync()
        let renamed = state.savedQueries.update(query.id) { $0.name = "New" }
        #expect(renamed)
        await state.syncCoordinator.sync()

        let pushed = await transport.pushedRecords.compactMap(SyncRecordMapper.toSavedQuery)
        let last = try #require(pushed.last)
        #expect(last.name == "New")
        #expect(last.folderId == folder.id)
    }
}
