//
//  RowVisualIndexTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import TableProPluginKit
import TableProTheme
import Testing

@MainActor
private final class CountingChangeManager: ChangeManaging {
    var changes: [RowChange] = []
    private(set) var scans = 0
    private(set) var lookups = 0

    var hasChanges: Bool { !changes.isEmpty }
    var reloadVersion: Int { 0 }
    var canRedo: Bool { false }
    var insertedRowIDs: Set<RowID> { [] }

    var rowChanges: [RowChange] {
        scans += 1
        return changes
    }

    func pendingChange(forRow rowID: RowID) -> RowChange? {
        lookups += 1
        return changes.first { $0.rowID == rowID }
    }

    func isRowDeleted(_ rowID: RowID) -> Bool { false }

    func recordCellChange(
        rowID: RowID,
        columnIndex: Int,
        columnName: String,
        oldValue: PluginCellValue,
        newValue: PluginCellValue,
        originalRow: [PluginCellValue]?
    ) {}

    func undoRowDeletion(rowID: RowID) {}
}

@MainActor
private final class RepaintRecordingView: DataGridMountedView {
    private(set) var changes: [DataGridChange] = []

    func apply(_ change: DataGridChange) {
        changes.append(change)
    }

    func selectionDidChange() {}
    func configurationDidChange() {}
    func reveal(row: Int, displayColumn: Int?) {}
    func revealColumn(_ displayColumn: Int) {}
    func sortDidChange() {}
    func summaryRulesDidChange() {}
    func viewportSample() -> (row: Int, offset: CGFloat)? { nil }
    func beginEditing(row: Int, displayColumn: Int) -> Bool { false }
    var isEditing: Bool { false }
    func commitEditing() -> Bool { true }
    func discardEditing() {}
    func focus() -> Bool { false }
    func anchor(forColumn displayColumn: Int) -> (view: NSView, rect: NSRect)? { nil }
}

@MainActor
struct UndoStepRepaintTests {
    private let fixture = CoordinatorFixture()

    // Undoing a command over every row runs one step per cell, so a step that repaints every row costs rows squared.
    @Test("Undoing a step repaints the row it names and no other")
    func undoRepaintsOnlyItsRow() {
        let rows = TableRows.from(
            queryRows: (0..<40).map { row -> [PluginCellValue] in [.text("\(row)"), .text("b")] },
            columns: ["id", "name"],
            columnTypes: [.text(rawType: nil), .text(rawType: nil)],
            hasAuthoritativeSchema: true
        )
        let tab = fixture.addTab(
            QueryTab(title: "users", query: "SELECT * FROM users", tabType: .table, tableName: "users"),
            rows: rows
        )
        let model = fixture.coordinator.gridModel(forTab: tab.id)
        let view = RepaintRecordingView()
        model.attach(view)

        fixture.coordinator.handleUndoResult(UndoResult(
            action: .cellEdit(
                rowID: .existing(7), columnIndex: 1, columnName: "name",
                previousValue: "a", newValue: "b", originalRow: ["7", "a"]
            ),
            needsRowRemoval: false,
            needsRowRestore: false,
            restoreRow: nil
        ), forTab: tab.id)

        var repainted = IndexSet()
        var marksRepainted = false
        for change in view.changes {
            guard case .rowsUpdated(let indexes, let columns) = change else { continue }
            repainted.formUnion(indexes)
            if columns == nil { marksRepainted = true }
        }
        #expect(repainted == IndexSet(integer: 7))
        #expect(marksRepainted)
        #expect(fixture.coordinator.tabSessionRegistry.tableRows(for: tab.id).rows[7].values[1] == "a")
    }

    @Test("A batch step names every row it holds")
    func batchStepNamesItsRows() {
        let deletion = UndoAction.batchRowDeletion(rows: [(rowID: .existing(1), originalRow: []), (rowID: .existing(3), originalRow: [])])
        let insertion = UndoAction.batchRowInsertion(
            rows: [InsertedRowLocation(rowID: .existing(5), storageIndex: 5)],
            rowValues: [[]]
        )

        #expect(RowEditingCoordinator.rowIDs(touchedBy: deletion) == [.existing(1), .existing(3)])
        #expect(RowEditingCoordinator.rowIDs(touchedBy: insertion) == [.existing(5)])
    }
}

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

    @Test("A cell staged as SQL is marked, on a saved row's edit and on a new row alike")
    func expressionCellsAreMarked() {
        let manager = makeManager()
        manager.recordCellChange(
            rowID: .existing(1), columnIndex: 1, columnName: "name",
            oldValue: "a", newValue: "now()", originalRow: ["1", "a"],
            absence: FieldAbsence(), isExpression: true
        )
        manager.recordCellChange(
            rowID: .existing(2), columnIndex: 1, columnName: "name",
            oldValue: "b", newValue: "now()", originalRow: ["2", "b"]
        )
        let inserted = RowID.inserted(UUID())
        manager.recordRowInsertion(rowID: inserted, values: [.null, "now()"], expressionColumns: [1])
        let index = RowVisualIndex()

        index.rebuild(from: AnyChangeManager(manager))

        #expect(index.visualState(for: .existing(1)).expressionColumns == [1])
        #expect(index.visualState(for: .existing(2)).expressionColumns.isEmpty)
        #expect(index.visualState(for: inserted).expressionColumns == [1])
    }

    @Test("Updating rows looks each one's change up by its id, never scanning every pending change")
    func updateRowLooksTheChangeUp() {
        let manager = CountingChangeManager()
        manager.changes = (0..<2_000).map { row in
            RowChange(
                rowID: .existing(row),
                type: .update,
                cellChanges: [CellChange(columnIndex: 1, columnName: "name", oldValue: "a", newValue: "b")]
            )
        }
        let changeManager = AnyChangeManager(manager)
        let index = RowVisualIndex()

        for row in 0..<2_000 {
            index.updateRow(.existing(row), from: changeManager)
        }

        #expect(manager.scans == 0)
        #expect(manager.lookups == 2_000)
        #expect(index.visualState(for: .existing(1_999)).modifiedColumns == [1])
    }

    @Test("A row's pending change is the one a scan of every change finds, after removals reorder them")
    func pendingChangeMatchesAScan() {
        let manager = makeManager()
        for row in 0..<6 {
            manager.recordCellChange(
                rowID: .existing(row), columnIndex: 1, columnName: "name",
                oldValue: "a", newValue: "b", originalRow: [.text("\(row)"), "a"]
            )
        }
        let inserted = RowID.inserted(UUID())
        manager.recordRowInsertion(rowID: inserted, values: [.null, .null])
        manager.recordRowDeletion(rowID: .existing(2), originalRow: ["2", "b"])
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "b", newValue: "a", originalRow: ["0", "b"]
        )
        manager.undoRowDeletion(rowID: .existing(2))
        manager.recordRowDeletion(rowID: .existing(4), originalRow: ["4", "b"])

        for rowID in (0..<8).map(RowID.existing) + [inserted] {
            let scanned = manager.rowChanges.first { $0.rowID == rowID }
            #expect(manager.pendingChange(forRow: rowID) == scanned)
        }
        #expect(manager.pendingChange(forRow: .existing(4))?.type == .delete)
        #expect(manager.pendingChange(forRow: .existing(0)) == nil)
    }

    @Test("A deleted or new row tints the whole row from its theme slot, a highlighted one with the rule's wash")
    func rowTintFollowsTheState() {
        let scope = ThemeScope.live
        let highlighted = RowVisualState(
            isDeleted: false,
            isInserted: false,
            modifiedColumns: [],
            highlight: RowHighlight(rowRule: HighlightRule(columnName: "name", value: "Ann", color: .blue), cellRules: [:])
        )

        #expect(RowVisualState(isDeleted: true, isInserted: false, modifiedColumns: []).tint(in: scope) == scope.resolved[.gridDeleted])
        #expect(RowVisualState(isDeleted: false, isInserted: true, modifiedColumns: []).tint(in: scope) == scope.resolved[.gridInserted])
        #expect(highlighted.tint(in: scope) == HighlightColor.blue.washColor)
        #expect(RowVisualState.empty.tint(in: scope) == nil)
    }
}
