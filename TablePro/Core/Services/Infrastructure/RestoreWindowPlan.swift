//
//  RestoreWindowPlan.swift
//  TablePro
//

import Foundation

/// Which restored group ends up in front. A group rather than a tab, because a window that held more
/// than one tab restores them all into itself, so the tab the user left selected identifies a window
/// to raise, not a tab to single out.
enum RestoreWindowPlan {
    enum FrontGroup: Equatable {
        case own
        case orphaned(windowGroupIndex: Int)
    }

    static func resolveFrontGroup(
        ownTabIds: [UUID],
        orphanedGroups: [(windowGroupIndex: Int, tabIds: [UUID])],
        selectedId: UUID?
    ) -> FrontGroup {
        guard let selectedId else { return .own }
        if ownTabIds.contains(selectedId) { return .own }
        if let match = orphanedGroups.first(where: { $0.tabIds.contains(selectedId) }) {
            return .orphaned(windowGroupIndex: match.windowGroupIndex)
        }
        return .own
    }
}
