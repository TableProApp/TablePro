//
//  FieldEditorResolverTests.swift
//  TableProTests
//

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
