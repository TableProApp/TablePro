//
//  TextView+FirstResponder.swift
//  TableProTextEngine
//
//  Created by Khan Winter on 6/15/24.
//

import AppKit

extension TextView {
    override open func becomeFirstResponder() -> Bool {
        isFirstResponder = true
        selectionManager.cursorTimer.resetTimer()
        selectionManager.updateSelectionViews(force: true)
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override open func resignFirstResponder() -> Bool {
        isFirstResponder = false
        selectionManager.removeCursors()
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override open var canBecomeKeyView: Bool {
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

    override open var needsPanelToBecomeKey: Bool {
        isSelectable || isEditable
    }

    override open var acceptsFirstResponder: Bool {
        isSelectable
    }

    override open func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override open func resetCursorRects() {
        super.resetCursorRects()
        if isSelectable {
            addCursorRect(
                visibleRect,
                cursor: isOptionPressed ? .crosshair : .iBeam
            )
        }
    }
}
