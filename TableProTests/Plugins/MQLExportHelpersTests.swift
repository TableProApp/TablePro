//
//  MQLExportHelpersTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("MQL Export Helpers")
struct MQLExportHelpersTests {
    private static let uuid = "8cd003eb-4a25-4324-9332-88fce2da0d1a"

    /// The dump is a mongosh script, so a value has to be a constructor call. mongosh reads
    /// `{"$binary": ...}` as a plain object literal and would insert a subdocument.
    @Test("A legacy UUID exports as a BinData constructor carrying its subtype")
    func legacyUuidExportsAsBinData() {
        let value = MQLExportHelpers.mqlJsonValue(for: "LegacyJavaUUID(\"\(Self.uuid)\")")
        #expect(value == "BinData(3, \"JEMlSusD0IwaDdri/Igykw==\")")
    }

    @Test("A standard UUID exports as a BinData constructor with subtype 4")
    func standardUuidExportsAsBinData() {
        let value = MQLExportHelpers.mqlJsonValue(for: "UUID(\"\(Self.uuid)\")")
        #expect(value == "BinData(4, \"jNAD60olQySTMoj84toNGg==\")")
    }

    @Test("Raw binary keeps the subtype its column reported")
    func rawBinaryKeepsSubtype() {
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF])
        #expect(MQLExportHelpers.mqlBinaryValue(for: data, subtype: 5) == "BinData(5, \"3q2+7w==\")")
        #expect(MQLExportHelpers.mqlBinaryValue(for: data, subtype: 0) == "BinData(0, \"3q2+7w==\")")
    }

    @Test("A column type name carries the subtype back out")
    func columnTypeNameRoundTrip() {
        #expect(MongoDBUuidCodec.columnTypeName(forSubtype: 0) == "BLOB")
        #expect(MongoDBUuidCodec.columnTypeName(forSubtype: 5) == "BLOB(5)")
        #expect(MongoDBUuidCodec.binarySubtype(fromColumnTypeName: "BLOB") == 0)
        #expect(MongoDBUuidCodec.binarySubtype(fromColumnTypeName: "BLOB(5)") == 5)
        #expect(MongoDBUuidCodec.binarySubtype(fromColumnTypeName: "BLOB(128)") == 128)
        #expect(MongoDBUuidCodec.binarySubtype(fromColumnTypeName: "") == 0)
        #expect(MongoDBUuidCodec.binarySubtype(fromColumnTypeName: "VARCHAR(255)") == 0)
        #expect(MongoDBUuidCodec.binarySubtype(fromColumnTypeName: "BLOB(999)") == 0)
    }

    @Test("Ordinary values are unaffected", arguments: [
        ("true", "true"),
        ("null", "null"),
        ("42", "42"),
        ("Alice", "\"Alice\""),
        ("UUID-ish", "\"UUID-ish\""),
    ])
    func ordinaryValuesUnchanged(input: String, expected: String) {
        #expect(MQLExportHelpers.mqlJsonValue(for: input) == expected)
    }

    @Test("An ObjectId column exports as an ObjectId constructor")
    func objectIdExportsAsConstructor() {
        let value = MQLExportHelpers.mqlTextValue(
            for: "507f1f77bcf86cd799439011", columnTypeName: "ObjectId"
        )
        #expect(value == "ObjectId(\"507f1f77bcf86cd799439011\")")
    }

    @Test("A value that is not a valid ObjectId falls back to a quoted string")
    func invalidObjectIdFallsBack() {
        #expect(MQLExportHelpers.mqlTextValue(for: "nope", columnTypeName: "ObjectId") == "\"nope\"")
    }

    @Test("A timestamp column exports as an ISODate constructor")
    func timestampExportsAsIsoDate() {
        let value = MQLExportHelpers.mqlTextValue(
            for: "2026-01-01T00:00:00Z", columnTypeName: "TIMESTAMP"
        )
        #expect(value == "ISODate(\"2026-01-01T00:00:00Z\")")

        let fractional = MQLExportHelpers.mqlTextValue(
            for: "2026-01-01T00:00:00.123Z", columnTypeName: "TIMESTAMP"
        )
        #expect(fractional == "ISODate(\"2026-01-01T00:00:00.123Z\")")
    }

    @Test("A non-date in a timestamp column falls back to a quoted string")
    func invalidTimestampFallsBack() {
        #expect(MQLExportHelpers.mqlTextValue(for: "later", columnTypeName: "TIMESTAMP") == "\"later\"")
    }

    @Test("An ordinary column is unaffected by the typed-scalar path")
    func ordinaryColumnUnaffected() {
        #expect(MQLExportHelpers.mqlTextValue(for: "Alice", columnTypeName: "VARCHAR") == "\"Alice\"")
        #expect(MQLExportHelpers.mqlTextValue(for: "42", columnTypeName: "INTEGER") == "42")
        #expect(
            MQLExportHelpers.mqlTextValue(for: "507f1f77bcf86cd799439011", columnTypeName: "VARCHAR")
                == "\"507f1f77bcf86cd799439011\""
        )
    }

    @Test("An exponential double exports as a number, not a quoted string")
    func exponentialDoubleStaysNumeric() {
        #expect(MQLExportHelpers.mqlTextValue(for: "1e-05", columnTypeName: "FLOAT") == "1e-05")
        #expect(MQLExportHelpers.mqlTextValue(for: "1e+20", columnTypeName: "FLOAT") == "1e+20")
        #expect(MQLExportHelpers.mqlTextValue(for: "-3.9192320754595876e-07", columnTypeName: "FLOAT")
            == "-3.9192320754595876e-07")
    }

    @Test("A decimal column exports as NumberDecimal so it does not land as a double")
    func decimalColumnExportsAsNumberDecimal() {
        #expect(
            MQLExportHelpers.mqlTextValue(for: "1847.270000000000000000000000001", columnTypeName: "DECIMAL")
                == "NumberDecimal(\"1847.270000000000000000000000001\")"
        )
    }

    @Test("A non-number in a decimal column falls back to a quoted string")
    func invalidDecimalFallsBack() {
        #expect(MQLExportHelpers.mqlTextValue(for: "n/a", columnTypeName: "DECIMAL") == "\"n/a\"")
    }

    @Test("A value that is not a JSON number stays a quoted string")
    func nonNumericStaysQuoted() {
        #expect(MQLExportHelpers.mqlTextValue(for: "007", columnTypeName: "VARCHAR") == "\"007\"")
        #expect(MQLExportHelpers.mqlTextValue(for: "1.2.3", columnTypeName: "VARCHAR") == "\"1.2.3\"")
    }

    @Test("A collection is addressed as db.<name> only when mongosh would resolve that to it")
    func collectionAccessorAvoidsShadowedNames() {
        #expect(MQLExportHelpers.collectionAccessor(for: "users") == "db.users")
        #expect(MQLExportHelpers.collectionAccessor(for: "stats") == "db.getCollection(\"stats\")")
        #expect(MQLExportHelpers.collectionAccessor(for: "my.data") == "db.getCollection(\"my.data\")")
        #expect(MQLExportHelpers.collectionAccessor(for: "2024") == "db.getCollection(\"2024\")")
    }
}
