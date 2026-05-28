//
//  FillColumnTests.swift
//  TableProTests
//
//  Locks Fill Column behaviour at two levels: the pure decisions (which loaded
//  rows a fill targets, how the dialog resolves NULL vs an empty string) and
//  the effect (applyFillColumn records one staged change per loaded row through
//  DataChangeManager, skipping deleted rows and read-only result sets).
//

import Foundation
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class NoopColumnLayoutPersister: ColumnLayoutPersisting {
    func load(for tableName: String, connectionId: UUID) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for tableName: String, connectionId: UUID) {}
    func clear(for tableName: String, connectionId: UUID) {}
}

@Suite("Fill Column")
@MainActor
struct FillColumnTests {
    private func makeCoordinator(
        columns: [String],
        rowCount: Int,
        isEditable: Bool = true,
        manager: DataChangeManager
    ) -> TableViewCoordinator {
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(manager),
            isEditable: isEditable,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: NoopColumnLayoutPersister()
        )
        let columnTypes: [ColumnType] = Array(repeating: .text(rawType: nil), count: columns.count)
        let rows = (0..<rowCount).map { i in (0..<columns.count).map { c in "r\(i)c\(c)" } }
        let tableRows = TableRows.from(
            queryRows: rows.map { row in row.map { PluginCellValue.text($0) } },
            columns: columns,
            columnTypes: columnTypes
        )
        coordinator.tableRowsProvider = { tableRows }
        coordinator.updateCache()
        return coordinator
    }

    // MARK: - Target selection

    @Test("Targets every loaded row when editable and none are deleted")
    func targetsAllLoadedRows() {
        let rows = TableViewCoordinator.fillTargetRows(
            rowCount: 5,
            isEditable: true,
            isRowDeleted: { _ in false }
        )
        #expect(rows == [0, 1, 2, 3, 4])
    }

    @Test("Excludes rows marked for deletion")
    func excludesDeletedRows() {
        let rows = TableViewCoordinator.fillTargetRows(
            rowCount: 5,
            isEditable: true,
            isRowDeleted: { $0 == 2 }
        )
        #expect(rows == [0, 1, 3, 4])
    }

    @Test("Targets nothing on a read-only result set")
    func noTargetsWhenReadOnly() {
        let rows = TableViewCoordinator.fillTargetRows(
            rowCount: 5,
            isEditable: false,
            isRowDeleted: { _ in false }
        )
        #expect(rows.isEmpty)
    }

    @Test("Targets nothing when no rows are loaded")
    func noTargetsWhenEmpty() {
        let rows = TableViewCoordinator.fillTargetRows(
            rowCount: 0,
            isEditable: true,
            isRowDeleted: { _ in false }
        )
        #expect(rows.isEmpty)
    }

    // MARK: - Value resolution

    @Test("Resolves NULL distinctly from an empty string")
    func resolvesNullDistinctFromEmpty() {
        #expect(TableViewCoordinator.fillColumnValue(text: "ignored", setNull: true) == .null)
        #expect(TableViewCoordinator.fillColumnValue(text: "", setNull: false) == .text(""))
        #expect(TableViewCoordinator.fillColumnValue(text: "active", setNull: false) == .text("active"))
    }

    @Test("Impact description reflects singular and plural counts")
    func impactDescriptionSingularAndPlural() {
        #expect(TableViewCoordinator.fillImpactDescription(rowCount: 1).contains("1 loaded row"))
        #expect(TableViewCoordinator.fillImpactDescription(rowCount: 42).contains("42 loaded rows"))
    }

    // MARK: - Apply (staged effect)

    @Test("Records one staged change per loaded row, leaving other columns untouched")
    func appliesToEveryLoadedRow() {
        let manager = DataChangeManager()
        let coordinator = makeCoordinator(columns: ["a", "b"], rowCount: 4, manager: manager)

        coordinator.applyFillColumn(columnIndex: 0, value: .text("X"))

        for row in 0..<4 {
            #expect(manager.pending.isCellModified(rowIndex: row, columnIndex: 0))
        }
        #expect(manager.pending.isCellModified(rowIndex: 0, columnIndex: 1) == false)
    }

    @Test("Does not touch rows marked for deletion")
    func skipsDeletedRowsOnApply() {
        let manager = DataChangeManager()
        let coordinator = makeCoordinator(columns: ["a"], rowCount: 4, manager: manager)
        manager.recordRowDeletion(rowIndex: 2, originalRow: [.text("r2c0")])

        coordinator.applyFillColumn(columnIndex: 0, value: .text("X"))

        #expect(manager.pending.isCellModified(rowIndex: 0, columnIndex: 0))
        #expect(manager.pending.isCellModified(rowIndex: 2, columnIndex: 0) == false)
    }

    @Test("Records nothing on a read-only result set")
    func recordsNothingWhenReadOnly() {
        let manager = DataChangeManager()
        let coordinator = makeCoordinator(columns: ["a"], rowCount: 4, isEditable: false, manager: manager)

        coordinator.applyFillColumn(columnIndex: 0, value: .text("X"))

        #expect(manager.hasChanges == false)
    }

    @Test("Writes NULL as a null change, not an empty string")
    func appliesNull() {
        let manager = DataChangeManager()
        let coordinator = makeCoordinator(columns: ["a"], rowCount: 2, manager: manager)

        coordinator.applyFillColumn(columnIndex: 0, value: .null)

        let change = manager.pending.change(forRow: 0, type: .update)
        #expect(change?.cellChanges.first?.newValue == .null)
    }

    @Test("Skips rows whose value already equals the fill value")
    func skipsRowsAlreadyEqual() {
        let manager = DataChangeManager()
        let coordinator = makeCoordinator(columns: ["a"], rowCount: 2, manager: manager)

        coordinator.applyFillColumn(columnIndex: 0, value: .text("r0c0"))

        #expect(manager.pending.isCellModified(rowIndex: 0, columnIndex: 0) == false)
        #expect(manager.pending.isCellModified(rowIndex: 1, columnIndex: 0))
    }
}
