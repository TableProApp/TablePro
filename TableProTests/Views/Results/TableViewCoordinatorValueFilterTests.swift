//
//  TableViewCoordinatorValueFilterTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("TableViewCoordinator value filter")
@MainActor
struct TableViewCoordinatorValueFilterTests {
    private func makeCoordinator() -> TableViewCoordinator {
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: FakeValueFilterPersister()
        )
        let rows: ContiguousArray<Row> = [
            Row(id: .existing(0), values: [.text("active"), .text("a")]),
            Row(id: .existing(1), values: [.text("inactive"), .text("b")]),
            Row(id: .existing(2), values: [.text("active"), .text("c")]),
            Row(id: .existing(3), values: [.null, .text("d")]),
        ]
        var captured = TableRows(
            rows: rows,
            columns: ["status", "name"],
            columnTypes: [.text(rawType: nil), .text(rawType: nil)]
        )
        coordinator.tableRowsProvider = { captured }
        coordinator.tableRowsMutator = { mutation in mutation(&captured) }
        coordinator.updateCache()
        return coordinator
    }

    @Test("distinctValues groups values with counts and a null bucket")
    func distinctValuesGroupsWithCounts() {
        let coordinator = makeCoordinator()
        let values = coordinator.distinctValues(forColumn: 0)

        #expect(values.count == 3)
        #expect(values.first?.isNull == true)
        #expect(values.first?.count == 1)
        let active = values.first { $0.display == "active" }
        let inactive = values.first { $0.display == "inactive" }
        #expect(active?.count == 2)
        #expect(inactive?.count == 1)
    }

    @Test("applying a value filter narrows the display set")
    func applyingFilterNarrowsRows() {
        let coordinator = makeCoordinator()

        coordinator.applyValueFilter(
            ColumnValueFilter(selectedValues: ["active"], includesNull: false),
            columnName: "status",
            forColumn: 0
        )

        #expect(coordinator.valueFilteredIDs == [.existing(0), .existing(2)])
        #expect(coordinator.cachedRowCount == 2)
        #expect(coordinator.displayRow(at: 0)?.id == .existing(0))
        #expect(coordinator.displayRow(at: 1)?.id == .existing(2))
        #expect(coordinator.tableRowsIndex(forDisplayRow: 1) == 2)
    }

    @Test("numberOfRows serves the filtered count")
    func numberOfRowsServesFilteredCount() {
        let coordinator = makeCoordinator()
        let tableView = NSTableView()

        coordinator.applyValueFilter(
            ColumnValueFilter(selectedValues: ["active"], includesNull: false),
            columnName: "status",
            forColumn: 0
        )

        #expect(coordinator.numberOfRows(in: tableView) == 2)
    }

    @Test("multiple column filters intersect")
    func multipleColumnFiltersIntersect() {
        let coordinator = makeCoordinator()

        coordinator.applyValueFilter(
            ColumnValueFilter(selectedValues: ["active"], includesNull: false),
            columnName: "status",
            forColumn: 0
        )
        coordinator.applyValueFilter(
            ColumnValueFilter(selectedValues: ["c"], includesNull: false),
            columnName: "name",
            forColumn: 1
        )

        #expect(coordinator.valueFilteredIDs == [.existing(2)])
        #expect(coordinator.cachedRowCount == 1)
    }

    @Test("null selection matches only null rows")
    func nullSelectionMatchesNullRows() {
        let coordinator = makeCoordinator()

        coordinator.applyValueFilter(
            ColumnValueFilter(selectedValues: [], includesNull: true),
            columnName: "status",
            forColumn: 0
        )

        #expect(coordinator.valueFilteredIDs == [.existing(3)])
    }

    @Test("clearing one filter recomputes the remaining intersection")
    func clearingOneFilterRecomputes() {
        let coordinator = makeCoordinator()
        coordinator.applyValueFilter(
            ColumnValueFilter(selectedValues: ["active"], includesNull: false),
            columnName: "status",
            forColumn: 0
        )
        coordinator.applyValueFilter(
            ColumnValueFilter(selectedValues: ["c"], includesNull: false),
            columnName: "name",
            forColumn: 1
        )

        coordinator.applyValueFilter(nil, columnName: "name", forColumn: 1)

        #expect(coordinator.valueFilteredIDs == [.existing(0), .existing(2)])
    }

    @Test("clearAllValueFilters restores every loaded row")
    func clearAllRestoresRows() {
        let coordinator = makeCoordinator()
        coordinator.applyValueFilter(
            ColumnValueFilter(selectedValues: ["active"], includesNull: false),
            columnName: "status",
            forColumn: 0
        )

        coordinator.clearAllValueFilters()

        #expect(coordinator.valueFilteredIDs == nil)
        #expect(coordinator.cachedRowCount == 4)
    }

    @Test("inserted rows stay visible while a filter is active")
    func insertedRowsStayVisible() {
        let coordinator = makeCoordinator()
        coordinator.applyValueFilter(
            ColumnValueFilter(selectedValues: ["active"], includesNull: false),
            columnName: "status",
            forColumn: 0
        )

        coordinator.tableRowsMutator { rows in
            _ = rows.appendInsertedRow(values: [.text("inactive"), .text("z")])
        }
        coordinator.recomputeValueFilteredIDs()
        coordinator.updateCache()

        #expect(coordinator.valueFilteredIDs?.count == 3)
        #expect(coordinator.valueFilteredIDs?.last?.isInserted == true)
    }

    @Test("a column set change prunes stale filters on full replace")
    func fullReplacePrunesStaleFilters() {
        let coordinator = makeCoordinator()
        coordinator.applyValueFilter(
            ColumnValueFilter(selectedValues: ["active"], includesNull: false),
            columnName: "status",
            forColumn: 0
        )

        coordinator.tableRowsMutator { rows in
            rows.columns = ["other", "name"]
        }
        coordinator.recomputeValueFilteredIDs()
        coordinator.updateCache()

        #expect(coordinator.valueFilteredIDs == nil)
        #expect(!coordinator.valueFilterState.isActive)
    }
}

@MainActor
private final class FakeValueFilterPersister: ColumnLayoutPersisting {
    func load(for tableName: String, connectionId: UUID) -> ColumnLayoutState? { nil }

    func save(_ layout: ColumnLayoutState, for tableName: String, connectionId: UUID) {}

    func clear(for tableName: String, connectionId: UUID) {}
}
