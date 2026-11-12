import Foundation
import TableProPluginKit
import TableProTestSupport
import Testing

@testable import TablePro

@MainActor
private final class SaveAnswers {
    var first: Bool?
    var second: Bool?
}

@MainActor
struct SaveAttributionTests {
    // A table tab with one edited cell, and a gate that holds the save until the test answers.
    private func makeEditedTable() -> (CoordinatorFixture, HeldExecutionGate, UUID) {
        let fixture = CoordinatorFixture()
        let gate = HeldExecutionGate()
        fixture.coordinator.executionGate = gate
        var tab = QueryTab(title: "users", query: "SELECT * FROM users", tabType: .table, tableName: "users")
        tab.execution.lastExecutedAt = Date()
        let rows = TableRows.from(
            queryRows: [[.text("1"), .text("a")]],
            columns: ["id", "name"],
            columnTypes: [.text(rawType: nil), .text(rawType: nil)],
            hasAuthoritativeSchema: true
        )
        fixture.addTab(tab, rows: rows)
        fixture.changeManager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
        )
        fixture.changeManager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "a", newValue: "z", originalRow: ["1", "a"]
        )
        return (fixture, gate, tab.id)
    }

    private func save(_ coordinator: MainContentCoordinator) {
        var truncates: Set<DatabaseTreeTableRef> = []
        var deletes: Set<DatabaseTreeTableRef> = []
        var options: [DatabaseTreeTableRef: TableOperationOptions] = [:]
        coordinator.saveChanges(
            pendingTruncates: &truncates,
            pendingDeletes: &deletes,
            tableOperationOptions: &options
        )
    }

    @Test("A save approved after a tab switch writes nothing and keeps the edits")
    func saveApprovedAfterATabSwitchIsDropped() async throws {
        let (fixture, gate, savingTabId) = makeEditedTable()
        let other = fixture.addTab(QueryTab(title: "B", query: "SELECT 1", tabType: .query), select: false)

        save(fixture.coordinator)
        try await waitUntil { gate.askedCount == 1 }
        fixture.tabManager.selectedTabId = other.id
        await gate.answer(allowing: true)

        try await waitUntil {
            fixture.tabManager.tabs.first { $0.id == savingTabId }?.execution.errorMessage != nil
        }
        #expect(fixture.changeManager.hasChanges)
        #expect(fixture.tabManager.tabs.first { $0.id == other.id }?.execution.errorMessage == nil)
        // The save is over: a second one is not refused as already running.
        #expect(fixture.coordinator.rowEditingCoordinator.beginSaveInFlight(tabId: nil))
        fixture.coordinator.rowEditingCoordinator.endSaveInFlight()
    }

    @Test("A value loaded during the approval prompt is not an edit, a new cell change is")
    func loadedValueDoesNotChangeThePlannedEdits() {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "users",
            columns: ["id", "name", "bio"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
        )
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "a", newValue: "z", originalRow: ["1", "a", .null]
        )
        let planned = PlannedEdits(manager.pending)
        let before = manager.pending

        manager.adoptLoadedValues([.existing(0): [2: .text("a long value")]])
        #expect(manager.pending != before)
        #expect(PlannedEdits(manager.pending) == planned)

        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 2, columnName: "bio",
            oldValue: "a long value", newValue: "edited", originalRow: ["1", "a", "a long value"]
        )
        #expect(PlannedEdits(manager.pending) != planned)
    }

    @Test("A second save-then-close gets its own answer and leaves the first one waiting for its save")
    func eachSaveResumesItsOwnWaiter() async throws {
        let (fixture, gate, _) = makeEditedTable()
        let coordinator = fixture.coordinator
        let answers = SaveAnswers()

        Task {
            answers.first = await withCheckedContinuation { continuation in
                coordinator.saveCompletionContinuation = continuation
                self.save(coordinator)
            }
        }
        try await waitUntil { gate.askedCount == 1 }
        Task {
            answers.second = await withCheckedContinuation { continuation in
                coordinator.saveCompletionContinuation = continuation
                self.save(coordinator)
            }
        }
        try await waitUntil { answers.second != nil }
        #expect(answers.second == false)
        #expect(answers.first == nil)

        await gate.answer(allowing: false)
        try await waitUntil { answers.first != nil }
        #expect(answers.first == false)
        #expect(coordinator.saveCompletionContinuation == nil)
    }
}
