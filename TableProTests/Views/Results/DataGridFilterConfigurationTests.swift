//
//  DataGridFilterConfigurationTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class FilterConfigurationLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@Suite("Data grid filter configuration", .serialized)
@MainActor
struct DataGridFilterConfigurationTests {
    private static let textType = ColumnType.text(rawType: "TEXT")

    private func makeCoordinator(columns: [String], values: [String]) -> TableViewCoordinator {
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: false,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: FilterConfigurationLayoutPersister()
        )
        let tableRows = TableRows.from(
            queryRows: [values.map { PluginCellValue.text($0) }],
            columns: columns,
            columnTypes: Array(repeating: Self.textType, count: columns.count)
        )
        coordinator.tableRowsProvider = { tableRows }
        coordinator.rebuildColumnMetadataCache(from: tableRows)
        coordinator.updateCache()
        return coordinator
    }

    private func attachTableView(to coordinator: TableViewCoordinator, columnCount: Int) {
        let tableView = KeyHandlingTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        tableView.coordinator = coordinator
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        tableView.addTableColumn(DataGridView.makeRowNumberColumn())
        coordinator.tableView = tableView
        coordinator.columnPool.reconcile(
            tableView: tableView,
            schema: coordinator.identitySchema,
            columnTypes: Array(repeating: Self.textType, count: columnCount),
            savedLayout: nil,
            isEditable: false,
            hiddenColumnNames: [],
            firstClickSortDirection: .ascending,
            widthCalculator: { _, _ in 90 }
        )
    }

    private func headerMenuActions(_ coordinator: TableViewCoordinator) throws -> [Selector] {
        let tableView = try #require(coordinator.tableView)
        let dataColumn = try #require(tableView.tableColumns.firstIndex { coordinator.dataColumnIndex(from: $0.identifier) == 0 })
        let menu = NSMenu()
        coordinator.populateHeaderMenu(menu, forColumnAt: dataColumn)
        return menu.items.compactMap(\.action)
    }

    @Test("Every grid offers value filters unless it says otherwise")
    func valueFilterDefaultsOn() {
        #expect(DataGridConfiguration().supportsValueFilter)
        #expect(DataGridConfiguration().filterMenuColumnTypes == nil)
    }

    @Test("Applying a configuration carries the value filter flag and the filter menu types")
    func applyCarriesFilterSettings() {
        let coordinator = makeCoordinator(columns: ["id"], values: ["1"])
        var configuration = DataGridConfiguration()
        configuration.supportsValueFilter = false
        configuration.filterMenuColumnTypes = [.integer(rawType: "INTEGER")]

        coordinator.apply(configuration: configuration, isEditable: false)

        #expect(!coordinator.supportsValueFilter)
        #expect(coordinator.filterMenuColumnTypes == [.integer(rawType: "INTEGER")])
    }

    @Test("Turning value filters off removes Filter Values and keeps the other column commands")
    func valueFilterOffKeepsColumnCommands() throws {
        let coordinator = makeCoordinator(columns: ["id", "name"], values: ["1", "a"])
        coordinator.supportsValueFilter = false
        attachTableView(to: coordinator, columnCount: 2)

        let actions = try headerMenuActions(coordinator)

        #expect(!actions.contains(#selector(TableViewCoordinator.filterColumnValues(_:))))
        #expect(actions.contains(#selector(TableViewCoordinator.filterWithColumn(_:))))
        #expect(actions.contains(#selector(TableViewCoordinator.hideColumn(_:))))
    }

    @Test("Value filters answer to their own flag, not to the column commands")
    func valueFilterIndependentOfColumnCommands() throws {
        let coordinator = makeCoordinator(columns: ["id", "name"], values: ["1", "a"])
        coordinator.supportsColumnCommands = false
        attachTableView(to: coordinator, columnCount: 2)

        let actions = try headerMenuActions(coordinator)

        #expect(actions.contains(#selector(TableViewCoordinator.filterColumnValues(_:))))
        #expect(!actions.contains(#selector(TableViewCoordinator.hideColumn(_:))))
        #expect(!actions.contains(#selector(TableViewCoordinator.filterWithColumn(_:))))
    }

    @Test("A default grid offers both")
    func defaultGridOffersBoth() throws {
        let coordinator = makeCoordinator(columns: ["id", "name"], values: ["1", "a"])
        attachTableView(to: coordinator, columnCount: 2)

        let actions = try headerMenuActions(coordinator)

        #expect(actions.contains(#selector(TableViewCoordinator.filterColumnValues(_:))))
        #expect(actions.contains(#selector(TableViewCoordinator.hideColumn(_:))))
    }

    @Test("The cell Filter menu reads the grid's own column types by default")
    func cellFilterMenuUsesGridTypesByDefault() throws {
        let coordinator = makeCoordinator(columns: ["total"], values: ["42"])

        let item = try #require(coordinator.cellFilterMenuItem(forRow: 0, dataColumn: 0) { _ in })

        #expect(item.submenu?.items.count == 2)
    }

    @Test("A host can type the cell Filter menu apart from the types the grid edits with")
    func cellFilterMenuUsesHostTypes() throws {
        let coordinator = makeCoordinator(columns: ["total"], values: ["42"])
        coordinator.filterMenuColumnTypes = [.integer(rawType: "INTEGER")]
        var applied: [TableFilter] = []

        let item = try #require(coordinator.cellFilterMenuItem(forRow: 0, dataColumn: 0) { applied.append($0) })
        let submenu = try #require(item.submenu)

        submenu.performActionForItem(at: 2)

        #expect(submenu.items.count == 4)
        #expect(applied.map(\.filterOperator) == [.greaterThan])
        #expect(applied.first?.value == "42")
    }

    @Test("A column the host gave no type for falls back to none")
    func cellFilterMenuTypeOutOfRange() {
        let coordinator = makeCoordinator(columns: ["a", "b"], values: ["1", "2"])
        coordinator.filterMenuColumnTypes = [.integer(rawType: "INTEGER")]
        let tableRows = coordinator.tableRowsProvider()

        #expect(coordinator.filterMenuColumnType(forDataColumn: 0, in: tableRows) == .integer(rawType: "INTEGER"))
        #expect(coordinator.filterMenuColumnType(forDataColumn: 1, in: tableRows) == nil)
        #expect(coordinator.cellFilterMenuItem(forRow: 0, dataColumn: 1) { _ in } == nil)
    }
}
