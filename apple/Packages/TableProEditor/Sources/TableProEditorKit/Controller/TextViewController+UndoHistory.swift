//
//  TextViewController+UndoHistory.swift
//  TableProEditorKit
//

import AppKit
import TableProTextEngine

// Every step's ranges point into `text`, so the history is only good for that exact text.
public struct EditorUndoHistory {
    let history: CEUndoManager.History
    public let text: String
}

public extension TextViewController {
    func takeUndoHistory() -> EditorUndoHistory? {
        guard let textView, let undoManager = textView.editorUndoManager else { return nil }
        let history = undoManager.history
        guard !history.isEmpty else { return nil }
        undoManager.clearStack()
        return EditorUndoHistory(history: history, text: textView.string)
    }

    @discardableResult
    func restoreUndoHistory(_ history: EditorUndoHistory) -> Bool {
        // Literal equality: the text can be megabytes, and canonical `==` normalizes all of it.
        guard let textView, let undoManager = textView.editorUndoManager,
              (history.text as NSString).isEqual(to: textView.string) else { return false }
        undoManager.restore(history.history)
        return true
    }

    // A whole-document change made by code, as one step Undo takes back. Like Replace All it skips the typing filters
    // and the suggestion triggers. The selection stays where it was, clamped, as `setText` leaves it.
    func replaceDocumentText(_ text: String) {
        guard let textView else { return }
        guard textView.isEditable else {
            setText(text)
            return
        }
        endSnippetSession()
        let selection = textView.selectionManager.textSelections.map(\.range)
        textView.undoManager?.beginUndoGrouping()
        isApplyingUnfilteredEdits = true
        textView.replaceCharacters(
            in: NSRange(location: 0, length: textView.textStorage.length),
            with: text,
            skipUpdateSelection: true
        )
        isApplyingUnfilteredEdits = false
        textView.undoManager?.endUndoGrouping()
        textView.selectionManager.setSelectedRanges(selection)
    }
}
