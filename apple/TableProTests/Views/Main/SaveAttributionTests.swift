import AppKit
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

// Writes every statement as one row affected, so a keyed save lands.
private final class RowWritingDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var received: [String] = []
    private var database: String?

    var queries: [String] { lock.withLock { received } }
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var currentDatabase: String? { lock.withLock { database } }
    var serverVersion: String? { nil }

    func ping() async throws {}
    func switchDatabase(to database: String) async throws {
        lock.withLock { self.database = database }
    }
    func execute(query: String) async throws -> PluginQueryResult {
        lock.withLock { received.append(query) }
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 1, executionTime: 0)
    }
}

@MainActor
struct SaveAttributionTests {
    // A table tab with one edited cell, and a gate that holds the save until the test answers.
    private func makeEditedTable(connection: DatabaseConnection = TestFixtures.makeConnection()) -> (CoordinatorFixture, HeldExecutionGate, UUID) {
        let fixture = CoordinatorFixture(connection: connection)
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

    @Test("A save approved after a tab switch writes the saving tab's edits and clears only them")
    func saveApprovedAfterATabSwitchClearsTheSavingTab() async throws {
        let connection = TestFixtures.makeConnection()
        let writer = RowWritingDriver()
        var session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: writer)
        )
        session.status = .connected
        session.browseDatabase = connection.database
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        // A failed save reports in a sheet on this window rather than in a modal alert nothing answers.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let (fixture, gate, savingTabId) = makeEditedTable(connection: connection)
        fixture.coordinator.contentWindow = window
        let other = fixture.addTab(QueryTab(title: "B", query: "SELECT * FROM orders", tabType: .query), select: false)
        let otherEdits = fixture.coordinator.changeManager(forTab: other.id)
        otherEdits.recordRowDeletion(rowID: .existing(0), originalRow: ["1"])

        save(fixture.coordinator)
        try await waitUntil { gate.askedCount == 1 }
        fixture.tabManager.selectedTabId = other.id
        fixture.coordinator.handleTabChange(from: savingTabId, to: other.id, tabs: fixture.tabManager.tabs)
        await gate.answer(allowing: true)

        let savingTab = { fixture.tabManager.tabs.first { $0.id == savingTabId } }
        try await waitUntil {
            !fixture.coordinator.hasStagedRowEdits(inTab: savingTabId) || savingTab()?.execution.errorMessage != nil
        }
        #expect(savingTab()?.execution.errorMessage == nil)
        #expect(!fixture.coordinator.hasStagedRowEdits(inTab: savingTabId))
        #expect(writer.queries.contains { $0.hasPrefix("UPDATE") })
        #expect(fixture.changeManager === otherEdits)
        #expect(otherEdits.hasChanges)
        // The save is over: a second one is not refused as already running.
        #expect(fixture.coordinator.rowEditingCoordinator.beginSaveInFlight(tabId: nil))
        fixture.coordinator.rowEditingCoordinator.endSaveInFlight()
        withExtendedLifetime(window) {}
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
