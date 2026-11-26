import Foundation
@testable import TableProMobile
import TableProFFI
import TableProModels
import TableProSyncTransport
import TableProTestSupport
import Testing

@MainActor
struct AppStateSyncWiringTests {
    private let fixture: AppStateFixture

    init() throws {
        fixture = try AppStateFixture()
    }

    private func makeSyncedState(engine: FakeIOSSyncEngine? = nil) -> AppState {
        let state = fixture.makeState(syncEnabled: true, engine: engine)
        state.connectSync()
        return state
    }

    @Test("A pass the engine finished brings what it wrote to the library into the app, with its saved queries")
    func aFinishedPassReloadsTheStores() async throws {
        let engine = FakeIOSSyncEngine()
        let pulled = DatabaseConnection(name: "From the Mac", type: .postgresql)
        let query = SavedQuery(name: "Revenue", query: "SELECT 1", connectionId: pulled.id)
        let directory = fixture.libraryDirectory
        engine.update { state in
            state.pass = { _ in
                try? ElsewhereWriter.write(connection: pulled, query: query, in: directory)
            }
        }
        let state = makeSyncedState(engine: engine)

        await state.syncCoordinator.sync(.userRequest)

        try await waitUntil { state.connections.contains { $0.id == pulled.id } }
        #expect(state.savedQueries.contents.queries.map(\.id) == [query.id])
    }

    @Test("An edit made before the app read a pass goes on top of what the pass wrote, and keeps both")
    func anEditOverAnUnreadPassKeepsBoth() throws {
        let state = makeSyncedState()
        let mine = DatabaseConnection(name: "Mine", type: .postgresql)
        #expect(state.addConnection(mine))
        let theirs = DatabaseConnection(name: "From the Mac", type: .postgresql)
        try ElsewhereWriter.replace(connections: [mine, theirs], in: fixture.libraryDirectory)

        #expect(state.mutateConnection(mine.id) { $0.name = "Mine, renamed" } == .applied)

        #expect(Set(state.connections.map(\.name)) == ["Mine, renamed", "From the Mac"])
        let reloaded = fixture.makeState(syncEnabled: false)
        #expect(Set(reloaded.connections.map(\.name)) == ["Mine, renamed", "From the Mac"])
    }

    @Test("A pass removes the unread groups and tags another device deleted, all in one write")
    func onePassRemovesEveryPendingUnreadCopy() async throws {
        let engine = FakeIOSSyncEngine()
        let group = UUID()
        let tag = UUID()
        let groupsFile = fixture.libraryDirectory.appendingPathComponent("groups.json")
        let tagsFile = fixture.libraryDirectory.appendingPathComponent("tags.json")
        try Data(#"[{"id":"\#(group.uuidString)","name":7}]"#.utf8).write(to: groupsFile)
        try Data(#"[{"id":"\#(tag.uuidString)","name":8}]"#.utf8).write(to: tagsFile)
        let state = makeSyncedState(engine: engine)
        #expect(state.unreadableCopies == UnreadableCopies(groups: [group], tags: [tag]))
        fixture.metadata.removalsPendingForUnreadableCopies = UnreadableCopies(groups: [group], tags: [tag]).recordNames

        await fixture.pull([DatabaseConnection(name: "Pulled", type: .postgresql)], into: state, through: engine)

        #expect(state.unreadableCopies.isEmpty)
        for file in [groupsFile, tagsFile] {
            let rows = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [NSDictionary])
            #expect(rows.isEmpty)
        }
    }

    @Test("A removal a failed write already made still purges what the connection left once a write goes through")
    func failedWriteKeepsThePurgeOwed() async throws {
        let engine = FakeIOSSyncEngine()
        let held = DatabaseConnection(name: "Held", type: .postgresql)
        try JSONEncoder().encode([held]).write(to: fixture.connectionsFile)
        _ = fixture.makeState(syncEnabled: false)
        var document = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.coreConnectionsFile)) as? [String: Any]
        )
        var entries = try #require(document["connections"] as? [[String: Any]])
        entries[0]["auth_mode"] = "from_the_future"
        document["connections"] = entries
        try JSONSerialization.data(withJSONObject: document).write(to: fixture.coreConnectionsFile)
        let group = UUID()
        let groupsFile = fixture.libraryDirectory.appendingPathComponent("groups.json")
        try Data(#"[{"id":"\#(group.uuidString)","name":7}]"#.utf8).write(to: groupsFile)

        let secureStore = MockSecureStore()
        try secureStore.store("secret", forKey: "com.TablePro.password.\(held.id.uuidString)")
        let state = fixture.makeState(syncEnabled: true, secureStore: secureStore, engine: engine)
        state.connectSync()
        #expect(state.unreadableCopies == UnreadableCopies(connections: [held.id], groups: [group]))
        fixture.metadata.removalsPendingForUnreadableCopies = UnreadableCopies(connections: [held.id], groups: [group]).recordNames
        try FileManager.default.removeItem(at: groupsFile)
        try FileManager.default.createDirectory(at: groupsFile, withIntermediateDirectories: false)
        let pulled = DatabaseConnection(name: "Pulled", type: .postgresql)

        await fixture.pull([pulled], into: state, through: engine)
        #expect(try secureStore.retrieve(forKey: "com.TablePro.password.\(held.id.uuidString)") == "secret")
        try FileManager.default.removeItem(at: groupsFile)
        await fixture.pull([pulled], into: state, through: engine)

        #expect(state.unreadableCopies.isEmpty)
        #expect(try secureStore.retrieve(forKey: "com.TablePro.password.\(held.id.uuidString)") == nil)
    }
}
