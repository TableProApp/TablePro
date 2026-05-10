//
//  ColumnDefinitionTests.swift
//  TablePro
//
//  Tests for EditableColumnDefinition
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("Editable Column Definition")
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
    }
}
