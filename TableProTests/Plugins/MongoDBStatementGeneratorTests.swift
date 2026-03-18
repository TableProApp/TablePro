//
//  MongoDBStatementGeneratorTests.swift
//  TableProTests
//
//  Tests for MongoDBStatementGenerator (compiled via symlink from MongoDBDriverPlugin).
//

import Foundation
import Testing
import TableProPluginKit

@Suite("MongoDB Statement Generator")
struct MongoDBStatementGeneratorTests {

    // MARK: - INSERT

    @Test("Simple insert generates insertOne, skipping _id")
    func simpleInsert() {
        let gen = MongoDBStatementGenerator(
            collectionName: "users",
            columns: ["_id", "name", "email"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )

        let insertedData: [Int: [String?]] = [
            0: [nil, "Alice", "alice@example.com"]
        ]

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        let stmt = results[0].statement
        #expect(stmt.contains("insertOne"))
        #expect(stmt.contains("\"email\": \"alice@example.com\""))
        #expect(stmt.contains("\"name\": \"Alice\""))
        #expect(!stmt.contains("\"_id\""))
    }

    @Test("Insert skips __DEFAULT__ sentinel values")
    func insertSkipsDefaultSentinel() {
        let gen = MongoDBStatementGenerator(
            collectionName: "users",
            columns: ["_id", "name", "age"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )

        let insertedData: [Int: [String?]] = [
            0: [nil, "Bob", "__DEFAULT__"]
        ]

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        let stmt = results[0].statement
        #expect(stmt.contains("\"name\": \"Bob\""))
        #expect(!stmt.contains("__DEFAULT__"))
        #expect(!stmt.contains("\"age\""))
    }

    @Test("Insert with nil values are excluded from document")
    func insertNilValuesExcluded() {
        let gen = MongoDBStatementGenerator(
            collectionName: "users",
            columns: ["_id", "name", "email"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )

        let insertedData: [Int: [String?]] = [
            0: [nil, "Carol", nil]
        ]

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        let stmt = results[0].statement
        #expect(stmt.contains("\"name\": \"Carol\""))
        #expect(!stmt.contains("\"email\""))
    }

    @Test("Insert with all nil/default values produces no statement")
    func insertAllNilProducesNothing() {
        let gen = MongoDBStatementGenerator(
            collectionName: "users",
            columns: ["_id", "name"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )

        let insertedData: [Int: [String?]] = [
            0: [nil, nil]
        ]

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.isEmpty)
    }

    @Test("Insert uses cellChanges as fallback when insertedRowData missing")
    func insertFallbackToCellChanges() {
        let gen = MongoDBStatementGenerator(
            collectionName: "users",
            columns: ["_id", "name"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [
                (columnIndex: 1, columnName: "name", oldValue: nil, newValue: "Dave")
            ],
            originalRow: nil
        )

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement.contains("\"name\": \"Dave\""))
    }

    @Test("Insert with numeric value auto-detects type")
    func insertNumericValue() {
        let gen = MongoDBStatementGenerator(
            collectionName: "data",
            columns: ["_id", "count"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )

        let insertedData: [Int: [String?]] = [
            0: [nil, "42"]
        ]

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement.contains("\"count\": 42"))
    }

    @Test("Insert not in insertedRowIndices is skipped")
    func insertNotInIndicesSkipped() {
        let gen = MongoDBStatementGenerator(
            collectionName: "users",
            columns: ["_id", "name"]
        )

        let change = PluginRowChange(
            rowIndex: 5,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )

        let insertedData: [Int: [String?]] = [
            5: [nil, "Eve"]
        ]

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0] // does not contain 5
        )

        #expect(results.isEmpty)
    }

    // MARK: - UPDATE

    @Test("Update with ObjectId _id")
    func updateWithObjectId() {
        let gen = MongoDBStatementGenerator(
            collectionName: "users",
            columns: ["_id", "name", "email"]
        )

        let objectId = "507f1f77bcf86cd799439011"
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                (columnIndex: 1, columnName: "name", oldValue: "Alice", newValue: "Alicia")
            ],
            originalRow: [objectId, "Alice", "alice@example.com"]
        )

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        let stmt = results[0].statement
        #expect(stmt.contains("updateOne"))
        #expect(stmt.contains("\"$oid\": \"\(objectId)\""))
        #expect(stmt.contains("\"$set\""))
        #expect(stmt.contains("\"name\": \"Alicia\""))
    }

    @Test("Update with numeric _id")
    func updateWithNumericId() {
        let gen = MongoDBStatementGenerator(
            collectionName: "users",
            columns: ["_id", "name"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                (columnIndex: 1, columnName: "name", oldValue: "Bob", newValue: "Robert")
            ],
            originalRow: ["42", "Bob"]
        )

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        let stmt = results[0].statement
        #expect(stmt.contains("{\"_id\": 42}"))
    }

    @Test("Update with string _id")
    func updateWithStringId() {
        let gen = MongoDBStatementGenerator(
            collectionName: "users",
            columns: ["_id", "name"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                (columnIndex: 1, columnName: "name", oldValue: "X", newValue: "Y")
            ],
            originalRow: ["my-custom-id", "X"]
        )

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        let stmt = results[0].statement
        #expect(stmt.contains("{\"_id\": \"my-custom-id\"}"))
    }

    @Test("Update with $set and $unset")
    func updateSetAndUnset() {
        let gen = MongoDBStatementGenerator(
            collectionName: "users",
            columns: ["_id", "name", "bio"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                (columnIndex: 1, columnName: "name", oldValue: "Alice", newValue: "Alicia"),
                (columnIndex: 2, columnName: "bio", oldValue: "Some bio", newValue: nil)
            ],
            originalRow: ["507f1f77bcf86cd799439011", "Alice", "Some bio"]
        )

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        let stmt = results[0].statement
        #expect(stmt.contains("\"$set\""))
        #expect(stmt.contains("\"name\": \"Alicia\""))
        #expect(stmt.contains("\"$unset\""))
        #expect(stmt.contains("\"bio\": \"\""))
    }

    @Test("Update skips _id column changes")
    func updateSkipsIdChange() {
        let gen = MongoDBStatementGenerator(
            collectionName: "users",
            columns: ["_id", "name"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                (columnIndex: 0, columnName: "_id", oldValue: "old", newValue: "new")
            ],
            originalRow: ["old", "Alice"]
        )

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.isEmpty)
    }

    @Test("Update without _id in original row is skipped")
    func updateNoIdSkipped() {
        let gen = MongoDBStatementGenerator(
            collectionName: "users",
            columns: ["name", "email"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                (columnIndex: 0, columnName: "name", oldValue: "A", newValue: "B")
            ],
            originalRow: ["A", "a@b.com"]
        )

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.isEmpty)
    }

    @Test("Update with empty cellChanges is skipped")
    func updateEmptyCellChanges() {
        let gen = MongoDBStatementGenerator(
            collectionName: "users",
            columns: ["_id", "name"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [],
            originalRow: ["507f1f77bcf86cd799439011", "Alice"]
        )

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.isEmpty)
    }

    // MARK: - DELETE

    @Test("Delete with ObjectId uses $oid filter")
    func deleteWithObjectId() {
        let gen = MongoDBStatementGenerator(
            collectionName: "users",
            columns: ["_id", "name"]
        )

        let objectId = "507f1f77bcf86cd799439011"
        let change = PluginRowChange(
            rowIndex: 0,
            type: .delete,
            cellChanges: [],
            originalRow: [objectId, "Alice"]
        )

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [0],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        let stmt = results[0].statement
        #expect(stmt.contains("deleteOne"))
        #expect(stmt.contains("\"$oid\": \"\(objectId)\""))
    }

    @Test("Bulk delete uses deleteMany with $in")
    func bulkDeleteMany() {
        let gen = MongoDBStatementGenerator(
            collectionName: "users",
            columns: ["_id", "name"]
        )

        let id1 = "507f1f77bcf86cd799439011"
        let id2 = "507f1f77bcf86cd799439022"

        let changes = [
            PluginRowChange(rowIndex: 0, type: .delete, cellChanges: [], originalRow: [id1, "Alice"]),
            PluginRowChange(rowIndex: 1, type: .delete, cellChanges: [], originalRow: [id2, "Bob"])
        ]

        let results = gen.generateStatements(
            from: changes,
            insertedRowData: [:],
            deletedRowIndices: [0, 1],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        let stmt = results[0].statement
        #expect(stmt.contains("deleteMany"))
        #expect(stmt.contains("\"$in\""))
        #expect(stmt.contains("{\"$oid\": \"\(id1)\"}"))
        #expect(stmt.contains("{\"$oid\": \"\(id2)\"}"))
    }

    @Test("Bulk delete with numeric ids")
    func bulkDeleteNumericIds() {
        let gen = MongoDBStatementGenerator(
            collectionName: "users",
            columns: ["_id", "name"]
        )

        let changes = [
            PluginRowChange(rowIndex: 0, type: .delete, cellChanges: [], originalRow: ["1", "Alice"]),
            PluginRowChange(rowIndex: 1, type: .delete, cellChanges: [], originalRow: ["2", "Bob"])
        ]

        let results = gen.generateStatements(
            from: changes,
            insertedRowData: [:],
            deletedRowIndices: [0, 1],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        let stmt = results[0].statement
        #expect(stmt.contains("deleteMany"))
        #expect(stmt.contains("\"$in\": [1, 2]"))
    }

    @Test("Single delete without _id falls back to all-field match")
    func singleDeleteNoIdFallback() {
        let gen = MongoDBStatementGenerator(
            collectionName: "users",
            columns: ["name", "email"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .delete,
            cellChanges: [],
            originalRow: ["Alice", "alice@example.com"]
        )

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [0],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        let stmt = results[0].statement
        #expect(stmt.contains("deleteOne"))
        #expect(stmt.contains("\"email\": \"alice@example.com\""))
        #expect(stmt.contains("\"name\": \"Alice\""))
    }

    @Test("Delete not in deletedRowIndices is skipped")
    func deleteNotInIndicesSkipped() {
        let gen = MongoDBStatementGenerator(
            collectionName: "users",
            columns: ["_id", "name"]
        )

        let change = PluginRowChange(
            rowIndex: 5,
            type: .delete,
            cellChanges: [],
            originalRow: ["507f1f77bcf86cd799439011", "Alice"]
        )

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [0], // does not contain 5
            insertedRowIndices: []
        )

        #expect(results.isEmpty)
    }

    @Test("Delete without originalRow is skipped")
    func deleteNoOriginalRowSkipped() {
        let gen = MongoDBStatementGenerator(
            collectionName: "users",
            columns: ["_id", "name"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .delete,
            cellChanges: [],
            originalRow: nil
        )

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [0],
            insertedRowIndices: []
        )

        #expect(results.isEmpty)
    }

    // MARK: - Mixed Operations

    @Test("Mixed insert, update, and delete in one batch")
    func mixedOperations() {
        let gen = MongoDBStatementGenerator(
            collectionName: "users",
            columns: ["_id", "name", "email"]
        )

        let objectId = "507f1f77bcf86cd799439011"
        let changes = [
            PluginRowChange(
                rowIndex: 0,
                type: .insert,
                cellChanges: [],
                originalRow: nil
            ),
            PluginRowChange(
                rowIndex: 1,
                type: .update,
                cellChanges: [
                    (columnIndex: 1, columnName: "name", oldValue: "Bob", newValue: "Robert")
                ],
                originalRow: [objectId, "Bob", "bob@test.com"]
            ),
            PluginRowChange(
                rowIndex: 2,
                type: .delete,
                cellChanges: [],
                originalRow: ["507f1f77bcf86cd799439022", "Carol", "carol@test.com"]
            )
        ]

        let insertedData: [Int: [String?]] = [
            0: [nil, "Alice", "alice@test.com"]
        ]

        let results = gen.generateStatements(
            from: changes,
            insertedRowData: insertedData,
            deletedRowIndices: [2],
            insertedRowIndices: [0]
        )

        #expect(results.count == 3)
        #expect(results[0].statement.contains("insertOne"))
        #expect(results[1].statement.contains("updateOne"))
        #expect(results[2].statement.contains("deleteOne"))
    }

    // MARK: - Collection Accessor

    @Test("Collection with dots uses bracket notation")
    func collectionBracketNotation() {
        let gen = MongoDBStatementGenerator(
            collectionName: "my.collection",
            columns: ["_id", "name"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [0: [nil, "Test"]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement.contains("db[\"my.collection\"]"))
    }

    // MARK: - Value Type Detection

    @Test("Boolean values are serialized as booleans")
    func booleanSerialization() {
        let gen = MongoDBStatementGenerator(
            collectionName: "data",
            columns: ["_id", "active"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [0: [nil, "true"]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement.contains("\"active\": true"))
    }

    @Test("Float values are serialized as numbers")
    func floatSerialization() {
        let gen = MongoDBStatementGenerator(
            collectionName: "data",
            columns: ["_id", "price"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [0: [nil, "19.99"]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement.contains("\"price\": 19.99"))
    }

    @Test("JSON object values are passed through as-is")
    func jsonObjectPassthrough() {
        let gen = MongoDBStatementGenerator(
            collectionName: "data",
            columns: ["_id", "metadata"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [0: [nil, "{\"nested\": true}"]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement.contains("\"metadata\": {\"nested\": true}"))
    }

    @Test("JSON array values are passed through as-is")
    func jsonArrayPassthrough() {
        let gen = MongoDBStatementGenerator(
            collectionName: "data",
            columns: ["_id", "tags"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [0: [nil, "[1, 2, 3]"]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement.contains("\"tags\": [1, 2, 3]"))
    }
}
