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

    @Test("read-only JSON-looking plain text without columnType returns viewJson via detector")
    func readOnlyJsonLikeTextWithoutTypeReturnsViewJson() {
        let context = ContextFactory.make(value: #"{"k":1}"#, columnType: nil, isTableEditable: false)
        #expect(resolver.resolve(context) == .viewJson)
    }

    @Test("read-only PHP-shaped plain text returns viewPhpSerialized")
    func readOnlyPhpLikeTextReturnsViewPhpSerialized() {
        let context = ContextFactory.make(value: "a:0:{}", columnType: .text(rawType: "TEXT"), isTableEditable: false)
        #expect(resolver.resolve(context) == .viewPhpSerialized)
    }

    @Test("read-only override .raw beats content sniffing")
    func readOnlyOverrideRawWins() {
        let context = ContextFactory.make(
            value: #"{"k":1}"#,
            columnType: .text(rawType: "TEXT"),
            isTableEditable: false,
            displayFormatOverride: .raw
        )
        #expect(resolver.resolve(context) == .viewInline(value: #"{"k":1}"#))
    }

    @Test("read-only override .json forces viewJson on non-JSON text")
    func readOnlyOverrideJsonForces() {
        let context = ContextFactory.make(
            value: "plain",
            columnType: .text(rawType: "TEXT"),
            isTableEditable: false,
            displayFormatOverride: .json
        )
        #expect(resolver.resolve(context) == .viewJson)
    }

    @Test("read-only override .phpSerialized forces viewPhpSerialized")
    func readOnlyOverridePhpSerializedForces() {
        let context = ContextFactory.make(
            value: "plain",
            columnType: .text(rawType: "TEXT"),
            isTableEditable: false,
            displayFormatOverride: .phpSerialized
        )
        #expect(resolver.resolve(context) == .viewPhpSerialized)
    }

    @Test("read-only override .raw on declared JSON column returns viewInline (override beats type)")
    func readOnlyOverrideRawBypassesJsonColumn() {
        let context = ContextFactory.make(
            value: #"{"k":1}"#,
            columnType: .json(rawType: "JSON"),
            isTableEditable: false,
            displayFormatOverride: .raw
        )
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

    @Test("editable PHP-shaped text returns viewPhpSerialized (read-only)")
    func editablePhpLikeTextReturnsView() {
        let context = ContextFactory.make(value: "a:0:{}", isTableEditable: true)
        #expect(resolver.resolve(context) == .viewPhpSerialized)
    }

    @Test("editable override .phpSerialized forces viewPhpSerialized")
    func editableOverridePhpForces() {
        let context = ContextFactory.make(
            value: "plain",
            isTableEditable: true,
            displayFormatOverride: .phpSerialized
        )
        #expect(resolver.resolve(context) == .viewPhpSerialized)
    }

    @Test("editable override .json forces editJson")
    func editableOverrideJsonForces() {
        let context = ContextFactory.make(
            value: "plain",
            isTableEditable: true,
            displayFormatOverride: .json
        )
        #expect(resolver.resolve(context) == .editJson)
    }

    @Test("editable override .raw bypasses JSON content detection")
    func editableOverrideRawSkipsJson() {
        let context = ContextFactory.make(
            value: #"{"k":1}"#,
            columnType: .text(rawType: "TEXT"),
            isTableEditable: true,
            displayFormatOverride: .raw
        )
        #expect(resolver.resolve(context) == .editInline(value: #"{"k":1}"#))
    }

    @Test("editable override .raw bypasses PHP content detection")
    func editableOverrideRawSkipsPhp() {
        let context = ContextFactory.make(
            value: "a:0:{}",
            columnType: .text(rawType: "TEXT"),
            isTableEditable: true,
            displayFormatOverride: .raw
        )
        #expect(resolver.resolve(context) == .editInline(value: "a:0:{}"))
    }

    @Test("editable override .raw on multiline value returns editOverlay")
    func editableOverrideRawMultilineReturnsOverlay() {
        let context = ContextFactory.make(
            value: "line1\nline2",
            columnType: .text(rawType: "TEXT"),
            isTableEditable: true,
            displayFormatOverride: .raw
        )
        #expect(resolver.resolve(context) == .editOverlay(value: "line1\nline2"))
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

    @Test("editable foreign key column returns editInline (FK popover is not opened by double-click)")
    func editableForeignKeyReturnsEditInline() {
        let context = ContextFactory.make(value: "1", columnType: .integer(rawType: "INT"), isTableEditable: true)
        #expect(resolver.resolve(context) == .editInline(value: "1"))
    }

    @Test("editable boolean column returns editInline, not a picker (pickers are chevron-only)")
    func editableBooleanColumnReturnsEditInline() {
        let context = ContextFactory.make(value: "true", columnType: .boolean(rawType: "BOOL"), isTableEditable: true)
        #expect(resolver.resolve(context) == .editInline(value: "true"))
    }

    @Test("editable enum column returns editInline, not a picker")
    func editableEnumColumnReturnsEditInline() {
        let context = ContextFactory.make(
            value: "small",
            columnType: .enumType(rawType: "ENUM", values: ["small", "medium", "large"]),
            isTableEditable: true
        )
        #expect(resolver.resolve(context) == .editInline(value: "small"))
    }

    @Test("read-only boolean column returns viewInline")
    func readOnlyBooleanColumnReturnsViewInline() {
        let context = ContextFactory.make(value: "true", columnType: .boolean(rawType: "BOOL"), isTableEditable: false)
        #expect(resolver.resolve(context) == .viewInline(value: "true"))
    }
}

private enum ContextFactory {
    static func make(
        value: String?,
        columnType: ColumnType? = nil,
        isTableEditable: Bool = false,
        isRowDeleted: Bool = false,
        isImmutableColumn: Bool = false,
        displayFormatOverride: ValueDisplayFormat? = nil
    ) -> CellContext {
        CellContext(
            columnType: columnType,
            value: value,
            isTableEditable: isTableEditable,
            isRowDeleted: isRowDeleted,
            isImmutableColumn: isImmutableColumn,
            displayFormatOverride: displayFormatOverride
        )
    }
}
