//
//  TabSwitchTracer.swift
//  TablePro
//

import AppKit
import os

// Key press or click to the first frame of the new tab; a tab that re-queries ends after its rows are drawn.
@MainActor
internal final class TabSwitchTracer {
    internal static let shared = TabSwitchTracer()

    nonisolated private static let writesToStandardError =
        ProcessInfo.processInfo.environment["TABLEPRO_TAB_SWITCH_TRACE"] == "1"

    internal static let inputEventTypes: Set<NSEvent.EventType> = [
        .keyDown, .keyUp, .flagsChanged,
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp
    ]

    private let logger = Logger(subsystem: "com.TablePro", category: "TabSwitch")
    private let signposter = OSSignposter(subsystem: "com.TablePro", category: .pointsOfInterest)
    private let clock = ContinuousClock()
    private var recorder = TabSwitchTraceRecorder()
    private var intervals: [Int: OSSignpostIntervalState] = [:]
    private weak var window: NSWindow?
    private var isShowing: (@MainActor () -> Bool)?

    internal func requestSwitch(
        _ trigger: TabSwitchTrigger,
        to tabId: UUID,
        event: NSEvent? = NSApp.currentEvent
    ) {
        let now = clock.now
        let timestamp = event.flatMap { Self.inputEventTypes.contains($0.type) ? $0.timestamp : nil }
        let startedAt = TabSwitchTraceRecorder.startInstant(
            eventTimestamp: timestamp,
            uptime: ProcessInfo.processInfo.systemUptime,
            now: now
        )
        let (sequence, previous) = recorder.request(trigger, to: tabId, startedAt: startedAt, at: now)
        if let previous {
            end(previous)
        }
        intervals[sequence] = signposter.beginInterval(
            "TabSwitch",
            id: signposter.makeSignpostID(),
            "#\(sequence, privacy: .public) \(trigger.rawValue, privacy: .public)"
        )
    }

    // isShowing answers, when the frame comes, whether the window still shows that tab.
    internal func selectionApplied(
        tabId: UUID,
        rows: TabSwitchRows,
        window: NSWindow?,
        isShowing: @escaping @MainActor () -> Bool
    ) {
        // Another window's selection does not move the switch this one is showing.
        if recorder.isAwaitingPresentation, window !== self.window { return }
        switch recorder.applySelection(tabId: tabId, rows: rows, at: clock.now) {
        case .ignored:
            return
        case .abandoned(let sequence):
            end(.abandoned(sequence: sequence))
        case .ended(let timing):
            end(.timed(timing))
        case .started(let sequence):
            self.window = window
            self.isShowing = isShowing
            logger.debug("tabswitch #\(sequence) selected rows=\(rows.rawValue, privacy: .public)")
            guard rows == .resident else { return }
            awaitFrame(sequence)
        }
    }

    internal func tableLoadFinished(tabId: UUID, outcome: TableLoadOutcome) {
        switch recorder.rowsLoaded(tabId: tabId, completed: outcome == .completed, at: clock.now) {
        case .ignored:
            return
        case .awaitFrame(let sequence):
            awaitFrame(sequence)
        case .ended(let timing):
            end(.timed(timing))
        }
    }

    private func awaitFrame(_ sequence: Int) {
        guard let window else {
            framePresented(sequence)
            return
        }
        window.afterNextFrame { [weak self] in
            self?.framePresented(sequence)
        }
    }

    // A connection switch or a sidebar click can leave the tab while its rows load, with no selection change here.
    private func framePresented(_ sequence: Int) {
        guard isShowing?() ?? true else {
            if let ending = recorder.supersede(sequence: sequence, at: clock.now) {
                end(ending)
            }
            return
        }
        guard let timing = recorder.framePresented(sequence: sequence, at: clock.now) else { return }
        end(.timed(timing))
    }

    private func end(_ ending: TabSwitchTraceRecorder.Ending) {
        switch ending {
        case .abandoned(let sequence):
            endInterval(sequence, outcome: "abandoned")
        case .timed(let timing):
            let line = timing.reportLine
            logger.debug("\(line, privacy: .public)")
            endInterval(timing.sequence, outcome: timing.outcome.rawValue)
            guard Self.writesToStandardError else { return }
            FileHandle.standardError.write(Data("\(line)\n".utf8))
        }
    }

    private func endInterval(_ sequence: Int, outcome: String) {
        guard let interval = intervals.removeValue(forKey: sequence) else { return }
        signposter.endInterval("TabSwitch", interval, "\(outcome, privacy: .public)")
    }
}
