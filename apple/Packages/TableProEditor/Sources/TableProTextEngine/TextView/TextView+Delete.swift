//
//  TextView+Delete.swift
//  TableProTextEngine
//
//  Created by Khan Winter on 8/24/23.
//

import AppKit

extension TextView {
    override open func deleteBackward(_ sender: Any?) {
        delete(direction: .backward, destination: .character)
    }

    override open func deleteBackwardByDecomposingPreviousCharacter(_ sender: Any?) {
        delete(direction: .backward, destination: .character, decomposeCharacters: true)
    }

    override open func deleteForward(_ sender: Any?) {
        delete(direction: .forward, destination: .character)
    }

    override open func deleteWordBackward(_ sender: Any?) {
        delete(direction: .backward, destination: .word)
    }

    override open func deleteWordForward(_ sender: Any?) {
        delete(direction: .forward, destination: .word)
    }

    // The four line and paragraph deletions are the ones `NSTextView` kills with.
    override open func deleteToBeginningOfLine(_ sender: Any?) {
        delete(direction: .backward, destination: .line, kills: true)
    }

    override open func deleteToEndOfLine(_ sender: Any?) {
        delete(direction: .forward, destination: .line, kills: true)
    }

    override open func deleteToBeginningOfParagraph(_ sender: Any?) {
        delete(direction: .backward, destination: .line, kills: true)
    }

    override open func deleteToEndOfParagraph(_ sender: Any?) {
        delete(direction: .forward, destination: .line, kills: true)
    }

    @objc public func killWordForward(_ sender: Any?) {
        delete(direction: .forward, destination: .word, kills: true)
    }

    @objc public func killWordBackward(_ sender: Any?) {
        delete(direction: .backward, destination: .word, kills: true)
    }

    @objc public func killSelection(_ sender: Any?) {
        guard isEditable else { return }
        let ranges = selectionManager.textSelections.map(\.range)
        guard let strings = selectedStrings(in: ranges) else { return }
        let before = killContinuation
        replaceVerbatim(ranges.map { TextReplacement(range: $0, string: "") })
        unmarkTextIfNeeded()
        KillRing.shared.kill(strings, direction: .forward, before: before, after: killContinuation)
    }

    @objc public func copySelectionToKillRing(_ sender: Any?) {
        guard let strings = selectedStrings(in: selectionManager.textSelections.map(\.range)) else { return }
        KillRing.shared.kill(strings, direction: .forward, before: nil, after: killContinuation)
    }

    // One string per cursor, empty for a bare caret, so a later yank still lines up with the cursors.
    private func selectedStrings(in ranges: [NSRange]) -> [String]? {
        let strings = ranges.map { textStorage.substring(from: $0) ?? "" }
        guard strings.contains(where: { !$0.isEmpty }) else {
            NSSound.beep()
            return nil
        }
        return strings
    }

    // Kills, yanks and transpositions move exactly the text the kill ring holds, so the typing filters that rewrite a
    // typed edit (auto-indent, bracket pairs, indentation-wide deletes) stay out of them. Each is one undo step, at
    // every cursor.
    func replaceVerbatim(_ replacements: [TextReplacement]) {
        acceptComposition()
        let ownsGroup = editorUndoManager?.isGrouping == false
        if ownsGroup { editorUndoManager?.beginUndoGrouping() }
        defer { if ownsGroup { editorUndoManager?.endUndoGrouping() } }
        replaceCharacters(replacements, skipUpdateSelection: false, asksDelegate: false)
    }

    var killContinuation: KillRing.Continuation {
        KillRing.Continuation(
            owner: ObjectIdentifier(self),
            selectionChangeCount: selectionManager.changeCount,
            length: textStorage.length
        )
    }

    private func delete(
        direction: TextSelectionManager.Direction,
        destination: TextSelectionManager.Destination,
        decomposeCharacters: Bool = false,
        kills: Bool = false
    ) {
        // A selectable read-only view still routes key equivalents here. `replaceCharacters` refuses the edit, but
        // only after this method has already widened the selection and filled the kill ring.
        guard isEditable else { return }
        let before = killContinuation

        for textSelection in selectionManager.textSelections {
            guard textSelection.range.isEmpty else { continue }
            var extendedRange = selectionManager.rangeOfSelection(
                from: textSelection.range.location,
                direction: direction,
                destination: destination
            )
            guard extendedRange.location >= 0 else { continue }
            // At a line end a forward line kill takes the line ending, as `NSTextView` and Emacs do.
            let location = textSelection.range.location
            if kills, destination == .line, direction == .forward, extendedRange.isEmpty,
               location < textStorage.length, (textStorage.string as NSString).isLineBreak(at: location) {
                extendedRange = (textStorage.string as NSString).caretStepRange(at: location)
            }
            textSelection.range.formUnion(extendedRange)
        }
        selectionManager.textSelections.sort(by: { $0.range.location < $1.range.location })
        let ranges = selectionManager.textSelections.map(\.range)
        let strings = kills ? ranges.map { textStorage.substring(from: $0) ?? "" } : []
        if kills {
            replaceVerbatim(ranges.map { TextReplacement(range: $0, string: "") })
        } else {
            replaceCharacters(in: ranges, with: "")
        }
        unmarkTextIfNeeded()
        guard strings.contains(where: { !$0.isEmpty }) else { return }
        KillRing.shared.kill(
            strings,
            direction: direction == .backward ? .backward : .forward,
            before: before,
            after: killContinuation
        )
    }
}
