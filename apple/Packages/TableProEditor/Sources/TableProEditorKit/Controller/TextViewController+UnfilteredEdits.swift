//
//  TextViewController+UnfilteredEdits.swift
//  TableProEditorKit
//

import AppKit
import TableProTextEngine

public extension TextViewController {
    func applyUnfilteredReplacements(_ replacements: [TextReplacement]) {
        let ordered = replacements.sorted { $0.range.location < $1.range.location }
        guard let first = ordered.first, let last = ordered.last, textView.isEditable else { return }
        let text = textView.string as NSString
        let span = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        guard NSMaxRange(span) <= text.length else { return }

        var cursor = span.location
        var rebuilt = ""
        for replacement in ordered {
            rebuilt += text.substring(with: NSRange(location: cursor, length: replacement.range.location - cursor))
            rebuilt += replacement.string
            cursor = NSMaxRange(replacement.range)
        }

        isApplyingUnfilteredEdits = true
        defer { isApplyingUnfilteredEdits = false }
        textView.replaceCharacters(in: span, with: rebuilt, skipUpdateSelection: true)
    }

    // A command's replacement, unlike `setText`, keeps the undo history: one undo group, no typing filters, no
    // suggestion triggers. The binding gets the text before this returns, so a run right after reads it.
    @discardableResult
    func replaceTextAsOneEdit(in range: NSRange, with string: String) -> Bool {
        guard let textView, textView.isEditable, NSMaxRange(range) <= textView.textStorage.length else { return false }
        guard !range.isEmpty || !string.isEmpty else { return true }
        textView.undoManager?.beginUndoGrouping()
        isApplyingUnfilteredEdits = true
        textView.replaceCharacters(in: range, with: string)
        isApplyingUnfilteredEdits = false
        textView.undoManager?.endUndoGrouping()
        flushPendingTextWriteback()
        return true
    }
}
