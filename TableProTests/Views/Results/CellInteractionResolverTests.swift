//
//  CellInteractionResolverTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("CellInteractionResolver - read-only path")
struct CellInteractionResolverReadOnlyTests {
    private let resolver = CellInteractionResolver()

    @Test("deleted row returns blocked regardless of editability")
    func deletedRowReturnsBlocked() {
        let context = ContextFactory.make(value: "hello", isTableEditable: false, isRowDeleted: true)
        #expect(resolver.resolve(context) == .blocked)
    }

    @Test("deleted row blocked even in editable table")
    func deletedRowBlockedInEditableTable() {
        let context = ContextFactory.make(value: "hello", isTableEditable: true, isRowDeleted: true)
        #expect(resolver.resolve(context) == .blocked)
    }

    @Test("read-only plain text returns viewInline with value")
    func readOnlyPlainTextReturnsViewInline() {
        let context = ContextFactory.make(value: "hello", isTableEditable: false)
        #expect(resolver.resolve(context) == .viewInline(value: "hello"))
    }

    @Test("read-only single-line text returns viewInline")
    func readOnlySingleLineReturnsViewInline() {
        let context = ContextFactory.make(value: "A", isTableEditable: false)
        #expect(resolver.resolve(context) == .viewInline(value: "A"))
    }

    @Test("read-only nil value returns viewInline with NULL placeholder")
    func readOnlyNilValueReturnsViewInlineWithNull() {
        let context = ContextFactory.make(value: nil, isTableEditable: false)
        #expect(resolver.resolve(context) == .viewInline(value: "NULL"))
    }

    @Test("read-only multiline text returns viewInline")
    func readOnlyMultilineReturnsViewInline() {
        let context = ContextFactory.make(value: "line1\nline2", isTableEditable: false)
        #expect(resolver.resolve(context) == .viewInline(value: "line1\nline2"))
    }

    @Test("read-only JSON column returns viewJson")
    func readOnlyJsonColumnReturnsViewJson() {
        let context = ContextFactory.make(value: #"{"k":1}"#, columnType: .json(rawType: "JSON"), isTableEditable: false)
        #expect(resolver.resolve(context) == .viewJson)
    }

    @Test("read-only BLOB column returns viewBlob")
    func readOnlyBlobColumnReturnsViewBlob() {
        let context = ContextFactory.make(value: nil, columnType: .blob(rawType: "BLOB"), isTableEditable: false)
        #expect(resolver.resolve(context) == .viewBlob)
    }

    @Test("immutable column on editable table follows read-only path for plain text")
    func immutableColumnFollowsReadOnlyPath() {
        let context = ContextFactory.make(value: "id-123", isTableEditable: true, isImmutableColumn: true)
        #expect(resolver.resolve(context) == .viewInline(value: "id-123"))
    }

    @Test("immutable JSON column on editable table still returns viewJson")
    func immutableJsonColumnReturnsViewJson() {
        let context = ContextFactory.make(value: "{}", columnType: .json(rawType: "JSON"), isTableEditable: true, isImmutableColumn: true)
        #expect(resolver.resolve(context) == .viewJson)
    }

    @Test("read-only FK column falls through to viewInline")
    func readOnlyForeignKeyReturnsViewInline() {
        let fkInfo = ForeignKeyInfo(name: "fk", column: "uid", referencedTable: "u", referencedColumn: "id")
        let context = ContextFactory.make(
            value: "42",
            columnType: .integer(rawType: "INT"),
            isTableEditable: false,
            foreignKeyInfo: fkInfo
        )
        #expect(resolver.resolve(context) == .viewInline(value: "42"))
    }

    @Test("read-only JSON-looking plain text without columnType returns viewInline, not viewJson")
    func readOnlyJsonLikeTextWithoutTypeReturnsViewInline() {
        let context = ContextFactory.make(value: #"{"k":1}"#, columnType: nil, isTableEditable: false)
        #expect(resolver.resolve(context) == .viewInline(value: #"{"k":1}"#))
    }
}

@Suite("CellInteractionResolver - editable path")
struct CellInteractionResolverEditableTests {
    private let resolver = CellInteractionResolver()

    @Test("editable plain single-line returns editInline")
    func editablePlainSingleLineReturnsEditInline() {
        let context = ContextFactory.make(value: "hello", isTableEditable: true)
        #expect(resolver.resolve(context) == .editInline(value: "hello"))
    }

    @Test("editable plain multiline returns editOverlay")
    func editablePlainMultilineReturnsEditOverlay() {
        let context = ContextFactory.make(value: "line1\nline2", isTableEditable: true)
        #expect(resolver.resolve(context) == .editOverlay(value: "line1\nline2"))
    }

    @Test("editable plain text that looks like JSON returns editJson")
    func editableJsonLikeTextReturnsEditJson() {
        let context = ContextFactory.make(value: #"{"k":1}"#, isTableEditable: true)
        #expect(resolver.resolve(context) == .editJson)
    }

    @Test("editable JSON column returns editJson")
    func editableJsonColumnReturnsEditJson() {
        let context = ContextFactory.make(value: "{}", columnType: .json(rawType: "JSON"), isTableEditable: true)
        #expect(resolver.resolve(context) == .editJson)
    }

    @Test("editable BLOB column returns editBlob")
    func editableBlobColumnReturnsEditBlob() {
        let context = ContextFactory.make(value: nil, columnType: .blob(rawType: "BLOB"), isTableEditable: true)
        #expect(resolver.resolve(context) == .editBlob)
    }

    @Test("editable foreign key column returns editForeignKey")
    func editableForeignKeyReturnsEditForeignKey() {
        let fkInfo = ForeignKeyInfo(name: "fk_users", column: "user_id", referencedTable: "users", referencedColumn: "id")
        let context = ContextFactory.make(
            value: "1",
            columnType: .integer(rawType: "INT"),
            isTableEditable: true,
            foreignKeyInfo: fkInfo
        )
        #expect(resolver.resolve(context) == .editForeignKey(fkInfo))
    }

    @Test("editable FK column with nil columnType still returns editForeignKey")
    func editableForeignKeyNilColumnTypeReturnsEditForeignKey() {
        let fkInfo = ForeignKeyInfo(name: "fk", column: "uid", referencedTable: "u", referencedColumn: "id")
        let context = ContextFactory.make(
            value: "1",
            columnType: nil,
            isTableEditable: true,
            foreignKeyInfo: fkInfo
        )
        #expect(resolver.resolve(context) == .editForeignKey(fkInfo))
    }

    @Test("editable dropdown column returns editDropdown")
    func editableDropdownColumnReturnsEditDropdown() {
        let context = ContextFactory.make(value: "true", isTableEditable: true, isDropdownColumn: true)
        #expect(resolver.resolve(context) == .editDropdown)
    }

    @Test("editable type-picker column returns editTypePicker")
    func editableTypePickerColumnReturnsEditTypePicker() {
        let context = ContextFactory.make(value: "TEXT", isTableEditable: true, isTypePickerColumn: true)
        #expect(resolver.resolve(context) == .editTypePicker)
    }

    @Test("editable enum column returns editEnum")
    func editableEnumColumnReturnsEditEnum() {
        let context = ContextFactory.make(
            value: "small",
            columnType: .enumType(rawType: "ENUM", values: ["small", "medium", "large"]),
            isTableEditable: true,
            hasEnumValues: true
        )
        #expect(resolver.resolve(context) == .editEnum)
    }

    @Test("editable set column returns editSet")
    func editableSetColumnReturnsEditSet() {
        let context = ContextFactory.make(
            value: "a,b",
            columnType: .set(rawType: "SET", values: ["a", "b", "c"]),
            isTableEditable: true,
            hasEnumValues: true
        )
        #expect(resolver.resolve(context) == .editSet)
    }

    @Test("dropdown column takes priority over column type")
    func dropdownColumnPriorityOverType() {
        let context = ContextFactory.make(
            value: nil,
            columnType: .json(rawType: "JSON"),
            isTableEditable: true,
            isDropdownColumn: true
        )
        #expect(resolver.resolve(context) == .editDropdown)
    }
}

private enum ContextFactory {
    static func make(
        value: String?,
        columnType: ColumnType? = nil,
        isTableEditable: Bool = false,
        isRowDeleted: Bool = false,
        isImmutableColumn: Bool = false,
        foreignKeyInfo: ForeignKeyInfo? = nil,
        isDropdownColumn: Bool = false,
        isTypePickerColumn: Bool = false,
        hasEnumValues: Bool = false
    ) -> CellContext {
        CellContext(
            row: 0,
            columnIndex: 0,
            columnName: "col",
            columnType: columnType,
            value: value,
            isTableEditable: isTableEditable,
            isRowDeleted: isRowDeleted,
            isImmutableColumn: isImmutableColumn,
            foreignKeyInfo: foreignKeyInfo,
            isDropdownColumn: isDropdownColumn,
            isTypePickerColumn: isTypePickerColumn,
            hasEnumValues: hasEnumValues
        )
    }
}
