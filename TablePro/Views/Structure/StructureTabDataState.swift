//
//  StructureTabDataState.swift
//  TablePro
//

import Foundation

/// Tracks which structure tabs hold data and which of them need re-fetching.
/// Keeping the two apart lets a refresh mark every tab stale without dropping the
/// counts already on screen, so the segmented picker never reflows mid-reload.
struct StructureTabDataState: Equatable {
    private var loaded: Set<StructureTab> = []
    private var stale: Set<StructureTab> = []

    func hasData(_ tab: StructureTab) -> Bool {
        loaded.contains(tab)
    }

    func needsFetch(_ tab: StructureTab) -> Bool {
        !loaded.contains(tab) || stale.contains(tab)
    }

    mutating func markAllStale() {
        stale = loaded
    }

    mutating func markFetched(_ tab: StructureTab) {
        loaded.insert(tab)
        stale.remove(tab)
    }

    mutating func reset() {
        loaded.removeAll()
        stale.removeAll()
    }

    static func label(for tab: StructureTab, count: Int?) -> String {
        guard let count else { return tab.displayName }
        return "\(tab.displayName) (\(count))"
    }
}
