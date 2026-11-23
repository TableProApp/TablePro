import AppKit
import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

// Every closed connection window used to stay in memory with its coordinator: the command actions'
// table binding captured the whole MainContentView, whose @State held those actions and the window.
@Suite("Connection window release", .serialized)
@MainActor
struct ConnectionWindowReleaseTests {
    private static let size = CGSize(width: 1_200, height: 800)

    @Test("A closed connection window tears its workspace down and lets go of the coordinator and actions")
    func closedWindowIsReleased() async throws {
        let connection = TestFixtures.makeConnection(name: "Release window", type: .mysql)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let released = try openAndClose(connectedTo: connection)

        try? await waitUntil { released.survivors.isEmpty }
        #expect(released.survivors.isEmpty, "Still held after the close: \(released.survivors)")
    }

    @Test("A closed window hosting two connections releases both")
    func closedWindowReleasesEveryConnection() async throws {
        let connection = TestFixtures.makeConnection(name: "Release first", type: .mysql)
        let other = TestFixtures.makeConnection(name: "Release second", type: .mysql)
        defer {
            DatabaseManager.shared.removeSession(for: connection.id)
            DatabaseManager.shared.removeSession(for: other.id)
        }

        let released = try openAndClose(connectedTo: connection, alsoHosting: other)

        try? await waitUntil { released.survivors.isEmpty }
        #expect(released.survivors.isEmpty, "Still held after the close: \(released.survivors)")
    }

    @Test("Teardown waits until the window is off screen, then empties the panes")
    func teardownRunsAfterTheWindowIsOrderedOut() async throws {
        let connection = TestFixtures.makeConnection(name: "Release order", type: .mysql)
        let fixture = try OffscreenConnectionWindow(size: Self.size, connectedTo: connection)
        defer { fixture.tearDown() }
        fixture.window.orderFront(nil)
        let detail = fixture.workspace.panes.detail
        try #require(detail.view.superview != nil)

        fixture.window.close()

        #expect(!fixture.window.isVisible)
        #expect(detail.view.superview != nil, "A pane emptied inside willClose changes a window still on screen")
        #expect(fixture.workspace.sessionState != nil)
        try await waitUntil { detail.view.superview == nil && fixture.workspace.sessionState == nil }
    }

    @Test("A workspace another window hosts by then keeps its panes and coordinator")
    func workspaceHostedElsewhereIsKept() throws {
        let harness = TwoConnectionWindow()
        defer { harness.tearDown() }
        let coordinator = try harness.coordinator(of: harness.foreground)

        TabWindowController.releaseWorkspaces([harness.foreground]) { _ in [harness.foreground] }

        #expect(harness.foreground.sessionState?.coordinator === coordinator)
        #expect(!coordinator.isTearingDown)
    }

    @Test("A connection closed out of a window that stays releases its coordinator and actions")
    func removedWorkspaceReleasesItsCoordinator() async throws {
        let harness = TwoConnectionWindow()
        defer { harness.tearDown() }
        let watched = try weakCoordinatorAndActions(of: harness.background, in: harness)
        let foreground = try harness.coordinator(of: harness.foreground)

        harness.controller.workspaces.remove(harness.background.connectionId)?.teardown()

        try await waitUntil { watched.coordinator == nil && watched.actions == nil }
        #expect(harness.foreground.sessionState?.coordinator === foreground)
        #expect(!foreground.isTearingDown)
    }

    @Test("A session that ends while its window stays lets go of its coordinator and actions")
    func endedSessionReleasesItsCoordinator() async throws {
        let harness = TwoConnectionWindow()
        defer { harness.tearDown() }
        let watched = try weakCoordinatorAndActions(of: harness.foreground, in: harness)

        DatabaseManager.shared.removeSession(for: harness.foreground.connectionId)
        harness.controller.refreshFromActiveSessions()

        #expect(harness.foreground.sessionState == nil)
        try await waitUntil { watched.coordinator == nil && watched.actions == nil }
    }

    @Test("A second teardown releases the schema provider hold once")
    func secondTeardownReleasesTheHoldOnce() throws {
        let registry = SchemaProviderRegistry()
        let fixture = CoordinatorFixture(services: .live.withSchemaProviderRegistry(registry))
        let connectionId = fixture.connection.id
        let scope = DatabaseScope(connectionId: connectionId, database: "app", schema: nil)
        registry.retain(for: connectionId)
        fixture.coordinator.markActivated()
        _ = registry.getOrCreate(for: scope)

        fixture.coordinator.teardown()
        fixture.coordinator.teardown()
        // Cancels any removal a dropped count scheduled, so the purge reads the count alone.
        _ = registry.getOrCreate(for: scope)
        registry.purgeUnused()

        #expect(registry.provider(for: scope) != nil, "The other holder's provider was dropped")
        registry.clear(for: connectionId)
    }

    @Test("Releasing the last window of a connection stops its agent session and keeps the transcript")
    func lastWindowStopsAgentSessions() async throws {
        let harness = TwoConnectionWindow()
        defer { harness.tearDown() }
        let session = harness.agentSessions.startSession(for: harness.foreground.connectionId)
        #expect(!session.status.isEnded)

        TabWindowController.releaseWorkspaces([harness.foreground]) { _ in [] }

        try await waitUntil { session.status.isEnded }
        #expect(harness.agentSessions.sessions(for: harness.foreground.connectionId).contains { $0 === session })
    }

    // MARK: - Helpers

    // The window itself is left to the memory bench: the test host keeps closed windows in its autorelease pool.
    private func openAndClose(
        connectedTo connection: DatabaseConnection,
        alsoHosting other: DatabaseConnection? = nil
    ) throws -> Released {
        let fixture = try OffscreenConnectionWindow(size: Self.size, connectedTo: connection)
        var workspaces = [fixture.workspace]
        if let other {
            var session = ConnectionSession(connection: other, driver: MockDatabaseDriver(connection: other))
            session.status = .connected
            DatabaseManager.shared.injectSession(session, for: other.id)
            let workspace = ConnectionWorkspace(
                connectionId: other.id,
                payload: nil,
                autoConnect: false,
                payloadConnection: other,
                session: nil,
                sessionState: nil,
                trailingPaneState: nil,
                phase: .connecting
            )
            fixture.split.workspaces.insert(workspace, select: false)
            fixture.split.refreshFromActiveSessions()
            workspaces.append(workspace)
        }
        fixture.window.orderFront(nil)
        let coordinator = try #require(fixture.workspace.sessionState?.coordinator)
        settle(fixture.window) { coordinator.commandActions != nil }
        let actions = try #require(coordinator.commandActions, "The content never appeared, so no actions cycle formed")
        let coordinators = try workspaces.map { try #require($0.sessionState?.coordinator) }
        let released = Released(workspaces: workspaces, coordinators: coordinators, actions: actions)
        fixture.window.close()
        return released
    }

    // Shows the workspace's content once so its actions exist, then puts the foreground back.
    private func weakCoordinatorAndActions(
        of workspace: ConnectionWorkspace,
        in harness: TwoConnectionWindow
    ) throws -> WatchedCoordinator {
        let selected = harness.controller.workspaces.selectedConnectionId
        harness.controller.workspaces.select(workspace.connectionId)
        let coordinator = try harness.coordinator(of: workspace)
        settle(harness.window) { coordinator.commandActions != nil }
        let actions = try #require(coordinator.commandActions, "The content never appeared, so no actions cycle formed")
        if let selected { harness.controller.workspaces.select(selected) }
        return WatchedCoordinator(coordinator: coordinator, actions: actions)
    }

    private func settle(_ window: NSWindow, until isSatisfied: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: 2)
        while !isSatisfied(), Date() < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
    }
}

@MainActor
private final class Released {
    let workspaces: [ConnectionWorkspace]
    private let coordinators: [WeakBox]
    weak var actions: MainContentCommandActions?

    init(workspaces: [ConnectionWorkspace], coordinators: [MainContentCoordinator], actions: MainContentCommandActions) {
        self.workspaces = workspaces
        self.coordinators = coordinators.map(WeakBox.init)
        self.actions = actions
    }

    var survivors: [String] {
        var held: [String] = []
        held += workspaces.filter { $0.sessionState != nil || $0.panes.detail.view.superview != nil }
            .map { "workspace \($0.connectionId)" }
        held += coordinators.filter { $0.value != nil }.map { _ in "coordinator" }
        if actions != nil { held.append("actions") }
        return held
    }
}

@MainActor
private final class WeakBox {
    weak var value: AnyObject?

    init(_ value: AnyObject) {
        self.value = value
    }
}

@MainActor
private final class WatchedCoordinator {
    weak var coordinator: MainContentCoordinator?
    weak var actions: MainContentCommandActions?

    init(coordinator: MainContentCoordinator, actions: MainContentCommandActions) {
        self.coordinator = coordinator
        self.actions = actions
    }
}

@MainActor
private extension AppServices {
    func withSchemaProviderRegistry(_ registry: SchemaProviderRegistry) -> AppServices {
        AppServices(
            appEvents: appEvents,
            appSettings: appSettings,
            appSettingsStorage: appSettingsStorage,
            connectionStorage: connectionStorage,
            databaseManager: databaseManager,
            pluginManager: pluginManager,
            schemaService: schemaService,
            schemaRefreshService: schemaRefreshService,
            schemaProviderRegistry: registry,
            catalogChangeService: catalogChangeService,
            sqlFavoriteManager: sqlFavoriteManager,
            favoriteTablesStorage: favoriteTablesStorage,
            favoriteDatabasesStorage: favoriteDatabasesStorage,
            tableFolderStorage: tableFolderStorage,
            aiChatStorage: aiChatStorage,
            aiKeyStorage: aiKeyStorage,
            aiAccessApprovals: aiAccessApprovals,
            groupStorage: groupStorage,
            tagStorage: tagStorage,
            sshProfileStorage: sshProfileStorage,
            credentialProfileStorage: credentialProfileStorage,
            featureAccess: featureAccess,
            syncMetadataStorage: syncMetadataStorage,
            favoritesExpansionState: favoritesExpansionState,
            linkedFolderWatcher: linkedFolderWatcher,
            queryHistoryManager: queryHistoryManager,
            dateFormattingService: dateFormattingService,
            copilotService: copilotService,
            mcpServerManager: mcpServerManager,
            syncTracker: syncTracker,
            welcomeRouter: welcomeRouter,
            telemetry: telemetry
        )
    }
}
