//
//  PlainControllerView.swift
//  TableProEditorKit
//

import AppKit

internal enum PlainControllerView {
    /// What `NSViewController.loadView()` builds for a controller that has no nib. macOS 13 raises
    /// there instead of building it, because it looks for a nib named after the class first, so the
    /// two controllers in this module build it by hand on 13 and keep `super` on 14.
    ///
    /// A bare `NSView()` is not the same view. Measured against the default implementation: the
    /// frame is 500pt square rather than zero, and the autoresizing mask is `[.width, .height]`
    /// rather than empty. The mask is the load-bearing half. With `translatesAutoresizingMask`
    /// left on, an empty mask pins the view at the size it was born with, so an editor built this
    /// way stays at zero size and draws nothing.
    internal static func make() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        view.autoresizingMask = [.width, .height]
        return view
    }
}
