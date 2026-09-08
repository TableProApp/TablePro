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
    /// Namespaced per sandbox under UI test: a saved frame lands in the standard defaults domain,
    /// which the sandbox does not redirect, so without this one case inherits another's window
    /// position and size. See `SplitViewAutosaveName`.
    @MainActor
    func applyAutosaveName(_ name: NSWindow.FrameAutosaveName) {
        let scoped = NSWindow.FrameAutosaveName(SplitViewAutosaveName.current(name))
        setFrameAutosaveName(scoped)
        if !setFrameUsingName(scoped) {
            center()
        }
    }
}
