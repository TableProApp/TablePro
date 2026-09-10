import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class FakeColumnLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@MainActor
private struct GutterGrid {
    let scrollView: NSScrollView
    let tableView: KeyHandlingTableView
    let coordinator: TableViewCoordinator
    let gutter: DataGridRowGutterView

    init(rowCount: Int = 40, dataColumns: Int = 30, showRowNumbers: Bool = true) {
        let columns = (0..<dataColumns).map { "col\($0)" }
        let rows = (0..<rowCount).map { row in columns.map { PluginCellValue.text("\($0)-\(row)") } }
        let tableRows = TableRows.from(
            queryRows: rows,
            columns: columns,
            columnTypes: Array(repeating: ColumnType.text(rawType: nil), count: dataColumns)
        )

        coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: FakeColumnLayoutPersister()
        )
        coordinator.tableRowsProvider = { tableRows }

        tableView = KeyHandlingTableView()
        tableView.coordinator = coordinator
        tableView.delegate = coordinator
        tableView.dataSource = coordinator
        tableView.rowHeight = 22
        tableView.allowsMultipleSelection = true
        tableView.headerView = NSTableHeaderView(frame: NSRect(x: 0, y: 0, width: 400, height: 28))

        let rowNumberColumn = DataGridView.makeRowNumberColumn()
        tableView.addTableColumn(rowNumberColumn)
        rowNumberColumn.isHidden = !showRowNumbers
        for name in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("dataColumn-\(name)"))
            column.width = 120
            tableView.addTableColumn(column)
        }

        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.documentView = tableView

        coordinator.tableView = tableView
        coordinator.rebuildColumnMetadataCache(from: tableRows)
        coordinator.updateCache()
        tableView.reloadData()

        gutter = DataGridRowGutterView(frame: .zero)
        gutter.coordinator = coordinator
        tableView.addSubview(gutter)
        scrollView.addFloatingSubview(gutter, for: .horizontal)
        coordinator.rowGutter = gutter
        scrollView.layoutSubtreeIfNeeded()
        gutter.synchronizeGeometry()
    }

    func scrollHorizontally(to x: CGFloat) {
        scrollView.contentView.scroll(to: NSPoint(x: x, y: scrollView.contentView.bounds.origin.y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrollView.layoutSubtreeIfNeeded()
    }

    var gutterWindowMinX: CGFloat { gutter.convert(gutter.bounds, to: nil).minX }
}

@Suite("Pinned row gutter")
@MainActor
struct DataGridRowGutterTests {
    @Test("the gutter holds the leading edge at every horizontal scroll offset")
    func gutterHoldsLeadingEdge() {
        let grid = GutterGrid()
        let atOrigin = grid.gutterWindowMinX

        grid.scrollHorizontally(to: 900)
        #expect(grid.gutterWindowMinX == atOrigin)

        grid.scrollHorizontally(to: 2400)
        #expect(grid.gutterWindowMinX == atOrigin)
    }

    @Test("the gutter is as wide as the row-number column it mirrors")
    func gutterMirrorsColumnWidth() {
        let grid = GutterGrid()
        let column = grid.tableView.tableColumns.first {
            $0.identifier == ColumnIdentitySchema.rowNumberIdentifier
        }

        #expect(column != nil)
        #expect(grid.gutter.frame.width == column?.width)
        #expect(grid.gutter.frame.width > 0)
    }

    @Test("the gutter width follows the column when the row count crosses a digit boundary")
    func gutterWidthFollowsRowCount() {
        let narrow = GutterGrid(rowCount: 9)
        let wide = GutterGrid(rowCount: 100_000)

        #expect(wide.gutter.frame.width > narrow.gutter.frame.width)
        #expect(wide.gutter.frame.width == DataGridRowGutterView.width(of: wide.tableView))
    }

    @Test("turning row numbers off hides the gutter and leaves the column attached at the head")
    func rowNumbersOffHidesGutter() {
        let grid = GutterGrid(showRowNumbers: false)

        #expect(grid.gutter.isHidden)
        #expect(DataGridRowGutterView.width(of: grid.tableView) == 0)
        #expect(grid.tableView.tableColumns.first?.identifier == ColumnIdentitySchema.rowNumberIdentifier)
    }

    @Test("the gutter is not a subview of the table view, so a wide result pays nothing for it")
    func gutterIsNotATableSubview() {
        let grid = GutterGrid(dataColumns: 200)

        #expect(grid.gutter.superview !== grid.tableView)
        #expect(!grid.tableView.subviews.contains(grid.gutter))
    }
}

@Suite("Scrolling a column clear of the pinned gutter")
@MainActor
struct GutterAwareColumnScrollTests {
    @Test("a column reached from off screen lands clear of the gutter")
    func columnLandsClearOfGutter() {
        let grid = GutterGrid()
        grid.scrollHorizontally(to: 2400)
        let gutterWidth = DataGridRowGutterView.width(of: grid.tableView)

        let target = grid.tableView.tableColumns.count - 20
        grid.coordinator.scrollColumnToVisible(tableColumnIndex: target)
        grid.scrollView.layoutSubtreeIfNeeded()

        let origin = grid.scrollView.contentView.bounds.origin.x
        let columnRect = grid.tableView.rect(ofColumn: target)
        #expect(columnRect.minX >= origin + gutterWidth)
    }

    @Test("a column already clear of the gutter is not scrolled at all")
    func clearColumnDoesNotScroll() {
        let grid = GutterGrid()
        grid.scrollHorizontally(to: 600)
        let before = grid.scrollView.contentView.bounds.origin.x
        let gutterWidth = DataGridRowGutterView.width(of: grid.tableView)

        /// A column that is wholly inside the viewport and already past the gutter, so AppKit has
        /// nothing to do and neither does the correction on top of it.
        let visible = grid.tableView.visibleRect
        let target = grid.tableView.columnIndexes(in: visible).first {
            let rect = grid.tableView.rect(ofColumn: $0)
            return rect.minX >= before + gutterWidth && rect.maxX <= visible.maxX
        }

        #expect(target != nil)
        grid.coordinator.scrollColumnToVisible(tableColumnIndex: target ?? 0)

        #expect(grid.scrollView.contentView.bounds.origin.x == before)
    }
}

@Suite("Select rows intersecting the selection")
@MainActor
struct SelectIntersectingRowsTests {
    @Test("a cell rectangle widens to every column of every row it covers")
    func rectangleWidensToWholeRows() {
        let controller = GridSelectionController()
        controller.update(
            .single(
                GridRect(rows: 2...4, columns: 1...2),
                anchor: GridCoord(row: 2, displayColumn: 1),
                active: GridCoord(row: 4, displayColumn: 2)
            )
        )

        controller.selectEntireRows(controller.selection.affectedRows, totalColumns: 6)

        /// One rectangle, because rows 2 to 4 are contiguous.
        #expect(controller.selection.rectangles.count == 1)
        #expect(controller.selection.affectedRows == IndexSet([2, 3, 4]))
        #expect(controller.selection.affectedColumns == IndexSet(integersIn: 0..<6))
    }

    @Test("a discontiguous selection stays discontiguous instead of filling the gap")
    func discontiguousStaysDiscontiguous() {
        let controller = GridSelectionController()

        controller.selectEntireRows([3, 17], totalColumns: 4)

        #expect(controller.selection.rectangles.count == 2)
        #expect(controller.selection.affectedRows == IndexSet([3, 17]))
        #expect(!controller.selection.contains(row: 10, displayColumn: 0))
        #expect(controller.selection.contains(row: 17, displayColumn: 3))
    }

    /// A contiguous run must not cost one rectangle per row: the overlay, the row fill and
    /// `columns(in:)` all walk every rectangle for every visible row, so Select All then Shift+Space
    /// over a large result would stall on its own bookkeeping.
    @Test("contiguous runs coalesce, and gaps still split them")
    func contiguousRunsCoalesce() {
        let controller = GridSelectionController()

        controller.selectEntireRows(Array(0..<10_000) + [20_000], totalColumns: 3)

        #expect(controller.selection.rectangles.count == 2)
        #expect(controller.selection.rectangles.first?.rows == 0...9_999)
        #expect(controller.selection.rectangles.last?.rows == 20_000...20_000)
        #expect(!controller.selection.contains(row: 15_000, displayColumn: 0))
    }

    @Test("selectEntireRow is the single-row case of the same widening")
    func singleRowMatchesPlural() {
        let single = GridSelectionController()
        let plural = GridSelectionController()

        single.selectEntireRow(5, totalColumns: 7)
        plural.selectEntireRows([5], totalColumns: 7)

        #expect(single.selection == plural.selection)
    }

    @Test("widening with no columns leaves the selection alone")
    func noColumnsLeavesSelectionAlone() {
        let controller = GridSelectionController()

        controller.selectEntireRows([1, 2], totalColumns: 0)

        #expect(controller.selection.isEmpty)
    }

    /// Numbers spells this command Option-Command-Return, which is already the shipped default for
    /// Execute Query Without Limit. That is a menu item, and AppKit resolves a menu key equivalent
    /// before the event reaches a view, so binding the grid to it would make one of the two dead.
    @Test("the shortcut does not collide with a shipped key equivalent")
    func shortcutDoesNotCollideWithAMenuItem() {
        let claimed = Set(KeyboardSettings.defaultShortcuts.values)

        #expect(claimed.contains(.special(.return, command: true, option: true)))
        #expect(claimed.contains(.special(.space)))
        #expect(!claimed.contains(.special(.space, shift: true)))
    }
}
