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
}
