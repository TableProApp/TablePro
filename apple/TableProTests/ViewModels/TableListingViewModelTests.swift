// A listing tab loads its own rows over a metadata connection; these pin what a refresh, a failure and a late answer leave.

import AppKit
import Combine
import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

private enum ListingReply: Sendable {
    case names([String])
    // One page of a listing the driver answers in pages, the way Redis answers `SCAN`.
    case page([String], status: String?)
    case failure(any Error)
}

private struct ListingRefused: Error, LocalizedError {
    var errorDescription: String? { "permission denied for view pg_stat_user_tables" }
}

// The driver runs off the main actor, so the log is locked rather than isolated.
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

// Can hold the next read until the test releases it, the way a driver blocked on the wire holds one.
@MainActor
private final class ScriptedListingProvider: ScopedMetadataProviding {
    private let connection: DatabaseConnection
    private let log = ListingQueryLog()
    private let pluginListsTables: Bool
    private let nameColumn: String
    private var replies: [ListingReply] = []
    private var nextHold: (reached: AsyncGate, release: AsyncGate)?
    private(set) var requestedScopes: [DatabaseScope] = []

    init(connection: DatabaseConnection, pluginListsTables: Bool = true, nameColumn: String = "name") {
        self.connection = connection
        self.pluginListsTables = pluginListsTables
        self.nameColumn = nameColumn
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
            let driver = ListingPluginDriver(names: names, listsTables: pluginListsTables, log: log, column: nameColumn)
            return try await body(PluginDriverAdapter(connection: connection, pluginDriver: driver))
        case .page(let names, let status):
            let driver = ListingPluginDriver(
                names: names, listsTables: pluginListsTables, log: log, isPartial: true, status: status, column: nameColumn
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

private struct ObjectSourceRequest: Equatable {
    let category: SidebarObjectCategory
    let scope: DatabaseScope
    let rereading: Bool
}

// Answers the way the sidebar's service does, and can hold a read until the test releases it.
@MainActor
private final class ScriptedObjectSource: CatalogObjectListSource {
    var reply: MetadataFetchOutcome<CatalogObjectList> = .fetched(.routines([]))
    // Taken in order before `reply`, for a read that answers differently the next time.
    var replies: [MetadataFetchOutcome<CatalogObjectList>] = []
    private(set) var requests: [ObjectSourceRequest] = []
    private var nextHold: (reached: AsyncGate, release: AsyncGate)?

    func holdNextRead() -> (reached: AsyncGate, release: AsyncGate) {
        let hold = (reached: AsyncGate(), release: AsyncGate())
        nextHold = hold
        return hold
    }

    func objects(
        _ category: SidebarObjectCategory,
        in scope: DatabaseScope,
        rereading: Bool
    ) async -> MetadataFetchOutcome<CatalogObjectList> {
        requests.append(ObjectSourceRequest(category: category, scope: scope, rereading: rereading))
        let reply = replies.isEmpty ? reply : replies.removeFirst()
        if let hold = nextHold {
            nextHold = nil
            await hold.reached.open()
            await hold.release.wait()
        }
        return reply
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
        pluginListsTables: Bool = true,
        nameColumn: String = "name",
        kind: SidebarObjectKind = .table,
        objectSource: ScriptedObjectSource? = nil,
        perform: @escaping (ObjectListingAction) -> Void = { _ in },
        onInteraction: @escaping () -> Void = {}
    ) -> (TableListingViewModel, ScriptedListingProvider) {
        let provider = ScriptedListingProvider(
            connection: connection, pluginListsTables: pluginListsTables, nameColumn: nameColumn
        )
        let viewModel = TableListingViewModel(
            tabId: tabId,
            scope: scope,
            kind: kind,
            loader: TableListingLoader(databaseType: databaseType, slot: slot),
            metadataProvider: provider,
            objectSource: objectSource ?? ScriptedObjectSource(),
            refreshRequests: refreshRequests.eraseToAnyPublisher(),
            perform: perform,
            onInteraction: onInteraction
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

    // A blocked read can finish after a newer load, and cancelling its task cannot stop it.
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

    // Coming back must run the load again, not find a spinner with nothing behind it.
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

    // A page passed off as the whole listing read as every table there is.
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

    // A refresh reaches a listing behind another tab before its view exists.
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

    // A closed tab's read can still be blocked on the wire; whatever it brings back belongs to nobody.
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

        #expect(store.model(forTab: openId, target: open.target) { open } === open)
        #expect(store.model(forTab: openId, target: open.target) { TableListingViewModel(
            tabId: openId,
            scope: scope,
            loader: TableListingLoader(databaseType: .postgresql, slot: .schema)
        ) } === open)
        #expect(store.model(forTab: closingId, target: closing.target) { closing } === closing)

        provider.answer(with: .names(["stale"]))
        let (reached, release) = provider.holdNextRead()
        let load = closing.reload()
        await reached.wait()

        store.retainTabs([openId])
        await release.open()
        await load.value

        #expect(closing.state.erased == .idle)
        #expect(store.model(forTab: openId, target: open.target) { closing } === open)
    }

    // MARK: - Grid

    private func gridNames(_ viewModel: TableListingViewModel) -> [String] {
        viewModel.grid.model.rows.rows.map { $0.values.first.flatMap { $0.asText } ?? "" }
    }

    @Test("A landed listing reaches the tab's grid")
    func listingReachesTheGrid() async {
        let (viewModel, provider) = makeViewModel()
        provider.answer(with: .names(["orders", "customers"]))

        await viewModel.reload().value

        #expect(gridNames(viewModel) == ["orders", "customers"])
        #expect(viewModel.grid.model.rowCount == 2)
        #expect(viewModel.grid.model.store.layoutScope == .ephemeral)
    }

    @Test("A header sort orders the listed tables, and the selection stays on the same table")
    func headerSortOrdersTheHeldRows() async throws {
        let (viewModel, provider) = makeViewModel()
        provider.answer(with: .names(["orders", "customers", "accounts"]))
        await viewModel.reload().value
        let model = viewModel.grid.model
        let orders = try #require(model.rowID(at: 0))
        model.selectRows([orders])

        model.setSort(SortState(columns: [SortColumn(columnIndex: 0, direction: .ascending)], source: .user))

        #expect(gridNames(viewModel) == ["accounts", "customers", "orders"])
        #expect(model.selectedRowIDs == [orders])
        #expect(model.displayIndex(of: orders) == 2)
    }

    @Test("The sort the reader chose orders the next listing too")
    func sortSurvivesARefresh() async {
        let (viewModel, provider) = makeViewModel()
        provider.answer(with: .names(["orders", "customers"]))
        await viewModel.reload().value
        let descending = SortState(columns: [SortColumn(columnIndex: 0, direction: .descending)], source: .user)
        viewModel.grid.model.setSort(descending)

        provider.answer(with: .names(["accounts", "orders", "zones"]))
        await viewModel.reload().value

        #expect(gridNames(viewModel) == ["zones", "orders", "accounts"])
        #expect(viewModel.grid.model.store.sortState == descending)
    }
    // MARK: - Other kinds

    private func functions(_ names: String...) -> CatalogObjectList {
        .routines(names.map {
            RoutineInfo(name: $0, kind: .function, schema: "sales", argumentSignature: "(integer)", returnType: "integer", language: "plpgsql")
        })
    }

    @Test("Another kind lists the sidebar's own objects of that kind and runs no listing statement")
    func otherKindsListTheSidebarObjects() async {
        let source = ScriptedObjectSource()
        source.reply = .fetched(functions("touch", "audit"))
        let (viewModel, provider) = makeViewModel(kind: .function, objectSource: source)

        await viewModel.loadIfNeeded()?.value

        #expect(names(viewModel.state) == ["touch", "audit"])
        #expect(viewModel.target == DatabaseTreeObjectGroup(database: "shop", schema: "sales", kind: .function))
        #expect(source.requests == [ObjectSourceRequest(category: .routine, scope: scope, rereading: false)])
        #expect(provider.executedQueries.isEmpty)
    }

    @Test("The first load takes the list the sidebar holds, and a refresh reads it again")
    func firstLoadTakesTheListAndRefreshRereads() async {
        let source = ScriptedObjectSource()
        source.reply = .fetched(functions("touch"))
        let (viewModel, _) = makeViewModel(kind: .function, objectSource: source)

        await viewModel.loadIfNeeded()?.value
        await viewModel.reload().value

        #expect(source.requests.map(\.rereading) == [false, true])
    }

    @Test("A refresh of another kind keeps its rows on screen until the new ones land")
    func otherKindRefreshKeepsRows() async {
        let source = ScriptedObjectSource()
        source.reply = .fetched(functions("touch"))
        let (viewModel, _) = makeViewModel(kind: .function, objectSource: source)
        await viewModel.reload().value

        source.reply = .fetched(functions("touch", "audit"))
        let (reached, release) = source.holdNextRead()
        let refresh = viewModel.reload()
        await reached.wait()
        #expect(names(viewModel.state) == ["touch"])
        #expect(viewModel.isRefreshing)

        await release.open()
        await refresh.value
        #expect(names(viewModel.state) == ["touch", "audit"])
        #expect(!viewModel.isRefreshing)
    }

    @Test("A failed read of another kind says why")
    func otherKindFailureCommitsItsMessage() async {
        let source = ScriptedObjectSource()
        source.reply = .failed("permission denied for schema sales")
        let (viewModel, _) = makeViewModel(kind: .trigger, objectSource: source)

        await viewModel.reload().value

        #expect(viewModel.state.erased == .failed("permission denied for schema sales"))
    }

    // MARK: - Filter and count

    @Test("The filter narrows the rows and the count, fetches nothing, and keeps the preview")
    func filterNarrowsRowsAndCount() async {
        var interactions = 0
        let (viewModel, provider) = makeViewModel(onInteraction: { interactions += 1 })
        provider.answer(with: .names(["orders", "order_items", "customers"]))
        await viewModel.reload().value
        #expect(viewModel.count == ObjectListingCount(shown: 3, total: 3))

        viewModel.filterText = "ORDER"

        #expect(gridNames(viewModel) == ["orders", "order_items"])
        #expect(viewModel.count == ObjectListingCount(shown: 2, total: 3))
        #expect(provider.executedQueries.count == 1)
        #expect(interactions == 1)

        viewModel.filterText = ""
        #expect(viewModel.count == ObjectListingCount(shown: 3, total: 3))
    }

    @Test("A refresh applies the filter to the rows it brings back")
    func filterSurvivesARefresh() async {
        let (viewModel, provider) = makeViewModel()
        provider.answer(with: .names(["orders", "customers"]))
        await viewModel.reload().value
        viewModel.filterText = "cust"

        provider.answer(with: .names(["orders", "customers", "customer_notes"]))
        await viewModel.reload().value

        #expect(gridNames(viewModel) == ["customers", "customer_notes"])
        #expect(viewModel.count == ObjectListingCount(shown: 2, total: 3))
    }

    @Test("A header sort keeps the preview")
    func sortKeepsThePreview() async {
        var interactions = 0
        let (viewModel, provider) = makeViewModel(onInteraction: { interactions += 1 })
        provider.answer(with: .names(["orders", "customers"]))
        await viewModel.reload().value

        viewModel.grid.model.setSort(SortState(columns: [SortColumn(columnIndex: 0, direction: .ascending)], source: .user))

        #expect(interactions == 1)
    }

    // MARK: - Row actions

    @Test("Each row of a Tables listing stands for its table in the tab's own schema")
    func tablesListingNamesItsRows() async {
        let (viewModel, provider) = makeViewModel()
        provider.answer(with: .names(["orders"]))

        await viewModel.reload().value

        #expect(viewModel.state.value?.items[.existing(0)] == .relation(name: "orders", schema: "sales", type: .table))
        #expect(viewModel.rowsNameObjects)
    }

    @Test("A double click opens the row's object and keeps the preview; the row's menu offers its commands")
    func rowOpensAndOffersItsCommands() async {
        var actions: [ObjectListingAction] = []
        var interactions = 0
        let (viewModel, provider) = makeViewModel(perform: { actions.append($0) }, onInteraction: { interactions += 1 })
        provider.answer(with: .names(["orders"]))
        await viewModel.reload().value
        let orders = ObjectListingItem.relation(name: "orders", schema: "sales", type: .table)

        viewModel.grid.gridOpenRow(.existing(0))
        let titles = viewModel.grid.gridRowMenuItems(for: [.existing(0)], clickedRow: .existing(0)).map(\.title)

        #expect(actions == [.open(orders)])
        #expect(interactions == 1)
        #expect(titles == [
            String(localized: "Open in New Tab"), String(localized: "Show Structure"), String(localized: "Copy Name"),
        ])
    }

    @Test("After a sort and a filter, a row's command acts on the object that row shows")
    func rowActionsFollowTheShownRow() async throws {
        var actions: [ObjectListingAction] = []
        let (viewModel, provider) = makeViewModel(perform: { actions.append($0) })
        provider.answer(with: .names(["orders", "customers", "order_items"]))
        await viewModel.reload().value
        viewModel.grid.model.setSort(SortState(columns: [SortColumn(columnIndex: 0, direction: .descending)], source: .user))
        viewModel.filterText = "order"

        let second = try #require(viewModel.grid.model.rowID(at: 1))
        viewModel.grid.gridOpenRow(second)

        #expect(gridNames(viewModel) == ["orders", "order_items"])
        #expect(actions == [.open(.relation(name: "order_items", schema: "sales", type: .table))])
    }

    @Test("A listing with no name column has no filter and no row commands")
    func listingWithoutNamesHasNoRowActions() async {
        var actions: [ObjectListingAction] = []
        let (viewModel, provider) = makeViewModel(
            databaseType: .redis, slot: .database, pluginListsTables: false, nameColumn: "Key",
            perform: { actions.append($0) }
        )
        provider.answer(with: .names(["session:1"]))
        await viewModel.reload().value

        viewModel.grid.gridOpenRow(.existing(0))

        #expect(!viewModel.rowsNameObjects)
        #expect(viewModel.grid.gridRowMenuItems(for: [.existing(0)], clickedRow: .existing(0)).isEmpty)
        #expect(actions.isEmpty)
    }

    // MARK: - Store

    @Test("A tab moved to another kind gets a fresh model, and the old one stops answering")
    func storeReplacesTheModelOfAnotherTarget() async {
        let store = TableListingModelStore()
        let tab = UUID()
        let (tables, provider) = makeViewModel()
        let (views, _) = makeViewModel(kind: .view)
        #expect(store.model(forTab: tab, target: tables.target) { tables } === tables)

        provider.answer(with: .names(["stale"]))
        let (reached, release) = provider.holdNextRead()
        let load = tables.reload()
        await reached.wait()

        #expect(store.model(forTab: tab, target: views.target) { views } === views)
        await release.open()
        await load.value

        #expect(tables.state.value == nil)
        #expect(store.model(forTab: tab, target: views.target) { tables } === views)
    }

    // MARK: - A read cancelled elsewhere

    // The sidebar's own reads can supersede the pane's. Nothing else is coming, so a spinner would wait forever.
    @Test("A read the sidebar keeps superseding reads once more, then offers Try Again instead of a spinner")
    func supersededReadNeverLeavesASpinner() async {
        let source = ScriptedObjectSource()
        source.replies = [.cancelled, .cancelled]
        let (viewModel, _) = makeViewModel(kind: .function, objectSource: source)

        await viewModel.loadIfNeeded()?.value

        #expect(source.requests.map(\.rereading) == [false, false])
        #expect(viewModel.state.erased == .idle)
        #expect(viewModel.wasInterrupted)
        #expect(!viewModel.isRefreshing)

        source.reply = .fetched(functions("touch"))
        await viewModel.reload().value
        #expect(names(viewModel.state) == ["touch"])
        #expect(!viewModel.wasInterrupted)
    }

    @Test("A read superseded once reads again and shows what it finds")
    func supersededReadReadsAgain() async {
        let source = ScriptedObjectSource()
        source.replies = [.cancelled]
        source.reply = .fetched(functions("touch"))
        let (viewModel, _) = makeViewModel(kind: .function, objectSource: source)

        await viewModel.loadIfNeeded()?.value

        #expect(names(viewModel.state) == ["touch"])
        #expect(source.requests.count == 2)
        #expect(!viewModel.wasInterrupted)
    }

    @Test("A cancelled refresh keeps the rows on screen and reads nothing more")
    func cancelledRefreshKeepsTheRows() async {
        let source = ScriptedObjectSource()
        source.reply = .fetched(functions("touch"))
        let (viewModel, _) = makeViewModel(kind: .function, objectSource: source)
        await viewModel.reload().value

        source.replies = [.cancelled]
        await viewModel.reload().value

        #expect(names(viewModel.state) == ["touch"])
        #expect(source.requests.count == 2)
        #expect(!viewModel.wasInterrupted)
    }

    @Test("A Tables read cancelled with nothing on screen offers Try Again, and loads again when asked")
    func cancelledTablesReadOffersTryAgain() async throws {
        let (viewModel, provider) = makeViewModel()
        provider.answer(with: .failure(CancellationError()))

        await viewModel.reload().value
        #expect(viewModel.wasInterrupted)

        provider.answer(with: .names(["customers"]))
        let again = try #require(viewModel.loadIfNeeded())
        await again.value
        #expect(names(viewModel.state) == ["customers"])
        #expect(!viewModel.wasInterrupted)
    }

    @Test("A load this tab cancelled is not an interruption: the tab is closing")
    func ownCancelIsNotAnInterruption() async {
        let (viewModel, provider) = makeViewModel()
        provider.answer(with: .names(["stale"]))
        let (reached, release) = provider.holdNextRead()
        let load = viewModel.reload()
        await reached.wait()

        viewModel.cancel()
        await release.open()
        await load.value

        #expect(!viewModel.wasInterrupted)
    }

}

private final class ListingPluginDriver: PluginDriverStub, @unchecked Sendable {
    private let names: [String]
    private let listsTables: Bool
    private let log: ListingQueryLog
    private let isPartial: Bool
    private let status: String?
    private let column: String

    init(
        names: [String],
        listsTables: Bool,
        log: ListingQueryLog,
        isPartial: Bool = false,
        status: String? = nil,
        column: String = "name"
    ) {
        self.names = names
        self.listsTables = listsTables
        self.log = log
        self.isPartial = isPartial
        self.status = status
        self.column = column
    }

    func allTablesMetadataSQL(schema: String?) -> String? {
        listsTables ? "LIST \(schema ?? "-")" : nil
    }

    func execute(query: String) async throws -> PluginQueryResult {
        log.record(query)
        return PluginQueryResult(
            columns: [column],
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
