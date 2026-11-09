//
//  ConnectionNavigatorViewControllerTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing

@MainActor
struct ConnectionNavigatorViewControllerTests {
    private let fixture: ConnectionNavigatorFixture

    init() throws {
        fixture = try ConnectionNavigatorFixture()
    }

    private struct Hosted {
        let controller: ConnectionNavigatorViewController
        let window: NSWindow

        func tearDown() {
            window.orderOut(nil)
            window.contentViewController = nil
        }
    }

    private func host() -> Hosted {
        let controller = ConnectionNavigatorViewController(model: fixture.makeModel())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        window.layoutIfNeeded()
        return Hosted(controller: controller, window: window)
    }

    private static func type(_ text: String, into controller: ConnectionNavigatorViewController) {
        controller.filterField.stringValue = text
        controller.controlTextDidChange(Notification(
            name: NSControl.textDidChangeNotification,
            object: controller.filterField
        ))
    }

    @Test("Typing a filter narrows the list and opens the group holding the match")
    func filterNarrowsAndExpands() throws {
        let group = ConnectionGroup(name: "Production")
        try fixture.groupStorage.addGroup(group)
        fixture.save([
            DatabaseConnection(name: "prod", groupId: group.id),
            DatabaseConnection(name: "dev"),
        ])
        let hosted = host()
        defer { hosted.tearDown() }
        let outline = hosted.controller.outlineView

        Self.type("prod", into: hosted.controller)

        #expect(hosted.controller.model.filterText == "prod")
        #expect(outline.numberOfRows == 2)
        #expect(outline.isItemExpanded(outline.item(atRow: 0)))
    }

    @Test("Escape in the list clears the filter")
    func escapeInListClearsFilter() {
        fixture.save([DatabaseConnection(name: "prod")])
        let hosted = host()
        defer { hosted.tearDown() }
        Self.type("prod", into: hosted.controller)
        #expect(hosted.controller.model.filterText == "prod")

        hosted.controller.outlineView.cancelOperation(nil)

        #expect(hosted.controller.model.filterText.isEmpty)
        #expect(hosted.controller.filterField.stringValue.isEmpty)
    }

    @Test("Find puts the keyboard in the filter field")
    func findFocusesFilter() {
        fixture.save([DatabaseConnection(name: "prod")])
        let hosted = host()
        defer { hosted.tearDown() }
        hosted.window.makeFirstResponder(hosted.controller.outlineView)
        #expect(hosted.controller.filterField.currentEditor() == nil)

        hosted.controller.performFind(nil)

        #expect(hosted.controller.filterField.currentEditor() != nil)
    }

    @Test("An empty library shows the empty state in place of the list")
    func emptyLibraryShowsEmptyState() {
        let hosted = host()
        defer { hosted.tearDown() }

        #expect(hosted.controller.isShowingEmptyState)
        #expect(hosted.controller.outlineView.enclosingScrollView?.isHidden == true)
    }

    @Test("The connection this window shows is the selected row")
    func shownConnectionIsSelected() {
        let first = DatabaseConnection(name: "first")
        let second = DatabaseConnection(name: "second")
        fixture.save([first, second])
        fixture.host.hosted = [first.id, second.id]
        fixture.host.selected = first.id
        let hosted = host()
        defer { hosted.tearDown() }

        fixture.host.selected = second.id
        hosted.controller.refreshSelection()

        let row = hosted.controller.row(for: .connection(second.id))
        #expect(row >= 0)
        #expect(hosted.controller.outlineView.selectedRow == row)
    }

    @Test("Return on a group opens it and remembers that")
    func returnOnGroupToggles() throws {
        let group = ConnectionGroup(name: "Group")
        try fixture.groupStorage.addGroup(group)
        fixture.save([DatabaseConnection(name: "inside", groupId: group.id)])
        let hosted = host()
        defer { hosted.tearDown() }
        let outline = hosted.controller.outlineView
        let row = hosted.controller.row(for: .group(group.id))
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)

        hosted.controller.activateSelection()

        #expect(outline.isItemExpanded(outline.item(atRow: row)))
        #expect(fixture.expansionStore.load(keeping: [group.id]) == [group.id])
    }

    /// A deleted connection's row must not stay selected after the list drops it.
    @Test("A selected connection deleted elsewhere hands the selection back to the shown one")
    func deletedSelectionFallsBackToShown() {
        let shown = DatabaseConnection(name: "shown")
        let doomed = DatabaseConnection(name: "doomed")
        fixture.save([shown, doomed])
        fixture.host.hosted = [shown.id]
        fixture.host.selected = shown.id
        let hosted = host()
        defer { hosted.tearDown() }
        let outline = hosted.controller.outlineView
        let doomedRow = hosted.controller.row(for: .connection(doomed.id))
        #expect(doomedRow >= 0)
        outline.selectRowIndexes(IndexSet(integer: max(doomedRow, 0)), byExtendingSelection: false)

        fixture.save([shown])
        hosted.controller.model.rebuild()

        #expect(hosted.controller.row(for: .connection(doomed.id)) == -1)
        let shownRow = hosted.controller.row(for: .connection(shown.id))
        #expect(shownRow >= 0)
        #expect(outline.selectedRow == shownRow)
    }

    /// A connection opened from a file or a link is hosted without ever being saved.
    @Test("A shown connection the library does not hold selects nothing")
    func unsavedShownConnectionSelectsNothing() {
        fixture.save([DatabaseConnection(name: "saved")])
        let unsaved = UUID()
        fixture.host.hosted = [unsaved]
        fixture.host.selected = unsaved
        let hosted = host()
        defer { hosted.tearDown() }

        hosted.controller.refreshSelection()

        #expect(hosted.controller.outlineView.numberOfRows == 1)
        #expect(hosted.controller.outlineView.selectedRow == -1)
    }
}
