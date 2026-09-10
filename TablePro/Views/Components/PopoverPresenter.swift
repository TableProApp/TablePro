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
        let popover = make(contentSize: contentSize, behavior: behavior, content: content)
        popover.show(relativeTo: bounds, of: view, preferredEdge: preferredEdge)
        return popover
    }

    /// Shows a SwiftUI view in an NSPopover anchored to a toolbar item.
    ///
    /// AppKit resolves the anchor itself: "When the item is in the overflow menu, the popover will
    /// be presented from another appropriate affordance in the window." That is the whole reason
    /// this overload exists, because a popover declared inside the item's own hosted view cannot
    /// present at all once the item is clipped, and a clipped item survives only as its
    /// `menuFormRepresentation`.
    ///
    /// The caller must have resolved `toolbarItem` out of a visible toolbar. AppKit throws
    /// `NSInvalidArgumentException` when it cannot locate the item, which Swift cannot catch, so
    /// the check belongs at the call site as a precondition rather than here as error handling.
    @discardableResult
    static func show<Content: View>(
        relativeTo toolbarItem: NSToolbarItem,
        contentSize: NSSize? = nil,
        behavior: NSPopover.Behavior = .semitransient,
        @ViewBuilder content: (_ dismiss: @escaping () -> Void) -> Content
    ) -> NSPopover {
        let popover = make(contentSize: contentSize, behavior: behavior, content: content)
        popover.show(relativeTo: toolbarItem)
        return popover
    }

    /// Builds the popover without presenting it, so its sizing can be asserted in tests.
    ///
    /// `NSPopover` computes where to put itself from `contentSize` at `show` time, and its header's
    /// promise that the size "is set to match the size of the content view when the content view
    /// controller is set" does not hold for an `NSHostingController`: that view's frame is still
    /// zero at assignment. `NSHostingController` defaults to `.standardBounds`, which leaves
    /// `preferredContentSize` at zero, so AppKit falls back to its own 320x320 default, places the
    /// popover for that phantom box, and then lets Auto Layout grow the window from the origin it
    /// already picked. The popover ends up above and left of the control it points at, which put
    /// the data grid's column value filter over the toolbar.
    ///
    /// `.preferredContentSize` alone is what publishes the real size in time, and it must not be
    /// combined with `.standardBounds`, which reinstates the broken default. A caller's
    /// `contentSize` is therefore applied to the SwiftUI content rather than to the popover, so
    /// the two can never disagree about how big the popover is.
    static func make<Content: View>(
        contentSize: NSSize? = nil,
        behavior: NSPopover.Behavior = .semitransient,
        @ViewBuilder content: (_ dismiss: @escaping () -> Void) -> Content
    ) -> NSPopover {
        let popover = NSPopover()
        let dismiss: () -> Void = { [weak popover] in popover?.close() }
        let hostingController = NSHostingController(
            rootView: content(dismiss)
                .frame(width: contentSize?.width, height: contentSize?.height)
        )
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController
        popover.behavior = behavior
        return popover
    }
}
