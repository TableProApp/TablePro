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
        coordinator.applyFullReplace()
        coordinator.recomputeValueFilteredIDs()
        coordinator.updateCache()

        #expect(coordinator.valueFilteredIDs == nil)
        #expect(!coordinator.valueFilterState.isActive)
    }

    @Test("Changing binary display format preserves the filtered rows")
    func binaryDisplayFormatRemapsSelectedValues() {
        let first = Data([
            0xAF, 0x49, 0x45, 0x3B, 0x7F, 0x2F, 0xFB, 0x58,
            0xFC, 0xD3, 0x2B, 0xD3, 0x99, 0x59, 0x9F, 0xA5,
        ])
        let second = Data(repeating: 0xBB, count: 16)
        let tableRows = TableRows(
            rows: [
                Row(id: .existing(0), values: [.bytes(first)]),
                Row(id: .existing(1), values: [.bytes(second)]),
            ],
            columns: ["id"],
            columnTypes: [.blob(rawType: "BYTEA")]
        )
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: FakeValueFilterPersister()
        )
        coordinator.tableRowsProvider = { tableRows }
        coordinator.updateDisplayFormats([nil])
        coordinator.updateCache()
        coordinator.applyValueFilter(
            ColumnValueFilter(
                selectedValues: ["0xAF49453B7F2FFB58FCD32BD399599FA5"],
                includesNull: false
            ),
            columnName: "id",
            forColumn: 0
        )

        #expect(coordinator.updateDisplayFormats([.uuid]))
        coordinator.recomputeValueFilteredIDs()

        #expect(coordinator.valueFilteredIDs == [.existing(0)])
        #expect(
            coordinator.valueFilterState.filter(forColumn: 0)?.selectedValues
                == ["af49453b-7f2f-fb58-fcd3-2bd399599fa5"]
        )

        #expect(coordinator.updateDisplayFormats([.raw]))
        coordinator.recomputeValueFilteredIDs()
        #expect(coordinator.valueFilteredIDs == [.existing(0)])
        #expect(
            coordinator.valueFilterState.filter(forColumn: 0)?.selectedValues
                == ["0xAF49453B7F2FFB58FCD32BD399599FA5"]
        )
    }

    @Test("Changing result sets does not discard unmatched filter selections")
    func displayFormatRemapPreservesSelectionsMissingFromCurrentRows() {
        let first = Data(repeating: 0xAA, count: 16)
        let second = Data(repeating: 0xBB, count: 16)
        let firstResult = TableRows(
            rows: [Row(id: .existing(0), values: [.bytes(first)])],
            columns: ["id"],
            columnTypes: [.blob(rawType: "BYTEA")]
        )
        let secondResult = TableRows(
            rows: [Row(id: .existing(1), values: [.bytes(second)])],
            columns: ["id"],
            columnTypes: [.blob(rawType: "BYTEA")]
        )
        var currentRows = firstResult
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: FakeValueFilterPersister()
        )
        coordinator.tableRowsProvider = { currentRows }
        coordinator.updateDisplayFormats([.raw])
        coordinator.applyValueFilter(
            ColumnValueFilter(
                selectedValues: ["0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"],
                includesNull: false
            ),
            columnName: "id",
            forColumn: 0
        )

        currentRows = secondResult
        coordinator.updateDisplayFormats([.uuid])
        coordinator.recomputeValueFilteredIDs()
        #expect(coordinator.valueFilteredIDs?.isEmpty == true)

        currentRows = firstResult
        coordinator.updateDisplayFormats([.raw])
        coordinator.recomputeValueFilteredIDs()

        #expect(coordinator.valueFilteredIDs == [.existing(0)])
        #expect(
            coordinator.valueFilterState.filter(forColumn: 0)?.selectedValues
                == ["0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"]
        )
    }

    @Test("Display format changes do not migrate filters to a renamed column")
    func displayFormatRemapPrunesRenamedColumns() {
        let bytes = Data(repeating: 0xAA, count: 16)
        var currentRows = TableRows(
            rows: [Row(id: .existing(0), values: [.bytes(bytes)])],
            columns: ["old_id"],
            columnTypes: [.blob(rawType: "BYTEA")]
        )
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: FakeValueFilterPersister()
        )
        coordinator.tableRowsProvider = { currentRows }
        coordinator.updateDisplayFormats([.raw])
        coordinator.applyValueFilter(
            ColumnValueFilter(
                selectedValues: ["0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"],
                includesNull: false
            ),
            columnName: "old_id",
            forColumn: 0
        )

        currentRows = TableRows(
            rows: [Row(id: .existing(0), values: [.bytes(bytes)])],
            columns: ["new_id"],
            columnTypes: [.blob(rawType: "BYTEA")]
        )
        #expect(coordinator.updateDisplayFormats([.uuid]))

        #expect(!coordinator.valueFilterState.isActive)
    }

    @Test("Display format remapping is independent of row order")
    func displayFormatRemapHandlesOverlappingOldAndNewValues() {
        let oldFirst = ValueDisplayFormatService.applyFormat("1000000", format: .unixTimestamp)
        let oldSecond = ValueDisplayFormatService.applyFormat("1000", format: .unixTimestamp)
        let newFirst = ValueDisplayFormatService.applyFormat("1000000", format: .unixTimestampMillis)
        let newSecond = ValueDisplayFormatService.applyFormat("1000", format: .unixTimestampMillis)
        #expect(newFirst == oldSecond)

        let tableRows = TableRows(
            rows: [
                Row(id: .existing(0), values: [.text("1000000")]),
                Row(id: .existing(1), values: [.text("1000")]),
            ],
            columns: ["created_at"],
            columnTypes: [.integer(rawType: "BIGINT")]
        )
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: FakeValueFilterPersister()
        )
        coordinator.tableRowsProvider = { tableRows }
        coordinator.updateDisplayFormats([.unixTimestamp])
        coordinator.applyValueFilter(
            ColumnValueFilter(selectedValues: [oldFirst, oldSecond], includesNull: false),
            columnName: "created_at",
            forColumn: 0
        )

        coordinator.updateDisplayFormats([.unixTimestampMillis])
        coordinator.recomputeValueFilteredIDs()

        #expect(coordinator.valueFilteredIDs == [.existing(0), .existing(1)])
        #expect(
            coordinator.valueFilterState.filter(forColumn: 0)?.selectedValues
                == [newFirst, newSecond]
        )
    }

    @Test("A format change that moves no selected value keeps the grid selection")
    func displayFormatRemapReportsNoChangeWhenSelectionIsUnaffected() {
        let loaded = Data(repeating: 0xCC, count: 16)
        let tableRows = TableRows(
            rows: [Row(id: .existing(0), values: [.bytes(loaded)])],
            columns: ["id"],
            columnTypes: [.blob(rawType: "BYTEA")]
        )
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: FakeValueFilterPersister()
        )
        coordinator.tableRowsProvider = { tableRows }
        coordinator.updateDisplayFormats([.raw])
        let selection: Set<String> = ["0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"]
        coordinator.applyValueFilter(
            ColumnValueFilter(selectedValues: selection, includesNull: false),
            columnName: "id",
            forColumn: 0
        )

        #expect(!coordinator.updateDisplayFormats([.uuid]))
        #expect(coordinator.valueFilterState.filter(forColumn: 0)?.selectedValues == selection)
    }

    @Test("The inspector ignores grid formats left over from another tab")
    func activeFormatsRequireMatchingColumns() {
        let tableRows = TableRows(
            rows: [Row(id: .existing(0), values: [.bytes(Data(repeating: 0xAA, count: 16))])],
            columns: ["id"],
            columnTypes: [.blob(rawType: "BYTEA")]
        )
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: FakeValueFilterPersister()
        )
        coordinator.tableRowsProvider = { tableRows }
        coordinator.updateDisplayFormats([.uuid])

        #expect(
            InspectorValueDisplayFormatResolver.activeFormats(
                from: coordinator,
                matching: ["id"]
            ) == [.uuid]
        )
        #expect(
            InspectorValueDisplayFormatResolver.activeFormats(
                from: coordinator,
                matching: ["payload"]
            ) == nil
        )
        #expect(InspectorValueDisplayFormatResolver.activeFormats(from: nil, matching: ["id"]) == nil)
    }
}

@MainActor
private final class FakeValueFilterPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }

    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}

    func clear(for key: ColumnLayoutTableKey) {}
}
