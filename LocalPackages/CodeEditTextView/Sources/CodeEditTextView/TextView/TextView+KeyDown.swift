//
//  TextView+KeyDown.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 6/15/24.
//

import AppKit
import Carbon.HIToolbox

extension TextView {
    override public func keyDown(with event: NSEvent) {
        guard isEditable else {
            super.keyDown(with: event)
            return
        }

        NSCursor.setHiddenUntilMouseMoves(true)

        // Handle Home/End explicitly — AppKit's default key bindings map these
        // to scrollToBeginningOfDocument:/scrollToEndOfDocument: which only
        // scroll without moving the cursor. We redirect to move actions instead.
        if handleHomeEndKey(event) {
            return
        }

        if !(inputContext?.handleEvent(event) ?? false) {
            interpretKeyEvents([event])
        } else {
            // Not handled, ignore so we don't double trigger events.
            return
        }
    }

    /// Handles Home and End key combinations.
    /// - Returns: `true` if the event was handled.
    private func handleHomeEndKey(_ event: NSEvent) -> Bool {
        let keyCode = Int(event.keyCode)
        guard keyCode == kVK_Home || keyCode == kVK_End else { return false }

        let shift = event.modifierFlags.contains(.shift)
        let cmd = event.modifierFlags.contains(.command)

        if keyCode == kVK_Home {
            switch (cmd, shift) {
            case (true, true): moveToBeginningOfDocumentAndModifySelection(self)
            case (true, false): moveToBeginningOfDocument(self)
            case (false, true): moveToLeftEndOfLineAndModifySelection(self)
            case (false, false): moveToLeftEndOfLine(self)
            }
        } else {
            switch (cmd, shift) {
            case (true, true): moveToEndOfDocumentAndModifySelection(self)
            case (true, false): moveToEndOfDocument(self)
            case (false, true): moveToRightEndOfLineAndModifySelection(self)
            case (false, false): moveToRightEndOfLine(self)
            }
        }
        return true
    }

    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isEditable else {
            return super.performKeyEquivalent(with: event)
        }

        switch Int(event.keyCode) {
        case kVK_PageUp:
            if !event.modifierFlags.contains(.shift) {
                self.pageUp(event)
                return true
            }
        case kVK_PageDown:
            if !event.modifierFlags.contains(.shift) {
                self.pageDown(event)
                return true
            }
        default:
            return false
        }

        return false
    }

    override public func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)

        let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let modifierFlagsIsOption = modifierFlags == [.option]

        if modifierFlagsIsOption != isOptionPressed {
            isOptionPressed = modifierFlagsIsOption
            resetCursorRects()
        }
    }
}
