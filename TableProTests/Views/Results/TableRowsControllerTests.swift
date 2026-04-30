import AppKit
import Foundation
import Testing
@testable import TablePro

@Suite("TableRowsController")
@MainActor
struct TableRowsControllerTests {

    final class RecordingTableView: NSTableView {
        struct Reload {
            let rows: IndexSet
            let columns: IndexSet
        }

        var insertCalls: [(IndexSet, NSTableView.AnimationOptions)] = []
        var removeCalls: [(IndexSet, NSTableView.AnimationOptions)] = []
        var rangeReloadCalls: [Reload] = []
        var fullReloadCount = 0
        var stubbedRowCount = 0

        override var numberOfRows: Int { stubbedRowCount }

        override func insertRows(at indexes: IndexSet, withAnimation animationOptions: NSTableView.AnimationOptions = []) {
            insertCalls.append((indexes, animationOptions))
        }

        override func removeRows(at indexes: IndexSet, withAnimation animationOptions: NSTableView.AnimationOptions = []) {
            removeCalls.append((indexes, animationOptions))
        }

        override func reloadData(forRowIndexes rowIndexes: IndexSet, columnIndexes: IndexSet) {
            rangeReloadCalls.append(Reload(rows: rowIndexes, columns: columnIndexes))
        }

        override func reloadData() {
            fullReloadCount += 1
        }
    }

    private func makeTableView(rows: Int, columns: Int) -> RecordingTableView {
        let view = RecordingTableView(frame: .zero)
        for index in 0..<columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col\(index)"))
            view.addTableColumn(column)
        }
        view.stubbedRowCount = rows
        return view
    }

    @Test("apply(.cellChanged) reloads single row+column")
    func cellChangedReloadsOneCell() {
        let table = makeTableView(rows: 5, columns: 3)
        let controller = TableRowsController(tableView: table)
        controller.apply(.cellChanged(row: 2, column: 1))
        #expect(table.rangeReloadCalls.count == 1)
        #expect(table.rangeReloadCalls.first?.rows == IndexSet(integer: 2))
        #expect(table.rangeReloadCalls.first?.columns == IndexSet(integer: 1))
    }

    @Test("apply(.cellChanged) ignores out-of-range row")
    func cellChangedIgnoresOutOfRange() {
        let table = makeTableView(rows: 5, columns: 3)
        let controller = TableRowsController(tableView: table)
        controller.apply(.cellChanged(row: 99, column: 1))
        #expect(table.rangeReloadCalls.isEmpty)
    }

    @Test("apply(.cellsChanged) collapses positions to row+column index sets")
    func cellsChangedCollapses() {
        let table = makeTableView(rows: 5, columns: 3)
        let controller = TableRowsController(tableView: table)
        let positions: Set<CellPosition> = [
            CellPosition(row: 0, column: 0),
            CellPosition(row: 0, column: 2),
            CellPosition(row: 3, column: 1)
        ]
        controller.apply(.cellsChanged(positions))
        #expect(table.rangeReloadCalls.count == 1)
        #expect(table.rangeReloadCalls.first?.rows == IndexSet([0, 3]))
        #expect(table.rangeReloadCalls.first?.columns == IndexSet([0, 1, 2]))
    }

    @Test("apply(.cellsChanged) with empty set is a no-op")
    func cellsChangedEmptyNoOp() {
        let table = makeTableView(rows: 5, columns: 3)
        let controller = TableRowsController(tableView: table)
        controller.apply(.cellsChanged([]))
        #expect(table.rangeReloadCalls.isEmpty)
    }

    @Test("apply(.rowsInserted) calls insertRows with the configured animation")
    func rowsInsertedCallsInsert() {
        let table = makeTableView(rows: 5, columns: 3)
        let controller = TableRowsController(tableView: table)
        controller.apply(.rowsInserted(IndexSet([5, 6])))
        #expect(table.insertCalls.count == 1)
        #expect(table.insertCalls.first?.0 == IndexSet([5, 6]))
        #expect(table.insertCalls.first?.1 == .slideDown)
    }

    @Test("apply(.rowsInserted) with empty set is a no-op")
    func rowsInsertedEmptyNoOp() {
        let table = makeTableView(rows: 5, columns: 3)
        let controller = TableRowsController(tableView: table)
        controller.apply(.rowsInserted(IndexSet()))
        #expect(table.insertCalls.isEmpty)
    }

    @Test("apply(.rowsRemoved) calls removeRows")
    func rowsRemovedCallsRemove() {
        let table = makeTableView(rows: 5, columns: 3)
        let controller = TableRowsController(tableView: table)
        controller.apply(.rowsRemoved(IndexSet([1, 2])))
        #expect(table.removeCalls.count == 1)
        #expect(table.removeCalls.first?.0 == IndexSet([1, 2]))
        #expect(table.removeCalls.first?.1 == .slideUp)
    }

    @Test("apply(.fullReplace) calls reloadData")
    func fullReplaceReloadsAll() {
        let table = makeTableView(rows: 5, columns: 3)
        let controller = TableRowsController(tableView: table)
        controller.apply(.fullReplace)
        #expect(table.fullReloadCount == 1)
    }

    @Test("apply(.columnsReplaced) calls reloadData")
    func columnsReplacedReloadsAll() {
        let table = makeTableView(rows: 5, columns: 3)
        let controller = TableRowsController(tableView: table)
        controller.apply(.columnsReplaced)
        #expect(table.fullReloadCount == 1)
    }

    @Test("apply with detached tableView is a no-op")
    func detachedNoOp() {
        let controller = TableRowsController()
        controller.apply(.fullReplace)
    }

    @Test("animation options are configurable")
    func animationsConfigurable() {
        let table = makeTableView(rows: 5, columns: 3)
        let controller = TableRowsController(tableView: table)
        controller.insertAnimation = .effectFade
        controller.removeAnimation = .effectGap

        controller.apply(.rowsInserted(IndexSet(integer: 3)))
        controller.apply(.rowsRemoved(IndexSet(integer: 1)))

        #expect(table.insertCalls.first?.1 == .effectFade)
        #expect(table.removeCalls.first?.1 == .effectGap)
    }
}
