import CloudKit
import Foundation
@testable import TableProMobile
import TableProModels
import TableProSync
import TableProSyncTransport
import Testing

@MainActor
struct SyncedWriteFailureTests {
    private let fixture: AppStateFixture
    private let zoneID = CKRecordZone.ID(zoneName: "RecordingZone", ownerName: CKCurrentUserDefaultName)
    private let tokenKey = "com.TablePro.sync.serverChangeToken"

    init() throws {
        fixture = try AppStateFixture()
    }

    private var savedToken: Data? {
        fixture.metadata.userDefaults.data(forKey: tokenKey)
    }

    // A directory the app cannot write into makes every library save fail the way a full disk does.
    private func setLibraryWritable(_ writable: Bool) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: writable ? 0o755 : 0o555],
            ofItemAtPath: fixture.libraryDirectory.path
        )
    }

    private func makeSyncedState(transport: RecordingSyncTransport) -> AppState {
        let state = fixture.makeState(syncEnabled: true, transport: transport)
        state.connectSync()
        return state
    }

    @Test("A pulled connection that could not be saved is not shown, and the change token waits for it")
    func unsavedConnectionHoldsTheToken() async throws {
        let remote = DatabaseConnection(name: "From Mac", type: .postgresql)
        let transport = RecordingSyncTransport(
            remoteRecords: [SyncRecordMapper.toRecord(remote, zoneID: zoneID)],
            newToken: try RecordingSyncTransport.makeChangeToken()
        )
        let state = makeSyncedState(transport: transport)
        try setLibraryWritable(false)
        defer { try? setLibraryWritable(true) }

        await state.syncCoordinator.sync()

        #expect(state.connections.isEmpty)
        #expect(savedToken == nil)
        #expect(state.syncCoordinator.status == .error(.pullNotSaved))

        try setLibraryWritable(true)
        await state.syncCoordinator.sync()

        let shown = state.connections.map(\.id)
        let stored = fixture.makeState(syncEnabled: false).connections.map(\.id)
        #expect(shown == [remote.id])
        #expect(stored == [remote.id])
        #expect(savedToken != nil)
    }

    @Test("A pulled saved query that could not be saved holds only the token: the cache moves and connections go up")
    func unsavedSavedQueryHoldsOnlyTheToken() async throws {
        let query = SavedQuery(name: "One", query: "SELECT 1")
        let record = SyncRecordMapper.toRecord(query, zoneID: zoneID)
        let transport = RecordingSyncTransport(remoteRecords: [record], newToken: try RecordingSyncTransport.makeChangeToken())
        let state = makeSyncedState(transport: transport)
        let local = DatabaseConnection(name: "Local", type: .mysql)
        #expect(state.addConnection(local))
        try setLibraryWritable(false)
        defer { try? setLibraryWritable(true) }

        await state.syncCoordinator.sync()

        #expect(state.savedQueries.contents.queries.isEmpty)
        #expect(savedToken == nil)
        #expect(state.syncCoordinator.status == .error(.pullNotSaved))
        let pushed = await transport.pushedRecords.compactMap(SyncRecordMapper.toConnection).map(\.id)
        #expect(pushed == [local.id])
        let cache = SyncRecordCache(directory: fixture.root.appendingPathComponent("Cache"), defaults: nil)
        #expect(cache.record(for: record.recordID) != nil)

        try setLibraryWritable(true)
        await state.syncCoordinator.sync()

        let stored = state.savedQueries.contents.queries.map(\.id)
        #expect(stored == [query.id])
        #expect(savedToken != nil)
        #expect(state.syncCoordinator.status == .idle)
    }

    @Test("With the saved queries file unreadable, connections still sync, the file is kept and the token waits")
    func unreadableSavedQueriesHoldOnlyTheToken() async throws {
        let file = fixture.libraryDirectory.appendingPathComponent("saved-queries.json")
        let unreadable = Data("{ not json".utf8)
        try unreadable.write(to: file)
        let query = SavedQuery(name: "One", query: "SELECT 1")
        let transport = RecordingSyncTransport(
            remoteRecords: [SyncRecordMapper.toRecord(query, zoneID: zoneID)],
            newToken: try RecordingSyncTransport.makeChangeToken()
        )
        let state = makeSyncedState(transport: transport)
        let local = DatabaseConnection(name: "Local", type: .mysql)
        #expect(state.addConnection(local))
        let marked = SavedQuery(name: "Marked", query: "SELECT 2")
        state.syncCoordinator.markDirty(savedQueries: [marked.id])
        state.syncCoordinator.markDeleted(savedQueries: [UUID()])

        await state.syncCoordinator.sync()

        #expect(state.loadStatus == .ready)
        #expect(state.savedQueries.status == .failed)
        #expect(try Data(contentsOf: file) == unreadable)
        #expect(savedToken == nil)
        let pushedTypes = Set(await transport.pushedRecords.map(\.recordType))
        #expect(pushedTypes == [SyncRecordType.connection.rawValue])
        #expect(await transport.pushedDeletions.isEmpty)
        #expect(state.syncCoordinator.status == .error(.pullNotSaved))

        try JSONEncoder().encode(SavedQueryContents()).write(to: file)
        state.retryLoadIfFailed()
        await state.syncCoordinator.sync()

        #expect(state.savedQueries.status == .ready)
        let stored = state.savedQueries.contents.queries.map(\.id)
        #expect(stored == [query.id])
        #expect(savedToken != nil)
    }
}
