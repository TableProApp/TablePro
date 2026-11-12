//
//  InspectorPopOutRegistry.swift
//  TablePro
//

import Foundation

// An editable pop-out commits to the row ids it opened on, which a reload hands to other rows, so Auto Refresh waits on it.
@MainActor
internal enum InspectorPopOutRegistry {
    private struct Entry {
        weak var owner: TrailingPaneState?
        weak var window: ValueViewerWindowController?
    }

    private static var entries: [Entry] = []

    // Weak both ways: the window controller lives exactly as long as its window is open.
    internal static func record(_ window: ValueViewerWindowController, openedFrom owner: TrailingPaneState) {
        prune()
        entries.append(Entry(owner: owner, window: window))
    }

    internal static func holdsWindow(openedFrom owner: TrailingPaneState) -> Bool {
        prune()
        return entries.contains { $0.owner === owner }
    }

    private static func prune() {
        entries.removeAll { $0.owner == nil || $0.window == nil }
    }
}
