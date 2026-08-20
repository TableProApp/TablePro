//
//  TabExecutionRegistry.swift
//  TablePro
//

import Foundation

/// Identity of one execution on one tab.
///
/// Validation is epoch-only and deliberately does not compare the tab's live table, database or
/// schema fields. `resolveTableTabSchemaIfNeeded` rewrites `schemaName` mid-flight whenever the
/// schema could not be resolved when the tab was created, which is the ordinary session-restore and
/// pre-connect path, so a field comparison would discard results that are perfectly valid. The
/// registry invalidates on retarget instead, which is strictly stronger: a claim minted before a
/// retarget is never current after it, whether or not a successor execution ever starts.
internal struct TabExecutionClaim: Hashable, Sendable {
    let tabId: UUID
    let epoch: Int

    /// When the work this claim owns actually started, on a clock that does not move when the
    /// system clock does. Every terminal point needs the elapsed wall time and none of them can
    /// recover it afterwards: the driver-reported execution time excludes queueing and tunnel
    /// setup, and the failure path records zero.
    let startedAt: ContinuousClock.Instant
}

/// Why an execution stopped owning its tab. Required rather than defaulted, so that adding a new
/// way to end one is a compile error at the new call site instead of a silent gap. The parallel
/// hand-maintained list this replaces was already incomplete when it was written.
internal enum ExecutionEndReason: Equatable, Sendable {
    case cancelledByUser
    case supersededNavigation
    case sessionEnded
    case abandoned
}

/// An execution that was ended by something other than its own completion, handed back so the
/// caller can report it. Returned rather than pushed through a callback because the registry is a
/// value type that several coordinators own copies of.
internal struct EndedExecution: Equatable, Sendable {
    internal let tabId: UUID
    internal let startedAt: ContinuousClock.Instant
    internal let reason: ExecutionEndReason
}

/// Per-tab owner of "which navigation owns this tab's execution", shaped after
/// `ConnectionAttemptRegistry` one level down: connection identity becomes tab identity.
///
/// Replaces a per-window generation counter, a stored per-tab `isExecuting` bool, and two task
/// handles that a tab retarget participated in none of. Busy state is derived from membership here,
/// never stored on the tab, because a stored flag is exactly what let a retargeted tab stay busy
/// forever and silently swallow every later navigation.
internal struct TabExecutionRegistry {
    private struct Entry {
        let epoch: Int
        let startedAt: ContinuousClock.Instant
    }

    private var entries: [UUID: Entry] = [:]
    private var contentEpochs: [UUID: Int] = [:]
    private var lastEpoch: Int = 0

    internal init() {}

    internal mutating func claim(_ tabId: UUID, startedAt: ContinuousClock.Instant = .now) -> TabExecutionClaim {
        lastEpoch += 1
        entries[tabId] = Entry(epoch: lastEpoch, startedAt: startedAt)
        contentEpochs[tabId] = lastEpoch
        return TabExecutionClaim(tabId: tabId, epoch: lastEpoch, startedAt: startedAt)
    }

    /// Identity of what the tab is currently showing, which outlives the claim that produced it.
    /// Background work that augments an already-applied result (exact row count, fetch all) has no
    /// claim of its own to validate, so it captures this and compares before writing back.
    internal func contentEpoch(for tabId: UUID) -> Int {
        contentEpochs[tabId] ?? 0
    }

    internal func isSameContent(_ epoch: Int, for tabId: UUID) -> Bool {
        contentEpoch(for: tabId) == epoch
    }

    /// Only for an execution that is still in flight and has more work to do. An execution that has
    /// finished asks `settle` instead, which answers the same question and releases the tab in one
    /// step: `settle` removes the entry, so `isCurrent` after it is false whether or not the claim
    /// owned anything, and a guard written that way rejects every result it was meant to admit.
    internal func isCurrent(_ claim: TabExecutionClaim) -> Bool {
        entries[claim.tabId]?.epoch == claim.epoch
    }

    /// Identity of what the tab is showing, asked on behalf of the claim that produced it. Work
    /// that outlives its own claim (phase 2, clearing pending edits) has to ask this, because its
    /// claim was settled the moment the result was applied.
    internal func ownsContent(_ claim: TabExecutionClaim) -> Bool {
        isSameContent(claim.epoch, for: claim.tabId)
    }

    /// Retarget, explicit cancel, tab close, teardown. Removing the entry rather than bumping a
    /// counter is what makes "no successor execution ever started" still invalidate, which is
    /// precisely the case the old per-window counter could not represent and the bug walked through.
    internal mutating func invalidate(_ tabId: UUID, reason: ExecutionEndReason) -> EndedExecution? {
        let ended = entries.removeValue(forKey: tabId).map {
            EndedExecution(tabId: tabId, startedAt: $0.startedAt, reason: reason)
        }
        lastEpoch += 1
        contentEpochs[tabId] = lastEpoch
        return ended
    }

    internal mutating func invalidateAll(reason: ExecutionEndReason) -> [EndedExecution] {
        let tabIds = Set(entries.keys).union(contentEpochs.keys)
        let ended = entries.map {
            EndedExecution(tabId: $0.key, startedAt: $0.value.startedAt, reason: reason)
        }
        entries.removeAll()
        for tabId in tabIds {
            lastEpoch += 1
            contentEpochs[tabId] = lastEpoch
        }
        return ended
    }

    /// Ends a claim that ran to completion and reports whether it still owned the tab. A claim that
    /// is no longer current settles nothing, so a late result cannot clear the busy state of the
    /// navigation that superseded it.
    ///
    /// The answer and the release are one call on purpose. Asking them separately is
    /// order-dependent, and releasing first makes the check that follows answer "no" forever, which
    /// is how a failed query stopped reporting its error (#2120). The returned value is the
    /// caller's authority to write: `guard settle(claim) else { return }`, with every write below
    /// the guard. It is deliberately not `@discardableResult`.
    ///
    /// `ConnectionAttemptRegistry.finish` is the same idea for connections and keeps the older
    /// void shape, because its completion sites call it last, after validating through a pure read.
    internal mutating func settle(_ claim: TabExecutionClaim) -> Bool {
        guard isCurrent(claim) else { return false }
        entries.removeValue(forKey: claim.tabId)
        return true
    }

    internal func isExecuting(_ tabId: UUID) -> Bool {
        entries[tabId] != nil
    }

    internal var isAnyExecuting: Bool {
        !entries.isEmpty
    }
}
