//
//  TableLoadTrace.swift
//  TablePro
//

import Foundation

internal enum TableLoadOrigin: String, Sendable {
    case sidebar
    case newWindowTab
    case restore
    case reExecute
    case inPlace
    case programmatic
}

internal enum TableLoadStage: String, Sendable {
    case openTableTab
    case addFirstTab
    case replaceTabContent
    case cancelPreviousLoad
    case lazyLoadScheduled
    case prepareFirstLoad
    case schemaColumnsBegin
    case schemaColumnsEnd
    case executeRequested
    case executeStarted
    case driverFetchBegin
    case driverFetchEnd
    case applyResultBegin
    case gridReloadBegin
    case gridReloadEnd
    case mainRunLoopIdle
}

internal enum TableLoadAnomaly: String, Sendable {
    case supersededByNewNavigation
    case blockedByInFlightExecution
    case loadAlreadyInFlight
    case staleResultDropped
    case resultTableMismatch
    case connectionNotReady
    case executionCancelled
    case preparationAbandoned

    /// A defect misleads the user about what they are looking at, so it is logged at
    /// error level and shows up without enabling debug capture. The rest are expected
    /// outcomes of ordinary navigation and stay informational.
    var isDefect: Bool {
        switch self {
        case .blockedByInFlightExecution, .resultTableMismatch:
            return true
        case .supersededByNewNavigation, .loadAlreadyInFlight, .staleResultDropped,
             .connectionNotReady, .executionCancelled, .preparationAbandoned:
            return false
        }
    }
}

/// Identifies one navigation for its whole lifetime. Execution carries the token into its
/// async closure so a late result is attributed to the navigation that issued it, not to
/// whichever navigation happens to own the tab when the result lands.
internal struct TableLoadTraceToken: Sendable, Equatable {
    let sequence: Int
    let tabId: UUID
    let table: String
}

internal struct TableLoadTiming: Equatable {
    let token: TableLoadTraceToken
    let previousStage: TableLoadStage?
    let sinceStart: Duration
    let sincePrevious: Duration
}

internal struct TableLoadTraceRecorder {
    internal struct Entry: Equatable {
        let token: TableLoadTraceToken
        let origin: TableLoadOrigin
        let startedAt: ContinuousClock.Instant
        var lastEventAt: ContinuousClock.Instant
        var lastStage: TableLoadStage?
        var startedExecution: Bool
        var isFinished: Bool
        var stageInstants: [TableLoadStage: ContinuousClock.Instant] = [:]
        var anomalies: [TableLoadAnomaly] = []
        var environment: TableLoadEnvironment = .unknown
        var resultMetrics: TableLoadResultMetrics?
        var wasSuperseded = false
        var isSummarized = false
    }

    internal static let retainedTraceLimit = 32

    private var entries: [Int: Entry] = [:]
    private var sequenceOrder: [Int] = []
    private var activeSequenceByTab: [UUID: Int] = [:]
    private var evictedSequences: [Int] = []
    private var completedSummaries: [TableLoadTraceSummary] = []
    private var nextSequence = 1

    internal init() {}

    /// The adapter keeps its own per-sequence signpost state, which this type cannot reach. Handing
    /// back what was evicted is what lets it close those intervals instead of leaking them.
    internal mutating func takeEvictedSequences() -> [Int] {
        defer { evictedSequences.removeAll() }
        return evictedSequences
    }

    /// The same channel for the persisted history. A trace ends four ways and only one of them is
    /// `finish`, so the summary is built where the entry actually leaves the live set rather than at
    /// any single caller, and `isSummarized` makes that at most once per trace whichever path wins.
    internal mutating func takeCompletedSummaries() -> [TableLoadTraceSummary] {
        defer { completedSummaries.removeAll() }
        return completedSummaries
    }

    /// Starting a navigation on a tab that still has one in flight is the shape the user
    /// sees as "the grid filled with the wrong table", so the abandoned trace is reported
    /// rather than silently dropped.
    /// `startedAt` lets a navigation that began in another window (a sidebar click that opens a new
    /// native window tab) date its trace from the click rather than from when the receiving window
    /// got around to loading, which is where most of that wait actually goes.
    internal mutating func begin(
        tabId: UUID,
        table: String,
        origin: TableLoadOrigin,
        environment: TableLoadEnvironment = .unknown,
        at instant: ContinuousClock.Instant,
        startedAt: ContinuousClock.Instant? = nil
    ) -> (token: TableLoadTraceToken, superseded: TableLoadTiming?) {
        let superseded = measure(tabId: tabId, at: instant)
        if let previous = activeSequenceByTab[tabId] {
            supersede(sequence: previous, at: instant)
        }

        let token = TableLoadTraceToken(sequence: nextSequence, tabId: tabId, table: table)
        nextSequence += 1
        entries[token.sequence] = Entry(
            token: token,
            origin: origin,
            startedAt: startedAt ?? instant,
            lastEventAt: instant,
            lastStage: nil,
            startedExecution: false,
            isFinished: false,
            environment: environment
        )
        sequenceOrder.append(token.sequence)
        activeSequenceByTab[tabId] = token.sequence
        pruneFinishedTraces(at: instant)
        return (token, superseded)
    }

    internal mutating func record(
        _ stage: TableLoadStage,
        token: TableLoadTraceToken,
        at instant: ContinuousClock.Instant
    ) -> TableLoadTiming? {
        guard let timing = measure(token: token, at: instant) else { return nil }
        entries[token.sequence]?.lastEventAt = instant
        entries[token.sequence]?.lastStage = stage
        entries[token.sequence]?.stageInstants[stage] = instant
        if stage == .executeStarted { entries[token.sequence]?.startedExecution = true }
        return timing
    }

    /// Anomalies belong to the trace, not only to the log line, so they are recorded here rather than
    /// measured and thrown away: "how often did a load report this" is the question the history exists
    /// to answer. Repeats are folded, because one navigation can be blocked several times.
    internal mutating func note(
        _ anomaly: TableLoadAnomaly,
        token: TableLoadTraceToken,
        at instant: ContinuousClock.Instant
    ) -> TableLoadTiming? {
        guard let timing = measure(token: token, at: instant) else { return nil }
        if entries[token.sequence]?.anomalies.contains(anomaly) == false {
            entries[token.sequence]?.anomalies.append(anomaly)
        }
        return timing
    }

    internal mutating func note(
        _ anomaly: TableLoadAnomaly,
        tabId: UUID,
        at instant: ContinuousClock.Instant
    ) -> TableLoadTiming? {
        guard let sequence = activeSequenceByTab[tabId], let entry = entries[sequence] else { return nil }
        return note(anomaly, token: entry.token, at: instant)
    }

    internal mutating func setResultMetrics(_ metrics: TableLoadResultMetrics, token: TableLoadTraceToken) {
        entries[token.sequence]?.resultMetrics = metrics
    }

    /// A trace that reached `.executeStarted` owns a query that is still on its way back, so nothing
    /// may close it early: the result has to be able to report against it when it lands.
    internal func hasStartedExecution(_ token: TableLoadTraceToken) -> Bool {
        entries[token.sequence]?.startedExecution ?? false
    }

    internal mutating func record(
        _ stage: TableLoadStage,
        tabId: UUID,
        at instant: ContinuousClock.Instant
    ) -> TableLoadTiming? {
        guard let sequence = activeSequenceByTab[tabId], let entry = entries[sequence] else { return nil }
        return record(stage, token: entry.token, at: instant)
    }

    internal func measure(token: TableLoadTraceToken, at instant: ContinuousClock.Instant) -> TableLoadTiming? {
        guard let entry = entries[token.sequence] else { return nil }
        return TableLoadTiming(
            token: entry.token,
            previousStage: entry.lastStage,
            sinceStart: entry.startedAt.duration(to: instant),
            sincePrevious: entry.lastEventAt.duration(to: instant)
        )
    }

    internal func measure(tabId: UUID, at instant: ContinuousClock.Instant) -> TableLoadTiming? {
        guard let sequence = activeSequenceByTab[tabId], let entry = entries[sequence] else { return nil }
        return measure(token: entry.token, at: instant)
    }

    internal mutating func finish(
        token: TableLoadTraceToken,
        outcome: TableLoadOutcome,
        at instant: ContinuousClock.Instant
    ) -> TableLoadTiming? {
        guard let timing = measure(token: token, at: instant) else { return nil }
        summarize(sequence: token.sequence, outcome: outcome, at: instant)
        entries[token.sequence]?.isFinished = true
        entries[token.sequence]?.lastEventAt = instant
        if activeSequenceByTab[token.tabId] == token.sequence {
            activeSequenceByTab[token.tabId] = nil
        }
        pruneFinishedTraces(at: instant)
        return timing
    }

    internal func activeToken(for tabId: UUID) -> TableLoadTraceToken? {
        guard let sequence = activeSequenceByTab[tabId] else { return nil }
        return entries[sequence]?.token
    }

    internal func entry(for token: TableLoadTraceToken) -> Entry? {
        entries[token.sequence]
    }

    internal func isActive(_ token: TableLoadTraceToken) -> Bool {
        activeSequenceByTab[token.tabId] == token.sequence
    }

    /// Finished traces go first so an in-flight one stays addressable by a late result, but an
    /// unfinished trace is still evicted once the window overflows: a navigation abandoned before
    /// it ever executed never finishes, and keeping those would grow the map without bound.
    ///
    /// An evicted trace is summarized on the way out. A finished one already was, so `summarize`
    /// declines it; an unfinished one is reported as `evicted`, which is the only record that a
    /// navigation was still open when the window overflowed. A superseded trace whose result never
    /// came back is reported as what it was, not as an eviction.
    private mutating func pruneFinishedTraces(at instant: ContinuousClock.Instant) {
        guard sequenceOrder.count > Self.retainedTraceLimit else { return }
        let finished = sequenceOrder.filter { entries[$0]?.isFinished == true }
        var evictable = finished + sequenceOrder.filter { entries[$0]?.isFinished == false }
        var overflow = sequenceOrder.count - Self.retainedTraceLimit
        var evicted: Set<Int> = []
        while overflow > 0, !evictable.isEmpty {
            let sequence = evictable.removeFirst()
            let outcome: TableLoadOutcome = entries[sequence]?.wasSuperseded == true ? .superseded : .evicted
            summarize(sequence: sequence, outcome: outcome, at: instant)
            entries[sequence] = nil
            evicted.insert(sequence)
            overflow -= 1
        }
        guard !evicted.isEmpty else { return }
        sequenceOrder.removeAll { evicted.contains($0) }
        activeSequenceByTab = activeSequenceByTab.filter { !evicted.contains($0.value) }
        evictedSequences.append(contentsOf: evicted)
    }

    /// A superseded trace stays addressable so its late result can still report against it, and that
    /// late report is the only source of `resultTableMismatch` and `staleResultDropped`, the two
    /// findings a history of this kind exists to count. Summarizing here would freeze the record
    /// before either could arrive, so a trace whose query is still on its way back is left to the
    /// ending that result gives it. One that never executed can never report again, so it is
    /// summarized now rather than waiting for an eviction that may never come.
    private mutating func supersede(sequence: Int, at instant: ContinuousClock.Instant) {
        guard var entry = entries[sequence] else { return }
        entry.wasSuperseded = true
        entry.isFinished = true
        if !entry.anomalies.contains(.supersededByNewNavigation) {
            entry.anomalies.append(.supersededByNewNavigation)
        }
        entries[sequence] = entry

        guard !entry.startedExecution else { return }
        summarize(sequence: sequence, outcome: .superseded, at: instant)
    }

    private mutating func summarize(
        sequence: Int,
        outcome: TableLoadOutcome,
        at instant: ContinuousClock.Instant
    ) {
        guard var entry = entries[sequence], !entry.isSummarized else { return }
        entry.isSummarized = true
        entries[sequence] = entry
        completedSummaries.append(Self.summary(for: entry, outcome: outcome, at: instant))
    }

    /// A phase whose bracketing stage never fired is absent rather than zero. `schemaColumnsBegin`
    /// and `schemaColumnsEnd` only fire when the first load needs the schema, and a trace cancelled
    /// before its query ran never reaches the fetch at all, so zero would read as "instant" for work
    /// that never happened.
    private static func summary(
        for entry: Entry,
        outcome: TableLoadOutcome,
        at instant: ContinuousClock.Instant
    ) -> TableLoadTraceSummary {
        func elapsed(_ from: TableLoadStage, _ to: TableLoadStage) -> Duration? {
            guard let start = entry.stageInstants[from], let end = entry.stageInstants[to] else { return nil }
            return start.duration(to: end)
        }

        return TableLoadTraceSummary(
            origin: entry.origin,
            outcome: outcome,
            anomalies: entry.anomalies,
            environment: entry.environment,
            resultMetrics: entry.resultMetrics,
            total: entry.startedAt.duration(to: instant),
            preparation: elapsed(.schemaColumnsBegin, .schemaColumnsEnd),
            driverFetch: elapsed(.driverFetchBegin, .driverFetchEnd),
            resultApply: elapsed(.applyResultBegin, .gridReloadBegin),
            gridReload: elapsed(.gridReloadBegin, .gridReloadEnd),
            mainRunLoopIdle: elapsed(.gridReloadEnd, .mainRunLoopIdle)
        )
    }
}
