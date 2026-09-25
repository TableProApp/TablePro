//
//  ColumnDefinitionTests.swift
//  TablePro
//
//  Tests for EditableColumnDefinition
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct ColumnDefinitionTests {
    // MARK: - placeholder Tests

    @Test("placeholder creates column with empty name and dataType")
    func placeholderHasEmptyFields() {
        let placeholder = EditableColumnDefinition.placeholder()
        #expect(placeholder.name == "")
        #expect(placeholder.dataType == "")
    }

    @Test("placeholder isValid returns false")
    func placeholderIsNotValid() {
        let placeholder = EditableColumnDefinition.placeholder()
        #expect(placeholder.isValid == false)
    }

    // MARK: - isValid Tests

    @Test("isValid returns true for valid column")
    func validColumnIsValid() {
        let column = EditableColumnDefinition(
            id: UUID(),
            name: "test",
            dataType: "INT",
            isNullable: true,
            defaultValue: nil,
            autoIncrement: false,
            unsigned: false,
            comment: nil,
            collation: nil,
            onUpdate: nil,
            charset: nil,
            extra: nil,
            isPrimaryKey: false
        )
        #expect(column.isValid == true)
    }

    @Test("isValid returns false for whitespace-only name")
    func whitespaceNameIsInvalid() {
        let column = EditableColumnDefinition(
            id: UUID(),
            name: "   ",
            dataType: "INT",
            isNullable: true,
            defaultValue: nil,
            autoIncrement: false,
            unsigned: false,
            comment: nil,
            collation: nil,
            onUpdate: nil,
            charset: nil,
            extra: nil,
            isPrimaryKey: false
        )
        #expect(column.isValid == false)
    }

    @Test("isValid returns false for whitespace-only dataType")
    func whitespaceDataTypeIsInvalid() {
        let column = EditableColumnDefinition(
            id: UUID(),
            name: "test",
            dataType: "   ",
            isNullable: true,
            defaultValue: nil,
            autoIncrement: false,
            unsigned: false,
            comment: nil,
            collation: nil,
            onUpdate: nil,
            charset: nil,
            extra: nil,
            isPrimaryKey: false
        )
        #expect(column.isValid == false)
    }

    // MARK: - Round-trip Conversion Tests

    @Test("from(ColumnInfo) creates EditableColumnDefinition with matching fields")
    func fromColumnInfoRoundTrip() {
        let columnInfo = ColumnInfo(
            name: "user_id",
            dataType: "int(11) unsigned",
            isNullable: false,
            isPrimaryKey: true,
            defaultValue: "0",
            extra: "auto_increment",
            charset: "utf8mb4",
            collation: "utf8mb4_unicode_ci",
            comment: "User identifier"
        )

        let editable = EditableColumnDefinition.from(columnInfo)

        #expect(editable.name == "user_id")
        #expect(editable.dataType == "int(11) unsigned")
        #expect(editable.isNullable == false)
        #expect(editable.isPrimaryKey == true)
        #expect(editable.defaultValue == "0")
        #expect(editable.charset == "utf8mb4")
        #expect(editable.collation == "utf8mb4_unicode_ci")
        #expect(editable.comment == "User identifier")
    }

    @Test("toColumnInfo creates ColumnInfo with matching fields")
    func toColumnInfoRoundTrip() {
        let editable = EditableColumnDefinition(
            id: UUID(),
            name: "email",
            dataType: "varchar(255)",
            isNullable: true,
            defaultValue: "NULL",
            autoIncrement: false,
            unsigned: false,
            comment: "Email address",
            collation: "utf8mb4_unicode_ci",
            onUpdate: nil,
            charset: "utf8mb4",
            extra: nil,
            isPrimaryKey: false
        )

        let columnInfo = editable.toColumnInfo()

        #expect(columnInfo.name == "email")
        #expect(columnInfo.dataType == "varchar(255)")
        #expect(columnInfo.isNullable == true)
        #expect(columnInfo.defaultValue == "NULL")
        #expect(columnInfo.charset == "utf8mb4")
        #expect(columnInfo.collation == "utf8mb4_unicode_ci")
        #expect(columnInfo.comment == "Email address")
        #expect(columnInfo.isPrimaryKey == false)
    }

    @Test("autoIncrement is detected from extra field containing auto_increment")
    func autoIncrementDetection() {
        let columnInfo = ColumnInfo(
            name: "id",
            dataType: "int",
            isNullable: false,
            isPrimaryKey: true,
            defaultValue: nil,
            extra: "auto_increment",
            charset: nil,
            collation: nil,
            comment: nil
        )

        let editable = EditableColumnDefinition.from(columnInfo)
        #expect(editable.autoIncrement == true)
    }

    @Test("unsigned is detected from dataType containing unsigned")
    func unsignedDetection() {
        let columnInfo = ColumnInfo(
            name: "count",
            dataType: "int unsigned",
            isNullable: false,
            isPrimaryKey: false,
            defaultValue: nil,
            extra: nil,
            charset: nil,
            collation: nil,
            comment: nil
        )

        let editable = EditableColumnDefinition.from(columnInfo)
        #expect(editable.unsigned == true)
    }

    @Test("full round-trip preserves data integrity")
    func fullRoundTripPreservesData() {
        let originalInfo = ColumnInfo(
            name: "created_at",
            dataType: "timestamp",
            isNullable: false,
            isPrimaryKey: false,
            defaultValue: "CURRENT_TIMESTAMP",
            extra: "on update CURRENT_TIMESTAMP",
            charset: nil,
            collation: nil,
            comment: "Creation timestamp"
        )

        let editable = EditableColumnDefinition.from(originalInfo)
        let convertedBack = editable.toColumnInfo()

        #expect(convertedBack.name == originalInfo.name)
        #expect(convertedBack.dataType == originalInfo.dataType)
        #expect(convertedBack.isNullable == originalInfo.isNullable)
        #expect(convertedBack.isPrimaryKey == originalInfo.isPrimaryKey)
        #expect(convertedBack.defaultValue == originalInfo.defaultValue)
        #expect(convertedBack.extra == originalInfo.extra)
        #expect(convertedBack.comment == originalInfo.comment)
        #expect(editable.onUpdate == "CURRENT_TIMESTAMP")
    }

    // MARK: - On Update

    @Test("Server-reported on-update timestamp survives a rebuild from the working column")
    func onUpdateSurvivesRebuild() {
        let original = ColumnInfo(
            name: "updated_at",
            dataType: "timestamp",
            isNullable: false,
            isPrimaryKey: false,
            defaultValue: "CURRENT_TIMESTAMP",
            extra: "on update CURRENT_TIMESTAMP",
            charset: nil,
            collation: nil,
            comment: nil
        )

        var editable = EditableColumnDefinition.from(original)
        editable.comment = "touched"
        let rebuilt = EditableColumnDefinition.from(editable.toColumnInfo())

        #expect(rebuilt.onUpdate == "CURRENT_TIMESTAMP")
        #expect(editable.toPlugin().onUpdate == "CURRENT_TIMESTAMP")
    }

    @Test(
        "On-update is parsed out of every EXTRA spelling the server uses",
        arguments: [
            (extra: String?.none, expected: String?.none),
            (extra: "", expected: nil),
            (extra: "auto_increment", expected: nil),
            (extra: "DEFAULT_GENERATED", expected: nil),
            (extra: "on update CURRENT_TIMESTAMP", expected: "CURRENT_TIMESTAMP"),
            (extra: "ON UPDATE CURRENT_TIMESTAMP", expected: "CURRENT_TIMESTAMP"),
            (extra: "on update CURRENT_TIMESTAMP(6)", expected: "CURRENT_TIMESTAMP"),
            (extra: "DEFAULT_GENERATED on update CURRENT_TIMESTAMP", expected: "CURRENT_TIMESTAMP"),
            (extra: "DEFAULT_GENERATED on update CURRENT_TIMESTAMP(3)", expected: "CURRENT_TIMESTAMP")
        ]
    )
    func onUpdateParsing(extra: String?, expected: String?) {
        let columnInfo = ColumnInfo(
            name: "updated_at",
            dataType: "timestamp",
            isNullable: false,
            isPrimaryKey: false,
            defaultValue: nil,
            extra: extra,
            charset: nil,
            collation: nil,
            comment: nil
        )

        #expect(EditableColumnDefinition.from(columnInfo).onUpdate == expected)
    }

    @Test("A placeholder column carries no on-update attribute")
    func placeholderHasNoOnUpdate() {
        #expect(EditableColumnDefinition.placeholder().onUpdate == nil)
    }

    // MARK: - ddlSpelling

    private func spatialColumn() -> EditableColumnDefinition {
        EditableColumnDefinition(
            id: UUID(),
            name: "shape",
            dataType: "geometry",
            isNullable: true,
            defaultValue: "st_geomfromtext('POINT(0 0)'::text, 4326)",
            autoIncrement: false,
            unsigned: false,
            comment: nil,
            collation: nil,
            onUpdate: nil,
            charset: nil,
            extra: nil,
            generationExpression: "st_x(shape)",
            generationKind: .stored,
            isPrimaryKey: false,
            ddlSpelling: "public.geometry(Point,4326)",
            ddlDefault: "public.st_geomfromtext('POINT(0 0)'::text, 4326)",
            ddlGenerationExpression: "public.st_x(shape)"
        )
    }

    @Test("The server's spellings survive construction")
    func ddlSpellingSurvivesInit() {
        let column = spatialColumn()
        #expect(column.ddlSpelling == "public.geometry(Point,4326)")
        #expect(column.ddlDefault == "public.st_geomfromtext('POINT(0 0)'::text, 4326)")
        #expect(column.ddlGenerationExpression == "public.st_x(shape)")
    }

    @Test("Changing a field sets aside only the spelling that described its old value")
    func changingFieldClearsItsOwnSpelling() {
        var retyped = spatialColumn()
        retyped.dataType = "geography"
        #expect(retyped.ddlSpelling == nil)
        #expect(retyped.ddlDefault != nil)
        #expect(retyped.ddlGenerationExpression != nil)

        var redefaulted = spatialColumn()
        redefaulted.defaultValue = nil
        #expect(redefaulted.ddlDefault == nil)
        #expect(redefaulted.ddlSpelling != nil)

        var regenerated = spatialColumn()
        regenerated.generationExpression = "st_y(shape)"
        #expect(regenerated.ddlGenerationExpression == nil)
        #expect(regenerated.ddlSpelling != nil)
    }

    @Test("Changing a field and changing it back restores its spelling and the loaded column")
    func editingAwayAndBackRestoresSpellingAndEquality() {
        let loaded = spatialColumn()
        var edited = loaded
        edited.dataType = "text"
        edited.defaultValue = nil
        edited.generationExpression = "st_y(shape)"
        #expect(edited != loaded)
        edited.dataType = "geometry"
        edited.defaultValue = "st_geomfromtext('POINT(0 0)'::text, 4326)"
        edited.generationExpression = "st_x(shape)"
        #expect(edited == loaded)
        #expect(edited.ddlSpelling == "public.geometry(Point,4326)")
        #expect(edited.ddlDefault == "public.st_geomfromtext('POINT(0 0)'::text, 4326)")
        #expect(edited.ddlGenerationExpression == "public.st_x(shape)")
    }

    @Test("A spelling for a field with no value is not kept")
    func spellingWithoutValueIsDropped() {
        let column = EditableColumnDefinition(
            id: UUID(), name: "id", dataType: "integer", isNullable: false, defaultValue: nil,
            autoIncrement: false, unsigned: false, comment: nil, collation: nil, onUpdate: nil,
            charset: nil, extra: nil, isPrimaryKey: true, ddlSpelling: "integer", ddlDefault: "0"
        )
        #expect(column.ddlDefault == nil)
        #expect(column.ddlSpelling == "integer")
    }

    @Test("Assigning a field its current value keeps its spelling")
    func reassigningSameValueKeepsSpellings() {
        var column = spatialColumn()
        column.dataType = "geometry"
        column.defaultValue = "st_geomfromtext('POINT(0 0)'::text, 4326)"
        column.generationExpression = "st_x(shape)"
        #expect(column.ddlSpelling == "public.geometry(Point,4326)")
        #expect(column.ddlDefault == "public.st_geomfromtext('POINT(0 0)'::text, 4326)")
        #expect(column.ddlGenerationExpression == "public.st_x(shape)")
    }

    @Test("The spelling travels from the column read to the DDL writer")
    func ddlSpellingCarriesThroughConversions() {
        let columnInfo = ColumnInfo(
            name: "status",
            dataType: "ENUM",
            isNullable: true,
            isPrimaryKey: false,
            defaultValue: "'new'::status",
            ddlSpelling: "public.status",
            ddlDefault: "'new'::public.status",
            ddlGenerationExpression: nil
        )
        let editable = EditableColumnDefinition.from(columnInfo)
        let plugin = editable.toPlugin()
        #expect(plugin.ddlSpelling == "public.status")
        #expect(plugin.ddlDefault == "'new'::public.status")
        let roundTripped = editable.toColumnInfo()
        #expect(roundTripped.ddlSpelling == "public.status")
        #expect(roundTripped.ddlDefault == "'new'::public.status")
        #expect(editable.withNewIdentity().ddlDefault == "'new'::public.status")
    }

    @Test("A column decoded from the clipboard carries no spelling from the connection it was copied on")
    func decodingDropsDDLSpelling() throws {
        let data = try JSONEncoder().encode([spatialColumn()])
        let decoded = try JSONDecoder().decode([EditableColumnDefinition].self, from: data)
        #expect(decoded.first?.dataType == "geometry")
        #expect(decoded.first?.defaultValue == "st_geomfromtext('POINT(0 0)'::text, 4326)")
        #expect(decoded.first?.ddlSpelling == nil)
        #expect(decoded.first?.ddlDefault == nil)
        #expect(decoded.first?.ddlGenerationExpression == nil)
    }
}
