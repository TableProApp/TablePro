// Show All Tables used to hand the listing statement to an editor tab and run nothing. A listing tab
// now loads its own rows over a metadata connection, built from the plugin each time, so these cases
// pin what it asks for, what it commits, and what a refresh, a failure and a late answer leave behind.

import Combine
import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

private enum ListingReply: Sendable {
    case names([String])
    /// One page of a listing the driver answers in pages, the way Redis answers `SCAN`.
    case page([String], status: String?)
    case failure(any Error)
}

private struct ListingRefused: Error, LocalizedError {
    var errorDescription: String? { "permission denied for view pg_stat_user_tables" }
}

/// The statements the stub driver was asked to run. The driver runs off the main actor, so the log is
/// locked rather than isolated.
private final class ListingQueryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var queries: [String] = []

    var all: [String] {
        lock.withLock { queries }
    }

    func record(_ query: String) {
        lock.withLock { queries.append(query) }
    }
}

/// Answers each read with the next scripted reply, and can hold the next read until the test releases
/// it, the way a driver blocked on the wire holds one.
@MainActor
private final class ScriptedListingProvider: ScopedMetadataProviding {
    private let connection: DatabaseConnection
    private let log = ListingQueryLog()
    private let pluginListsTables: Bool
    private var replies: [ListingReply] = []
    private var nextHold: (reached: AsyncGate, release: AsyncGate)?
    private(set) var requestedScopes: [DatabaseScope] = []

    init(connection: DatabaseConnection, pluginListsTables: Bool = true) {
        self.connection = connection
        self.pluginListsTables = pluginListsTables
    }

    var executedQueries: [String] {
        log.all
    }

    func answer(with reply: ListingReply) {
        replies.append(reply)
    }

    func holdNextRead() -> (reached: AsyncGate, release: AsyncGate) {
        let hold = (reached: AsyncGate(), release: AsyncGate())
        nextHold = hold
        return hold
    }

    func withMetadataDriver<T: Sendable>(
        scope: DatabaseScope,
        workload: MetadataConnectionPool.Workload,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        requestedScopes.append(scope)
        let reply = replies.isEmpty ? ListingReply.names([]) : replies.removeFirst()
        if let hold = nextHold {
            nextHold = nil
            await hold.reached.open()
            await hold.release.wait()
        }
        switch reply {
        case .names(let names):
            let driver = ListingPluginDriver(names: names, listsTables: pluginListsTables, log: log)
            return try await body(PluginDriverAdapter(connection: connection, pluginDriver: driver))
        case .page(let names, let status):
            let driver = ListingPluginDriver(
                names: names, listsTables: pluginListsTables, log: log, isPartial: true, status: status
            )
            return try await body(PluginDriverAdapter(connection: connection, pluginDriver: driver))
        case .failure(let error):
            throw error
        }
    }

    func browseScope(for connectionId: UUID) -> DatabaseScope? {
        nil
    }
}

@MainActor
struct TableListingViewModelTests {
    private let connection = TestFixtures.makeConnection(database: "shop", type: .postgresql)

    private var scope: DatabaseScope {
        DatabaseScope(connectionId: connection.id, database: "shop", schema: "sales")
    }

    private let tabId = UUID()
    private let refreshRequests = PassthroughSubject<UUID, Never>()

    private func makeViewModel(
        databaseType: DatabaseType = .postgresql,
        slot: EngineNamespaceSlot = .schema,
        pluginListsTables: Bool = true
    ) -> (TableListingViewModel, ScriptedListingProvider) {
        let provider = ScriptedListingProvider(connection: connection, pluginListsTables: pluginListsTables)
        let viewModel = TableListingViewModel(
            tabId: tabId,
            scope: scope,
            loader: TableListingLoader(databaseType: databaseType, slot: slot),
            metadataProvider: provider,
            refreshRequests: refreshRequests.eraseToAnyPublisher()
        )
        return (viewModel, provider)
    }

    private func names(_ state: MetadataLoadState<TableListing>) -> [String]? {
        state.value?.rows.rows.map { row in
            row.values.first.flatMap { $0.asText } ?? ""
        }
    }

    @Test("A load lists the tab's own schema and commits the rows the server returned")
    func loadCommitsTheListing() async {
        let (viewModel, provider) = makeViewModel()
        provider.answer(with: .names(["customers", "orders"]))

        await viewModel.reload().value

        #expect(names(viewModel.state) == ["customers", "orders"])
        #expect(viewModel.state.value?.rows.columns == ["name"])
        #expect(viewModel.state.value?.isIncomplete == false)
        #expect(viewModel.state.value?.notice == nil)
        #expect(provider.requestedScopes == [scope])
        #expect(provider.executedQueries == ["LIST sales"])
    }

    @Test("The listing names the container its engine lists by", arguments: [
        (EngineNamespaceSlot.schema, "LIST sales"),
        (.database, "LIST shop"),
        (.unqualified, "LIST -")
    ])
    func containerFollowsTheSlot(slot: EngineNamespaceSlot, expected: String) async {
        let (viewModel, provider) = makeViewModel(slot: slot)

        await viewModel.reload().value

        #expect(provider.executedQueries == [expected])
    }

    @Test("Redis, with no plugin listing, runs its shell's own command")
    func shellFallbackRuns() async {
        let (viewModel, provider) = makeViewModel(databaseType: .redis, slot: .database, pluginListsTables: false)

        await viewModel.reload().value

        #expect(provider.executedQueries == ["SCAN 0 MATCH * COUNT 100"])
        #expect(viewModel.state.value != nil)
    }

    @Test("An engine with no listing at all says so instead of showing an empty grid")
    func noListingIsAFailure() async {
        let (viewModel, provider) = makeViewModel(databaseType: .cassandra, slot: .database, pluginListsTables: false)

        await viewModel.reload().value

        #expect(viewModel.state.erased == .failed(TableListingError.unavailable.localizedDescription))
        #expect(provider.executedQueries.isEmpty)
    }

    @Test("A refused listing commits the server's message")
    func failureCommitsItsMessage() async {
        let (viewModel, provider) = makeViewModel()
        provider.answer(with: .failure(ListingRefused()))

        await viewModel.reload().value

        #expect(viewModel.state.erased == .failed(ListingRefused().localizedDescription))
    }

    @Test("A refresh keeps the rows on screen until the new ones land")
    func refreshKeepsTheRows() async {
        let (viewModel, provider) = makeViewModel()
        provider.answer(with: .names(["customers"]))
        await viewModel.reload().value

        provider.answer(with: .names(["customers", "orders"]))
        let (reached, release) = provider.holdNextRead()
        let refresh = viewModel.reload()
        await reached.wait()
        #expect(names(viewModel.state) == ["customers"])

        await release.open()
        await refresh.value
        #expect(names(viewModel.state) == ["customers", "orders"])
    }

    @Test("A refresh that fails keeps the rows it was refreshing")
    func failedRefreshKeepsTheRows() async {
        let (viewModel, provider) = makeViewModel()
        provider.answer(with: .names(["customers"]))
        await viewModel.reload().value

        provider.answer(with: .failure(ListingRefused()))
        await viewModel.reload().value

        #expect(names(viewModel.state) == ["customers"])
    }

    /// A driver blocked on the wire finishes after a newer load has, and cancelling its task cannot stop
    /// it. Whatever it comes back with is older than what is on screen.
    @Test("A load a newer one superseded commits nothing, whatever it returns")
    func supersededLoadCommitsNothing() async {
        let outcomes: [ListingReply] = [.names(["stale"]), .failure(ListingRefused()), .failure(CancellationError())]
        for outcome in outcomes {
            let (viewModel, provider) = makeViewModel()
            provider.answer(with: outcome)
            provider.answer(with: .names(["fresh"]))
            let (reached, release) = provider.holdNextRead()

            let stale = viewModel.reload()
            await reached.wait()
            await viewModel.reload().value
            #expect(names(viewModel.state) == ["fresh"])

            await release.open()
            await stale.value
            #expect(names(viewModel.state) == ["fresh"], "\(outcome)")
        }
    }

    /// The pane leaving cancels the load, and coming back has to run it again rather than find a spinner
    /// with nothing behind it, or an empty grid that reads as no tables.
    @Test("A cancelled first load settles back to idle and loads again when asked")
    func cancelledLoadRunsAgain() async throws {
        let (viewModel, provider) = makeViewModel()
        provider.answer(with: .failure(CancellationError()))

        await viewModel.reload().value
        #expect(viewModel.state.erased == .idle)

        provider.answer(with: .names(["customers"]))
        let again = try #require(viewModel.loadIfNeeded())
        await again.value
        #expect(names(viewModel.state) == ["customers"])
    }

    @Test("Appearing again leaves a listing already on screen alone")
    func loadIfNeededIsIdempotent() async {
        let (viewModel, provider) = makeViewModel()
        provider.answer(with: .names(["customers"]))
        await viewModel.loadIfNeeded()?.value

        #expect(viewModel.loadIfNeeded() == nil)
        #expect(provider.executedQueries.count == 1)
    }

    /// A page passed off as the whole listing read as every table there is, and an empty first page as
    /// none at all.
    @Test("A partial listing says so, in the driver's words when it has some")
    func partialListingSaysSo() async {
        let (viewModel, provider) = makeViewModel(databaseType: .redis, slot: .database, pluginListsTables: false)
        provider.answer(with: .page(["session:1"], status: "Next cursor: 42"))
        await viewModel.reload().value
        #expect(viewModel.state.value?.isIncomplete == true)
        #expect(viewModel.state.value?.notice == "Next cursor: 42")

        provider.answer(with: .page([], status: nil))
        await viewModel.reload().value
        #expect(viewModel.state.value?.isIncomplete == true)
        #expect(viewModel.state.value?.rows.rows.isEmpty == true)
        #expect(viewModel.state.value?.notice == String(localized: "The driver returned part of the listing."))
    }

    @Test("A complete listing carries the driver's notice without calling itself partial")
    func completeListingKeepsItsNotice() {
        let listing = TableListing(rows: TableRows(), isIncomplete: false, statusMessage: "NOTICE: stats are stale")
        #expect(!listing.isIncomplete)
        #expect(listing.notice == "NOTICE: stats are stale")
        #expect(TableListing(rows: TableRows(), isIncomplete: false, statusMessage: "").notice == nil)
    }

    /// Refresh reaches a listing whose tab is not on screen too: asking again for a listing behind
    /// another tab selects it and refreshes it in the same turn, before its view exists.
    @Test("A refresh for this tab reloads it, and one for another tab does not")
    func refreshRequestReloadsOnlyThisTab() async throws {
        let (viewModel, provider) = makeViewModel()
        provider.answer(with: .names(["customers"]))
        await viewModel.reload().value

        refreshRequests.send(UUID())
        #expect(provider.executedQueries.count == 1)

        provider.answer(with: .names(["customers", "orders"]))
        refreshRequests.send(tabId)
        try await waitUntil { self.names(viewModel.state) == ["customers", "orders"] }
        #expect(provider.executedQueries.count == 2)
    }

    /// A closed tab's read can still be blocked on the wire when the tab goes. Whatever it brings back
    /// belongs to nobody.
    @Test("A cancelled load commits nothing when its read returns, and loads again when asked")
    func cancelledLoadCommitsNothing() async throws {
        let (viewModel, provider) = makeViewModel()
        provider.answer(with: .names(["stale"]))
        let (reached, release) = provider.holdNextRead()
        let load = viewModel.reload()
        await reached.wait()

        viewModel.cancel()
        #expect(viewModel.state.erased == .idle)
        await release.open()
        await load.value
        #expect(viewModel.state.erased == .idle)

        provider.answer(with: .names(["fresh"]))
        let again = try #require(viewModel.loadIfNeeded())
        await again.value
        #expect(names(viewModel.state) == ["fresh"])
    }

    @Test("The store keeps a tab's model while the tab is open, and cancels it when the tab closes")
    func storeKeepsAndReleasesModels() async {
        let store = TableListingModelStore()
        let (open, _) = makeViewModel()
        let (closing, provider) = makeViewModel()
        let openId = UUID()
        let closingId = UUID()

        #expect(store.model(forTab: openId) { open } === open)
        #expect(store.model(forTab: openId) { TableListingViewModel(
            tabId: openId,
            scope: scope,
            loader: TableListingLoader(databaseType: .postgresql, slot: .schema)
        ) } === open)
        #expect(store.model(forTab: closingId) { closing } === closing)

        provider.answer(with: .names(["stale"]))
        let (reached, release) = provider.holdNextRead()
        let load = closing.reload()
        await reached.wait()

        store.retainTabs([openId])
        await release.open()
        await load.value

        #expect(closing.state.erased == .idle)
        #expect(store.model(forTab: openId) { closing } === open)
    }
}

private final class ListingPluginDriver: PluginDriverStub, @unchecked Sendable {
    private let names: [String]
    private let listsTables: Bool
    private let log: ListingQueryLog
    private let isPartial: Bool
    private let status: String?

    init(names: [String], listsTables: Bool, log: ListingQueryLog, isPartial: Bool = false, status: String? = nil) {
        self.names = names
        self.listsTables = listsTables
        self.log = log
        self.isPartial = isPartial
        self.status = status
    }

    func allTablesMetadataSQL(schema: String?) -> String? {
        listsTables ? "LIST \(schema ?? "-")" : nil
    }

    func execute(query: String) async throws -> PluginQueryResult {
        log.record(query)
        return PluginQueryResult(
            columns: ["name"],
            columnTypeNames: ["TEXT"],
            rows: names.map { [.text($0)] },
            rowsAffected: 0,
            executionTime: 0,
            isTruncated: isPartial,
            statusMessage: status
        )
    }

    func ping() async throws {}
}
