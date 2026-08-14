//
//  WorkspaceSwitchTrace.swift
//  TablePro
//

import AppKit
import os

/// Times one workspace switch, stage by stage.
///
/// A switch is a single synchronous burst on the main thread, so a total on its own says only that
/// it was slow. What is actionable is which stage inside it is long, and whether the time is spent
/// in the code that runs at the click or in the layout pass that follows it.
///
/// That second half is why this does not simply bracket the method. Assigning `NSHostingController`
/// a new root view returns immediately and books the real work for the next layout, so a timer that
/// stops at the end of the call reports a switch that costs almost nothing while the window visibly
/// stalls. The interval therefore closes from a `CATransaction` completion block, which runs after
/// the transaction that laid out and drew the new content has committed: click to pixels.
///
/// Signposts are what Instruments reads. The same numbers are logged so the breakdown can be read
/// in Console with no profiler attached.
@MainActor
internal final class WorkspaceSwitchTrace {
    private static let signposter = OSSignposter(subsystem: "com.TablePro", category: "WorkspaceSwitch")
    private static let logger = Logger(subsystem: "com.TablePro", category: "WorkspaceSwitch")

    private let signpostId: OSSignpostID
    private let interval: OSSignpostIntervalState
    private let clock = ContinuousClock()
    private let started: ContinuousClock.Instant
    private var stageStarted: ContinuousClock.Instant
    private let label: String

    internal init(connectionId: UUID?) {
        label = connectionId.map { String($0.uuidString.prefix(8)) } ?? "none"
        signpostId = Self.signposter.makeSignpostID()
        interval = Self.signposter.beginInterval("switch", id: signpostId)
        started = clock.now
        stageStarted = started
        Self.logger.info("switch begin conn=\(self.label, privacy: .public)")
    }

    /// Closes the stage that was running and opens the next one. Named after the work that just
    /// finished, so a long line names its own culprit.
    internal func stage(_ name: StaticString) {
        let now = clock.now
        let elapsed = Self.milliseconds(from: stageStarted, to: now)
        stageStarted = now
        Self.signposter.emitEvent(name, id: signpostId)
        /// Logged at info rather than debug so `log show` can retrieve a switch after the fact.
        /// A switch happens at human speed, so this is a handful of lines per click, not a stream.
        Self.logger.info(
            "switch stage conn=\(self.label, privacy: .public) \(name, privacy: .public)=\(elapsed, privacy: .public)ms"
        )
    }

    /// Ends the synchronous part and hands the rest to the layout pass. The completion block runs
    /// once the transaction the switch dirtied has been committed to the screen.
    internal func endAfterDisplay() {
        let synchronous = Self.milliseconds(from: started, to: clock.now)
        let started = started
        let clock = clock
        let label = label
        let interval = interval
        /// Chained rather than assigned. `setCompletionBlock` replaces whatever the current
        /// transaction already carries, and a diagnostic has no business dropping somebody else's
        /// completion handler.
        let existing = CATransaction.completionBlock()
        CATransaction.setCompletionBlock {
            existing?()
            MainActor.assumeIsolated {
                let total = Self.milliseconds(from: started, to: clock.now)
                Self.signposter.endInterval("switch", interval)
                Self.logger.info(
                    """
                    switch end conn=\(label, privacy: .public) \
                    synchronous=\(synchronous, privacy: .public)ms displayed=\(total, privacy: .public)ms
                    """
                )
            }
        }
    }

    private static func milliseconds(from: ContinuousClock.Instant, to: ContinuousClock.Instant) -> Int {
        let duration = to - from
        return Int(duration.components.seconds * 1_000)
            + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
