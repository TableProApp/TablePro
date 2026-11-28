//
//  TableContextMenu.swift
//  TablePro
//

import AppKit

// A list's contextual menu opened without a pointer: Show Menu from VoiceOver on the list or on a cell. Each path hands
// the table the right-click a pointer on the row would send, as AppKit does for the keyboard's menu key, so
// `clickedRow` names the row and every menu keeps one rule: the selection when the row is in it, else the row.
internal enum TableContextMenuTarget: Equatable {
    case row(Int)
    case emptyArea

    // `requestedRow` is a cell's row, nil for the list itself. The list opens over the last selected row, where AppKit
    // anchors a keyboard menu.
    internal static func resolve(requestedRow: Int?, selectedRow: Int, numberOfRows: Int) -> TableContextMenuTarget {
        let rows = 0..<numberOfRows
        if let requestedRow {
            return rows.contains(requestedRow) ? .row(requestedRow) : .emptyArea
        }
        return rows.contains(selectedRow) ? .row(selectedRow) : .emptyArea
    }
}

// A table that builds each row's menu in `menu(for:)` and leaves `menu` nil, so AppKit cannot tell it has one.
@MainActor
internal protocol RowMenuBuildingTableView: NSTableView {
    var buildsRowMenus: Bool { get }
}

// A table that is not an outline names what each row shows, so a deferred menu can tell the row still shows it.
@MainActor
internal protocol ContextMenuRowIdentifying: NSTableView {
    func contextMenuRowIdentity(_ row: Int) -> AnyHashable?
}

internal extension NSTableView {
    var offersContextMenu: Bool {
        menu != nil || (self as? any RowMenuBuildingTableView)?.buildsRowMenus == true
    }

    func contextMenuIdentity(ofRow row: Int) -> AnyHashable? {
        if let outline = self as? NSOutlineView {
            return outline.item(atRow: row).map { AnyHashable(ObjectIdentifier($0 as AnyObject)) }
        }
        return (self as? any ContextMenuRowIdentifying)?.contextMenuRowIdentity(row)
    }

    // The event a right-click at the middle of the cell sends; column -1 takes the middle of the row.
    func contextMenuEvent(row: Int, column: Int) -> NSEvent? {
        guard let window, (0..<numberOfRows).contains(row) else { return nil }
        let rect = (0..<numberOfColumns).contains(column) ? frameOfCell(atColumn: column, row: row) : rect(ofRow: row)
        return NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: convert(NSPoint(x: rect.midX, y: rect.midY), to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    }

    // False with nothing selected, so the caller's `super` opens AppKit's empty-area menu.
    func showContextMenuForSelectedRow() -> Bool {
        guard offersContextMenu,
              case .row(let row) = TableContextMenuTarget.resolve(requestedRow: nil, selectedRow: selectedRow, numberOfRows: numberOfRows)
        else { return false }
        scrollRowToVisible(row)
        scheduleContextMenu(row: row, column: -1)
        return true
    }

    // Deferred, because a Show Menu request has to return before the menu starts tracking or the client times out.
    func scheduleContextMenu(row: Int, column: Int) {
        let request = DeferredContextMenu(table: self, row: row, column: column)
        DispatchQueue.main.async { request.present() }
    }
}

@MainActor
private final class DeferredContextMenu {
    private weak var table: NSTableView?
    private let row: Int
    private let column: Int
    private let identity: AnyHashable?

    init(table: NSTableView, row: Int, column: Int) {
        self.table = table
        self.row = row
        self.column = column
        identity = table.contextMenuIdentity(ofRow: row)
    }

    // A reload in between can put another item on the row, and then nothing opens.
    func present() {
        guard let table, (0..<table.numberOfRows).contains(row), table.contextMenuIdentity(ofRow: row) == identity,
              let event = table.contextMenuEvent(row: row, column: column),
              let menu = table.menu(for: event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: table)
    }
}

internal extension NSView {
    var enclosingTableView: NSTableView? {
        var view = superview
        while let current = view {
            if let table = current as? NSTableView { return table }
            view = current.superview
        }
        return nil
    }

    // AppKit's AXRow is its own element and offers no Show Menu, so a cell answers for its row with the menu a
    // right-click on it opens. False when the table has no menu, so the caller's `super` decides.
    func showEnclosingRowContextMenu() -> Bool {
        guard let table = enclosingTableView, table.offersContextMenu,
              case .row(let row) = TableContextMenuTarget.resolve(
                  requestedRow: table.row(for: self),
                  selectedRow: table.selectedRow,
                  numberOfRows: table.numberOfRows
              )
        else { return false }
        table.scheduleContextMenu(row: row, column: table.column(for: self))
        return true
    }
}
