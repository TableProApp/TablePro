//
//  HistoryPanelViewModelTests.swift
//  TableProTests
//

import Combine
import Foundation
@testable import TablePro
import Testing

private actor RecordingHistoryReader: QueryHistoryReading {
    var storeIsAvailable = true

    func isStoreAvailable() -> Bool { storeIsAvailable }

    func setStoreAvailable(_ available: Bool) { storeIsAvailable = available }

    private var entries: [QueryHistoryEntry]
    private(set) var receivedFilters: [QueryHistoryFilter] = []
    private(set) var clearCalls: [QueryHistoryFilter] = []

    init(entries: [QueryHistoryEntry]) {
        self.entries = entries.sorted { lhs, rhs in
            if lhs.executedAt != rhs.executedAt { return lhs.executedAt > rhs.executedAt }
            return lhs.id.uuidString > rhs.id.uuidString
        }
    }

    func fetch(_ filter: QueryHistoryFilter, after cursor: QueryHistoryCursor?, limit: Int) -> QueryHistoryPage {
        receivedFilters.append(filter)

        var matching = entries.filter { entry in
            if let connectionId = filter.scope.connectionId, entry.connectionId != connectionId { return false }
            if !filter.sources.contains(entry.source) { return false }
            switch filter.outcome {
            case .any: break
            case .succeeded where !entry.wasSuccessful: return false
            case .failed where entry.wasSuccessful: return false
            default: break
            }
            if let searchText = filter.searchText, !entry.query.localizedCaseInsensitiveContains(searchText) {
                return false
            }
            if let since = filter.since, entry.executedAt < since { return false }
            return true
        }

        if let cursor {
            matching = matching.filter { entry in
                entry.executedAt < cursor.executedAt
                    || (entry.executedAt == cursor.executedAt && entry.id.uuidString < cursor.id.uuidString)
            }
        }

        let page = Array(matching.prefix(limit))
        let hasMore = matching.count > limit
        return QueryHistoryPage(entries: page, nextCursor: hasMore ? page.last?.cursor : nil)
    }

    func delete(id: UUID) -> Bool {
        let before = entries.count
        entries.removeAll { $0.id == id }
        return entries.count < before
    }

    func clear(matching filter: QueryHistoryFilter) -> Bool {
        clearCalls.append(filter)
        entries.removeAll { entry in
            if let connectionId = filter.scope.connectionId, entry.connectionId != connectionId { return false }
            if !filter.sources.contains(entry.source) { return false }
            switch filter.outcome {
            case .any: break
            case .succeeded where !entry.wasSuccessful: return false
            case .failed where entry.wasSuccessful: return false
            default: break
            }
            if let searchText = filter.searchText, !entry.query.localizedCaseInsensitiveContains(searchText) {
                return false
            }
            if let since = filter.since, entry.executedAt < since { return false }
            return true
        }
        return true
    }

    func count(scope: QueryHistoryScope) -> Int {
        entries.filter { scope.connectionId == nil || $0.connectionId == scope.connectionId }.count
    }

    func lastFilter() -> QueryHistoryFilter? { receivedFilters.last }

    func fetchCount() -> Int { receivedFilters.count }
}

@Suite("HistoryPanelViewModel", .serialized)
@MainActor
struct HistoryPanelViewModelTests {
    private static func makeEntry(
        connectionId: UUID,
        query: String = "SELECT 1",
        source: QueryHistorySource = .editor,
        wasSuccessful: Bool = true,
        executedAt: Date = Date()
    ) -> QueryHistoryEntry {
        QueryHistoryEntry(
            query: query,
            connectionId: connectionId,
            databaseName: "db",
            databaseType: .postgresql,
            source: source,
            executedAt: executedAt,
            executionTime: 0.01,
            rowCount: 1,
            wasSuccessful: wasSuccessful
        )
    }

    private func makeViewModel(
        connectionId: UUID,
        entries: [QueryHistoryEntry],
        pageSize: Int = 10
    ) -> (HistoryPanelViewModel, RecordingHistoryReader) {
        HistoryPanelState.removeConnection(connectionId)
        HistoryPanelPreferencesStorage.remove(for: connectionId)
        let reader = RecordingHistoryReader(entries: entries)
        let viewModel = HistoryPanelViewModel(
            connectionId: connectionId,
            history: reader,
            connectionDirectory: .none,
            pageSize: pageSize
        )
        return (viewModel, reader)
    }

    /// The store returns the same empty page for "nothing recorded" and "could not read", so a
    /// corrupt or unwritable database told the user their history was empty and kept saying so.
    @Test("an unreadable store is reported, not shown as an empty history")
    func unreadableStoreIsReported() async {
        let connectionId = UUID()
        let (viewModel, reader) = makeViewModel(connectionId: connectionId, entries: [])

        await viewModel.reload()
        #expect(!viewModel.isStoreUnavailable, "An empty but readable store is simply empty")
        #expect(viewModel.isEmpty)

        await reader.setStoreAvailable(false)
        await viewModel.reload()

        #expect(viewModel.isStoreUnavailable)
        #expect(viewModel.isEmpty)
    }

    /// The drawer is collapsed rather than removed, so `onDisappear` never fires and nothing was
    /// left to stop the live refresh. Every recorded statement then woke a panel nobody could see.
    @Test("a deactivated panel stops refetching when history changes")
    func deactivatedPanelStopsRefetching() async throws {
        let connectionId = UUID()
        let (viewModel, reader) = makeViewModel(
            connectionId: connectionId,
            entries: [Self.makeEntry(connectionId: connectionId, query: "SELECT 1")]
        )

        await viewModel.activate()
        #expect(viewModel.isObserving)
        let afterActivate = await reader.fetchCount()

        AppEvents.shared.queryHistoryDidUpdate.send(connectionId)
        let refetched = await Self.waitForFetchCount(above: afterActivate, in: reader)
        #expect(refetched, "A visible panel refreshes when a query is recorded")
        let whileVisible = await reader.fetchCount()

        viewModel.deactivate()
        #expect(!viewModel.isObserving)

        AppEvents.shared.queryHistoryDidUpdate.send(connectionId)
        try await Task.sleep(for: .milliseconds(600))
        #expect(
            await reader.fetchCount() == whileVisible,
            "A panel nobody can see must not go back to the store"
        )
    }

    private static func waitForFetchCount(
        above baseline: Int,
        in reader: RecordingHistoryReader
    ) async -> Bool {
        for _ in 0..<40 {
            if await reader.fetchCount() > baseline { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @Test("the panel scopes to its own connection by default")
    func defaultScopeIsOwnConnection() async {
        let mine = UUID()
        let theirs = UUID()
        let (viewModel, reader) = makeViewModel(
            connectionId: mine,
            entries: [
                Self.makeEntry(connectionId: mine, query: "SELECT mine"),
                Self.makeEntry(connectionId: theirs, query: "SELECT theirs")
            ]
        )

        await viewModel.reload()

        #expect(await reader.lastFilter()?.scope == .connection(mine))
        let queries = viewModel.sections.flatMap(\.entries).map(\.query)
        #expect(queries == ["SELECT mine"])
    }

    @Test("switching to all connections widens the scope")
    func allConnectionsWidensScope() async {
        let mine = UUID()
        let theirs = UUID()
        let (viewModel, reader) = makeViewModel(
            connectionId: mine,
            entries: [
                Self.makeEntry(connectionId: mine, query: "SELECT mine"),
                Self.makeEntry(connectionId: theirs, query: "SELECT theirs")
            ]
        )

        viewModel.state.showsAllConnections = true
        await viewModel.reload()

        #expect(await reader.lastFilter()?.scope == .all)
        #expect(viewModel.sections.flatMap(\.entries).count == 2)
    }

    @Test("app-generated statements are hidden until asked for")
    func generatedSourcesHiddenByDefault() async {
        let connectionId = UUID()
        let (viewModel, _) = makeViewModel(
            connectionId: connectionId,
            entries: [
                Self.makeEntry(connectionId: connectionId, query: "SELECT typed", source: .editor),
                Self.makeEntry(connectionId: connectionId, query: "SELECT browsed", source: .tableBrowse)
            ]
        )

        await viewModel.reload()
        #expect(viewModel.sections.flatMap(\.entries).map(\.query) == ["SELECT typed"])

        viewModel.state.sources = Set(QueryHistorySource.allCases)
        await viewModel.reload()
        #expect(viewModel.sections.flatMap(\.entries).count == 2)
    }

    @Test("the connection column stays hidden while scoped to one connection")
    func connectionColumnHiddenWhenSingleScoped() async {
        let connectionId = UUID()
        let entry = Self.makeEntry(connectionId: connectionId)
        let (viewModel, _) = makeViewModel(connectionId: connectionId, entries: [entry])

        await viewModel.reload()
        #expect(viewModel.state.showsConnectionColumn == false)
        #expect(viewModel.connectionLabel(for: entry) == nil)

        viewModel.state.showsAllConnections = true
        #expect(viewModel.state.showsConnectionColumn)
    }

    @Test("load more appends the next page without repeating rows")
    func loadMoreAppendsWithoutDuplicates() async {
        let connectionId = UUID()
        let base = Date()
        let entries = (0 ..< 25).map { index in
            Self.makeEntry(
                connectionId: connectionId,
                query: "SELECT page_\(index)",
                executedAt: base.addingTimeInterval(-Double(index))
            )
        }
        let (viewModel, _) = makeViewModel(connectionId: connectionId, entries: entries, pageSize: 10)

        await viewModel.reload()
        #expect(viewModel.totalLoaded == 10)
        #expect(viewModel.hasMore)

        await viewModel.loadMore()
        #expect(viewModel.totalLoaded == 20)

        await viewModel.loadMore()
        #expect(viewModel.totalLoaded == 25)
        #expect(viewModel.hasMore == false)

        let queries = viewModel.sections.flatMap(\.entries).map(\.query)
        #expect(Set(queries).count == 25)
    }

    @Test("a live refresh keeps the pages the user already loaded")
    func liveRefreshKeepsLoadedPages() async {
        let connectionId = UUID()
        let base = Date()
        let entries = (0 ..< 40).map { index in
            Self.makeEntry(
                connectionId: connectionId,
                query: "SELECT page_\(index)",
                executedAt: base.addingTimeInterval(-Double(index))
            )
        }
        let (viewModel, _) = makeViewModel(connectionId: connectionId, entries: entries, pageSize: 10)

        await viewModel.reload()
        await viewModel.loadMore()
        await viewModel.loadMore()
        #expect(viewModel.totalLoaded == 30)

        await viewModel.reload(preservingLoadedWindow: true)

        #expect(
            viewModel.totalLoaded == 30,
            "A query finishing while the drawer is open must not throw away Load More"
        )
    }

    @Test("changing a filter starts the list over")
    func filterChangeResetsPaging() async {
        let connectionId = UUID()
        let base = Date()
        let entries = (0 ..< 40).map { index in
            Self.makeEntry(
                connectionId: connectionId,
                query: "SELECT page_\(index)",
                executedAt: base.addingTimeInterval(-Double(index))
            )
        }
        let (viewModel, _) = makeViewModel(connectionId: connectionId, entries: entries, pageSize: 10)

        await viewModel.reload()
        await viewModel.loadMore()
        #expect(viewModel.totalLoaded == 20)

        await viewModel.reload()
        #expect(viewModel.totalLoaded == 10, "A new question does not inherit the old scroll depth")
    }

    @Test("load more stops when there is nothing further")
    func loadMoreStopsAtTheEnd() async {
        let connectionId = UUID()
        let (viewModel, _) = makeViewModel(
            connectionId: connectionId,
            entries: [Self.makeEntry(connectionId: connectionId)],
            pageSize: 10
        )

        await viewModel.reload()
        #expect(viewModel.hasMore == false)

        await viewModel.loadMore()
        #expect(viewModel.totalLoaded == 1)
    }

    @Test("deleting the selected row selects its neighbour")
    func deleteMovesSelectionToNeighbour() async {
        let connectionId = UUID()
        let base = Date()
        let entries = (0 ..< 3).map { index in
            Self.makeEntry(
                connectionId: connectionId,
                query: "SELECT row_\(index)",
                executedAt: base.addingTimeInterval(-Double(index))
            )
        }
        let (viewModel, _) = makeViewModel(connectionId: connectionId, entries: entries)

        await viewModel.reload()
        let middle = viewModel.sections.flatMap(\.entries)[1]
        viewModel.selectedEntryId = middle.id

        await viewModel.delete(middle)

        #expect(viewModel.selectedEntryId != nil)
        #expect(viewModel.selectedEntryId != middle.id)
        #expect(viewModel.totalLoaded == 2)
    }

    @Test("deleting the first row selects the new first row")
    func deleteFirstRowSelectsNewFirst() async {
        let connectionId = UUID()
        let base = Date()
        let entries = (0 ..< 3).map { index in
            Self.makeEntry(
                connectionId: connectionId,
                query: "SELECT row_\(index)",
                executedAt: base.addingTimeInterval(-Double(index))
            )
        }
        let (viewModel, _) = makeViewModel(connectionId: connectionId, entries: entries)

        await viewModel.reload()
        let first = viewModel.sections.flatMap(\.entries)[0]
        viewModel.selectedEntryId = first.id

        await viewModel.delete(first)

        #expect(viewModel.selectedEntryId == viewModel.sections.flatMap(\.entries).first?.id)
        #expect(viewModel.totalLoaded == 2)
    }

    @Test("deleting the last row selects the one above it")
    func deleteLastRowSelectsPrevious() async {
        let connectionId = UUID()
        let base = Date()
        let entries = (0 ..< 3).map { index in
            Self.makeEntry(
                connectionId: connectionId,
                query: "SELECT row_\(index)",
                executedAt: base.addingTimeInterval(-Double(index))
            )
        }
        let (viewModel, _) = makeViewModel(connectionId: connectionId, entries: entries)

        await viewModel.reload()
        let loaded = viewModel.sections.flatMap(\.entries)
        let last = loaded[2]
        viewModel.selectedEntryId = last.id

        await viewModel.delete(last)

        #expect(viewModel.selectedEntryId == loaded[1].id)
        #expect(viewModel.totalLoaded == 2)
    }

    @Test("deleting a row that is not selected leaves the selection alone")
    func deleteOtherRowKeepsSelection() async {
        let connectionId = UUID()
        let base = Date()
        let entries = (0 ..< 3).map { index in
            Self.makeEntry(
                connectionId: connectionId,
                query: "SELECT row_\(index)",
                executedAt: base.addingTimeInterval(-Double(index))
            )
        }
        let (viewModel, _) = makeViewModel(connectionId: connectionId, entries: entries)

        await viewModel.reload()
        let loaded = viewModel.sections.flatMap(\.entries)
        viewModel.selectedEntryId = loaded[0].id

        await viewModel.delete(loaded[2])

        #expect(viewModel.selectedEntryId == loaded[0].id)
        #expect(viewModel.totalLoaded == 2)
    }

    @Test("deleting the only row clears the selection")
    func deleteLastRowClearsSelection() async {
        let connectionId = UUID()
        let entry = Self.makeEntry(connectionId: connectionId)
        let (viewModel, _) = makeViewModel(connectionId: connectionId, entries: [entry])

        await viewModel.reload()
        viewModel.selectedEntryId = entry.id
        await viewModel.delete(entry)

        #expect(viewModel.selectedEntryId == nil)
        #expect(viewModel.isEmpty)
    }

    @Test("clear only removes what the panel is showing")
    func clearRespectsVisibleScope() async {
        let mine = UUID()
        let theirs = UUID()
        let (viewModel, reader) = makeViewModel(
            connectionId: mine,
            entries: [
                Self.makeEntry(connectionId: mine, query: "SELECT mine"),
                Self.makeEntry(connectionId: theirs, query: "SELECT theirs")
            ]
        )

        await viewModel.reload()
        _ = await viewModel.clearVisibleScope()

        let calls = await reader.clearCalls
        #expect(calls.count == 1)
        #expect(calls.first?.scope == .connection(mine))
        #expect(await reader.count(scope: .connection(theirs)) == 1)
    }

    @Test("clear carries the date range so a narrowed view does not wipe everything")
    func clearCarriesDateRange() async {
        let connectionId = UUID()
        let (viewModel, reader) = makeViewModel(
            connectionId: connectionId,
            entries: [Self.makeEntry(connectionId: connectionId)]
        )

        viewModel.state.dateRange = .today
        await viewModel.reload()
        _ = await viewModel.clearVisibleScope()

        let calls = await reader.clearCalls
        #expect(calls.first?.since != nil)
    }

    @Test("clearing a failures-only view keeps the queries that succeeded")
    func clearRespectsOutcomeFilter() async {
        let connectionId = UUID()
        let (viewModel, reader) = makeViewModel(
            connectionId: connectionId,
            entries: [
                Self.makeEntry(connectionId: connectionId, query: "SELECT good", wasSuccessful: true),
                Self.makeEntry(connectionId: connectionId, query: "SELECT bad", wasSuccessful: false)
            ]
        )

        viewModel.state.outcome = .failed
        await viewModel.reload()
        #expect(viewModel.totalLoaded == 1)

        _ = await viewModel.clearVisibleScope()

        #expect(await reader.clearCalls.first?.outcome == .failed)
        viewModel.state.outcome = .any
        await viewModel.reload()
        #expect(viewModel.sections.flatMap(\.entries).map(\.query) == ["SELECT good"])
    }

    @Test("clearing a source-filtered view keeps the sources it was hiding")
    func clearRespectsSourceFilter() async {
        let connectionId = UUID()
        let (viewModel, reader) = makeViewModel(
            connectionId: connectionId,
            entries: [
                Self.makeEntry(connectionId: connectionId, query: "SELECT typed", source: .editor),
                Self.makeEntry(connectionId: connectionId, query: "SELECT browsed", source: .tableBrowse)
            ]
        )

        await viewModel.reload()
        _ = await viewModel.clearVisibleScope()

        #expect(await reader.clearCalls.first?.sources == QueryHistorySource.userAuthored)
        viewModel.state.sources = Set(QueryHistorySource.allCases)
        await viewModel.reload()
        #expect(viewModel.sections.flatMap(\.entries).map(\.query) == ["SELECT browsed"])
    }

    @Test("clearing a searched view keeps the rows the search was hiding")
    func clearRespectsSearchText() async {
        let connectionId = UUID()
        let (viewModel, reader) = makeViewModel(
            connectionId: connectionId,
            entries: [
                Self.makeEntry(connectionId: connectionId, query: "SELECT alpha"),
                Self.makeEntry(connectionId: connectionId, query: "SELECT beta")
            ]
        )

        viewModel.state.searchText = "alpha"
        await viewModel.reload()
        _ = await viewModel.clearVisibleScope()

        #expect(await reader.clearCalls.first?.searchText == "alpha")
        viewModel.state.searchText = ""
        await viewModel.reload()
        #expect(viewModel.sections.flatMap(\.entries).map(\.query) == ["SELECT beta"])
    }

    @Test("search text reaches the filter and a blank search does not")
    func searchTextReachesFilter() async {
        let connectionId = UUID()
        let (viewModel, reader) = makeViewModel(
            connectionId: connectionId,
            entries: [
                Self.makeEntry(connectionId: connectionId, query: "SELECT alpha"),
                Self.makeEntry(connectionId: connectionId, query: "SELECT beta")
            ]
        )

        viewModel.state.searchText = "alpha"
        await viewModel.reload()
        #expect(await reader.lastFilter()?.searchText == "alpha")
        #expect(viewModel.sections.flatMap(\.entries).map(\.query) == ["SELECT alpha"])

        viewModel.state.searchText = "   "
        await viewModel.reload()
        #expect(await reader.lastFilter()?.searchText == nil)
        #expect(viewModel.totalLoaded == 2)
    }

    @Test("an untouched panel does not report itself as filtered")
    func defaultFilterIsNotNarrowing() async {
        let connectionId = UUID()
        let (viewModel, _) = makeViewModel(connectionId: connectionId, entries: [])

        #expect(viewModel.state.sources == QueryHistorySource.userAuthored)
        #expect(
            viewModel.state.hasNarrowingFilter == false,
            "A connection with no history must offer the empty state, not 'no matches, reset filters'"
        )
    }

    @Test("filter state reports whether it is narrowing the view")
    func narrowingFilterIsReported() async {
        let connectionId = UUID()
        let (viewModel, _) = makeViewModel(connectionId: connectionId, entries: [])

        viewModel.state.dateRange = .today
        #expect(viewModel.state.hasNarrowingFilter)

        viewModel.state.resetFilters()
        #expect(viewModel.state.hasNarrowingFilter == false)

        viewModel.state.outcome = .failed
        #expect(viewModel.state.hasNarrowingFilter)

        viewModel.state.resetFilters()
        viewModel.state.searchText = "users"
        #expect(viewModel.state.hasNarrowingFilter)

        viewModel.state.resetFilters()
        viewModel.state.sources = Set(QueryHistorySource.allCases)
        #expect(viewModel.state.hasNarrowingFilter)

        viewModel.state.resetFilters()
        #expect(viewModel.state.dateRange == .all)
        #expect(viewModel.state.outcome == .any)
        #expect(viewModel.state.sources == QueryHistorySource.userAuthored)
        #expect(viewModel.state.searchText.isEmpty)
    }
}
