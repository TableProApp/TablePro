//
//  RestoredTabMerge.swift
//  TablePro
//

import Foundation

/// Tabs can reach a coordinator before its restore does (a moved tab, a reopened one, the founding
/// payload), and replacing the list with the saved set lost them.
@MainActor
internal struct RestoredTabMerge {
    internal let tabs: [QueryTab]
    internal let selectedTabId: UUID?
    /// The tabs that came from disk, which are the only ones that still need filters and a load.
    internal let restoredTabIds: Set<UUID>
    internal let renamedTabIds: Set<UUID>

    internal static func merge(
        restored: [QueryTab],
        restoredSelection: UUID?,
        present: [QueryTab],
        presentSelection: UUID?,
        heldElsewhere: Set<UUID>
    ) -> RestoredTabMerge {
        let presentIds = Set(present.map(\.id))
        let presentFiles = Set(present.compactMap(\.content.sourceFileURL))
        let kept = restored.filter { tab in
            guard !presentIds.contains(tab.id), !heldElsewhere.contains(tab.id) else { return false }
            guard let url = tab.content.sourceFileURL, presentFiles.contains(url) else { return true }
            /// A saved buffer with unsaved text is kept beside the open one: two tabs on a file lose nothing.
            return tab.content.isFileDirty
        }

        var merged = kept
        var renamed: Set<UUID> = []
        for var tab in present {
            /// Titled before the saved set was read, so a present "Query 1" can repeat a restored one.
            if QueryTab.isDefaultQueryTitle(tab.title),
               merged.contains(where: { $0.tabType == .query && $0.title == tab.title }) {
                tab.title = QueryTabManager.nextQueryTitle(existingTabs: merged + present)
                renamed.insert(tab.id)
            }
            merged.append(tab)
        }

        return RestoredTabMerge(
            tabs: merged,
            selectedTabId: resolvedSelection(
                kept: kept,
                restoredSelection: restoredSelection,
                present: present,
                presentSelection: presentSelection
            ),
            restoredTabIds: Set(kept.map(\.id)),
            renamedTabIds: renamed
        )
    }

    /// A present tab is what the user is looking at or just asked for, so it keeps the selection.
    private static func resolvedSelection(
        kept: [QueryTab],
        restoredSelection: UUID?,
        present: [QueryTab],
        presentSelection: UUID?
    ) -> UUID? {
        if !present.isEmpty {
            if let presentSelection, present.contains(where: { $0.id == presentSelection }) {
                return presentSelection
            }
            return present.first?.id
        }
        if let restoredSelection, kept.contains(where: { $0.id == restoredSelection }) {
            return restoredSelection
        }
        return kept.first?.id
    }
}
