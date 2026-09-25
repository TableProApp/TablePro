//
//  DataGridEmptyResultColumnsTests.swift
//  TableProTests
//
//  A failed Run All leaves an error result active, and an error result has no columns and no rows.
//  The grid stays mounted under the error banner, so its update pass is what decides the headings
//  shown there. It reconciled the column pool only for a result that had columns, and kept the
//  previous run's headings over an empty grid, while a grid mounted fresh over the same result
//  showed the row-number heading alone.
//
//  Driven through a real `NSHostingView`, because the defect lived in `updateNSView`, which only
//  SwiftUI calls.
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class NoopLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@MainActor
private final class HostedGrid {
    private let window: NSWindow
    private let host: NSHostingView<DataGridView>

    init(showing rows: TableRows) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        host = NSHostingView(rootView: Self.makeGrid(showing: rows))
        window.contentView = host
        settle()
    }

    /// A new root value, the way the editor hands the grid a new one on every render, which is what
    /// makes SwiftUI run `updateNSView` against the result it now provides.
    func show(_ rows: TableRows) {
        host.rootView = Self.makeGrid(showing: rows)
        settle()
    }

    func close() {
        window.orderOut(nil)
    }

    var tableView: NSTableView? {
        Self.firstTableView(in: host)
    }

    /// The headings the reader sees: every attached data column that is not hidden.
    var presentedHeadings: [String] {
        guard let tableView else { return [] }
        return tableView.tableColumns
            .filter { !$0.isHidden && $0.identifier != ColumnIdentitySchema.rowNumberIdentifier }
            .map(\.headerCell.stringValue)
    }

    var visibleColumnIdentifiers: [NSUserInterfaceItemIdentifier] {
        tableView?.tableColumns.filter { !$0.isHidden }.map(\.identifier) ?? []
    }

    private static func makeGrid(showing rows: TableRows) -> DataGridView {
        DataGridView(
            tableRowsProvider: { rows },
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: false,
            configuration: DataGridConfiguration(tabType: .query),
            layoutPersister: NoopLayoutPersister(),
            selectedRowIndices: .constant([]),
            sortState: .constant(SortState()),
            columnLayout: .constant(ColumnLayoutState())
        )
    }

    private func settle() {
        for _ in 0 ..< 10 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
    }

    private static func firstTableView(in view: NSView) -> NSTableView? {
        if let tableView = view as? NSTableView { return tableView }
        for subview in view.subviews {
            if let found = firstTableView(in: subview) { return found }
        }
        return nil
    }
}

@MainActor
struct DataGridEmptyResultColumnsTests {
    private static func result(_ columns: [String], rowCount: Int = 1) -> TableRows {
        TableRows.from(
            queryRows: (0 ..< rowCount).map { row in columns.map { PluginCellValue.text("\($0)-\(row)") } },
            columns: columns,
            columnTypes: Array(repeating: ColumnType.text(rawType: nil), count: columns.count)
        )
    }

    @Test("an error result takes down the headings of the result before it")
    func errorResultDropsThePreviousHeadings() throws {
        let grid = HostedGrid(showing: Self.result(["first_col", "second_col"]))
        defer { grid.close() }
        grid.show(Self.result(["third_col"]))
        try #require(grid.presentedHeadings == ["third_col"])

        grid.show(TableRows())

        #expect(grid.presentedHeadings.isEmpty, "got \(grid.presentedHeadings)")
        #expect(grid.tableView?.numberOfRows == 0)
    }

    @Test("updating to an error result leaves the grid a fresh mount over it would show")
    func updateMatchesAFreshMount() throws {
        let updated = HostedGrid(showing: Self.result(["third_col"]))
        defer { updated.close() }
        let fresh = HostedGrid(showing: TableRows())
        defer { fresh.close() }
        try #require(fresh.visibleColumnIdentifiers == [ColumnIdentitySchema.rowNumberIdentifier])

        updated.show(TableRows())

        #expect(updated.visibleColumnIdentifiers == fresh.visibleColumnIdentifiers)
    }

    @Test("the headings come back when a result with columns follows an error result")
    func headingsReturnAfterAnErrorResult() {
        let grid = HostedGrid(showing: Self.result(["third_col"]))
        defer { grid.close() }
        grid.show(TableRows())

        grid.show(Self.result(["x"], rowCount: 2))

        #expect(grid.presentedHeadings == ["x"])
        #expect(grid.tableView?.numberOfRows == 2)
    }
}
