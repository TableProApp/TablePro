//
//  MultiRowEditStateFieldAbsenceTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct MultiRowEditStateFieldAbsenceTests {
    private let rowA = RowID.existing(0)
    private let rowB = RowID.existing(1)

    private func configured(rows: [[String?]], absentCells: [Set<Int>], modified: Set<Int> = []) -> MultiRowEditState {
        let state = MultiRowEditState()
        state.configure(
            selectedRowIndices: Set(rows.indices),
            rowIDs: Array([rowA, rowB].prefix(rows.count)),
            allRows: rows,
            absentCells: absentCells,
            columns: ["_id", "nick"],
            columnTypes: [.text(rawType: nil), .text(rawType: nil)],
            externallyModifiedColumns: modified
        )
        return state
    }

    @Test("A field no selected row has reads No Field, and one they disagree on reads as multiple values")
    func missingFieldHasItsOwnState() {
        let missing = configured(rows: [["1", nil]], absentCells: [[1]])
        #expect(FieldValueState.resolve(missing.fields[1]) == .absent)
        #expect(FieldValueState.resolve(missing.fields[1]).placeholder == "No Field")

        let null = configured(rows: [["1", nil]], absentCells: [[]])
        #expect(FieldValueState.resolve(null.fields[1]) == .null)

        let mixed = configured(rows: [["1", nil], ["2", nil]], absentCells: [[1], []])
        #expect(FieldValueState.resolve(mixed.fields[1]) == .multipleValues)
    }

    @Test("Remove Field asks for the field to go from every selected row")
    func removeFieldReportsTheRows() {
        let state = configured(rows: [["1", "Ada"], ["2", "Bo"]], absentCells: [[], []])
        var removed: (Int, [RowID])?
        state.onFieldRemoved = { removed = ($0, $1) }

        state.removeField(at: 1)

        #expect(removed?.0 == 1)
        #expect(removed?.1 == [rowA, rowB])
        #expect(FieldValueState.resolve(state.fields[1]) == .pendingRemoval)
        #expect(state.fields[1].hasEdit)
    }

    @Test("A field the grid removed shows as a pending removal rather than an empty value")
    func externallyRemovedFieldIsPendingRemoval() {
        let state = configured(rows: [["1", nil]], absentCells: [[1]], modified: [1])

        #expect(FieldValueState.resolve(state.fields[1]) == .pendingRemoval)
    }

    @Test("Removing a field no selected row had, after typing into it, leaves nothing pending")
    func removalBackToMissingIsNoEdit() {
        let state = configured(rows: [["1", nil]], absentCells: [[1]])
        var removed: [RowID]?
        state.onFieldChanged = { _, _, _ in }
        state.onFieldRemoved = { removed = $1 }

        state.updateField(at: 1, value: "Ada")
        state.removeField(at: 1)

        #expect(removed == [rowA])
        #expect(!state.hasEdits)
        #expect(FieldValueState.resolve(state.fields[1]) == .absent)
        #expect(state.getEditedFields().isEmpty)
    }

    @Test("Removing a field only some selected rows had is still a pending removal")
    func removalOnMixedRowsIsPending() {
        let state = configured(rows: [["1", nil], ["2", "Bo"]], absentCells: [[1], []])
        state.onFieldRemoved = { _, _ in }

        state.removeField(at: 1)

        #expect(state.hasEdits)
        #expect(FieldValueState.resolve(state.fields[1]) == .pendingRemoval)
    }

    @Test("A pending removal reaches the save as a removal, not as NULL")
    func editedFieldsCarryRemoval() {
        let state = configured(rows: [["1", "Ada"]], absentCells: [[]])
        state.onFieldRemoved = { _, _ in }

        state.removeField(at: 1)

        #expect(state.getEditedFields() == [
            InspectorFieldEdit(columnIndex: 1, columnName: "nick", newValue: nil, removesField: true)
        ])
    }

    @Test("Clearing a value typed into a missing field puts the field back to missing")
    func revertOfMissingFieldRemovesItAgain() {
        let state = configured(rows: [["1", nil]], absentCells: [[1]])
        var reverted: Set<RowID>?
        state.onFieldChanged = { _, _, _ in }
        state.onFieldReverted = { _, _, absentRows in reverted = absentRows }

        state.updateField(at: 1, value: "Ada")
        state.updateField(at: 1, value: nil)

        #expect(reverted == [rowA])
    }

    /// Staging refuses a value for a MongoDB `_id`, so the inspector offered Remove Field, Set NULL
    /// and typing on a field whose edit then stayed pending and never saved.
    @Test("A column the change manager refuses is read-only in the inspector, Remove Field included")
    func unwritableColumnOffersNoEdit() throws {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "items", columns: ["_id", "nick"], primaryKeyColumns: ["_id"],
            databaseType: .mongodb, generatedColumns: []
        )
        let state = MultiRowEditState()
        state.configure(
            selectedRowIndices: [0],
            rowIDs: [rowA],
            allRows: [["1", "Ada"]],
            absentCells: [[]],
            columns: ["_id", "nick"],
            columnTypes: [.text(rawType: nil), .text(rawType: nil)],
            externallyModifiedColumns: [],
            serverOwnedColumns: manager.unwritableColumns(among: ["_id", "nick"])
        )

        let identity = try #require(state.fields.first)
        let nick = try #require(state.fields.last)
        #expect(!InspectorFieldListView.isFieldEditable(identity, kind: FieldEditorResolver.resolve(field: identity), rowIsEditable: true))
        #expect(InspectorFieldListView.isFieldEditable(nick, kind: FieldEditorResolver.resolve(field: nick), rowIsEditable: true))
    }

    @Test("The inspector's read-only columns are the generated ones and the ones the driver declares immutable")
    func unwritableColumnsJoinGeneratedAndImmutable() {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "items", columns: ["_id", "nick", "total"], primaryKeyColumns: ["_id"],
            databaseType: .mongodb, generatedColumns: ["total"]
        )
        #expect(manager.unwritableColumns(among: ["_id", "nick", "total"]) == ["_id", "total"])

        manager.configureForTable(
            tableName: "items", columns: ["_id", "nick"], primaryKeyColumns: ["_id"],
            databaseType: .mysql, generatedColumns: []
        )
        #expect(manager.unwritableColumns(among: ["_id", "nick"]).isEmpty)
    }
}
