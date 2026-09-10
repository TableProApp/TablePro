//
//  TextView+Select.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 10/20/23.
//

import AppKit
import TextStory

extension TextView {
    override public func selectAll(_ sender: Any?) {
        selectionManager.setSelectedRange(documentRange)
        selectionManager.textSelections.first?.pivot = documentRange.location
        unmarkTextIfNeeded()
    }

    override public func selectLine(_ sender: Any?) {
        let newSelections = selectionManager.textSelections.compactMap { textSelection -> NSRange? in
            guard let linePosition = layoutManager.textLineForOffset(textSelection.range.location) else {
                return nil
            }
            return linePosition.range
        }
        selectionManager.setSelectedRanges(newSelections)
        unmarkTextIfNeeded()
    }

    override public func selectWord(_ sender: Any?) {
        let newSelections = selectionManager.textSelections.map { textSelection in
            findWordBoundary(at: textSelection.range.location)
        }
        selectionManager.setSelectedRanges(newSelections)
        unmarkTextIfNeeded()
    }

    /// Given a position, find the range of the word that exists at that position.
    internal func findWordBoundary(at position: Int) -> NSRange {
        guard position >= 0 && position < textStorage.length,
              let char = textStorage.substring(
                from: NSRange(location: position, length: 1)
              )?.first else {
            return NSRange(location: position, length: 0)
        }

        let charSet = CharacterSet(charactersIn: String(char))
        let characterSet: CharacterSet

        if CharacterSet.codeIdentifierCharacters.isSuperset(of: charSet) {
            characterSet = .codeIdentifierCharacters
        } else if CharacterSet.whitespaces.isSuperset(of: charSet) {
            characterSet = .whitespaces
        } else if CharacterSet.newlines.isSuperset(of: charSet) {
            characterSet = .newlines
        } else if CharacterSet.punctuationCharacters.isSuperset(of: charSet) {
            characterSet = .punctuationCharacters
        } else if CharacterSet.symbols.isSuperset(of: charSet) {
            // Operators are Unicode symbols, not punctuation: `= < > + | ~ ^ $` are all in Sm or Sk. Without this
            // branch every one of them fell through to the zero-length return, so double-clicking an operator in a
            // SQL statement selected nothing.
            characterSet = .symbols
        } else {
            return NSRange(location: position, length: 0)
        }

        // The scan returns nil once it runs past the end of the storage, which is what happens for
        // the last word in a document: there is no character after it to end the word. The start
        // and the end of the document are word boundaries too.
        let start = textStorage.findPrecedingOccurrenceOfCharacter(in: characterSet.inverted, from: position) ?? 0
        let end = textStorage.findNextOccurrenceOfCharacter(
            in: characterSet.inverted,
            from: position
        ) ?? textStorage.length

        return NSRange(start: start, end: end)
    }

    /// Given a position, find the range of the entire line that exists at that position.
    internal func findLineBoundary(at position: Int) -> NSRange {
        guard let linePosition = layoutManager.textLineForOffset(position) else {
            return NSRange(location: position, length: 0)
        }
        return linePosition.range
    }
}
