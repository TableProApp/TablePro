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

    @Test("A table rename moves its choice and leaves a longer name alone")
    func renameTableMovesOnlyThatTable() throws {
        let store = try makeStore()
        let connection = UUID()
        let other = UUID()
        store.setLabelColumn("Name", for: scope(connectionId: connection))
        store.setLabelColumn("Title", for: scope(connectionId: connection, table: "Artist_archive"))
        store.setLabelColumn("Code", for: scope(connectionId: other))

        store.renameTable(
            from: scope(connectionId: connection),
            to: scope(connectionId: connection, table: "Performer")
        )

        #expect(store.labelColumn(for: scope(connectionId: connection)) == nil)
        #expect(store.labelColumn(for: scope(connectionId: connection, table: "Performer")) == "Name")
        #expect(store.labelColumn(for: scope(connectionId: connection, table: "Artist_archive")) == "Title")
        #expect(store.labelColumn(for: scope(connectionId: other)) == "Code")
    }

    @Test("A schema rename moves every table in it and nothing outside it")
    func renameContainerMovesTheSchema() throws {
        let store = try makeStore()
        let connection = UUID()
        let other = UUID()
        store.setLabelColumn("Name", for: scope(connectionId: connection, schema: "music"))
        store.setLabelColumn("Title", for: scope(connectionId: connection, schema: "music", table: "Album"))
        store.setLabelColumn("Code", for: scope(connectionId: connection, schema: "music_old"))
        store.setLabelColumn("Email", for: scope(connectionId: other, schema: "music"))

        store.renameContainer(
            connectionId: connection, fromDatabase: "chinook", fromSchema: "music",
            toDatabase: "chinook", toSchema: "catalog"
        )

        #expect(store.labelColumn(for: scope(connectionId: connection, schema: "catalog")) == "Name")
        #expect(store.labelColumn(for: scope(connectionId: connection, schema: "catalog", table: "Album")) == "Title")
        #expect(store.labelColumn(for: scope(connectionId: connection, schema: "music")) == nil)
        #expect(store.labelColumn(for: scope(connectionId: connection, schema: "music_old")) == "Code")
        #expect(store.labelColumn(for: scope(connectionId: other, schema: "music")) == "Email")
    }

    @Test("A database rename moves its tables and leaves a longer database name alone")
    func renameDatabaseMovesItsTables() throws {
        let store = try makeStore()
        let connection = UUID()
        store.setLabelColumn("Name", for: scope(connectionId: connection))
        store.setLabelColumn("Title", for: scope(connectionId: connection, database: "chinook_backup"))

        store.renameContainer(
            connectionId: connection, fromDatabase: "chinook", fromSchema: nil,
            toDatabase: "music", toSchema: nil
        )

        #expect(store.labelColumn(for: scope(connectionId: connection, database: "music")) == "Name")
        #expect(store.labelColumn(for: scope(connectionId: connection)) == nil)
        #expect(store.labelColumn(for: scope(connectionId: connection, database: "chinook_backup")) == "Title")
    }

    @Test("Deleting a connection removes its choices and keeps every other connection's")
    func purgeConnectionsRemovesOnlyThatConnection() throws {
        let store = try makeStore()
        let connection = UUID()
        let other = UUID()
        store.setLabelColumn("Name", for: scope(connectionId: connection))
        store.setLabelColumn("Title", for: scope(connectionId: connection, table: "Album"))
        store.setLabelColumn("Code", for: scope(connectionId: other))

        store.purgeConnections([connection])

        #expect(store.labelColumn(for: scope(connectionId: connection)) == nil)
        #expect(store.labelColumn(for: scope(connectionId: connection, table: "Album")) == nil)
        #expect(store.labelColumn(for: scope(connectionId: other)) == "Code")
    }
}
