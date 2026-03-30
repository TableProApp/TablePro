//
//  QuerySplitView.swift
//  TablePro
//
//  NSSplitViewController wrapper for the query editor / results split.
//  Uses NSSplitViewItem.isCollapsed for proper collapse/expand with divider
//  position preservation, and autosaveName for cross-session persistence.
//

import AppKit
import SwiftUI

struct QuerySplitView<TopContent: View, BottomContent: View>: NSViewControllerRepresentable {
    var isBottomCollapsed: Bool
    var autosaveName: String
    @ViewBuilder var topContent: TopContent
    @ViewBuilder var bottomContent: BottomContent

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSViewController(context: Context) -> NSSplitViewController {
        let splitVC = NSSplitViewController()
        splitVC.splitView.isVertical = false
        splitVC.splitView.dividerStyle = .thin
        splitVC.splitView.autosaveName = autosaveName

        let topHosting = NSHostingController(rootView: topContent)
        topHosting.sizingOptions = []
        let bottomHosting = NSHostingController(rootView: bottomContent)
        bottomHosting.sizingOptions = []

        let topItem = NSSplitViewItem(viewController: topHosting)
        topItem.minimumThickness = 100
        topItem.holdingPriority = .init(240)

        let bottomItem = NSSplitViewItem(viewController: bottomHosting)
        bottomItem.minimumThickness = 150
        bottomItem.holdingPriority = .init(260)
        bottomItem.canCollapse = true
        bottomItem.isCollapsed = isBottomCollapsed

        splitVC.addSplitViewItem(topItem)
        splitVC.addSplitViewItem(bottomItem)

        context.coordinator.topHostingController = topHosting
        context.coordinator.bottomHostingController = bottomHosting

        return splitVC
    }

    func updateNSViewController(_ splitVC: NSSplitViewController, context: Context) {
        guard splitVC.splitViewItems.count == 2 else { return }
        let bottomItem = splitVC.splitViewItems[1]
        if bottomItem.isCollapsed != isBottomCollapsed {
            bottomItem.animator().isCollapsed = isBottomCollapsed
        }

        context.coordinator.topHostingController?.rootView = topContent
        context.coordinator.bottomHostingController?.rootView = bottomContent
    }

    final class Coordinator: NSObject, NSSplitViewDelegate {
        var topHostingController: NSHostingController<TopContent>?
        var bottomHostingController: NSHostingController<BottomContent>?

        func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
            subview == splitView.subviews.last
        }
    }
}
