//
//  TableContextMenuTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@MainActor
struct TableContextMenuTests {
    private final class Source: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        func numberOfRows(in tableView: NSTableView) -> Int { 6 }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            NSTableCellView()
        }
    }

    private struct List {
        let table: NSTableView
        let source: Source
        let window: NSWindow
    }

    private func makeList(withMenu: Bool = true) -> List {
        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 24
        table.allowsMultipleSelection = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Column"))
        column.width = 280
        table.addTableColumn(column)
        let source = Source()
        table.dataSource = source
        table.delegate = source
        if withMenu {
            table.menu = NSMenu()
        }
        let frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        let scrollView = NSScrollView(frame: frame)
        scrollView.documentView = table
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        table.reloadData()
        window.layoutIfNeeded()
        table.layoutSubtreeIfNeeded()
        return List(table: table, source: source, window: window)
    }

    @Test("A cell's Show Menu opens over its own row, selected or not")
    func requestedRowOpensItsOwnMenu() {
        #expect(TableContextMenuTarget.resolve(requestedRow: 4, selectedRow: 1, numberOfRows: 6) == .row(4))
        #expect(TableContextMenuTarget.resolve(requestedRow: 1, selectedRow: 1, numberOfRows: 6) == .row(1))
    }

    @Test("The list's Show Menu with rows selected opens over the last selected row")
    func selectionWithoutAClickOpensOverTheSelection() {
        #expect(TableContextMenuTarget.resolve(requestedRow: nil, selectedRow: 3, numberOfRows: 6) == .row(3))
    }

    @Test("With nothing clicked or selected the list keeps its empty-area menu")
    func neitherKeepsTheEmptyAreaMenu() {
        #expect(TableContextMenuTarget.resolve(requestedRow: nil, selectedRow: -1, numberOfRows: 6) == .emptyArea)
        #expect(TableContextMenuTarget.resolve(requestedRow: 6, selectedRow: -1, numberOfRows: 6) == .emptyArea)
    }

    @Test("The event for the selection's row makes AppKit report it clicked, so the menu acts on the whole selection")
    func selectionEventSetsClickedRowInsideTheSelection() throws {
        let list = makeList()
        defer { list.window.orderOut(nil) }
        list.table.selectRowIndexes(IndexSet([1, 3]), byExtendingSelection: false)
        let target = TableContextMenuTarget.resolve(
            requestedRow: nil,
            selectedRow: list.table.selectedRow,
            numberOfRows: list.table.numberOfRows
        )
        guard case .row(let row) = target else {
            Issue.record("A selection must open over a row, got \(target)")
            return
        }
        let event = try #require(list.table.contextMenuEvent(row: row, column: -1))

        #expect(list.table.menu(for: event) === list.table.menu)
        #expect(list.table.clickedRow == 3)
        #expect(SidebarMenuTarget.resolve(clicked: list.table.clickedRow, selection: Array(list.table.selectedRowIndexes)) == [1, 3])
    }

    @Test("A cell's event lands on its own row and column")
    func cellEventLandsOnItsRow() throws {
        let list = makeList()
        defer { list.window.orderOut(nil) }
        let cell = try #require(list.table.view(atColumn: 0, row: 4, makeIfNecessary: true))

        #expect(cell.enclosingTableView === list.table)
        let event = try #require(list.table.contextMenuEvent(row: list.table.row(for: cell), column: list.table.column(for: cell)))
        _ = list.table.menu(for: event)
        #expect(list.table.clickedRow == 4)
        #expect(list.table.clickedColumn == 0)
    }

    @Test("A deferred menu recognizes an outline row by its item, so a reload that moves another item there cancels it")
    func outlineRowIdentityIsItsItem() throws {
        final class Source: NSObject, NSOutlineViewDataSource {
            var items: [NSString] = ["a", "b"]
            func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { item == nil ? items.count : 0 }
            func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { items[index] }
            func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }
        }
        let outline = NSOutlineView()
        let source = Source()
        outline.dataSource = source
        outline.reloadData()
        let before = try #require(outline.contextMenuIdentity(ofRow: 0))
        #expect(before == AnyHashable(ObjectIdentifier(source.items[0])))

        source.items = ["c", "a"]
        outline.reloadData()
        #expect(outline.contextMenuIdentity(ofRow: 0) != before)
        #expect(outline.contextMenuIdentity(ofRow: 1) == before)
    }

    @Test("A table without a menu offers none, so its cells leave Show Menu to AppKit")
    func tableWithoutMenuOffersNone() {
        let list = makeList(withMenu: false)
        defer { list.window.orderOut(nil) }
        list.table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)

        #expect(!list.table.offersContextMenu)
        #expect(!list.table.showContextMenuForSelectedRow())
    }

    @Test("A list built from menu items offers Show Menu only when it has items")
    func fieldDrivenListOffersShowMenuWithItems() {
        final class Provider: NSObject, NSTableViewDelegate, FieldDrivenMenuProviding {
            var offersMenus = false
            func menu(forRow row: Int) -> NSMenu? { nil }
        }
        let table = FieldDrivenTableView()
        let provider = Provider()
        table.delegate = provider

        #expect(!table.offersContextMenu)
        #expect(!table.isAccessibilitySelectorAllowed(#selector(NSTableView.accessibilityPerformShowMenu)))
        provider.offersMenus = true
        #expect(table.offersContextMenu)
        #expect(table.isAccessibilitySelectorAllowed(#selector(NSTableView.accessibilityPerformShowMenu)))
    }
}
