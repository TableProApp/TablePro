//
//  SizeAllColumnsToFitTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class CountingLayoutPersister: ColumnLayoutPersisting {
    private(set) var saveCount = 0

    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) { saveCount += 1 }
    func clear(for key: ColumnLayoutTableKey) {}
}

/// `captureColumnLayout()` asks `tableRowsProvider` for the result exactly once, which is what
/// these tests count. The walks are otherwise invisible from outside.
@Suite("Size All Columns to Fit", .serialized)
@MainActor
struct SizeAllColumnsToFitTests {
    private struct Grid {
        let window: NSWindow
        let coordinator: TableViewCoordinator
        let persister: CountingLayoutPersister
        let rowsRequested: () -> Int
    }

    private func makeGrid(columns: [String], rows: Int = 3) -> Grid {
        let persister = CountingLayoutPersister()
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: persister
        )
        coordinator.tabType = .table
        coordinator.connectionId = UUID()
        coordinator.tableName = "users"

        let queryRows = (0 ..< rows).map { row in columns.map { PluginCellValue.text("\($0)-\(row)") } }
        let tableRows = TableRows.from(
            queryRows: queryRows,
            columns: columns,
            columnTypes: Array(repeating: ColumnType.text(rawType: "TEXT"), count: columns.count)
        )

        let counter = RequestCounter()
        coordinator.tableRowsProvider = {
            counter.value += 1
            return tableRows
        }
        coordinator.rebuildColumnMetadataCache(from: tableRows)
        coordinator.updateCache()

        let tableView = KeyHandlingTableView(frame: NSRect(x: 0, y: 0, width: 900, height: 200))
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
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
            widthCalculator: { _, _ in 90 }
        )
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 200))
        scrollView.documentView = tableView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        tableView.reloadData()
        tableView.layoutSubtreeIfNeeded()
        return Grid(
            window: window,
            coordinator: coordinator,
            persister: persister,
            rowsRequested: { counter.value }
        )
    }

    @MainActor
    private final class RequestCounter {
        var value = 0
    }

    /// One read for the menu item and one for the single capture, whatever the column count.
    @Test("Fitting every column captures the layout once")
    func fittingEveryColumnCapturesOnce() throws {
        let grid = makeGrid(columns: ["id", "name", "email", "city", "country"])
        defer { grid.coordinator.layoutPersistTask?.cancel() }
        let before = grid.rowsRequested()

        grid.coordinator.sizeAllColumnsToFit(NSMenuItem())

        #expect(grid.rowsRequested() - before == 2)
    }

    @Test("The capture count does not grow with the number of columns")
    func captureCountIsIndependentOfColumnCount() throws {
        let narrow = makeGrid(columns: ["id", "name"])
        defer { narrow.coordinator.layoutPersistTask?.cancel() }
        let narrowBefore = narrow.rowsRequested()
        narrow.coordinator.sizeAllColumnsToFit(NSMenuItem())
        let narrowCost = narrow.rowsRequested() - narrowBefore

        let wide = makeGrid(columns: (0 ..< 24).map { "c\($0)" })
        defer { wide.coordinator.layoutPersistTask?.cancel() }
        let wideBefore = wide.rowsRequested()
        wide.coordinator.sizeAllColumnsToFit(NSMenuItem())
        let wideCost = wide.rowsRequested() - wideBefore

        #expect(narrowCost == wideCost)
    }

    /// Without ownership the next reconcile measures every column from its content and drops the fit.
    @Test("Every fitted column is still marked user-sized")
    func everyFittedColumnKeepsOwnership() throws {
        let grid = makeGrid(columns: ["id", "name", "email"])
        defer { grid.coordinator.layoutPersistTask?.cancel() }

        grid.coordinator.sizeAllColumnsToFit(NSMenuItem())

        #expect(grid.coordinator.userSizedColumnNames == ["id", "name", "email"])
    }

    @Test("Every fitted column ends up in the persisted layout")
    func everyFittedColumnIsPersisted() throws {
        let grid = makeGrid(columns: ["id", "name", "email"])

        grid.coordinator.sizeAllColumnsToFit(NSMenuItem())
        grid.coordinator.flushPendingColumnLayoutPersistence()

        #expect(grid.persister.saveCount == 1)
    }

    /// A fit inside a rebuild must leave the rebuild's own suppression intact.
    @Test("A fit restores the rebuild flag it found")
    func theRebuildFlagIsRestored() throws {
        let grid = makeGrid(columns: ["id", "name"])
        defer { grid.coordinator.layoutPersistTask?.cancel() }

        grid.coordinator.sizeAllColumnsToFit(NSMenuItem())
        #expect(!grid.coordinator.isRebuildingColumns)

        grid.coordinator.isRebuildingColumns = true
        grid.coordinator.sizeAllColumnsToFit(NSMenuItem())
        #expect(grid.coordinator.isRebuildingColumns)
        grid.coordinator.isRebuildingColumns = false
    }

    @Test("Fitting every column still repaints the drawn cells")
    func fittingEveryColumnStillRepaints() throws {
        let grid = makeGrid(columns: ["id", "name", "email"])
        defer { grid.coordinator.layoutPersistTask?.cancel() }
        let tableView = try #require(grid.coordinator.tableView)
        for row in 0 ..< tableView.numberOfRows {
            _ = tableView.rowView(atRow: row, makeIfNecessary: true)
        }
        tableView.display()

        var contentViews: [DataGridRowContentView] = []
        tableView.enumerateAvailableRowViews { rowView, _ in
            guard let content = rowView.subviews.first as? DataGridRowContentView else { return }
            contentViews.append(content)
        }
        #expect(!contentViews.isEmpty)
        #expect(contentViews.allSatisfy { !$0.needsDisplay })

        grid.coordinator.sizeAllColumnsToFit(NSMenuItem())

        let everyRowAwaitsRepaint = contentViews.allSatisfy { $0.needsDisplay }
        #expect(everyRowAwaitsRepaint)
    }
}
