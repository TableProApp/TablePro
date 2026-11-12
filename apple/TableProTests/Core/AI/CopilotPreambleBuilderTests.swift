//
//  CopilotPreambleBuilderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class FetchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    func increment() {
        lock.withLock { value += 1 }
    }
}

@MainActor
struct CopilotPreambleBuilderTests {
    @Test("same-named tables in two schemas each list their own columns under a qualified name")
    func sameNamedTablesInTwoSchemasListTheirOwnColumns() async {
        let columnsBySchema: [String: [ColumnInfo]] = [
            "sales": [TestFixtures.makeColumnInfo(name: "amount", dataType: "DECIMAL")],
            "hr": [TestFixtures.makeColumnInfo(name: "salary", dataType: "INT")]
        ]
        let source = SQLSchemaProvider.ColumnMetadataSource(
            fetchColumns: { _, schema in schema.flatMap { columnsBySchema[$0] } ?? [] },
            fetchAllColumns: { [:] }
        )
        let provider = SQLSchemaProvider(metadataSource: source)
        await provider.resetForDatabase(
            "shop",
            tables: [
                TestFixtures.makeTableInfo(name: "orders", schema: "sales"),
                TestFixtures.makeTableInfo(name: "orders", schema: "hr")
            ],
            driver: MockDatabaseDriver(),
            connection: TestFixtures.makeConnection()
        )
        await provider.waitForEagerColumnLoad()

        let builder = CopilotPreambleBuilder()
        await builder.buildPreamble(schemaProvider: provider, databaseName: "shop", databaseType: .mysql, maxTables: 20)

        let lines = builder.preamble.split(separator: "\n").map(String.init)
        #expect(lines.contains("-- sales.orders(amount DECIMAL PK NOT NULL)"))
        #expect(lines.contains("-- hr.orders(salary INT PK NOT NULL)"))
    }

    @Test("a large catalog reads columns for the table budget only, the document's tables first, one line per table")
    func largeCatalogReadsColumnsForTheBudgetOnly() async throws {
        let fetches = FetchCounter()
        let columns = [TestFixtures.makeColumnInfo(name: "id")]
        let source = SQLSchemaProvider.ColumnMetadataSource(
            fetchColumns: { _, _ in
                fetches.increment()
                return columns
            },
            fetchAllColumns: { [:] }
        )
        let provider = SQLSchemaProvider(metadataSource: source)
        let tables = [TestFixtures.makeTableInfo(name: "line\nbreak")]
            + (1..<2_000).map { TestFixtures.makeTableInfo(name: "table_\($0)") }
        await provider.resetForDatabase(
            "shop",
            tables: tables,
            driver: MockDatabaseDriver(),
            connection: TestFixtures.makeConnection()
        )
        await provider.waitForEagerColumnLoad()
        let fetchesBefore = fetches.count

        let builder = CopilotPreambleBuilder()
        await builder.buildPreamble(
            schemaProvider: provider,
            databaseName: "shop",
            databaseType: .mysql,
            referencing: "SELECT * FROM table_1500 t JOIN table_1999 u ON u.id = t.id;",
            maxTables: 20
        )

        #expect(fetches.count - fetchesBefore <= 20)
        let lines = builder.preamble.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        try #require(lines.count == 25)
        #expect(lines[3].hasPrefix("-- table_1500("))
        #expect(lines[4].hasPrefix("-- table_1999("))
        #expect(lines[5] == "-- line break(id INT PK NOT NULL)")
        #expect(lines[23] == "-- … and 1980 more tables")
        #expect(builder.preambleLineCount == 24)
    }
}
