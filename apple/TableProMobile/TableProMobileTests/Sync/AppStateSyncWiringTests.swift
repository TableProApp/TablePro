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
