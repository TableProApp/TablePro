//
//  InteractionTrace.swift
//  TablePro
//

import Foundation

internal enum InteractionPath: String, Sendable, CaseIterable {
    case sidebarListing
    case sidebarFilter
    case sidebarExpand
    case quickOpenPanel
    case quickOpenResult
    case completion
}

internal enum InteractionOutcome: String, Sendable {
    case presented
    case superseded
}

internal struct InteractionTiming: Equatable, Sendable {
    let sequence: Int
    let path: InteractionPath
    let outcome: InteractionOutcome
    let total: Duration
    let detail: String
    // systemUptime at the end, so stalls printed against the same clock can be placed inside the trace.
    let endUptime: TimeInterval

    var reportLine: String {
        var line = """
            interaction #\(sequence) path=\(path.rawValue) outcome=\(outcome.rawValue) \
            totalMs=\(String(format: "%.1f", TableLoadDuration.milliseconds(total))) \
            end=\(String(format: "%.3f", endUptime))
            """
        if !detail.isEmpty { line += " \(detail)" }
        return line
    }
}

// One trace per path: a new one means the user moved on, so the open one ends as superseded.
internal struct InteractionTraceRecorder {
    private struct Trace {
        let sequence: Int
        let key: String
        let subject: String
        let startedAt: ContinuousClock.Instant
        var awaitingFrame = false
    }

    private var open: [InteractionPath: Trace] = [:]
    private var nextSequence = 1

    internal init() {}

    internal mutating func begin(
        _ path: InteractionPath,
        key: String,
        subject: String,
        startedAt: ContinuousClock.Instant,
        at now: ContinuousClock.Instant,
        uptime: TimeInterval
    ) -> (sequence: Int, superseded: InteractionTiming?) {
        let superseded = open[path].map {
            timing($0, path: path, outcome: .superseded, detail: "", at: now, uptime: uptime)
        }
        let sequence = nextSequence
        nextSequence += 1
        open[path] = Trace(sequence: sequence, key: key, subject: subject, startedAt: startedAt)
        return (sequence, superseded)
    }

    // The subject is what the trace waits to see: the text a search was typed for, the row being expanded.
    internal func subject(of path: InteractionPath, key: String) -> String? {
        guard let trace = open[path], trace.key == key, !trace.awaitingFrame else { return nil }
        return trace.subject
    }

    // A reload while the frame is pending must not end the same trace twice.
    internal mutating func awaitFrame(_ path: InteractionPath, key: String) -> Int? {
        guard var trace = open[path], trace.key == key, !trace.awaitingFrame else { return nil }
        trace.awaitingFrame = true
        open[path] = trace
        return trace.sequence
    }

    internal mutating func framePresented(
        _ path: InteractionPath,
        sequence: Int,
        detail: String,
        at now: ContinuousClock.Instant,
        uptime: TimeInterval
    ) -> InteractionTiming? {
        guard let trace = open[path], trace.sequence == sequence else { return nil }
        open[path] = nil
        return timing(trace, path: path, outcome: .presented, detail: detail, at: now, uptime: uptime)
    }

    private func timing(
        _ trace: Trace,
        path: InteractionPath,
        outcome: InteractionOutcome,
        detail: String,
        at now: ContinuousClock.Instant,
        uptime: TimeInterval
    ) -> InteractionTiming {
        InteractionTiming(
            sequence: trace.sequence,
            path: path,
            outcome: outcome,
            total: trace.startedAt.duration(to: now),
            detail: detail,
            endUptime: uptime
        )
    }
}
