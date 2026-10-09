//
//  GeometryFieldChromeTests.swift
//  TableProTests
//
//  What a geometry field's toolbar and panes are held to and no value-level test can see: one Open
//  in Window button for both segments, names on the icon-only buttons, a preference only the
//  picker writes, and no map view kept alive behind the inspector's JSON rendering.
//

import Foundation
import Testing

struct GeometryFieldChromeTests {
    private static let path = "TablePro/Views/RowInspector/FieldEditors/GeometryFieldView.swift"

    private func source() throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("project.yml").path) {
                return try String(contentsOf: directory.appendingPathComponent(Self.path), encoding: .utf8)
            }
            directory = directory.deletingLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    /// The text and JSON editors draw their own button whenever they are handed a pop-out action,
    /// which would put two buttons with one label and two targets on the Text segment.
    @Test("The editors under Text carry no Open in Window button of their own")
    func embeddedEditorsHaveNoPopOutButton() throws {
        let source = try source()
        #expect(source.contains("MultiLineEditorView(context: context, onPopOut: nil,"))
        #expect(source.contains("JsonEditorView(context: context, onPopOut: nil,"))
        #expect(source.components(separatedBy: #"Button(String(localized: "Open in Window")"#).count == 2)
    }

    /// A tooltip is a hint, not a name: VoiceOver reads the label first.
    @Test("Both icon-only buttons carry an accessibility label")
    func iconOnlyButtonsAreNamed() throws {
        let source = try source()
        #expect(source.contains(#".accessibilityLabel(String(localized: "Fit to Geometry"))"#))
        #expect(source.contains(#".accessibilityLabel(String(localized: "Open in Window"))"#))
    }

    /// A write anywhere else would let a value that became drawable while it was typed change what
    /// every other geometry field opens on.
    @Test("Only the picker writes the mode preference")
    func onlyThePickerWritesThePreference() throws {
        let source = try source()
        #expect(source.components(separatedBy: "storedMode = ").count == 3)
        #expect(source.contains("private var storedMode = Mode.map.rawValue"))
        #expect(source.contains("latch.choose(chosen)\n                storedMode = chosen.rawValue"))
    }

    /// The field list stays mounted, disabled, behind the JSON rendering. A map view left there
    /// holds its memory for as long as the tab lives.
    @Test("The map canvas is built only while the list is enabled")
    func canvasFollowsTheEnabledState() throws {
        let source = try source()
        #expect(source.contains("@Environment(\\.isEnabled) private var isEnabled"))
        #expect(source.contains("if isEnabled {\n                GeometryFieldMapCanvas("))
        #expect(source.components(separatedBy: "GeometryFieldMapCanvas(").count == 2)
    }
}
