//
//  TabSwitchTraceRecorderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct TabSwitchTraceRecorderTests {
    private let base = ContinuousClock.now

    private func instant(_ milliseconds: Int) -> ContinuousClock.Instant {
        base.advanced(by: .milliseconds(milliseconds))
    }

    private func started(_ result: TabSwitchTraceRecorder.SelectionResult) throws -> Int {
        guard case .started(let sequence) = result else {
            Issue.record("Expected the selection to start the trace, got \(result)")
            throw CancellationError()
        }
        return sequence
    }

    @Test("The clock starts at the input event, not at the command it ran")
    func startsAtTheEventTimestamp() {
        let start = TabSwitchTraceRecorder.startInstant(eventTimestamp: 100.25, uptime: 100.5, now: instant(1_000))

        #expect(start.duration(to: instant(1_000)) == .milliseconds(250))
    }

    @Test("No event, a future event or a stale one starts the clock at the request")
    func ignoresAnUnusableEvent() {
        let now = instant(1_000)

        #expect(TabSwitchTraceRecorder.startInstant(eventTimestamp: nil, uptime: 100, now: now) == now)
        #expect(TabSwitchTraceRecorder.startInstant(eventTimestamp: 100.5, uptime: 100, now: now) == now)
        #expect(TabSwitchTraceRecorder.startInstant(eventTimestamp: 90, uptime: 100, now: now) == now)
    }

    @Test("A tab with resident rows ends at the first frame after the selection")
    func residentEndsAtTheFrame() throws {
        var recorder = TabSwitchTraceRecorder()
        let tabId = UUID()

        let (requested, previous) = recorder.request(.adjacentTab, to: tabId, startedAt: instant(0), at: instant(5))
        #expect(previous == nil)
        let sequence = try started(recorder.applySelection(tabId: tabId, rows: .resident, at: instant(12)))
        #expect(sequence == requested)
        let presented = recorder.framePresented(sequence: sequence, at: instant(40))
        let timing = try #require(presented)

        #expect(timing.trigger == .adjacentTab)
        #expect(timing.rows == .resident)
        #expect(timing.outcome == .presented)
        #expect(timing.total == .milliseconds(40))
        #expect(timing.selection == .milliseconds(12))
    }

    @Test("A tab that re-queries waits for its rows before the frame counts")
    func requeryWaitsForRows() throws {
        var recorder = TabSwitchTraceRecorder()
        let tabId = UUID()

        _ = recorder.request(.recentTab, to: tabId, startedAt: instant(0), at: instant(0))
        let sequence = try started(recorder.applySelection(tabId: tabId, rows: .requery, at: instant(10)))

        #expect(recorder.framePresented(sequence: sequence, at: instant(20)) == nil)
        #expect(recorder.rowsLoaded(tabId: tabId, completed: true, at: instant(90)) == .awaitFrame(sequence: sequence))
        let presented = recorder.framePresented(sequence: sequence, at: instant(105))
        let timing = try #require(presented)

        #expect(timing.rows == .requery)
        #expect(timing.outcome == .presented)
        #expect(timing.total == .milliseconds(105))
    }

    @Test("A load that does not complete ends the switch without a frame")
    func failedLoadEndsTheSwitch() throws {
        var recorder = TabSwitchTraceRecorder()
        let tabId = UUID()

        _ = recorder.request(.tabStrip, to: tabId, startedAt: instant(0), at: instant(0))
        let sequence = try started(recorder.applySelection(tabId: tabId, rows: .firstLoad, at: instant(5)))
        let result = recorder.rowsLoaded(tabId: tabId, completed: false, at: instant(50))

        guard case .ended(let timing) = result else {
            Issue.record("Expected the switch to end, got \(result)")
            return
        }
        #expect(timing.outcome == .loadFailed)
        #expect(recorder.framePresented(sequence: sequence, at: instant(60)) == nil)
    }

    @Test("Rows for another tab, or for a resident switch, change nothing")
    func ignoresUnrelatedRows() throws {
        var recorder = TabSwitchTraceRecorder()
        let tabId = UUID()

        _ = recorder.request(.adjacentTab, to: tabId, startedAt: instant(0), at: instant(0))
        let sequence = try started(recorder.applySelection(tabId: tabId, rows: .resident, at: instant(5)))

        #expect(recorder.rowsLoaded(tabId: UUID(), completed: true, at: instant(10)) == .ignored)
        #expect(recorder.rowsLoaded(tabId: tabId, completed: false, at: instant(10)) == .ignored)
        #expect(recorder.framePresented(sequence: sequence, at: instant(20))?.outcome == .presented)
    }

    @Test("A new request supersedes a switch still on its way to the screen")
    func newRequestSupersedes() throws {
        var recorder = TabSwitchTraceRecorder()
        let firstTab = UUID()
        let secondTab = UUID()

        _ = recorder.request(.adjacentTab, to: firstTab, startedAt: instant(0), at: instant(0))
        let first = try started(recorder.applySelection(tabId: firstTab, rows: .requery, at: instant(5)))
        let (second, previous) = recorder.request(.adjacentTab, to: secondTab, startedAt: instant(30), at: instant(30))

        guard case .timed(let superseded) = previous else {
            Issue.record("Expected the first switch to end timed, got \(String(describing: previous))")
            return
        }
        #expect(superseded.sequence == first)
        #expect(superseded.outcome == .superseded)
        #expect(superseded.total == .milliseconds(30))

        #expect(try started(recorder.applySelection(tabId: secondTab, rows: .resident, at: instant(35))) == second)
        #expect(recorder.framePresented(sequence: first, at: instant(40)) == nil)
        #expect(recorder.framePresented(sequence: second, at: instant(40))?.total == .milliseconds(10))
    }

    @Test("Selecting another tab after the switch landed ends it as superseded")
    func selectionMovingAwaySupersedes() throws {
        var recorder = TabSwitchTraceRecorder()
        let tabId = UUID()

        _ = recorder.request(.adjacentTab, to: tabId, startedAt: instant(0), at: instant(0))
        let sequence = try started(recorder.applySelection(tabId: tabId, rows: .requery, at: instant(5)))
        #expect(recorder.isAwaitingPresentation)
        let moved = recorder.applySelection(tabId: UUID(), rows: .resident, at: instant(50))

        guard case .ended(let timing) = moved else {
            Issue.record("Expected the switch to end, got \(moved)")
            return
        }
        #expect(timing.sequence == sequence)
        #expect(timing.outcome == .superseded)
        #expect(!recorder.isAwaitingPresentation)
        #expect(recorder.rowsLoaded(tabId: tabId, completed: true, at: instant(90)) == .ignored)
    }

    @Test("A switch whose tab left the screen before its frame ends as superseded")
    func supersedeEndsTheSwitch() throws {
        var recorder = TabSwitchTraceRecorder()
        let tabId = UUID()

        _ = recorder.request(.recentTab, to: tabId, startedAt: instant(0), at: instant(0))
        let sequence = try started(recorder.applySelection(tabId: tabId, rows: .requery, at: instant(5)))
        _ = recorder.rowsLoaded(tabId: tabId, completed: true, at: instant(80))
        let ending = recorder.supersede(sequence: sequence, at: instant(90))

        guard case .timed(let timing) = ending else {
            Issue.record("Expected a timed ending, got \(String(describing: ending))")
            return
        }
        #expect(timing.outcome == .superseded)
        #expect(recorder.framePresented(sequence: sequence, at: instant(95)) == nil)
        #expect(recorder.supersede(sequence: sequence, at: instant(96)) == nil)
    }

    @Test("A request replaced before its selection landed is abandoned, not timed")
    func unansweredRequestIsAbandoned() {
        var recorder = TabSwitchTraceRecorder()

        let (first, _) = recorder.request(.tabNumber, to: UUID(), startedAt: instant(0), at: instant(0))
        let (_, previous) = recorder.request(.tabNumber, to: UUID(), startedAt: instant(10), at: instant(10))

        #expect(previous == .abandoned(sequence: first))
    }

    @Test("A selection of another tab leaves the request waiting for its own")
    func otherSelectionIsIgnored() throws {
        var recorder = TabSwitchTraceRecorder()
        let tabId = UUID()

        let (requested, _) = recorder.request(.recentTab, to: tabId, startedAt: instant(0), at: instant(0))

        #expect(recorder.applySelection(tabId: UUID(), rows: .resident, at: instant(5)) == .ignored)
        #expect(try started(recorder.applySelection(tabId: tabId, rows: .resident, at: instant(8))) == requested)
    }

    @Test("A selection nobody asked for starts no trace")
    func selectionWithoutRequestIsIgnored() {
        var recorder = TabSwitchTraceRecorder()

        #expect(recorder.applySelection(tabId: UUID(), rows: .resident, at: instant(0)) == .ignored)
    }

    @Test("A selection that lands long after its request is abandoned")
    func lateSelectionIsAbandoned() {
        var recorder = TabSwitchTraceRecorder()
        let tabId = UUID()

        let (requested, _) = recorder.request(.adjacentTab, to: tabId, startedAt: instant(0), at: instant(0))

        let late = recorder.applySelection(tabId: tabId, rows: .resident, at: instant(1_500))

        #expect(late == .abandoned(sequence: requested))
        #expect(recorder.framePresented(sequence: requested, at: instant(1_510)) == nil)
    }

    @Test("One request starts one trace")
    func requestIsConsumedOnce() throws {
        var recorder = TabSwitchTraceRecorder()
        let tabId = UUID()

        _ = recorder.request(.tabNumber, to: tabId, startedAt: instant(0), at: instant(0))
        _ = try started(recorder.applySelection(tabId: tabId, rows: .resident, at: instant(5)))

        #expect(recorder.applySelection(tabId: tabId, rows: .resident, at: instant(6)) == .ignored)
    }

    @Test("A tab that loads is a re-query when its rows were dropped, else a first load")
    func rowsFollowTheLoad() {
        #expect(TabSwitchRows(loads: false, needsReload: true) == .resident)
        #expect(TabSwitchRows(loads: true, needsReload: true) == .requery)
        #expect(TabSwitchRows(loads: true, needsReload: false) == .firstLoad)
    }

    @Test("The report line carries what the benchmark script reads")
    func reportLineNamesEveryField() {
        let timing = TabSwitchTiming(
            sequence: 3,
            trigger: .recentTab,
            rows: .requery,
            outcome: .presented,
            total: .microseconds(84_240),
            selection: .microseconds(3_100)
        )

        #expect(
            timing.reportLine
                == "tabswitch #3 trigger=recentTab rows=requery outcome=presented totalMs=84.2 selectionMs=3.1"
        )
    }
}
