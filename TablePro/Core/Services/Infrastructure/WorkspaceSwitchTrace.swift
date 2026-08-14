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
    /// An `OSSignpostIntervalState` may be ended once. Core Animation gives no guarantee that a
    /// completion block runs exactly once, so the guarantee is made here instead.
    private var hasEnded = false

    /// The click itself, recorded before anything acts on it. Without this a trace that shows no
    /// switch cannot say whether the switch was slow, never started, or went to another window.
    internal static func recordActivation(connectionId: UUID, isHostedByThisWindow: Bool) {
        logger.notice(
            """
            rail activate conn=\(String(connectionId.uuidString.prefix(8)), privacy: .public) \
            hosted=\(isHostedByThisWindow, privacy: .public)
            """
        )
    }

    internal init(connectionId: UUID?) {
        label = connectionId.map { String($0.uuidString.prefix(8)) } ?? "none"
        signpostId = Self.signposter.makeSignpostID()
        interval = Self.signposter.beginInterval("switch", id: signpostId)
        started = clock.now
        stageStarted = started
        Self.logger.notice("switch begin conn=\(self.label, privacy: .public)")
    }

    /// Closes the stage that was running and opens the next one. Named after the work that just
    /// finished, so a long line names its own culprit.
    internal func stage(_ name: StaticString) {
        let now = clock.now
        let elapsed = Self.milliseconds(from: stageStarted, to: now)
        stageStarted = now
        Self.signposter.emitEvent(name, id: signpostId)
        /// Logged at notice, the lowest level the unified log persists to disk. `debug` and `info`
        /// live in a memory buffer that `log show` cannot read back, so a trace written at either
        /// one is invisible unless a profiler was already streaming when the switch happened. A
        /// switch is a human-speed event, so this is a handful of lines per click, not a stream.
        Self.logger.notice(
            "switch stage conn=\(self.label, privacy: .public) \(name, privacy: .public)=\(elapsed, privacy: .public)ms"
        )
    }

    /// Ends the synchronous part and hands the rest to the layout pass. The completion block runs
    /// once the transaction the switch dirtied has been committed to the screen.
    ///
    /// The block is assigned, not chained onto whatever the transaction already carries.
    /// `CATransaction.completionBlock()` will hand back a block Core Animation has already run, so
    /// calling it again ran a previous switch's ending a second time and trapped on an interval
    /// that was already closed. Replacing is the safe direction here: nothing else in the app sets
    /// a completion block, and `finish` is idempotent so a repeat call costs nothing either way.
    internal func endAfterDisplay() {
        let synchronous = Self.milliseconds(from: started, to: clock.now)
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                self.finish(synchronous: synchronous)
            }
        }
    }

    private func finish(synchronous: Int) {
        guard !hasEnded else { return }
        hasEnded = true
        let total = Self.milliseconds(from: started, to: clock.now)
        Self.signposter.endInterval("switch", interval)
        Self.logger.notice(
            """
            switch end conn=\(self.label, privacy: .public) \
            synchronous=\(synchronous, privacy: .public)ms displayed=\(total, privacy: .public)ms
            """
        )
    }

    private static func milliseconds(from: ContinuousClock.Instant, to: ContinuousClock.Instant) -> Int {
        let duration = to - from
        return Int(duration.components.seconds * 1_000)
            + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
