//
//  TableLoadTracer.swift
//  TablePro
//

import Foundation
import os

/// Time tracing for the table browse path: sidebar click, tab open, query execution,
/// grid reload, frame presented.
///
/// Stage lines are logged at debug level, so they cost nothing until capture is turned on
/// (`log stream --level debug --predicate 'subsystem == "com.TablePro"'`). Anomalies that
/// mislead the user are logged at error level and are always captured. Every trace is also
/// an Instruments interval under Points of Interest.
///
/// Both of those are live only, so a finished trace is additionally summarized to `sink`, which
/// keeps a bounded local history an intermittent slowdown can be looked at in after the fact.
@MainActor
internal final class TableLoadTracer {
    internal static let shared = TableLoadTracer(sink: TableLoadTracer.defaultSink())

    private struct Interval {
        let id: OSSignpostID
        let state: OSSignpostIntervalState
    }

    private static let handoffExpiry = Duration.seconds(30)

    private let logger = Logger(subsystem: "com.TablePro", category: "TableLoad")
    private let signposter = OSSignposter(subsystem: "com.TablePro", category: .pointsOfInterest)
    private let sink: any TableLoadSummarySink
    private var recorder = TableLoadTraceRecorder()
    private var intervals: [Int: Interval] = [:]
    private var handoffs: [String: ContinuousClock.Instant] = [:]
    private var applyScope: TableLoadTraceToken?
    private let clock = ContinuousClock()

    internal init(sink: any TableLoadSummarySink) {
        self.sink = sink
    }

    /// A unit test that drives a coordinator opens real table tabs and so begins real traces, and
    /// `AppStorageEnvironment` resolves to the production directory under a unit-test host. Choosing
    /// the sink here keeps those traces off the developer's own history without the store having to
    /// know it is being tested.
    private static func defaultSink() -> any TableLoadSummarySink {
        guard NSClassFromString("XCTestCase") == nil else { return DiscardingTableLoadSummarySink() }
        return TableLoadHistoryStore.shared
    }

    /// A sidebar click that opens a new native window tab finishes in a different coordinator, so the
    /// click instant is parked here and picked up by whichever window ends up doing the load. Without
    /// it the trace starts after the window has already mounted and hides that cost.
    internal func noteWindowTabHandoff(connectionId: UUID, table: String) {
        handoffs[Self.handoffKey(connectionId: connectionId, table: table)] = clock.now
        let cutoff = clock.now
        handoffs = handoffs.filter { $0.value.duration(to: cutoff) < Self.handoffExpiry }
    }

    private static func handoffKey(connectionId: UUID, table: String) -> String {
        "\(connectionId.uuidString)|\(table)"
    }

    @discardableResult
    internal func begin(
        tabId: UUID,
        table: String,
        origin: TableLoadOrigin,
        environment: TableLoadEnvironment,
        connectionId: UUID? = nil
    ) -> TableLoadTraceToken {
        let now = clock.now
        var resolvedOrigin = origin
        var startedAt: ContinuousClock.Instant?
        if let connectionId,
           let handoff = handoffs.removeValue(forKey: Self.handoffKey(connectionId: connectionId, table: table)) {
            startedAt = handoff
            resolvedOrigin = .newWindowTab
        }
        let (token, superseded) = recorder.begin(
            tabId: tabId,
            table: table,
            origin: resolvedOrigin,
            environment: environment,
            at: now,
            startedAt: startedAt
        )
        let origin = resolvedOrigin

        if let superseded {
            report(.supersededByNewNavigation, timing: superseded, detail: "replacedBy=#\(token.sequence)")
            endInterval(for: superseded.token, outcome: TableLoadOutcome.superseded.rawValue)
        }

        let signpostID = signposter.makeSignpostID()
        let state = signposter.beginInterval(
            "TableLoad",
            id: signpostID,
            "#\(token.sequence, privacy: .public) \(token.table, privacy: .public)"
        )
        intervals[token.sequence] = Interval(id: signpostID, state: state)
        logger.debug(
            "\(Self.prefix(token), privacy: .public) +0.0ms START origin=\(origin.rawValue, privacy: .public)"
        )
        drainCompletedTraces()
        return token
    }

    /// A navigation the recorder dropped still owns an open signpost interval here. Closing it keeps
    /// `intervals` bounded and stops Instruments from showing a interval that never ends.
    private func closeEvictedIntervals() {
        for sequence in recorder.takeEvictedSequences() {
            guard let interval = intervals.removeValue(forKey: sequence) else { continue }
            signposter.endInterval("TableLoad", interval.state, "\(TableLoadOutcome.evicted.rawValue)")
        }
    }

    /// Stamped on the main actor because the version strings are resolved once per process and the
    /// timestamp costs nothing, then handed over. The sink never blocks: everything it does with the
    /// record happens after this returns.
    private func drainCompletedTraces() {
        closeEvictedIntervals()
        let summaries = recorder.takeCompletedSummaries()
        guard !summaries.isEmpty else { return }
        let stamp = TableLoadRuntimeStamp.current
        let recordedAt = Date()
        for summary in summaries {
            sink.record(TableLoadPerformanceRecord(summary: summary, stamp: stamp, recordedAt: recordedAt))
        }
    }

    internal func stage(_ stage: TableLoadStage, token: TableLoadTraceToken, detail: String? = nil) {
        guard let timing = recorder.record(stage, token: token, at: clock.now) else { return }
        emit(stage, timing: timing, detail: detail)
    }

    /// Stages that bracket a suspension timestamp themselves with `ContinuousClock.now` and report
    /// once the caller resumes, so the recorded instant is when the work actually happened rather
    /// than when the log call got scheduled. The gap between a driver fetch measured this way and
    /// the driver's own reported time is main actor queueing delay, which is the point.
    internal func stage(
        _ stage: TableLoadStage,
        token: TableLoadTraceToken,
        at instant: ContinuousClock.Instant,
        detail: String? = nil
    ) {
        guard let timing = recorder.record(stage, token: token, at: instant) else { return }
        emit(stage, timing: timing, detail: detail)
    }

    internal func stage(_ stage: TableLoadStage, tabId: UUID, detail: String? = nil) {
        guard let timing = recorder.record(stage, tabId: tabId, at: clock.now) else { return }
        emit(stage, timing: timing, detail: detail)
    }

    internal func anomaly(_ anomaly: TableLoadAnomaly, token: TableLoadTraceToken, detail: String? = nil) {
        guard let timing = recorder.note(anomaly, token: token, at: clock.now) else { return }
        report(anomaly, timing: timing, detail: detail)
    }

    internal func anomaly(_ anomaly: TableLoadAnomaly, tabId: UUID, detail: String? = nil) {
        guard let timing = recorder.note(anomaly, tabId: tabId, at: clock.now) else { return }
        report(anomaly, timing: timing, detail: detail)
    }

    internal func setResultMetrics(_ metrics: TableLoadResultMetrics, token: TableLoadTraceToken) {
        recorder.setResultMetrics(metrics, token: token)
    }

    /// `detail` is written to the log and the signpost but never to the history. It is where an
    /// error's Swift type name still reaches a developer reading `log stream`, while the recorded
    /// outcome stays a closed set an external report can group by.
    internal func finish(token: TableLoadTraceToken, outcome: TableLoadOutcome, detail: String? = nil) {
        guard let timing = recorder.finish(token: token, outcome: outcome, at: clock.now) else { return }
        let label = Self.label(for: outcome, detail: detail)
        logger.debug(
            """
            \(Self.prefix(timing.token), privacy: .public) \
            +\(Self.milliseconds(timing.sinceStart), privacy: .public)ms \
            END outcome=\(label, privacy: .public)
            """
        )
        endInterval(for: timing.token, outcome: label)
        drainCompletedTraces()
    }

    private static func label(for outcome: TableLoadOutcome, detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return outcome.rawValue }
        return "\(outcome.rawValue):\(detail)"
    }

    internal func activeToken(for tabId: UUID) -> TableLoadTraceToken? {
        recorder.activeToken(for: tabId)
    }

    internal func isActive(_ token: TableLoadTraceToken) -> Bool {
        recorder.isActive(token)
    }

    internal func hasStartedExecution(_ token: TableLoadTraceToken) -> Bool {
        recorder.hasStartedExecution(token)
    }

    /// The grid reload runs deep inside the result-apply call chain, well past any parameter this
    /// diagnostic could ride on without pushing itself into a domain API. Scoping the applying token
    /// here keeps the reload cost on the navigation that produced the rows, which in the late-result
    /// case is deliberately not the navigation that currently owns the tab. A clear-the-grid reload
    /// outside any apply has no scope and is left untraced rather than charged to the wrong trace.
    internal func beginApplyScope(_ token: TableLoadTraceToken?) {
        applyScope = token
    }

    internal func endApplyScope() {
        applyScope = nil
    }

    internal var applyingToken: TableLoadTraceToken? {
        applyScope
    }

    private func emit(_ stage: TableLoadStage, timing: TableLoadTiming, detail: String?) {
        logger.debug(
            """
            \(Self.prefix(timing.token), privacy: .public) \
            +\(Self.milliseconds(timing.sinceStart), privacy: .public)ms \
            (+\(Self.milliseconds(timing.sincePrevious), privacy: .public)ms) \
            \(stage.rawValue, privacy: .public)\(Self.suffix(detail), privacy: .public)
            """
        )
        guard let interval = intervals[timing.token.sequence] else { return }
        signposter.emitEvent("TableLoadStage", id: interval.id, "\(stage.rawValue)")
    }

    private func report(_ anomaly: TableLoadAnomaly, timing: TableLoadTiming, detail: String?) {
        let line = """
            \(Self.prefix(timing.token)) \
            +\(Self.milliseconds(timing.sinceStart))ms \
            ANOMALY \(anomaly.rawValue) after=\(timing.previousStage?.rawValue ?? "start")\(Self.suffix(detail))
            """
        if anomaly.isDefect {
            logger.error("\(line, privacy: .public)")
        } else {
            logger.info("\(line, privacy: .public)")
        }
        guard let interval = intervals[timing.token.sequence] else { return }
        signposter.emitEvent("TableLoadAnomaly", id: interval.id, "\(anomaly.rawValue)")
    }

    private func endInterval(for token: TableLoadTraceToken, outcome: String) {
        guard let interval = intervals.removeValue(forKey: token.sequence) else { return }
        signposter.endInterval("TableLoad", interval.state, "\(outcome)")
    }

    private static func prefix(_ token: TableLoadTraceToken) -> String {
        "[tableload #\(token.sequence) \(token.table)]"
    }

    private static func suffix(_ detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return "" }
        return " \(detail)"
    }

    private static func milliseconds(_ duration: Duration) -> String {
        String(format: "%.1f", TableLoadDuration.milliseconds(duration))
    }
}
