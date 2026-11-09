//
//  ConnectionNavigatorViewControllerTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import TableProTestSupport
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
            for sheet in controller.presentedViewControllers ?? [] {
                controller.dismiss(sheet)
            }
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

    // MARK: - New Group sheet

    /// Escape and Return are the Cancel and Create buttons' own shortcuts, so a key equivalent runs
    /// the button's action. SwiftUI builds no accessibility tree in the test host to press through.
    private static func keyEquivalent(_ characters: String, keyCode: UInt16, in sheet: NSViewController) throws -> NSEvent {
        let window = try #require(sheet.view.window)
        return try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    /// Typed through the field editor, the way a key press edits it, so SwiftUI's binding hears it.
    private static func type(_ text: String, intoFieldOf sheet: NSViewController) throws {
        let field = try #require(editableTextField(in: sheet.view))
        let window = try #require(sheet.view.window)
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    private static func editableTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = editableTextField(in: subview) { return field }
        }
        return nil
    }

    private func presentedSheet(of controller: ConnectionNavigatorViewController) throws -> NSViewController {
        let sheet = try #require(controller.presentedViewControllers?.first)
        sheet.view.layoutSubtreeIfNeeded()
        return sheet
    }

    /// The sheet is SwiftUI hosted in an AppKit sheet, where SwiftUI's own dismiss reaches nothing.
    @Test("Cancel closes the New Group sheet")
    func cancelClosesNewGroupSheet() async throws {
        fixture.save([DatabaseConnection(name: "prod")])
        let hosted = host()
        defer { hosted.tearDown() }
        hosted.controller.presentNewGroupSheet(parentId: nil)
        let sheet = try presentedSheet(of: hosted.controller)
        let escape = try Self.keyEquivalent("\u{1b}", keyCode: 53, in: sheet)

        #expect(sheet.view.performKeyEquivalent(with: escape))
        try await waitUntil(timeout: .seconds(2)) { hosted.controller.presentedViewControllers?.isEmpty ?? true }
        #expect(fixture.groupStorage.loadGroups().isEmpty)
    }

    @Test("Create saves the group and closes the New Group sheet")
    func createSavesAndClosesNewGroupSheet() async throws {
        fixture.save([DatabaseConnection(name: "prod")])
        let hosted = host()
        defer { hosted.tearDown() }
        hosted.controller.presentNewGroupSheet(parentId: nil)
        let sheet = try presentedSheet(of: hosted.controller)
        try Self.type("Reports", intoFieldOf: sheet)
        let returnKey = try Self.keyEquivalent("\r", keyCode: 36, in: sheet)

        /// Create turns on once SwiftUI has read the typed name, which it does on its own schedule.
        try await waitUntil(timeout: .seconds(2)) { sheet.view.performKeyEquivalent(with: returnKey) }
        try await waitUntil(timeout: .seconds(2)) { !fixture.groupStorage.loadGroups().isEmpty }
        #expect(fixture.groupStorage.loadGroups().map(\.name) == ["Reports"])
        try await waitUntil(timeout: .seconds(2)) { hosted.controller.presentedViewControllers?.isEmpty ?? true }
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
