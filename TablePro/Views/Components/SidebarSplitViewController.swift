//
//  SidebarSplitViewController.swift
//  TablePro
//

import AppKit
import Combine
import SwiftUI

/// What a sidebar window's list has selected. The sidebar and the detail pane are separate hosting
/// controllers, so the selection lives here rather than in either view's state.
@MainActor
internal final class SidebarSelection<Value: Hashable>: ObservableObject {
    @Published var value: Value?

    internal init(_ value: Value? = nil) {
        self.value = value
    }
}

/// A window whose navigation is a sidebar list beside a detail pane, built from AppKit split items.
///
/// Not `NavigationSplitView`: its sidebar collapses when the divider is dragged shut whatever its
/// column visibility says, and in a window AppKit hosts it shows no button to bring it back.
@MainActor
internal final class SidebarSplitViewController: NSSplitViewController {
    private let sidebarController: NSViewController
    private let detailController: NSViewController
    private let sidebarThickness: ClosedRange<CGFloat>
    private let idealSidebarThickness: CGFloat
    private let detailMinimumThickness: CGFloat

    internal init(
        sidebar: some View,
        detail: some View,
        sidebarThickness: ClosedRange<CGFloat>,
        idealSidebarThickness: CGFloat,
        detailMinimumThickness: CGFloat
    ) {
        let sidebarHost = NSHostingController(rootView: sidebar)
        sidebarHost.sizingOptions = []
        let detailHost = NSHostingController(rootView: detail)
        detailHost.sizingOptions = []
        /// Scene bridging is how the detail's `.toolbar`, `.searchable` and `.navigationTitle` reach
        /// the window, and it is macOS 14. On 13 the pane contributes none of them.
        if #available(macOS 14.0, *) {
            detailHost.sceneBridgingOptions = [.toolbars, .title]
        }
        sidebarController = sidebarHost
        detailController = detailHost
        self.sidebarThickness = sidebarThickness
        self.idealSidebarThickness = idealSidebarThickness
        self.detailMinimumThickness = detailMinimumThickness
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    internal required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override internal func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true

        /// The split view opens each pane at its view's own width, clamped to the item's range, so
        /// this is the width the sidebar starts at. Without it the sidebar opens at its minimum.
        sidebarController.view.frame.size.width = idealSidebarThickness
        let sidebarItem = NSSplitViewItem.navigationSidebar(sidebarController)
        sidebarItem.minimumThickness = sidebarThickness.lowerBound
        sidebarItem.maximumThickness = sidebarThickness.upperBound
        sidebarItem.holdingPriority = .splitPaneHolding
        addSplitViewItem(sidebarItem)

        let detailItem = NSSplitViewItem(viewController: detailController)
        detailItem.minimumThickness = detailMinimumThickness
        detailItem.holdingPriority = .defaultLow
        addSplitViewItem(detailItem)
    }
}
