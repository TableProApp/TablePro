//
//  DataGridCellFactoryPerfTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Column Width Optimization")
@MainActor
struct ColumnWidthOptimizationTests {
    @Test("Column width is within min/max bounds")
    func columnWidthWithinBounds() {
        let factory = DataGridCellFactory()
        let tableRows = TestFixtures.makeTableRows(rowCount: 10)

        for (index, column) in tableRows.columns.enumerated() {
            let width = factory.calculateOptimalColumnWidth(
                for: column,
                columnIndex: index,
                tableRows: tableRows
            )
            #expect(width >= 60, "Width should be at least 60 (min)")
            #expect(width <= 800, "Width should be at most 800 (max)")
        }
    }

    @Test("Header-only column returns reasonable width")
    func headerOnlyColumnWidth() {
        let factory = DataGridCellFactory()
        let tableRows = TableRows.from(
            queryRows: [],
            columns: ["username"],
            columnTypes: [.text(rawType: nil)]
        )

        let width = factory.calculateOptimalColumnWidth(
            for: "username",
            columnIndex: 0,
            tableRows: tableRows
        )
        #expect(width >= 60)
        #expect(width <= 800)
    }

    @Test("Empty header with no rows returns minimum width")
    func emptyHeaderNoRowsReturnsMinWidth() {
        let factory = DataGridCellFactory()
        let tableRows = TableRows.from(
            queryRows: [],
            columns: [""],
            columnTypes: [.text(rawType: nil)]
        )

        let width = factory.calculateOptimalColumnWidth(
            for: "",
            columnIndex: 0,
            tableRows: tableRows
        )
        #expect(width >= 60, "Should return at least minimum width")
    }

    @Test("Very long cell content caps width at maximum")
    func longContentCapsAtMax() {
        let factory = DataGridCellFactory()
        let longValue = String(repeating: "X", count: 5_000)
        let rows: [[String?]] = [[longValue]]
        let tableRows = TableRows.from(
            queryRows: rows,
            columns: ["data"],
            columnTypes: [.text(rawType: nil)]
        )

        let width = factory.calculateOptimalColumnWidth(
            for: "data",
            columnIndex: 0,
            tableRows: tableRows
        )
        #expect(width <= 800, "Width should be capped at max (800)")
    }

    @Test("Many columns still produce valid widths")
    func manyColumnsProduceValidWidths() {
        let factory = DataGridCellFactory()
        let columnCount = 60
        let columns = (0..<columnCount).map { "col_\($0)" }
        let columnTypes = Array(repeating: ColumnType.text(rawType: nil), count: columnCount)
        let rows: [[String?]] = (0..<100).map { rowIdx in
            columns.map { "\($0)_val_\(rowIdx)" }
        }
        let tableRows = TableRows.from(queryRows: rows, columns: columns, columnTypes: columnTypes)

        for (index, column) in columns.enumerated() {
            let width = factory.calculateOptimalColumnWidth(
                for: column,
                columnIndex: index,
                tableRows: tableRows
            )
            #expect(width >= 60)
            #expect(width <= 800)
        }
    }

    @Test("Width based on header-only method matches expected bounds")
    func headerOnlyWidthCalculation() {
        let factory = DataGridCellFactory()

        let shortWidth = factory.calculateColumnWidth(for: "id")
        #expect(shortWidth >= 60)

        let longWidth = factory.calculateColumnWidth(for: "a_very_long_column_name_that_is_descriptive")
        #expect(longWidth > shortWidth)
        #expect(longWidth <= 800)
    }

    @Test("Nil cell values do not crash width calculation")
    func nilCellValuesSafe() {
        let factory = DataGridCellFactory()
        let rows: [[String?]] = [
            [nil],
            ["hello"],
            [nil],
        ]
        let tableRows = TableRows.from(
            queryRows: rows,
            columns: ["name"],
            columnTypes: [.text(rawType: nil)]
        )

        let width = factory.calculateOptimalColumnWidth(
            for: "name",
            columnIndex: 0,
            tableRows: tableRows
        )
        #expect(width >= 60)
        #expect(width <= 800)
    }
}

@Suite("Change Reapplication Version Tracking")
struct ChangeReapplyVersionTests {
    @Test("Version tracking skips redundant work")
    func versionTrackingSkipsRedundantWork() {
        var lastVersion = 0
        var applyCount = 0
        let currentVersion = 3

        func reapplyIfNeeded(version: Int) {
            guard lastVersion != version else { return }
            lastVersion = version
            applyCount += 1
        }

        reapplyIfNeeded(version: currentVersion)
        #expect(applyCount == 1)
        #expect(lastVersion == 3)

        reapplyIfNeeded(version: currentVersion)
        #expect(applyCount == 1, "Should skip when version unchanged")

        reapplyIfNeeded(version: 4)
        #expect(applyCount == 2, "Should apply when version changes")
        #expect(lastVersion == 4)
    }

    @Test("Version starts at zero and tracks increments")
    func versionStartsAtZeroAndIncrements() {
        var lastVersion = 0
        var versions: [Int] = []

        for v in [0, 1, 1, 2, 2, 2, 3] {
            if lastVersion != v {
                lastVersion = v
                versions.append(v)
            }
        }

        #expect(versions == [1, 2, 3], "Only version changes should be recorded")
    }

    @Test("DataChangeManager reloadVersion increments on cell change")
    @MainActor
    func dataChangeManagerVersionIncrements() {
        let manager = DataChangeManager()
        let initialVersion = manager.reloadVersion

        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 0,
            columnName: "name",
            oldValue: "old",
            newValue: "new"
        )

        #expect(manager.reloadVersion > initialVersion)
    }
}
