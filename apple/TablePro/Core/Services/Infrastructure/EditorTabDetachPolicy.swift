//
//  EditorTabDetachPolicy.swift
//  TablePro
//

import Foundation

// Whether a tab may move into a window of its own. Detaching carries the `QueryTab` and nothing the coordinator
// holds beside it, so anything that would be lost or left behind refuses rather than moving quietly.
internal enum EditorTabDetachPolicy {
    internal static func canDetach(
        tabType: TabType,
        tabCount: Int,
        hasUnsavedWork: Bool,
        isBusy: Bool,
        isConnected: Bool
    ) -> Bool {
        // A debug run's prompts and its close on a declined start act on the coordinator that opened it; a live
        // subscription is registered with that coordinator's tab.
        guard tabType != .routineDebug, tabType != .liveMessages else { return false }
        // Moving the last tab is Move Connection to New Window.
        guard tabCount > 1 else { return false }
        guard !hasUnsavedWork else { return false }
        // The completion of a query or table load in flight would find no tab, and the new window would fetch again.
        guard !isBusy else { return false }
        return isConnected
    }
}
