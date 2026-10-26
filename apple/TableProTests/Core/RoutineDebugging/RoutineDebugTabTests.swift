//
//  RoutineDebugTabTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

// A debug tab holds a live session: every way it can go away stops that session first, and none of the app's outside surfaces see it.
@MainActor
@Suite(.serialized)
struct RoutineDebugTabTests {
    private func openDebugTab(
        in fixture: CoordinatorFixture,
        session: FakeDebugSession = FakeDebugSession(),
        drivers: DebugDriverLog = DebugDriverLog(),
        startBehavior: FakeStartBehavior = .immediate
    ) -> (tabId: UUID, controller: RoutineDebugController) {
        let (controller, _) = RoutineDebugFixtures.controller(session: session, drivers: drivers, startBehavior: startBehavior)
        let tabId = UUID()
        RoutineDebugSessions.shared.register(controller, tabId: tabId, connectionId: fixture.connection.id)
        fixture.tabManager.addRoutineDebugTab(
            id: tabId,
            title: QueryTabManager.routineDebugTitle(for: "order_total"),
            databaseName: "app",
            schemaName: "public"
        )
        return (tabId, controller)
    }

    @Test("A debug tab is titled for its routine from the moment it opens")
    func titleIsRightFromCreation() {
        let fixture = CoordinatorFixture()
        let (tabId, controller) = openDebugTab(in: fixture)
        defer { RoutineDebugSessions.shared.endSession(forTab: tabId) }

        let tab = fixture.tabManager.tabs.first { $0.id == tabId }
        #expect(tab?.tabType == .routineDebug)
        #expect(tab?.title == String(format: String(localized: "Debug %@"), "order_total"))
        #expect(fixture.tabManager.selectedTabId == tabId)
        #expect(fixture.coordinator.frontRoutineDebugController === controller)
        let payload = EditorTabPayload(connectionId: UUID(), tabType: .routineDebug, tabTitle: " ")
        #expect(!WindowTitleResolver.resolveTitle(payload: payload, databaseType: .postgresql, queryLanguageName: nil).isBlank)
    }

    @Test("Closing a debug tab stops its session and closes every driver it opened")
    func closingTheTabStopsTheSession() async throws {
        let fixture = CoordinatorFixture()
        let session = FakeDebugSession()
        let drivers = DebugDriverLog()
        let (tabId, controller) = openDebugTab(in: fixture, session: session, drivers: drivers)
        controller.start()
        try await waitUntil { controller.state.pausedLocation != nil }

        fixture.coordinator.closeTabsByUser(ids: [tabId])
        await controller.waitUntilEnded()

        #expect(session.stopCount == 1)
        #expect(drivers.openedCount == 2)
        #expect(drivers.closedCount == 2)
        #expect(RoutineDebugSessions.shared.controller(forTab: tabId) == nil)
        #expect(!RecentlyClosedTabStore.shared.entries.contains { $0.tab.id == tabId })
    }

    @Test("Closing a debug tab while its run is still starting cancels the start and closes its drivers")
    func closingTheTabWhileStarting() async throws {
        let fixture = CoordinatorFixture()
        let drivers = DebugDriverLog()
        let (tabId, controller) = openDebugTab(in: fixture, drivers: drivers, startBehavior: .untilCancelled)
        controller.start()
        try await waitUntil { drivers.openedCount == 2 }

        fixture.coordinator.closeTabsByUser(ids: [tabId])
        try await waitUntil { controller.hasEnded }

        #expect(drivers.closedCount == 2)
        #expect(!fixture.tabManager.tabs.contains { $0.id == tabId })
        guard case .stopped = controller.state else {
            Issue.record("expected stopped, got \(controller.state)")
            return
        }
    }

    @Test("Tearing the window down stops the sessions of its debug tabs")
    func teardownStopsTheSession() async throws {
        let fixture = CoordinatorFixture()
        let session = FakeDebugSession()
        let (_, controller) = openDebugTab(in: fixture, session: session)
        controller.start()
        try await waitUntil { controller.state.pausedLocation != nil }

        fixture.coordinator.teardown()
        await controller.waitUntilEnded()

        #expect(session.stopCount == 1)
    }

    @Test("Stopping a connection's sessions waits for each target to end")
    func stopAllForConnection() async throws {
        let fixture = CoordinatorFixture()
        let session = FakeDebugSession()
        let (tabId, controller) = openDebugTab(in: fixture, session: session)
        defer { RoutineDebugSessions.shared.endSession(forTab: tabId) }
        controller.start()
        try await waitUntil { controller.state.pausedLocation != nil }

        let other = UUID()
        await RoutineDebugSessions.shared.stopAll(connectionId: other)
        RoutineDebugSessions.shared.reopenAdmission(for: other)
        #expect(session.stopCount == 0)
        await RoutineDebugSessions.shared.stopAll(connectionId: fixture.connection.id)
        RoutineDebugSessions.shared.reopenAdmission(for: fixture.connection.id)

        #expect(session.stopCount == 1)
        #expect(controller.hasEnded)
    }

    @Test("Turning the module off closes every debug tab and stops its session")
    func moduleOffClosesDebugTabs() async throws {
        let fixture = CoordinatorFixture()
        fixture.coordinator.registerEagerly()
        let session = FakeDebugSession()
        let (tabId, controller) = openDebugTab(in: fixture, session: session)
        controller.start()
        try await waitUntil { controller.state.pausedLocation != nil }
        try #require(!AppModuleSettings.shared.isEnabled(.routineDebugger))

        NotificationCenter.default.post(name: .appModulesDidChange, object: AppModule.routineDebugger)
        try await waitUntil { !fixture.tabManager.tabs.contains { $0.id == tabId } }
        await controller.waitUntilEnded()

        #expect(session.stopCount == 1)
        #expect(RoutineDebugSessions.shared.controller(forTab: tabId) == nil)
    }

    @Test("A debug tab refuses a move to another connection")
    func debugTabRefusesAMove() {
        let fixture = CoordinatorFixture()
        let (tabId, _) = openDebugTab(in: fixture)
        defer { RoutineDebugSessions.shared.endSession(forTab: tabId) }

        #expect(!fixture.coordinator.canMoveTabToConnection(tabId))
    }

    @Test("A debug tab is never written with the connection's tabs")
    func debugTabIsNotPersisted() async {
        let persistence = TabPersistenceCoordinator(connectionId: UUID())
        persistence.markObservedTabs()
        defer { TabDiskActor.clearSync(connectionId: persistence.connectionId) }
        let query = QueryTab(title: "Query 1", query: "SELECT 1", tabType: .query)
        let debug = QueryTab(title: "Debug order_total", tabType: .routineDebug)

        persistence.saveNowSync(tabs: [query, debug], selectedTabId: debug.id)
        let state = await TabDiskActor.shared.load(connectionId: persistence.connectionId)

        #expect(state?.tabs.map { $0.id } == [query.id])
        #expect(state?.selectedTabId == query.id)
    }

    @Test("A window holding only a debug tab writes nothing over the saved tabs")
    func onlyDebugTabWritesNothing() async {
        let persistence = TabPersistenceCoordinator(connectionId: UUID())
        persistence.markObservedTabs()
        defer { TabDiskActor.clearSync(connectionId: persistence.connectionId) }

        persistence.saveNowSync(tabs: [QueryTab(title: "Debug f", tabType: .routineDebug)], selectedTabId: nil)

        #expect(await TabDiskActor.shared.load(connectionId: persistence.connectionId) == nil)
    }

    @Test("Closing the last saved tab while a debug tab stays open clears the saved tabs")
    func closingLastSavedTabBesideDebugTabClears() async {
        let fixture = CoordinatorFixture()
        fixture.coordinator.registerEagerly()
        fixture.coordinator.persistence.markObservedTabs()
        defer { TabDiskActor.clearSync(connectionId: fixture.connection.id) }
        let query = fixture.addTab(QueryTab(title: "Query 1", query: "SELECT 1", tabType: .query))
        fixture.coordinator.persistence.saveNowSync(tabs: [query], selectedTabId: query.id)
        let (tabId, _) = openDebugTab(in: fixture)
        defer { RoutineDebugSessions.shared.endSession(forTab: tabId) }

        fixture.coordinator.closeTabsByUser(ids: [query.id])

        #expect(await TabDiskActor.shared.load(connectionId: fixture.connection.id) == nil)
    }

    @Test("MCP clients never see a debug tab")
    func debugTabIsLeftOutOfMCPSnapshots() {
        let fixture = CoordinatorFixture()
        fixture.coordinator.registerEagerly()
        let query = fixture.addTab(QueryTab(title: "Query 1", query: "SELECT 1", tabType: .query))
        let (tabId, _) = openDebugTab(in: fixture)
        defer { RoutineDebugSessions.shared.endSession(forTab: tabId) }

        let snapshots = MCPTabSnapshotProvider.collectTabSnapshots()

        #expect(snapshots.contains { $0.tabId == query.id })
        #expect(!snapshots.contains { $0.tabId == tabId })
    }

    @Test("AppleScript has no tab kind for a debug tab")
    func debugTabHasNoScriptingKind() {
        let tab = QueryTab(title: "Debug f", tabType: .routineDebug)

        #expect(ScriptEnumerations.code(for: .routineDebug) == nil)
        #expect(ScriptTab(tab: tab, connectionId: UUID(), container: nil) == nil)
    }

    @Test("The debugger dials its dedicated drivers on the frozen database with no query timeout")
    func liveSourceOpensWithoutQueryTimeout() async throws {
        let requested = TimeoutLog()
        let plugin = FakeDebugDriver()
        let connectionId = UUID()
        let source = RoutineDebugSessionSource.live(
            scope: DatabaseScope(connectionId: connectionId, database: "sales", schema: nil),
            generation: RoutineDebugSessions.shared.admissionGeneration(for: connectionId)
        ) { scope, timeout in
            requested.record(timeout, database: scope.database)
            return PluginDriverAdapter(connection: TestFixtures.makeConnection(), pluginDriver: plugin)
        }

        let driver = try await source.openSession()
        await source.closeAll()

        #expect(requested.values == [0])
        #expect(requested.databases == ["sales"])
        #expect(driver === plugin)
    }

    @Test("Debug… from a sidebar row keeps that row's database and schema, not the one being browsed")
    func sidebarPickKeepsTheRowsDatabase() {
        let fixture = CoordinatorFixture()
        let routine = RoutineInfo(name: "order_total", kind: .function, schema: "public", identity: "16431")

        let pick = fixture.coordinator.routineDebugPick(
            for: RoutineDebugFixtures.target,
            routine: routine,
            database: "sales",
            schema: "reporting"
        )

        #expect(fixture.coordinator.browseDatabaseName != "sales")
        #expect(pick?.scope.database == "sales")
        #expect(pick?.scope.schema == "reporting")
        #expect(pick?.scope.connectionId == fixture.connection.id)
    }

    @Test("A debug tab stays in sight when the sidebar moves to another database, and keeps the database it runs in")
    func debugTabStaysVisibleAcrossContainers() {
        let manager = QueryTabManager(containerTarget: .database, visibleContainer: "sales")
        var query = QueryTab(title: "Query 1", query: "SELECT 1", tabType: .query)
        query.tableContext.databaseName = "sales"
        manager.tabs.append(query)
        let debugId = manager.addRoutineDebugTab(title: "Debug order_total", databaseName: "sales", schemaName: "public")

        manager.show(container: "hr")

        #expect(manager.visibleTabs.map { $0.id } == [debugId])
        #expect(manager.tabs.first { $0.id == debugId }?.tableContext.databaseName == "sales")
        manager.show(container: "sales")
        #expect(Set(manager.visibleTabs.map { $0.id }) == [query.id, debugId])
    }

    @Test("A payload never opens a debug tab, which needs a live session")
    func payloadOpensNoDebugTab() {
        let manager = QueryTabManager()
        let payload = EditorTabPayload(connectionId: UUID(), tabType: .routineDebug, tabTitle: "Debug f")

        EditorTabOpener.apply(payload, to: manager, connection: TestFixtures.makeConnection(), toolbarState: nil)

        #expect(manager.tabs.isEmpty)
    }
}

private final class TimeoutLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int] = []
    private var dialed: [String] = []

    var values: [Int] { lock.withLock { recorded } }
    var databases: [String] { lock.withLock { dialed } }

    func record(_ timeout: Int, database: String) {
        lock.withLock {
            recorded.append(timeout)
            dialed.append(database)
        }
    }
}
