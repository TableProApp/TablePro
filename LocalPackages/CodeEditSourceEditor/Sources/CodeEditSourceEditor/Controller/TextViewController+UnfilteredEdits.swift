//
//  TextViewController+UnfilteredEdits.swift
//  CodeEditSourceEditor
//

import AppKit
import CodeEditTextView

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
}
