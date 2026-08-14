//
//  PopoverPresenter.swift
//  TablePro
//
//  Lightweight utility to show SwiftUI views in NSPopover from AppKit contexts.
//

import AppKit
import SwiftUI

@MainActor
enum PopoverPresenter {
    /// Shows a SwiftUI view in an NSPopover anchored to an AppKit view.
    /// The content closure receives a dismiss action to close the popover.
    @discardableResult
    static func show<Content: View>(
        relativeTo bounds: NSRect,
        of view: NSView,
        preferredEdge: NSRectEdge = .maxY,
        contentSize: NSSize? = nil,
        behavior: NSPopover.Behavior = .semitransient,
        @ViewBuilder content: (_ dismiss: @escaping () -> Void) -> Content
    ) -> NSPopover {
        let popover = NSPopover()
        let dismiss: () -> Void = { [weak popover] in popover?.close() }
        let hostingController = NSHostingController(rootView: content(dismiss))
        popover.contentViewController = hostingController
        popover.behavior = behavior
        if let size = contentSize {
            popover.contentSize = size
        }
        popover.show(relativeTo: bounds, of: view, preferredEdge: preferredEdge)
        return popover
    }
}
