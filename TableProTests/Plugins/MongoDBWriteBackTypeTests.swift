//
//  MongoDBWriteBackTypeTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("MongoDB Write Back Types")
struct MongoDBWriteBackTypeTests {
    private func update(
        column: String,
        to newValue: PluginCellValue,
        kinds: [String: BsonValueKind]
    ) -> String? {
        let gen = MongoDBStatementGenerator(
            collectionName: "products",
            columns: ["_id", column],
            columnKinds: kinds
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
}
