//
//  DynamoDBStatementGeneratorTests.swift
//  TableProTests
//
//  Tests for DynamoDBStatementGenerator (compiled via symlink from DynamoDBDriverPlugin).
//

import Foundation
import Testing
import TableProPluginKit

@Suite("DynamoDB Statement Generator")
struct DynamoDBStatementGeneratorTests {

    private func makeGenerator(
        table: String = "TestTable",
        columns: [String] = ["id", "name", "age"],
        columnTypeNames: [String] = ["S", "S", "N"],
        keySchema: [(name: String, keyType: String)] = [("id", "HASH")]
    ) -> DynamoDBStatementGenerator {
        DynamoDBStatementGenerator(
            tableName: table,
            columns: columns,
            columnTypeNames: columnTypeNames,
            keySchema: keySchema
        )
    }

    private func insertChange(
        rowIndex: Int = 0
    ) -> PluginRowChange {
        PluginRowChange(
            rowIndex: rowIndex,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )
    }

    // MARK: - INSERT

    @Test("Basic insert with string columns")
    func basicInsert() throws {
        let gen = makeGenerator(
            columns: ["id", "name"],
            columnTypeNames: ["S", "S"],
            keySchema: [("id", "HASH")]
        )

        let results = try gen.generateStatements(
            from: [insertChange()],
            insertedRowData: [0: ["pk1", "Alice"]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "INSERT INTO \"TestTable\" VALUE { 'id': 'pk1', 'name': 'Alice' }")
    }

    @Test("Insert with number type produces unquoted value")
    func insertWithNumber() throws {
        let gen = makeGenerator()

        let results = try gen.generateStatements(
            from: [insertChange()],
            insertedRowData: [0: ["pk1", "Alice", "30"]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement.contains("'age': 30"))
    }

    @Test("Insert with boolean type")
    func insertWithBoolean() throws {
        let gen = makeGenerator(
            columns: ["id", "active"],
            columnTypeNames: ["S", "BOOL"],
            keySchema: [("id", "HASH")]
        )

        let results = try gen.generateStatements(
            from: [insertChange()],
            insertedRowData: [0: ["pk1", "true"]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement.contains("'active': true"))
    }

    @Test("Insert with NULL type")
    func insertWithNull() throws {
        let gen = makeGenerator(
            columns: ["id", "data"],
            columnTypeNames: ["S", "NULL"],
            keySchema: [("id", "HASH")]
        )

        let results = try gen.generateStatements(
            from: [insertChange()],
            insertedRowData: [0: ["pk1", "anything"]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement.contains("'data': NULL"))
    }

    @Test("Insert with mixed types")
    func insertWithMixedTypes() throws {
        let gen = makeGenerator(
            columns: ["id", "name", "score", "active"],
            columnTypeNames: ["S", "S", "N", "BOOL"],
            keySchema: [("id", "HASH")]
        )

        let results = try gen.generateStatements(
            from: [insertChange()],
            insertedRowData: [0: ["pk1", "Bob", "99", "false"]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        let stmt = results[0].statement
        #expect(stmt.contains("'id': 'pk1'"))
        #expect(stmt.contains("'name': 'Bob'"))
        #expect(stmt.contains("'score': 99"))
        #expect(stmt.contains("'active': false"))
    }

    @Test("Insert missing key column produces empty result")
    func insertMissingKey() throws {
        let gen = makeGenerator()

        let results = try gen.generateStatements(
            from: [insertChange()],
            insertedRowData: [0: [nil, "Alice", "30"]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.isEmpty)
    }

    @Test("Insert with single quotes in value escapes them")
    func insertWithSingleQuotes() throws {
        let gen = makeGenerator(
            columns: ["id", "name"],
            columnTypeNames: ["S", "S"],
            keySchema: [("id", "HASH")]
        )

        let results = try gen.generateStatements(
            from: [insertChange()],
            insertedRowData: [0: ["pk1", "O'Brien"]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement.contains("'O''Brien'"))
    }

    @Test("Insert with complex type passes value through as-is")
    func insertWithComplexType() throws {
        let gen = makeGenerator(
            columns: ["id", "tags"],
            columnTypeNames: ["S", "L"],
            keySchema: [("id", "HASH")]
        )

        let results = try gen.generateStatements(
            from: [insertChange()],
            insertedRowData: [0: ["pk1", "[\"a\",\"b\"]"]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement.contains("'tags': [\"a\",\"b\"]"))
    }

    // MARK: - UPDATE

    @Test("Basic update of non-key column")
    func basicUpdate() throws {
        let gen = makeGenerator()

        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                PluginCellChange(columnName: "name", oldValue: "Alice", newValue: "Bob")
            ],
            originalRow: ["pk1", "Alice", "30"]
        )

        let results = try gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "UPDATE \"TestTable\" SET \"name\" = 'Bob' WHERE \"id\" = 'pk1'")
    }

    @Test("Update with composite key produces AND in WHERE")
    func updateCompositeKey() throws {
        let gen = makeGenerator(
            columns: ["pk", "sk", "val"],
            columnTypeNames: ["S", "S", "S"],
            keySchema: [("pk", "HASH"), ("sk", "RANGE")]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                PluginCellChange(columnName: "val", oldValue: "old", newValue: "new")
            ],
            originalRow: ["partKey", "sortKey", "old"]
        )

        let results = try gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        #expect(results[0].statement.contains("WHERE \"pk\" = 'partKey' AND \"sk\" = 'sortKey'"))
    }

    @Test("Update key column only is skipped")
    func updateKeyColumnOnly() throws {
        let gen = makeGenerator()

        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                PluginCellChange(columnName: "id", oldValue: "pk1", newValue: "pk2")
            ],
            originalRow: ["pk1", "Alice", "30"]
        )

        let results = try gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.isEmpty)
    }

    @Test("Update with NULL new value")
    func updateWithNull() throws {
        let gen = makeGenerator()

        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                PluginCellChange(columnName: "name", oldValue: "Alice", newValue: nil)
            ],
            originalRow: ["pk1", "Alice", "30"]
        )

        let results = try gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        #expect(results[0].statement.contains("SET \"name\" = NULL"))
    }

    @Test("Update with number type value")
    func updateWithNumber() throws {
        let gen = makeGenerator()

        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                PluginCellChange(columnName: "age", oldValue: "30", newValue: "31")
            ],
            originalRow: ["pk1", "Alice", "30"]
        )

        let results = try gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        #expect(results[0].statement.contains("SET \"age\" = 31"))
    }

    // MARK: - DELETE

    @Test("Basic delete with key condition")
    func basicDelete() throws {
        let gen = makeGenerator()

        let change = PluginRowChange(
            rowIndex: 0,
            type: .delete,
            cellChanges: [],
            originalRow: ["pk1", "Alice", "30"]
        )

        let results = try gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [0],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "DELETE FROM \"TestTable\" WHERE \"id\" = 'pk1'")
    }

    @Test("Delete with composite key")
    func deleteCompositeKey() throws {
        let gen = makeGenerator(
            columns: ["pk", "sk", "val"],
            columnTypeNames: ["S", "S", "S"],
            keySchema: [("pk", "HASH"), ("sk", "RANGE")]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .delete,
            cellChanges: [],
            originalRow: ["partKey", "sortKey", "value"]
        )

        let results = try gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [0],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        #expect(results[0].statement.contains("WHERE \"pk\" = 'partKey' AND \"sk\" = 'sortKey'"))
    }

    @Test("Delete with missing originalRow returns nil")
    func deleteMissingOriginalRow() throws {
        let gen = makeGenerator()

        let change = PluginRowChange(
            rowIndex: 0,
            type: .delete,
            cellChanges: [],
            originalRow: nil
        )

        let results = try gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [0],
            insertedRowIndices: []
        )

        #expect(results.isEmpty)
    }

    // MARK: - formatValue Validation

    @Test("Valid integer number does not throw")
    func validIntegerNumber() throws {
        let gen = makeGenerator(
            columns: ["id", "count"],
            columnTypeNames: ["S", "N"],
            keySchema: [("id", "HASH")]
        )

        let results = try gen.generateStatements(
            from: [insertChange()],
            insertedRowData: [0: ["pk1", "42"]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement.contains("'count': 42"))
    }

    @Test("Valid float number does not throw")
    func validFloatNumber() throws {
        let gen = makeGenerator(
            columns: ["id", "price"],
            columnTypeNames: ["S", "N"],
            keySchema: [("id", "HASH")]
        )

        let results = try gen.generateStatements(
            from: [insertChange()],
            insertedRowData: [0: ["pk1", "3.14"]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement.contains("'price': 3.14"))
    }

    @Test("Invalid number throws invalidNumber error")
    func invalidNumber() {
        let gen = makeGenerator(
            columns: ["id", "count"],
            columnTypeNames: ["S", "N"],
            keySchema: [("id", "HASH")]
        )

        #expect(throws: DynamoDBStatementError.self) {
            _ = try gen.generateStatements(
                from: [insertChange()],
                insertedRowData: [0: ["pk1", "abc"]],
                deletedRowIndices: [],
                insertedRowIndices: [0]
            )
        }
    }

    @Test("Valid boolean values do not throw", arguments: ["true", "false", "1", "0"])
    func validBoolean(value: String) throws {
        let gen = makeGenerator(
            columns: ["id", "flag"],
            columnTypeNames: ["S", "BOOL"],
            keySchema: [("id", "HASH")]
        )

        let results = try gen.generateStatements(
            from: [insertChange()],
            insertedRowData: [0: ["pk1", value]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
    }

    @Test("Invalid boolean throws invalidBoolean error")
    func invalidBoolean() {
        let gen = makeGenerator(
            columns: ["id", "flag"],
            columnTypeNames: ["S", "BOOL"],
            keySchema: [("id", "HASH")]
        )

        #expect(throws: DynamoDBStatementError.self) {
            _ = try gen.generateStatements(
                from: [insertChange()],
                insertedRowData: [0: ["pk1", "yes"]],
                deletedRowIndices: [],
                insertedRowIndices: [0]
            )
        }
    }

    // MARK: - Identifier Escaping

    @Test("Table name with double quotes is escaped")
    func tableNameEscaping() throws {
        let gen = makeGenerator(
            table: "My\"Table",
            columns: ["id"],
            columnTypeNames: ["S"],
            keySchema: [("id", "HASH")]
        )

        let results = try gen.generateStatements(
            from: [insertChange()],
            insertedRowData: [0: ["pk1"]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement.contains("\"My\"\"Table\""))
    }
}
