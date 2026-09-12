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
        #expect(store.labelChoice(for: scope(connectionId: UUID())) == .unset)
    }

    @Test("A stored choice comes back")
    func storedChoiceRoundTrips() throws {
        let store = try makeStore()
        let target = scope(connectionId: UUID())
        store.setLabelChoice(.column("Name"), for: target)
        #expect(store.labelChoice(for: target) == .column("Name"))
    }

    @Test("Unset clears the stored choice")
    func unsetClearsTheChoice() throws {
        let store = try makeStore()
        let target = scope(connectionId: UUID())
        store.setLabelChoice(.column("Name"), for: target)
        store.setLabelChoice(.unset, for: target)
        #expect(store.labelChoice(for: target) == .unset)
    }

    /// The reader choosing to see keys on their own is an answer, and it used to be stored as no
    /// answer at all, so the heuristic picked a label again the moment the picker was reopened.
    @Test("Choosing no label outlives a reopen")
    func explicitNoneOutlivesAReopen() throws {
        let store = try makeStore()
        let target = scope(connectionId: UUID())
        store.setLabelChoice(.column("Name"), for: target)
        store.setLabelChoice(.noLabel, for: target)
        #expect(store.labelChoice(for: target) == .noLabel)
    }

    @Test("The three states are distinct")
    func theThreeStatesAreDistinct() throws {
        let store = try makeStore()
        let unset = scope(connectionId: UUID())
        let none = scope(connectionId: UUID())
        let named = scope(connectionId: UUID())
        store.setLabelChoice(.noLabel, for: none)
        store.setLabelChoice(.column("Name"), for: named)

        #expect(store.labelChoice(for: unset) == .unset)
        #expect(store.labelChoice(for: none) == .noLabel)
        #expect(store.labelChoice(for: named) == .column("Name"))
    }

    /// SQLite accepts `create table t("" integer)`, so a zero-length column name is one a reader can
    /// really pick. It must not read back as either of the other two states.
    @Test("An empty column name is a choice of its own")
    func anEmptyColumnNameIsAChoiceOfItsOwn() throws {
        let store = try makeStore()
        let target = scope(connectionId: UUID())
        store.setLabelChoice(.column(""), for: target)
        #expect(store.labelChoice(for: target) == .column(""))
    }

    @Test("Choosing no label survives a rename")
    func explicitNoneSurvivesARename() throws {
        let store = try makeStore()
        let old = scope(connectionId: UUID())
        let new = scope(connectionId: old.connectionId, table: "Performer")
        store.setLabelChoice(.noLabel, for: old)

        store.renameTable(from: old, to: new)

        #expect(store.labelChoice(for: new) == .noLabel)
        #expect(store.labelChoice(for: old) == .unset)
    }

    /// The seam the defect lived in: the store said nothing, so the resolver guessed.
    @Test("Choosing no label stops the heuristic")
    func explicitNoneStopsTheHeuristic() throws {
        let store = try makeStore()
        let target = scope(connectionId: UUID())
        store.setLabelChoice(.noLabel, for: target)

        let columns = [
            ForeignKeyLookupColumn(name: "id", type: .integer(rawType: "INTEGER")),
            ForeignKeyLookupColumn(name: "name", type: .text(rawType: "VARCHAR(64)"))
        ]
        let resolved = ForeignKeyLabelColumn.resolve(
            columns: columns, keyColumn: "id", choice: store.labelChoice(for: target)
        )
        #expect(resolved == nil)
    }

    /// The choice belongs to the table being picked from, so two tables of the same name in
    /// different connections, databases or schemas keep their own.
    @Test("Each table keeps its own choice")
    func choiceIsScopedToTheTable() throws {
        let store = try makeStore()
        let connection = UUID()
        store.setLabelChoice(.column("Name"), for: scope(connectionId: connection))
        store.setLabelChoice(.column("Title"), for: scope(connectionId: connection, table: "Album"))
        store.setLabelChoice(.column("Email"), for: scope(connectionId: connection, database: "other"))
        store.setLabelChoice(.column("Code"), for: scope(connectionId: UUID()))

        #expect(store.labelChoice(for: scope(connectionId: connection)) == .column("Name"))
        #expect(store.labelChoice(for: scope(connectionId: connection, table: "Album")) == .column("Title"))
        #expect(store.labelChoice(for: scope(connectionId: connection, database: "other")) == .column("Email"))
    }

    @Test("A name with a dot or a quote survives the key encoding")
    func awkwardNamesSurvive() throws {
        let store = try makeStore()
        let target = scope(connectionId: UUID(), schema: "public.v2", table: "user\"s")
        store.setLabelChoice(.column("full name"), for: target)
        #expect(store.labelChoice(for: target) == .column("full name"))
        #expect(store.labelChoice(for: scope(connectionId: target.connectionId)) == .unset)
    }

    @Test("A table rename moves its choice and leaves a longer name alone")
    func renameTableMovesOnlyThatTable() throws {
        let store = try makeStore()
        let connection = UUID()
        let other = UUID()
        store.setLabelChoice(.column("Name"), for: scope(connectionId: connection))
        store.setLabelChoice(.column("Title"), for: scope(connectionId: connection, table: "Artist_archive"))
        store.setLabelChoice(.column("Code"), for: scope(connectionId: other))

        store.renameTable(
            from: scope(connectionId: connection),
            to: scope(connectionId: connection, table: "Performer")
        )

        #expect(store.labelChoice(for: scope(connectionId: connection)) == .unset)
        #expect(store.labelChoice(for: scope(connectionId: connection, table: "Performer")) == .column("Name"))
        #expect(store.labelChoice(for: scope(connectionId: connection, table: "Artist_archive")) == .column("Title"))
        #expect(store.labelChoice(for: scope(connectionId: other)) == .column("Code"))
    }

    @Test("A schema rename moves every table in it and nothing outside it")
    func renameContainerMovesTheSchema() throws {
        let store = try makeStore()
        let connection = UUID()
        let other = UUID()
        store.setLabelChoice(.column("Name"), for: scope(connectionId: connection, schema: "music"))
        store.setLabelChoice(.column("Title"), for: scope(connectionId: connection, schema: "music", table: "Album"))
        store.setLabelChoice(.column("Code"), for: scope(connectionId: connection, schema: "music_old"))
        store.setLabelChoice(.column("Email"), for: scope(connectionId: other, schema: "music"))

        store.renameContainer(
            connectionId: connection, fromDatabase: "chinook", fromSchema: "music",
            toDatabase: "chinook", toSchema: "catalog"
        )

        #expect(store.labelChoice(for: scope(connectionId: connection, schema: "catalog")) == .column("Name"))
        #expect(store.labelChoice(for: scope(connectionId: connection, schema: "catalog", table: "Album")) == .column("Title"))
        #expect(store.labelChoice(for: scope(connectionId: connection, schema: "music")) == .unset)
        #expect(store.labelChoice(for: scope(connectionId: connection, schema: "music_old")) == .column("Code"))
        #expect(store.labelChoice(for: scope(connectionId: other, schema: "music")) == .column("Email"))
    }

    @Test("A database rename moves its tables and leaves a longer database name alone")
    func renameDatabaseMovesItsTables() throws {
        let store = try makeStore()
        let connection = UUID()
        store.setLabelChoice(.column("Name"), for: scope(connectionId: connection))
        store.setLabelChoice(.column("Title"), for: scope(connectionId: connection, database: "chinook_backup"))

        store.renameContainer(
            connectionId: connection, fromDatabase: "chinook", fromSchema: nil,
            toDatabase: "music", toSchema: nil
        )

        #expect(store.labelChoice(for: scope(connectionId: connection, database: "music")) == .column("Name"))
        #expect(store.labelChoice(for: scope(connectionId: connection)) == .unset)
        #expect(store.labelChoice(for: scope(connectionId: connection, database: "chinook_backup")) == .column("Title"))
    }

    @Test("Deleting a connection removes its choices and keeps every other connection's")
    func purgeConnectionsRemovesOnlyThatConnection() throws {
        let store = try makeStore()
        let connection = UUID()
        let other = UUID()
        store.setLabelChoice(.column("Name"), for: scope(connectionId: connection))
        store.setLabelChoice(.column("Title"), for: scope(connectionId: connection, table: "Album"))
        store.setLabelChoice(.column("Code"), for: scope(connectionId: other))

        store.purgeConnections([connection])

        #expect(store.labelChoice(for: scope(connectionId: connection)) == .unset)
        #expect(store.labelChoice(for: scope(connectionId: connection, table: "Album")) == .unset)
        #expect(store.labelChoice(for: scope(connectionId: other)) == .column("Code"))
    }
}
