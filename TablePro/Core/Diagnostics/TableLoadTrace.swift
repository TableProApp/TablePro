//
//  TableLoadTrace.swift
//  TablePro
//

import Foundation

internal enum TableLoadOrigin: String {
    case sidebar
    case newWindowTab
    case restore
    case reExecute
    case inPlace
    case programmatic
}

internal enum TableLoadStage: String {
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

internal enum TableLoadAnomaly: String {
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
    }

    internal static let retainedTraceLimit = 32

    private var entries: [Int: Entry] = [:]
    private var sequenceOrder: [Int] = []
    private var activeSequenceByTab: [UUID: Int] = [:]
    private var evictedSequences: [Int] = []
    private var nextSequence = 1

    internal init() {}

    /// The adapter keeps its own per-sequence signpost state, which this type cannot reach. Handing
    /// back what was evicted is what lets it close those intervals instead of leaking them.
    internal mutating func takeEvictedSequences() -> [Int] {
        defer { evictedSequences.removeAll() }
        return evictedSequences
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
        at instant: ContinuousClock.Instant,
        startedAt: ContinuousClock.Instant? = nil
    ) -> (token: TableLoadTraceToken, superseded: TableLoadTiming?) {
        let superseded = measure(tabId: tabId, at: instant)
        if let previous = activeSequenceByTab[tabId] {
            entries[previous]?.isFinished = true
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
            isFinished: false
        )
        sequenceOrder.append(token.sequence)
        activeSequenceByTab[tabId] = token.sequence
        pruneFinishedTraces()
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
        if stage == .executeStarted { entries[token.sequence]?.startedExecution = true }
        return timing
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
        at instant: ContinuousClock.Instant
    ) -> TableLoadTiming? {
        guard let timing = measure(token: token, at: instant) else { return nil }
        entries[token.sequence]?.isFinished = true
        entries[token.sequence]?.lastEventAt = instant
        if activeSequenceByTab[token.tabId] == token.sequence {
            activeSequenceByTab[token.tabId] = nil
        }
        pruneFinishedTraces()
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
    private mutating func pruneFinishedTraces() {
        guard sequenceOrder.count > Self.retainedTraceLimit else { return }
        let finished = sequenceOrder.filter { entries[$0]?.isFinished == true }
        var evictable = finished + sequenceOrder.filter { entries[$0]?.isFinished == false }
        var overflow = sequenceOrder.count - Self.retainedTraceLimit
        var evicted: Set<Int> = []
        while overflow > 0, !evictable.isEmpty {
            let sequence = evictable.removeFirst()
            entries[sequence] = nil
            evicted.insert(sequence)
            overflow -= 1
        }
        guard !evicted.isEmpty else { return }
        sequenceOrder.removeAll { evicted.contains($0) }
        activeSequenceByTab = activeSequenceByTab.filter { !evicted.contains($0.value) }
        evictedSequences.append(contentsOf: evicted)
    }
}
