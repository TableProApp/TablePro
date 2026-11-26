import Foundation
@testable import TableProMobile
import TableProModels
import TableProSyncTransport
import Testing

@MainActor
@Suite("Deleted connection purge")
struct DeletedConnectionPurgeTests {
    private let fixture: AppStateFixture
    private let engine = FakeIOSSyncEngine()
    private let deleted = DatabaseConnection(name: "Deleted", type: .postgresql)
    private let kept = DatabaseConnection(name: "Kept", type: .postgresql)

    init() throws {
        fixture = try AppStateFixture()
    }

    private func makeLibrary(secureStore: MockSecureStore = MockSecureStore()) -> AppState {
        let state = fixture.makeState(syncEnabled: true, secureStore: secureStore, engine: engine)
        state.connectSync()
        #expect(state.addConnection(deleted))
        #expect(state.addConnection(kept))
        state.queryHistory.save(QueryHistoryItem(query: "SELECT card FROM payments", connectionId: deleted.id))
        state.queryHistory.save(QueryHistoryItem(query: "SELECT 1", connectionId: kept.id))
        return state
    }

    @Test("Deleting a connection forgets its query history and keeps the others'")
    func localDeleteClearsHistory() {
        let state = makeLibrary()

        state.removeConnections([deleted.id])

        #expect(state.queryHistory.load(for: deleted.id).isEmpty)
        #expect(state.queryHistory.load(for: kept.id).map(\.query) == ["SELECT 1"])
    }

    @Test("A connection deleted on another device loses its history and secrets here")
    func syncedDeleteClearsLocalState() async throws {
        let secureStore = MockSecureStore()
        let state = makeLibrary(secureStore: secureStore)
        let deletedPassword = ConnectionSecretKind.password.account(for: deleted.id)
        let keptPassword = ConnectionSecretKind.password.account(for: kept.id)
        secureStore.seed(deletedPassword, "hunter2")
        secureStore.seed(keptPassword, "kept")

        await fixture.pull(state.connections.filter { $0.id != deleted.id }, into: state, through: engine)

        #expect(state.connections.map(\.id) == [kept.id])
        #expect(state.queryHistory.load(for: deleted.id).isEmpty)
        #expect(state.queryHistory.load(for: kept.id).map(\.query) == ["SELECT 1"])
        #expect(try secureStore.retrieve(forKey: deletedPassword) == nil)
        #expect(try secureStore.retrieve(forKey: keptPassword) == "kept")
    }

    @Test("The purge removes the connection's saved tab, database, schema and query, and no other connection's")
    func purgeClearsSavedState() {
        let history = QueryHistoryStorage(directory: fixture.libraryDirectory)
        let purge = ConnectionLocalState(
            secrets: ConnectionSecrets(secureStore: MockSecureStore()),
            queryHistory: history,
            defaults: fixture.defaults
        )
        for key in ConnectionDefaultsKey.allCases {
            fixture.defaults.set("value", forKey: key.name(for: deleted.id))
            fixture.defaults.set("value", forKey: key.name(for: kept.id))
        }

        purge.purge([deleted.id])

        for key in ConnectionDefaultsKey.allCases {
            #expect(fixture.defaults.string(forKey: key.name(for: deleted.id)) == nil)
            #expect(fixture.defaults.string(forKey: key.name(for: kept.id)) == "value")
        }
    }

    @Test("The saved-state keys keep the names already stored on the device")
    func savedStateKeyNames() {
        let id = deleted.id.uuidString
        #expect(ConnectionDefaultsKey.allCases.map { $0.name(for: deleted.id) } == [
            "lastTab.\(id)", "lastDB.\(id)", "lastSchema.\(id)", "lastQuery.\(id)"
        ])
    }

    @Test("Deleting a connection deletes its saved queries and folders, and a global query it held moves to the top")
    func localDeleteRemovesSavedQueries() {
        let state = makeLibrary()
        let folder = SavedQueryFolder(name: "Reports", connectionId: deleted.id)
        let scoped = SavedQuery(name: "Scoped", query: "SELECT 1", folderId: folder.id, connectionId: deleted.id)
        let global = SavedQuery(name: "Global", query: "SELECT 2", folderId: folder.id)
        let other = SavedQuery(name: "Other", query: "SELECT 3", connectionId: kept.id)
        #expect(state.savedQueries.insertFolder(folder))
        #expect(state.savedQueries.insert(scoped))
        #expect(state.savedQueries.insert(global))
        #expect(state.savedQueries.insert(other))

        state.removeConnections([deleted.id])

        let remaining = state.savedQueries.contents
        #expect(remaining.queries.map(\.id) == [global.id, other.id])
        #expect(remaining.query(global.id)?.folderId == nil)
        #expect(remaining.folders.isEmpty)
    }

    @Test("A connection deleted on another device takes its saved queries with it")
    func syncedDeleteRemovesSavedQueries() async {
        let state = makeLibrary()
        let scoped = SavedQuery(name: "Scoped", query: "SELECT 1", connectionId: deleted.id)
        #expect(state.savedQueries.insert(scoped))

        await fixture.pull(state.connections.filter { $0.id != deleted.id }, into: state, through: engine)

        #expect(state.savedQueries.contents.queries.isEmpty)
    }

    @Test("Deleting the sample removes its saved queries")
    func sampleDeleteRemovesSavedQueries() throws {
        let state = fixture.makeState(syncEnabled: false)
        let sampleId = try state.openSampleDatabase()
        let scoped = SavedQuery(name: "Sample", query: "SELECT 1", connectionId: sampleId)
        #expect(state.savedQueries.insert(scoped))

        state.removeConnections([sampleId])

        #expect(state.savedQueries.contents.queries.isEmpty)
    }

    @Test("A pull that deletes nothing leaves every history alone")
    func syncWithoutDeletionKeepsHistory() async throws {
        let state = makeLibrary()
        var renamed = try #require(state.connections.first { $0.id == kept.id })
        renamed.name = "Renamed"

        await fixture.pull(state.connections.map { $0.id == kept.id ? renamed : $0 }, into: state, through: engine)

        #expect(state.queryHistory.load(for: deleted.id).count == 1)
        #expect(state.queryHistory.load(for: kept.id).count == 1)
    }
}
