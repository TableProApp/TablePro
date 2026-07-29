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

    @Test("read-only BLOB column returns viewBlob")
    func readOnlyBlobColumnReturnsViewBlob() {
        let context = ContextFactory.make(value: nil, columnType: .blob(rawType: "BLOB"), isTableEditable: false)
        #expect(resolver.resolve(context) == .viewBlob)
    }

    @Test("read-only JSON column shows its value inline; the chevron opens the JSON viewer")
    func readOnlyJsonColumnShowsInline() {
        let context = ContextFactory.make(value: #"{"k":1}"#, columnType: .json(rawType: "JSON"), isTableEditable: false)
        #expect(resolver.resolve(context) == .viewInline(value: #"{"k":1}"#))
    }

    @Test("immutable column on editable table follows the read-only inline path")
    func immutableColumnFollowsReadOnlyPath() {
        let context = ContextFactory.make(value: "id-123", isTableEditable: true, isImmutableColumn: true)
        #expect(resolver.resolve(context) == .viewInline(value: "id-123"))
    }

    @Test("JSON-looking text is not content-routed; it shows inline")
    func jsonLikeTextShowsInline() {
        let context = ContextFactory.make(value: #"{"k":1}"#, columnType: nil, isTableEditable: false)
        #expect(resolver.resolve(context) == .viewInline(value: #"{"k":1}"#))
    }

    @Test("read-only override .json shows the JSON viewer")
    func readOnlyOverrideJsonShowsViewer() {
        let context = ContextFactory.make(
            value: "plain",
            columnType: .text(rawType: "TEXT"),
            isTableEditable: false,
            displayFormatOverride: .json
        )
        #expect(resolver.resolve(context) == .viewJson)
    }

    @Test("read-only override .phpSerialized shows the PHP viewer")
    func readOnlyOverridePhpShowsViewer() {
        let context = ContextFactory.make(
            value: "plain",
            columnType: .text(rawType: "TEXT"),
            isTableEditable: false,
            displayFormatOverride: .phpSerialized
        )
        #expect(resolver.resolve(context) == .viewPhpSerialized)
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

    @Test("editable JSON column edits inline; the chevron opens the JSON editor")
    func editableJsonColumnEditsInline() {
        let context = ContextFactory.make(value: #"{"k":1}"#, columnType: .json(rawType: "JSON"), isTableEditable: true)
        #expect(resolver.resolve(context) == .editInline(value: #"{"k":1}"#))
    }

    @Test("editable multiline JSON column opens the inline overlay editor")
    func editableMultilineJsonColumnEditsOverlay() {
        let value = "{\n\"k\": 1\n}"
        let context = ContextFactory.make(value: value, columnType: .json(rawType: "JSON"), isTableEditable: true)
        #expect(resolver.resolve(context) == .editOverlay(value: value))
    }

    @Test("editable BLOB column returns editBlob")
    func editableBlobColumnReturnsEditBlob() {
        let context = ContextFactory.make(value: "x", columnType: .blob(rawType: "BLOB"), isTableEditable: true)
        #expect(resolver.resolve(context) == .editBlob)
    }

    @Test("JSON-looking text is not content-routed; it edits inline")
    func jsonLikeTextEditsInline() {
        let context = ContextFactory.make(value: #"{"k":1}"#, isTableEditable: true)
        #expect(resolver.resolve(context) == .editInline(value: #"{"k":1}"#))
    }

    @Test("editable override .json opens the JSON editor")
    func editableOverrideJsonOpensEditor() {
        let context = ContextFactory.make(value: "plain", isTableEditable: true, displayFormatOverride: .json)
        #expect(resolver.resolve(context) == .editJson)
    }

    @Test("editable override .phpSerialized shows the PHP viewer")
    func editableOverridePhpShowsViewer() {
        let context = ContextFactory.make(value: "plain", isTableEditable: true, displayFormatOverride: .phpSerialized)
        #expect(resolver.resolve(context) == .viewPhpSerialized)
    }

    @Test("editable override .uuid still edits inline")
    func editableOverrideUuidEditsInline() {
        let context = ContextFactory.make(
            value: "0x00",
            columnType: .text(rawType: "TEXT"),
            isTableEditable: true,
            displayFormatOverride: .uuid
        )
        #expect(resolver.resolve(context) == .editInline(value: "0x00"))
    }

    @Test("editable foreign key column returns editInline")
    func editableForeignKeyReturnsEditInline() {
        let context = ContextFactory.make(value: "1", columnType: .integer(rawType: "INT"), isTableEditable: true)
        #expect(resolver.resolve(context) == .editInline(value: "1"))
    }

    @Test("editable boolean column returns editInline, not a picker")
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
