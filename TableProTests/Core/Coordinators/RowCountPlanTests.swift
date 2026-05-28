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
        state.appliedFilters = [TestFixtures.makeTableFilter()]
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
