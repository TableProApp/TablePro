//
//  RowVisualIndexTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("RowVisualIndex row identity")
@MainActor
struct RowVisualIndexTests {
    private func makeManager() -> DataChangeManager {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
        )
        return manager
    }

    @Test("An inserted row is marked on its own row id")
    func insertedRowMarkedOnItsID() {
        let manager = makeManager()
        let inserted = RowID.inserted(UUID())
        manager.recordRowInsertion(rowID: inserted, values: [.null, .null])
        let index = RowVisualIndex()

        index.rebuild(from: AnyChangeManager(manager))

        #expect(index.visualState(for: inserted).isInserted)
        #expect(!index.visualState(for: .existing(0)).isInserted)
    }

    @Test("Edits and deletions are marked on the rows they were made to")
    func editsAndDeletionsFollowTheirRows() {
        let manager = makeManager()
        manager.recordCellChange(
            rowID: .existing(7), columnIndex: 1, columnName: "name",
            oldValue: "Ann", newValue: "Bea", originalRow: ["7", "Ann"]
        )
        manager.recordRowDeletion(rowID: .existing(3), originalRow: ["3", "Cy"])
        let index = RowVisualIndex()

        index.rebuild(from: AnyChangeManager(manager))

        #expect(index.visualState(for: .existing(7)).modifiedColumns == [1])
        #expect(!index.visualState(for: .existing(7)).isDeleted)
        #expect(index.visualState(for: .existing(3)).isDeleted)
        #expect(index.visualState(for: .existing(0)) == .empty)
    }

    @Test("Updating one row picks up its latest state and leaves the others alone")
    func updateRowRefreshesOneRow() {
        let manager = makeManager()
        let changeManager = AnyChangeManager(manager)
        manager.recordRowDeletion(rowID: .existing(1), originalRow: ["1", "A"])
        let index = RowVisualIndex()
        index.rebuild(from: changeManager)

        manager.recordCellChange(
            rowID: .existing(2), columnIndex: 1, columnName: "name",
            oldValue: "B", newValue: "C", originalRow: ["2", "B"]
        )
        index.updateRow(.existing(2), from: changeManager)

        #expect(index.visualState(for: .existing(2)).modifiedColumns == [1])
        #expect(index.visualState(for: .existing(1)).isDeleted)

        manager.undoRowDeletion(rowID: .existing(1))
        index.updateRow(.existing(1), from: changeManager)

        #expect(index.visualState(for: .existing(1)) == .empty)
    }

    @Test("No changes leaves every row clean")
    func noChangesLeavesStateEmpty() {
        let index = RowVisualIndex()

        index.rebuild(from: AnyChangeManager(makeManager()))

        #expect(index.visualState(for: .existing(0)) == .empty)
        #expect(index.visualState(for: .inserted(UUID())) == .empty)
    }
}
