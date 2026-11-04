//
//  FilterRowViewTests.swift
//  TableProTests
//
//  A row's first popup picks a column or the raw condition, and both modes show one text. The raw
//  field and the value field are different AppKit fields, so the text has to survive the switch in
//  the model the new field is seeded from.
//

import AppKit
import SwiftUI
@testable import TablePro
import Testing

@MainActor
private final class FilterRowHost {
    var filter: TableFilter
    let window: NSWindow
    private let hosting: NSHostingView<AnyView>

    init(_ filter: TableFilter) {
        self.filter = filter
        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        render()
    }

    /// The panel re-renders its rows whenever the state changes; a test does it by hand.
    func render() {
        let binding = Binding(get: { self.filter }, set: { self.filter = $0 })
        hosting.rootView = AnyView(
            FilterRowView(
                filter: binding,
                columns: ["id", "name", "email"],
                completions: [],
                onAdd: {},
                onDuplicate: {},
                onRemove: {},
                onApply: {},
                onSubmit: {},
                onCancel: {},
                isReorderEnabled: false,
                canMoveUp: false,
                canMoveDown: false,
                onMoveUp: {},
                onMoveDown: {},
                onDropFilter: { _ in },
                focusedFilterId: .constant(nil)
            )
            .frame(width: 520)
        )
        hosting.layoutSubtreeIfNeeded()
    }

    var valueField: NSTextField? {
        Self.editableFields(in: hosting).first
    }

    func type(_ text: String) throws {
        let field = try #require(valueField)
        field.stringValue = text
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    private static func editableFields(in view: NSView) -> [NSTextField] {
        let own = (view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []
        return own + view.subviews.flatMap(editableFields(in:))
    }
}

@MainActor
struct FilterRowViewTests {
    @Test("Text typed as Raw SQL is in the value field after picking a column")
    func rawTextFollowsTheSwitchToAColumn() throws {
        let host = FilterRowHost(TableFilter.rawCondition(""))
        defer { host.window.orderOut(nil) }

        try host.type("id = 1")
        #expect(host.filter.value == "id = 1")

        host.filter = host.filter.selectingColumn("name")
        host.render()

        #expect(host.valueField?.stringValue == "id = 1")
    }

    @Test("A value typed under a column is in the Raw SQL field after picking Raw SQL")
    func valueFollowsTheSwitchToRawSQL() throws {
        let host = FilterRowHost(TableFilter(columnName: "email", filterOperator: .contains))
        defer { host.window.orderOut(nil) }

        try host.type("gmail")
        host.filter = host.filter.selectingRawCondition()
        host.render()

        #expect(host.filter.isRawSQL)
        #expect(host.valueField?.stringValue == "gmail")
    }
}
