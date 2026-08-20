//
//  TextView+CopyPaste.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 8/21/23.
//

import AppKit

extension TextView {
    @objc open func copy(_ sender: AnyObject) {
        guard let ranges = copyRanges(), !ranges.isEmpty else { return }
        let strings = ranges.compactMap { textStorage.attributedSubstring(from: $0) }
        guard !strings.isEmpty, strings.contains(where: { $0.length > 0 }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(strings)
    }

    @objc open func paste(_ sender: AnyObject) {
        guard let stringContents = PasteboardTextReader.plainText() else { return }
        insertText(
            normalizedLineEndings(in: stringContents),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    @objc open func cut(_ sender: AnyObject) {
        expandEmptySelectionsToCurrentLine()
        copy(sender)
        deleteBackward(sender)
    }

    @objc open func delete(_ sender: AnyObject) {
        deleteBackward(sender)
    }

    /// The ranges a copy should write. A bare caret copies its whole line rather than writing an
    /// empty string, which used to clear the pasteboard and silently discard whatever the user had
    /// copied somewhere else.
    private func copyRanges() -> [NSRange]? {
        guard let selections = selectionManager?.textSelections.map(\.range), !selections.isEmpty else {
            return nil
        }
        guard selections.contains(where: \.isEmpty) else { return selections }
        guard textStorage.length > 0 else { return nil }
        let text = textStorage.string as NSString
        return selections.map { Self.cutRange(for: $0, in: text) }
    }

    /// Pasted text can carry line endings the document does not use, and a lone carriage return
    /// reads as a single unterminated line. `TextView+Drag` already normalizes an insertion this
    /// way; a paste is the same kind of foreign input.
    ///
    /// The carriage-return test goes through `NSString`. Swift's `contains` compares grapheme
    /// clusters and `\r\n` is one cluster, so `"a\r\nb".contains("\r")` is false and a
    /// CRLF-only clipboard, the common Windows case, would skip the pass it needs.
    private func normalizedLineEndings(in string: String) -> String {
        let target = layoutManager.detectedLineEnding
        let carriesReturn = (string as NSString).range(of: "\r").location != NSNotFound
        if target == .lineFeed, !carriesReturn { return string }
        let unified = string
            .replacingOccurrences(of: LineEnding.carriageReturnLineFeed.rawValue, with: "\n")
            .replacingOccurrences(of: LineEnding.carriageReturn.rawValue, with: "\n")
        guard target != .lineFeed else { return unified }
        return unified.replacingOccurrences(of: "\n", with: target.rawValue)
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

/// AppKit resolves an Edit menu command against the responder chain and, per
/// `NSUserInterfaceValidations`, enables the item whenever the responder implements the action and
/// offers no validator. Without this, the read-only hosts of this view show Paste, Cut and Delete
/// enabled over content they cannot change and the keystroke is swallowed with no feedback, because
/// a menu key equivalent is the only route Command+V has to a text view: AppKit ships no key
/// binding for any Command chord.
///
/// `paste:` and `delete:` follow the `NSTextView` contract. `copy:` and `cut:` deliberately diverge
/// from it: an empty selection acts on the current line here, which is what this view's `cut(_:)`
/// has always done and what Xcode, VS Code and JetBrains do, so both stay enabled while the
/// document has content.
extension TextView: NSUserInterfaceValidations {
    public func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            return !documentIsEmpty
        case #selector(cut(_:)):
            return isEditable && !documentIsEmpty
        case #selector(paste(_:)):
            return isEditable && PasteboardTextReader.hasText()
        case #selector(delete(_:)):
            return isEditable && hasNonEmptySelection
        default:
            return true
        }
    }

    private var documentIsEmpty: Bool {
        textStorage.length == 0
    }

    private var hasNonEmptySelection: Bool {
        selectionManager?.textSelections.contains { !$0.range.isEmpty } ?? false
    }
}
