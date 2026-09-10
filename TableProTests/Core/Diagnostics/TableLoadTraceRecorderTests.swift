//
//  TableLoadTraceRecorderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("TableLoadTraceRecorder")
struct TableLoadTraceRecorderTests {
    private let base = ContinuousClock.now

    private func instant(_ milliseconds: Int) -> ContinuousClock.Instant {
        base.advanced(by: .milliseconds(milliseconds))
    }

    @Test("Elapsed time is measured from the start of the trace")
    func measuresElapsedFromStart() throws {
        var recorder = TableLoadTraceRecorder()
        let tabId = UUID()
        let started = recorder.begin(tabId: tabId, table: "users", origin: .sidebar, at: instant(0))

        let recorded = recorder.record(.executeStarted, token: started.token, at: instant(120))
        let timing = try #require(recorded)

        #expect(timing.sinceStart == .milliseconds(120))
        #expect(timing.sincePrevious == .milliseconds(120))
        #expect(timing.previousStage == nil)
    }

    @Test("Each stage reports the gap since the stage before it")
    func measuresGapBetweenStages() throws {
        var recorder = TableLoadTraceRecorder()
        let tabId = UUID()
        let started = recorder.begin(tabId: tabId, table: "users", origin: .sidebar, at: instant(0))

        _ = recorder.record(.executeStarted, token: started.token, at: instant(10))
        let recorded = recorder.record(.driverFetchEnd, token: started.token, at: instant(310))
        let timing = try #require(recorded)

        #expect(timing.sinceStart == .milliseconds(310))
        #expect(timing.sincePrevious == .milliseconds(300))
        #expect(timing.previousStage == .executeStarted)
    }

    @Test("Navigating again on the same tab reports the abandoned trace")
    func reportsSupersededTrace() throws {
        var recorder = TableLoadTraceRecorder()
        let tabId = UUID()
        let first = recorder.begin(tabId: tabId, table: "users", origin: .sidebar, at: instant(0))
        _ = recorder.record(.driverFetchBegin, token: first.token, at: instant(20))

        let second = recorder.begin(tabId: tabId, table: "orders", origin: .sidebar, at: instant(50))

        let superseded = try #require(second.superseded)
        #expect(superseded.token == first.token)
        #expect(superseded.sinceStart == .milliseconds(50))
        #expect(superseded.previousStage == .driverFetchBegin)
        #expect(second.token.table == "orders")
        #expect(second.token.sequence == first.token.sequence + 1)
    }

    @Test("A first navigation on a tab has nothing to supersede")
    func firstNavigationSupersedesNothing() {
        var recorder = TableLoadTraceRecorder()
        let started = recorder.begin(tabId: UUID(), table: "users", origin: .sidebar, at: instant(0))
        #expect(started.superseded == nil)
    }

    @Test("A superseded trace stays addressable so its late result is still attributed to it")
    func lateResultKeepsItsOwnTrace() throws {
        var recorder = TableLoadTraceRecorder()
        let tabId = UUID()
        let first = recorder.begin(tabId: tabId, table: "users", origin: .sidebar, at: instant(0))
        let second = recorder.begin(tabId: tabId, table: "orders", origin: .sidebar, at: instant(50))

        let recorded = recorder.record(.applyResultBegin, token: first.token, at: instant(900))
        let late = try #require(recorded)

        #expect(late.token.table == "users")
        #expect(late.sinceStart == .milliseconds(900))
        #expect(recorder.isActive(first.token) == false)
        #expect(recorder.isActive(second.token))
        #expect(recorder.activeToken(for: tabId) == second.token)
    }

    @Test("Finishing a superseded trace does not clear the tab's active trace")
    func finishingSupersededKeepsActiveTrace() throws {
        var recorder = TableLoadTraceRecorder()
        let tabId = UUID()
        let first = recorder.begin(tabId: tabId, table: "users", origin: .sidebar, at: instant(0))
        let second = recorder.begin(tabId: tabId, table: "orders", origin: .sidebar, at: instant(50))

        _ = recorder.finish(token: first.token, outcome: .completed, at: instant(900))

        #expect(recorder.activeToken(for: tabId) == second.token)
    }

    @Test("Finishing the active trace clears it from the tab")
    func finishingActiveTraceClearsTab() throws {
        var recorder = TableLoadTraceRecorder()
        let tabId = UUID()
        let started = recorder.begin(tabId: tabId, table: "users", origin: .sidebar, at: instant(0))

        let finished = recorder.finish(token: started.token, outcome: .completed, at: instant(400))
        let timing = try #require(finished)

        #expect(timing.sinceStart == .milliseconds(400))
        #expect(recorder.activeToken(for: tabId) == nil)
    }

    @Test("Measuring does not advance the previous stage, so the next stage keeps its real gap")
    func measuringDoesNotAdvanceStages() throws {
        var recorder = TableLoadTraceRecorder()
        let started = recorder.begin(tabId: UUID(), table: "users", origin: .sidebar, at: instant(0))
        _ = recorder.record(.executeStarted, token: started.token, at: instant(10))

        _ = recorder.measure(token: started.token, at: instant(200))
        let recorded = recorder.record(.applyResultBegin, token: started.token, at: instant(310))
        let next = try #require(recorded)

        #expect(next.sincePrevious == .milliseconds(300))
        #expect(next.previousStage == .executeStarted)
    }

    @Test("Stages recorded by tab id land on that tab's active trace")
    func recordsByTabId() throws {
        var recorder = TableLoadTraceRecorder()
        let tabId = UUID()
        let started = recorder.begin(tabId: tabId, table: "users", origin: .sidebar, at: instant(0))

        let recorded = recorder.record(.gridReloadBegin, tabId: tabId, at: instant(75))
        let timing = try #require(recorded)

        #expect(timing.token == started.token)
        #expect(timing.sinceStart == .milliseconds(75))
    }

    @Test("An unknown tab produces no timing rather than a fabricated one")
    func unknownTabProducesNoTiming() {
        var recorder = TableLoadTraceRecorder()
        #expect(recorder.record(.gridReloadBegin, tabId: UUID(), at: instant(10)) == nil)
        #expect(recorder.measure(tabId: UUID(), at: instant(10)) == nil)
        #expect(recorder.activeToken(for: UUID()) == nil)
    }

    @Test("The retained trace window is bounded even when traces never finish")
    func prunesUnfinishedTracesBeyondTheWindow() throws {
        var recorder = TableLoadTraceRecorder()
        let overflow = TableLoadTraceRecorder.retainedTraceLimit + 20
        var tokens: [TableLoadTraceToken] = []
        for index in 0..<overflow {
            tokens.append(
                recorder.begin(tabId: UUID(), table: "t\(index)", origin: .sidebar, at: instant(index)).token
            )
        }

        let retained = tokens.filter { recorder.entry(for: $0) != nil }
        #expect(retained.count <= TableLoadTraceRecorder.retainedTraceLimit)

        let newest = try #require(tokens.last)
        #expect(recorder.entry(for: newest) != nil)
    }

    @Test("Finished traces are evicted before in-flight ones")
    func evictsFinishedTracesFirst() throws {
        var recorder = TableLoadTraceRecorder()
        let inFlightTab = UUID()
        let inFlight = recorder.begin(tabId: inFlightTab, table: "keep", origin: .sidebar, at: instant(0))

        for index in 0..<(TableLoadTraceRecorder.retainedTraceLimit + 5) {
            let token = recorder.begin(
                tabId: UUID(), table: "t\(index)", origin: .sidebar, at: instant(index + 1)
            ).token
            _ = recorder.finish(token: token, outcome: .completed, at: instant(index + 2))
        }

        #expect(recorder.entry(for: inFlight.token) != nil)
        #expect(recorder.activeToken(for: inFlightTab) == inFlight.token)
    }

    @Test("Evicted sequences are handed back once so their signpost intervals can be closed")
    func reportsEvictedSequencesOnce() {
        var recorder = TableLoadTraceRecorder()
        var tokens: [TableLoadTraceToken] = []
        for index in 0..<(TableLoadTraceRecorder.retainedTraceLimit + 10) {
            let token = recorder.begin(
                tabId: UUID(), table: "t\(index)", origin: .sidebar, at: instant(index)
            ).token
            _ = recorder.finish(token: token, outcome: .completed, at: instant(index))
            tokens.append(token)
        }

        let evicted = recorder.takeEvictedSequences()
        #expect(evicted.isEmpty == false)
        #expect(Set(evicted).count == evicted.count)
        for sequence in evicted {
            #expect(tokens.contains { $0.sequence == sequence })
        }
        for sequence in evicted {
            #expect(recorder.entry(for: TableLoadTraceToken(sequence: sequence, tabId: UUID(), table: "")) == nil)
        }
        #expect(recorder.takeEvictedSequences().isEmpty)
    }

    @Test("A trace with no evictions hands back nothing")
    func reportsNoEvictionsWhenUnderTheLimit() {
        var recorder = TableLoadTraceRecorder()
        let started = recorder.begin(tabId: UUID(), table: "users", origin: .sidebar, at: instant(0))
        _ = recorder.finish(token: started.token, outcome: .completed, at: instant(10))
        #expect(recorder.takeEvictedSequences().isEmpty)
    }

    @Test("A trace only counts as executing once it reaches executeStarted")
    func tracksWhetherExecutionStarted() {
        var recorder = TableLoadTraceRecorder()
        let started = recorder.begin(tabId: UUID(), table: "users", origin: .sidebar, at: instant(0))

        _ = recorder.record(.lazyLoadScheduled, token: started.token, at: instant(5))
        #expect(recorder.hasStartedExecution(started.token) == false)

        _ = recorder.record(.executeStarted, token: started.token, at: instant(10))
        #expect(recorder.hasStartedExecution(started.token))

        _ = recorder.record(.driverFetchEnd, token: started.token, at: instant(90))
        #expect(recorder.hasStartedExecution(started.token))
    }

    @Test("A handoff start time dates the trace from the click, not from when the window loaded")
    func datesTraceFromHandoffInstant() throws {
        var recorder = TableLoadTraceRecorder()
        let started = recorder.begin(
            tabId: UUID(),
            table: "users",
            origin: .newWindowTab,
            at: instant(800),
            startedAt: instant(0)
        )

        let recorded = recorder.record(.executeStarted, token: started.token, at: instant(900))
        let timing = try #require(recorded)

        #expect(timing.sinceStart == .milliseconds(900))
        #expect(timing.sincePrevious == .milliseconds(100))
    }

    @Test("Without a handoff the trace is dated from the call")
    func datesTraceFromCallWhenNoHandoff() throws {
        var recorder = TableLoadTraceRecorder()
        let started = recorder.begin(tabId: UUID(), table: "users", origin: .sidebar, at: instant(800))

        let recorded = recorder.record(.executeStarted, token: started.token, at: instant(900))
        let timing = try #require(recorded)

        #expect(timing.sinceStart == .milliseconds(100))
    }

    @Test("Only anomalies that mislead the user are treated as defects")
    func classifiesDefectAnomalies() {
        #expect(TableLoadAnomaly.blockedByInFlightExecution.isDefect)
        #expect(TableLoadAnomaly.resultTableMismatch.isDefect)
        #expect(TableLoadAnomaly.staleResultDropped.isDefect == false)
        #expect(TableLoadAnomaly.supersededByNewNavigation.isDefect == false)
        #expect(TableLoadAnomaly.executionCancelled.isDefect == false)
        #expect(TableLoadAnomaly.connectionNotReady.isDefect == false)
        #expect(TableLoadAnomaly.loadAlreadyInFlight.isDefect == false)
        #expect(TableLoadAnomaly.preparationAbandoned.isDefect == false)
    }
}
