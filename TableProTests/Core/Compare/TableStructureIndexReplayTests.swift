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

    /// What PostgreSQLIndexRow reads from PostgreSQL 17.11's catalog for the probe schema. PostgreSQLDriverTests'
    /// PostgreSQLIndexReplayTests holds the plugin to writing `CREATE INDEX` from these spellings.
    private static let catalogIndexes = [
        PluginIndexInfo(
            name: "users_tenant_lower_email", columns: ["tenant_id", "lower(email)"], isUnique: true,
            expressions: ["lower(email)"], includedColumns: nil,
            ddlMethodAndKeys: "USING btree (tenant_id, lower(email))", ddlWhereClause: nil
        ),
        PluginIndexInfo(
            name: "users_email_trgm", columns: ["email"], type: "GIN",
            expressions: nil, includedColumns: nil,
            ddlMethodAndKeys: "USING gin (email public.gin_trgm_ops)", ddlWhereClause: nil
        ),
        PluginIndexInfo(
            name: "users_partial_fn", columns: ["id"], whereClause: "st_isvalid(shape)",
            expressions: nil, includedColumns: nil,
            ddlMethodAndKeys: "USING btree (id)", ddlWhereClause: "public.st_isvalid(shape)"
        )
    ]

    /// Measured on PostgreSQL 17.11: written from these spellings under `search_path = dst`, each index came back
    /// identical, where the field-built statement lost the expression key and the gin operator class.
    @Test("An index read from the catalog reaches the driver with the server's own spelling")
    func catalogIndexReplaysItsSpelling() {
        let written = Self.snapshot(Self.catalogIndexes).indexes.map { $0.toPlugin() }

        #expect(written.map(\.name) == ["users_tenant_lower_email", "users_email_trgm", "users_partial_fn"])
        #expect(written.map(\.isUnique) == [true, false, false])
        #expect(written.map(\.ddlMethodAndKeys) == [
            "USING btree (tenant_id, lower(email))",
            "USING gin (email public.gin_trgm_ops)",
            "USING btree (id)"
        ])
        #expect(written.map(\.ddlWhereClause) == [nil, nil, "public.st_isvalid(shape)"])
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
