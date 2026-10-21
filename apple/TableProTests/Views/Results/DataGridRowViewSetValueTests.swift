//
//  DataGridRowViewSetValueTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class SetValueMenuLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@MainActor
private final class SetValueMenuRowStore {
    var tableRows: TableRows

    init(_ tableRows: TableRows) {
        self.tableRows = tableRows
    }
}

@MainActor
struct DataGridRowViewSetValueTests {
    private struct Fixture {
        let manager: DataChangeManager
        let coordinator: TableViewCoordinator
        let store: SetValueMenuRowStore
    }

    private func makeFixture(
        columns: [String],
        columnTypes: [ColumnType],
        rows: [[PluginCellValue]],
        columnNullable: [String: Bool] = [:],
        columnDefaults: [String: String?] = [:],
        columnForeignKeys: [String: ForeignKeyInfo] = [:],
        databaseType: DatabaseType = .postgresql
    ) -> Fixture {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "t",
            columns: columns,
            primaryKeyColumns: [columns[0]],
            databaseType: databaseType,
            generatedColumns: []
        )
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(manager),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: SetValueMenuLayoutPersister()
        )
        let store = SetValueMenuRowStore(TableRows.from(
            queryRows: rows,
            columns: columns,
            columnTypes: columnTypes,
            columnDefaults: columnDefaults,
            columnForeignKeys: columnForeignKeys,
            columnNullable: columnNullable
        ))
        coordinator.tableRowsProvider = { store.tableRows }
        coordinator.tableRowsMutator = { mutation in mutation(&store.tableRows) }
        coordinator.databaseType = databaseType
        coordinator.updateCache()
        return Fixture(manager: manager, coordinator: coordinator, store: store)
    }

    private func setValueMenu(_ fixture: Fixture, row: Int = 0, column: Int) -> (DataGridRowView, NSMenu) {
        let rowView = DataGridRowView()
        rowView.coordinator = fixture.coordinator
        rowView.rowIndex = row
        let targets = fixture.coordinator.setValueTargets(clicked: SetValueTarget(displayRow: row, columnIndex: column))
        let menu = rowView.buildSetValueMenu(
            commands: fixture.coordinator.setValueCommands(for: targets),
            clickedColumn: column
        )
        return (rowView, menu)
    }

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
    }

    private func uuidKeyFixture() -> Fixture {
        makeFixture(
            columns: ["id", "name"],
            columnTypes: [.text(rawType: "uuid"), .text(rawType: "text")],
            rows: [[.null, .text("a")]],
            columnNullable: ["id": false, "name": true]
        )
    }

    @Test("A PostgreSQL uuid key, NOT NULL with no default, offers Generate UUID and Generate UUIDv7")
    func reportersUUIDKey() {
        let (_, menu) = setValueMenu(uuidKeyFixture(), column: 0)

        #expect(titles(menu) == ["Generate UUID", "Generate UUIDv7"])
    }

    @Test("A date column lists the engine's functions after the placeholders, behind a separator")
    func dateColumnFunctions() {
        let fixture = makeFixture(
            columns: ["id", "born"],
            columnTypes: [.integer(rawType: "INT"), .date(rawType: "DATE")],
            rows: [[.text("1"), .text("2024-01-01")]],
            columnNullable: ["born": true],
            databaseType: .mysql
        )

        let (_, menu) = setValueMenu(fixture, column: 1)

        #expect(titles(menu) == ["NULL", "-", "CURDATE()", "UTC_DATE()"])
    }

    @Test("A nullable uuid column with a default keeps NULL and Default apart from the UUIDs")
    func uuidWithDefaultGroups() {
        let fixture = makeFixture(
            columns: ["id", "ref"],
            columnTypes: [.integer(rawType: "int4"), .text(rawType: "uuid")],
            rows: [[.text("1"), .null]],
            columnNullable: ["ref": true],
            columnDefaults: ["ref": "gen_random_uuid()"]
        )

        let (_, menu) = setValueMenu(fixture, column: 1)

        #expect(titles(menu) == ["NULL", "Default", "-", "Generate UUID", "Generate UUIDv7"])
    }

    @Test("A uuid foreign key offers no new UUID, which would point at no row")
    func foreignKeyOffersNoUUID() {
        let fixture = makeFixture(
            columns: ["id", "owner"],
            columnTypes: [.integer(rawType: "int4"), .text(rawType: "uuid")],
            rows: [[.text("1"), .null]],
            columnNullable: ["owner": true],
            columnForeignKeys: [
                "owner": ForeignKeyInfo(name: "fk", column: "owner", referencedTable: "users", referencedColumn: "id")
            ]
        )

        let (_, menu) = setValueMenu(fixture, column: 1)

        #expect(titles(menu) == ["NULL"])
    }

    @Test("Choosing Generate UUID writes a new lowercase UUID into the clicked cell")
    func choosingGenerateUUIDWritesIt() throws {
        let fixture = uuidKeyFixture()
        let (rowView, menu) = setValueMenu(fixture, column: 0)
        let item = try #require(menu.items.first { $0.title == "Generate UUID" })
        let action = try #require(item.action)

        _ = rowView.perform(action, with: item)

        let staged = try #require(
            fixture.manager.pending.change(forRow: .existing(0), type: .update)?.cellChanges.first?.newValue.asText
        )
        #expect(staged == staged.lowercased())
        #expect(UUID(uuidString: staged) != nil)
        #expect(fixture.store.tableRows.rows[0].values[0] == .text(staged))
    }

    @Test("The cell's context menu carries Set Value on the reporter's uuid key")
    func contextMenuCarriesSetValue() throws {
        let fixture = uuidKeyFixture()
        let tableView = KeyHandlingTableView()
        tableView.coordinator = fixture.coordinator
        fixture.coordinator.tableView = tableView
        let rowView = DataGridRowView()
        rowView.coordinator = fixture.coordinator
        rowView.rowIndex = 0

        let menu = try #require(rowView.contextMenu(target: .cell(dataColumn: 0)))
        let setValue = try #require(menu.items.first { $0.title == "Set Value" }?.submenu)

        #expect(titles(setValue) == ["Generate UUID", "Generate UUIDv7", "-", "Set Cells to Value…"])
    }

    @Test("A NOT NULL number with no default still offers Set Cells to Value, alone")
    func typedValueIsTheOnlyItemOnANotNullNumber() throws {
        let fixture = makeFixture(
            columns: ["id", "qty"],
            columnTypes: [.integer(rawType: "int4"), .integer(rawType: "int4")],
            rows: [[.text("1"), .text("5")]],
            columnNullable: ["id": false, "qty": false]
        )
        let tableView = KeyHandlingTableView()
        tableView.coordinator = fixture.coordinator
        fixture.coordinator.tableView = tableView
        let rowView = DataGridRowView()
        rowView.coordinator = fixture.coordinator
        rowView.rowIndex = 0

        let menu = try #require(rowView.contextMenu(target: .cell(dataColumn: 1)))
        let setValue = try #require(menu.items.first { $0.title == "Set Value" }?.submenu)

        #expect(titles(setValue) == ["Set Cells to Value…"])
    }

    @Test("A read-only grid has no Set Value at all")
    func readOnlyGridOffersNothing() {
        let fixture = uuidKeyFixture()
        fixture.coordinator.isEditable = false

        let (_, menu) = setValueMenu(fixture, column: 1)

        #expect(menu.items.isEmpty)
    }
}
