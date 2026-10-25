//
//  CellInteractionResolverTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

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

    @Test("read-only plain text opens the text viewer with its value")
    func readOnlyPlainTextReturnsViewInline() {
        let context = ContextFactory.make(value: "hello", isTableEditable: false)
        #expect(resolver.resolve(context) == .viewText(value: "hello"))
    }

    @Test("read-only nil value opens the text viewer on the NULL placeholder")
    func readOnlyNilValueReturnsViewInlineWithNull() {
        let context = ContextFactory.make(value: nil, isTableEditable: false)
        #expect(resolver.resolve(context) == .viewText(value: "NULL"))
    }

    @Test("read-only multiline text opens the text viewer")
    func readOnlyMultilineReturnsViewInline() {
        let context = ContextFactory.make(value: "line1\nline2", isTableEditable: false)
        #expect(resolver.resolve(context) == .viewText(value: "line1\nline2"))
    }

    @Test("read-only BLOB column returns viewBlob")
    func readOnlyBlobColumnReturnsViewBlob() {
        let context = ContextFactory.make(value: nil, columnType: .blob(rawType: "BLOB"), isTableEditable: false)
        #expect(resolver.resolve(context) == .viewBlob)
    }

    @Test("read-only JSON column shows its value inline; the chevron opens the JSON viewer")
    func readOnlyJsonColumnShowsInline() {
        let context = ContextFactory.make(value: #"{"k":1}"#, columnType: .json(rawType: "JSON"), isTableEditable: false)
        #expect(resolver.resolve(context) == .viewText(value: #"{"k":1}"#))
    }

    @Test("immutable column on editable table follows the read-only inline path")
    func immutableColumnFollowsReadOnlyPath() {
        let context = ContextFactory.make(value: "id-123", isTableEditable: true, isImmutableColumn: true)
        #expect(resolver.resolve(context) == .viewText(value: "id-123"))
    }

    @Test("JSON-looking text is not content-routed; it shows inline")
    func jsonLikeTextShowsInline() {
        let context = ContextFactory.make(value: #"{"k":1}"#, columnType: nil, isTableEditable: false)
        #expect(resolver.resolve(context) == .viewText(value: #"{"k":1}"#))
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

struct CellInteractionResolverEditableTests {
    private let resolver = CellInteractionResolver()

    @Test("editable plain single-line returns editInline")
    func editablePlainSingleLineReturnsEditInline() {
        let context = ContextFactory.make(value: "hello", isTableEditable: true)
        #expect(resolver.resolve(context) == .editInline(value: "hello"))
    }

    @Test("a single-line value past the inline limit edits in the text popover, one at the limit in the cell")
    func longValueEditsInPopover() {
        let limit = CellInteractionResolver.inlineLengthLimit
        let atLimit = String(repeating: "a", count: limit)
        let pastLimit = atLimit + "a"

        #expect(resolver.resolve(ContextFactory.make(value: atLimit, isTableEditable: true)) == .editInline(value: atLimit))
        #expect(resolver.resolve(ContextFactory.make(value: pastLimit, isTableEditable: true)) == .editText(value: pastLimit))
    }

    @Test("editable plain multiline edits in the text popover")
    func editablePlainMultilineEditsInPopover() {
        let context = ContextFactory.make(value: "line1\nline2", isTableEditable: true)
        #expect(resolver.resolve(context) == .editText(value: "line1\nline2"))
    }

    @Test("editable JSON column edits inline; the chevron opens the JSON editor")
    func editableJsonColumnEditsInline() {
        let context = ContextFactory.make(value: #"{"k":1}"#, columnType: .json(rawType: "JSON"), isTableEditable: true)
        #expect(resolver.resolve(context) == .editInline(value: #"{"k":1}"#))
    }

    @Test("editable multiline JSON column edits in the text popover")
    func editableMultilineJsonColumnEditsInPopover() {
        let value = "{\n\"k\": 1\n}"
        let context = ContextFactory.make(value: value, columnType: .json(rawType: "JSON"), isTableEditable: true)
        #expect(resolver.resolve(context) == .editText(value: value))
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

    @Test("read-only boolean column opens the text viewer")
    func readOnlyBooleanColumnReturnsViewInline() {
        let context = ContextFactory.make(value: "true", columnType: .boolean(rawType: "BOOL"), isTableEditable: false)
        #expect(resolver.resolve(context) == .viewText(value: "true"))
    }
}

struct CellInteractionResolverBinaryTests {
    private let resolver = CellInteractionResolver()

    @Test("a binary cell in a text column opens the blob editor")
    func binaryCellInTextColumnEdits() {
        let context = ContextFactory.make(
            value: nil, columnType: .text(rawType: "RedisRaw"), isTableEditable: true, isBinaryValue: true
        )
        #expect(resolver.resolve(context) == .editBlob)
    }

    @Test("a binary cell in a read-only table opens the blob viewer")
    func binaryCellReadOnlyViews() {
        let context = ContextFactory.make(
            value: nil, columnType: .text(rawType: "RedisRaw"), isTableEditable: false, isBinaryValue: true
        )
        #expect(resolver.resolve(context) == .viewBlob)
    }

    @Test("a binary cell in an immutable column is not editable")
    func binaryCellImmutableColumnViews() {
        let context = ContextFactory.make(
            value: nil, columnType: .text(rawType: "RedisRaw"), isTableEditable: true,
            isImmutableColumn: true, isBinaryValue: true
        )
        #expect(resolver.resolve(context) == .viewBlob)
    }

    @Test("a text cell in the same column still edits inline")
    func textCellInSameColumnEditsInline() {
        let context = ContextFactory.make(
            value: "hello", columnType: .text(rawType: "RedisRaw"), isTableEditable: true
        )
        #expect(resolver.resolve(context) == .editInline(value: "hello"))
    }

    @Test("a deleted row stays blocked even when binary")
    func deletedBinaryRowBlocked() {
        let context = ContextFactory.make(
            value: nil, isTableEditable: true, isRowDeleted: true, isBinaryValue: true
        )
        #expect(resolver.resolve(context) == .blocked)
    }

    @Test(
        "A binary decoder format opens the decoded viewer, read-only, on an editable table too",
        arguments: [
            (ValueDisplayFormat.messagePack, BinaryValueFormat.messagePack),
            (.protobuf, .protobuf),
        ]
    )
    func decoderFormatOpensDecodedViewer(format: ValueDisplayFormat, expected: BinaryValueFormat) {
        for isTableEditable in [false, true] {
            let context = ContextFactory.make(
                value: nil, columnType: .blob(rawType: "BLOB"), isTableEditable: isTableEditable,
                isBinaryValue: true, displayFormatOverride: format
            )
            #expect(resolver.resolve(context) == .viewBinaryValue(expected))
        }
    }

    @Test("A NULL under a decoder format keeps the hex editor, which is how bytes get into it")
    func nullUnderDecoderFormatKeepsHexEditor() {
        let context = ContextFactory.make(
            value: nil, columnType: .blob(rawType: "BLOB"), isTableEditable: true, displayFormatOverride: .messagePack
        )
        #expect(resolver.resolve(context) == .editBlob)
    }

    @Test("Text and both UUID formats keep the hex editor on a binary cell")
    func characterFormatsKeepHexEditor() {
        for format in [ValueDisplayFormat.text, .uuid, .uuidSwappedTime] {
            let context = ContextFactory.make(
                value: nil, columnType: .blob(rawType: "BINARY(16)"), isTableEditable: true,
                isBinaryValue: true, displayFormatOverride: format
            )
            #expect(resolver.resolve(context) == .editBlob)
        }
    }

    @Test("A decoder format left on a text column edits as text")
    func decoderFormatOnTextColumn() {
        let context = ContextFactory.make(
            value: "hello", columnType: .text(rawType: "TEXT"), isTableEditable: true, displayFormatOverride: .messagePack
        )
        #expect(resolver.resolve(context) == .editInline(value: "hello"))
    }
}

struct CellInteractionResolverForeignKeyTests {
    private let resolver = CellInteractionResolver()

    @Test("a writable foreign key cell opens the value picker")
    func writableForeignKeyOpensThePicker() {
        let context = ContextFactory.make(
            value: "42", columnType: .integer(rawType: "INTEGER"), isTableEditable: true, isForeignKey: true
        )
        #expect(resolver.resolve(context) == .editForeignKey)
    }

    @Test("an empty foreign key cell opens the picker too")
    func emptyForeignKeyOpensThePicker() {
        let context = ContextFactory.make(
            value: nil, columnType: .integer(rawType: "INTEGER"), isTableEditable: true, isForeignKey: true
        )
        #expect(resolver.resolve(context) == .editForeignKey)
    }

    @Test("a read-only foreign key cell keeps its viewer")
    func readOnlyForeignKeyKeepsTheViewer() {
        let context = ContextFactory.make(
            value: "42", columnType: .integer(rawType: "INTEGER"), isForeignKey: true
        )
        #expect(resolver.resolve(context) == .viewText(value: "42"))
    }

    @Test("an immutable foreign key column keeps its viewer")
    func immutableForeignKeyKeepsTheViewer() {
        let context = ContextFactory.make(
            value: "42", columnType: .integer(rawType: "INTEGER"),
            isTableEditable: true, isImmutableColumn: true, isForeignKey: true
        )
        #expect(resolver.resolve(context) == .viewText(value: "42"))
    }

    @Test("a deleted row stays blocked on a foreign key column")
    func deletedForeignKeyRowBlocked() {
        let context = ContextFactory.make(
            value: "42", isTableEditable: true, isRowDeleted: true, isForeignKey: true
        )
        #expect(resolver.resolve(context) == .blocked)
    }

    // The picker lists keys; the reference is still followed from the arrow and the context menu.
    @Test("a foreign key column holding a blob keeps the blob editor")
    func blobForeignKeyKeepsTheBlobEditor() {
        let context = ContextFactory.make(
            value: nil, columnType: .blob(rawType: "BLOB"), isTableEditable: true, isForeignKey: true
        )
        #expect(resolver.resolve(context) == .editBlob)
    }

    @Test("a foreign key column shown as JSON keeps the JSON editor")
    func jsonDisplayForeignKeyKeepsTheJsonEditor() {
        let context = ContextFactory.make(
            value: "{}", columnType: .text(rawType: "TEXT"), isTableEditable: true,
            isForeignKey: true, displayFormatOverride: .json
        )
        #expect(resolver.resolve(context) == .editJson)
    }

    @Test("a column with no foreign key still edits inline")
    func plainColumnStillEditsInline() {
        let context = ContextFactory.make(
            value: "42", columnType: .integer(rawType: "INTEGER"), isTableEditable: true
        )
        #expect(resolver.resolve(context) == .editInline(value: "42"))
    }
}

private enum ContextFactory {
    static func make(
        value: String?,
        columnType: ColumnType? = nil,
        isTableEditable: Bool = false,
        isRowDeleted: Bool = false,
        isImmutableColumn: Bool = false,
        isBinaryValue: Bool = false,
        isForeignKey: Bool = false,
        displayFormatOverride: ValueDisplayFormat? = nil,
        detectedContent: CellValueContent = .plain
    ) -> CellContext {
        CellContext(
            columnType: columnType,
            value: value,
            isTableEditable: isTableEditable,
            isRowDeleted: isRowDeleted,
            isImmutableColumn: isImmutableColumn,
            isBinaryValue: isBinaryValue,
            isForeignKey: isForeignKey,
            displayFormatOverride: displayFormatOverride,
            detectedContent: detectedContent
        )
    }
}

struct CellInteractionResolverImageTests {
    private let resolver = CellInteractionResolver()
    private let markup = "<svg><rect/></svg>"

    @Test("SVG in a read-only text column opens the SVG viewer")
    func readOnlySvgViews() {
        let context = ContextFactory.make(
            value: markup,
            columnType: .text(rawType: "TEXT"),
            isTableEditable: false,
            detectedContent: .image(.svg)
        )
        #expect(resolver.resolve(context) == .viewSvg)
    }

    @Test("SVG in an editable text column opens the SVG viewer with its source editable")
    func editableSvgEdits() {
        let context = ContextFactory.make(
            value: markup,
            columnType: .text(rawType: "TEXT"),
            isTableEditable: true,
            detectedContent: .image(.svg)
        )
        #expect(resolver.resolve(context) == .editSvg)
    }

    @Test("SVG in an immutable column keeps the read-only viewer")
    func immutableSvgViews() {
        let context = ContextFactory.make(
            value: markup,
            columnType: .text(rawType: "TEXT"),
            isTableEditable: true,
            isImmutableColumn: true,
            detectedContent: .image(.svg)
        )
        #expect(resolver.resolve(context) == .viewSvg)
    }

    // Raw Value is how a column opts out of every kind of detection, image included.
    @Test("Display As Raw Value suppresses the SVG viewer")
    func rawOverrideSuppressesSvg() {
        let context = ContextFactory.make(
            value: markup,
            columnType: .text(rawType: "TEXT"),
            isTableEditable: false,
            displayFormatOverride: .raw,
            detectedContent: .image(.svg)
        )
        #expect(resolver.resolve(context) == .viewText(value: markup))
    }

    // A binary column keeps the hex popover, which grows an Image segment of its own.
    @Test("a raster image in a blob column still opens the blob viewer")
    func rasterInBlobColumnKeepsTheBlobViewer() {
        let context = ContextFactory.make(
            value: nil,
            columnType: .blob(rawType: "BLOB"),
            isTableEditable: false,
            isBinaryValue: true,
            detectedContent: .image(.raster("public.png"))
        )
        #expect(resolver.resolve(context) == .viewBlob)
    }

    @Test("SVG stored as bytes keeps the blob path rather than the text one")
    func svgAsBytesKeepsTheBlobPath() {
        let context = ContextFactory.make(
            value: nil,
            columnType: .blob(rawType: "BLOB"),
            isTableEditable: true,
            isBinaryValue: true,
            detectedContent: .image(.svg)
        )
        #expect(resolver.resolve(context) == .editBlob)
    }

    @Test("a row marked for deletion opens nothing, image or not")
    func deletedRowStaysBlocked() {
        let context = ContextFactory.make(
            value: markup,
            columnType: .text(rawType: "TEXT"),
            isTableEditable: true,
            isRowDeleted: true,
            detectedContent: .image(.svg)
        )
        #expect(resolver.resolve(context) == .blocked)
    }
}

struct CellInteractionResolverVectorTests {
    private let resolver = CellInteractionResolver()
    private let vector = ColumnType.vector(rawType: "vector(3)")

    @Test("A vector opens the vector viewer, editable where the cell is")
    func vectorOpensViewer() {
        #expect(resolver.resolve(ContextFactory.make(value: "[1,2,3]", columnType: vector, isTableEditable: true)) == .editVector)
        #expect(resolver.resolve(ContextFactory.make(value: "[1,2,3]", columnType: vector)) == .viewVector)
        #expect(
            resolver.resolve(ContextFactory.make(value: "{1:2}/3", columnType: .vector(rawType: "sparsevec(3)"))) == .viewVector
        )
    }

    @Test("NULL and text the viewer cannot list keep the text editor")
    func unreadableValueKeepsTextEditor() {
        #expect(resolver.resolve(ContextFactory.make(value: nil, columnType: vector, isTableEditable: true)) == .editInline(value: ""))
        #expect(
            resolver.resolve(ContextFactory.make(value: "oops", columnType: vector, isTableEditable: true)) == .editInline(value: "oops")
        )
    }

    @Test("A display format left from the column's text days does not take the viewer away")
    func staleFormatIgnored() {
        let context = ContextFactory.make(
            value: "[1,2,3]", columnType: vector, isTableEditable: true, displayFormatOverride: .json
        )
        #expect(resolver.resolve(context) == .editVector)
    }

    @Test("A bracketed value in a column that is no vector keeps the text editor")
    func textColumnUnchanged() {
        let context = ContextFactory.make(value: "[1,2,3]", columnType: .text(rawType: "text"), isTableEditable: true)
        #expect(resolver.resolve(context) == .editInline(value: "[1,2,3]"))
    }
}
