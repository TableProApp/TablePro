//
//  SavedRowsCountEffectTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct SavedRowsCountEffectTests {
    private static let threshold = 100_000

    private func effect(
        total: Int?,
        narrowsRows: Bool = false,
        showsTruncatedTable: Bool = false,
        threshold: Int = SavedRowsCountEffectTests.threshold
    ) -> SavedRowsCountEffect {
        SavedRowsCountEffect.effect(
            on: SavedRowsCountEffect.Tab(
                narrowsRows: narrowsRows, showsTruncatedTable: showsTruncatedTable, totalRowCount: total
            ),
            threshold: threshold
        )
    }

    @Test("A total at or past the threshold stays as an estimate after a save", arguments: [100_000, 200_000, 5_000_000])
    func largeTotalStaysAsAnEstimate(total: Int) {
        #expect(effect(total: total) == .estimate)
    }

    @Test("A smaller total, or none, is counted again as before", arguments: [Int?.none, 0, 900, 99_999])
    func smallTotalIsRecounted(total: Int?) {
        #expect(effect(total: total) == .retire)
    }

    @Test("A filtered tab, a truncate of the tab's table, or Always count recounts, whatever the size")
    func filterTruncateOrAlwaysCountRecounts() {
        #expect(effect(total: 5_000_000, narrowsRows: true) == .retire)
        #expect(effect(total: 5_000_000, showsTruncatedTable: true) == .retire)
        #expect(effect(total: 5_000_000, threshold: Int.max) == .retire)
    }

    @Test("A kept estimate makes the next count skip, so no capped count blanks it")
    func keptEstimateSkipsTheCount() {
        var exact = PaginationState(totalRowCount: 200_000)
        exact.keepTotalAsEstimate()
        #expect(exact.totalRowCount == 200_000)
        #expect(exact.isApproximateRowCount)
        #expect(exact.settledRowCountScope == nil)

        let plan = QueryExecutionCoordinator.rowCountPlan(
            isNonSQL: false,
            filterState: TabFilterState(),
            approximateRowCount: exact.isApproximateRowCount ? exact.totalRowCount : nil,
            threshold: Self.threshold
        )
        #expect(plan == .skip)

        var empty = PaginationState()
        empty.keepTotalAsEstimate()
        #expect(!empty.isApproximateRowCount)
    }
}
