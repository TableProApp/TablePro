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

    @Test("A legacy UUID exports as BSON binary so the dump re-imports as binary")
    func legacyUuidExportsAsBinary() {
        let value = MQLExportHelpers.mqlJsonValue(for: "LegacyJavaUUID(\"\(Self.uuid)\")")
        #expect(value == "{\"$binary\": {\"base64\": \"JEMlSusD0IwaDdri/Igykw==\", \"subType\": \"03\"}}")
    }

    @Test("A standard UUID exports as BSON binary subtype 4")
    func standardUuidExportsAsBinary() {
        let value = MQLExportHelpers.mqlJsonValue(for: "UUID(\"\(Self.uuid)\")")
        #expect(value == "{\"$binary\": {\"base64\": \"jNAD60olQySTMoj84toNGg==\", \"subType\": \"04\"}}")
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
