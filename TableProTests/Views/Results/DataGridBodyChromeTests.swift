//
//  DataGridBodyChromeTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class BodyChromeLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

/// The grid draws its own column separators because `NSTableView` draws vertical grid lines with one
/// separator view per column and re-sorts its whole subview list on every layout pass: 518ms for a
/// single pass on a 500-column result, against 0.03ms with the mask cleared (#2381).
///
/// These measure through `rect(ofColumn:)` and through the rendered pixels, never through the chrome
/// type's own arithmetic, so they cannot pass by agreeing with themselves.
@Suite("Data grid body chrome")
@MainActor
struct DataGridBodyChromeTests {
    private struct Grid {
        let window: NSWindow
        let tableView: KeyHandlingTableView
        let coordinator: TableViewCoordinator
    }

    private func makeGrid(columns: [String], rows: Int = 3, width: CGFloat = 600) -> Grid {
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: BodyChromeLayoutPersister()
        )
        let queryRows = (0 ..< rows).map { row in
            columns.map { PluginCellValue.text("\($0)-\(row)") }
        }
        let tableRows = TableRows.from(
            queryRows: queryRows,
            columns: columns,
            columnTypes: Array(repeating: ColumnType.text(rawType: "TEXT"), count: columns.count)
        )
        coordinator.tableRowsProvider = { tableRows }
        coordinator.rebuildColumnMetadataCache(from: tableRows)
        coordinator.updateCache()

        let tableView = KeyHandlingTableView(frame: NSRect(x: 0, y: 0, width: width, height: 200))
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 1, height: 0)
        tableView.rowHeight = 21
        tableView.coordinator = coordinator
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        tableView.addTableColumn(DataGridView.makeRowNumberColumn())
        coordinator.tableView = tableView
        coordinator.columnPool.reconcile(
            tableView: tableView,
            schema: coordinator.identitySchema,
            columnTypes: Array(repeating: ColumnType.text(rawType: "TEXT"), count: columns.count),
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: { _, _ in 120 }
        )

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 200))
        scrollView.documentView = tableView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        tableView.reloadData()
        tableView.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        return Grid(window: window, tableView: tableView, coordinator: coordinator)
    }

    /// Clearing the mask is the fix, so a test that only checked the drawing would pass with the
    /// separator views back and the cost with them. The fixture sets the mask itself, so asserting
    /// on the fixture proves nothing; this reads the one line in the app that decides it.
    @Test("The grid never asks AppKit for vertical grid lines")
    func gridStyleMaskIsClearedInTheAppItself() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TablePro/Views/Results/DataGridView.swift")
        let text = try String(contentsOf: source, encoding: .utf8)

        #expect(text.contains("gridStyleMask = []"))
        #expect(
            !text.contains("solidVerticalGridLineMask"),
            "one separator view per column costs 518ms of layout per pass on a 500-column result"
        )
    }

    /// A partial repaint invalidates one cell's rect, and `rect(ofColumn:)` includes the intercell
    /// spacing, so the next column's separator lives inside the rect being repainted. It has to be
    /// redrawn there or every visited cell loses its right-hand rule until a full-row repaint.
    @Test("Repainting one cell redraws the separator standing inside its rect")
    func partialRepaintRedrawsTheSeparatorInsideIt() throws {
        let grid = makeGrid(columns: ["id", "name", "total"])
        let view = NSView(frame: grid.tableView.bounds)
        let first = try #require(grid.coordinator.firstPresentedColumnIndex())
        let next = try #require(grid.coordinator.nextPresentedColumnIndex(after: first))
        let cellRect = grid.tableView.rect(ofColumn: first)
        let neighbourSeparator = grid.tableView.rect(ofColumn: next).minX - DataGridBodyChrome.separatorThickness

        #expect(
            neighbourSeparator >= cellRect.minX && neighbourSeparator < cellRect.maxX,
            "the neighbour's separator sits inside the repainted cell's rect, so the repaint erases it"
        )

        let separators = DataGridBodyChrome.separatorRects(
            in: cellRect,
            of: view,
            tableView: grid.tableView,
            presentsColumn: { grid.coordinator.presentsColumn(atTableColumnIndex: $0) }
        )

        #expect(separators.map(\.minX).contains(neighbourSeparator))
    }

    /// AppKit put its separator at the leading edge of every column, which is the boundary the
    /// reader sees between two columns and the one that keeps the row-number column's edge.
    @Test("A separator stands at the leading edge of every presented column")
    func separatorsSitAtPresentedColumnLeadingEdges() {
        let grid = makeGrid(columns: ["id", "name", "total"])
        let view = NSView(frame: grid.tableView.bounds)

        let separators = DataGridBodyChrome.separatorRects(
            in: view.bounds,
            of: view,
            tableView: grid.tableView,
            presentsColumn: { grid.coordinator.presentsColumn(atTableColumnIndex: $0) }
        )

        let expected = grid.tableView.tableColumns.indices
            .filter { grid.coordinator.presentsColumn(atTableColumnIndex: $0) }
            .map { grid.tableView.rect(ofColumn: $0).minX - DataGridBodyChrome.separatorThickness }
        #expect(!expected.isEmpty)
        #expect(separators.map(\.minX) == expected)
        #expect(separators.allSatisfy { $0.width == DataGridBodyChrome.separatorThickness })
    }

    /// The row-number column is an attached column that the result does not present, so it gets no
    /// separator of its own; the boundary the reader sees there is the first data column's edge.
    @Test("The row-number column is not given a separator of its own")
    func rowNumberColumnHasNoSeparator() {
        let grid = makeGrid(columns: ["id", "name"])
        let rowNumber = grid.tableView.column(withIdentifier: ColumnIdentitySchema.rowNumberIdentifier)

        #expect(rowNumber >= 0)
        #expect(!grid.coordinator.presentsColumn(atTableColumnIndex: rowNumber))
    }

    /// The colour has to come from `tableView.gridColor`, which is the dynamic catalog colour AppKit
    /// was filling with, so an appearance change carries the separator with it and there is no
    /// second spelling to keep in sync. A hardcoded colour would pass a geometry test and be wrong
    /// in dark mode.
    @Test("The separator is drawn in the table view's own grid colour")
    func separatorUsesTheTableViewGridColor() throws {
        let grid = makeGrid(columns: ["id", "name"])
        grid.tableView.gridColor = .systemRed
        let rowView = try #require(grid.tableView.rowView(atRow: 0, makeIfNecessary: true) as? DataGridRowView)
        rowView.layoutSubtreeIfNeeded()

        let rep = try #require(rowView.bitmapImageRepForCachingDisplay(in: rowView.bounds))
        rowView.cacheDisplay(in: rowView.bounds, to: rep)

        let firstData = try #require(grid.coordinator.firstPresentedColumnIndex())
        let boundary = grid.tableView.rect(ofColumn: firstData).minX
        let scale = CGFloat(rep.pixelsWide) / rowView.bounds.width
        let sampled = rep.colorAt(
            x: Int((boundary - 0.5) * scale),
            y: Int(rowView.bounds.height * scale / 2)
        )?.usingColorSpace(.deviceRGB)
        let expected = NSColor.systemRed.usingColorSpace(.deviceRGB)

        let sampledRed = try #require(sampled?.redComponent)
        let sampledGreen = try #require(sampled?.greenComponent)
        let expectedRed = try #require(expected?.redComponent)
        #expect(abs(sampledRed - expectedRed) < 0.15)
        #expect(sampledRed > sampledGreen + 0.3, "the separator has to carry the grid colour, not a fixed grey")
    }

}
