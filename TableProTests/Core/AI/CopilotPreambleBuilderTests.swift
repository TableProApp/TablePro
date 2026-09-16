//
//  CopilotPreambleBuilderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Copilot schema preamble")
@MainActor
struct CopilotPreambleBuilderTests {
    /// The preamble fetched every table's columns with no schema and keyed them by the bare name,
    /// so a table outside the current schema listed nothing or its namesake's columns.
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
        await builder.buildPreamble(schemaProvider: provider, databaseName: "shop", databaseType: .mysql)

        let lines = builder.preamble.split(separator: "\n").map(String.init)
        #expect(lines.contains("-- sales.orders(amount DECIMAL PK NOT NULL)"))
        #expect(lines.contains("-- hr.orders(salary INT PK NOT NULL)"))
    }
}
