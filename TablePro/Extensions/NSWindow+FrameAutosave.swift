//
//  NSWindow+FrameAutosave.swift
//  TablePro
//

import AppKit

extension NSWindow {
    func applyAutosaveName(_ name: NSWindow.FrameAutosaveName) {
        setFrameAutosaveName(name)
        if !setFrameUsingName(name) {
            center()
        }
    }
}
