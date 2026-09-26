//
//  MongoDBFieldPresenceWriteTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

/// Measured on MongoDB 7.0.43 with a validator of `required: ["deletedAt"]` and `bsonType:
/// ["date", "null"]`: `$unset` of `deletedAt` fails with 121 "Document failed validation", and
/// `$set: {deletedAt: null}` saves and still matches `{deletedAt: {$exists: true}}`.
struct MongoDBFieldPresenceWriteTests {
    private static let identity: PluginCellValue = "507f1f77bcf86cd799439011"

    private func update(
        _ cells: [(column: Int, old: PluginCellValue, new: PluginCellValue)],
        columns: [String],
        removing removed: Set<Int> = []
    ) throws -> String {
        let gen = MongoDBStatementGenerator(collectionName: "items", columns: columns)
        var change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: cells.map { (columnIndex: $0.column, columnName: columns[$0.column], oldValue: $0.old, newValue: $0.new) },
            originalRow: [Self.identity] + columns.dropFirst().map { _ in PluginCellValue.null }
        )
        if !removed.isEmpty {
            change.absentColumns = removed
        }
        let writes = try gen.generateRowWrites(
            from: [change], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
        )
        return try #require(writes.first?.statement)
    }

    @Test("Set NULL stores null and leaves the field in the document")
    func setNullStoresNull() throws {
        let statement = try update([(1, "2024-05-01T10:00:00Z", .null)], columns: ["_id", "deletedAt"])

        #expect(statement == #"db.items.updateOne({"_id": {"$oid": "507f1f77bcf86cd799439011"}}, {"$set": {"deletedAt": null}})"#)
        #expect(!statement.contains("$unset"))
    }

    @Test("Remove Field writes $unset, and only for the field it names")
    func removeFieldWritesUnset() throws {
        let statement = try update(
            [(1, "a", .null), (2, "b", .null)],
            columns: ["_id", "nick", "deletedAt"],
            removing: [1]
        )

        #expect(statement.contains(#""$unset": {"nick": ""}"#))
        #expect(statement.contains(#""$set": {"deletedAt": null}"#))
    }

    @Test("A value written into a field the document lacked is a $set")
    func valueIntoMissingFieldIsSet() throws {
        let statement = try update([(1, .null, "Ada")], columns: ["_id", "nick"])

        #expect(statement == #"db.items.updateOne({"_id": {"$oid": "507f1f77bcf86cd799439011"}}, {"$set": {"nick": "Ada"}})"#)
    }

    @Test("A field named with a dot takes null through $setField and is removed through $unsetField")
    func specialNamesKeepNullAndRemovalApart() throws {
        let nulled = try update([(1, "10", .null)], columns: ["_id", "price.usd"])
        #expect(nulled.contains(#""$setField": {"field": {"$literal": "price.usd"}, "input": "$$ROOT", "value": {"$literal": null}}"#))
        #expect(!nulled.contains("$unsetField"))

        let removed = try update([(1, "10", .null)], columns: ["_id", "price.usd"], removing: [1])
        #expect(removed.contains(#""$unsetField": {"field": {"$literal": "price.usd"}, "input": "$$ROOT"}"#))
    }

    @Test("A new row keeps its null fields and leaves out the ones it does not have")
    func insertTellsNullFromMissing() throws {
        let gen = MongoDBStatementGenerator(collectionName: "items", columns: ["_id", "name", "deletedAt", "nick"])
        var change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        change.absentColumns = [3]

        let writes = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [0: ["__DEFAULT__", "Ada", .null, .null]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(writes.map(\.statement) == [#"db.items.insertOne({"name": "Ada", "deletedAt": null})"#])
    }

    @Test("A NULL _id on a new row is the server's to generate, not a null key")
    func nullIdentityOnInsertIsLeftOut() throws {
        let gen = MongoDBStatementGenerator(collectionName: "items", columns: ["_id", "name"])
        let change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)

        let writes = try gen.generateRowWrites(
            from: [change], insertedRowData: [0: [.null, "Ada"]], deletedRowIndices: [], insertedRowIndices: [0]
        )

        #expect(writes.map(\.statement) == [#"db.items.insertOne({"name": "Ada"})"#])
    }

    /// Measured on 7.0.43: insertOne fails with "[22] invalid document for insert: empty key" for an
    /// empty name whatever it holds, null included, and the shell drops `__proto__` whatever it
    /// holds. Leaving the field out is the only route, and it is what the refusal names.
    @Test("A new row with an empty or __proto__ field refuses null there and leaves the field out once removed")
    func unwritableNamesAreLeftOutOnlyWhenMissing() throws {
        for name in ["", "__proto__"] {
            let gen = MongoDBStatementGenerator(collectionName: "items", columns: ["_id", "name", name])
            var change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
            let row: [PluginCellValue] = [.null, "Ada", .null]

            #expect(throws: PluginRowWriteRefusal.self, "\(name)") {
                try gen.generateRowWrites(
                    from: [change], insertedRowData: [0: row], deletedRowIndices: [], insertedRowIndices: [0]
                )
            }

            change.absentColumns = [2]
            let writes = try gen.generateRowWrites(
                from: [change], insertedRowData: [0: row], deletedRowIndices: [], insertedRowIndices: [0]
            )
            #expect(writes.map(\.statement) == [#"db.items.insertOne({"name": "Ada"})"#], "\(name)")
        }
    }

    @Test("Putting a deleted document back keeps its null fields and leaves missing ones missing")
    func restoreTellsNullFromMissing() throws {
        let gen = MongoDBStatementGenerator(collectionName: "items", columns: ["_id", "name", "deletedAt", "nick"])

        let restored = try #require(gen.generateRestore(
            rows: [[Self.identity, "Ada", .null, .null]],
            absentCells: [0: [3]]
        )?.first)

        #expect(restored.statement == #"db.items.insertOne({"_id": {"$oid": "507f1f77bcf86cd799439011"}, "name": "Ada", "deletedAt": null})"#)
    }
}
