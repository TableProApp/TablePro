//
//  InspectorFieldEditStagingTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Row inspector edits reach the grid")
@MainActor
struct InspectorFieldEditStagingTests {
    @MainActor
    private struct Fixture {
        let coordinator: MainContentCoordinator
        let tabId: UUID

        var tableRows: TableRows {
            coordinator.tabSessionRegistry.tableRows(for: tabId)
        }

        func value(row: Int, column: Int) -> PluginCellValue {
            tableRows.rows[row].values[column]
        }

        func stage(
            _ value: PluginCellValue,
            column: Int = 1,
            rows: [RowID] = [.existing(1)],
            continuity: FieldEditContinuity = .discrete
        ) {
            coordinator.stageInspectorFieldEdit(
                columnIndex: column, value: value, rowIDs: rows, continuity: continuity
            )
        }

        func type(_ value: PluginCellValue, column: Int = 1, rows: [RowID] = [.existing(1)]) {
            stage(value, column: column, rows: rows, continuity: .typing)
        }

        /// A real `MultiRowEditState` wired the way the inspector wires it, so a field edit takes
        /// the same route from the editor's binding to the staged change.
        func configuredEditState(rows: [RowID]) -> MultiRowEditState {
            let state = MultiRowEditState()
            let selected = rows.compactMap { tableRows.row(withID: $0) }
            state.configure(
                selectedRowIndices: Set(selected.indices),
                rowIDs: selected.map(\.id),
                allRows: selected.map { $0.values.map(\.asText) },
                columns: tableRows.columns,
                columnTypes: [.text(rawType: nil), .text(rawType: nil)]
            )
            state.onFieldChanged = { [coordinator] columnIndex, value, continuity in
                coordinator.stageInspectorFieldEdit(
                    columnIndex: columnIndex, value: value, rowIDs: rows, continuity: continuity
                )
            }
            state.onFieldReverted = { [coordinator] columnIndex, valuesByRow in
                coordinator.revertInspectorFieldEdit(columnIndex: columnIndex, valuesByRow: valuesByRow)
            }
            return state
        }
    }

    private func makeFixture(generatedColumns: Set<String> = []) -> Fixture {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        var tab = QueryTab(title: "users", query: "SELECT * FROM users", tabType: .table, tableName: "users")
        tab.execution.lastExecutedAt = Date()
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id

        coordinator.setActiveTableRows(
            TableRows.from(
                queryRows: [
                    [.text("1"), .text("Alice")],
                    [.text("2"), .text("Bob")],
                    [.text("3"), .text("Carol")]
                ],
                columns: ["id", "name"],
                columnTypes: [.text(rawType: nil), .text(rawType: nil)],
                hasAuthoritativeSchema: true
            ),
            for: tab.id
        )
        coordinator.changeManager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: generatedColumns
        )
        return Fixture(coordinator: coordinator, tabId: tab.id)
    }

    private func cellChange(_ fixture: Fixture, rowID: RowID, column: Int) -> CellChange? {
        fixture.coordinator.changeManager.rowChanges
            .first { $0.rowID == rowID && $0.type == .update }?
            .cellChanges
            .first { $0.columnIndex == column }
    }

    @Test("the edited value lands in the row buffer the grid draws from")
    func theEditReachesTheRowBuffer() {
        let fixture = makeFixture()

        fixture.stage(.text("Zed"))

        #expect(fixture.value(row: 1, column: 1) == .text("Zed"))
        #expect(fixture.coordinator.changeManager.hasChanges)
        #expect(cellChange(fixture, rowID: .existing(1), column: 1)?.newValue == .text("Zed"))
    }

    /// The inspector rebuilds its fields from the same buffer on the next selection change, so an
    /// edit that never reached it came back showing the value before the edit (#2851).
    @Test("reconfiguring the inspector from the edited row shows the edited value")
    func theInspectorRebuildsFromTheEditedRow() {
        let fixture = makeFixture()
        fixture.stage(.text("Zed"))

        let editState = MultiRowEditState()
        let row = fixture.tableRows.rows[1]
        editState.configure(
            selectedRowIndices: [1],
            rowIDs: [row.id],
            allRows: [row.values.map(\.asText)],
            columns: ["id", "name"],
            columnTypes: [.text(rawType: nil), .text(rawType: nil)]
        )

        #expect(editState.fields[1].originalValue == "Zed")
    }

    @Test("typing the stored value back clears the pending change and restores the row")
    func revertingToTheStoredValueClearsTheChange() {
        let fixture = makeFixture()

        fixture.stage(.text("Zed"))
        fixture.stage(.text("Bob"))

        #expect(fixture.value(row: 1, column: 1) == .text("Bob"))
        #expect(!fixture.coordinator.changeManager.hasChanges)
    }

    /// Every row used to be recorded with one shared previous value taken from the inspector's
    /// field, which is nil, and so NULL, whenever the selected rows disagree.
    @Test("each row in a multi-row edit keeps its own previous value")
    func multiRowEditKeepsEachRowsPreviousValue() {
        let fixture = makeFixture()

        fixture.stage(.text("Same"), rows: [.existing(0), .existing(1)])

        #expect(cellChange(fixture, rowID: .existing(0), column: 1)?.oldValue == .text("Alice"))
        #expect(cellChange(fixture, rowID: .existing(1), column: 1)?.oldValue == .text("Bob"))
        #expect(fixture.value(row: 0, column: 1) == .text("Same"))
        #expect(fixture.value(row: 1, column: 1) == .text("Same"))
    }

    @Test("undo puts the stored value back in the row buffer")
    func undoRestoresTheStoredValue() {
        let fixture = makeFixture()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        fixture.coordinator.changeManager.undoManagerProvider = { undoManager }

        fixture.stage(.text("Zed"))
        undoManager.undo()

        #expect(fixture.value(row: 1, column: 1) == .text("Bob"))
        #expect(!fixture.coordinator.changeManager.hasChanges)
    }

    /// `originalValue` is nil both for a stored NULL and for a selection whose rows disagree, and
    /// sending that nil as one value wrote NULL into every selected row.
    @Test("clearing a field the selected rows disagree on puts each row's own value back")
    func clearingAMultiValueFieldRestoresEachRow() {
        let fixture = makeFixture()
        let editState = fixture.configuredEditState(rows: [.existing(0), .existing(1)])

        editState.updateField(at: 1, value: "Same")
        editState.updateField(at: 1, value: "")

        #expect(fixture.value(row: 0, column: 1) == .text("Alice"))
        #expect(fixture.value(row: 1, column: 1) == .text("Bob"))
        #expect(!fixture.coordinator.changeManager.hasChanges)
    }

    @Test("clearing a field the rows agree on still sends the stored value")
    func clearingASingleValueFieldSendsTheStoredValue() {
        let fixture = makeFixture()
        let editState = fixture.configuredEditState(rows: [.existing(1)])

        editState.updateField(at: 1, value: "Zed")
        editState.updateField(at: 1, value: "Bob")

        #expect(fixture.value(row: 1, column: 1) == .text("Bob"))
        #expect(!fixture.coordinator.changeManager.hasChanges)
    }

    @Test("an explicit NULL over rows that disagree still stages")
    func anExplicitNullStillStages() {
        let fixture = makeFixture()
        let editState = fixture.configuredEditState(rows: [.existing(0), .existing(1)])

        editState.setFieldToNull(at: 1)

        #expect(fixture.value(row: 0, column: 1) == .null)
        #expect(fixture.value(row: 1, column: 1) == .null)
        #expect(fixture.coordinator.changeManager.hasChanges)
    }

    @Test("a row the buffer does not hold is skipped rather than staged")
    func anUnknownRowIsSkipped() {
        let fixture = makeFixture()

        fixture.stage(.text("Zed"), rows: [.existing(99)])

        #expect(!fixture.coordinator.changeManager.hasChanges)
        #expect(fixture.value(row: 1, column: 1) == .text("Bob"))
    }

    @Test("a server-owned column is refused before the row is touched")
    func aServerOwnedColumnIsRefused() {
        let fixture = makeFixture(generatedColumns: ["name"])

        fixture.stage(.text("Zed"))

        #expect(!fixture.coordinator.changeManager.hasChanges)
        #expect(fixture.value(row: 1, column: 1) == .text("Bob"))
    }

    /// Rows are named by identity, so an edit staged while a value filter is hiding rows cannot
    /// land on whatever row sits at the same display position.
    @Test("a value filter does not move the edit to another row")
    func aValueFilterDoesNotMoveTheEdit() {
        let fixture = makeFixture()
        var filter = GridValueFilterState()
        filter.set(
            ColumnValueFilter(selectedValues: ["Bob", "Carol"], includesNull: false),
            columnName: "name",
            forColumn: 1
        )
        fixture.coordinator.setValueFilter(filter, forTab: fixture.tabId)
        #expect(fixture.coordinator.activeGridDisplayIDs == [.existing(1), .existing(2)])

        fixture.stage(.text("Zed"), rows: [.existing(2)])

        #expect(fixture.value(row: 2, column: 1) == .text("Zed"))
        #expect(fixture.value(row: 1, column: 1) == .text("Bob"))
    }

    /// A `TextField` bound to a string writes its binding per character, so a typed word reached
    /// the undo stack one character at a time.
    @Test("a typed word is one undo step")
    func typingIsOneUndoStep() {
        let fixture = makeFixture()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        fixture.coordinator.changeManager.undoManagerProvider = { undoManager }

        fixture.type(.text("Bobb"))
        fixture.type(.text("Bobby"))
        fixture.coordinator.endInspectorEditRun()
        #expect(fixture.value(row: 1, column: 1) == .text("Bobby"))

        undoManager.undo()

        #expect(fixture.value(row: 1, column: 1) == .text("Bob"))
        #expect(!fixture.coordinator.changeManager.hasChanges)
        #expect(!undoManager.canUndo)
    }

    @Test("redo puts the last typed value back, not the first keystroke")
    func redoRestoresTheFinalValue() {
        let fixture = makeFixture()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        fixture.coordinator.changeManager.undoManagerProvider = { undoManager }

        fixture.type(.text("Bobb"))
        fixture.type(.text("Bobby"))
        fixture.coordinator.endInspectorEditRun()
        undoManager.undo()
        undoManager.redo()

        #expect(fixture.value(row: 1, column: 1) == .text("Bobby"))
    }

    @Test("a word typed across a multi-row selection is one undo step for every row")
    func multiRowTypingIsOneUndoStep() {
        let fixture = makeFixture()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        fixture.coordinator.changeManager.undoManagerProvider = { undoManager }

        fixture.type(.text("Sa"), rows: [.existing(0), .existing(1)])
        fixture.type(.text("Sam"), rows: [.existing(0), .existing(1)])
        fixture.coordinator.endInspectorEditRun()

        undoManager.undo()

        #expect(fixture.value(row: 0, column: 1) == .text("Alice"))
        #expect(fixture.value(row: 1, column: 1) == .text("Bob"))
        #expect(!fixture.coordinator.changeManager.hasChanges)
        #expect(!undoManager.canUndo)
    }

    /// A row that already held the typed text joins the run on the keystroke that first changes it,
    /// with its own starting value.
    @Test("a row that only changes later still comes back with the rest")
    func aLateJoiningRowIsRestored() {
        let fixture = makeFixture()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        fixture.coordinator.changeManager.undoManagerProvider = { undoManager }

        fixture.type(.text("Alice"), rows: [.existing(0), .existing(1)])
        fixture.type(.text("AliceX"), rows: [.existing(0), .existing(1)])
        fixture.coordinator.endInspectorEditRun()

        undoManager.undo()

        #expect(fixture.value(row: 0, column: 1) == .text("Alice"))
        #expect(fixture.value(row: 1, column: 1) == .text("Bob"))
        #expect(!fixture.coordinator.changeManager.hasChanges)
    }

    @Test("a word typed back to where it started leaves no undo step")
    func typingBackToTheStartLeavesNoStep() {
        let fixture = makeFixture()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        fixture.coordinator.changeManager.undoManagerProvider = { undoManager }

        fixture.type(.text("Bobby"))
        fixture.type(.text("Bob"))
        fixture.coordinator.endInspectorEditRun()

        #expect(!undoManager.canUndo)
        #expect(!fixture.coordinator.changeManager.hasChanges)
        #expect(fixture.value(row: 1, column: 1) == .text("Bob"))
    }

    @Test("a discrete action ends the run and takes its own step")
    func aDiscreteActionTakesItsOwnStep() {
        let fixture = makeFixture()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        fixture.coordinator.changeManager.undoManagerProvider = { undoManager }

        fixture.type(.text("Bobby"))
        fixture.stage(.null)

        undoManager.undo()
        #expect(fixture.value(row: 1, column: 1) == .text("Bobby"))

        undoManager.undo()
        #expect(fixture.value(row: 1, column: 1) == .text("Bob"))
    }

    @Test("the Edit menu offers Undo while a word is still being typed")
    func anOpenRunIsUndoable() {
        let fixture = makeFixture()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        fixture.coordinator.changeManager.undoManagerProvider = { undoManager }

        fixture.type(.text("Bobby"))

        #expect(fixture.coordinator.changeManager.hasCoalescedUndoRun)
        #expect(!undoManager.canUndo)

        fixture.coordinator.endInspectorEditRun()

        #expect(!fixture.coordinator.changeManager.hasCoalescedUndoRun)
        #expect(undoManager.canUndo)
    }
}
