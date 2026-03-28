//
//  BigQueryStatementGeneratorTests.swift
//  TableProTests
//
//  Tests for BigQueryStatementGenerator (compiled via symlink from BigQueryDriverPlugin).
//

import Foundation
import TableProPluginKit
import Testing

@Suite("BigQueryStatementGenerator - INSERT")
struct BigQueryStatementGeneratorInsertTests {
    @Test("Generates INSERT with correct table quoting")
    func basicInsert() {
        let gen = BigQueryStatementGenerator(
            projectId: "myproj", dataset: "mydata", tableName: "users",
            columns: ["id", "name", "age"],
            columnTypeNames: ["INT64", "STRING", "INT64"]
        )
        let change = PluginRowChange(
            rowIndex: 0, type: .insert,
            cellChanges: [
                (columnIndex: 0, columnName: "id", oldValue: nil, newValue: "1"),
                (columnIndex: 1, columnName: "name", oldValue: nil, newValue: "Alice"),
                (columnIndex: 2, columnName: "age", oldValue: nil, newValue: "30")
            ],
            originalRow: nil
        )
        let result = gen.generateStatements(
            from: [change], insertedRowData: [0: ["1", "Alice", "30"]],
            deletedRowIndices: [], insertedRowIndices: [0]
        )
        #expect(result.count == 1)
        let sql = result[0].statement
        #expect(sql.contains("`myproj.mydata.users`"))
        #expect(sql.contains("INSERT INTO"))
        #expect(sql.contains("1"))
        #expect(sql.contains("'Alice'"))
        #expect(sql.contains("30"))
    }

    @Test("INT64 values are unquoted")
    func numericInsert() {
        let gen = BigQueryStatementGenerator(
            projectId: "p", dataset: "d", tableName: "t",
            columns: ["val"],
            columnTypeNames: ["INT64"]
        )
        let change = PluginRowChange(
            rowIndex: 0, type: .insert,
            cellChanges: [(columnIndex: 0, columnName: "val", oldValue: nil, newValue: "42")],
            originalRow: nil
        )
        let result = gen.generateStatements(
            from: [change], insertedRowData: [0: ["42"]],
            deletedRowIndices: [], insertedRowIndices: [0]
        )
        let sql = result[0].statement
        #expect(sql.contains("VALUES (42)"))
    }

    @Test("NULL values generate NULL keyword")
    func nullInsert() {
        let gen = BigQueryStatementGenerator(
            projectId: "p", dataset: "d", tableName: "t",
            columns: ["a", "b"],
            columnTypeNames: ["STRING", "STRING"]
        )
        let change = PluginRowChange(
            rowIndex: 0, type: .insert,
            cellChanges: [
                (columnIndex: 0, columnName: "a", oldValue: nil, newValue: "val"),
                (columnIndex: 1, columnName: "b", oldValue: nil, newValue: nil)
            ],
            originalRow: nil
        )
        let result = gen.generateStatements(
            from: [change], insertedRowData: [0: ["val", nil]],
            deletedRowIndices: [], insertedRowIndices: [0]
        )
        let sql = result[0].statement
        #expect(sql.contains("NULL"))
    }

    @Test("BOOL values format as TRUE/FALSE")
    func boolInsert() {
        let gen = BigQueryStatementGenerator(
            projectId: "p", dataset: "d", tableName: "t",
            columns: ["flag"],
            columnTypeNames: ["BOOL"]
        )
        let change = PluginRowChange(
            rowIndex: 0, type: .insert,
            cellChanges: [(columnIndex: 0, columnName: "flag", oldValue: nil, newValue: "true")],
            originalRow: nil
        )
        let result = gen.generateStatements(
            from: [change], insertedRowData: [0: ["true"]],
            deletedRowIndices: [], insertedRowIndices: [0]
        )
        #expect(result[0].statement.contains("TRUE"))
    }
}

@Suite("BigQueryStatementGenerator - UPDATE")
struct BigQueryStatementGeneratorUpdateTests {
    @Test("Generates UPDATE with SET and WHERE")
    func basicUpdate() {
        let gen = BigQueryStatementGenerator(
            projectId: "p", dataset: "d", tableName: "users",
            columns: ["id", "name"],
            columnTypeNames: ["INT64", "STRING"]
        )
        let change = PluginRowChange(
            rowIndex: 0, type: .update,
            cellChanges: [(columnIndex: 1, columnName: "name", oldValue: "Alice", newValue: "Bob")],
            originalRow: ["1", "Alice"]
        )
        let result = gen.generateStatements(
            from: [change], insertedRowData: [:],
            deletedRowIndices: [], insertedRowIndices: []
        )
        #expect(result.count == 1)
        let sql = result[0].statement
        #expect(sql.contains("UPDATE `p.d.users`"))
        #expect(sql.contains("SET `name` = 'Bob'"))
        #expect(sql.contains("WHERE `id` = 1 AND `name` = 'Alice'"))
    }

    @Test("Skips STRUCT/ARRAY columns in WHERE clause")
    func skipsComplexTypesInWhere() {
        let gen = BigQueryStatementGenerator(
            projectId: "p", dataset: "d", tableName: "t",
            columns: ["id", "metadata", "tags"],
            columnTypeNames: ["INT64", "STRUCT<a INT64>", "ARRAY<STRING>"]
        )
        let change = PluginRowChange(
            rowIndex: 0, type: .update,
            cellChanges: [(columnIndex: 0, columnName: "id", oldValue: "1", newValue: "2")],
            originalRow: ["1", "{\"a\":1}", "[\"tag1\"]"]
        )
        let result = gen.generateStatements(
            from: [change], insertedRowData: [:],
            deletedRowIndices: [], insertedRowIndices: []
        )
        let sql = result[0].statement
        #expect(sql.contains("`id` = 1"))
        #expect(!sql.contains("`metadata`"))
        #expect(!sql.contains("`tags`"))
    }

    @Test("NULL original values use IS NULL in WHERE")
    func nullInWhere() {
        let gen = BigQueryStatementGenerator(
            projectId: "p", dataset: "d", tableName: "t",
            columns: ["id", "note"],
            columnTypeNames: ["INT64", "STRING"]
        )
        let change = PluginRowChange(
            rowIndex: 0, type: .update,
            cellChanges: [(columnIndex: 1, columnName: "note", oldValue: nil, newValue: "hello")],
            originalRow: ["1", nil]
        )
        let result = gen.generateStatements(
            from: [change], insertedRowData: [:],
            deletedRowIndices: [], insertedRowIndices: []
        )
        let sql = result[0].statement
        #expect(sql.contains("`note` IS NULL"))
    }
}

@Suite("BigQueryStatementGenerator - DELETE")
struct BigQueryStatementGeneratorDeleteTests {
    @Test("Generates DELETE with WHERE from original row")
    func basicDelete() {
        let gen = BigQueryStatementGenerator(
            projectId: "p", dataset: "d", tableName: "t",
            columns: ["id", "name"],
            columnTypeNames: ["INT64", "STRING"]
        )
        let change = PluginRowChange(
            rowIndex: 0, type: .delete,
            cellChanges: [],
            originalRow: ["42", "Alice"]
        )
        let result = gen.generateStatements(
            from: [change], insertedRowData: [:],
            deletedRowIndices: [0], insertedRowIndices: []
        )
        #expect(result.count == 1)
        let sql = result[0].statement
        #expect(sql.contains("DELETE FROM `p.d.t`"))
        #expect(sql.contains("`id` = 42"))
        #expect(sql.contains("`name` = 'Alice'"))
    }

    @Test("DELETE without original row is skipped")
    func deleteWithoutOriginalRow() {
        let gen = BigQueryStatementGenerator(
            projectId: "p", dataset: "d", tableName: "t",
            columns: ["id"],
            columnTypeNames: ["INT64"]
        )
        let change = PluginRowChange(
            rowIndex: 0, type: .delete,
            cellChanges: [],
            originalRow: nil
        )
        let result = gen.generateStatements(
            from: [change], insertedRowData: [:],
            deletedRowIndices: [0], insertedRowIndices: []
        )
        #expect(result.isEmpty)
    }
}

@Suite("BigQueryStatementGenerator - String Escaping")
struct BigQueryStatementGeneratorEscapingTests {
    @Test("Single quotes in values are escaped with doubling")
    func singleQuoteEscaping() {
        let gen = BigQueryStatementGenerator(
            projectId: "p", dataset: "d", tableName: "t",
            columns: ["name"],
            columnTypeNames: ["STRING"]
        )
        let change = PluginRowChange(
            rowIndex: 0, type: .insert,
            cellChanges: [(columnIndex: 0, columnName: "name", oldValue: nil, newValue: "O'Brien")],
            originalRow: nil
        )
        let result = gen.generateStatements(
            from: [change], insertedRowData: [0: ["O'Brien"]],
            deletedRowIndices: [], insertedRowIndices: [0]
        )
        #expect(result[0].statement.contains("O''Brien"))
    }

    @Test("FLOAT64 values are unquoted")
    func floatUnquoted() {
        let gen = BigQueryStatementGenerator(
            projectId: "p", dataset: "d", tableName: "t",
            columns: ["score"],
            columnTypeNames: ["FLOAT64"]
        )
        let change = PluginRowChange(
            rowIndex: 0, type: .insert,
            cellChanges: [(columnIndex: 0, columnName: "score", oldValue: nil, newValue: "3.14")],
            originalRow: nil
        )
        let result = gen.generateStatements(
            from: [change], insertedRowData: [0: ["3.14"]],
            deletedRowIndices: [], insertedRowIndices: [0]
        )
        #expect(result[0].statement.contains("VALUES (3.14)"))
    }
}
