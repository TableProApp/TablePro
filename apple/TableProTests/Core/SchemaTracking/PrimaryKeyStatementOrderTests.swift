//
//  PrimaryKeyStatementOrderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class KeyDDLDriver: PluginDriverStub, @unchecked Sendable {
    var isConnected: Bool { true }
    var currentSchema: String? { "public" }

    func ping() async throws {}
    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func generateDropColumnSQL(table: String, columnName: String) -> String? {
        "ALTER TABLE \(table) DROP COLUMN \(columnName)"
    }

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        "ALTER TABLE \(table) ADD COLUMN \(column.name)"
    }

    func generateModifyPrimaryKeySQL(table: String, oldColumns: [String], newColumns: [String], constraintName: String?) -> [String]? {
        var statements: [String] = []
        if !oldColumns.isEmpty { statements.append("ALTER TABLE \(table) DROP CONSTRAINT \(constraintName ?? "pk")") }
        if !newColumns.isEmpty { statements.append("ALTER TABLE \(table) ADD PRIMARY KEY (\(newColumns.joined(separator: ", ")))") }
        return statements
    }
}

struct PrimaryKeyStatementOrderTests {
    private func column(_ name: String) -> EditableColumnDefinition {
        EditableColumnDefinition.from(ColumnInfo(name: name, dataType: "INT", isNullable: false, isPrimaryKey: false))
    }

    // Dropping a key column drops the key with it, so the key's own DROP has to run first.
    @Test("A key that loses a dropped column is dropped before the column and added after the new columns")
    func keyDropRunsBeforeTheColumnDrop() throws {
        let statements = try SchemaStatementGenerator(tableName: "orders", pluginDriver: KeyDDLDriver())
            .generate(changes: [
                .deleteColumn(column("a")),
                .addColumn(column("c")),
                .modifyPrimaryKey(old: ["a"], new: ["b", "c"]),
            ])
            .map(\.sql)

        #expect(statements == [
            "ALTER TABLE orders DROP CONSTRAINT pk;",
            "ALTER TABLE orders DROP COLUMN a;",
            "ALTER TABLE orders ADD COLUMN c;",
            "ALTER TABLE orders ADD PRIMARY KEY (b, c);",
        ])
    }

    @Test("A key change that drops no key column stays one change after the columns")
    func keyChangeWithoutDroppedColumnStaysWhole() throws {
        let statements = try SchemaStatementGenerator(tableName: "orders", pluginDriver: KeyDDLDriver())
            .generate(changes: [.modifyPrimaryKey(old: ["a"], new: ["a", "b"])])
            .map(\.sql)

        #expect(statements == [
            "ALTER TABLE orders DROP CONSTRAINT pk;",
            "ALTER TABLE orders ADD PRIMARY KEY (a, b);",
        ])
    }
}
