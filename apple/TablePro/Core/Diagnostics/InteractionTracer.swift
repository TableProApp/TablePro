//
//  InteractionTracer.swift
//  TablePro
//

import AppKit
import os

// Sidebar, Open Quickly and autocomplete on a large catalog (#3661): the key press, click or connect
// to the first frame that shows the answer.
@MainActor
internal final class InteractionTracer {
    internal static let shared = InteractionTracer()

    nonisolated internal static let writesToStandardError =
        ProcessInfo.processInfo.environment["TABLEPRO_INTERACTION_TRACE"] == "1"

    private let signposter = OSSignposter(subsystem: "com.TablePro", category: .pointsOfInterest)
    private let clock = ContinuousClock()
    private var recorder = InteractionTraceRecorder()
    private var intervals: [Int: OSSignpostIntervalState] = [:]

    // Off unless something reads the traces, so the checks behind an end cost nothing otherwise.
    internal var isRecording: Bool {
        Self.writesToStandardError || signposter.isEnabled
    }

    internal func begin(
        _ path: InteractionPath,
        key: String = "",
        subject: String = "",
        event: NSEvent? = NSApp.currentEvent
    ) {
        guard isRecording else { return }
        let now = clock.now
        let uptime = ProcessInfo.processInfo.systemUptime
        let timestamp = event.flatMap { TabSwitchTracer.inputEventTypes.contains($0.type) ? $0.timestamp : nil }
        let startedAt = TabSwitchTraceRecorder.startInstant(eventTimestamp: timestamp, uptime: uptime, now: now)
        let (sequence, superseded) = recorder.begin(
            path, key: key, subject: subject, startedAt: startedAt, at: now, uptime: uptime
        )
        if let superseded {
            report(superseded)
        }
        intervals[sequence] = signposter.beginInterval(
            "Interaction",
            id: signposter.makeSignpostID(),
            "#\(sequence, privacy: .public) \(path.rawValue, privacy: .public)"
        )
    }

    internal func subject(of path: InteractionPath, key: String = "") -> String? {
        recorder.subject(of: path, key: key)
    }

    internal func end(_ path: InteractionPath, key: String = "", detail: String = "", after window: NSWindow?) {
        guard let sequence = recorder.awaitFrame(path, key: key) else { return }
        let finish: @MainActor () -> Void = { [weak self] in
            guard let self,
                  let timing = self.recorder.framePresented(
                    path,
                    sequence: sequence,
                    detail: detail,
                    at: self.clock.now,
                    uptime: ProcessInfo.processInfo.systemUptime
                  )
            else { return }
            self.report(timing)
        }
        guard let window else {
            finish()
            return
        }
        window.afterNextFrame(finish)
    }

    private func report(_ timing: InteractionTiming) {
        if let interval = intervals.removeValue(forKey: timing.sequence) {
            signposter.endInterval("Interaction", interval, "\(timing.outcome.rawValue, privacy: .public)")
        }
        guard Self.writesToStandardError else { return }
        FileHandle.standardError.write(Data("\(timing.reportLine)\n".utf8))
    }
}
