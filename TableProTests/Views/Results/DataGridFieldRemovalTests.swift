//
//  DataGridFieldRemovalTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class NoopFieldRemovalLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

private final class FieldRemovalClipboard: ClipboardProvider {
    var written: GridRowsClipboardPayload?

    func readText() -> String? { nil }
    func readGridRows() -> GridRowsClipboardPayload? { nil }
    func writeText(_ text: String) {}
    func writeCsv(_ csv: String) {}
    func writeImage(_ image: NSImage) {}
    func writeRows(tsv: String, html: String?, gridRows: GridRowsClipboardPayload) { written = gridRows }
    var hasText: Bool { false }
    var hasGridRows: Bool { written != nil }
}

@MainActor
private final class FieldRemovalRowStore {
    var tableRows: TableRows

    init(_ tableRows: TableRows) {
        self.tableRows = tableRows
    }
}

@MainActor
struct DataGridFieldRemovalTests {
    private static let columns = ["_id", "nick", "deletedAt"]

    private func makeGrid(
        _ databaseType: DatabaseType = .mongodb
    ) -> (TableViewCoordinator, FieldRemovalRowStore, DataChangeManager) {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "items",
            columns: Self.columns,
            primaryKeyColumns: ["_id"],
            databaseType: databaseType,
            generatedColumns: []
        )
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(manager),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: NoopFieldRemovalLayoutPersister()
        )
        coordinator.databaseType = databaseType
        let store = FieldRemovalRowStore(TableRows.from(
            queryRows: [["1", "Ada", .null]],
            columns: Self.columns,
            columnTypes: Array(repeating: .text(rawType: nil), count: Self.columns.count),
            absentCells: [0: [2]]
        ))
        coordinator.tableRowsProvider = { store.tableRows }
        coordinator.tableRowsMutator = { mutation in mutation(&store.tableRows) }
        coordinator.updateCache()
        return (coordinator, store, manager)
    }

    @Test("A missing field reads No Field, not NULL")
    func missingFieldIsNamed() {
        let (coordinator, _, _) = makeGrid()

        #expect(coordinator.accessibilityText(row: 0, columnIndex: 2) == "No Field")
        #expect(DataGridCellContent.placeholder(for: .null, isAbsent: true) == .absent)
        #expect(DataGridCellContent.placeholder(for: .null) == .null)
    }

    @Test("Remove Field takes the field out of the row and stages the removal")
    func removeFieldStagesTheRemoval() throws {
        let (coordinator, store, manager) = makeGrid()

        coordinator.removeField(row: 0, columnIndex: 1)

        #expect(store.tableRows.isAbsent(row: 0, column: 1))
        let cell = try #require(manager.changes.first?.cellChanges.first)
        #expect(cell.oldValue == "Ada" && !cell.oldIsAbsent)
        #expect(cell.newIsAbsent)
        #expect(coordinator.accessibilityText(row: 0, columnIndex: 1) == "No Field")
    }

    @Test("Set NULL on a missing field puts the field back holding null")
    func nullOverMissingFieldIsAnEdit() throws {
        let (coordinator, store, manager) = makeGrid()

        coordinator.commitCellEdit(row: 0, columnIndex: 2, newValue: nil)

        #expect(!store.tableRows.isAbsent(row: 0, column: 2))
        let change = try #require(manager.changes.first)
        #expect(change.absentColumns == [2])
        let cell = try #require(change.cellChanges.first)
        #expect(cell.oldIsAbsent && !cell.newIsAbsent)
        #expect(cell.newValue == .null)
        #expect(coordinator.accessibilityText(row: 0, columnIndex: 2) == "NULL")
    }

    @Test("Copy with Headers records which fields each copied row lacked")
    func copyWithHeadersCarriesAbsence() throws {
        let (coordinator, _, _) = makeGrid()
        let clipboard = FieldRemovalClipboard()
        ClipboardService.shared = clipboard
        defer { ClipboardService.shared = NSPasteboardClipboardProvider() }

        coordinator.copyRowsWithHeaders(at: [0])

        let payload = try #require(clipboard.written)
        #expect(payload.columns == Self.columns)
        #expect(payload.rows == [["1", "Ada", .null]])
        #expect(payload.absentCells == [0: [2]])
    }

    @Test("An engine that cannot tell a missing field from NULL offers no removal")
    func removalNeedsTheCapability() {
        let (coordinator, store, manager) = makeGrid(.mysql)

        coordinator.removeField(row: 0, columnIndex: 1)

        #expect(!coordinator.supportsFieldRemoval)
        #expect(!store.tableRows.isAbsent(row: 0, column: 1))
        #expect(!manager.hasChanges)
    }
}
