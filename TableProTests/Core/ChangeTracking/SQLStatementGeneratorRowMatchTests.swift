//
//  SQLStatementGeneratorRowMatchTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("SQL Statement Generator: keyless row match exclusions")
@MainActor
struct SQLStatementGeneratorRowMatchTests {
    private let columns = ["id", "name", "payload", "tags"]
    private let originalRow: [PluginCellValue] = ["1", "a", "{\"k\":1}", "[1,2]"]

    private func generator(excluding excluded: Set<String>) throws -> SQLStatementGenerator {
        try SQLStatementGenerator(
            tableName: "t",
            columns: columns,
            primaryKeyColumns: [],
            databaseType: .databend,
            rowMatchExcludedColumns: excluded,
            quoteIdentifier: { "`\($0)`" }
        )
    }

    @Test("An update matches on every column the engine can compare, and none it cannot")
    func updateLeavesExcludedColumnsOut() throws {
        let change = RowChange(
            rowID: .existing(0),
            type: .update,
            cellChanges: [CellChange(columnIndex: 1, columnName: "name", oldValue: "a", newValue: "b")],
            originalRow: originalRow
        )
        let statement = try #require(try generator(excluding: ["payload", "tags"]).generateUpdateSQL(for: change))
        #expect(statement.sql == "UPDATE `t` SET `name` = ? WHERE `id` = ? AND `name` = ?")
        #expect(statement.parameters.count == 3)
    }

    @Test("A delete matches the same way")
    func deleteLeavesExcludedColumnsOut() throws {
        let change = RowChange(rowID: .existing(0), type: .delete, cellChanges: [], originalRow: originalRow)
        let statements = try generator(excluding: ["payload", "tags"]).generateStatements(
            from: [change], insertedRowData: [:], deletedRowIDs: [.existing(0)], insertedRowIDs: []
        )
        #expect(statements.map(\.sql) == ["DELETE FROM `t` WHERE (`id` = ? AND `name` = ?)"])
    }

    @Test("When columns are left out, each keyless delete is its own statement so each is counted")
    func keylessDeletesAreNotBatched() throws {
        let other: [PluginCellValue] = ["2", "b", "{}", "[]"]
        let changes = [
            RowChange(rowID: .existing(0), type: .delete, cellChanges: [], originalRow: originalRow),
            RowChange(rowID: .existing(1), type: .delete, cellChanges: [], originalRow: other)
        ]
        let statements = try generator(excluding: ["payload", "tags"]).generateAttributedStatements(
            from: changes, insertedRowData: [:], deletedRowIDs: [.existing(0), .existing(1)], insertedRowIDs: []
        )
        #expect(statements.count == 2)
        #expect(statements.allSatisfy { $0.rowCount == 1 && !$0.statement.sql.contains(" OR ") })
    }

    @Test("A Databend row left entirely on defaults names one column with DEFAULT")
    func databendAllDefaultsInsert() throws {
        let change = RowChange(rowID: .existing(0), type: .insert, cellChanges: [], originalRow: nil)
        let statements = try generator(excluding: []).generateStatements(
            from: [change],
            insertedRowData: [.existing(0): [.text("__DEFAULT__"), .text("__DEFAULT__"), .text("__DEFAULT__"), .text("__DEFAULT__")]],
            deletedRowIDs: [],
            insertedRowIDs: [.existing(0)]
        )
        #expect(statements.map(\.sql) == ["INSERT INTO `t` (`id`) VALUES (DEFAULT)"])
    }

    @Test("With nothing excluded, every column still identifies the row")
    func noExclusionsKeepsEveryColumn() throws {
        let change = RowChange(rowID: .existing(0), type: .delete, cellChanges: [], originalRow: originalRow)
        let statements = try generator(excluding: []).generateStatements(
            from: [change], insertedRowData: [:], deletedRowIDs: [.existing(0)], insertedRowIDs: []
        )
        #expect(statements.first?.sql.contains("`payload` = ?") == true)
        #expect(statements.first?.sql.contains("`tags` = ?") == true)
    }

    @Test("A delete whose every column is excluded is refused, not dropped")
    func unidentifiableDeleteIsRefused() {
        let factory = RowChangeStatementFactory(
            tableName: "t",
            schemaName: nil,
            columns: ["payload", "tags"],
            primaryKeyColumns: [],
            rowMatchExcludedColumns: ["payload", "tags"],
            databaseType: .mysql,
            pluginDriver: nil
        )
        let change = RowChange(rowID: .existing(0), type: .delete, cellChanges: [], originalRow: ["{}", "[]"])
        #expect(throws: DataWriteError.self) {
            _ = try factory.statements(for: [change], deletedRowIDs: [.existing(0)])
        }
    }

    @Test("The schema names the excluded columns from the engine's type prefixes")
    func schemaDerivesExclusions() {
        let columns = [
            ColumnInfo(name: "id", dataType: "INT", isNullable: false, isPrimaryKey: false, defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil),
            ColumnInfo(name: "tags", dataType: "ARRAY(INT32)", isNullable: true, isPrimaryKey: false, defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil),
            ColumnInfo(name: "doc", dataType: "variant", isNullable: true, isPrimaryKey: false, defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil),
        ]
        #expect(QueryExecutor.rowMatchExcludedColumns(in: columns, typePrefixes: ["ARRAY", "VARIANT"]) == ["tags", "doc"])
        #expect(QueryExecutor.rowMatchExcludedColumns(in: columns, typePrefixes: []).isEmpty)
    }
}
