//
//  FieldDrivenListMenuTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@Suite("Field driven list context menu")
@MainActor
struct FieldDrivenListMenuTests {
    private static let rowCount = 3

    /// Stands in for the coordinator: row 0 is a section header and carries no menu, row 1 is an
    /// item, and row 2 belongs to a list that supplies no menu items at all.
    private final class Provider: NSObject, NSTableViewDelegate, FieldDrivenMenuProviding {
        private(set) var askedRows: [Int] = []

        func menu(forRow row: Int) -> NSMenu? {
            askedRows.append(row)
            guard row == 1 else { return nil }
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: "Copy", action: nil, keyEquivalent: ""))
            return menu
        }
    }

    private final class Source: NSObject, NSTableViewDataSource {
        func numberOfRows(in tableView: NSTableView) -> Int { rowCount }
    }

    private struct List {
        let tableView: FieldDrivenTableView
        let provider: Provider
        let source: Source
        let window: NSWindow
    }

    private func makeList() -> List {
        let tableView = FieldDrivenTableView()
        tableView.headerView = nil
        tableView.rowHeight = 30
        tableView.allowsEmptySelection = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FieldDrivenColumn"))
        column.width = 280
        tableView.addTableColumn(column)

        let provider = Provider()
        let source = Source()
        tableView.dataSource = source
        tableView.delegate = provider

        let frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        let scrollView = NSScrollView(frame: frame)
        scrollView.documentView = tableView
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scrollView
        tableView.reloadData()
        window.layoutIfNeeded()
        tableView.layoutSubtreeIfNeeded()
        return List(tableView: tableView, provider: provider, source: source, window: window)
    }

    private func rightClick(_ list: List, row: Int) -> NSMenu? {
        let rect = list.tableView.rect(ofRow: row)
        let inWindow = list.tableView.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        guard let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: inWindow,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: list.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else {
            Issue.record("Could not synthesize a right-click event")
            return nil
        }
        return list.tableView.menu(for: event)
    }

    /// The regression. `selectRowIndexes` does not consult `tableView(_:shouldSelectRow:)`, so a
    /// right-click on a day header in the query history drawer used to select the header, which the
    /// coordinator reads back as an empty selection, and then showed no menu at all.
    @Test("Right-clicking a row with no menu leaves the selection alone")
    func rightClickWithoutMenuKeepsSelection() {
        let list = makeList()
        list.tableView.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)

        let menu = rightClick(list, row: 0)

        #expect(menu == nil)
        #expect(list.tableView.selectedRowIndexes == IndexSet(integer: 2))
    }

    @Test("Right-clicking a row that has a menu selects it and returns the menu")
    func rightClickWithMenuSelectsTheRow() {
        let list = makeList()
        list.tableView.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)

        let menu = rightClick(list, row: 1)

        #expect(menu?.items.count == 1)
        #expect(list.tableView.selectedRowIndexes == IndexSet(integer: 1))
    }

    /// A right-click inside an existing selection acts on the whole selection, so it must not
    /// collapse it down to the clicked row.
    @Test("Right-clicking inside the selection keeps the whole selection")
    func rightClickInsideSelectionKeepsIt() {
        let list = makeList()
        list.tableView.allowsMultipleSelection = true
        list.tableView.selectRowIndexes(IndexSet([1, 2]), byExtendingSelection: false)

        let menu = rightClick(list, row: 1)

        #expect(menu?.items.count == 1)
        #expect(list.tableView.selectedRowIndexes == IndexSet([1, 2]))
    }

    @Test("The delegate is asked before the selection is touched")
    func providerIsConsultedFirst() {
        let list = makeList()
        list.tableView.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)

        _ = rightClick(list, row: 0)

        #expect(list.provider.askedRows == [0])
    }

    @Test("A click outside every row produces no menu and no selection change")
    func clickBelowTheRowsIsIgnored() {
        let list = makeList()
        list.tableView.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)

        let below = list.tableView.convert(NSPoint(x: 10, y: list.tableView.bounds.height + 40), to: nil)
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: below,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: list.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )

        #expect(event.flatMap { list.tableView.menu(for: $0) } == nil)
        #expect(list.tableView.selectedRowIndexes == IndexSet(integer: 2))
        #expect(list.provider.askedRows.isEmpty)
    }
}
