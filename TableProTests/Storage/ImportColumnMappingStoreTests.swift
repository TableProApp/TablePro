//
//  ImportColumnMappingStoreTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@MainActor
struct ImportColumnMappingStoreTests {
    private func makeStore() throws -> ImportColumnMappingStore {
        let defaults = try #require(UserDefaults(suiteName: "ImportColumnMappingStoreTests.\(UUID().uuidString)"))
        return ImportColumnMappingStore(defaults: defaults)
    }

    private func scope(
        connectionId: UUID,
        database: String? = "shop",
        schema: String? = nil,
        table: String = "people"
    ) -> TableScope {
        TableScope(connectionId: connectionId, database: database, schema: schema, table: table)
    }

    @Test("Overrides remembered for a table come back for that table only")
    func rememberedOverridesRoundTrip() throws {
        let store = try makeStore()
        let connectionId = UUID()
        let people = scope(connectionId: connectionId)
        store.remember(["Name": .column("full_name"), "id": .skip], forFields: ["id", "Name"], in: people)

        #expect(store.overrides(for: people) == ["Name": .column("full_name"), "id": .skip])
        #expect(store.overrides(for: scope(connectionId: connectionId, table: "orders")).isEmpty)
        #expect(store.overrides(for: scope(connectionId: connectionId, schema: "archive")).isEmpty)
        #expect(store.overrides(for: scope(connectionId: UUID())).isEmpty)
    }

    @Test("A later import that falls back to the name match for every field forgets the table")
    func importMatchingByNameClearsTheEntry() throws {
        let store = try makeStore()
        let people = scope(connectionId: UUID())
        store.remember(["Name": .column("full_name")], forFields: ["Name"], in: people)

        store.remember([:], forFields: ["Name"], in: people)

        #expect(store.overrides(for: people).isEmpty)
    }

    @Test("A second file layout into the same table keeps the first layout's choices")
    func secondLayoutKeepsTheFirst() throws {
        let store = try makeStore()
        let people = scope(connectionId: UUID())
        store.remember(["Name": .column("full_name")], forFields: ["Name"], in: people)

        store.remember(["Customer": .column("full_name")], forFields: ["Customer"], in: people)

        #expect(store.overrides(for: people) == ["Name": .column("full_name"), "Customer": .column("full_name")])
    }

    @Test("Renaming a table carries its choices to the new name")
    func renameTableMovesTheEntry() throws {
        let store = try makeStore()
        let connectionId = UUID()
        let old = scope(connectionId: connectionId, table: "people")
        let new = scope(connectionId: connectionId, table: "customers")
        store.remember(["Name": .column("full_name")], forFields: ["Name"], in: old)

        store.renameTable(from: old, to: new)

        #expect(store.overrides(for: old).isEmpty)
        #expect(store.overrides(for: new) == ["Name": .column("full_name")])
    }

    @Test("Renaming a database carries every table's choices")
    func renameContainerMovesEveryTable() throws {
        let store = try makeStore()
        let connectionId = UUID()
        let people = scope(connectionId: connectionId, database: "shop", table: "people")
        store.remember(["Name": .column("full_name")], forFields: ["Name"], in: people)

        store.renameContainer(
            connectionId: connectionId, fromDatabase: "shop", fromSchema: nil, toDatabase: "store", toSchema: nil
        )

        #expect(store.overrides(for: people).isEmpty)
        #expect(store.overrides(for: scope(connectionId: connectionId, database: "store")) == ["Name": .column("full_name")])
    }

    @Test("Dropping a table forgets its choices and leaves its siblings alone")
    func dropTableForgetsOnlyThatTable() throws {
        let store = try makeStore()
        let connectionId = UUID()
        let dropped = scope(connectionId: connectionId, table: "people")
        let kept = scope(connectionId: connectionId, table: "orders")
        store.remember(["Name": .column("full_name")], forFields: ["Name"], in: dropped)
        store.remember(["Total": .column("amount")], forFields: ["Total"], in: kept)

        store.dropTable(dropped)

        #expect(store.overrides(for: dropped).isEmpty)
        #expect(store.overrides(for: kept) == ["Total": .column("amount")])
    }

    @Test("Dropping a database forgets every table under it and nothing outside it")
    func dropContainerForgetsTheWholeDatabase() throws {
        let store = try makeStore()
        let connectionId = UUID()
        let inside = scope(connectionId: connectionId, database: "shop")
        let outside = scope(connectionId: connectionId, database: "archive")
        store.remember(["Name": .column("full_name")], forFields: ["Name"], in: inside)
        store.remember(["Name": .column("full_name")], forFields: ["Name"], in: outside)

        store.dropContainer(connectionId: connectionId, database: "shop", schema: nil)

        #expect(store.overrides(for: inside).isEmpty)
        #expect(store.overrides(for: outside) == ["Name": .column("full_name")])
    }

    @Test("Deleting a connection forgets its choices and nobody else's")
    func purgeForgetsOnlyThatConnection() throws {
        let store = try makeStore()
        let deleted = scope(connectionId: UUID())
        let kept = scope(connectionId: UUID())
        store.remember(["Name": .column("full_name")], forFields: ["Name"], in: deleted)
        store.remember(["Name": .column("full_name")], forFields: ["Name"], in: kept)

        store.purgeConnections([deleted.connectionId], leavesTombstones: true)

        #expect(store.overrides(for: deleted).isEmpty)
        #expect(store.overrides(for: kept) == ["Name": .column("full_name")])
    }
}
