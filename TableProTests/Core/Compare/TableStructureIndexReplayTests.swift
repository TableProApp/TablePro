//
//  TableStructureIndexReplayTests.swift
//  TableProTests
//
//  A PostgreSQL index read into a table snapshot, compared, and written back as the `CREATE INDEX`
//  a Copy To runs. The catalog rows are the ones PostgreSQL 17.11 returned on a probe schema.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct TableStructureIndexReplayTests {
    private static let table = PluginTableInfo(name: "users", schema: "src", comment: nil)

    private static func snapshot(_ indexes: [PluginIndexInfo]) -> TableStructureSnapshot {
        TableStructureSnapshot.from(table: table, columns: [], indexes: indexes, foreignKeys: [])
    }

    private static func editable(
        _ name: String,
        columns: [String],
        expressions: [String] = [],
        includedColumns: [String] = []
    ) -> EditableIndexDefinition {
        EditableIndexDefinition(
            id: UUID(), name: name, columns: columns, type: .btree, isUnique: false, isPrimary: false,
            comment: nil, expressions: expressions, includedColumns: includedColumns
        )
    }

    private static func structure(_ indexes: [EditableIndexDefinition]) -> TableStructureSnapshot {
        TableStructureSnapshot(name: "users", columns: [], indexes: indexes)
    }

    /// Measured on PostgreSQL 17.11: the statement below, run under `search_path = dst`, recreated the
    /// index identically. The field-built one it replaces wrote `UNIQUE (tenant_id)`, which refused two
    /// rows the source accepts, and `USING gin ("email")` with no operator class, which the server
    /// refused outright.
    @Test("An index read from the catalog is written back from the server's own spelling")
    func catalogIndexReplaysItsSpelling() throws {
        let ddl = PostgreSQLIndexQueries.indexDDL(rows: [
            [.text("users"), .text("users_tenant_lower_email"), .text("USING btree (tenant_id, lower(email))"), .null],
            [.text("users"), .text("users_email_trgm"), .text("USING gin (email public.gin_trgm_ops)"), .null],
            [.text("users"), .text("users_partial_fn"), .text("USING btree (id)"), .text("public.st_isvalid(shape)")]
        ])
        let rows: [[PluginCellValue]] = [
            [
                .text("users"), .text("users_tenant_lower_email"), .text("{tenant_id,lower(email)}"), .text("true"),
                .text("false"), .text("btree"), .null, .text("{lower(email)}"), .text("{}")
            ],
            [
                .text("users"), .text("users_email_trgm"), .text("{email}"), .text("false"), .text("false"),
                .text("gin"), .null, .text("{}"), .text("{}")
            ],
            [
                .text("users"), .text("users_partial_fn"), .text("{id}"), .text("false"), .text("false"),
                .text("btree"), .text("st_isvalid(shape)"), .text("{}"), .text("{}")
            ]
        ]
        let indexes = rows.compactMap { PostgreSQLIndexRow.index(from: $0, ddl: ddl)?.index }
        let statements = Self.snapshot(indexes).indexes.map {
            PostgreSQLIndexClauses.createStatement(for: $0.toPlugin(), qualifiedTable: #""dst"."users""#)
        }
        #expect(statements == [
            #"CREATE UNIQUE INDEX "users_tenant_lower_email" ON "dst"."users" USING btree (tenant_id, lower(email))"#,
            #"CREATE INDEX "users_email_trgm" ON "dst"."users" USING gin (email public.gin_trgm_ops)"#,
            #"CREATE INDEX "users_partial_fn" ON "dst"."users" USING btree (id) WHERE public.st_isvalid(shape)"#
        ])
    }

    @Test("An index that differs only in its INCLUDE columns is a real change")
    func includeDifferenceIsAChange() {
        let result = StructureDiffEngine().compareTable(
            source: Self.structure([Self.editable("i", columns: ["a"], includedColumns: ["b"])]),
            target: Self.structure([Self.editable("i", columns: ["a"])])
        )
        #expect(result.changes.count == 2)
    }

    @Test("An INCLUDE column is not the same index as a second key column")
    func includeIsNotAKeyColumn() {
        let result = StructureDiffEngine().compareTable(
            source: Self.structure([Self.editable("i", columns: ["a"], includedColumns: ["b"])]),
            target: Self.structure([Self.editable("i", columns: ["a", "b"])])
        )
        #expect(result.changes.count == 2)
    }

    @Test("An expression key and a column of a similar name are different indexes")
    func expressionDiffersFromColumn() {
        let result = StructureDiffEngine().compareTable(
            source: Self.structure([Self.editable("i", columns: ["lower(email)"], expressions: ["lower(email)"])]),
            target: Self.structure([Self.editable("i", columns: ["email"])])
        )
        #expect(result.changes.count == 2)
    }

    @Test("The rendered definition lists INCLUDE columns")
    func renderedDefinitionListsInclude() {
        let lines = TableDefinitionRenderer.lines(
            for: Self.structure([Self.editable("i", columns: ["a"], includedColumns: ["b", "c"])])
        )
        #expect(lines.contains("  INDEX i (a) USING BTREE INCLUDE (b, c)"))
    }
}
