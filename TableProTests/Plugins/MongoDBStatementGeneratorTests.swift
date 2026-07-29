//
//  MongoDBStatementGeneratorTests.swift
//  TableProTests
//
//  Tests for MongoDBStatementGenerator (compiled via symlink from MongoDBDriverPlugin).
//

import Foundation
import TableProPluginKit
import Testing

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

        let insertedData: [Int: [PluginCellValue]] = [
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

        let insertedData: [Int: [PluginCellValue]] = [
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

        let insertedData: [Int: [PluginCellValue]] = [
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

        let insertedData: [Int: [PluginCellValue]] = [
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

        let insertedData: [Int: [PluginCellValue]] = [
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

    @Test("Insert emits JSON-valid decimal and exponent numbers")
    func insertEmitsJsonValidNumbers() {
        let gen = MongoDBStatementGenerator(
            collectionName: "users",
            columns: ["_id", "decimal", "exponent"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )

        let insertedData: [Int: [PluginCellValue]] = [
            0: [nil, "0.5", "1e3"]
        ]

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        let document = firstArgumentObject(in: results[0].statement)
        #expect(document?["decimal"] as? Double == 0.5)
        #expect(document?["exponent"] as? Double == 1_000)
    }

    @Test("Insert quotes non-JSON numeric spellings")
    func insertQuotesNonJsonNumericSpellings() {
        let gen = MongoDBStatementGenerator(
            collectionName: "users",
            columns: ["_id", "leadingDecimal", "trailingDecimal", "leadingPlus", "leadingZero"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )

        let insertedData: [Int: [PluginCellValue]] = [
            0: [nil, ".5", "1.", "+7", "01"]
        ]

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        let document = firstArgumentObject(in: results[0].statement)
        #expect(document?["leadingDecimal"] as? String == ".5")
        #expect(document?["trailingDecimal"] as? String == "1.")
        #expect(document?["leadingPlus"] as? String == "+7")
        #expect(document?["leadingZero"] as? String == "01")
    }

    @Test("Insert quotes integers that overflow Int64 but keeps in-range integers numeric")
    func insertQuotesInt64Overflow() {
        let gen = MongoDBStatementGenerator(
            collectionName: "users",
            columns: ["_id", "overflow", "maxInt64"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )

        let insertedData: [Int: [PluginCellValue]] = [
            0: [nil, "12345678901234567890", "9223372036854775807"]
        ]

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        let document = firstArgumentObject(in: results[0].statement)
        #expect(document?["overflow"] as? String == "12345678901234567890")
        #expect(document?["maxInt64"] as? Int64 == 9_223_372_036_854_775_807)
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

        let insertedData: [Int: [PluginCellValue]] = [
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
            originalRow: [.text(objectId), "Alice", "alice@example.com"]
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
            originalRow: [.text(objectId), "Alice"]
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
            PluginRowChange(rowIndex: 0, type: .delete, cellChanges: [], originalRow: [.text(id1), "Alice"]),
            PluginRowChange(rowIndex: 1, type: .delete, cellChanges: [], originalRow: [.text(id2), "Bob"])
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

    @Test("Delete quotes an _id that overflows Int64 to preserve precision")
    func deleteQuotesInt64OverflowId() {
        let gen = MongoDBStatementGenerator(
            collectionName: "users",
            columns: ["_id", "name"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .delete,
            cellChanges: [],
            originalRow: ["12345678901234567890", "Alice"]
        )

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [0],
            insertedRowIndices: []
        )

        #expect(results[0].statement.contains("{\"_id\": \"12345678901234567890\"}"))
    }

    @Test("Delete keeps a decimal or exponent _id quoted so a string _id still matches")
    func deleteQuotesNonIntegerId() {
        let gen = MongoDBStatementGenerator(
            collectionName: "users",
            columns: ["_id", "name"]
        )

        for id in ["1.5", "1e3"] {
            let change = PluginRowChange(
                rowIndex: 0,
                type: .delete,
                cellChanges: [],
                originalRow: [PluginCellValue.text(id), "Alice"]
            )

            let results = gen.generateStatements(
                from: [change],
                insertedRowData: [:],
                deletedRowIndices: [0],
                insertedRowIndices: []
            )

            #expect(results[0].statement.contains("{\"_id\": \"\(id)\"}"))
        }
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
                originalRow: [.text(objectId), "Bob", "bob@test.com"]
            ),
            PluginRowChange(
                rowIndex: 2,
                type: .delete,
                cellChanges: [],
                originalRow: ["507f1f77bcf86cd799439022", "Carol", "carol@test.com"]
            )
        ]

        let insertedData: [Int: [PluginCellValue]] = [
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

private func firstArgumentObject(in statement: String) -> [String: Any]? {
    guard let openParen = statement.firstIndex(of: "("),
          let closeParen = statement.lastIndex(of: ")"),
          openParen < closeParen else { return nil }
    let json = String(statement[statement.index(after: openParen) ..< closeParen])
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}
