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
}
