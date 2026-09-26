//
//  MongoDBWriteBackBinaryTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct MongoDBWriteBackBinaryTests {
    private static let objectId = "507f1f77bcf86cd799439011"
    private static let png = Data([0x89, 0x50])
    private static let signature = Data([0x00, 0x01, 0x02, 0x03])

    private func generator(
        columns: [String] = ["_id", "name", "thumbnail"],
        subtypes: MongoDBBinarySubtypes = .empty,
        declaredBinary: Set<String> = [],
        identityKind: BsonValueKind? = nil
    ) -> MongoDBStatementGenerator {
        MongoDBStatementGenerator(
            collectionName: "items",
            columns: columns,
            identityKind: identityKind,
            binarySubtypes: subtypes,
            declaredBinaryFields: declaredBinary
        )
    }

    private func subtypes(_ entries: [(Data, UInt8, String)]) -> MongoDBBinarySubtypes {
        var recorded = MongoDBBinarySubtypes.empty
        for (data, subtype, field) in entries {
            recorded.record(data, subtype: subtype, field: field)
        }
        return recorded
    }

    /// A new row whose `typed` columns the user filled in; every other value was copied into it.
    private func insert(
        _ values: [PluginCellValue],
        typed: Set<Int> = [],
        columns: [String] = ["_id", "name", "thumbnail"],
        with gen: MongoDBStatementGenerator
    ) throws -> [PluginRowWrite] {
        let filledIn = typed.sorted().map { index in
            (columnIndex: index, columnName: columns[index], oldValue: PluginCellValue.null, newValue: values[index])
        }
        return try gen.generateRowWrites(
            from: [PluginRowChange(rowIndex: 0, type: .insert, cellChanges: filledIn, originalRow: nil)],
            insertedRowData: [0: values],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )
    }

    private func edit(
        _ column: String,
        from oldValue: PluginCellValue,
        to newValue: PluginCellValue,
        with gen: MongoDBStatementGenerator
    ) throws -> [PluginRowWrite] {
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(columnIndex: 2, columnName: column, oldValue: oldValue, newValue: newValue)],
            originalRow: [.text(Self.objectId), .text("a"), oldValue]
        )
        return try gen.generateRowWrites(from: [change], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: [])
    }

    // MARK: - Inserts

    @Test("A duplicated row keeps its binary field, with the subtype the value was read with")
    func duplicateKeepsGenericBinary() throws {
        let gen = generator(subtypes: subtypes([(Self.png, 0, "thumbnail")]))

        let writes = try insert(["__DEFAULT__", "a", .bytes(Self.png)], with: gen)

        #expect(writes.count == 1)
        #expect(writes[0].statement.contains(#""thumbnail": {"$binary": {"base64": "iVA=", "subType": "00"}}"#))
        #expect(writes[0].rowIndices == [0])
    }

    @Test("A subtype-5 value is written back as subtype 05")
    func duplicateKeepsSubtypeFive() throws {
        let gen = generator(columns: ["_id", "name", "sig"], subtypes: subtypes([(Self.signature, 5, "sig")]))

        let writes = try insert(["__DEFAULT__", "b", .bytes(Self.signature)], with: gen)

        #expect(writes[0].statement.contains(#""sig": {"$binary": {"base64": "AAECAw==", "subType": "05"}}"#))
    }

    @Test("Bytes seen with two subtypes in one field are refused, never inserted without them")
    func ambiguousSubtypeIsRefused() {
        let gen = generator(subtypes: subtypes([(Self.png, 0, "thumbnail"), (Self.png, 5, "thumbnail")]))

        #expect(throws: MongoDBWriteRefusal.binarySubtypeUnknown(field: "thumbnail").refusal(ofRow: 0)) {
            try insert(["__DEFAULT__", "a", .bytes(Self.png)], with: gen)
        }
    }

    @Test("Bytes never read and in a field no validator declares binary are refused")
    func unknownBytesAreRefused() {
        #expect(throws: MongoDBWriteRefusal.binarySubtypeUnknown(field: "thumbnail").refusal(ofRow: 0)) {
            try insert(["__DEFAULT__", "a", .bytes(Self.png)], with: generator())
        }
    }

    @Test("Bytes typed into a new document, in a field the validator declares binary, are generic binary")
    func declaredBinaryFieldTakesSubtypeZero() throws {
        let gen = generator(declaredBinary: ["thumbnail"])

        let writes = try insert(["__DEFAULT__", "a", .bytes(Self.png)], typed: [2], with: gen)

        #expect(writes[0].statement.contains(#""subType": "00""#))
    }

    @Test("Bytes copied into a new document, as a duplicate or a paste does, never take a default subtype")
    func copiedBytesInADeclaredFieldAreRefused() {
        let gen = generator(declaredBinary: ["thumbnail"])

        #expect(throws: MongoDBWriteRefusal.binarySubtypeUnknown(field: "thumbnail").refusal(ofRow: 0)) {
            try insert(["__DEFAULT__", "a", .bytes(Self.png)], typed: [1], with: gen)
        }
    }

    @Test("Bytes typed into a new document keep a subtype that was read for them")
    func typedBytesKeepARecordedSubtype() throws {
        let gen = generator(subtypes: subtypes([(Self.png, 5, "thumbnail")]), declaredBinary: ["thumbnail"])

        let writes = try insert(["__DEFAULT__", "a", .bytes(Self.png)], typed: [2], with: gen)

        #expect(writes[0].statement.contains(#""subType": "05""#))
    }

    @Test("A row empty apart from a value that cannot be written is refused, not inserted as {}")
    func refusedValueNeverBecomesEmptyDocument() {
        #expect(throws: MongoDBWriteRefusal.binarySubtypeUnknown(field: "thumbnail").refusal(ofRow: 0)) {
            try insert([nil, nil, .bytes(Self.png)], with: generator())
        }
    }

    @Test("An _id typed into a new row is kept, typed the way the filters type it")
    func typedIdIsKept() throws {
        let writes = try insert(["1001", "a", nil], with: generator(identityKind: .int32))

        #expect(writes[0].statement == #"db.items.insertOne({"_id": 1001, "name": "a"})"#)
    }

    // MARK: - Updates

    @Test("Editing a binary cell writes $set with the bytes, never $unset")
    func editedBinaryIsSet() throws {
        let gen = generator(subtypes: subtypes([(Self.png, 0, "thumbnail")]))

        let writes = try edit("thumbnail", from: .bytes(Self.png), to: .bytes(Data([0x01, 0x02])), with: gen)

        #expect(writes.count == 1)
        let statement = writes[0].statement
        #expect(statement.contains(#""$set": {"thumbnail": {"$binary": {"base64": "AQI=", "subType": "00"}}}"#))
        #expect(!statement.contains("$unset"))
    }

    @Test("Edited bytes keep the subtype of the value they replace, not one recorded for other bytes")
    func editKeepsTheReplacedValuesSubtype() throws {
        let gen = generator(subtypes: subtypes([(Self.png, 5, "thumbnail"), (Data([0x01]), 0, "thumbnail")]))

        let writes = try edit("thumbnail", from: .bytes(Self.png), to: .bytes(Data([0x01])), with: gen)

        #expect(writes[0].statement.contains(#""subType": "05""#))
    }

    @Test("Emptying a binary cell writes empty bytes of the same subtype")
    func emptyTextOverBinaryIsEmptyBinary() throws {
        let gen = generator(subtypes: subtypes([(Self.png, 5, "thumbnail")]))

        let writes = try edit("thumbnail", from: .bytes(Self.png), to: .text(""), with: gen)

        #expect(writes[0].statement.contains(#""thumbnail": {"$binary": {"base64": "", "subType": "05"}}"#))
    }

    @Test("Text typed over a binary value is refused rather than stored as a string")
    func textOverBinaryIsRefused() {
        let gen = generator(subtypes: subtypes([(Self.png, 0, "thumbnail")]))

        #expect(throws: MongoDBWriteRefusal.binaryNeedsBytes(field: "thumbnail").refusal(ofRow: 0)) {
            try edit("thumbnail", from: .bytes(Self.png), to: .text("hello"), with: gen)
        }
    }

    @Test("Bytes put back over a missing value keep the subtype they were read with")
    func bytesOverNullKeepTheirRecordedSubtype() throws {
        let gen = generator(subtypes: subtypes([(Self.signature, 5, "thumbnail")]), declaredBinary: ["thumbnail"])

        let writes = try edit("thumbnail", from: .null, to: .bytes(Self.signature), with: gen)

        #expect(writes[0].statement.contains(#""thumbnail": {"$binary": {"base64": "AAECAw==", "subType": "05"}}"#))
    }

    /// Data Rewind undoes Set NULL on a binary field with this very edit, holding bytes alone, so a
    /// generator that has not read them since a relaunch cannot tell them from bytes the user typed.
    @Test("Bytes set over a missing value with no recorded subtype are refused, even in a declared binary field")
    func bytesOverNullWithoutASubtypeAreRefused() {
        let relaunched = generator(declaredBinary: ["thumbnail"])

        #expect(throws: MongoDBWriteRefusal.binarySubtypeUnknown(field: "thumbnail").refusal(ofRow: 0)) {
            try edit("thumbnail", from: .null, to: .bytes(Self.signature), with: relaunched)
        }
    }

    // MARK: - Restore

    @Test("A restore keeps the subtype its bytes were read with")
    func restoreKeepsTheRecordedSubtype() throws {
        let gen = generator(subtypes: subtypes([(Self.signature, 5, "thumbnail")]), declaredBinary: ["thumbnail"])

        let restored = try #require(gen.generateRestore(rows: [[.text(Self.objectId), "a", .bytes(Self.signature)]])?.first)

        #expect(restored.statement.contains(#""thumbnail": {"$binary": {"base64": "AAECAw==", "subType": "05"}}"#))
    }

    /// After a relaunch the driver is new and its registry empty, and a Data Rewind record holds the
    /// bytes without their subtype. Subtype 0 in a declared binary field used to fill the gap, which
    /// stored a subtype-5 value as subtype 0 and reported the restore as done.
    @Test("A restore by a new generator with an empty registry refuses bytes rather than assuming a subtype")
    func restoreAfterARelaunchRefusesBytes() {
        let relaunched = generator(declaredBinary: ["thumbnail"])

        #expect(relaunched.generateRestore(rows: [[.text(Self.objectId), "a", .bytes(Self.signature)]]) == nil)
    }

    @Test("DEFAULT is refused on an update, because MongoDB has no default values")
    func defaultMarkerIsRefused() {
        #expect(throws: MongoDBWriteRefusal.noDefaultValue(field: "thumbnail").refusal(ofRow: 0)) {
            try edit("thumbnail", from: .text("x"), to: .text("__DEFAULT__"), with: generator())
        }
    }

    // MARK: - Binary _id

    @Test("A document keyed by generic binary is updated and deleted through a $binary filter")
    func binaryIdFiltersOnBinary() throws {
        let key = Data([0xAB, 0xCD, 0xEF])
        let gen = generator(columns: ["_id", "name"], subtypes: subtypes([(key, 5, "_id")]))
        let update = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(columnIndex: 1, columnName: "name", oldValue: .text("k"), newValue: .text("k2"))],
            originalRow: [.bytes(key), .text("k")]
        )
        let delete = PluginRowChange(rowIndex: 1, type: .delete, cellChanges: [], originalRow: [.bytes(key), .text("k")])

        let writes = try gen.generateRowWrites(
            from: [update, delete], insertedRowData: [:], deletedRowIndices: [1], insertedRowIndices: []
        )

        let filter = #"{"_id": {"$binary": {"base64": "q83v", "subType": "05"}}}"#
        #expect(writes.map { $0.statement } == [
            "db.items.updateOne(\(filter), {\"$set\": {\"name\": \"k2\"}})",
            "db.items.deleteOne(\(filter))"
        ])
        #expect(writes.map { $0.rowIndices } == [[0], [1]])
    }

    /// The same bytes under another subtype are another `_id`, so a subtype borrowed from the other
    /// rows could delete a different document.
    @Test("A binary _id with no recorded subtype is refused, even when every sampled _id shares one")
    func binaryIdWithoutARecordedSubtypeIsRefused() {
        let gen = generator(columns: ["_id", "name"], identityKind: .binary(subtype: 3))
        let delete = PluginRowChange(rowIndex: 0, type: .delete, cellChanges: [], originalRow: [.bytes(Data([1])), "k"])

        #expect(throws: MongoDBWriteRefusal.identitySubtypeUnknown.refusal(ofRow: 0)) {
            try gen.generateRowWrites(from: [delete], insertedRowData: [:], deletedRowIndices: [0], insertedRowIndices: [])
        }
    }

    // MARK: - Recording

    @Test("Every top-level binary value is recorded by field and value")
    func recordingReadsTopLevelBinary() {
        let recorded = MongoDBBinarySubtypes.recording([
            ["_id": MongoDBObjectId(hex: Self.objectId), "sig": MongoDBBinaryValue(data: Self.signature, subtype: 5)],
            ["thumb": MongoDBBinaryValue(data: Self.png, subtype: 0), "nested": ["sig": MongoDBBinaryValue(data: Self.png, subtype: 9)]]
        ])

        #expect(recorded.subtypes(of: Self.signature, in: "sig") == [5])
        #expect(recorded.subtypes(of: Self.png, in: "thumb") == [0])
        #expect(recorded.subtypes(of: Self.png, in: "sig").isEmpty)
        #expect(recorded.count == 2)
    }

    @Test("Merging a later page keeps earlier values and keeps a value seen twice ambiguous")
    func mergingAddsRatherThanReplaces() {
        let first = subtypes([(Self.png, 0, "blob")])
        let second = subtypes([(Self.png, 5, "blob"), (Self.signature, 5, "blob")])

        let merged = first.merging(second)

        #expect(merged.subtypes(of: Self.png, in: "blob") == [0, 5])
        #expect(merged.subtypes(of: Self.signature, in: "blob") == [5])
        #expect(merged.count == 3)
    }
}
