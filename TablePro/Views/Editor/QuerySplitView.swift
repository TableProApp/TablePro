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
        let splitViewController = NSSplitViewController()
        splitViewController.splitView.isVertical = false
        splitViewController.splitView.dividerStyle = .thin
        splitViewController.splitView.autosaveName = autosaveName

        let topController = NSHostingController(rootView: topContent)
        let topItem = NSSplitViewItem(viewController: topController)
        topItem.minimumThickness = 100

        let bottomController = NSHostingController(rootView: bottomContent)
        let bottomItem = NSSplitViewItem(viewController: bottomController)
        bottomItem.canCollapse = true
        bottomItem.minimumThickness = 150

        splitViewController.addSplitViewItem(topItem)
        splitViewController.addSplitViewItem(bottomItem)

        context.coordinator.topController = topController
        context.coordinator.bottomController = bottomController
        context.coordinator.bottomItem = bottomItem
        context.coordinator.lastCollapsedState = isBottomCollapsed

        if isBottomCollapsed {
            bottomItem.isCollapsed = true
        }

        return splitViewController
    }

    func updateNSViewController(_ splitViewController: NSSplitViewController, context: Context) {
        context.coordinator.topController?.rootView = topContent
        context.coordinator.bottomController?.rootView = bottomContent

        guard let bottomItem = context.coordinator.bottomItem else { return }
        let wasCollapsed = context.coordinator.lastCollapsedState

        if isBottomCollapsed != wasCollapsed {
            context.coordinator.lastCollapsedState = isBottomCollapsed
            let collapse = isBottomCollapsed
            DispatchQueue.main.async {
                bottomItem.animator().isCollapsed = collapse
            }
        }
    }

    final class Coordinator {
        var topController: NSHostingController<TopContent>?
        var bottomController: NSHostingController<BottomContent>?
        var bottomItem: NSSplitViewItem?
        var lastCollapsedState = false
    }
}
