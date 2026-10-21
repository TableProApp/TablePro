//
//  TabSwitchTrace.swift
//  TablePro
//

import Foundation

internal enum TabSwitchTrigger: String, Sendable {
    case adjacentTab
    case tabNumber
    case recentTab
    case tabStrip
}

// requery: the memory budget dropped the rows. firstLoad: restored from the last session, never shown since.
internal enum TabSwitchRows: String, Sendable {
    case resident
    case requery
    case firstLoad

    init(loads: Bool, needsReload: Bool) {
        guard loads else {
            self = .resident
            return
        }
        self = needsReload ? .requery : .firstLoad
    }
}

internal enum TabSwitchOutcome: String, Sendable {
    case presented
    case superseded
    case loadFailed
}

internal struct TabSwitchTiming: Equatable, Sendable {
    let sequence: Int
    let trigger: TabSwitchTrigger
    let rows: TabSwitchRows
    let outcome: TabSwitchOutcome
    let total: Duration
    let selection: Duration

    var reportLine: String {
        """
        tabswitch #\(sequence) trigger=\(trigger.rawValue) rows=\(rows.rawValue) \
        outcome=\(outcome.rawValue) totalMs=\(Self.milliseconds(total)) \
        selectionMs=\(Self.milliseconds(selection))
        """
    }

    private static func milliseconds(_ duration: Duration) -> String {
        String(format: "%.1f", TableLoadDuration.milliseconds(duration))
    }
}

// One switch at a time: a second request means the user moved on, so the first ends as superseded.
internal struct TabSwitchTraceRecorder {
    internal enum Ending: Equatable {
        case timed(TabSwitchTiming)
        case abandoned(sequence: Int)
    }

    internal enum SelectionResult: Equatable {
        case ignored
        case started(sequence: Int)
        case abandoned(sequence: Int)
        case ended(TabSwitchTiming)
    }

    internal enum RowsResult: Equatable {
        case ignored
        case awaitFrame(sequence: Int)
        case ended(TabSwitchTiming)
    }

    // A selection landing this long after the request came from something other than the gesture.
    internal static let requestExpiry = Duration.seconds(1)

    internal static let maximumEventAge: TimeInterval = 2

    private struct Selection {
        let rows: TabSwitchRows
        let at: ContinuousClock.Instant
        var awaitingRows: Bool
    }

    private struct Trace {
        let sequence: Int
        let trigger: TabSwitchTrigger
        let tabId: UUID
        let startedAt: ContinuousClock.Instant
        let requestedAt: ContinuousClock.Instant
        var selection: Selection?
    }

    private var current: Trace?
    private var nextSequence = 1

    internal init() {}

    internal var isAwaitingPresentation: Bool {
        current?.selection != nil
    }

    // NSEvent.timestamp and systemUptime share mach_absolute_time, so the difference is the event's age.
    internal static func startInstant(
        eventTimestamp: TimeInterval?,
        uptime: TimeInterval,
        now: ContinuousClock.Instant
    ) -> ContinuousClock.Instant {
        guard let eventTimestamp else { return now }
        let age = uptime - eventTimestamp
        guard age >= 0, age <= maximumEventAge else { return now }
        return now.advanced(by: .seconds(-age))
    }

    internal mutating func request(
        _ trigger: TabSwitchTrigger,
        to tabId: UUID,
        startedAt: ContinuousClock.Instant,
        at now: ContinuousClock.Instant
    ) -> (sequence: Int, previous: Ending?) {
        let previous = current.map { end($0, as: .superseded, at: now) }
        let sequence = nextSequence
        nextSequence += 1
        current = Trace(sequence: sequence, trigger: trigger, tabId: tabId, startedAt: startedAt, requestedAt: now)
        return (sequence, previous)
    }

    internal mutating func applySelection(
        tabId: UUID,
        rows: TabSwitchRows,
        at now: ContinuousClock.Instant
    ) -> SelectionResult {
        guard var trace = current else { return .ignored }
        if let selection = trace.selection {
            // The user moved on, through a path that asks for no switch of its own, such as the sidebar.
            guard tabId != trace.tabId else { return .ignored }
            current = nil
            return .ended(timing(trace, selection, outcome: .superseded, at: now))
        }
        guard trace.tabId == tabId else { return .ignored }
        guard trace.requestedAt.duration(to: now) <= Self.requestExpiry else {
            current = nil
            return .abandoned(sequence: trace.sequence)
        }
        trace.selection = Selection(rows: rows, at: now, awaitingRows: rows != .resident)
        current = trace
        return .started(sequence: trace.sequence)
    }

    internal mutating func rowsLoaded(tabId: UUID, completed: Bool, at now: ContinuousClock.Instant) -> RowsResult {
        guard var trace = current, trace.tabId == tabId, var selection = trace.selection, selection.awaitingRows
        else { return .ignored }
        guard completed else {
            current = nil
            return .ended(timing(trace, selection, outcome: .loadFailed, at: now))
        }
        selection.awaitingRows = false
        trace.selection = selection
        current = trace
        return .awaitFrame(sequence: trace.sequence)
    }

    internal mutating func supersede(sequence: Int, at now: ContinuousClock.Instant) -> Ending? {
        guard let trace = current, trace.sequence == sequence else { return nil }
        current = nil
        return end(trace, as: .superseded, at: now)
    }

    internal mutating func framePresented(sequence: Int, at now: ContinuousClock.Instant) -> TabSwitchTiming? {
        guard let trace = current, trace.sequence == sequence,
              let selection = trace.selection, !selection.awaitingRows
        else { return nil }
        current = nil
        return timing(trace, selection, outcome: .presented, at: now)
    }

    private func end(_ trace: Trace, as outcome: TabSwitchOutcome, at now: ContinuousClock.Instant) -> Ending {
        guard let selection = trace.selection else { return .abandoned(sequence: trace.sequence) }
        return .timed(timing(trace, selection, outcome: outcome, at: now))
    }

    private func timing(
        _ trace: Trace,
        _ selection: Selection,
        outcome: TabSwitchOutcome,
        at now: ContinuousClock.Instant
    ) -> TabSwitchTiming {
        TabSwitchTiming(
            sequence: trace.sequence,
            trigger: trace.trigger,
            rows: selection.rows,
            outcome: outcome,
            total: trace.startedAt.duration(to: now),
            selection: trace.startedAt.duration(to: selection.at)
        )
    }
}
