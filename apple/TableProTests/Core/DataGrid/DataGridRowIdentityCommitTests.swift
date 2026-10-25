//
//  DataGridRowIdentityCommitTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

// Records each commit in a real change manager and writes the rows, the way the data tab's adapter does.
@MainActor
private final class ChangeRecordingOwner: DataGridDataSource, DataGridActions {
    var tableRows: TableRows
    let manager: DataChangeManager
    let changeState: AnyChangeManager
    weak var model: DataGridModel?
    private(set) var commitCount = 0

    init(_ tableRows: TableRows, manager: DataChangeManager) {
        self.tableRows = tableRows
        self.manager = manager
        changeState = AnyChangeManager(manager)
    }

    var gridRows: TableRows { tableRows }
    var gridChangeState: AnyChangeManager { changeState }

    func gridCommit(_ edits: [DataGridResolvedEdit], actionName: String) -> Bool {
        commitCount += 1
        var writes: [(row: Int, column: Int, value: PluginCellValue)] = []
        for edit in edits {
            guard let storageRow = tableRows.index(of: edit.rowID) else { continue }
            manager.recordCellChange(
                rowID: edit.rowID,
                columnIndex: edit.dataIndex,
                columnName: edit.columnName,
                oldValue: edit.oldValue,
                newValue: edit.newValue,
                originalRow: edit.originalRow,
                absence: edit.absence,
                isExpression: edit.isExpression
            )
            writes.append((row: storageRow, column: edit.dataIndex, value: edit.newValue))
        }
        guard !writes.isEmpty else { return false }
        model?.apply(tableRows.editMany(writes))
        return true
    }
}

@MainActor
struct DataGridRowIdentityCommitTests {
    private static let status = DataGridColumnID(name: "status", occurrence: 0)
    private static let id = DataGridColumnID(name: "id", occurrence: 0)

    private func makeManager() -> DataChangeManager {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "users",
            columns: ["id", "status"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
        )
        return manager
    }

    private func makeGrid(manager: DataChangeManager) -> (DataGridModel, ChangeRecordingOwner) {
        let owner = ChangeRecordingOwner(TableRows.from(
            queryRows: [
                [.text("1"), .text("active")],
                [.text("2"), .text("inactive")],
                [.text("3"), .text("active")],
                [.text("4"), .text("inactive")],
            ],
            columns: ["id", "status"],
            columnTypes: [.text(rawType: nil), .text(rawType: nil)]
        ), manager: manager)
        var configuration = DataGridConfiguration()
        configuration.isEditable = true
        let model = DataGridModel(configuration: configuration)
        model.dataSource = owner
        model.actions = owner
        owner.model = model
        model.reloadRows()
        return (model, owner)
    }

    private func filterToInactive(_ model: DataGridModel) {
        var filter = GridValueFilterState()
        filter.set(ColumnValueFilter(selectedValues: ["inactive"], includesNull: false), columnName: "status", forColumn: 1)
        model.setValueFilter(filter)
    }

    private func edit(_ rowID: RowID, _ column: DataGridColumnID, _ text: String) -> DataGridCellEdit {
        DataGridCellEdit(rowID: rowID, columnID: column, value: .enteredText(text))
    }

    @Test("An edit under a value filter lands on the row shown there, and only that row changes")
    func editUnderFilterLandsOnTheShownRow() throws {
        let manager = makeManager()
        let (model, owner) = makeGrid(manager: manager)
        filterToInactive(model)
        #expect(model.order.filteredIDs == [.existing(1), .existing(3)])
        let shown = try #require(model.rowID(at: 1))

        #expect(model.commit([edit(shown, Self.status, "archived")], actionName: "Edit Cell"))

        #expect(manager.isCellModified(rowID: .existing(3), columnIndex: 1))
        #expect(!manager.isCellModified(rowID: .existing(1), columnIndex: 1))
        #expect(owner.tableRows.rows[3].values[1] == "archived")
        #expect(owner.tableRows.rows[1].values[1] == "inactive")

        let statements = try manager.generateSQL()
        let parameters = statements.first?.parameters ?? []
        #expect(statements.count == 1)
        #expect(parameters.count == 2)
        #expect(parameters.last.flatMap { $0 as? String } == "4")
    }

    @Test("An edit keeps its row when the filter is cleared and positions move")
    func editFollowsItsRowAcrossADisplayOrderChange() throws {
        let manager = makeManager()
        // The model holds its owner weakly, so the test holds it.
        let (model, owner) = makeGrid(manager: manager)
        defer { withExtendedLifetime(owner) {} }
        filterToInactive(model)
        let shown = try #require(model.rowID(at: 0))

        model.commit([edit(shown, Self.status, "archived")], actionName: "Edit Cell")
        model.setValueFilter(GridValueFilterState())

        let index = RowVisualIndex()
        index.rebuild(from: model.changeState)
        #expect(!model.order.isFiltered)
        #expect(model.displayIndex(of: .existing(1)) == 1)
        #expect(index.visualState(for: .existing(1)).modifiedColumns == [1])
        #expect(index.visualState(for: .existing(0)).modifiedColumns.isEmpty)
    }

    @Test("Undoing an edit made under a value filter reverts the row that was edited")
    func undoUnderFilterRevertsTheEditedRow() throws {
        let manager = makeManager()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        manager.undoManagerProvider = { undoManager }
        var captured: UndoResult?
        manager.onUndoApplied = { captured = $0 }
        let (model, owner) = makeGrid(manager: manager)
        filterToInactive(model)
        let shown = try #require(model.rowID(at: 1))

        model.commit([edit(shown, Self.id, "9")], actionName: "Edit Cell")
        #expect(owner.tableRows.rows[3].values[0] == "9")

        undoManager.undo()
        let result = try #require(captured)
        _ = RowOperationsManager(changeManager: manager).applyUndoResult(result, tableRows: &owner.tableRows)

        #expect(owner.tableRows.rows[3].values[0] == "4")
        #expect(owner.tableRows.rows[1].values[0] == "2")
        #expect(!manager.isCellModified(rowID: .existing(3), columnIndex: 0))
    }

    @Test("A deleted row is recognised at whatever position the filter shows it")
    func deletedRowIsFoundByIdentity() throws {
        let manager = makeManager()
        // The model holds its owner weakly, so the test holds it.
        let (model, owner) = makeGrid(manager: manager)
        defer { withExtendedLifetime(owner) {} }
        manager.recordRowDeletion(rowID: .existing(3), originalRow: ["4", "inactive"])
        filterToInactive(model)

        let shown = try #require(model.rowID(at: 1))
        let index = RowVisualIndex()
        index.rebuild(from: model.changeState)

        #expect(shown == .existing(3))
        #expect(model.changeState?.isRowDeleted(shown) == true)
        #expect(model.changeState?.isRowDeleted(.existing(1)) == false)
        #expect(index.visualState(for: shown).isDeleted)
    }

    @Test("A commit over the shown rows under a filter writes them and skips a deleted one")
    func commitOverShownRowsSkipsDeleted() {
        let manager = makeManager()
        // The model holds its owner weakly, so the test holds it.
        let (model, owner) = makeGrid(manager: manager)
        defer { withExtendedLifetime(owner) {} }
        filterToInactive(model)
        manager.recordRowDeletion(rowID: .existing(3), originalRow: ["4", "inactive"])

        let shown = (0..<model.rowCount).compactMap { model.rowID(at: $0) }
        model.commit(shown.map { edit($0, Self.status, "gone") }, actionName: "Fill Column")

        #expect(manager.isCellModified(rowID: .existing(1), columnIndex: 1))
        #expect(!manager.isCellModified(rowID: .existing(3), columnIndex: 1))
        #expect(!manager.isCellModified(rowID: .existing(0), columnIndex: 1))
        #expect(!manager.isCellModified(rowID: .existing(2), columnIndex: 1))
    }

    @Test("A commit by row identity writes the record the editor was opened for")
    func identityCommitWritesTheOpenedRecord() throws {
        let manager = makeManager()
        let (model, owner) = makeGrid(manager: manager)
        let opened = try #require(model.rowID(at: 1))

        filterToInactive(model)
        model.commit([edit(opened, Self.status, "archived")], actionName: "Edit Cell")

        #expect(opened == .existing(1))
        #expect(model.rowID(at: 1) == .existing(3))
        #expect(manager.isCellModified(rowID: .existing(1), columnIndex: 1))
        #expect(!manager.isCellModified(rowID: .existing(3), columnIndex: 1))
        #expect(owner.tableRows.rows[1].values[1] == .text("archived"))
        #expect(owner.tableRows.rows[3].values[1] == .text("inactive"))
    }

    @Test("A commit by row identity still writes a record the filter is hiding")
    func identityCommitWritesAHiddenRecord() throws {
        let manager = makeManager()
        let (model, owner) = makeGrid(manager: manager)
        let opened = try #require(model.rowID(at: 0))

        filterToInactive(model)
        #expect(model.displayIndex(of: opened) == nil)
        model.commit([edit(opened, Self.status, "archived")], actionName: "Edit Cell")

        #expect(opened == .existing(0))
        #expect(manager.isCellModified(rowID: .existing(0), columnIndex: 1))
        #expect(owner.tableRows.rows[0].values[1] == .text("archived"))
    }

    @Test("A commit naming a record the result no longer holds writes nothing")
    func identityCommitForAMissingRecordWritesNothing() {
        let manager = makeManager()
        let (model, owner) = makeGrid(manager: manager)

        let committed = model.commit([edit(.existing(99), Self.status, "archived")], actionName: "Edit Cell")

        #expect(!committed)
        #expect(owner.commitCount == 0)
        #expect(!manager.hasChanges)
        #expect(owner.tableRows.rows[1].values[1] == .text("inactive"))
    }
}
