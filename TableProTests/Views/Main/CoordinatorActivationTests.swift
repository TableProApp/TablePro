//
//  CoordinatorActivationTests.swift
//  TableProTests
//
//  A connection switch takes a connection's panes out of the window and puts them back, which
//  runs `onAppear` again. Activation must treat that as the same connection coming back, not as a
//  new one opening: nothing it already loaded is fetched again.
//

import AppKit
import Foundation
@testable import TablePro
import Testing

@Suite("Coordinator activation", .serialized)
@MainActor
struct CoordinatorActivationTests {
    @Test("Switching back to a loaded connection queries nothing")
    func switchingBackQueriesNothing() async throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let mock = harness.connectBackground()
        harness.controller.workspaces.select(harness.background.connectionId)
        let coordinator = try #require(harness.background.sessionState?.coordinator)
        await harness.settle { coordinator.isActivated && harness.isAutocompletePopulated && coordinator.schemaLoadTask == nil }
        try #require(harness.isAutocompletePopulated)
        let tablesFetched = mock.fetchTablesCallCount

        for _ in 0..<3 {
            await harness.switchAway()
            let activations = coordinator.activationCount
            harness.controller.workspaces.select(harness.background.connectionId)
            await harness.settle { coordinator.activationCount > activations && coordinator.schemaLoadTask == nil }
            await harness.settle(for: 0.5)
        }

        #expect(coordinator.activationCount >= 4)
        #expect(mock.fetchTablesCallCount == tablesFetched)
        #expect(mock.fetchAllColumnsCallCount == 0)

        // Controls: a dropped provider is rebuilt from the loaded catalog without a read, and a
        // dropped catalog is read again, so the counts above were measured where a reload shows.
        SchemaProviderRegistry.shared.clear(for: harness.backgroundConnection.id)
        await harness.switchAway()
        harness.controller.workspaces.select(harness.background.connectionId)
        await harness.settle { harness.isAutocompletePopulated && coordinator.schemaLoadTask == nil }

        #expect(harness.isAutocompletePopulated)
        #expect(mock.fetchTablesCallCount == tablesFetched)

        await harness.switchAway()
        await SchemaService.shared.invalidate(connectionId: harness.backgroundConnection.id)
        harness.controller.workspaces.select(harness.background.connectionId)
        await harness.settle { mock.fetchTablesCallCount > tablesFetched }

        #expect(mock.fetchTablesCallCount > tablesFetched)
        #expect(mock.fetchAllColumnsCallCount == 0)
    }

    @Test("Opening a connection reads its tables once and no columns")
    func openingReadsTablesOnceAndNoColumns() async throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let mock = harness.connectBackground()
        harness.controller.workspaces.select(harness.background.connectionId)
        let coordinator = try #require(harness.background.sessionState?.coordinator)

        await harness.settle { coordinator.isActivated && harness.isAutocompletePopulated && coordinator.schemaLoadTask == nil }
        await harness.settle(for: 0.2)

        #expect(harness.isAutocompletePopulated)
        #expect(mock.fetchTablesCallCount == 1)
        #expect(mock.fetchAllColumnsCallCount == 0)
    }

    /// The store refuses a second load for a scope already loading, so a prefetch left running by
    /// the connect is what would make this one return nil.
    @Test("Opening a connection starts no foreign-key read")
    func openingStartsNoForeignKeyRead() async throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let mock = harness.connectBackground(bulkForeignKeyFetch: true)
        harness.controller.workspaces.select(harness.background.connectionId)
        let coordinator = try #require(harness.background.sessionState?.coordinator)
        await harness.settle { coordinator.isActivated && harness.isAutocompletePopulated && coordinator.schemaLoadTask == nil }
        let scope = try #require(DatabaseManager.shared.browseScope(for: harness.backgroundConnection.id))

        #expect(mock.providesBulkForeignKeyFetch)
        #expect(SchemaForeignKeyStore.shared.prefetch(scope: scope) { nil } != nil)
    }

    @Test("A file connection starts one watcher however often it appears")
    func fileWatcherStartsOnce() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("activation-\(UUID().uuidString).sqlite")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: file) }
        let connection = TestFixtures.makeConnection(database: file.path, type: .sqlite)
        let coordinator = SessionStateFactory.create(connection: connection, payload: nil).coordinator
        defer { coordinator.teardown() }

        coordinator.markActivated()
        let watcher = try #require(coordinator.fileWatcher)
        coordinator.markActivated()
        coordinator.markActivated()

        #expect(coordinator.fileWatcher === watcher)
    }

    /// Nothing re-reads a tree list until it is marked, and the change came from another process,
    /// so no catalog change of this app's own will mark it.
    @Test("An external change to the database file marks the tree's loaded lists stale")
    func fileChangeMarksTreeListsStale() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("activation-\(UUID().uuidString).sqlite")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: file) }
        let connection = TestFixtures.makeConnection(database: file.path, type: .sqlite)
        let driver = MockDatabaseDriver(connection: connection)
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "users")]
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        // SQLite metadata reads lease a pooled connection, and only a plugin can open one.
        let scope = try #require(DatabaseManager.shared.browseScope(for: connection.id))
        for workload in [MetadataConnectionPool.Workload.interactive, .bulk] {
            MetadataConnectionPool.shared.injectEntry(driver, scope: scope, workload: workload)
        }
        let tree = DatabaseTreeMetadataService.shared
        await tree.loadTables(connectionId: connection.id, database: connection.database, schema: nil)
        let coordinator = SessionStateFactory.create(connection: connection, payload: nil).coordinator
        defer {
            coordinator.teardown()
            DatabaseManager.shared.removeSession(for: connection.id)
        }
        try #require(tree.isTablesCurrent(connectionId: connection.id, database: connection.database, schema: nil))
        coordinator.markActivated()
        try #require(coordinator.fileWatcher != nil)
        for _ in 0 ..< 50 where coordinator.schemaLoadTask != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(
            tree.isTablesCurrent(connectionId: connection.id, database: connection.database, schema: nil),
            "Opening the connection marked the list before the file changed"
        )

        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("changed".utf8))
        try handle.close()
        for _ in 0 ..< 300 where tree.isTablesCurrent(connectionId: connection.id, database: connection.database, schema: nil) {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(!tree.isTablesCurrent(connectionId: connection.id, database: connection.database, schema: nil))
        await tree.handleDisconnect(connectionId: connection.id)
    }

    /// One window hosting two connections. The background one has no database name, so its browse
    /// scope is the server itself and every metadata read goes to its session driver, the mock,
    /// rather than to a pooled connection that plugins would have to open.
    @MainActor
    private struct Harness {
        let controller: MainSplitViewController
        let foreground: ConnectionWorkspace
        let background: ConnectionWorkspace
        let backgroundConnection: DatabaseConnection
        private let window: NSWindow

        init() {
            let foregroundConnection = TestFixtures.makeConnection(name: "Foreground")
            backgroundConnection = TestFixtures.makeConnection(name: "Background", database: "")
            foreground = Self.makeWorkspace(connection: foregroundConnection, phase: .idle)
            background = Self.makeWorkspace(connection: backgroundConnection, phase: .connecting)

            controller = MainSplitViewController(payload: nil, sessionState: nil, adopting: foreground)
            controller.workspaces.insert(background, select: false)

            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            window.orderFront(nil)
        }

        var isAutocompletePopulated: Bool {
            guard let scope = DatabaseManager.shared.browseScope(for: backgroundConnection.id) else { return false }
            return SchemaProviderRegistry.shared.isPopulated(scope)
        }

        func connectBackground(bulkForeignKeyFetch: Bool = false) -> MockDatabaseDriver {
            let mock = MockDatabaseDriver(connection: backgroundConnection)
            mock.bulkForeignKeyFetch = bulkForeignKeyFetch
            mock.tablesToReturn = [
                TestFixtures.makeTableInfo(name: "users"),
                TestFixtures.makeTableInfo(name: "orders"),
            ]
            mock.allColumnsToReturn = [
                "users": [TestFixtures.makeColumnInfo(name: "id")],
                "orders": [TestFixtures.makeColumnInfo(name: "id")],
            ]
            var session = ConnectionSession(connection: backgroundConnection, driver: mock)
            session.status = .connected
            DatabaseManager.shared.injectSession(session, for: backgroundConnection.id)
            controller.refreshFromActiveSessions()
            return mock
        }

        /// SwiftUI mounts a pane on the next layout pass, and the schema load runs as a main-actor
        /// task, so a test that asks what a switch did has to give the main actor up between passes.
        /// Spinning the run loop from inside a synchronous test holds the actor and runs neither.
        func settle(until isSatisfied: () -> Bool) async {
            let deadline = Date(timeIntervalSinceNow: 10)
            while !isSatisfied(), Date() < deadline {
                await pump()
            }
        }

        func switchAway() async {
            controller.workspaces.select(foreground.connectionId)
            await settle(for: 0.1)
        }

        func settle(for interval: TimeInterval) async {
            let deadline = Date(timeIntervalSinceNow: interval)
            while Date() < deadline {
                await pump()
            }
        }

        private func pump() async {
            window.contentView?.layoutSubtreeIfNeeded()
            controller.view.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }

        func tearDown() {
            window.orderOut(nil)
            window.contentViewController = nil
            background.teardown()
            foreground.teardown()
            SchemaForeignKeyStore.shared.invalidate(connectionId: backgroundConnection.id)
            DatabaseManager.shared.removeSession(for: backgroundConnection.id)
        }

        private static func makeWorkspace(
            connection: DatabaseConnection,
            phase: ConnectionWindowPhase
        ) -> ConnectionWorkspace {
            ConnectionWorkspace(
                connectionId: connection.id,
                payload: nil,
                autoConnect: false,
                payloadConnection: connection,
                session: nil,
                sessionState: nil,
                trailingPaneState: nil,
                phase: phase
            )
        }
    }
}
