//
//  MongoDBStatementGeneratorTests.swift
//  TableProTests
//
//  Tests for MongoDBStatementGenerator (compiled via symlink from MongoDBDriverPlugin).
//

import Foundation
import TableProPluginKit
import Testing

struct MongoDBStatementGeneratorTests {
    // MARK: - INSERT

    @Test("Simple insert generates insertOne, skipping _id")
    func simpleInsert() throws {
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

        let results = try gen.generateRowWrites(
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
    func insertSkipsDefaultSentinel() throws {
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

        let results = try gen.generateRowWrites(
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
    func insertNilValuesExcluded() throws {
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

        let results = try gen.generateRowWrites(
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

    @Test("A new row with every cell empty inserts the empty document")
    func insertAllNilWritesEmptyDocument() throws {
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
            0: [nil, "__DEFAULT__"]
        ]

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.map { $0.statement } == ["db.users.insertOne({})"])
        #expect(results.map { $0.rowIndices } == [[0]])
    }

    @Test("Insert uses cellChanges as fallback when insertedRowData missing")
    func insertFallbackToCellChanges() throws {
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

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement.contains("\"name\": \"Dave\""))
    }

    @Test("Insert with numeric value auto-detects type")
    func insertNumericValue() throws {
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

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement.contains("\"count\": 42"))
    }

    @Test("Insert emits JSON-valid decimal and exponent numbers")
    func insertEmitsJsonValidNumbers() throws {
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

        let results = try gen.generateRowWrites(
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
    func insertQuotesNonJsonNumericSpellings() throws {
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

        let results = try gen.generateRowWrites(
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

    /// The maximum Int64 is past 2^53, where a bare JavaScript literal rounds: JavaScriptCore reads
    /// `9223372036854775807` as `9223372036854776000`. It has to cross as `$numberLong`.
    @Test("Insert quotes integers that overflow Int64 and writes the largest ones as $numberLong")
    func insertQuotesInt64Overflow() throws {
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

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        let document = firstArgumentObject(in: results[0].statement)
        #expect(document?["overflow"] as? String == "12345678901234567890")
        #expect((document?["maxInt64"] as? [String: Any])?["$numberLong"] as? String == "9223372036854775807")
    }

    @Test("Insert not in insertedRowIndices is skipped")
    func insertNotInIndicesSkipped() throws {
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

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0] // does not contain 5
        )

        #expect(results.isEmpty)
    }

    // MARK: - UPDATE

    @Test("Update with ObjectId _id")
    func updateWithObjectId() throws {
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

        let results = try gen.generateRowWrites(
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
    func updateWithNumericId() throws {
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

        let results = try gen.generateRowWrites(
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
    func updateWithStringId() throws {
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

        let results = try gen.generateRowWrites(
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
    func updateSetAndUnset() throws {
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

        let results = try gen.generateRowWrites(
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

    @Test("An edit of _id is refused, because MongoDB never changes a document's _id")
    func updateRefusesIdChange() throws {
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

        #expect(throws: MongoDBWriteRefusal.identityChanged.refusal(ofRow: 0)) {
            try gen.generateRowWrites(from: [change], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: [])
        }
    }

    @Test("An update of a row with no _id is refused rather than left out")
    func updateWithoutIdIsRefused() throws {
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

        #expect(throws: MongoDBWriteRefusal.missingIdentity.refusal(ofRow: 0)) {
            try gen.generateRowWrites(from: [change], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: [])
        }
    }

    @Test("Update with empty cellChanges is skipped")
    func updateEmptyCellChanges() throws {
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

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.isEmpty)
    }

    // MARK: - DELETE

    @Test("Delete with ObjectId uses $oid filter")
    func deleteWithObjectId() throws {
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

        let results = try gen.generateRowWrites(
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
    func bulkDeleteMany() throws {
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

        let results = try gen.generateRowWrites(
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
    func bulkDeleteNumericIds() throws {
        let gen = MongoDBStatementGenerator(
            collectionName: "users",
            columns: ["_id", "name"]
        )

        let changes = [
            PluginRowChange(rowIndex: 0, type: .delete, cellChanges: [], originalRow: ["1", "Alice"]),
            PluginRowChange(rowIndex: 1, type: .delete, cellChanges: [], originalRow: ["2", "Bob"])
        ]

        let results = try gen.generateRowWrites(
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
    func deleteQuotesInt64OverflowId() throws {
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

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [0],
            insertedRowIndices: []
        )

        #expect(results[0].statement.contains("{\"_id\": \"12345678901234567890\"}"))
    }

    @Test("Delete keeps a decimal or exponent _id quoted so a string _id still matches")
    func deleteQuotesNonIntegerId() throws {
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

            let results = try gen.generateRowWrites(
                from: [change],
                insertedRowData: [:],
                deletedRowIndices: [0],
                insertedRowIndices: []
            )

            #expect(results[0].statement.contains("{\"_id\": \"\(id)\"}"))
        }
    }

    /// An all-field filter cannot express a binary value and drops every column it cannot
    /// stringify, so it deletes the first partial match rather than the intended document.
    @Test("A collection with no _id column refuses the delete instead of matching on every field")
    func singleDeleteWithoutIdColumnIsRefused() throws {
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

        #expect(throws: MongoDBWriteRefusal.missingIdentity.refusal(ofRow: 0)) {
            try gen.generateRowWrites(from: [change], insertedRowData: [:], deletedRowIndices: [0], insertedRowIndices: [])
        }
    }

    @Test("Delete not in deletedRowIndices is skipped")
    func deleteNotInIndicesSkipped() throws {
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

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [0], // does not contain 5
            insertedRowIndices: []
        )

        #expect(results.isEmpty)
    }

    @Test("A delete without its original row is refused")
    func deleteNoOriginalRowIsRefused() throws {
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

        #expect(throws: MongoDBWriteRefusal.missingIdentity.refusal(ofRow: 0)) {
            try gen.generateRowWrites(from: [change], insertedRowData: [:], deletedRowIndices: [0], insertedRowIndices: [])
        }
    }

    // MARK: - Mixed Operations

    @Test("Mixed insert, update, and delete in one batch")
    func mixedOperations() throws {
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

        let results = try gen.generateRowWrites(
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

    @Test("Collection with dots goes through getCollection")
    func collectionBracketNotation() throws {
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

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [0: [nil, "Test"]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement.contains("db.getCollection(\"my.collection\")"))
    }

    // MARK: - Value Type Detection

    @Test("Boolean values are serialized as booleans")
    func booleanSerialization() throws {
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

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [0: [nil, "true"]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement.contains("\"active\": true"))
    }

    @Test("Float values are serialized as numbers")
    func floatSerialization() throws {
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

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [0: [nil, "19.99"]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement.contains("\"price\": 19.99"))
    }

    @Test("A JSON object value is written as the object it spells")
    func jsonObjectPassthrough() throws {
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

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [0: [nil, "{\"nested\": true}"]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement.contains("\"metadata\": {\"nested\":true}"))
    }

    @Test("A JSON array value is written as the array it spells")
    func jsonArrayPassthrough() throws {
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

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [0: [nil, "[1, 2, 3]"]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement.contains("\"tags\": [1,2,3]"))
    }
    // MARK: - Binary UUID round trip

    private static let uuid = "8cd003eb-4a25-4324-9332-88fce2da0d1a"
    private static let javaBase64 = "JEMlSusD0IwaDdri/Igykw=="
    private static let standardBase64 = "jNAD60olQySTMoj84toNGg=="

    @Test("Editing a legacy UUID field writes BSON binary, not a string")
    func updateWritesLegacyUuidBinary() throws {
        let gen = MongoDBStatementGenerator(collectionName: "docs", columns: ["_id", "ref"])
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                (
                    columnIndex: 1,
                    columnName: "ref",
                    oldValue: .null,
                    newValue: .text("LegacyJavaUUID(\"\(Self.uuid)\")")
                )
            ],
            originalRow: ["507f1f77bcf86cd799439011", .null]
        )

        let results = try gen.generateRowWrites(
            from: [change], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
        )

        #expect(results.count == 1)
        let stmt = results[0].statement
        #expect(stmt.contains("\"subType\": \"03\""))
        #expect(stmt.contains(Self.javaBase64))
        #expect(!stmt.contains("\"ref\": \"LegacyJavaUUID"))
    }

    @Test("Inserting a standard UUID writes BSON binary subtype 4")
    func insertWritesStandardUuidBinary() throws {
        let gen = MongoDBStatementGenerator(collectionName: "docs", columns: ["_id", "ref"])
        let change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [0: [nil, .text("UUID(\"\(Self.uuid)\")")]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement.contains("\"subType\": \"04\""))
        #expect(results[0].statement.contains(Self.standardBase64))
    }

    @Test("An _id that is a legacy UUID filters on binary, not on the wrapper text")
    func updateFiltersOnBinaryId() throws {
        let gen = MongoDBStatementGenerator(collectionName: "docs", columns: ["_id", "name"])
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                (columnIndex: 1, columnName: "name", oldValue: .text("a"), newValue: .text("b"))
            ],
            originalRow: [.text("LegacyJavaUUID(\"\(Self.uuid)\")"), .text("a")]
        )

        let results = try gen.generateRowWrites(
            from: [change], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
        )

        #expect(results.count == 1)
        let stmt = results[0].statement
        #expect(stmt.contains("updateOne({\"_id\": {\"$binary\""))
        #expect(stmt.contains(Self.javaBase64))
    }

    @Test("Deleting a document with a legacy UUID _id filters on binary")
    func deleteFiltersOnBinaryId() throws {
        let gen = MongoDBStatementGenerator(collectionName: "docs", columns: ["_id", "name"])
        let change = PluginRowChange(
            rowIndex: 0,
            type: .delete,
            cellChanges: [],
            originalRow: [.text("LegacyJavaUUID(\"\(Self.uuid)\")"), .text("a")]
        )

        let results = try gen.generateRowWrites(
            from: [change], insertedRowData: [:], deletedRowIndices: [0], insertedRowIndices: []
        )

        #expect(results.count == 1)
        #expect(results[0].statement.contains("deleteOne({\"_id\": {\"$binary\""))
    }

    @Test("A bulk delete of UUID _ids uses binary values inside $in")
    func bulkDeleteUsesBinaryIds() throws {
        let gen = MongoDBStatementGenerator(collectionName: "docs", columns: ["_id"])
        let changes = [
            PluginRowChange(
                rowIndex: 0, type: .delete, cellChanges: [],
                originalRow: [.text("LegacyJavaUUID(\"\(Self.uuid)\")")]
            ),
            PluginRowChange(
                rowIndex: 1, type: .delete, cellChanges: [],
                originalRow: [.text("UUID(\"\(Self.uuid)\")")]
            )
        ]

        let results = try gen.generateRowWrites(
            from: changes, insertedRowData: [:], deletedRowIndices: [0, 1], insertedRowIndices: []
        )

        #expect(results.count == 1)
        let stmt = results[0].statement
        #expect(stmt.contains("deleteMany"))
        #expect(stmt.contains("\"subType\": \"03\""))
        #expect(stmt.contains("\"subType\": \"04\""))
    }

    /// Matching on the remaining fields cannot express a binary value, so it would
    /// delete the first partial match instead of the intended document.
    @Test("A delete whose binary _id has no known subtype is refused rather than matched on other fields")
    func deleteWithoutUsableIdIsRefused() throws {
        let gen = MongoDBStatementGenerator(collectionName: "docs", columns: ["_id", "name"])
        let change = PluginRowChange(
            rowIndex: 0,
            type: .delete,
            cellChanges: [],
            originalRow: [.bytes(Data([0x01, 0x02])), .text("Alice")]
        )

        #expect(throws: MongoDBWriteRefusal.binarySubtypeUnknown(field: "_id").refusal(ofRow: 0)) {
            try gen.generateRowWrites(from: [change], insertedRowData: [:], deletedRowIndices: [0], insertedRowIndices: [])
        }
    }

    // MARK: - Restore

    /// An ordinary insert drops `_id` so the server picks one. Undoing a delete has the opposite
    /// requirement: a new `_id` is a different document, and whatever referenced the old one is
    /// still pointing at nothing.
    @Test("Restoring a deleted document keeps its original _id")
    func restoreKeepsObjectId() throws {
        let gen = MongoDBStatementGenerator(collectionName: "users", columns: ["_id", "name"])

        let statements = gen.generateRestore(rows: [["507f1f77bcf86cd799439011", "Alice"]])

        #expect(statements?.count == 1)
        let statement = statements?.first?.statement ?? ""
        #expect(statement.hasPrefix("db.users.insertOne("))
        let document = firstArgumentObject(in: statement)
        #expect((document?["_id"] as? [String: Any])?["$oid"] as? String == "507f1f77bcf86cd799439011")
        #expect(document?["name"] as? String == "Alice")
    }

    @Test("A numeric key is restored as a number, not a string")
    func restoreKeepsNumericId() throws {
        let gen = MongoDBStatementGenerator(collectionName: "counters", columns: ["_id", "value"])

        let statement = gen.generateRestore(rows: [["42", "7"]])?.first?.statement ?? ""

        let document = firstArgumentObject(in: statement)
        #expect(document?["_id"] as? Int == 42)
    }

    @Test("A restored document keeps its binary field with the subtype it was read with")
    func restoreKeepsBinaryField() throws {
        var subtypes = MongoDBBinarySubtypes.empty
        subtypes.record(Data([0x01]), subtype: 5, field: "avatar")
        let gen = MongoDBStatementGenerator(
            collectionName: "users", columns: ["_id", "avatar"], binarySubtypes: subtypes
        )

        let statement = try #require(gen.generateRestore(rows: [["507f1f77bcf86cd799439011", .bytes(Data([0x01]))]])?.first)

        #expect(statement.statement.contains(#""avatar": {"$binary": {"base64": "AQ==", "subType": "05"}}"#))
    }

    /// Dropping the field would restore a document that is missing it, and report success.
    @Test("A binary field whose subtype is unknown refuses the restore rather than dropping the field")
    func restoreRefusesUnknownBinarySubtype() throws {
        let gen = MongoDBStatementGenerator(collectionName: "users", columns: ["_id", "avatar"])

        #expect(gen.generateRestore(rows: [["507f1f77bcf86cd799439011", .bytes(Data([0x01]))]]) == nil)
    }

    @Test("A collection with no _id column cannot be restored")
    func restoreRefusesWithoutIdColumn() throws {
        let gen = MongoDBStatementGenerator(collectionName: "users", columns: ["name", "email"])

        #expect(gen.generateRestore(rows: [["Alice", "alice@example.com"]]) == nil)
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
