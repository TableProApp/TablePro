//
//  StructureListGridAccessibilityTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class SpokenValueLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@Suite("Structure list cells speak what they mean", .serialized)
@MainActor
struct StructureListGridAccessibilityTests {
    private struct Grid {
        let window: NSWindow
        let coordinator: TableViewCoordinator
        let model: StructureListGridModel<String>
    }

    private func makeGrid(columns: [String], rows: [StructureListRow<String>]) -> Grid {
        let model = StructureListGridModel<String>()
        let tableRows = model.ensureLoaded(key: 1, columns: columns) { rows }
        let coordinator = TableViewCoordinator(
            changeManager: model.changeManager,
            isEditable: false,
            selectedRowIndices: .constant([]),
            delegate: model,
            layoutPersister: SpokenValueLayoutPersister()
        )
        coordinator.tableRowsProvider = { tableRows }
        coordinator.rebuildColumnMetadataCache(from: tableRows)
        coordinator.updateCache()

        let tableView = KeyHandlingTableView(frame: NSRect(x: 0, y: 0, width: 700, height: 200))
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
            columnTypes: Array(repeating: ColumnType.text(rawType: nil), count: columns.count),
            savedLayout: nil,
            isEditable: false,
            hiddenColumnNames: [],
            firstClickSortDirection: .ascending,
            widthCalculator: { _, _ in 100 }
        )
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 200))
        scrollView.documentView = tableView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        model.dataGridAttach(tableViewCoordinator: coordinator)
        tableView.reloadData()
        tableView.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        return Grid(window: window, coordinator: coordinator, model: model)
    }

    private func cell(in grid: Grid, row: Int, dataColumn: Int) throws -> DataGridCellAccessibilityView {
        let tableView = try #require(grid.coordinator.tableView)
        let column = try #require(grid.coordinator.tableColumnIndex(for: dataColumn))
        return try #require(
            tableView.view(atColumn: column, row: row, makeIfNecessary: true) as? DataGridCellAccessibilityView
        )
    }

    private func spoken(in grid: Grid, row: Int, dataColumn: Int) throws -> String? {
        try cell(in: grid, row: row, dataColumn: dataColumn).accessibilityValue() as? String
    }

    private func drawn(in grid: Grid, row: Int, dataColumn: Int) -> String? {
        grid.coordinator.cellAppearance(row: row, columnIndex: dataColumn, onEmphasizedSelection: false)?.text
    }

    @Test("The Enabled column draws YES and NO and reads Enabled and Disabled")
    func triggerEnabledIsSpoken() throws {
        DataGridAccessibility.isActive = true
        defer { DataGridAccessibility.isActive = false }
        let triggers = [
            TriggerInfo(name: "trg_on", timing: "BEFORE", event: "UPDATE", statement: "", enabled: true),
            TriggerInfo(name: "trg_off", timing: "AFTER", event: "INSERT", statement: "", enabled: false),
        ]
        let rows = triggers.map { trigger in
            StructureListRow(
                id: trigger.id,
                values: TriggerListColumns.values(for: trigger, showsEnabled: true),
                spokenValues: TriggerListColumns.spokenValues(for: trigger, showsEnabled: true)
            )
        }
        let grid = makeGrid(columns: TriggerListColumns.titles(showsEnabled: true), rows: rows)
        let enabled = TriggerListColumns.enabledColumn

        #expect(drawn(in: grid, row: 0, dataColumn: enabled) == "YES")
        #expect(drawn(in: grid, row: 1, dataColumn: enabled) == "NO")
        #expect(try spoken(in: grid, row: 0, dataColumn: enabled) == String(localized: "Enabled"))
        #expect(try spoken(in: grid, row: 1, dataColumn: enabled) == String(localized: "Disabled"))
        #expect(try cell(in: grid, row: 1, dataColumn: enabled).accessibilityLabel() == String(
            format: String(localized: "Row %d, column %d: %@"), 2, enabled + 1, String(localized: "Disabled")
        ))
        #expect(try spoken(in: grid, row: 0, dataColumn: TriggerListColumns.nameColumn) == "trg_on")
        withExtendedLifetime(grid) {}
    }

    @Test("The Active column draws YES and NO and reads Active and Inactive")
    func partActiveIsSpoken() throws {
        DataGridAccessibility.isActive = true
        defer { DataGridAccessibility.isActive = false }
        let parts = [true, false].map { active in
            ClickHousePartInfo(
                partition: "202601", name: "p", rows: 1, bytesOnDisk: 1, modificationTime: "", active: active
            )
        }
        let rows = parts.map { part in
            let row = ClickHousePartsView.gridRow(for: part)
            return StructureListRow(id: part.id.uuidString, values: row.values, spokenValues: row.spokenValues)
        }
        let grid = makeGrid(columns: ClickHousePartsView.columnTitles, rows: rows)
        let active = ClickHousePartsView.activeColumn

        #expect(drawn(in: grid, row: 0, dataColumn: active) == "YES")
        #expect(try spoken(in: grid, row: 0, dataColumn: active) == String(localized: "Active"))
        #expect(try spoken(in: grid, row: 1, dataColumn: active) == String(localized: "Inactive"))
        #expect(try spoken(in: grid, row: 0, dataColumn: 0) == "202601")
        withExtendedLifetime(grid) {}
    }

    @Test("A cell with no spoken value reads the text it draws")
    func unspokenCellReadsItsText() throws {
        DataGridAccessibility.isActive = true
        defer { DataGridAccessibility.isActive = false }
        let grid = makeGrid(
            columns: ["Name", "Unique"],
            rows: [StructureListRow(id: "idx", values: ["idx_name", "YES"])]
        )

        #expect(try spoken(in: grid, row: 0, dataColumn: 1) == "YES")
        #expect(grid.model.dataGridAccessibilityText(row: 0, column: 1) == nil)
        withExtendedLifetime(grid) {}
    }
}
