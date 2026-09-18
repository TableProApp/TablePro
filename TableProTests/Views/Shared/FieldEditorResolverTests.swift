//
//  FieldEditorResolverTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing

@MainActor
@Suite("FieldEditorResolver")
struct FieldEditorResolverTests {
    @Test("JSON column resolves to .json")
    func jsonColumnReturnsJson() {
        let kind = FieldEditorResolver.resolve(
            for: .json(rawType: "JSON"),
            isLongText: false,
            originalValue: "{}"
        )
        #expect(kind == .json)
    }

    @Test("text column with JSON-shaped value resolves to .json")
    func jsonShapedTextReturnsJson() {
        let kind = FieldEditorResolver.resolve(
            for: .text(rawType: "TEXT"),
            isLongText: false,
            originalValue: #"{"k":1}"#
        )
        #expect(kind == .json)
    }

    @Test("text column with PHP-shaped value resolves to .phpSerialized")
    func phpShapedTextReturnsPhpSerialized() {
        let kind = FieldEditorResolver.resolve(
            for: .text(rawType: "TEXT"),
            isLongText: false,
            originalValue: "a:0:{}"
        )
        #expect(kind == .phpSerialized)
    }

    @Test("override .phpSerialized forces .phpSerialized")
    func overridePhpSerializedWins() {
        let kind = FieldEditorResolver.resolve(
            for: .text(rawType: "TEXT"),
            isLongText: false,
            originalValue: "not php",
            displayFormatOverride: .phpSerialized
        )
        #expect(kind == .phpSerialized)
    }

    @Test("a stored value with a newline needs the multi-line editor whatever the column type says")
    func newlineInVarcharReturnsMultiLine() {
        let kind = FieldEditorResolver.resolve(
            for: .text(rawType: "VARCHAR(255)"),
            isLongText: false,
            originalValue: "first line\nsecond line"
        )
        #expect(kind == .multiLine)
    }

    @Test("a long single-line value needs the multi-line editor")
    func longVarcharValueReturnsMultiLine() {
        let kind = FieldEditorResolver.resolve(
            for: .text(rawType: "VARCHAR(10000)"),
            isLongText: false,
            originalValue: String(repeating: "a", count: 5_000)
        )
        #expect(kind == .multiLine)
    }

    @Test("NCLOB and VARCHAR(MAX) route on the value, which the exact-match type list never covered")
    func longValueRoutesForTypesIsLongTextMisses() {
        let long = String(repeating: "a", count: 20_000)
        #expect(ColumnType.text(rawType: "NCLOB").isLongText == false)
        #expect(ColumnType.text(rawType: "nvarchar(max)").isLongText == false)
        #expect(ColumnType.text(rawType: "Nullable(String)").isLongText == false)
        for raw in ["NCLOB", "nvarchar(max)", "Nullable(String)"] {
            let type = ColumnType.text(rawType: raw)
            #expect(FieldEditorResolver.resolve(for: type, isLongText: type.isLongText, originalValue: long) == .multiLine)
        }
    }

    @Test("a short scalar keeps the single-line field AppKit intends for it")
    func shortVarcharStaysSingleLine() {
        let kind = FieldEditorResolver.resolve(
            for: .text(rawType: "VARCHAR(255)"),
            isLongText: false,
            originalValue: "hello"
        )
        #expect(kind == .singleLine)
    }

    @Test("an empty long-text column still opens the multi-line editor")
    func emptyLongTextColumnStaysMultiLine() {
        let kind = FieldEditorResolver.resolve(
            for: .text(rawType: "TEXT"),
            isLongText: true,
            originalValue: ""
        )
        #expect(kind == .multiLine)
    }

    @Test("a NULL value in a short column stays single-line")
    func nullShortValueStaysSingleLine() {
        let kind = FieldEditorResolver.resolve(
            for: .text(rawType: "VARCHAR(255)"),
            isLongText: false,
            originalValue: nil
        )
        #expect(kind == .singleLine)
    }

    @Test("a value right at the threshold stays single-line and one past it does not")
    func thresholdBoundary() {
        let type = ColumnType.text(rawType: "VARCHAR(255)")
        let atLimit = String(repeating: "a", count: FieldEditorResolver.multiLineValueThreshold)
        let overLimit = String(repeating: "a", count: FieldEditorResolver.multiLineValueThreshold + 1)
        #expect(FieldEditorResolver.resolve(for: type, isLongText: false, originalValue: atLimit) == .singleLine)
        #expect(FieldEditorResolver.resolve(for: type, isLongText: false, originalValue: overLimit) == .multiLine)
    }

    @Test("a long JSON value still opens the JSON editor rather than the plain text one")
    func longJsonValueStillResolvesJson() {
        let json = "{\"k\":\"" + String(repeating: "a", count: 5_000) + "\"}"
        let kind = FieldEditorResolver.resolve(
            for: .text(rawType: "TEXT"),
            isLongText: true,
            originalValue: json
        )
        #expect(kind == .json)
    }

    @Test("a long value in a boolean column still opens the picker")
    func longValueInBooleanColumnStillResolvesPicker() {
        let kind = FieldEditorResolver.resolve(
            for: .boolean(rawType: "TINYINT(1)"),
            isLongText: false,
            originalValue: String(repeating: "1", count: 5_000)
        )
        #expect(kind == .boolean)
    }

    @Test("override .json forces .json on non-JSON text")
    func overrideJsonWins() {
        let kind = FieldEditorResolver.resolve(
            for: .text(rawType: "TEXT"),
            isLongText: false,
            originalValue: "plain text",
            displayFormatOverride: .json
        )
        #expect(kind == .json)
    }

    @Test("override .raw skips structured detection for PHP")
    func overrideRawSkipsPhp() {
        let kind = FieldEditorResolver.resolve(
            for: .text(rawType: "TEXT"),
            isLongText: false,
            originalValue: "a:0:{}",
            displayFormatOverride: .raw
        )
        #expect(kind != .phpSerialized)
    }

    @Test("boolean column resolves to .boolean")
    func booleanColumn() {
        let kind = FieldEditorResolver.resolve(
            for: .boolean(rawType: "BOOL"),
            isLongText: false,
            originalValue: "1"
        )
        #expect(kind == .boolean)
    }

    @Test("long text resolves to .multiLine")
    func longTextMultiLine() {
        let kind = FieldEditorResolver.resolve(
            for: .text(rawType: "TEXT"),
            isLongText: true,
            originalValue: "long content"
        )
        #expect(kind == .multiLine)
    }

    @Test("short plain text resolves to .singleLine")
    func plainSingleLine() {
        let kind = FieldEditorResolver.resolve(
            for: .text(rawType: "VARCHAR"),
            isLongText: false,
            originalValue: "short"
        )
        #expect(kind == .singleLine)
    }
}

@MainActor
@Suite("FieldEditorResolver image content")
struct FieldEditorResolverImageTests {
    private func encodedPng() -> Data {
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 4,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return Data() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        NSColor.systemGreen.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        NSGraphicsContext.restoreGraphicsState()
        return representation.representation(using: .png, properties: [:]) ?? Data()
    }

    @Test("SVG markup in a text column resolves to the image editor")
    func svgTextResolvesToImage() {
        let kind = FieldEditorResolver.resolve(
            for: .text(rawType: "TEXT"),
            isLongText: true,
            originalValue: "<svg><rect/></svg>"
        )
        #expect(kind == .image(.svg))
    }

    /// The image branch runs before the blob branch, or a PNG in a BLOB column would only ever be
    /// a hex dump in the inspector while the grid popover drew it.
    @Test("PNG bytes in a blob column resolve to the image editor")
    func pngBlobResolvesToImage() throws {
        let value = try #require(String(data: encodedPng(), encoding: .isoLatin1))
        let kind = FieldEditorResolver.resolve(
            for: .blob(rawType: "BLOB"),
            isLongText: false,
            originalValue: value
        )
        #expect(kind == .image(.raster("public.png")))
    }

    @Test("binary that is not an image still resolves to the hex editor")
    func nonImageBlobStaysHex() {
        let kind = FieldEditorResolver.resolve(
            for: .blob(rawType: "BLOB"),
            isLongText: false,
            originalValue: "\u{0}\u{1}\u{2}\u{3}"
        )
        #expect(kind == .blobHex)
    }

    @Test("Raw Value suppresses image detection the way it suppresses JSON")
    func rawOverrideSuppressesImage() {
        let kind = FieldEditorResolver.resolve(
            for: .text(rawType: "TEXT"),
            isLongText: true,
            originalValue: "<svg><rect/></svg>",
            displayFormatOverride: .raw
        )
        #expect(kind == .multiLine)
    }

    @Test("JSON still wins over image detection")
    func jsonWinsOverImage() {
        let kind = FieldEditorResolver.resolve(
            for: .text(rawType: "TEXT"),
            isLongText: false,
            originalValue: #"{"a":1}"#
        )
        #expect(kind == .json)
    }

    private var jsonArrayType: ColumnType {
        .array(rawType: "jsonb[]", element: .json(rawType: "jsonb"))
    }

    private var textArrayType: ColumnType {
        .array(rawType: "text[]", element: .text(rawType: "text"))
    }

    @Test("A jsonb[] value resolves to the element editor, not the JSON editor")
    func jsonArrayResolvesToElements() {
        let kind = FieldEditorResolver.resolve(
            for: jsonArrayType,
            isLongText: false,
            originalValue: #"{"{\"id\": 1}","{\"id\": 2}"}"#
        )
        #expect(kind == .arrayElements(element: .json, values: []))
    }

    @Test("A scalar array resolves to the element editor too")
    func scalarArrayResolvesToElements() {
        let kind = FieldEditorResolver.resolve(
            for: textArrayType,
            isLongText: false,
            originalValue: "{a,b}"
        )
        #expect(kind == .arrayElements(element: .scalar, values: []))
    }

    /// `jsonb[]` and `jsonb[][]` are one type in PostgreSQL's catalog and any array column may
    /// carry a dimension prefix, so the declared type cannot rule either out on a given row. The
    /// text editor over the raw literal is the lossless fallback, as it is in the grid, and which
    /// text editor is the value's own length talking: both literals here sit under
    /// `multiLineValueThreshold`.
    @Test("A literal the element list cannot represent falls back to the text editor")
    func unrepresentableArrayFallsBackToText() {
        #expect(
            FieldEditorResolver.resolve(
                for: jsonArrayType,
                isLongText: false,
                originalValue: #"{{"{\"id\": 1}"},{"{\"id\": 2}"}}"#
            ) == .singleLine
        )
        #expect(
            FieldEditorResolver.resolve(
                for: textArrayType,
                isLongText: false,
                originalValue: "[0:2]={a,b,c}"
            ) == .singleLine
        )
    }

    /// An engine whose list literal is not PostgreSQL's reaches the same gate and fails it, so the
    /// classifier's engine-blind `[]` rule cannot hand another driver's value to this editor.
    @Test("A list literal from another engine does not reach the element editor")
    func foreignListLiteralFallsBackToText() {
        let kind = FieldEditorResolver.resolve(
            for: textArrayType,
            isLongText: false,
            originalValue: "[a, b]"
        )
        #expect(kind == .singleLine)
    }

    /// The parse is also what scopes the editor to the engines whose arrays are written this way:
    /// the classifier's `[]` rule takes no engine, and a document store's `object[]` classifies the
    /// same, so a field with no literal to read must not be offered a list that commits `{…}`.
    @Test("An array column with no value keeps the plain editor")
    func absentArrayValueKeepsPlainEditor() {
        #expect(
            FieldEditorResolver.resolve(for: jsonArrayType, isLongText: false, originalValue: nil)
                == .singleLine
        )
        #expect(
            FieldEditorResolver.resolve(for: textArrayType, isLongText: false, originalValue: "")
                == .singleLine
        )
    }

    /// The labels arrive separately in `TableRows.columnEnumValues` and are injected into the type
    /// before the inspector resolves it, so they have to reach the element inside the array.
    @Test("An enum array carries its declared labels into the element editor")
    func enumArrayCarriesItsLabels() {
        let labels = ["sad", "ok", "happy"]
        let type = ColumnType
            .array(rawType: "ENUM[]", element: .enumType(rawType: "ENUM", values: nil))
            .withAllowedValues(labels)
        #expect(
            FieldEditorResolver.resolve(for: type, isLongText: false, originalValue: "{happy}")
                == .arrayElements(element: .scalar, values: labels)
        )
    }

    /// An empty array literal is itself valid JSON, so resolving the array before the JSON branch
    /// is what keeps `{}` out of the JSON editor.
    @Test("An empty array opens the element editor rather than the JSON editor")
    func emptyArrayResolvesToElements() {
        let kind = FieldEditorResolver.resolve(
            for: jsonArrayType,
            isLongText: false,
            originalValue: "{}"
        )
        #expect(kind == .arrayElements(element: .json, values: []))
    }
}
