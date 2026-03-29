//
//  TextView+FirstResponder.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 6/15/24.
//

import AppKit

extension TextView {
    open override func becomeFirstResponder() -> Bool {
        isFirstResponder = true
        selectionManager.cursorTimer.resetTimer()
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    open override func resignFirstResponder() -> Bool {
        isFirstResponder = false
        selectionManager.removeCursors()
        needsDisplay = true
        return super.resignFirstResponder()
    }

    open override var canBecomeKeyView: Bool {
        super.canBecomeKeyView && acceptsFirstResponder && !isHiddenOrHasHiddenAncestor
    }

    /// Sent to the window's first responder when `NSWindow.makeKey()` occurs.
    @objc private func becomeKeyWindow() {
        _ = becomeFirstResponder()
    }

    /// Sent to the window's first responder when `NSWindow.resignKey()` occurs.
    @objc private func resignKeyWindow() {
        _ = resignFirstResponder()
    }

    open override var needsPanelToBecomeKey: Bool {
        isSelectable || isEditable
    }

    open override var acceptsFirstResponder: Bool {
        isSelectable
    }

    open override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    open override func resetCursorRects() {
        super.resetCursorRects()
        if isSelectable {
            addCursorRect(
                visibleRect,
                cursor: isOptionPressed ? .crosshair : .iBeam
            )
        }
    }
}
