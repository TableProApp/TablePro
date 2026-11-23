//
//  EditorUndoHistories.swift
//  TablePro
//

import AppKit
import TableProEditorKit

// What a query tab leaves in the shared editor while another tab is shown. Every part is a place in `text`, so it
// comes back only while the tab still holds that text.
struct EditorTabHistory {
    let text: String
    let undo: EditorUndoHistory?
    let vimMarks: VimDocumentMarks?
    let selection: [NSRange]
    let scrollPosition: CGPoint
}

@MainActor
final class EditorUndoHistories {
    private var entries: [UUID: EditorTabHistory] = [:]

    func store(_ history: EditorTabHistory?, for tabId: UUID) {
        entries[tabId] = history
    }

    func take(for tabId: UUID) -> EditorTabHistory? {
        entries.removeValue(forKey: tabId)
    }

    func forget(_ tabId: UUID) {
        entries.removeValue(forKey: tabId)
    }

    func forgetAll(except openTabIds: Set<UUID>) {
        guard entries.keys.contains(where: { !openTabIds.contains($0) }) else { return }
        entries = entries.filter { openTabIds.contains($0.key) }
    }
}
