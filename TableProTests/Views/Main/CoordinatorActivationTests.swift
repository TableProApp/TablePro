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
        await harness.settle { coordinator.isActivated && mock.fetchAllColumnsCallCount > 0 && coordinator.schemaLoadTask == nil }
        try #require(mock.fetchAllColumnsCallCount > 0)
        let tablesFetched = mock.fetchTablesCallCount
        let columnsFetched = mock.fetchAllColumnsCallCount

        for _ in 0..<3 {
            harness.controller.workspaces.select(harness.foreground.connectionId)
            await harness.settle(for: 0.1)
            let activations = coordinator.activationCount
            harness.controller.workspaces.select(harness.background.connectionId)
            await harness.settle { coordinator.activationCount > activations && coordinator.schemaLoadTask == nil }
            /// The column fetch is the provider's own task, started after the load returns.
            await harness.settle(for: 0.5)
        }

        #expect(coordinator.activationCount >= 4)
        #expect(mock.fetchTablesCallCount == tablesFetched)
        #expect(mock.fetchAllColumnsCallCount == columnsFetched)

        /// The control: with the autocomplete provider gone, the same switch does fetch, so the
        /// unchanged counts above were measured on a path that would have shown a reload.
        SchemaProviderRegistry.shared.clear(for: harness.backgroundConnection.id)
        harness.controller.workspaces.select(harness.foreground.connectionId)
        await harness.settle(for: 0.1)
        harness.controller.workspaces.select(harness.background.connectionId)
        await harness.settle { mock.fetchAllColumnsCallCount > columnsFetched }

        #expect(mock.fetchAllColumnsCallCount > columnsFetched)
    }

    @Test("Opening a connection fetches its columns once")
    func openingFetchesColumnsOnce() async throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let mock = harness.connectBackground()
        harness.controller.workspaces.select(harness.background.connectionId)
        let coordinator = try #require(harness.background.sessionState?.coordinator)

        await harness.settle { coordinator.isActivated && mock.fetchAllColumnsCallCount > 0 && coordinator.schemaLoadTask == nil }
        await harness.settle(for: 0.2)

        #expect(mock.fetchTablesCallCount == 1)
        #expect(mock.fetchAllColumnsCallCount == 1)
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

        func connectBackground() -> MockDatabaseDriver {
            let mock = MockDatabaseDriver(connection: backgroundConnection)
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
