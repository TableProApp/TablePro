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

        if !(inputContext?.handleEvent(event) ?? false) {
            interpretKeyEvents([event])
        } else {
            // Not handled, ignore so we don't double trigger events.
            return
        }
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
