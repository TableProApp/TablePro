import AppKit
import SwiftUI
@testable import TablePro
import TableProTestSupport
import Testing

// Selecting another row updates the list in place: each field keeps its control and shows the new value, and an
// editor that seeds state from the value starts over inside it.
@MainActor
struct InspectorRowChangeTests {
    private static let columns = ["id", "name", "note", "meta"]
    private static let types: [ColumnType] = [
        .integer(rawType: "INT"), .text(rawType: "VARCHAR(40)"), .text(rawType: "TEXT"), .json(rawType: "JSON"),
    ]

    private static func descendants<View: NSView>(of root: NSView, as type: View.Type) -> [View] {
        let own = (root as? View).map { [$0] } ?? []
        return own + root.subviews.flatMap { descendants(of: $0, as: type) }
    }

    private static func select(_ row: Int, in state: MultiRowEditState) {
        state.configure(
            rowIDs: [.existing(row)],
            allRows: [["\(row)", "name \(row)", "note \(row)", #"{"row": \#(row)}"#]],
            absentCells: [[]],
            columns: columns,
            columnTypes: types
        )
    }

    private static func host(_ state: MultiRowEditState) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: InspectorFieldListView(
            editState: state,
            isEditable: true,
            databaseType: .mysql
        ))
        window.layoutIfNeeded()
        return window
    }

    private static func singleLineValues(in window: NSWindow) -> [String] {
        guard let root = window.contentView else { return [] }
        return descendants(of: root, as: ValueTextFieldView.self).map(\.stringValue).sorted()
    }

    @Test("A single-line field keeps its control and shows the newly selected row's value")
    func singleLineFieldFollowsTheRowInPlace() async throws {
        let state = MultiRowEditState()
        Self.select(0, in: state)
        let window = Self.host(state)
        defer { window.orderOut(nil) }
        let root = try #require(window.contentView)
        try await waitUntil { Self.singleLineValues(in: window) == ["0", "name 0"] }
        let fields = Self.descendants(of: root, as: ValueTextFieldView.self)

        Self.select(1, in: state)
        try await waitUntil {
            root.layoutSubtreeIfNeeded()
            return Self.singleLineValues(in: window) == ["1", "name 1"]
        }

        let after = Self.descendants(of: root, as: ValueTextFieldView.self)
        #expect(after.count == fields.count)
        #expect(after.allSatisfy { field in fields.contains { $0 === field } })
    }

    @Test("A multi-line field keeps its text view, shows the new row from the start and drops the old row's typing undo")
    func multiLineFieldStartsOverInPlace() async throws {
        let state = MultiRowEditState()
        Self.select(0, in: state)
        let window = Self.host(state)
        defer { window.orderOut(nil) }
        let root = try #require(window.contentView)
        func noteViews() -> [NSTextView] {
            Self.descendants(of: root, as: NSTextView.self).filter { $0.string.hasPrefix("note ") }
        }
        try await waitUntil { noteViews().map(\.string) == ["note 0"] }
        let before = try #require(noteViews().first)
        let undo = try #require(window.undoManager)
        // The test host sends no events, so the group the end of the typing event would close is closed here.
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        window.makeFirstResponder(before)
        before.setSelectedRange(NSRange(location: 6, length: 0))
        undo.beginUndoGrouping()
        before.insertText(" typed", replacementRange: NSRange(location: NSNotFound, length: 0))
        undo.endUndoGrouping()
        #expect(undo.canUndo)

        Self.select(1, in: state)
        try await waitUntil {
            root.layoutSubtreeIfNeeded()
            return noteViews().map(\.string) == ["note 1"]
        }

        #expect(noteViews().first === before)
        #expect(before.selectedRange() == NSRange(location: 0, length: 0))
        #expect(before.undoManager === undo)
        #expect(!undo.canUndo)
    }

    @Test("A JSON field keeps its editor and shows the newly selected row's document")
    func jsonFieldFollowsTheRowInPlace() async throws {
        let state = MultiRowEditState()
        Self.select(0, in: state)
        let window = Self.host(state)
        defer { window.orderOut(nil) }
        let root = try #require(window.contentView)
        func jsonEditors() -> [NSView] {
            Self.descendants(of: root, as: NSView.self).filter { $0.accessibilityIdentifier() == "inspector-json-field" }
        }
        func shows(_ row: Int) -> Bool {
            jsonEditors().contains { ($0.accessibilityValue() as? String)?.contains("\"row\": \(row)") == true }
        }
        try await waitUntil { shows(0) }
        let before = try #require(jsonEditors().first)

        Self.select(1, in: state)
        try await waitUntil {
            root.layoutSubtreeIfNeeded()
            return shows(1)
        }

        #expect(jsonEditors().count == 1)
        #expect(jsonEditors().first === before)
    }
}
