//
//  TextView+Move.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 9/10/23.
//

import Foundation

extension TextView {
    fileprivate func updateAfterMove() {
        unmarkTextIfNeeded()
        scrollSelectionToVisible()
    }

    /// Moves the cursors up one character.
    override public func moveUp(_ sender: Any?) {
        selectionManager.moveSelections(direction: .up, destination: .character)
        updateAfterMove()
    }

    /// Moves the cursors up one character extending the current selection.
    override public func moveUpAndModifySelection(_ sender: Any?) {
        selectionManager.moveSelections(direction: .up, destination: .character, modifySelection: true)
        updateAfterMove()
    }

    /// Moves the cursors down one character.
    override public func moveDown(_ sender: Any?) {
        selectionManager.moveSelections(direction: .down, destination: .character)
        updateAfterMove()
    }

    /// Moves the cursors down one character extending the current selection.
    override public func moveDownAndModifySelection(_ sender: Any?) {
        selectionManager.moveSelections(direction: .down, destination: .character, modifySelection: true)
        updateAfterMove()
    }

    /// Moves the cursors left one character.
    override public func moveLeft(_ sender: Any?) {
        selectionManager.moveSelections(direction: .backward, destination: .character)
        updateAfterMove()
    }

    /// Moves the cursors left one character extending the current selection.
    override public func moveLeftAndModifySelection(_ sender: Any?) {
        selectionManager.moveSelections(direction: .backward, destination: .character, modifySelection: true)
        updateAfterMove()
    }

    /// Moves the cursors right one character.
    override public func moveRight(_ sender: Any?) {
        selectionManager.moveSelections(direction: .forward, destination: .character)
        updateAfterMove()
    }

    /// Moves the cursors right one character extending the current selection.
    override public func moveRightAndModifySelection(_ sender: Any?) {
        selectionManager.moveSelections(direction: .forward, destination: .character, modifySelection: true)
        updateAfterMove()
    }

    /// Moves the cursors left one word.
    override public func moveWordLeft(_ sender: Any?) {
        selectionManager.moveSelections(direction: .backward, destination: .word)
        updateAfterMove()
    }

    /// Moves the cursors left one word extending the current selection.
    override public func moveWordLeftAndModifySelection(_ sender: Any?) {
        selectionManager.moveSelections(direction: .backward, destination: .word, modifySelection: true)
        updateAfterMove()
    }

    /// Moves the cursors right one word.
    override public func moveWordRight(_ sender: Any?) {
        selectionManager.moveSelections(direction: .forward, destination: .word)
        updateAfterMove()
    }

    /// Moves the cursors right one word extending the current selection.
    override public func moveWordRightAndModifySelection(_ sender: Any?) {
        selectionManager.moveSelections(direction: .forward, destination: .word, modifySelection: true)
        updateAfterMove()
    }

    /// Moves the cursors left to the end of the line.
    override public func moveToLeftEndOfLine(_ sender: Any?) {
        selectionManager.moveSelections(direction: .backward, destination: .visualLine)
        updateAfterMove()
    }

    /// Moves the cursors left to the end of the line extending the current selection.
    override public func moveToLeftEndOfLineAndModifySelection(_ sender: Any?) {
        selectionManager.moveSelections(direction: .backward, destination: .visualLine, modifySelection: true)
        updateAfterMove()
    }

    /// Moves the cursors right to the end of the line.
    override public func moveToRightEndOfLine(_ sender: Any?) {
        selectionManager.moveSelections(direction: .forward, destination: .visualLine)
        updateAfterMove()
    }

    /// Moves the cursors right to the end of the line extending the current selection.
    override public func moveToRightEndOfLineAndModifySelection(_ sender: Any?) {
        selectionManager.moveSelections(direction: .forward, destination: .visualLine, modifySelection: true)
        updateAfterMove()
    }

    /// Moves the cursors to the beginning of the line, if pressed again selects the next line up.
    override public func moveToBeginningOfParagraph(_ sender: Any?) {
        selectionManager.moveSelections(direction: .up, destination: .line)
        updateAfterMove()
    }

    /// Moves the cursors to the beginning of the line, if pressed again selects the next line up extending the current
    /// selection.
    override public func moveToBeginningOfParagraphAndModifySelection(_ sender: Any?) {
        selectionManager.moveSelections(direction: .up, destination: .line, modifySelection: true)
        updateAfterMove()
    }

    /// Moves the cursors to the end of the line, if pressed again selects the next line up.
    override public func moveToEndOfParagraph(_ sender: Any?) {
        selectionManager.moveSelections(direction: .down, destination: .line)
        updateAfterMove()
    }

    /// Moves the cursors to the end of the line, if pressed again selects the next line up extending the current
    /// selection.
    override public func moveToEndOfParagraphAndModifySelection(_ sender: Any?) {
        selectionManager.moveSelections(direction: .down, destination: .line, modifySelection: true)
        updateAfterMove()
    }

    /// Moves the cursors to the beginning of the document.
    override public func moveToBeginningOfDocument(_ sender: Any?) {
        selectionManager.moveSelections(direction: .up, destination: .document)
        updateAfterMove()
    }

    /// Moves the cursors to the beginning of the document extending the current selection.
    override public func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) {
        selectionManager.moveSelections(direction: .up, destination: .document, modifySelection: true)
        updateAfterMove()
    }

    /// Moves the cursors to the end of the document.
    override public func moveToEndOfDocument(_ sender: Any?) {
        selectionManager.moveSelections(direction: .down, destination: .document)
        updateAfterMove()
    }

    /// Moves the cursors to the end of the document extending the current selection.
    override public func moveToEndOfDocumentAndModifySelection(_ sender: Any?) {
        selectionManager.moveSelections(direction: .down, destination: .document, modifySelection: true)
        updateAfterMove()
    }

    override public func pageUp(_ sender: Any?) {
        enclosingScrollView?.pageUp(sender)
    }

    override public func pageUpAndModifySelection(_ sender: Any?) {
        selectionManager.moveSelections(direction: .up, destination: .page, modifySelection: true)
        updateAfterMove()
    }

    override public func pageDown(_ sender: Any?) {
        enclosingScrollView?.pageDown(sender)
    }

    override public func pageDownAndModifySelection(_ sender: Any?) {
        selectionManager.moveSelections(direction: .down, destination: .page, modifySelection: true)
        updateAfterMove()
    }
}
