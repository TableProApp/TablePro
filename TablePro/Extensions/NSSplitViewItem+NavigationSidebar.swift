//
//  NSSplitViewItem+NavigationSidebar.swift
//  TablePro
//

import AppKit

internal extension NSSplitViewItem {
    /// A sidebar that is its window's only navigation, the way System Settings' is: it resizes and
    /// never collapses. Dragged shut, it takes every section with it, and `NSSplitViewController`
    /// hides the divider it would be dragged back by, which leaves the window stuck on one page.
    ///
    /// With `canCollapse` off AppKit also dims Show Sidebar for the window and turns off
    /// `canCollapseFromWindowResize`, so no route collapses it.
    static func navigationSidebar(_ viewController: NSViewController) -> NSSplitViewItem {
        let item = NSSplitViewItem(sidebarWithViewController: viewController)
        item.canCollapse = false
        return item
    }
}
