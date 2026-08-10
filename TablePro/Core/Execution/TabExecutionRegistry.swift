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
}

internal enum TabExecutionPhase: Equatable, Sendable {
    case preparing
    case executing
    case applying
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
        var phase: TabExecutionPhase
    }

    private var entries: [UUID: Entry] = [:]
    private var lastEpoch: Int = 0

    internal init() {}

    internal mutating func claim(_ tabId: UUID) -> TabExecutionClaim {
        lastEpoch += 1
        entries[tabId] = Entry(epoch: lastEpoch, phase: .preparing)
        return TabExecutionClaim(tabId: tabId, epoch: lastEpoch)
    }

    internal func isCurrent(_ claim: TabExecutionClaim) -> Bool {
        entries[claim.tabId]?.epoch == claim.epoch
    }

    internal mutating func advance(_ claim: TabExecutionClaim, to phase: TabExecutionPhase) {
        guard isCurrent(claim) else { return }
        entries[claim.tabId]?.phase = phase
    }

    /// Retarget, explicit cancel, tab close, teardown. Removing the entry rather than bumping a
    /// counter is what makes "no successor execution ever started" still invalidate, which is
    /// precisely the case the old per-window counter could not represent and the bug walked through.
    internal mutating func invalidate(_ tabId: UUID) {
        entries.removeValue(forKey: tabId)
    }

    internal mutating func invalidateAll() {
        entries.removeAll()
    }

    /// Ends a claim that ran to completion. A claim that is no longer current settles nothing, so a
    /// late result cannot clear the busy state of the navigation that superseded it.
    internal mutating func settle(_ claim: TabExecutionClaim) {
        guard isCurrent(claim) else { return }
        entries.removeValue(forKey: claim.tabId)
    }

    internal func phase(for tabId: UUID) -> TabExecutionPhase? {
        entries[tabId]?.phase
    }

    internal func isExecuting(_ tabId: UUID) -> Bool {
        entries[tabId] != nil
    }

    internal var executingTabIds: Set<UUID> {
        Set(entries.keys)
    }

    internal var isAnyExecuting: Bool {
        !entries.isEmpty
    }
}
