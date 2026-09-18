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
        let legacyJson = Data("""
        {
            "name": "id",
            "dataType": "INTEGER",
            "isNullable": false,
            "isPrimaryKey": true,
            "isGenerated": false
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(PluginColumnInfo.self, from: legacyJson)
        #expect(decoded.allowedValues == nil)
        #expect(decoded.name == "id")
        #expect(decoded.isPrimaryKey)
    }

    @Test("The DDL spellings round-trip through JSON encoding")
    func ddlSpellingRoundTrip() throws {
        let original = PluginColumnInfo(
            name: "shape",
            dataType: "geometry",
            generationExpression: nil,
            generationKind: nil,
            ddlSpelling: "public.geometry(Point,4326)",
            ddlDefault: "public.st_geomfromtext('POINT(0 0)'::text, 4326)",
            ddlGenerationExpression: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PluginColumnInfo.self, from: data)
        #expect(decoded.ddlSpelling == "public.geometry(Point,4326)")
        #expect(decoded.ddlDefault == "public.st_geomfromtext('POINT(0 0)'::text, 4326)")
    }

    @Test("A payload written before the DDL spellings existed decodes with none")
    func payloadWithoutDDLSpellingDecodesToNil() throws {
        let legacyJson = Data("""
        {
            "name": "shape",
            "dataType": "geometry",
            "isNullable": true,
            "isPrimaryKey": false,
            "isGenerated": false
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(PluginColumnInfo.self, from: legacyJson)
        #expect(decoded.ddlSpelling == nil)
        #expect(decoded.ddlDefault == nil)
        #expect(decoded.ddlGenerationExpression == nil)
        #expect(decoded.dataType == "geometry")
    }
}
