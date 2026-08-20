import Foundation
import Testing

@testable import TablePro

@Suite("HistoryClearSummary")
struct HistoryClearSummaryTests {
    private let everySource = Set(QueryHistorySource.allCases)

    /// The panel opens filtered to the user's own queries, so the default state already hides five
    /// of the seven sources. Calling that "unfiltered" is what made the old message promise a wipe
    /// it never performed.
    @Test("The panel's own default source filter counts as hiding queries")
    func defaultSourceFilterHidesQueries() {
        #expect(
            HistoryClearSummary.hidesRecordedQueries(
                sources: QueryHistorySource.userAuthored,
                outcome: .any,
                dateRange: .all,
                searchText: ""
            )
        )
    }

    @Test("Nothing is hidden only when every filter is wide open")
    func nothingHiddenWithEveryFilterOpen() {
        #expect(
            !HistoryClearSummary.hidesRecordedQueries(
                sources: everySource,
                outcome: .any,
                dateRange: .all,
                searchText: "   "
            )
        )
    }

    @Test("An outcome, a date range or a search each count as hiding queries", arguments: [0, 1, 2])
    func eachNarrowingCounts(_ which: Int) {
        let hidden = HistoryClearSummary.hidesRecordedQueries(
            sources: everySource,
            outcome: which == 0 ? .failed : .any,
            dateRange: which == 1 ? .week : .all,
            searchText: which == 2 ? "customers" : ""
        )
        #expect(hidden)
    }

    @Test("A wide open filter promises the whole connection")
    func unfilteredMessageNamesTheConnection() {
        let message = HistoryClearSummary.message(
            showsAllConnections: false,
            sources: everySource,
            outcome: .any,
            dateRange: .all,
            searchText: ""
        )

        #expect(message.contains("this connection's query history"))
        #expect(!message.contains("only the queries listed here"))
    }

    @Test("A narrowed filter says only what is listed goes")
    func narrowedMessageSaysOnlyWhatIsListed() {
        let message = HistoryClearSummary.message(
            showsAllConnections: false,
            sources: QueryHistorySource.userAuthored,
            outcome: .any,
            dateRange: .all,
            searchText: ""
        )

        #expect(message.contains("only the queries listed here"))
        #expect(message.contains("stay"))
    }

    @Test("Widening the scope is named in both messages")
    func scopeIsNamedWhetherOrNotFiltersNarrow() {
        let wideOpen = HistoryClearSummary.message(
            showsAllConnections: true,
            sources: everySource,
            outcome: .any,
            dateRange: .all,
            searchText: ""
        )
        let narrowed = HistoryClearSummary.message(
            showsAllConnections: true,
            sources: everySource,
            outcome: .any,
            dateRange: .week,
            searchText: ""
        )

        #expect(wideOpen.contains("every connection"))
        #expect(narrowed.contains("every connection"))
    }
}
