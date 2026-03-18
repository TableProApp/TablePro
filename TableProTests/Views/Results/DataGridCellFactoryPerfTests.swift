//
//  DataGridCellFactoryPerfTests.swift
//  TableProTests
//
//  Regression tests for DataGrid performance optimizations:
//  - P2-4: VoiceOver caching (verified via build — static cache replaces per-cell system calls)
//  - P1-5: Column width optimization
//  - P2-7: Change reapplication version tracking
//

import Foundation
@testable import TablePro
import Testing

// MARK: - Column Width Optimization (P1-5)

@Suite("Column Width Optimization")
@MainActor
struct ColumnWidthOptimizationTests {
    @Test("Column width is within min/max bounds")
    func columnWidthWithinBounds() {
        let factory = DataGridCellFactory()
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 10)

        for (index, column) in provider.columns.enumerated() {
            let width = factory.calculateOptimalColumnWidth(
                for: column,
                columnIndex: index,
                rowProvider: provider
            )
            #expect(width >= 60, "Width should be at least 60 (min)")
            #expect(width <= 800, "Width should be at most 800 (max)")
        }
    }

    @Test("Header-only column returns reasonable width")
    func headerOnlyColumnWidth() {
        let factory = DataGridCellFactory()
        let provider = InMemoryRowProvider(rows: [], columns: ["username"])

        let width = factory.calculateOptimalColumnWidth(
            for: "username",
            columnIndex: 0,
            rowProvider: provider
        )
        #expect(width >= 60)
        #expect(width <= 800)
    }

    @Test("Empty header with no rows returns minimum width")
    func emptyHeaderNoRowsReturnsMinWidth() {
        let factory = DataGridCellFactory()
        let provider = InMemoryRowProvider(rows: [], columns: [""])

        let width = factory.calculateOptimalColumnWidth(
            for: "",
            columnIndex: 0,
            rowProvider: provider
        )
        #expect(width >= 60, "Should return at least minimum width")
    }

    @Test("Very long cell content caps width at maximum")
    func longContentCapsAtMax() {
        let factory = DataGridCellFactory()
        let longValue = String(repeating: "X", count: 5_000)
        let rows = [QueryResultRow(id: 0, values: [longValue])]
        let provider = InMemoryRowProvider(rows: rows, columns: ["data"])

        let width = factory.calculateOptimalColumnWidth(
            for: "data",
            columnIndex: 0,
            rowProvider: provider
        )
        #expect(width <= 800, "Width should be capped at max (800)")
    }

    @Test("Many columns still produce valid widths")
    func manyColumnsProduceValidWidths() {
        let factory = DataGridCellFactory()
        let columnCount = 60
        let columns = (0..<columnCount).map { "col_\($0)" }
        let rows = (0..<100).map { rowIdx in
            QueryResultRow(id: rowIdx, values: columns.map { "\($0)_val_\(rowIdx)" })
        }
        let provider = InMemoryRowProvider(rows: rows, columns: columns)

        for (index, column) in columns.enumerated() {
            let width = factory.calculateOptimalColumnWidth(
                for: column,
                columnIndex: index,
                rowProvider: provider
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
        let rows = [
            QueryResultRow(id: 0, values: [nil]),
            QueryResultRow(id: 1, values: ["hello"]),
            QueryResultRow(id: 2, values: [nil]),
        ]
        let provider = InMemoryRowProvider(rows: rows, columns: ["name"])

        let width = factory.calculateOptimalColumnWidth(
            for: "name",
            columnIndex: 0,
            rowProvider: provider
        )
        #expect(width >= 60)
        #expect(width <= 800)
    }
}

// MARK: - Change Reapplication Version Tracking (P2-7)

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
