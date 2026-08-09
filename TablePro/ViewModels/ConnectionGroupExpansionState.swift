//
//  ConnectionGroupExpansionState.swift
//  TablePro
//

import Foundation
import Observation

/// Which connection groups are expanded. A group is one thing wherever it is drawn,
/// so the welcome window and every connection window's Connections tab share this
/// state rather than each keeping their own copy.
///
/// Local only. `ConnectionGroup`'s CloudKit fields are written with raw string
/// subscripts instead of a gated field enum, so a synced expansion flag would have
/// no schema-parity guard behind it.
@MainActor
@Observable
internal final class ConnectionGroupExpansionState {
    internal static let shared = ConnectionGroupExpansionState()

    internal private(set) var expandedGroupIds: Set<UUID> = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey = "com.TablePro.expandedGroupIds"
    @ObservationIgnored private let legacyCollapsedKey = "com.TablePro.collapsedGroupIds"

    internal init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.stringArray(forKey: storageKey) ?? []
        if stored.isEmpty {
            defaults.removeObject(forKey: legacyCollapsedKey)
        }
        expandedGroupIds = Set(stored.compactMap { UUID(uuidString: $0) })
    }

    internal func isExpanded(_ groupId: UUID) -> Bool {
        expandedGroupIds.contains(groupId)
    }

    internal func setExpanded(_ groupId: UUID, expanded: Bool) {
        guard expandedGroupIds.contains(groupId) != expanded else { return }
        var ids = expandedGroupIds
        if expanded {
            ids.insert(groupId)
        } else {
            ids.remove(groupId)
        }
        replace(with: ids)
    }

    internal func expand(_ ids: Set<UUID>) {
        replace(with: expandedGroupIds.union(ids))
    }

    internal func collapse(_ ids: Set<UUID>) {
        replace(with: expandedGroupIds.subtracting(ids))
    }

    /// Seeds every group as expanded the first time anything renders the tree, so a
    /// new install shows its groups open instead of a column of closed rows.
    internal func expandAllIfNeeded(groups: [ConnectionGroup]) {
        guard expandedGroupIds.isEmpty, !groups.isEmpty else { return }
        replace(with: Set(groups.map(\.id)))
    }

    internal func replace(with ids: Set<UUID>) {
        guard expandedGroupIds != ids else { return }
        expandedGroupIds = ids
        defaults.set(ids.map(\.uuidString), forKey: storageKey)
    }
}
