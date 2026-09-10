import Foundation
import Testing

@testable import TablePro

@Suite("ForeignKeyLabelColumnStore")
@MainActor
struct ForeignKeyLabelColumnStoreTests {
    private func makeStore() throws -> ForeignKeyLabelColumnStore {
        let defaults = try #require(UserDefaults(suiteName: "ForeignKeyLabelColumnTests.\(UUID().uuidString)"))
        return ForeignKeyLabelColumnStore(defaults: defaults)
    }

    private func scope(
        connectionId: UUID,
        database: String? = "chinook",
        schema: String? = nil,
        table: String = "Artist"
    ) -> TableScope {
        TableScope(connectionId: connectionId, database: database, schema: schema, table: table)
    }

    @Test("A table with no stored choice answers nil")
    func unsetScopeAnswersNil() throws {
        let store = try makeStore()
        #expect(store.labelColumn(for: scope(connectionId: UUID())) == nil)
    }

    @Test("A stored choice comes back")
    func storedChoiceRoundTrips() throws {
        let store = try makeStore()
        let target = scope(connectionId: UUID())
        store.setLabelColumn("Name", for: target)
        #expect(store.labelColumn(for: target) == "Name")
    }

    @Test("Nil clears the stored choice")
    func nilClearsTheChoice() throws {
        let store = try makeStore()
        let target = scope(connectionId: UUID())
        store.setLabelColumn("Name", for: target)
        store.setLabelColumn(nil, for: target)
        #expect(store.labelColumn(for: target) == nil)
    }

    @Test("An empty name clears rather than storing a blank")
    func emptyNameClears() throws {
        let store = try makeStore()
        let target = scope(connectionId: UUID())
        store.setLabelColumn("Name", for: target)
        store.setLabelColumn("", for: target)
        #expect(store.labelColumn(for: target) == nil)
    }

    /// The choice belongs to the table being picked from, so two tables of the same name in
    /// different connections, databases or schemas keep their own.
    @Test("Each table keeps its own choice")
    func choiceIsScopedToTheTable() throws {
        let store = try makeStore()
        let connection = UUID()
        store.setLabelColumn("Name", for: scope(connectionId: connection))
        store.setLabelColumn("Title", for: scope(connectionId: connection, table: "Album"))
        store.setLabelColumn("Email", for: scope(connectionId: connection, database: "other"))
        store.setLabelColumn("Code", for: scope(connectionId: UUID()))

        #expect(store.labelColumn(for: scope(connectionId: connection)) == "Name")
        #expect(store.labelColumn(for: scope(connectionId: connection, table: "Album")) == "Title")
        #expect(store.labelColumn(for: scope(connectionId: connection, database: "other")) == "Email")
    }

    @Test("A name with a dot or a quote survives the key encoding")
    func awkwardNamesSurvive() throws {
        let store = try makeStore()
        let target = scope(connectionId: UUID(), schema: "public.v2", table: "user\"s")
        store.setLabelColumn("full name", for: target)
        #expect(store.labelColumn(for: target) == "full name")
        #expect(store.labelColumn(for: scope(connectionId: target.connectionId)) == nil)
    }
}
