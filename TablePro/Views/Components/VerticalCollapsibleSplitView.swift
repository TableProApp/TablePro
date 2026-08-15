import AppKit
import SwiftUI

struct VerticalCollapsibleSplitView<TopContent: View, BottomContent: View>: NSViewControllerRepresentable {
    static var defaultTopMinimumThickness: CGFloat { 100 }
    static var defaultBottomMinimumThickness: CGFloat { 150 }

    /// What a split using the defaults needs before its own constraints become unsatisfiable.
    /// An enclosing split whose pane hosts one of these must not promise less than this.
    static var combinedMinimumThickness: CGFloat {
        defaultTopMinimumThickness + defaultBottomMinimumThickness + 10
    }

    @Binding var isBottomCollapsed: Bool
    var autosaveName: String
    var topMinimumThickness: CGFloat = VerticalCollapsibleSplitView.defaultTopMinimumThickness
    var bottomMinimumThickness: CGFloat = VerticalCollapsibleSplitView.defaultBottomMinimumThickness
    @ViewBuilder var topContent: TopContent
    @ViewBuilder var bottomContent: BottomContent

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSViewController(context: Context) -> NSSplitViewController {
        let splitViewController = ResizeCursorSplitViewController()
        splitViewController.splitView.isVertical = false
        splitViewController.splitView.dividerStyle = .thin

        let topController = NSHostingController(rootView: topContent)
        let topItem = NSSplitViewItem(viewController: topController)
        topItem.minimumThickness = topMinimumThickness

        let bottomController = NSHostingController(rootView: bottomContent)
        let bottomItem = NSSplitViewItem(viewController: bottomController)
        bottomItem.canCollapse = true
        bottomItem.minimumThickness = bottomMinimumThickness

        // Without this the hosting controllers report their content's ideal size as a
        // preferredContentSize, which this split view forwards to the window: wide results
        // content then outranks a divider drag and the editor/results divider stops moving.
        topController.sizingOptions = []
        bottomController.sizingOptions = []

        splitViewController.addSplitViewItem(topItem)
        splitViewController.addSplitViewItem(bottomItem)

        // autosaveName is assigned after the items are added; setting it earlier does not record
        // the divider, and adjustSubviews then resets it.
        splitViewController.splitView.autosaveName = autosaveName

        context.coordinator.topController = topController
        context.coordinator.bottomController = bottomController
        context.coordinator.bottomItem = bottomItem
        context.coordinator.lastCollapsedState = isBottomCollapsed
        context.coordinator.onUserCollapseChange = { collapsed in
            guard isBottomCollapsed != collapsed else { return }
            isBottomCollapsed = collapsed
        }
        context.coordinator.observeCollapse(of: bottomItem)

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

        context.coordinator.onUserCollapseChange = { collapsed in
            guard isBottomCollapsed != collapsed else { return }
            isBottomCollapsed = collapsed
        }

        guard isBottomCollapsed != wasCollapsed else { return }
        context.coordinator.lastCollapsedState = isBottomCollapsed
        context.coordinator.applyProgrammatically {
            bottomItem.animator().isCollapsed = isBottomCollapsed
        }
    }

    /// The divider is draggable and double-clickable, so AppKit owns this state as much as
    /// SwiftUI does. Observing it back keeps the persisted value honest instead of letting the
    /// two drift until the next programmatic toggle snaps the pane back.
    final class Coordinator {
        var topController: NSHostingController<TopContent>?
        var bottomController: NSHostingController<BottomContent>?
        var bottomItem: NSSplitViewItem?
        var lastCollapsedState = false
        var onUserCollapseChange: ((Bool) -> Void)?

        private var collapseObservation: NSKeyValueObservation?
        private var isApplyingProgrammatically = false

        func observeCollapse(of item: NSSplitViewItem) {
            collapseObservation = item.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
                MainActor.assumeIsolated {
                    guard let self, !self.isApplyingProgrammatically else { return }
                    self.lastCollapsedState = item.isCollapsed
                    self.onUserCollapseChange?(item.isCollapsed)
                }
            }
        }

        func applyProgrammatically(_ body: () -> Void) {
            isApplyingProgrammatically = true
            defer { isApplyingProgrammatically = false }
            body()
        }
    }
}
