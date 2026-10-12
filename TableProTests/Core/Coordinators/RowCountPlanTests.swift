//
//  RowCountPlanTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct RowCountPlanTests {
    private func filtered() -> TabFilterState {
        var state = TabFilterState()
        state.filters = [TestFixtures.makeTableFilter()]
        state.commit = .all
        return state
    }

    @Test("Unfiltered small table runs an exact unfiltered count")
    func unfilteredSmall() {
        let plan = QueryExecutionCoordinator.rowCountPlan(
            isNonSQL: false, filterState: TabFilterState(), approximateRowCount: 100, threshold: 100_000
        )
        #expect(plan == .exactCount(filtered: false))
    }

    @Test("Unfiltered large table skips the exact count and keeps the estimate")
    func unfilteredLarge() {
        let plan = QueryExecutionCoordinator.rowCountPlan(
            isNonSQL: false, filterState: TabFilterState(), approximateRowCount: 5_000_000, threshold: 100_000
        )
        #expect(plan == .skip)
    }

    @Test("Unfiltered unknown size runs an exact count")
    func unfilteredUnknownSize() {
        let plan = QueryExecutionCoordinator.rowCountPlan(
            isNonSQL: false, filterState: TabFilterState(), approximateRowCount: nil, threshold: 100_000
        )
        #expect(plan == .exactCount(filtered: false))
    }

    @Test("Filtered small table runs an exact filtered count")
    func filteredSmall() {
        let plan = QueryExecutionCoordinator.rowCountPlan(
            isNonSQL: false, filterState: filtered(), approximateRowCount: 100, threshold: 100_000
        )
        #expect(plan == .exactCount(filtered: true))
    }

    @Test("Filtered large table clears the count instead of counting a huge table")
    func filteredLarge() {
        let plan = QueryExecutionCoordinator.rowCountPlan(
            isNonSQL: false, filterState: filtered(), approximateRowCount: 5_000_000, threshold: 100_000
        )
        #expect(plan == .clear)
    }

    @Test("Filtered unknown size runs an exact filtered count")
    func filteredUnknownSize() {
        let plan = QueryExecutionCoordinator.rowCountPlan(
            isNonSQL: false, filterState: filtered(), approximateRowCount: nil, threshold: 100_000
        )
        #expect(plan == .exactCount(filtered: true))
    }

    @Test("Non-SQL unfiltered uses the approximate count")
    func nonSQLUnfiltered() {
        let plan = QueryExecutionCoordinator.rowCountPlan(
            isNonSQL: true, filterState: TabFilterState(), approximateRowCount: nil, threshold: 100_000
        )
        #expect(plan == .approximate)
    }

    @Test("An engine whose count is a full scan is never counted automatically", arguments: [
        DatabaseType.dynamodb, .cassandra, .scylladb
    ])
    func fullScanEngineIsCountedOnlyOnRequest(databaseType: DatabaseType) {
        let countsAutomatically = PluginManager.shared.countsRowsAutomatically(for: databaseType)

        let unfiltered = QueryExecutionCoordinator.rowCountPlan(
            isNonSQL: false, filterState: TabFilterState(), approximateRowCount: 100, threshold: 100_000,
            countsAutomatically: countsAutomatically
        )
        let filteredPlan = QueryExecutionCoordinator.rowCountPlan(
            isNonSQL: false, filterState: filtered(), approximateRowCount: 100, threshold: 100_000,
            countsAutomatically: countsAutomatically
        )

        #expect(!countsAutomatically)
        #expect(unfiltered == .skip)
        #expect(filteredPlan == .clear)
    }

    @Test("An engine that can seek and counts cheaply is still counted automatically")
    func ordinaryEngineIsCountedAutomatically() {
        #expect(PluginManager.shared.countsRowsAutomatically(for: .postgresql))
        #expect(!PluginManager.shared.exactRowCountIsFullScan(for: .postgresql))
        #expect(PluginManager.shared.exactRowCountIsFullScan(for: .dynamodb))
        #expect(PluginManager.shared.exactRowCountIsFullScan(for: .cassandra))
        #expect(PluginManager.shared.exactRowCountIsFullScan(for: .scylladb))
    }

    /// The estimate is the whole database's key count, so on a tab narrowed by its key pattern it is
    /// never the total. The plan counts by the search instead, bounded by the database's size.
    @Test("A browse search is counted by its own scope, never by the table's estimate")
    func browseSearchCountsItsOwnScope() {
        let search = BrowseSearchState(pattern: "user:*")
        let plan = QueryExecutionCoordinator.rowCountPlan(
            isNonSQL: true, filterState: TabFilterState(), approximateRowCount: 5_000_000, threshold: 100_000,
            browseSearch: search
        )
        #expect(plan == .browseSearch(search, tableSizeLimit: 100_000))
    }

    @Test("A browse search on an engine counted only on request keeps whatever count it has")
    func browseSearchWithoutAutomaticCountSkips() {
        let plan = QueryExecutionCoordinator.rowCountPlan(
            isNonSQL: true, filterState: TabFilterState(), approximateRowCount: nil, threshold: 100_000,
            countsAutomatically: false, browseSearch: BrowseSearchState(typeScope: "hash")
        )
        #expect(plan == .skip)
    }

    @Test("A browse search narrows the rows only on an engine that runs one")
    func browseSearchNarrowsRows() {
        var state = TabFilterState()
        state.browseSearch = BrowseSearchState(pattern: "user:*")

        #expect(state.narrowsRows(browseSearchIsSupported: true))
        #expect(!state.narrowsRows(browseSearchIsSupported: false))
        #expect(state.activeBrowseSearch(isSupported: true) == BrowseSearchState(pattern: "user:*"))
        #expect(!TabFilterState().narrowsRows(browseSearchIsSupported: true))
        #expect(filtered().narrowsRows(browseSearchIsSupported: false))
    }

    @Test("Non-SQL filtered defers to the driver filtered count")
    func nonSQLFiltered() {
        let state = filtered()
        let plan = QueryExecutionCoordinator.rowCountPlan(
            isNonSQL: true, filterState: state, approximateRowCount: nil, threshold: 100_000
        )
        #expect(plan == .filteredNonSQL(filters: state.appliedFilters, logicMode: state.filterLogicMode))
    }
}

struct RowCountOutcomeTests {
    @Test("A positive estimate is applied and stays marked approximate")
    func positiveEstimateApplies() throws {
        let applied = try #require(RowCountOutcome.count(4_600_000, isApproximate: true).appliedTotal)
        #expect(applied.total == 4_600_000)
        #expect(applied.isApproximate)
    }

    /// Phase 1 has usually already put an estimate on screen by the time a phase 2 count lands, so
    /// "we could not work it out" has to leave that alone. Blanking it made a row count appear and
    /// then vanish a moment later.
    @Test("An estimate of zero is no answer, so it applies nothing")
    func zeroEstimateAppliesNothing() {
        #expect(RowCountOutcome.count(0, isApproximate: true).appliedTotal == nil)
    }

    @Test("A negative estimate applies nothing")
    func negativeEstimateAppliesNothing() {
        #expect(RowCountOutcome.count(-1, isApproximate: true).appliedTotal == nil)
    }

    @Test("An exact zero is trustworthy and reported as an empty table")
    func exactZeroIsApplied() throws {
        let applied = try #require(RowCountOutcome.count(0, isApproximate: false).appliedTotal)
        #expect(applied.total == 0)
        #expect(!applied.isApproximate)
    }

    @Test("A negative exact count applies nothing")
    func negativeExactAppliesNothing() {
        #expect(RowCountOutcome.count(-5, isApproximate: false).appliedTotal == nil)
    }

    /// A filter change genuinely invalidates the count, so this one still wipes it.
    @Test("Clearing reports an unknown total")
    func clearIsUnknown() throws {
        let applied = try #require(RowCountOutcome.clear.appliedTotal)
        #expect(applied.total == nil)
        #expect(!applied.isApproximate)
    }
}
