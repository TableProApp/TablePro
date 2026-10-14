//
//  ColumnClassificationHintTests.swift
//  TableProTests
//
//  The name a column is classified by, once `dataType` carries the server's declared spelling.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct ColumnClassificationHintTests {
    private func columnInfo(
        _ name: String,
        dataType: String,
        hint: String?,
        allowedValues: [String]? = nil
    ) -> ColumnInfo {
        ColumnInfo(
            name: name,
            dataType: dataType,
            isNullable: true,
            isPrimaryKey: false,
            allowedValues: allowedValues,
            classificationTypeName: hint
        )
    }

    @Test("A plugin column's hint reaches the app model and its editable definition")
    func hintCrossesTheMapper() throws {
        let plugin = PluginColumnInfo(
            name: "st",
            dataType: "status",
            generationExpression: nil,
            generationKind: nil,
            ddlSpelling: "public.status",
            ddlDefault: nil,
            ddlGenerationExpression: nil,
            ddlCollation: nil,
            classificationTypeName: "ENUM"
        )
        let column = ColumnInfo(plugin)
        #expect(column.dataType == "status")
        #expect(column.typeNameForClassification == "ENUM")

        let editable = EditableColumnDefinition.from(column)
        #expect(editable.dataType == "status")
        #expect(editable.typeNameForClassification == "ENUM")
        #expect(editable.toColumnInfo().classificationTypeName == "ENUM")
    }

    @Test("The hint retires when the type is edited and returns when the edit is undone")
    func hintFollowsTheTypeItWasReadWith() {
        var column = EditableColumnDefinition.from(columnInfo("st", dataType: "status", hint: "ENUM"))
        column.dataType = "text"
        #expect(column.classificationTypeName == nil)
        #expect(column.typeNameForClassification == "text")
        column.dataType = "status"
        #expect(column.typeNameForClassification == "ENUM")
    }

    @Test("The hint is not encoded, because it names the reading connection's catalog")
    func hintIsNotEncoded() throws {
        let column = EditableColumnDefinition.from(columnInfo("st", dataType: "status", hint: "ENUM"))
        let decoded = try JSONDecoder().decode(
            EditableColumnDefinition.self, from: try JSONEncoder().encode(column)
        )
        #expect(decoded.dataType == "status")
        #expect(decoded.classificationTypeName == nil)
        #expect(decoded.typeNameForClassification == "status")
    }

    @Test("Dropping the catalog spellings keeps the hint, because it names a kind and not an object")
    func dropKeepsTheHint() {
        var column = EditableColumnDefinition.from(columnInfo("p", dataType: "posint", hint: "INTEGER"))
        column.dropCatalogSpellings()
        #expect(column.typeNameForClassification == "INTEGER")
    }

    @Test("A schema column entry classifies by the hint, and by the declared type without one")
    func schemaColumnsClassifyByTheHint() {
        let entry = SchemaColumnStore.Entry(fetchedColumns: [
            columnInfo("p", dataType: "posint", hint: "INTEGER"),
            columnInfo("st", dataType: "status", hint: "ENUM", allowedValues: ["new"]),
            columnInfo("v", dataType: "character varying(50)", hint: nil),
            columnInfo("g", dataType: "public.geometry(Point,4326)", hint: "geometry"),
            columnInfo("ra", dataType: "real[]", hint: nil)
        ])
        #expect(entry.columnTypes["p"] == .integer(rawType: "INTEGER"))
        #expect(entry.columnTypes["st"]?.isEnumType == true)
        #expect(ColumnTypeSQLQuoting.isCharacterType(entry.columnTypes["v"]) == true)
        #expect(entry.columnTypes["g"] == .spatial(rawType: "geometry"))
        /// `real[]` used to reach the classifier as `float4[]`, which no table names, so an array of
        /// numbers read as an array of text. The result path already reported `real[]`.
        #expect(entry.columnTypes["ra"] == .array(rawType: "real[]", element: .decimal(rawType: "real")))
    }

    @Test("A PostgreSQL column crosses to MySQL by its hint and keeps its declared modifier")
    func crossEngineReadsTheHint() throws {
        let snapshot = TableStructureSnapshot(
            name: "t",
            schema: "public",
            columns: [
                EditableColumnDefinition.from(columnInfo("p", dataType: "posint", hint: "INTEGER")),
                EditableColumnDefinition.from(columnInfo("v", dataType: "character varying(50)", hint: nil)),
                EditableColumnDefinition.from(
                    columnInfo("ts", dataType: "timestamp(3) with time zone", hint: nil)
                )
            ]
        )
        let result = CrossEngineStructureTranslator.translate(snapshot, from: .postgresql, to: .mysql)
        #expect(result.snapshot.columns.map(\.dataType) == ["INT", "VARCHAR(50)", "DATETIME(3)"])
    }
}
