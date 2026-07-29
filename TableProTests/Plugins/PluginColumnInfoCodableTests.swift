import Foundation
import TableProPluginKit
import Testing

@Suite("PluginColumnInfo Codable")
struct PluginColumnInfoCodableTests {
    @Test("allowedValues round-trips through JSON encoding")
    func allowedValuesRoundTrip() throws {
        let original = PluginColumnInfo(
            name: "status",
            dataType: "ENUM",
            allowedValues: ["active", "inactive", "pending"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PluginColumnInfo.self, from: data)
        #expect(decoded.allowedValues == ["active", "inactive", "pending"])
    }

    @Test("nil allowedValues encodes and decodes back to nil")
    func nilAllowedValuesRoundTrip() throws {
        let original = PluginColumnInfo(name: "id", dataType: "INTEGER")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PluginColumnInfo.self, from: data)
        #expect(decoded.allowedValues == nil)
    }

    @Test("decoding a payload without allowedValues keeps it nil for forward compatibility")
    func legacyPayloadDecodesToNilAllowedValues() throws {
        let legacyJson = """
        {
            "name": "id",
            "dataType": "INTEGER",
            "isNullable": false,
            "isPrimaryKey": true,
            "isGenerated": false
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PluginColumnInfo.self, from: legacyJson)
        #expect(decoded.allowedValues == nil)
        #expect(decoded.name == "id")
        #expect(decoded.isPrimaryKey)
    }
}
