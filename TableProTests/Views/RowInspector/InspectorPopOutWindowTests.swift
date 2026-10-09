//
//  InspectorPopOutWindowTests.swift
//  TableProTests
//
//  Open in Window on a geometry field's Text segment opens the window that segment's editor
//  would: GeoJSON in the JSON window, WKT in the text window. The map has a window of its own.
//

import Foundation
@testable import TablePro
import Testing

struct InspectorPopOutWindowTests {
    private func geometry(_ editor: GeometryTextEditor, _ source: GeometryFieldSource) -> FieldEditorKind {
        .geometry(GeometryFieldDescriptor(textEditor: editor, source: source))
    }

    @Test("GeoJSON opens in the JSON window, from either kind of column")
    func geoJSONOpensAsJSON() {
        #expect(InspectorPopOutWindow.resolve(for: geometry(.json, .jsonColumn)) == .json)
        #expect(InspectorPopOutWindow.resolve(for: geometry(.json, .spatialColumn)) == .json)
    }

    @Test("WKT opens in the text window")
    func wktOpensAsText() {
        #expect(InspectorPopOutWindow.resolve(for: geometry(.multiLine, .spatialColumn)) == .text)
    }

    @Test("The kinds that had a window keep it")
    func otherKindsAreUnchanged() {
        #expect(InspectorPopOutWindow.resolve(for: .json) == .json)
        #expect(InspectorPopOutWindow.resolve(for: .phpSerialized) == .php)
        #expect(InspectorPopOutWindow.resolve(for: .multiLine) == .text)
        #expect(InspectorPopOutWindow.resolve(for: .singleLine) == .text)
        #expect(InspectorPopOutWindow.resolve(for: .schemaText) == .text)
    }
}
