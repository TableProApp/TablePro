//
//  PluginColumnInfoCollationCodableTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct PluginColumnInfoCollationCodableTests {
    @Test("The collation spelling round-trips through JSON encoding")
    func ddlCollationRoundTrip() throws {
        let original = PluginColumnInfo(
            name: "code",
            dataType: "TEXT",
            collation: "Case Insens",
            generationExpression: nil,
            generationKind: nil,
            ddlSpelling: "text",
            ddlDefault: nil,
            ddlGenerationExpression: nil,
            ddlCollation: #"app."Case Insens""#,
            classificationTypeName: "ENUM"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PluginColumnInfo.self, from: data)
        #expect(decoded.ddlCollation == #"app."Case Insens""#)
        #expect(decoded.collation == "Case Insens")
    }

    /// The signature every plugin built against kit 32 carries. It has to keep resolving, and it
    /// has to keep meaning "this driver names no classified type", or the app would classify a
    /// column by a hint the plugin never set.
    @Test("The initializer published before the classification hint still resolves, and sets none")
    func initializerWithoutTheHintKeepsResolving() {
        let column = PluginColumnInfo(
            name: "geom",
            dataType: "geometry",
            generationExpression: nil,
            generationKind: nil,
            ddlSpelling: "public.geometry(Point,4326)",
            ddlDefault: nil,
            ddlGenerationExpression: nil,
            ddlCollation: nil
        )
        #expect(column.classificationTypeName == nil)
        #expect(column.typeNameForClassification == "geometry")
    }

    @Test("A payload written before the collation spelling existed decodes with none")
    func payloadWithoutDDLCollationDecodesToNil() throws {
        let legacyJson = Data("""
        {
            "name": "code",
            "dataType": "TEXT",
            "isNullable": true,
            "isPrimaryKey": false,
            "isGenerated": false,
            "collation": "C",
            "ddlSpelling": "text"
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(PluginColumnInfo.self, from: legacyJson)
        #expect(decoded.ddlCollation == nil)
        #expect(decoded.collation == "C")
        #expect(decoded.ddlSpelling == "text")
    }

    @Test("The initializers published before the collation spelling leave it nil")
    func olderInitializersLeaveCollationSpellingNil() {
        let column = PluginColumnInfo(
            name: "code",
            dataType: "TEXT",
            collation: "C",
            generationExpression: nil,
            generationKind: nil,
            ddlSpelling: "text",
            ddlDefault: nil,
            ddlGenerationExpression: nil
        )
        #expect(column.ddlCollation == nil)
        let definition = PluginColumnDefinition(
            name: "code",
            dataType: "TEXT",
            collation: "C",
            generationExpression: nil,
            generationKind: nil,
            ddlSpelling: "text",
            ddlDefault: nil,
            ddlGenerationExpression: nil
        )
        #expect(definition.ddlCollation == nil)
    }
}
