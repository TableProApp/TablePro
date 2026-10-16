//
//  KeyHandlingTableViewSetValueTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class MenuBarSetValueLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@MainActor
private final class MenuBarSetValueRowStore {
    var tableRows: TableRows

    init(_ tableRows: TableRows) {
        self.tableRows = tableRows
    }
}

@MainActor
struct KeyHandlingTableViewSetValueTests {
    private static let id = 0
    private static let note = 1

    private struct SUT {
        let manager: DataChangeManager
        let coordinator: TableViewCoordinator
        let tableView: KeyHandlingTableView
        let store: MenuBarSetValueRowStore
    }

    /// Built through the column pool, so the focused positions are the ones the grid really has.
    private func makeSUT(isEditable: Bool = true) -> SUT {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "things",
            columns: ["id", "note"],
            primaryKeyColumns: ["id"],
            databaseType: .postgresql,
            generatedColumns: []
        )
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(manager),
            isEditable: isEditable,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: MenuBarSetValueLayoutPersister()
        )
        let store = MenuBarSetValueRowStore(TableRows.from(
            queryRows: [[.null, .text("a")], [.null, .text("b")]],
            columns: ["id", "note"],
            columnTypes: [.text(rawType: "uuid"), .text(rawType: "text")],
            columnNullable: ["id": false, "note": true]
        ))
        coordinator.tableRowsProvider = { store.tableRows }
        coordinator.tableRowsMutator = { mutation in mutation(&store.tableRows) }
        coordinator.databaseType = .postgresql
        coordinator.rebuildColumnMetadataCache(from: store.tableRows)
        coordinator.updateCache()

        let tableView = KeyHandlingTableView()
        tableView.coordinator = coordinator
        tableView.addTableColumn(DataGridView.makeRowNumberColumn())
        coordinator.tableView = tableView
        coordinator.columnPool.reconcile(
            tableView: tableView,
            schema: coordinator.identitySchema,
            columnTypes: [],
            savedLayout: nil,
            isEditable: isEditable,
            hiddenColumnNames: [],
            firstClickSortDirection: .ascending,
            widthCalculator: { _, _ in 100 }
        )
        return SUT(manager: manager, coordinator: coordinator, tableView: tableView, store: store)
    }

    private func focus(_ sut: SUT, row: Int, dataColumn: Int) {
        guard let identifier = sut.coordinator.identitySchema.identifier(for: dataColumn) else { return }
        sut.tableView.focusedRow = row
        sut.tableView.focusedColumn = sut.tableView.column(withIdentifier: identifier)
    }

    private func isEnabled(_ selector: Selector, in sut: SUT) -> Bool {
        sut.tableView.validateUserInterfaceItem(NSMenuItem(title: "", action: selector, keyEquivalent: ""))
    }

    private static let empty = #selector(SetValueCommandResponding.setValueEmpty(_:))
    private static let null = #selector(SetValueCommandResponding.setValueNull(_:))
    private static let defaultValue = #selector(SetValueCommandResponding.setValueDefault(_:))
    private static let uuidV4 = #selector(SetValueCommandResponding.generateUUIDv4(_:))
    private static let uuidV7 = #selector(SetValueCommandResponding.generateUUIDv7(_:))

    @Test("On the focused uuid key only the UUID items are enabled")
    func focusedUUIDKey() {
        let sut = makeSUT()
        focus(sut, row: 0, dataColumn: Self.id)

        #expect(isEnabled(Self.uuidV4, in: sut))
        #expect(isEnabled(Self.uuidV7, in: sut))
        #expect(!isEnabled(Self.null, in: sut))
        #expect(!isEnabled(Self.empty, in: sut))
        #expect(!isEnabled(Self.defaultValue, in: sut))
    }

    @Test("On a focused nullable text cell Empty and NULL are enabled and the UUIDs are not")
    func focusedTextCell() {
        let sut = makeSUT()
        focus(sut, row: 0, dataColumn: Self.note)

        #expect(isEnabled(Self.empty, in: sut))
        #expect(isEnabled(Self.null, in: sut))
        #expect(!isEnabled(Self.uuidV4, in: sut))
    }

    @Test("With no focused cell and no selection every item is dimmed")
    func nothingFocused() {
        let sut = makeSUT()

        for selector in [Self.empty, Self.null, Self.defaultValue, Self.uuidV4, Self.uuidV7] {
            #expect(!isEnabled(selector, in: sut))
        }
    }

    @Test("A read-only grid dims every item")
    func readOnlyGrid() {
        let sut = makeSUT(isEditable: false)
        focus(sut, row: 0, dataColumn: Self.note)

        #expect(!isEnabled(Self.null, in: sut))
        #expect(!isEnabled(Self.empty, in: sut))
    }

    @Test("A selection across both columns enables what either one takes, and writes each only where it fits")
    func selectionAcrossColumns() {
        let sut = makeSUT()
        sut.coordinator.selectionController.update(.single(
            GridRect(rows: 0...1, columns: 0...1),
            anchor: GridCoord(row: 0, displayColumn: 0),
            active: GridCoord(row: 1, displayColumn: 1)
        ))

        #expect(isEnabled(Self.uuidV4, in: sut))
        #expect(isEnabled(Self.null, in: sut))

        sut.tableView.generateUUIDv4(nil)

        let ids = (0..<2).compactMap { sut.store.tableRows.rows[$0].values[Self.id].asText }
        #expect(ids.count == 2)
        #expect(Set(ids).count == 2)
        #expect(ids.allSatisfy { UUID(uuidString: $0) != nil })
        #expect(sut.store.tableRows.rows[0].values[Self.note] == .text("a"))
        #expect(sut.store.tableRows.rows[1].values[Self.note] == .text("b"))
    }

    @Test("Set Value NULL from the menu bar writes the focused cell")
    func menuBarNullWritesFocusedCell() {
        let sut = makeSUT()
        focus(sut, row: 1, dataColumn: Self.note)

        sut.tableView.setValueNull(nil)

        #expect(sut.store.tableRows.rows[1].values[Self.note] == .null)
        #expect(sut.store.tableRows.rows[0].values[Self.note] == .text("a"))
    }
}
