import Combine
import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

// History, Query Insights and the quick switcher read "every connection" as the active project's.
@MainActor
struct HistoryProjectScopeTests {
    private let connectionId = UUID()
    private let inProject: Set<UUID> = [UUID(), UUID()]

    private func panelState(project: Set<UUID>?) -> HistoryPanelState {
        HistoryPanelState.removeConnection(connectionId)
        HistoryPanelPreferencesStorage.remove(for: connectionId)
        let state = HistoryPanelState.forConnection(connectionId)
        state.projectConnectionIds = { project }
        return state
    }

    private func cleanUp() {
        HistoryPanelState.removeConnection(connectionId)
        HistoryPanelPreferencesStorage.remove(for: connectionId)
        QueryInsightsPreferencesStorage.remove(for: connectionId)
    }

    @Test("History for all connections asks for the active project's connections")
    func historyAllFollowsTheProject() {
        defer { cleanUp() }
        let state = panelState(project: inProject)
        state.showsAllConnections = true

        #expect(state.filter().scope == .all)
        #expect(state.filter().allowedConnectionIds == inProject)
    }

    @Test("In All Connections history is not narrowed, so a run whose connection is gone still shows")
    func historyAllIsOpenInAllConnections() {
        defer { cleanUp() }
        let state = panelState(project: nil)
        state.showsAllConnections = true

        #expect(state.filter().scope == .all)
        #expect(state.filter().allowedConnectionIds == nil)
    }

    @Test("History for one connection is that connection's, whatever project is active")
    func historyForOneConnectionIsNotNarrowed() {
        defer { cleanUp() }
        let state = panelState(project: inProject)
        state.showsAllConnections = false

        #expect(state.filter().scope == .connection(connectionId))
        #expect(state.filter().allowedConnectionIds == nil)
    }

    @Test("Query Insights for all connections asks for the active project's connections")
    func insightsAllFollowsTheProject() {
        defer { cleanUp() }
        let inProject = inProject
        let scoped = QueryInsightsViewModel(
            connectionId: connectionId, history: QueryHistoryManager.shared, projectConnectionIds: { inProject }
        )
        scoped.showsAllConnections = true
        #expect(scoped.makeRequest().allowedConnectionIds == inProject)

        scoped.showsAllConnections = false
        #expect(scoped.makeRequest().allowedConnectionIds == nil)

        let open = QueryInsightsViewModel(
            connectionId: connectionId, history: QueryHistoryManager.shared, projectConnectionIds: { nil }
        )
        open.showsAllConnections = true
        #expect(open.makeRequest().allowedConnectionIds == nil)
    }

    @Test("The quick switcher's queries come from the active project's connections and the panel's own")
    func quickSwitcherTargetsFollowTheProject() {
        let own = UUID()
        let member = UUID()
        let outside = UUID()
        let targets = [own: "own", member: "member", outside: "outside"]

        let scoped = QuickSwitcherViewModel.inActiveProject(targets, own: own, projectConnectionIds: [member])
        let open = QuickSwitcherViewModel.inActiveProject(targets, own: own, projectConnectionIds: nil)

        #expect(Set(scoped.keys) == [own, member])
        #expect(open == targets)
    }

    // MARK: - The scope signal

    private func historyViewModel(
        over library: ProjectLibraryFixture,
        reader: any QueryHistoryReading,
        clock: ManualClock,
        showsAll: Bool = true
    ) -> HistoryPanelViewModel {
        let state = panelState(project: nil)
        state.projectConnectionIds = { library.scope.allowedConnectionIds }
        state.showsAllConnections = showsAll
        return HistoryPanelViewModel(
            connectionId: connectionId,
            history: reader,
            connectionDirectory: .none,
            clock: clock,
            scopeChanged: library.scope.scopedSetChanged,
            appEvents: library.appEvents
        )
    }

    @Test("History for all connections reloads on a switch, a move between projects and a deleted active project")
    func historyReloadsOnTheScopeSignal() async throws {
        defer { cleanUp() }
        let library = try ProjectLibraryFixture()
        let acme = try library.projects.createProject(name: "Acme")
        let mine = library.addConnection("mine", projectId: acme.id)
        let other = library.addConnection("other")
        library.appEvents.connectionUpdated.send(nil)
        let reader = ScopeRecordingHistoryReader()
        let clock = ManualClock()
        let viewModel = historyViewModel(over: library, reader: reader, clock: clock)
        await viewModel.activate()
        defer { viewModel.deactivate() }
        #expect(await reader.fetchedScopes == [nil])

        #expect(library.connections.mutateConnections(ids: [mine.id]) { $0.name = "renamed" })
        await Self.drainMainRunLoop()
        #expect(clock.pendingSleeperCount == 0, "A library change that leaves the scope alone costs no reload")

        library.scope.setActiveProject(acme.id)
        await clock.waitUntilSleeping()
        clock.advance(by: .milliseconds(200))
        try await waitUntil { await reader.fetchedScopes.last == .some([mine.id]) }

        #expect(library.projects.moveConnections([other.id], toProject: acme.id))
        await clock.waitUntilSleeping()
        clock.advance(by: .milliseconds(200))
        try await waitUntil { await reader.fetchedScopes.last == .some([mine.id, other.id]) }

        try library.projects.deleteProject(id: acme.id)
        await clock.waitUntilSleeping()
        clock.advance(by: .milliseconds(200))
        try await waitUntil { await reader.fetchedScopes.count == 4 }
        #expect(await reader.fetchedScopes.last == .some(nil))
    }

    @Test("History for one connection ignores the scope signal")
    func historyForOneConnectionIgnoresTheScopeSignal() async throws {
        defer { cleanUp() }
        let library = try ProjectLibraryFixture()
        let acme = try library.projects.createProject(name: "Acme")
        let clock = ManualClock()
        let viewModel = historyViewModel(
            over: library, reader: ScopeRecordingHistoryReader(), clock: clock, showsAll: false
        )
        await viewModel.activate()
        defer { viewModel.deactivate() }

        library.scope.setActiveProject(acme.id)
        await Self.drainMainRunLoop()

        #expect(clock.pendingSleeperCount == 0)
    }

    @Test("History rows read for the old scope are dropped when they land after a switch")
    func historyDropsAReadStartedUnderTheOldScope() async throws {
        defer { cleanUp() }
        let library = try ProjectLibraryFixture()
        let acme = try library.projects.createProject(name: "Acme")
        let mine = library.addConnection("mine", projectId: acme.id)
        let other = library.addConnection("other")
        library.appEvents.connectionUpdated.send(nil)
        let reader = GatedHistoryReader()
        let clock = ManualClock()
        let viewModel = historyViewModel(over: library, reader: reader, clock: clock)
        let activation = Task { await viewModel.activate() }
        defer { viewModel.deactivate() }
        try await waitUntil { await reader.waitingCount == 1 }

        library.scope.setActiveProject(acme.id)
        await reader.release(with: [Self.entry("SELECT other", connectionId: other.id)])
        await activation.value
        #expect(viewModel.isEmpty, "The rows of every connection never reach a list scoped to one project")

        await clock.waitUntilSleeping()
        clock.advance(by: .milliseconds(200))
        try await waitUntil { await reader.waitingCount == 1 }
        await reader.release(with: [Self.entry("SELECT mine", connectionId: mine.id)])
        try await waitUntil { !viewModel.isEmpty }

        #expect(viewModel.sections.flatMap(\.entries).map(\.connectionId) == [mine.id])
        #expect(await reader.scopes == [nil, [mine.id]])
    }

    @Test("Query Insights for all connections reloads on a switch and on a move between projects")
    func insightsReloadOnTheScopeSignal() async throws {
        defer { cleanUp() }
        let library = try ProjectLibraryFixture()
        let acme = try library.projects.createProject(name: "Acme")
        let mine = library.addConnection("mine", projectId: acme.id)
        let other = library.addConnection("other")
        library.appEvents.connectionUpdated.send(nil)
        let reader = ScopeRecordingHistoryReader()
        let viewModel = QueryInsightsViewModel(
            connectionId: connectionId,
            history: reader,
            projectConnectionIds: { library.scope.allowedConnectionIds },
            scopeChanged: library.scope.scopedSetChanged,
            appEvents: library.appEvents
        )
        viewModel.showsAllConnections = true
        await viewModel.activate()
        defer { viewModel.deactivate() }
        let afterActivate = await reader.insightScopes.count

        #expect(library.connections.mutateConnections(ids: [mine.id]) { $0.name = "renamed" })
        library.scope.setActiveProject(acme.id)
        try await waitUntil { await reader.insightScopes.last == .some([mine.id]) }
        #expect(await reader.insightScopes.count == afterActivate + 1)

        #expect(library.projects.moveConnections([other.id], toProject: acme.id))
        try await waitUntil { await reader.insightScopes.last == .some([mine.id, other.id]) }
    }

    @Test("Query Insights figures counted for the old scope are dropped when they land after a switch")
    func insightsDropAReadStartedUnderTheOldScope() async throws {
        defer { cleanUp() }
        let library = try ProjectLibraryFixture()
        let acme = try library.projects.createProject(name: "Acme")
        let mine = library.addConnection("mine", projectId: acme.id)
        library.appEvents.connectionUpdated.send(nil)
        let reader = GatedHistoryReader()
        let viewModel = QueryInsightsViewModel(
            connectionId: connectionId,
            history: reader,
            projectConnectionIds: { library.scope.allowedConnectionIds },
            scopeChanged: library.scope.scopedSetChanged,
            appEvents: library.appEvents
        )
        viewModel.showsAllConnections = true
        let activation = Task { await viewModel.activate() }
        defer { viewModel.deactivate() }
        // Turning "all connections" on starts a read of its own, so more than one can be out.
        try await waitUntil { await reader.waitingCount >= 1 }

        library.scope.setActiveProject(acme.id)
        await reader.releaseAll()
        await activation.value
        #expect(!viewModel.hasLoadedContent, "Figures for every connection never reach a tab scoped to one project")

        try await waitUntil { await reader.scopes.last == .some([mine.id]) }
        #expect(!viewModel.hasLoadedContent)
        await reader.releaseAll()
        try await waitUntil { viewModel.hasLoadedContent }
        #expect(await reader.scopes.dropLast().allSatisfy { $0 == nil })
    }

    private static func entry(_ query: String, connectionId: UUID) -> QueryHistoryEntry {
        QueryHistoryEntry(
            query: query,
            connectionId: connectionId,
            databaseName: "testdb",
            databaseType: .postgresql,
            source: .editor,
            executedAt: Date(),
            executionTime: 0.05,
            rowCount: 1,
            wasSuccessful: true
        )
    }

    // Runs after a main-actor task an earlier send started.
    private static func drainMainRunLoop() async {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform { continuation.resume() }
        }
    }
}

private actor ScopeRecordingHistoryReader: QueryHistoryReading {
    private(set) var fetchedScopes: [Set<UUID>?] = []
    private(set) var insightScopes: [Set<UUID>?] = []

    func fetch(_ filter: QueryHistoryFilter, after cursor: QueryHistoryCursor?, limit: Int) -> QueryHistoryPage {
        fetchedScopes.append(filter.allowedConnectionIds)
        return QueryHistoryPage(entries: [], nextCursor: nil)
    }

    func delete(id: UUID) -> Bool { false }

    func clear(matching filter: QueryHistoryFilter) -> Bool { false }

    func count(scope: QueryHistoryScope) -> Int { 0 }

    func isStoreAvailable() -> Bool { true }

    func insights(_ request: QueryInsightsRequest, slowestRanking: QueryInsightsSlowestRanking) -> QueryInsightsSnapshot {
        insightScopes.append(request.allowedConnectionIds)
        return .empty
    }
}

// Holds each read until the test lets it go, so a scope change can land while one is out.
private actor GatedHistoryReader: QueryHistoryReading {
    private(set) var scopes: [Set<UUID>?] = []
    private var waiting: [CheckedContinuation<[QueryHistoryEntry], Never>] = []

    var waitingCount: Int { waiting.count }

    func release(with entries: [QueryHistoryEntry]) {
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().resume(returning: entries)
    }

    func releaseAll() {
        let held = waiting
        waiting = []
        held.forEach { $0.resume(returning: []) }
    }

    private func held(_ scope: Set<UUID>?) async -> [QueryHistoryEntry] {
        scopes.append(scope)
        return await withCheckedContinuation { waiting.append($0) }
    }

    func fetch(_ filter: QueryHistoryFilter, after cursor: QueryHistoryCursor?, limit: Int) async -> QueryHistoryPage {
        QueryHistoryPage(entries: await held(filter.allowedConnectionIds), nextCursor: nil)
    }

    func delete(id: UUID) -> Bool { false }

    func clear(matching filter: QueryHistoryFilter) -> Bool { false }

    func count(scope: QueryHistoryScope) -> Int { 0 }

    func isStoreAvailable() -> Bool { true }

    func insights(
        _ request: QueryInsightsRequest,
        slowestRanking: QueryInsightsSlowestRanking
    ) async -> QueryInsightsSnapshot {
        _ = await held(request.allowedConnectionIds)
        return .empty
    }
}

struct QueryInsightsProjectScopeTests {
    private let storage = QueryHistoryStorage(
        databaseURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("query_insights_scope_\(UUID().uuidString).db"),
        removeDatabaseOnDeinit: true
    )

    private func record(_ query: String, connectionId: UUID) async {
        _ = await storage.record(QueryHistoryEntry(
            query: query,
            connectionId: connectionId,
            databaseName: "testdb",
            databaseType: .postgresql,
            source: .editor,
            executedAt: Date(),
            executionTime: 0.05,
            rowCount: 1,
            wasSuccessful: true
        ))
    }

    @Test("Insights and history across connections count only the allowed ones")
    func allowedConnectionsNarrowTheStore() async {
        let member = UUID()
        let outside = UUID()
        await record("SELECT 1", connectionId: member)
        await record("SELECT 2 FROM other", connectionId: outside)

        let scoped = await storage.insights(
            QueryInsightsRequest(scope: .all, allowedConnectionIds: [member]), slowestRanking: .totalTime
        )
        let open = await storage.insights(QueryInsightsRequest(scope: .all), slowestRanking: .totalTime)
        let none = await storage.insights(
            QueryInsightsRequest(scope: .all, allowedConnectionIds: []), slowestRanking: .totalTime
        )
        let history = await storage.fetch(
            QueryHistoryFilter(scope: .all, allowedConnectionIds: [member]), after: nil, limit: 10
        )

        #expect(scoped.totals.totalCount == 1)
        #expect(open.totals.totalCount == 2)
        #expect(none.totals.totalCount == 0)
        #expect(history.entries.map(\.connectionId) == [member])
    }
}
