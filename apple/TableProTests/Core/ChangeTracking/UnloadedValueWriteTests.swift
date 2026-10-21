//
//  UnloadedValueWriteTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@MainActor
struct UnloadedValueWriteTests {
    private static let columns = ["id", "name", "data"]

    private static func page() -> TableRows {
        TableRows.from(
            queryRows: [["1", "a", .null]],
            columns: columns,
            columnTypes: [.integer(rawType: "INT"), .text(rawType: "VARCHAR"), .blob(rawType: "LONGBLOB")],
            unloadedCells: [0: [2: 5_242_880]]
        )
    }

    private static func manager() -> DataChangeManager {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "files",
            columns: columns,
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
        )
        return manager
    }

    @Test("An edit beside an unloaded value writes only the edited column, found by key")
    func editBesideUnloadedValue() throws {
        let row = Self.page().rows[0]
        let manager = Self.manager()
        manager.recordCellChange(
            rowID: row.id,
            columnIndex: 1,
            columnName: "name",
            oldValue: "a",
            newValue: "b",
            originalRow: Array(row.values)
        )

        let statements = try manager.generateSQL()
        #expect(statements.count == 1)
        #expect(statements[0].sql == "UPDATE `files` SET `name` = ? WHERE `id` = ?")
        #expect(statements[0].parameters.compactMap { $0 as? String } == ["b", "1"])
    }

    @Test("A deleted row whose value was never loaded cannot be rewound")
    func deletedUnloadedRowIsNotReversible() throws {
        let row = Self.page().rows[0]
        let manager = Self.manager()
        manager.recordRowDeletion(rowID: row.id, originalRow: Array(row.values))

        let build = try manager.buildRowWrites(
            database: "d", schema: nil, containsTableOperation: false, rowsWithUnloadedValues: [row.id]
        )
        #expect(build.operations.first?.refusal == .valueTooLarge)

        let loaded = try manager.buildRowWrites(database: "d", schema: nil, containsTableOperation: false)
        #expect(loaded.operations.first?.refusal == nil)
    }

    @Test("A value loaded after its row was deleted completes the deletion's pre-image")
    func valueLoadedAfterDeleteCompletesPreImage() throws {
        let row = Self.page().rows[0]
        let manager = Self.manager()
        manager.recordRowDeletion(rowID: row.id, originalRow: Array(row.values))
        manager.adoptLoadedValues([row.id: [2: .bytes(Data([5]))]])

        let build = try manager.buildRowWrites(database: "d", schema: nil, containsTableOperation: false)
        #expect(build.operations.first?.preImage?[2] == .bytes(Data([5])))
        #expect(build.operations.first?.refusal == nil)
    }

    @Test("A value loaded while a deletion was undone completes the image its redo records")
    func redoAfterLoadKeepsLoadedValue() throws {
        let row = Self.page().rows[0]
        let manager = Self.manager()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        manager.undoManagerProvider = { undoManager }

        manager.recordRowDeletion(rowID: row.id, originalRow: Array(row.values))
        undoManager.undo()
        manager.adoptLoadedValues([row.id: [2: .bytes(Data([5]))]])
        undoManager.redo()

        let build = try manager.buildRowWrites(database: "d", schema: nil, containsTableOperation: false)
        #expect(build.operations.first?.preImage?[2] == .bytes(Data([5])))
    }

    @Test("A value loaded for a tab in the background completes that tab's saved deletion")
    func backgroundTabSnapshotTakesLoadedValue() {
        let row = Self.page().rows[0]
        var snapshot = TabChangeSnapshot()
        snapshot.changes = [RowChange(rowID: row.id, type: .delete, originalRow: Array(row.values))]
        snapshot.adoptLoadedValues([row.id: [2: .bytes(Data([5]))]])
        #expect(snapshot.changes.first?.originalRow?[2] == .bytes(Data([5])))
    }
}
