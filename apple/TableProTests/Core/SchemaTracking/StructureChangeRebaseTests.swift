//
//  StructureChangeRebaseTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

// MySQL and Oracle commit each DDL statement as it runs, so a save that fails part way has already changed the table.
@MainActor
struct StructureChangeRebaseTests {
    private func column(_ name: String) -> ColumnInfo {
        ColumnInfo(
            name: name, dataType: "INTEGER", isNullable: name != "id", isPrimaryKey: name == "id",
            defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil
        )
    }

    private func manager() -> StructureChangeManager {
        let manager = StructureChangeManager()
        manager.loadSchema(
            tableName: "notes",
            columns: ["id", "a", "x"].map { column($0) },
            indexes: [],
            foreignKeys: [],
            primaryKey: ["id"]
        )
        return manager
    }

    private func workingColumn(_ name: String, in manager: StructureChangeManager) throws -> EditableColumnDefinition {
        try #require(manager.workingColumns.first { $0.name == name })
    }

    private func stageRenameAddColumnAndIndex(in manager: StructureChangeManager) throws {
        var renamed = try workingColumn("a", in: manager)
        renamed.name = "b"
        manager.updateColumn(id: renamed.id, with: renamed)
        var added = try workingColumn("x", in: manager)
        added.id = UUID()
        added.name = "c"
        manager.addColumn(added)
        manager.addIndex(
            EditableIndexDefinition(
                id: UUID(), name: "idx_c", columns: ["c"], type: .btree, isUnique: false, isPrimary: false, comment: nil
            )
        )
    }

    @Test("Statements that ran before the failure leave the staged edits")
    func appliedChangesAreDropped() throws {
        let manager = manager()
        try stageRenameAddColumnAndIndex(in: manager)
        #expect(manager.getChangesArray().count == 3)

        let moved = manager.rebaseStagedChanges(
            onto: StructureRebase.Baseline(
                columns: ["id", "b", "x", "c"].map { column($0) },
                indexes: [],
                foreignKeys: [],
                primaryKey: ["id"]
            )
        )

        #expect(moved)
        let changes = manager.getChangesArray()
        #expect(changes.count == 1)
        if case .addIndex(let index)? = changes.first {
            #expect(index.name == "idx_c")
        } else {
            Issue.record("The index that failed should be the one change left")
        }
        let baseline = manager.currentColumns.map { $0.name }
        let shown = manager.workingColumns.map { $0.name }
        #expect(baseline == ["id", "b", "x", "c"])
        #expect(shown == ["id", "b", "x", "c"])
    }

    @Test("A save that wrote nothing keeps every staged edit and its undo history")
    func unchangedBaselineIsLeftAlone() throws {
        let manager = manager()
        try stageRenameAddColumnAndIndex(in: manager)
        let before = manager.getChangesArray()

        let moved = manager.rebaseStagedChanges(
            onto: StructureRebase.Baseline(
                columns: ["id", "a", "x"].map { column($0) },
                indexes: [],
                foreignKeys: [],
                primaryKey: ["id"]
            )
        )

        #expect(!moved)
        #expect(manager.getChangesArray() == before)
        #expect(manager.canUndo)
    }

    @Test("A deletion that ran is gone, and one that did not is still staged")
    func deletionsFollowTheTable() throws {
        let manager = manager()
        try manager.deleteColumn(id: workingColumn("x", in: manager).id)
        try manager.deleteColumn(id: workingColumn("a", in: manager).id)

        let moved = manager.rebaseStagedChanges(
            onto: StructureRebase.Baseline(
                columns: ["id", "a"].map { column($0) },
                indexes: [],
                foreignKeys: [],
                primaryKey: ["id"]
            )
        )

        #expect(moved)
        let changes = manager.getChangesArray()
        #expect(changes.count == 1)
        if case .deleteColumn(let deleted)? = changes.first {
            #expect(deleted.name == "a")
        } else {
            Issue.record("The deletion that did not run should be the one change left")
        }
        let shown = manager.workingColumns.map { $0.name }
        #expect(shown == ["id", "a"])
    }

    @Test("A rename that did not run is staged against the table as it is")
    func unappliedRenameStaysStaged() throws {
        let manager = manager()
        try stageRenameAddColumnAndIndex(in: manager)

        let moved = manager.rebaseStagedChanges(
            onto: StructureRebase.Baseline(
                columns: ["id", "a", "x", "c"].map { column($0) },
                indexes: [],
                foreignKeys: [],
                primaryKey: ["id"]
            )
        )

        #expect(moved)
        let renames = manager.getChangesArray().compactMap { change -> String? in
            guard case .modifyColumn(let old, let new) = change else { return nil }
            return "\(old.name)>\(new.name)"
        }
        #expect(renames == ["a>b"])
    }
}
