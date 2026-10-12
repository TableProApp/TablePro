import Foundation
@testable import TableProMobile
import TableProModels
import Testing

@MainActor
@Suite("Deleted connection purge")
struct DeletedConnectionPurgeTests {
    private let fixture: AppStateFixture
    private let deleted = DatabaseConnection(name: "Deleted", type: .postgresql)
    private let kept = DatabaseConnection(name: "Kept", type: .postgresql)

    init() throws {
        fixture = try AppStateFixture()
    }

    private func makeLibrary(secureStore: MockSecureStore = MockSecureStore()) -> AppState {
        let state = fixture.makeState(syncEnabled: false, secureStore: secureStore)
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
    func syncedDeleteClearsLocalState() throws {
        let secureStore = MockSecureStore()
        let state = makeLibrary(secureStore: secureStore)
        let deletedPassword = ConnectionSecretKind.password.account(for: deleted.id)
        let keptPassword = ConnectionSecretKind.password.account(for: kept.id)
        secureStore.seed(deletedPassword, "hunter2")
        secureStore.seed(keptPassword, "kept")

        state.applySyncedConnections(state.connections.filter { $0.id != deleted.id })

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

    @Test("A sync merge that deletes nothing leaves every history alone")
    func syncWithoutDeletionKeepsHistory() throws {
        let state = makeLibrary()
        var renamed = try #require(state.connections.first { $0.id == kept.id })
        renamed.name = "Renamed"

        state.applySyncedConnections(state.connections.map { $0.id == kept.id ? renamed : $0 })

        #expect(state.queryHistory.load(for: deleted.id).count == 1)
        #expect(state.queryHistory.load(for: kept.id).count == 1)
    }
}
