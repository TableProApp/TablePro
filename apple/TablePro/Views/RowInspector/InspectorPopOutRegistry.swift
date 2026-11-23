//
//  InspectorPopOutRegistry.swift
//  TablePro
//

import AppKit

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

// An editable pop-out's writes, held to the tab and records it opened on. It closes rather than write elsewhere.
@MainActor
internal final class InspectorPopOutSession {
    private weak var editState: MultiRowEditState?
    private weak var window: ValueViewerWindowController?
    private let target: InspectorDetachedTarget

    internal init?(editState: MultiRowEditState, columnIndex: Int) {
        guard let target = editState.holdDetachedField(columnIndex: columnIndex) else { return nil }
        self.editState = editState
        self.target = target
    }

    internal func attach(_ window: ValueViewerWindowController, openedFrom owner: TrailingPaneState) {
        self.window = window
        InspectorPopOutRegistry.record(window, openedFrom: owner)
    }

    internal func commit(_ value: String) {
        guard editState?.commitDetachedField(value, to: target) != true else { return }
        NSSound.beep()
        window?.close()
        window = nil
    }
}
