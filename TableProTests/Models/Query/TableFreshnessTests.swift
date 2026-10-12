//
//  TableFreshnessTests.swift
//  TableProTests
//
//  A load that was already running when its table changed cleared the change's mark when it
//  committed, so the tab counted as fresh while it showed rows read before the write.
//

import Foundation
@testable import TablePro
import Testing

struct TableFreshnessTests {
    private let base = ContinuousClock.now

    private func at(_ milliseconds: Int) -> ContinuousClock.Instant {
        base.advanced(by: .milliseconds(milliseconds))
    }

    private func rows(at milliseconds: Int) -> TableFreshness.Change {
        TableFreshness.Change(extent: .rows, at: at(milliseconds))
    }

    private func definition(at milliseconds: Int) -> TableFreshness.Change {
        TableFreshness.Change(extent: .definition, at: at(milliseconds))
    }

    private func read(startedAt milliseconds: Int, includesDefinition: Bool = false) -> TableFreshness.Read {
        TableFreshness.Read(startedAt: at(milliseconds), includesDefinition: includesDefinition)
    }

    @Test("A read that started after the change clears it")
    func aLaterReadClearsTheChange() {
        var freshness = TableFreshness()
        freshness.record(rows(at: 10))

        freshness.record(read(startedAt: 20))

        #expect(!freshness.isStale)
    }

    @Test("A read that started before the change leaves it in place")
    func anEarlierReadLeavesTheChange() {
        var freshness = TableFreshness()
        freshness.record(rows(at: 10))

        freshness.record(read(startedAt: 5))

        #expect(freshness.isStale)
    }

    @Test("A read between two changes covers only the first, so the tab stays stale")
    func aReadBetweenTwoChangesLeavesTheSecond() {
        var freshness = TableFreshness()
        freshness.record(rows(at: 10))
        freshness.record(rows(at: 30))

        freshness.record(read(startedAt: 20))
        #expect(freshness.isStale)

        freshness.record(read(startedAt: 40))
        #expect(!freshness.isStale)
    }

    @Test("A definition change is cleared only by a later read that fetched the definition")
    func aDefinitionNeedsARead() {
        var freshness = TableFreshness()
        freshness.record(definition(at: 10))
        #expect(freshness.needsDefinition)

        freshness.record(read(startedAt: 20))
        #expect(freshness.needsDefinition)
        #expect(freshness.isStale)

        freshness.record(read(startedAt: 5, includesDefinition: true))
        #expect(freshness.needsDefinition)

        freshness.record(read(startedAt: 20, includesDefinition: true))
        #expect(!freshness.needsDefinition)
        #expect(!freshness.isStale)
    }

    @Test("A rows change leaves the definition alone")
    func aRowsChangeNeedsNoDefinition() {
        var freshness = TableFreshness()

        freshness.record(rows(at: 10))

        #expect(freshness.isStale)
        #expect(!freshness.needsDefinition)
    }

    @Test("A query already running covers a rows change only when it claimed the tab after it, and never a definition")
    func anInFlightReadCoversOnlyALaterRowsChange() {
        #expect(TableFreshness.inFlightRead(startedAt: at(20), covers: rows(at: 10)))
        #expect(!TableFreshness.inFlightRead(startedAt: at(5), covers: rows(at: 10)))
        #expect(!TableFreshness.inFlightRead(startedAt: at(20), covers: definition(at: 10)))
    }

    @Test("A read reports whether it answered a change to the rows")
    func aReadReportsWhetherItAnsweredTheRows() {
        var freshness = TableFreshness()
        let onAFreshTab = freshness.record(read(startedAt: 0))
        freshness.record(rows(at: 10))
        let startedBefore = freshness.record(read(startedAt: 5))
        let startedAfter = freshness.record(read(startedAt: 20))
        let afterItWasAnswered = freshness.record(read(startedAt: 30))

        #expect(!onAFreshTab)
        #expect(!startedBefore)
        #expect(startedAfter)
        #expect(!afterItWasAnswered)
    }

    @Test("The change a read still owes carries the latest instant, as a definition while one is outstanding")
    func pendingChangeIsTheLatestOutstandingOne() {
        var freshness = TableFreshness()
        #expect(freshness.pendingChange == nil)

        freshness.record(definition(at: 10))
        freshness.record(rows(at: 30))
        #expect(freshness.pendingChange == definition(at: 30))

        freshness.record(read(startedAt: 40))
        #expect(freshness.pendingChange == definition(at: 10))

        freshness.record(read(startedAt: 40, includesDefinition: true))
        #expect(freshness.pendingChange == nil)

        freshness.record(rows(at: 50))
        #expect(freshness.pendingChange == rows(at: 50))
    }

    @Test("A definition is current only when the read that fetched it started after the last definition change")
    func aDefinitionIsCurrentOnlyAfterTheLastChange() {
        var freshness = TableFreshness()
        #expect(freshness.definitionIsCurrent(asOf: at(0)))

        freshness.record(definition(at: 10))
        freshness.record(rows(at: 30))

        #expect(!freshness.definitionIsCurrent(asOf: at(5)))
        #expect(freshness.definitionIsCurrent(asOf: at(20)))
    }
}
