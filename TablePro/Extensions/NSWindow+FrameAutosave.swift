//
//  NSWindow+FrameAutosave.swift
//  TablePro
//

import AppKit

extension NSWindow {
    /// Not for a window whose content is an `NSSplitViewController`: its resize during init fires the
    /// autosave and overwrites the saved frame. `TabWindowController` restores and saves by hand instead.
    @MainActor
    func applyAutosaveName(_ name: NSWindow.FrameAutosaveName) {
        guard let scoped = SplitViewAutosaveName.current(name) else {
            center()
            return
        }
        setFrameAutosaveName(scoped)
        if !setFrameUsingName(scoped) {
            center()
        }
    }

    func setFrame(usingAutosaveName name: NSWindow.FrameAutosaveName?) -> Bool {
        guard let name else { return false }
        return setFrameUsingName(name)
    }

    func saveFrame(usingAutosaveName name: NSWindow.FrameAutosaveName?) {
        guard let name else { return }
        saveFrame(usingName: name)
    }
}
