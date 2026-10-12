//
//  CachedColumnOrderTests.swift
//  TableProTests
//
//  `allColumnsFromCachedTables` used to walk its cache as a Dictionary. That order is seeded per
//  process and shifts again on an insert, and `rankResults` falls back to emission position for
//  candidates that score the same, so which of two equally ranked columns Return committed changed
//  between launches.
//

import Foundation
@testable import TablePro
import Testing

struct CachedColumnOrderTests {
    private func loadedProvider(
        tables: [(name: String, schema: String?, columns: [String])]
    ) async -> SQLSchemaProvider {
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = tables.map { TestFixtures.makeTableInfo(name: $0.name, schema: $0.schema) }
        driver.columnsToReturn = Dictionary(
            uniqueKeysWithValues: tables.map { table in
                (table.name, table.columns.map { TestFixtures.makeColumnInfo(name: $0) })
            }
        )

        let provider = SQLSchemaProvider()
        await provider.loadSchema(using: driver, connection: TestFixtures.makeConnection())
        for table in tables {
            _ = await provider.getColumns(for: table.name, schema: table.schema)
        }
        return provider
    }

    /// Declared deliberately out of alphabetical order, so a walk that kept insertion or hash order
    /// would not produce the expected sequence by accident.
    @Test("Columns come back grouped by table in a stable order")
    func emissionOrderIsSortedByTable() async {
        let provider = await loadedProvider(tables: [
            (name: "zeta", schema: nil, columns: ["z_one", "z_two"]),
            (name: "alpha", schema: nil, columns: ["a_one"]),
            (name: "mid", schema: nil, columns: ["m_one"])
        ])

        let labels = await provider.allColumnsFromCachedTables().map(\.label)
        #expect(labels == ["a_one", "m_one", "z_one", "z_two"])
    }

    @Test("A schema-qualified table sorts by schema first")
    func schemaSortsAheadOfName() async {
        let provider = await loadedProvider(tables: [
            (name: "widgets", schema: "sales", columns: ["s_widget"]),
            (name: "aardvark", schema: "zoo", columns: ["z_aardvark"]),
            (name: "orders", schema: nil, columns: ["plain_order"])
        ])

        let labels = await provider.allColumnsFromCachedTables().map(\.label)
        #expect(labels == ["plain_order", "s_widget", "z_aardvark"])
    }

    /// The defect that made the order matter: two columns that score identically for the same
    /// prefix, where position is the only thing left to separate them.
    @Test("Two equally ranked columns keep the same winner across repeated reads")
    func equallyRankedColumnsAreStable() async {
        let provider = await loadedProvider(tables: [
            (name: "users", schema: nil, columns: ["id"]),
            (name: "logs", schema: nil, columns: ["ip"])
        ])

        let first = await provider.allColumnsFromCachedTables().map(\.label)
        #expect(first == ["ip", "id"], "logs sorts before users, so its column is emitted first")

        for _ in 0..<5 {
            let again = await provider.allColumnsFromCachedTables().map(\.label)
            #expect(again == first)
        }
    }

    @Test("An empty cache still returns nothing")
    func emptyCacheReturnsNothing() async {
        let provider = SQLSchemaProvider()
        #expect(await provider.allColumnsFromCachedTables().isEmpty)
    }
}
