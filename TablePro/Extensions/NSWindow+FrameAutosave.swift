//
//  NSWindow+FrameAutosave.swift
//  TablePro
//

import AppKit

extension NSWindow {
    /// Do not call on a window owned by an `NSWindowController` whose
    /// `contentViewController` is an `NSSplitViewController`. The contentVC's
    /// intrinsic-size resize during init fires the implicit auto-save observer
    /// installed by `setFrameAutosaveName`, overwriting the persisted frame
    /// with the small intrinsic size. Use `setFrameUsingName` plus explicit
    /// `saveFrame(usingName:)` calls in `NSWindowDelegate` methods instead.
    /// See `TabWindowController` for that pattern.
    func applyAutosaveName(_ name: NSWindow.FrameAutosaveName) {
        setFrameAutosaveName(name)
        if !setFrameUsingName(name) {
            center()
        }
    }
}
