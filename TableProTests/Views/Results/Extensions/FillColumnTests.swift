//
//  FillColumnTests.swift
//  TableProTests
//
//  Locks the Fill Column decision logic: which loaded rows a fill targets
//  (editable guard, deleted-row skipping, empty result) and how the dialog
//  resolves NULL distinctly from an empty string. The apply loop itself
//  reuses commitTypedCellEdit, which the cell-edit and paste paths exercise.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Fill Column")
@MainActor
struct FillColumnTests {
    @Test("Fills every loaded row when editable and none are deleted")
    func fillsAllLoadedRows() {
        let rows = TableViewCoordinator.fillTargetRows(
            rowCount: 5,
            isEditable: true,
            isRowDeleted: { _ in false }
        )
        #expect(rows == [0, 1, 2, 3, 4])
    }

    @Test("Skips rows marked for deletion")
    func skipsDeletedRows() {
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
}
