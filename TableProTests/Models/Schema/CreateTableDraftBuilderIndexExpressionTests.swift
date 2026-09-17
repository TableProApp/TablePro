//
//  CreateTableDraftBuilderIndexExpressionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
@Suite("Create Table draft builder expression indexes")
struct CreateTableDraftBuilderIndexExpressionTests {
    private func column(_ name: String) -> EditableColumnDefinition {
        EditableColumnDefinition(
            id: UUID(), name: name, dataType: "TEXT", isNullable: true, defaultValue: nil,
            autoIncrement: false, unsigned: false, comment: nil, collation: nil,
            onUpdate: nil, charset: nil, extra: nil, isPrimaryKey: false
        )
    }

    private func plan(_ index: EditableIndexDefinition) -> CreateTablePlan {
        CreateTableDraftBuilder.plan(
            tableName: "users",
            options: CreateTableOptions(),
            columns: [column("tenant_id"), column("email"), column("name")],
            indexes: [index],
            foreignKeys: [],
            dialect: ForeignKeyDialect.forType(.postgresql),
            includesEngineOptions: false
        )
    }

    private func index(
        columns: [String],
        expressions: [String] = [],
        includedColumns: [String] = []
    ) -> EditableIndexDefinition {
        EditableIndexDefinition(
            id: UUID(), name: "users_idx", columns: columns, type: .btree, isUnique: false, isPrimary: false,
            comment: nil, expressions: expressions, includedColumns: includedColumns
        )
    }

    @Test("An expression key is not looked up as a column")
    func expressionKeyIsAccepted() {
        let result = plan(index(
            columns: ["tenant_id", "lower(email)"], expressions: ["lower(email)"], includedColumns: ["name"]
        ))
        #expect(result.issues.isEmpty)
        #expect(result.indexes.first?.expressions == ["lower(email)"])
        #expect(result.indexes.first?.includedColumns == ["name"])
    }

    @Test("A key entry that is not an expression still has to name a column")
    func unknownColumnIsStillReported() {
        let result = plan(index(columns: ["tenant_id", "lower(email)"]))
        #expect(result.issues.contains { $0.message == "The table has no column named lower(email)." })
    }

    @Test("An INCLUDE column the table does not have is reported")
    func unknownIncludedColumnIsReported() {
        let result = plan(index(columns: ["tenant_id"], includedColumns: ["nickname"]))
        #expect(result.issues.contains { $0.message == "The table has no column named nickname." })
    }
}
