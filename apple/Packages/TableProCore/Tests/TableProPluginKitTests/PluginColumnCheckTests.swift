import Foundation
import TableProPluginKit
import Testing

struct PluginColumnCheckTests {
    @Test("A column's own CHECK round-trips through JSON encoding")
    func columnCheckRoundTrip() throws {
        let original = PluginColumnInfo(
            name: "payload",
            dataType: "LONGTEXT",
            generationExpression: nil,
            generationKind: nil,
            ddlSpelling: nil,
            ddlDefault: nil,
            ddlGenerationExpression: nil,
            ddlCollation: nil,
            classificationTypeName: nil,
            columnCheck: "json_valid(`payload`)"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PluginColumnInfo.self, from: data)
        #expect(decoded.columnCheck == "json_valid(`payload`)")
    }

    @Test("A payload written before the column CHECK existed decodes with none")
    func legacyPayloadDecodesToNil() throws {
        let legacyJson = Data("""
        {
            "name": "payload",
            "dataType": "LONGTEXT",
            "isNullable": true,
            "isPrimaryKey": false,
            "isGenerated": false,
            "classificationTypeName": "JSON"
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(PluginColumnInfo.self, from: legacyJson)
        #expect(decoded.columnCheck == nil)
        #expect(decoded.classificationTypeName == "JSON")
    }

    /// The signatures every plugin built against kit 40 carries. They have to keep resolving, and keep
    /// meaning "no check", or a driver that never read one would restate one.
    @Test("The initializers published before the column CHECK still resolve, and set none")
    func olderInitializersLeaveItNil() {
        let column = PluginColumnInfo(
            name: "n",
            dataType: "INT",
            generationExpression: nil,
            generationKind: nil,
            ddlSpelling: nil,
            ddlDefault: nil,
            ddlGenerationExpression: nil,
            ddlCollation: nil,
            classificationTypeName: nil
        )
        #expect(column.columnCheck == nil)
        let definition = PluginColumnDefinition(
            name: "n",
            dataType: "INT",
            generationExpression: nil,
            generationKind: nil,
            ddlSpelling: nil,
            ddlDefault: nil,
            ddlGenerationExpression: nil,
            ddlCollation: nil
        )
        #expect(definition.columnCheck == nil)
    }

    @Test("A column definition carries the CHECK it was given")
    func definitionCarriesTheCheck() {
        let definition = PluginColumnDefinition(
            name: "n",
            dataType: "INT",
            generationExpression: nil,
            generationKind: nil,
            ddlSpelling: nil,
            ddlDefault: nil,
            ddlGenerationExpression: nil,
            ddlCollation: nil,
            columnCheck: "`n` > 0"
        )
        #expect(definition.columnCheck == "`n` > 0")
    }
}
