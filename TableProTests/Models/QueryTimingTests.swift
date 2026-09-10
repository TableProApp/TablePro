//
//  QueryTimingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("PluginQueryTiming")
struct QueryTimingTests {
    @Test("A driver that measured nothing reports the elapsed time as the database time")
    func elapsedIsTheFloor() {
        let timing = PluginQueryTiming(total: 3.4)

        #expect(timing.databaseTime == 3.4)
        #expect(timing.transfer == nil)
        #expect(timing.hasBreakdown == false)
    }

    @Test("Time to first row stands in for database time when the engine reports none")
    func firstRowBeatsElapsed() {
        let timing = PluginQueryTiming(total: 3.4, firstRow: 0.012)

        #expect(timing.databaseTime == 0.012)
        #expect(timing.transfer == 3.4 - 0.012)
        #expect(timing.hasBreakdown)
    }

    @Test("The engine's own report outranks the client measurement")
    func serverBeatsFirstRow() {
        let timing = PluginQueryTiming(total: 3.4, firstRow: 0.012, server: 0.009)

        #expect(timing.databaseTime == 0.009)
    }

    /// A clock read on either side of a fast query can land out of order, and a negative transfer
    /// would render as a query that finished before it started.
    @Test("Transfer never goes negative when the first row outlasts the total")
    func transferIsClamped() {
        let timing = PluginQueryTiming(total: 0.010, firstRow: 0.012)

        #expect(timing.transfer == 0)
    }

    @Test("A batch sums a part only when every statement supplied it")
    func batchSumsOnlyCompleteParts() {
        let folded = PluginQueryTiming.total(of: [
            PluginQueryTiming(total: 1.0, firstRow: 0.1, server: 0.05),
            PluginQueryTiming(total: 2.0, firstRow: 0.2),
        ])

        let firstRow = folded?.firstRow ?? -1
        #expect(folded?.total == 3.0)
        #expect(abs(firstRow - 0.3) < 0.000_001)
        #expect(folded?.server == nil)
    }

    @Test("An empty batch folds to nothing")
    func emptyBatchFoldsToNil() {
        #expect(PluginQueryTiming.total(of: []) == nil)
    }

    @Test("A batch of results with no timing still reports zero rather than nothing")
    func emptyResultBatchReportsZero() {
        #expect(PluginQueryTiming.batch(of: []).total == 0)
    }
}

@Suite("QueryTimingBreakdown")
struct QueryTimingBreakdownTests {
    @Test("Only the parts the driver measured become rows")
    func rowsFollowWhatWasMeasured() {
        let breakdown = QueryTimingBreakdown(timing: PluginQueryTiming(total: 3.4, firstRow: 0.012))

        #expect(breakdown.rows.map(\.id) == ["elapsed", "firstRow", "transfer"])
    }

    @Test("A server-reported figure is listed ahead of the client measurement")
    func serverLeadsTheClientFigure() {
        let breakdown = QueryTimingBreakdown(
            timing: PluginQueryTiming(total: 3.4, firstRow: 0.012, server: 0.009)
        )

        #expect(breakdown.rows.map(\.id) == ["elapsed", "server", "firstRow", "transfer"])
    }

    @Test("An unmeasured result reports the elapsed time alone")
    func elapsedAlone() {
        let breakdown = QueryTimingBreakdown(timing: PluginQueryTiming(total: 3.4))

        #expect(breakdown.rows.count == 1)
        #expect(breakdown.rows[0].id == "elapsed")
    }
}
