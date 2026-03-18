//
//  NoSlotScroller.swift
//  CodeEditSourceEditor
//
//  Created by Abe Malla on 12/26/24.
//

import AppKit

class NoSlotScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // Don't draw the knob slot (the background track behind the knob)
    }
}
