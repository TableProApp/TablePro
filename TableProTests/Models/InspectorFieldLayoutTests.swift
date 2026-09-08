//
//  InspectorFieldLayoutTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
@Suite("Inspector field layout")
struct InspectorFieldLayoutTests {
    private static let everyKind: [FieldEditorKind] = [
        .singleLine,
        .boolean,
        .schemaText,
        .typePicker,
        .enumPicker(values: ["a", "b"]),
        .setPicker(values: ["a", "b"]),
        .multiLine,
        .json,
        .phpSerialized,
        .blobHex,
        .image(.raster("public.png"))
    ]

    /// A column name is user data of no bounded length, so no label lane can hold every one of them
    /// and a lane wide enough to try takes the width the value needs. Measured at the pane's 270pt
    /// minimum, a side-by-side data row truncates the name *and* the value; stacking shows both.
    @Test("Every data field stacks, whatever editor it resolves to")
    func dataFieldsAlwaysStack() {
        for kind in Self.everyKind {
            #expect(
                InspectorFieldLayout.resolve(for: kind, isSchemaField: false) == .stacked,
                "\(kind) should stack on a data row"
            )
        }
    }

    /// A schema label comes from a closed authored vocabulary whose widest member renders at 66.4pt,
    /// so the lane holds it and the row stays one line high.
    @Test("A schema scalar takes one line")
    func schemaScalarsAreInline() {
        #expect(InspectorFieldLayout.resolve(for: .singleLine, isSchemaField: true) == .inline)
        #expect(InspectorFieldLayout.resolve(for: .boolean, isSchemaField: true) == .inline)
        #expect(InspectorFieldLayout.resolve(for: .schemaText, isSchemaField: true) == .inline)
        #expect(InspectorFieldLayout.resolve(for: .typePicker, isSchemaField: true) == .inline)
        #expect(InspectorFieldLayout.resolve(for: .enumPicker(values: ["a"]), isSchemaField: true) == .inline)
        #expect(InspectorFieldLayout.resolve(for: .setPicker(values: ["a"]), isSchemaField: true) == .inline)
    }

    /// The editors that need the pane's width still take it, on a schema row as on a data row.
    @Test("A schema editor that needs room spans the width")
    func schemaLargeEditorsAreStacked() {
        #expect(InspectorFieldLayout.resolve(for: .multiLine, isSchemaField: true) == .stacked)
        #expect(InspectorFieldLayout.resolve(for: .json, isSchemaField: true) == .stacked)
        #expect(InspectorFieldLayout.resolve(for: .phpSerialized, isSchemaField: true) == .stacked)
        #expect(InspectorFieldLayout.resolve(for: .blobHex, isSchemaField: true) == .stacked)
        #expect(InspectorFieldLayout.resolve(for: .image(.raster("public.png")), isSchemaField: true) == .stacked)
    }

    /// `.enumPicker` is the kind for a data row's ENUM column *and* for a structure row's dropdown
    /// (On Delete, Unique, Nullable), so the editor kind alone cannot say which shape a row takes.
    /// Resolving on the kind by itself is what put a structure dropdown and an ENUM value in the
    /// same geometry.
    @Test("One editor kind resolves differently by provenance")
    func provenanceDecidesWhereTheKindIsShared() {
        let dropdown = FieldEditorKind.enumPicker(values: ["CASCADE", "RESTRICT"])
        #expect(InspectorFieldLayout.resolve(for: dropdown, isSchemaField: true) == .inline)
        #expect(InspectorFieldLayout.resolve(for: dropdown, isSchemaField: false) == .stacked)
    }

    /// A long value still reaches its own editor through `FieldEditorResolver`; the layout no longer
    /// asks the value a second time, so the two can never drift apart.
    @Test("A long value resolves to the multi-line editor")
    func aLongValueBecomesMultiLineThroughItsEditor() {
        let long = String(repeating: "x", count: FieldEditorResolver.multiLineValueThreshold + 1)
        let kind = FieldEditorResolver.resolve(for: .text(rawType: "TEXT"), isLongText: false, originalValue: long)
        #expect(kind == .multiLine)
        #expect(InspectorFieldLayout.resolve(for: kind, isSchemaField: false) == .stacked)
    }

    /// A short data value gets the same shape as a long one. Choosing per row from the value's own
    /// length would reflow a field from one shape to the other while the user typed into it.
    @Test("A short data value keeps the same shape as a long one")
    func aShortValueKeepsTheStackedShape() {
        let kind = FieldEditorResolver.resolve(for: .text(rawType: "TEXT"), isLongText: false, originalValue: "ok")
        #expect(kind == .singleLine)
        #expect(InspectorFieldLayout.resolve(for: kind, isSchemaField: false) == .stacked)
    }
}
