//
//  TabQueryTasks.swift
//  TablePro
//

import Foundation

/// Which execution installed a tab's query task.
///
/// Fetch All is why this is not simply a claim. It extends the result already on screen, so it
/// registers unclaimed work rather than minting a content epoch that would discard its own rows,
/// and it still owns the handle for as long as it runs.
internal enum TabQueryTaskOwner: Hashable, Sendable {
    case claim(TabExecutionClaim)
    case unclaimedWork(tabId: UUID, token: UUID)

    internal var tabId: UUID {
        switch self {
        case .claim(let claim): return claim.tabId
        case .unclaimedWork(let tabId, _): return tabId
        }
    }
}

/// One tab's in-flight query: the cooperative handle, and the driver lease a Stop has to reach.
///
/// Both are needed, and neither substitutes for the other. `Task.cancel()` is cooperative, so it
/// stops a batch at its next statement boundary and does nothing at all to a single statement
/// blocked in a C call; the lease is what carries the engine's own abort to the handle the
/// statement is running on.
internal struct TabQueryTask {
    internal let owner: TabQueryTaskOwner
    internal let lease: DriverLeaseOwner
    internal let task: Task<Void, Never>
}

/// One query task per tab, shaped after `TabExecutionRegistry` one layer up: the registry owns which
/// navigation owns a tab's result, this owns which one owns the tab's cancellation.
///
/// It replaces a single handle per window. That handle was what made cancellation window-wide:
/// every start path cancelled whatever it held, whichever tab owned it, so running a query in one
/// tab or opening a table from the sidebar aborted the batch another tab had running and rolled it
/// back, reporting "cancelled by user" over a Stop nobody pressed.
internal struct TabQueryTasks {
    private var entries: [UUID: TabQueryTask] = [:]

    internal init() {}

    /// Hands back whatever the tab already held, which the caller has to end: a tab reaching a
    /// second execution without its first having retired means the first is still running.
    internal mutating func install(_ entry: TabQueryTask) -> TabQueryTask? {
        let displaced = entries.updateValue(entry, forKey: entry.owner.tabId)
        return displaced?.owner == entry.owner ? nil : displaced
    }

    /// Retires by exact owner, so a completion that owns its own tab cannot take down the handle a
    /// successor installed on it. Answers whether it was still the owner.
    internal mutating func retire(_ owner: TabQueryTaskOwner) -> Bool {
        guard entries[owner.tabId]?.owner == owner else { return false }
        entries.removeValue(forKey: owner.tabId)
        return true
    }

    /// Takes the tab's entry whoever installed it, for a Stop, a supersede or a tab close, all of
    /// which end that tab's work regardless of which execution started it.
    internal mutating func remove(tabId: UUID) -> TabQueryTask? {
        entries.removeValue(forKey: tabId)
    }

    internal mutating func removeAll() -> [TabQueryTask] {
        let all = Array(entries.values)
        entries.removeAll()
        return all
    }

    internal func task(for tabId: UUID) -> Task<Void, Never>? {
        entries[tabId]?.task
    }

    internal func hasTask(for tabId: UUID) -> Bool {
        entries[tabId] != nil
    }
}
