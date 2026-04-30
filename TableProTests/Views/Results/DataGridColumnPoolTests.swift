//
//  DataGridColumnPoolTests.swift
//  TableProTests
//

import AppKit
import Testing

@testable import TablePro

@Suite("DataGridColumnPool")
@MainActor
struct DataGridColumnPoolTests {
    private func makeTableView() -> NSTableView {
        let tableView = NSTableView()
        let rowNumberColumn = NSTableColumn(identifier: ColumnIdentitySchema.rowNumberIdentifier)
        rowNumberColumn.width = 40
        tableView.addTableColumn(rowNumberColumn)
        return tableView
    }

    private func makeColumnTypes(count: Int) -> [ColumnType] {
        Array(repeating: ColumnType.text(rawType: nil), count: count)
    }

    private func defaultWidthCalculator(name: String, slot: Int) -> CGFloat {
        100
    }

    private func dataColumns(in tableView: NSTableView) -> [NSTableColumn] {
        tableView.tableColumns.filter { $0.identifier != ColumnIdentitySchema.rowNumberIdentifier }
    }

    @Test("reconcile grows pool when column count exceeds capacity")
    func reconcile_growsPoolWhenColumnCountExceedsCapacity() {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()
        let schema = ColumnIdentitySchema(columns: ["id", "name", "email"])

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 3),
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )

        #expect(pool.totalSlots == 3)
        #expect(dataColumns(in: tableView).count == 3)
    }

    @Test("reconcile does not shrink pool when column count drops")
    func reconcile_doesNotShrinkPoolWhenColumnCountDrops() {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()

        pool.reconcile(
            tableView: tableView,
            schema: ColumnIdentitySchema(columns: ["a", "b", "c", "d"]),
            columnTypes: makeColumnTypes(count: 4),
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )
        #expect(pool.totalSlots == 4)

        pool.reconcile(
            tableView: tableView,
            schema: ColumnIdentitySchema(columns: ["a", "b"]),
            columnTypes: makeColumnTypes(count: 2),
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )

        #expect(pool.totalSlots == 4)
        let extras = dataColumns(in: tableView).filter { column in
            let identifier = column.identifier.rawValue
            return identifier == "dataColumn-2" || identifier == "dataColumn-3"
        }
        #expect(extras.count == 2)
        #expect(extras.allSatisfy { $0.isHidden })
    }

    @Test("reconcile attaches columns in natural order when no saved layout")
    func reconcile_attachesColumnsInNaturalOrderWithoutSavedLayout() {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()
        let schema = ColumnIdentitySchema(columns: ["id", "name", "email"])

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 3),
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )

        let identifiers = dataColumns(in: tableView).map(\.identifier.rawValue)
        #expect(identifiers == ["dataColumn-0", "dataColumn-1", "dataColumn-2"])
    }

    @Test("reconcile attaches columns in saved order on first call")
    func reconcile_attachesColumnsInSavedOrderOnFirstCall() {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()
        let schema = ColumnIdentitySchema(columns: ["id", "name", "email"])

        var layout = ColumnLayoutState()
        layout.columnOrder = ["email", "id", "name"]

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 3),
            savedLayout: layout,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )

        let identifiers = dataColumns(in: tableView).map(\.identifier.rawValue)
        #expect(identifiers == ["dataColumn-2", "dataColumn-0", "dataColumn-1"])
    }

    @Test("reconcile reorders existing columns when saved order differs from current")
    func reconcile_reordersExistingColumnsWhenSavedOrderDiffersFromCurrent() {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()
        let schema = ColumnIdentitySchema(columns: ["id", "name", "email"])

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 3),
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )

        var layout = ColumnLayoutState()
        layout.columnOrder = ["email", "id", "name"]

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 3),
            savedLayout: layout,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )

        let identifiers = dataColumns(in: tableView).map(\.identifier.rawValue)
        #expect(identifiers == ["dataColumn-2", "dataColumn-0", "dataColumn-1"])

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 3),
            savedLayout: layout,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )

        let afterSecond = dataColumns(in: tableView).map(\.identifier.rawValue)
        #expect(afterSecond == ["dataColumn-2", "dataColumn-0", "dataColumn-1"])
    }

    @Test("reconcile reuses the same NSTableColumn instances across calls")
    func reconcile_reusesSameTableColumnInstancesAcrossCalls() {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()
        let schema = ColumnIdentitySchema(columns: ["id", "name", "email"])

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 3),
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )

        let firstSnapshot = dataColumns(in: tableView)
        let capturedSlot1 = firstSnapshot[1]

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 3),
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )

        let afterSnapshot = dataColumns(in: tableView)
        #expect(afterSnapshot[1] === capturedSlot1)
        for (before, after) in zip(firstSnapshot, afterSnapshot) {
            #expect(before === after)
        }
    }

    @Test("reconcile honors hidden columns from saved layout")
    func reconcile_honorsHiddenColumnsFromSavedLayout() {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()
        let schema = ColumnIdentitySchema(columns: ["id", "name", "email"])

        var layout = ColumnLayoutState()
        layout.hiddenColumns = ["name"]

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 3),
            savedLayout: layout,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )

        let columns = dataColumns(in: tableView)
        let hiddenStateByName = Dictionary(uniqueKeysWithValues: columns.map { ($0.headerCell.stringValue, $0.isHidden) })
        #expect(hiddenStateByName["id"] == false)
        #expect(hiddenStateByName["name"] == true)
        #expect(hiddenStateByName["email"] == false)
    }

    @Test("reconcile honors hidden columns from hiddenColumnNames parameter")
    func reconcile_honorsHiddenColumnsFromParameter() {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()
        let schema = ColumnIdentitySchema(columns: ["id", "name", "email"])

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 3),
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: ["email"],
            widthCalculator: defaultWidthCalculator
        )

        let columns = dataColumns(in: tableView)
        let hiddenStateByName = Dictionary(uniqueKeysWithValues: columns.map { ($0.headerCell.stringValue, $0.isHidden) })
        #expect(hiddenStateByName["id"] == false)
        #expect(hiddenStateByName["name"] == false)
        #expect(hiddenStateByName["email"] == true)
    }

    @Test("Slot identifiers use dataColumn-N format")
    func reconcile_slotIdentifierFormatIsDataColumnN() {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()
        let schema = ColumnIdentitySchema(columns: ["id", "name", "email", "created"])

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 4),
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )

        let identifiers = dataColumns(in: tableView).map(\.identifier.rawValue).sorted()
        #expect(identifiers == ["dataColumn-0", "dataColumn-1", "dataColumn-2", "dataColumn-3"])
    }

    @Test("Column width comes from widthCalculator when no saved widths")
    func reconcile_widthFromCalculatorWhenNoSavedWidths() {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()
        let schema = ColumnIdentitySchema(columns: ["id", "name"])

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 2),
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: { name, _ in name == "id" ? 50 : 200 }
        )

        let widthsByName = Dictionary(uniqueKeysWithValues: dataColumns(in: tableView).map { ($0.headerCell.stringValue, $0.width) })
        #expect(widthsByName["id"] == 50)
        #expect(widthsByName["name"] == 200)
    }

    @Test("Column width comes from saved layout when present")
    func reconcile_widthFromSavedLayoutWhenPresent() {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()
        let schema = ColumnIdentitySchema(columns: ["id", "name"])

        var layout = ColumnLayoutState()
        layout.columnWidths = ["id": 75, "name": 250]

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 2),
            savedLayout: layout,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: { _, _ in 9999 }
        )

        let widthsByName = Dictionary(uniqueKeysWithValues: dataColumns(in: tableView).map { ($0.headerCell.stringValue, $0.width) })
        #expect(widthsByName["id"] == 75)
        #expect(widthsByName["name"] == 250)
    }

    @Test("reconcile is idempotent for equivalent inputs")
    func reconcile_isIdempotentForEquivalentInputs() {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()
        let schema = ColumnIdentitySchema(columns: ["id", "name", "email"])

        var layout = ColumnLayoutState()
        layout.columnOrder = ["name", "id", "email"]
        layout.columnWidths = ["id": 60, "name": 120, "email": 180]

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 3),
            savedLayout: layout,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )

        let beforeIdentifiers = tableView.tableColumns.map(\.identifier.rawValue)
        let beforeWidths = tableView.tableColumns.map(\.width)

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 3),
            savedLayout: layout,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )

        let afterIdentifiers = tableView.tableColumns.map(\.identifier.rawValue)
        let afterWidths = tableView.tableColumns.map(\.width)

        #expect(beforeIdentifiers == afterIdentifiers)
        #expect(beforeWidths == afterWidths)
    }

    @Test("detachFromTableView removes pool columns and allows clean re-attach")
    func detachFromTableView_removesPoolColumnsAndAllowsCleanReattach() {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()
        let schema = ColumnIdentitySchema(columns: ["id", "name", "email"])

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 3),
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )
        #expect(dataColumns(in: tableView).count == 3)

        pool.detachFromTableView()
        #expect(dataColumns(in: tableView).count == 0)
        #expect(pool.totalSlots == 3)

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 3),
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )
        #expect(dataColumns(in: tableView).count == 3)
        #expect(pool.totalSlots == 3)
    }
}
