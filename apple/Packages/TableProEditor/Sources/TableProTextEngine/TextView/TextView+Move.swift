//
//  TextView+Move.swift
//  TableProTextEngine
//
//  Created by Khan Winter on 9/10/23.
//

import Foundation

extension TextView {
    fileprivate func updateAfterMove() {
        unmarkTextIfNeeded()
        scrollSelectionToVisible()
    }

    override public func moveUp(_ sender: Any?) {
        selectionManager.moveSelections(direction: .up, destination: .character)
        updateAfterMove()
    }

    override public func moveUpAndModifySelection(_ sender: Any?) {
        selectionManager.moveSelections(direction: .up, destination: .character, modifySelection: true)
        updateAfterMove()
    }

    override public func moveDown(_ sender: Any?) {
        selectionManager.moveSelections(direction: .down, destination: .character)
        updateAfterMove()
    }

    override public func moveDownAndModifySelection(_ sender: Any?) {
        selectionManager.moveSelections(direction: .down, destination: .character, modifySelection: true)
        updateAfterMove()
    }

    override public func moveLeft(_ sender: Any?) {
        selectionManager.moveSelections(direction: .backward, destination: .character)
        updateAfterMove()
    }

    override public func moveLeftAndModifySelection(_ sender: Any?) {
        selectionManager.moveSelections(direction: .backward, destination: .character, modifySelection: true)
        updateAfterMove()
    }

    override public func moveRight(_ sender: Any?) {
        selectionManager.moveSelections(direction: .forward, destination: .character)
        updateAfterMove()
    }

    override public func moveRightAndModifySelection(_ sender: Any?) {
        selectionManager.moveSelections(direction: .forward, destination: .character, modifySelection: true)
        updateAfterMove()
    }

    override public func moveWordLeft(_ sender: Any?) {
        selectionManager.moveSelections(direction: .backward, destination: .word)
        updateAfterMove()
    }

    override public func moveWordLeftAndModifySelection(_ sender: Any?) {
        selectionManager.moveSelections(direction: .backward, destination: .word, modifySelection: true)
        updateAfterMove()
    }

    override public func moveWordRight(_ sender: Any?) {
        selectionManager.moveSelections(direction: .forward, destination: .word)
        updateAfterMove()
    }

    override public func moveWordRightAndModifySelection(_ sender: Any?) {
        selectionManager.moveSelections(direction: .forward, destination: .word, modifySelection: true)
        updateAfterMove()
    }

    override public func moveToLeftEndOfLine(_ sender: Any?) {
        selectionManager.moveSelections(direction: .backward, destination: .visualLine)
        updateAfterMove()
    }

    override public func moveToLeftEndOfLineAndModifySelection(_ sender: Any?) {
        selectionManager.moveSelections(direction: .backward, destination: .visualLine, modifySelection: true)
        updateAfterMove()
    }

    override public func moveToRightEndOfLine(_ sender: Any?) {
        selectionManager.moveSelections(direction: .forward, destination: .visualLine)
        updateAfterMove()
    }

    override public func moveToRightEndOfLineAndModifySelection(_ sender: Any?) {
        selectionManager.moveSelections(direction: .forward, destination: .visualLine, modifySelection: true)
        updateAfterMove()
    }

    override public func moveToBeginningOfParagraph(_ sender: Any?) {
        selectionManager.moveSelections(direction: .up, destination: .line)
        updateAfterMove()
    }

    override public func moveToBeginningOfParagraphAndModifySelection(_ sender: Any?) {
        selectionManager.moveSelections(direction: .up, destination: .line, modifySelection: true)
        updateAfterMove()
    }

    override public func moveToEndOfParagraph(_ sender: Any?) {
        selectionManager.moveSelections(direction: .down, destination: .line)
        updateAfterMove()
    }

    override public func moveToEndOfParagraphAndModifySelection(_ sender: Any?) {
        selectionManager.moveSelections(direction: .down, destination: .line, modifySelection: true)
        updateAfterMove()
    }

    override public func moveToBeginningOfDocument(_ sender: Any?) {
        selectionManager.moveSelections(direction: .up, destination: .document)
        updateAfterMove()
    }

    override public func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) {
        selectionManager.moveSelections(direction: .up, destination: .document, modifySelection: true)
        updateAfterMove()
    }

    override public func moveToEndOfDocument(_ sender: Any?) {
        selectionManager.moveSelections(direction: .down, destination: .document)
        updateAfterMove()
    }

    override public func moveToEndOfDocumentAndModifySelection(_ sender: Any?) {
        selectionManager.moveSelections(direction: .down, destination: .document, modifySelection: true)
        updateAfterMove()
    }

    // Logical direction. This view lays out left to right only, so forward is right.
    override public func moveForward(_ sender: Any?) {
        moveRight(sender)
    }

    override public func moveForwardAndModifySelection(_ sender: Any?) {
        moveRightAndModifySelection(sender)
    }

    override public func moveBackward(_ sender: Any?) {
        moveLeft(sender)
    }

    override public func moveBackwardAndModifySelection(_ sender: Any?) {
        moveLeftAndModifySelection(sender)
    }

    override public func moveWordForward(_ sender: Any?) {
        moveWordRight(sender)
    }

    override public func moveWordForwardAndModifySelection(_ sender: Any?) {
        moveWordRightAndModifySelection(sender)
    }

    override public func moveWordBackward(_ sender: Any?) {
        moveWordLeft(sender)
    }

    override public func moveWordBackwardAndModifySelection(_ sender: Any?) {
        moveWordLeftAndModifySelection(sender)
    }

    override public func moveToBeginningOfLine(_ sender: Any?) {
        moveToLeftEndOfLine(sender)
    }

    override public func moveToEndOfLine(_ sender: Any?) {
        moveToRightEndOfLine(sender)
    }

    override public func moveToBeginningOfLineAndModifySelection(_ sender: Any?) {
        moveToLeftEndOfLineAndModifySelection(sender)
    }

    override public func moveToEndOfLineAndModifySelection(_ sender: Any?) {
        moveToRightEndOfLineAndModifySelection(sender)
    }

    override public func centerSelectionInVisibleArea(_ sender: Any?) {
        guard let scrollView,
              let selection = selectionManager.textSelections.first,
              let rect = layoutManager.rectForOffset(selection.range.location) else { return }
        let visibleHeight = scrollView.contentView.bounds.height
        let targetY = max(rect.midY - visibleHeight / 2, 0)
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
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
