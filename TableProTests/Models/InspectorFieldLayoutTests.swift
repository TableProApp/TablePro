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
    @Test("A scalar editor takes one line")
    func scalarsAreInline() {
        #expect(InspectorFieldLayout.resolve(for: .singleLine) == .inline)
        #expect(InspectorFieldLayout.resolve(for: .boolean) == .inline)
        #expect(InspectorFieldLayout.resolve(for: .schemaText) == .inline)
        #expect(InspectorFieldLayout.resolve(for: .typePicker) == .inline)
        #expect(InspectorFieldLayout.resolve(for: .enumPicker(values: ["a", "b"])) == .inline)
        #expect(InspectorFieldLayout.resolve(for: .setPicker(values: ["a", "b"])) == .inline)
    }

    /// Measured at the pane's 270pt minimum: a `LabeledContent` squeezes a text editor into its
    /// trailing half, so anything that needs room has to own the full width.
    @Test("An editor that needs room spans the width")
    func largeEditorsAreStacked() {
        #expect(InspectorFieldLayout.resolve(for: .multiLine) == .stacked)
        #expect(InspectorFieldLayout.resolve(for: .json) == .stacked)
        #expect(InspectorFieldLayout.resolve(for: .phpSerialized) == .stacked)
        #expect(InspectorFieldLayout.resolve(for: .blobHex) == .stacked)
        #expect(InspectorFieldLayout.resolve(for: .image(.raster("public.png"))) == .stacked)
    }

    /// The editor kind already answers this, because `FieldEditorResolver` chooses `.singleLine`
    /// against `.multiLine` from the value's own length and newlines. Asking the value again in the
    /// layout would be a second opinion that could drift from the first.
    @Test("A long value reaches the stacked layout through the editor it resolves to")
    func aLongValueBecomesStackedThroughItsEditor() {
        let long = String(repeating: "x", count: FieldEditorResolver.multiLineValueThreshold + 1)
        let kind = FieldEditorResolver.resolve(for: .text(rawType: "TEXT"), isLongText: false, originalValue: long)
        #expect(kind == .multiLine)
        #expect(InspectorFieldLayout.resolve(for: kind) == .stacked)
    }

    @Test("A short value stays on one line")
    func aShortValueStaysInline() {
        let kind = FieldEditorResolver.resolve(for: .text(rawType: "TEXT"), isLongText: false, originalValue: "ok")
        #expect(kind == .singleLine)
        #expect(InspectorFieldLayout.resolve(for: kind) == .inline)
    }

    /// A value with a newline in it cannot be shown on one line whatever its length.
    @Test("A value with a newline is stacked")
    func newlinesAreStacked() {
        let kind = FieldEditorResolver.resolve(for: .text(rawType: "TEXT"), isLongText: false, originalValue: "a\nb")
        #expect(InspectorFieldLayout.resolve(for: kind) == .stacked)
    }
}
