//
//  CrossEngineIndexExpressionTests.swift
//  TableProTests
//
//  A PostgreSQL index over an expression, or with INCLUDE columns or the server's own spellings,
//  copied to another engine.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Cross-engine index expressions and spellings")
struct CrossEngineIndexExpressionTests {
    private static func column(_ name: String, _ type: String = "integer") -> EditableColumnDefinition {
        EditableColumnDefinition(
            id: UUID(), name: name, dataType: type, isNullable: true, defaultValue: nil, autoIncrement: false,
            unsigned: false, comment: nil, collation: nil, onUpdate: nil, charset: nil, extra: nil,
            isPrimaryKey: false
        )
    }

    private static func index(
        _ name: String,
        columns: [String],
        whereClause: String? = nil,
        expressions: [String] = [],
        includedColumns: [String] = [],
        ddlMethodAndKeys: String? = nil,
        ddlWhereClause: String? = nil
    ) -> EditableIndexDefinition {
        EditableIndexDefinition(
            id: UUID(), name: name, columns: columns, type: .btree, isUnique: false, isPrimary: false,
            comment: nil, whereClause: whereClause, expressions: expressions, includedColumns: includedColumns,
            ddlMethodAndKeys: ddlMethodAndKeys, ddlWhereClause: ddlWhereClause
        )
    }

    private static func snapshot(_ indexes: [EditableIndexDefinition]) -> TableStructureSnapshot {
        TableStructureSnapshot(
            name: "users",
            schema: "public",
            columns: [column("tenant_id"), column("email", "varchar(255)"), column("name", "varchar(80)")],
            indexes: indexes
        )
    }

    @Test("An index over an expression is left out of another engine's copy, with a note")
    func expressionIndexIsDropped() throws {
        let result = CrossEngineStructureTranslator.translate(
            Self.snapshot([
                Self.index("users_tenant_lower_email", columns: ["tenant_id", "lower(email)"], expressions: ["lower(email)"]),
                Self.index("users_tenant", columns: ["tenant_id"])
            ]),
            from: .postgresql,
            to: .mysql
        )
        #expect(result.snapshot.indexes.map(\.name) == ["users_tenant"])
        let note = try #require(result.notes.first { $0.subject == "users_tenant_lower_email" })
        #expect(note.summary == "The index users_tenant_lower_email is left out")
        #expect(note.reason.contains("lower(email)"))
    }

    @Test("INCLUDE columns are left out of another engine's copy, with a note, and the key is kept")
    func includedColumnsAreDropped() throws {
        let result = CrossEngineStructureTranslator.translate(
            Self.snapshot([Self.index("users_include", columns: ["tenant_id"], includedColumns: ["name"])]),
            from: .postgresql,
            to: .mysql
        )
        let index = try #require(result.snapshot.indexes.first)
        #expect(index.columns == ["tenant_id"])
        #expect(index.includedColumns.isEmpty)
        let note = try #require(result.notes.first { $0.subject == "users_include" })
        #expect(note.reason.contains("name"))
    }

    @Test("A translated index carries none of the source server's spellings")
    func translatedIndexDropsSpellings() throws {
        let result = CrossEngineStructureTranslator.translate(
            Self.snapshot([
                Self.index(
                    "users_partial",
                    columns: ["tenant_id"],
                    whereClause: "(tenant_id > 0)",
                    ddlMethodAndKeys: "USING btree (tenant_id)",
                    ddlWhereClause: "(tenant_id > 0)"
                )
            ]),
            from: .postgresql,
            to: .duckdb
        )
        let index = try #require(result.snapshot.indexes.first)
        #expect(index.whereClause == "(tenant_id > 0)")
        #expect(index.ddlMethodAndKeys == nil)
        #expect(index.ddlWhereClause == nil)
    }

    @Test("A same-engine copy keeps the expression, the INCLUDE columns and the spellings")
    func sameEngineKeepsEverything() throws {
        let result = CrossEngineStructureTranslator.translate(
            Self.snapshot([
                Self.index(
                    "users_tenant_lower_email",
                    columns: ["tenant_id", "lower(email)"],
                    expressions: ["lower(email)"],
                    includedColumns: ["name"],
                    ddlMethodAndKeys: "USING btree (tenant_id, lower(email)) INCLUDE (name)"
                )
            ]),
            from: .postgresql,
            to: .postgresql
        )
        let index = try #require(result.snapshot.indexes.first)
        #expect(result.notes.isEmpty)
        #expect(index.expressions == ["lower(email)"])
        #expect(index.includedColumns == ["name"])
        #expect(index.ddlMethodAndKeys == "USING btree (tenant_id, lower(email)) INCLUDE (name)")
    }
}
