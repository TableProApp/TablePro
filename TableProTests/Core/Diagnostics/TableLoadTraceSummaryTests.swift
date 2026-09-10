//
//  TableLoadTraceSummaryTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("TableLoadTraceSummary")
struct TableLoadTraceSummaryTests {
    private let base = ContinuousClock.now

    private func instant(_ milliseconds: Int) -> ContinuousClock.Instant {
        base.advanced(by: .milliseconds(milliseconds))
    }

    private func environment(tabs: Int = 3) -> TableLoadEnvironment {
        TableLoadEnvironment(databaseTypeId: "PostgreSQL", usesSSH: true, openTabCount: tabs)
    }

    private func fullyStagedRecorder() -> (recorder: TableLoadTraceRecorder, token: TableLoadTraceToken) {
        var recorder = TableLoadTraceRecorder()
        let started = recorder.begin(
            tabId: UUID(),
            table: "users",
            origin: .sidebar,
            environment: environment(),
            at: instant(0)
        )
        let token = started.token
        _ = recorder.record(.schemaColumnsBegin, token: token, at: instant(10))
        _ = recorder.record(.schemaColumnsEnd, token: token, at: instant(40))
        _ = recorder.record(.driverFetchBegin, token: token, at: instant(50))
        _ = recorder.record(.driverFetchEnd, token: token, at: instant(250))
        _ = recorder.record(.applyResultBegin, token: token, at: instant(260))
        _ = recorder.record(.gridReloadBegin, token: token, at: instant(300))
        _ = recorder.record(.gridReloadEnd, token: token, at: instant(360))
        _ = recorder.record(.mainRunLoopIdle, token: token, at: instant(420))
        return (recorder, token)
    }

    @Test("Each phase is measured between the stages that bracket it")
    func measuresEveryPhase() throws {
        let staged = fullyStagedRecorder()
        var recorder = staged.recorder
        _ = recorder.finish(token: staged.token, outcome: .completed, at: instant(420))

        let summaries = recorder.takeCompletedSummaries()
        let summary = try #require(summaries.first)
        #expect(summary.total == .milliseconds(420))
        #expect(summary.preparation == .milliseconds(30))
        #expect(summary.driverFetch == .milliseconds(200))
        #expect(summary.resultApply == .milliseconds(40))
        #expect(summary.gridReload == .milliseconds(60))
        #expect(summary.mainRunLoopIdle == .milliseconds(60))
        #expect(summary.outcome == .completed)
        #expect(summary.origin == .sidebar)
    }

    @Test("A phase whose stages never fired is absent rather than zero")
    func absentPhasesStayNil() throws {
        var recorder = TableLoadTraceRecorder()
        let started = recorder.begin(tabId: UUID(), table: "users", origin: .sidebar, at: instant(0))
        _ = recorder.record(.executeStarted, token: started.token, at: instant(10))
        _ = recorder.finish(token: started.token, outcome: .cancelled, at: instant(90))

        let summaries = recorder.takeCompletedSummaries()
        let summary = try #require(summaries.first)
        #expect(summary.total == .milliseconds(90))
        #expect(summary.preparation == nil)
        #expect(summary.driverFetch == nil)
        #expect(summary.resultApply == nil)
        #expect(summary.gridReload == nil)
        #expect(summary.mainRunLoopIdle == nil)
    }

    @Test("A driver fetch that was backdated is still measured between its own instants")
    func backdatedFetchIsMeasuredFromItsOwnInstants() throws {
        var recorder = TableLoadTraceRecorder()
        let started = recorder.begin(tabId: UUID(), table: "users", origin: .sidebar, at: instant(0))
        _ = recorder.record(.driverFetchBegin, token: started.token, at: instant(20))
        _ = recorder.record(.driverFetchEnd, token: started.token, at: instant(140))
        _ = recorder.finish(token: started.token, outcome: .completed, at: instant(600))

        let summaries = recorder.takeCompletedSummaries()
        let summary = try #require(summaries.first)
        #expect(summary.driverFetch == .milliseconds(120))
        #expect(summary.total == .milliseconds(600))
    }

    @Test("A finished trace produces exactly one summary")
    func finishProducesOneSummary() {
        var recorder = TableLoadTraceRecorder()
        let started = recorder.begin(tabId: UUID(), table: "users", origin: .sidebar, at: instant(0))
        _ = recorder.finish(token: started.token, outcome: .completed, at: instant(100))

        #expect(recorder.takeCompletedSummaries().count == 1)
        let drained = recorder.takeCompletedSummaries()
        #expect(drained.isEmpty)
    }

    @Test("A superseded trace is summarized by the navigation that replaced it")
    func supersededTraceIsSummarized() throws {
        var recorder = TableLoadTraceRecorder()
        let tabId = UUID()
        _ = recorder.begin(
            tabId: tabId,
            table: "users",
            origin: .sidebar,
            environment: environment(),
            at: instant(0)
        )
        _ = recorder.begin(tabId: tabId, table: "orders", origin: .sidebar, at: instant(80))

        let summaries = recorder.takeCompletedSummaries()
        #expect(summaries.count == 1)
        let summary = try #require(summaries.first)
        #expect(summary.outcome == .superseded)
        #expect(summary.total == .milliseconds(80))
        #expect(summary.environment.databaseTypeId == "PostgreSQL")
    }

    /// The superseded trace stays addressable so its late result can still report against it, which
    /// means `finish` runs on a trace that was already summarized.
    @Test("Finishing an already superseded trace does not summarize it twice")
    func supersededThenFinishedStaysOneSummary() throws {
        var recorder = TableLoadTraceRecorder()
        let tabId = UUID()
        let first = recorder.begin(tabId: tabId, table: "users", origin: .sidebar, at: instant(0))
        _ = recorder.begin(tabId: tabId, table: "orders", origin: .sidebar, at: instant(80))
        _ = recorder.finish(token: first.token, outcome: .staleDropped, at: instant(900))

        let summaries = recorder.takeCompletedSummaries()
        #expect(summaries.count == 1)
        let summary = try #require(summaries.first)
        #expect(summary.outcome == .superseded)
    }

    /// The late result is the only source of `resultTableMismatch` and `staleResultDropped`, so a
    /// summary frozen at the moment of supersession could never carry either.
    @Test("A superseded trace with a query in flight waits for what its result reports")
    func supersededTraceWithAQueryInFlightWaitsForItsResult() throws {
        var recorder = TableLoadTraceRecorder()
        let tabId = UUID()
        let first = recorder.begin(tabId: tabId, table: "users", origin: .sidebar, at: instant(0))
        _ = recorder.record(.executeStarted, token: first.token, at: instant(10))
        _ = recorder.begin(tabId: tabId, table: "orders", origin: .sidebar, at: instant(80))

        #expect(recorder.takeCompletedSummaries().isEmpty)

        _ = recorder.note(.resultTableMismatch, token: first.token, at: instant(900))
        _ = recorder.note(.staleResultDropped, token: first.token, at: instant(910))
        _ = recorder.finish(token: first.token, outcome: .staleDropped, at: instant(920))

        let summaries = recorder.takeCompletedSummaries()
        #expect(summaries.count == 1)
        let summary = try #require(summaries.first)
        #expect(summary.outcome == .staleDropped)
        #expect(summary.anomalies == [.supersededByNewNavigation, .resultTableMismatch, .staleResultDropped])
        #expect(summary.total == .milliseconds(920))
    }

    @Test("A superseded trace whose result never came back is still reported as superseded")
    func supersededTraceEvictedWithoutItsResultStaysSuperseded() throws {
        var recorder = TableLoadTraceRecorder()
        let tabId = UUID()
        let first = recorder.begin(tabId: tabId, table: "users", origin: .sidebar, at: instant(0))
        _ = recorder.record(.executeStarted, token: first.token, at: instant(10))
        _ = recorder.begin(tabId: tabId, table: "orders", origin: .sidebar, at: instant(80))
        #expect(recorder.takeCompletedSummaries().isEmpty)

        for index in 0..<(TableLoadTraceRecorder.retainedTraceLimit + 5) {
            _ = recorder.begin(tabId: UUID(), table: "t\(index)", origin: .sidebar, at: instant(100 + index))
        }

        let summaries = recorder.takeCompletedSummaries()
        let superseded = summaries.filter { $0.outcome == .superseded }
        #expect(superseded.count == 1)
        let summary = try #require(superseded.first)
        #expect(summary.anomalies == [.supersededByNewNavigation])
    }

    @Test("A trace still open when it is evicted is reported as evicted")
    func evictedUnfinishedTraceIsSummarized() throws {
        var recorder = TableLoadTraceRecorder()
        let overflow = TableLoadTraceRecorder.retainedTraceLimit + 5
        for index in 0..<overflow {
            _ = recorder.begin(tabId: UUID(), table: "t\(index)", origin: .sidebar, at: instant(index))
        }

        let summaries = recorder.takeCompletedSummaries()
        #expect(summaries.isEmpty == false)
        #expect(summaries.allSatisfy { $0.outcome == .evicted })
        #expect(summaries.count == overflow - TableLoadTraceRecorder.retainedTraceLimit)
    }

    @Test("A finished trace evicted later is not summarized a second time")
    func evictionDoesNotResummarizeFinishedTraces() {
        var recorder = TableLoadTraceRecorder()
        let overflow = TableLoadTraceRecorder.retainedTraceLimit + 5
        for index in 0..<overflow {
            let token = recorder.begin(
                tabId: UUID(), table: "t\(index)", origin: .sidebar, at: instant(index)
            ).token
            _ = recorder.finish(token: token, outcome: .completed, at: instant(index + 1))
        }

        let summaries = recorder.takeCompletedSummaries()
        #expect(summaries.count == overflow)
        #expect(summaries.allSatisfy { $0.outcome == .completed })
    }

    @Test("Anomalies ride on the trace, and a repeat is folded")
    func recordsAnomaliesOnce() throws {
        var recorder = TableLoadTraceRecorder()
        let started = recorder.begin(tabId: UUID(), table: "users", origin: .sidebar, at: instant(0))
        _ = recorder.note(.blockedByInFlightExecution, token: started.token, at: instant(10))
        _ = recorder.note(.blockedByInFlightExecution, token: started.token, at: instant(20))
        _ = recorder.note(.staleResultDropped, token: started.token, at: instant(30))
        _ = recorder.finish(token: started.token, outcome: .blocked, at: instant(40))

        let summaries = recorder.takeCompletedSummaries()
        let summary = try #require(summaries.first)
        #expect(summary.anomalies == [.blockedByInFlightExecution, .staleResultDropped])
    }

    @Test("An anomaly noted by tab id lands on that tab's active trace")
    func notesAnomalyByTabId() throws {
        var recorder = TableLoadTraceRecorder()
        let tabId = UUID()
        let started = recorder.begin(tabId: tabId, table: "users", origin: .sidebar, at: instant(0))

        let noted = recorder.note(.preparationAbandoned, tabId: tabId, at: instant(15))
        let timing = try #require(noted)
        #expect(timing.token == started.token)

        _ = recorder.finish(token: started.token, outcome: .prepareAbandoned, at: instant(20))
        let summaries = recorder.takeCompletedSummaries()
        let summary = try #require(summaries.first)
        #expect(summary.anomalies == [.preparationAbandoned])
    }

    @Test("The result's shape reaches the summary from the fetch that produced it")
    func carriesResultMetrics() throws {
        let staged = fullyStagedRecorder()
        var recorder = staged.recorder
        recorder.setResultMetrics(
            TableLoadResultMetrics(rowCount: 480, columnCount: 12, estimatedBytes: 2_048),
            token: staged.token
        )
        _ = recorder.finish(token: staged.token, outcome: .completed, at: instant(420))

        let summaries = recorder.takeCompletedSummaries()
        let metrics = try #require(summaries.first?.resultMetrics)
        #expect(metrics.rowCount == 480)
        #expect(metrics.columnCount == 12)
        #expect(metrics.estimatedBytes == 2_048)
    }

    @Test("A trace that never fetched carries no result shape")
    func leavesResultMetricsAbsentWithoutAFetch() throws {
        var recorder = TableLoadTraceRecorder()
        let started = recorder.begin(tabId: UUID(), table: "users", origin: .sidebar, at: instant(0))
        _ = recorder.finish(token: started.token, outcome: .notConnected, at: instant(30))

        let summaries = recorder.takeCompletedSummaries()
        let summary = try #require(summaries.first)
        #expect(summary.resultMetrics == nil)
    }
}
