//
//  ToolbarVisibility.swift
//  TablePro
//

import AppKit

/// Which of the connection window's toolbar items the app has taken out of the titlebar.
///
/// The app's own record, and the only answer to "is this item on screen" anything may act on.
/// AppKit's readings of the same question are measured unsafe on macOS 27: after one visit to
/// Customize Toolbar, `NSToolbar.visibleItems` and `NSToolbarItem.isVisible` over-report for good,
/// listing 6 items against 2 laid out at a 460pt window and calling a hidden item visible, and no
/// resize, re-toggle or re-insert repaired either. The error always runs toward "on screen", which
/// is the direction that hands `NSPopover` an anchor with no window.
///
/// Its own file so `ToolbarSwitcherPresenter` can take one without reaching into the resolver.
internal struct ToolbarVisibility: Equatable {
    internal let hidden: Set<NSToolbarItem.Identifier>

    internal init(hidden: Set<NSToolbarItem.Identifier> = []) {
        self.hidden = hidden
    }

    internal func hides(_ identifier: NSToolbarItem.Identifier) -> Bool {
        hidden.contains(identifier)
    }
}
