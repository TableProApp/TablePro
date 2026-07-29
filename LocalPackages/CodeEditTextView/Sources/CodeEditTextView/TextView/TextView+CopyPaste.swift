//
//  TextView+CopyPaste.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 8/21/23.
//

import AppKit

extension TextView {
    @objc open func copy(_ sender: AnyObject) {
        guard let textSelections = selectionManager?
            .textSelections
            .compactMap({ textStorage.attributedSubstring(from: $0.range) }),
              !textSelections.isEmpty else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(textSelections)
    }

    @objc open func paste(_ sender: AnyObject) {
        guard let stringContents = NSPasteboard.general.string(forType: .string) else { return }
        insertText(stringContents, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    @objc open func cut(_ sender: AnyObject) {
        expandEmptySelectionsToCurrentLine()
        copy(sender)
        deleteBackward(sender)
    }

    @objc open func delete(_ sender: AnyObject) {
        deleteBackward(sender)
    }

    /// When a selection is empty, a cut removes the whole current line (including
    /// its trailing line break), matching Xcode, VS Code, and JetBrains.
    private func expandEmptySelectionsToCurrentLine() {
        guard !textStorage.string.isEmpty else { return }
        let text = textStorage.string as NSString
        let ranges = selectionManager.textSelections.map { Self.cutRange(for: $0.range, in: text) }
        guard ranges.contains(where: { !$0.isEmpty }) else { return }
        selectionManager.setSelectedRanges(ranges)
    }

    /// The range a cut should remove for a given selection: the selection itself
    /// when non-empty, otherwise the line containing the caret.
    static func cutRange(for selectionRange: NSRange, in text: NSString) -> NSRange {
        guard selectionRange.isEmpty,
              selectionRange.location >= 0,
              selectionRange.location <= text.length else {
            return selectionRange
        }
        return text.lineRange(for: NSRange(location: selectionRange.location, length: 0))
    }
}
