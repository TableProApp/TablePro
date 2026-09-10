//
//  RowCountPlanTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("RowCountPlan")
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

    @Test("Non-SQL filtered defers to the driver filtered count")
    func nonSQLFiltered() {
        let state = filtered()
        let plan = QueryExecutionCoordinator.rowCountPlan(
            isNonSQL: true, filterState: state, approximateRowCount: nil, threshold: 100_000
        )
        #expect(plan == .filteredNonSQL(filters: state.appliedFilters, logicMode: state.filterLogicMode))
    }
}

@Suite("RowCountOutcome")
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
