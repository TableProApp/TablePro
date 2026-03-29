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
        unmarkTextIfNeeded()
        needsDisplay = true
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
        needsDisplay = true
    }

    override public func selectWord(_ sender: Any?) {
        let newSelections = selectionManager.textSelections.compactMap { (textSelection) -> NSRange? in
                guard textSelection.range.isEmpty else {
                    return nil
                }
                return findWordBoundary(at: textSelection.range.location)
            }
        selectionManager.setSelectedRanges(newSelections)
        unmarkTextIfNeeded()
        needsDisplay = true
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
        } else {
            return NSRange(location: position, length: 0)
        }

        guard let start = textStorage.findPrecedingOccurrenceOfCharacter(in: characterSet.inverted, from: position),
              let end = textStorage.findNextOccurrenceOfCharacter(in: characterSet.inverted, from: position) else {
            return NSRange(location: position, length: 0)
        }

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
