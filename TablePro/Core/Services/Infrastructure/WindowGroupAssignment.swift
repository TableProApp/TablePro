//
//  WindowGroupAssignment.swift
//  TablePro
//

import Foundation

/// Which saved tabs a restoring window claims, and which saved groups have no window left to claim
/// them. Every window of a connection asks this independently: the answer depends only on the window's
/// own position and on what is on disk, never on which window got here first. That is what lets a
/// connection with several windows restore without any of them arbitrating, since the windows all
/// react to one session-return broadcast in no defined order.
internal enum WindowGroupAssignment {
    internal struct Group: Equatable {
        internal let windowGroupIndex: Int
        internal let tabs: [QueryTab]
        internal let selectedTabId: UUID?
    }

    internal struct Plan: Equatable {
        internal let ownTabs: [QueryTab]
        internal let ownSelectedTabId: UUID?
        /// Groups whose window is gone, for the leftmost window to reopen. Empty for every other
        /// window, which is what keeps exactly one window fanning out without a claim protocol.
        internal let orphanedGroups: [Group]
    }

    internal static func resolve(
        windowIndex: Int,
        openWindowCount: Int,
        tabs: [QueryTab],
        windowGroupIndexByTabId: [UUID: Int],
        selectedTabId: UUID?
    ) -> Plan {
        let grouped = Dictionary(grouping: tabs) { windowGroupIndexByTabId[$0.id] ?? 0 }
        let ownTabs = grouped[windowIndex] ?? []
        let ownSelectedTabId = selectedTabId.flatMap { id in
            ownTabs.contains { $0.id == id } ? id : nil
        }

        guard windowIndex == 0 else {
            return Plan(ownTabs: ownTabs, ownSelectedTabId: ownSelectedTabId, orphanedGroups: [])
        }

        let orphanedGroups = grouped.keys
            .filter { $0 >= openWindowCount }
            .sorted()
            .map { index in
                let groupTabs = grouped[index] ?? []
                return Group(
                    windowGroupIndex: index,
                    tabs: groupTabs,
                    selectedTabId: selectedTabId.flatMap { id in
                        groupTabs.contains { $0.id == id } ? id : nil
                    }
                )
            }

        return Plan(ownTabs: ownTabs, ownSelectedTabId: ownSelectedTabId, orphanedGroups: orphanedGroups)
    }

    /// A file saved before tabs recorded their window carries no grouping at all. Reading every tab
    /// as group zero would pile them into one window, and with no in-window tab bar all but one would
    /// be invisible, so each tab keeps its own window the way it always has: its position is its group.
    internal static func normalizedGroupIndices(for tabs: [PersistedTab]) -> [UUID: Int] {
        guard tabs.contains(where: { $0.windowGroupIndex != nil }) else {
            return Dictionary(uniqueKeysWithValues: tabs.enumerated().map { ($0.element.id, $0.offset) })
        }
        return Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.windowGroupIndex ?? 0) })
    }
}
