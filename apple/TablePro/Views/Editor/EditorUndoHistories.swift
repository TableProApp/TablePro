//
//  EditorUndoHistories.swift
//  TablePro
//

import Foundation
import TableProEditorKit

// What a query tab leaves in the shared editor while another tab is shown. Both parts are offsets into `text`, so
// they come back only while the tab still holds that text.
struct EditorTabHistory {
    let text: String
    let undo: EditorUndoHistory?
    let vimMarks: VimDocumentMarks?
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
