// A query tab opened from a .sql file can hold result edits too. Save and Save on close wrote the edits
// and reported success, and the file on disk kept its old text.

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import TableProUtilities
import Testing

private final class FileTabRowWriter: PluginDriverStub, @unchecked Sendable {
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
struct SaveFileBesideResultEditsTests {
    @MainActor
    private struct Harness {
        let fixture: CoordinatorFixture
        let actions: MainContentCommandActions
        let writer: FileTabRowWriter
        let window: NSWindow
        let folder: URL
        let fileURL: URL
        let tabId: UUID

        var tab: QueryTab? { fixture.tabManager.tabs.first { $0.id == tabId } }

        func tearDown() {
            window.orderOut(nil)
            DatabaseManager.shared.removeSession(for: fixture.connection.id)
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // report.sql open in a query tab, its text edited, and a cell of its result edited.
    private func makeHarness() throws -> Harness {
        let connection = TestFixtures.makeConnection()
        let writer = FileTabRowWriter()
        var session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: writer)
        )
        session.status = .connected
        session.browseDatabase = connection.database
        DatabaseManager.shared.injectSession(session, for: connection.id)

        let fixture = CoordinatorFixture(connection: connection)
        fixture.coordinator.executionGate = AlwaysAllowGate()
        // A failed save reports in a sheet on this window rather than in a modal alert nothing answers.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        fixture.coordinator.contentWindow = window

        var selectedTables: Set<DatabaseTreeTableRef> = []
        var pendingTruncates: Set<DatabaseTreeTableRef> = []
        var pendingDeletes: Set<DatabaseTreeTableRef> = []
        var tableOperationOptions: [DatabaseTreeTableRef: TableOperationOptions] = [:]
        let actions = MainContentCommandActions(
            coordinator: fixture.coordinator,
            connection: connection,
            selectedTables: Binding(get: { selectedTables }, set: { selectedTables = $0 }),
            pendingTruncates: Binding(get: { pendingTruncates }, set: { pendingTruncates = $0 }),
            pendingDeletes: Binding(get: { pendingDeletes }, set: { pendingDeletes = $0 }),
            tableOperationOptions: Binding(
                get: { tableOperationOptions },
                set: { tableOperationOptions = $0 }
            ),
            trailingPaneState: TrailingPaneState()
        )
        actions.window = window
        actions.chooseSaveURL = { _ in
            Issue.record("Save As was not expected")
            return nil
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("save-on-close-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileURL = folder.appendingPathComponent("report.sql")
        try Data("SELECT * FROM users".utf8).write(to: fileURL)
        let loaded = try #require(FileTextLoader.load(fileURL))
        fixture.tabManager.addTab(initialQuery: loaded.content, sourceFileURL: fileURL, sourceFileStamp: loaded.stamp)
        let tabId = try #require(fixture.tabManager.selectedTabId)
        fixture.tabManager.mutate(tabId: tabId) { tab in
            tab.content.query = "SELECT * FROM users WHERE id = 1"
            tab.tableContext.tableName = "users"
            tab.execution.lastExecutedAt = Date()
        }
        fixture.coordinator.setActiveTableRows(
            TableRows.from(
                queryRows: [[.text("1"), .text("a")]],
                columns: ["id", "name"],
                columnTypes: [.text(rawType: nil), .text(rawType: nil)],
                hasAuthoritativeSchema: true
            ),
            for: tabId
        )
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
        return Harness(
            fixture: fixture,
            actions: actions,
            writer: writer,
            window: window,
            folder: folder,
            fileURL: fileURL,
            tabId: tabId
        )
    }

    @Test("One Save writes the result edits and the tab's .sql file")
    func saveWritesTheResultEditsAndTheFile() async throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }

        harness.actions.saveChanges()

        try await waitUntil(timeout: .seconds(5)) { harness.tab?.content.isFileDirty == false }
        #expect(harness.writer.queries.contains { $0.hasPrefix("UPDATE") })
        #expect(!harness.fixture.coordinator.hasStagedRowEdits(inTab: harness.tabId))
        #expect(try String(contentsOf: harness.fileURL, encoding: .utf8) == "SELECT * FROM users WHERE id = 1")
    }

    @Test("Save on close writes the tab's .sql file beside its result edits")
    func saveOnCloseWritesTheFileToo() async throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }

        let mayClose = await harness.actions.saveSelectedTabWork()

        #expect(mayClose)
        #expect(harness.writer.queries.contains { $0.hasPrefix("UPDATE") })
        #expect(try String(contentsOf: harness.fileURL, encoding: .utf8) == "SELECT * FROM users WHERE id = 1")
        #expect(harness.tab?.content.isFileDirty == false)
    }

    @Test("Closing the connection writes the on-screen tab's .sql file beside its result edits")
    func connectionCloseWritesTheFileToo() async throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }

        let mayClose = await harness.actions.saveEveryTabsWork()

        #expect(mayClose)
        #expect(harness.writer.queries.contains { $0.hasPrefix("UPDATE") })
        #expect(try String(contentsOf: harness.fileURL, encoding: .utf8) == "SELECT * FROM users WHERE id = 1")
    }

    @Test("Save on close keeps the tab open when its file changed on disk, after the result edits saved")
    func fileConflictKeepsTheTabAfterTheResultEditsSave() async throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }
        let handle = try FileHandle(forWritingTo: harness.fileURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("SELECT 0".utf8))
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3_600)],
            ofItemAtPath: harness.fileURL.path
        )

        let mayClose = await harness.actions.saveSelectedTabWork()

        #expect(!mayClose)
        #expect(harness.writer.queries.contains { $0.hasPrefix("UPDATE") })
        #expect(harness.fixture.coordinator.fileConflictRequest?.tabId == harness.tabId)
        #expect(try String(contentsOf: harness.fileURL, encoding: .utf8) == "SELECT 0")
    }
}
