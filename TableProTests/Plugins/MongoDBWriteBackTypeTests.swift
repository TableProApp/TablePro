//
//  MongoDBWriteBackTypeTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct MongoDBWriteBackTypeTests {
    private func update(
        column: String,
        to newValue: PluginCellValue,
        kinds: [String: BsonValueKind],
        declared: [String: BsonValueKind] = [:]
    ) -> String? {
        let gen = MongoDBStatementGenerator(
            collectionName: "products",
            columns: ["_id", column],
            columnKinds: kinds,
            declaredKinds: declared
        )
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(columnIndex: 1, columnName: column, oldValue: .null, newValue: newValue)],
            originalRow: [.text("507f1f77bcf86cd799439011"), .null]
        )
        return gen.generateStatements(
            from: [change], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
        ).first?.statement
    }

    @Test("A decimal column stays decimal instead of collapsing to a double")
    func decimalColumnKeepsItsType() throws {
        let stmt = try #require(update(
            column: "price",
            to: .text("1847.270000000000000000000000001"),
            kinds: ["price": .decimal128]
        ))
        #expect(stmt.contains(#"{"$numberDecimal": "1847.270000000000000000000000001"}"#))
    }

    @Test("A 64-bit integer column is not narrowed to int32")
    func int64ColumnKeepsItsWidth() throws {
        let stmt = try #require(update(column: "qty", to: .text("5"), kinds: ["qty": .int64]))
        #expect(stmt.contains(#"{"$numberLong": "5"}"#))
    }

    @Test("A double column stays a double even when the value looks whole")
    func doubleColumnKeepsItsType() throws {
        let stmt = try #require(update(column: "rate", to: .text("3"), kinds: ["rate": .double]))
        #expect(stmt.contains(#"{"$numberDouble": "3"}"#))
    }

    @Test("A column with no recorded type writes a bare number, as before")
    func unknownColumnWritesBareNumber() throws {
        let stmt = try #require(update(column: "count", to: .text("7"), kinds: [:]))
        #expect(stmt.contains(#""count": 7"#))
    }

    @Test("A truncated nested value is refused instead of stored as a fragment")
    func truncatedValueIsNotWritten() {
        let fragment = "{\"a\": 1, \"b\": \"" + String(repeating: "x", count: 50) + "..."
        #expect(update(column: "payload", to: .text(fragment), kinds: [:]) == nil)
    }

    @Test("A complete nested value still writes")
    func completeNestedValueWrites() throws {
        let stmt = try #require(update(column: "payload", to: .text(#"{"a":1}"#), kinds: [:]))
        #expect(stmt.contains(#""payload": {"a":1}"#))
    }

    @Test("A decimal wider than a 64-bit integer still writes as a decimal")
    func wideDecimalKeepsItsType() throws {
        let digits = "12345678901234567890123456789012"
        let stmt = try #require(update(column: "price", to: .text(digits), kinds: ["price": .decimal128]))
        #expect(stmt.contains("{\"$numberDecimal\": \"\(digits)\"}"))
    }

    @Test("A half-typed brace is written, not mistaken for truncated text")
    func userTypedBraceStillWrites() throws {
        let stmt = try #require(update(column: "note", to: .text("{draft"), kinds: [:]))
        #expect(stmt.contains(#""note": "{draft""#))
    }

    // MARK: - Dates and ObjectIds

    @Test("A date column is written as a BSON date, not the text the grid shows")
    func dateColumnWritesADate() throws {
        let stmt = try #require(update(column: "when", to: .text("2024-01-02T03:04:05Z"), kinds: ["when": .date]))
        #expect(stmt.contains(#""when": {"$date": {"$numberLong": "1704164645000"}}"#))
    }

    @Test("A date the picker wrote is read in the local zone, which is the zone the picker shows")
    func pickedDateIsLocalWallClock() throws {
        let stmt = try #require(update(column: "when", to: .text("2024-01-02 03:04:05"), kinds: ["when": .date]))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let local = try #require(formatter.date(from: "2024-01-02 03:04:05"))
        let millis = Int64((local.timeIntervalSince1970 * 1_000).rounded())
        #expect(stmt.contains("{\"$date\": {\"$numberLong\": \"\(millis)\"}}"))
    }

    @Test("A date-only value is a date too")
    func dateOnlyIsADate() throws {
        let stmt = try #require(update(column: "day", to: .text("2024-01-02"), kinds: ["day": .date]))
        #expect(stmt.contains(#""day": {"$date": "#))
    }

    @Test("A bare number typed into a date column stays a number rather than becoming 1970")
    func numberInADateColumnStaysANumber() throws {
        let stmt = try #require(update(column: "day", to: .text("2024"), kinds: ["day": .date]))
        #expect(stmt.contains(#""day": 2024"#))
    }

    @Test("A field holding ObjectIds keeps holding ObjectIds")
    func objectIdColumnWritesAnObjectId() throws {
        let stmt = try #require(update(
            column: "authorId", to: .text("65a1b2c3d4e5f60718293a4b"), kinds: ["authorId": .objectId]
        ))
        #expect(stmt.contains(#""authorId": {"$oid": "65a1b2c3d4e5f60718293a4b"}"#))
    }

    // MARK: - Declared kinds

    @Test("A field the validator declares a string is written as one, whatever the text looks like")
    func declaredStringIsAlwaysAString() throws {
        for text in ["123", "true", "null", "[1, 2]"] {
            let stmt = try #require(update(column: "code", to: .text(text), kinds: [:], declared: ["code": .string]))
            let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
            #expect(stmt.contains("\"code\": \"\(escaped)\""), "\(text)")
        }
    }

    @Test("A sampled string column still reads typed JSON, because sampling is a majority vote")
    func sampledStringKeepsItsSpelling() throws {
        let stmt = try #require(update(column: "meta", to: .text(#"{"a":1}"#), kinds: ["meta": .string]))
        #expect(stmt.contains(#""meta": {"a":1}"#))
    }

    @Test("A declared type outranks what the sampled documents held")
    func declaredKindWins() throws {
        let stmt = try #require(update(
            column: "rate", to: .text("3"), kinds: ["rate": .int32], declared: ["rate": .double]
        ))
        #expect(stmt.contains(#"{"$numberDouble": "3"}"#))
    }

    @Test("An int field takes a bare number that fits in 32 bits")
    func int32ColumnWritesABareNumber() throws {
        let stmt = try #require(update(column: "n", to: .text("42"), kinds: [:], declared: ["n": .int32]))
        #expect(stmt.contains(#""n": 42"#))
    }

    // MARK: - Numbers past a double

    /// Measured with JavaScriptCore: `JSON.stringify({a: 9007199254740993})` gives
    /// `9007199254740992`, so the bare literal reached the server one off.
    @Test("An integer past 2^53 is written as a 64-bit integer so JavaScript cannot round it")
    func hugeIntegerIsNotRounded() throws {
        let stmt = try #require(update(column: "big", to: .text("9007199254740993"), kinds: [:]))
        #expect(stmt.contains(#""big": {"$numberLong": "9007199254740993"}"#))
    }

    @Test("An integer JavaScript holds exactly stays bare")
    func exactIntegerStaysBare() throws {
        let stmt = try #require(update(column: "n", to: .text("9007199254740992"), kinds: [:]))
        #expect(stmt.contains(#""n": 9007199254740992"#))
    }

    // MARK: - Statements are code

    /// The statement is JavaScript the shell evaluates, so text that only looks like an array
    /// used to be pasted in as code.
    @Test("Stored text shaped like an array but not JSON is written as a string, never run")
    func arrayShapedCodeIsAString() throws {
        let hostile = #"[db.getCollection("audit").drop()]"#
        let stmt = try #require(update(column: "note", to: .text(hostile), kinds: [:]))
        #expect(stmt.contains("\"note\": \(MongoScriptJson.jsonString(hostile))"))
        #expect(!stmt.contains(#""note": [db"#))
    }

    @Test("Stored text shaped like a document but not JSON is written as a string, never run")
    func documentShapedCodeIsAString() throws {
        let hostile = #"{a: db.dropDatabase()}"#
        let stmt = try #require(update(column: "note", to: .text(hostile), kinds: [:]))
        #expect(stmt.contains("\"note\": \(MongoScriptJson.jsonString(hostile))"))
    }

    /// U+0600 is a Unicode Prepend character, so it and the quote after it are one `Character`, which
    /// matched no escape case and went into the statement raw, closing the string literal early.
    @Test("A quote joined to a Prepend character is still escaped, so the value cannot close its string")
    func quoteInsideAGraphemeClusterIsEscaped() throws {
        let hostile = "x\u{0600}\"}}); db.getCollection(\"victim\").drop(); db.x.find({\"a\": {\"b\": \""
        let stmt = try #require(update(column: "note", to: .text(hostile), kinds: [:], declared: ["note": .string]))
        let start = try #require(stmt.range(of: "\"$set\": ")).upperBound
        let setDocument = String(stmt[start...].dropLast(2))
        let data = try #require(setDocument.data(using: .utf8))
        let parsed = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(parsed["note"] as? String == hostile)
    }

    /// Measured on macOS 27: `JSONSerialization` refuses each of these, so none reaches the statement
    /// as source. This pins it, because a parser that stopped at the first complete value would let
    /// the rest run.
    @Test("JSON followed by more text is written as a string, never pasted as source")
    func jsonPrefixWithTrailingCodeIsAString() throws {
        let payloads = [
            "{}, injected: db.dropDatabase(), tail: {}",
            #"{"a":1}, db.dropDatabase(), {}"#,
            "[1], db.dropDatabase(), [2]"
        ]
        for hostile in payloads {
            let stmt = try #require(update(column: "note", to: .text(hostile), kinds: [:]))
            #expect(stmt.contains("\"note\": \(MongoScriptJson.jsonString(hostile))"), "\(hostile)")
            let gen = MongoDBStatementGenerator(collectionName: "notes", columns: ["_id", "note"])
            let restored = try #require(gen.generateRestore(rows: [["507f1f77bcf86cd799439011", .text(hostile)]])?.first)
            #expect(restored.statement.contains("\"note\": \(MongoScriptJson.jsonString(hostile))"), "\(hostile)")
        }
    }

    @Test("Restoring a deleted row writes a hostile stored string back as a string")
    func restoreDoesNotRunStoredText() throws {
        let gen = MongoDBStatementGenerator(collectionName: "notes", columns: ["_id", "body"])
        let hostile = #"[db.getCollection("audit").drop()]"#
        let statement = try #require(gen.generateRestore(rows: [["507f1f77bcf86cd799439011", .text(hostile)]])?.first)
        #expect(statement.statement.contains("\"body\": \(MongoScriptJson.jsonString(hostile))"))
    }

    // MARK: - _id

    private func updateFilter(
        id: String,
        idKind: BsonValueKind?,
        sampledKinds: [String: BsonValueKind] = [:]
    ) -> String? {
        let gen = MongoDBStatementGenerator(
            collectionName: "codes",
            columns: ["_id", "label"],
            columnKinds: sampledKinds,
            identityKind: idKind
        )
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(columnIndex: 1, columnName: "label", oldValue: .text("a"), newValue: .text("b"))],
            originalRow: [.text(id), .text("a")]
        )
        return gen.generateStatements(
            from: [change], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
        ).first?.statement
    }

    @Test("A string _id that looks like a number is matched as a string")
    func stringIdIsMatchedAsAString() throws {
        let stmt = try #require(updateFilter(id: "1001", idKind: .string))
        #expect(stmt.contains(#"{"_id": "1001"}"#))
    }

    @Test("A string _id that looks like an ObjectId is matched as a string")
    func hexStringIdIsMatchedAsAString() throws {
        let stmt = try #require(updateFilter(id: "65a1b2c3d4e5f60718293a4b", idKind: .string))
        #expect(stmt.contains(#"{"_id": "65a1b2c3d4e5f60718293a4b"}"#))
    }

    @Test("A 64-bit _id is matched as one")
    func longIdIsMatchedAsALong() throws {
        let stmt = try #require(updateFilter(id: "42", idKind: .int64))
        #expect(stmt.contains(#"{"_id": {"$numberLong": "42"}}"#))
    }

    @Test("A mostly-string _id column does not quote a row whose _id kinds differ")
    func mixedIdKindsFallBackToTheSpelling() throws {
        let stmt = try #require(updateFilter(
            id: "65a1b2c3d4e5f60718293a4b", idKind: nil, sampledKinds: ["_id": .string]
        ))
        #expect(stmt.contains(#"{"_id": {"$oid": "65a1b2c3d4e5f60718293a4b"}}"#))
    }

    /// JavaScriptCore evaluates a bare `010` in a statement as the octal number 8.
    @Test("An int written with a leading zero is sent as its decimal value")
    func int32IsCanonicalised() throws {
        let stmt = try #require(update(column: "n", to: .text("010"), kinds: [:], declared: ["n": .int32]))
        #expect(stmt.contains(#""n": 10"#))
        let negative = try #require(update(column: "n", to: .text("-010"), kinds: ["n": .int32]))
        #expect(negative.contains(#""n": -10"#))
    }

    @Test("An _id of unknown kind is still read from its spelling")
    func unknownIdFallsBackToItsSpelling() throws {
        let stmt = try #require(updateFilter(id: "65a1b2c3d4e5f60718293a4b", idKind: nil))
        #expect(stmt.contains(#"{"_id": {"$oid": "65a1b2c3d4e5f60718293a4b"}}"#))
    }
}
