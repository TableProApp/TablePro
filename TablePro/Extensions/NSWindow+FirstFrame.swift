//
//  NSWindow+FirstFrame.swift
//  TablePro
//

import AppKit
import QuartzCore

internal extension NSWindow {
    /// Runs `body` once Core Animation has committed the frame this window is about to present.
    ///
    /// AppKit orders a window in immediately and Core Animation draws it on the next commit, so
    /// ordering and presenting are a whole frame apart and only the second is what a person sees.
    /// Anything scheduled from here therefore starts after the window is on screen rather than
    /// competing with it for the main thread.
    func afterNextFrame(_ body: @escaping () -> Void) {
        CATransaction.begin()
        CATransaction.setCompletionBlock(body)
        displayIfNeeded()
        CATransaction.commit()
    }
}
