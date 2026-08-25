//
//  AutosavingSplitView.swift
//  TablePro
//
//  A split view whose divider position persists via NSSplitView.autosaveName.
//  autosaveName is assigned after the items are added; setting it earlier does not record
//  the divider, and adjustSubviews then resets it.
//

import AppKit
import SwiftUI

struct AutosavingSplitView<Primary: View, Secondary: View>: NSViewControllerRepresentable {
    let autosaveName: String
    var isVertical = true
    var primaryMinimum: CGFloat
    var primaryMaximum: CGFloat?
    var secondaryMinimum: CGFloat

    /// The share of the width the primary pane takes before the user has ever dragged the divider.
    /// `NSSplitViewItem.contentListWithViewController` sets 0.33 for a list beside a detail view,
    /// "akin to Mail's message list", and caps automatic sizing at 576pt so a wide display grows
    /// the detail pane rather than the list. Nil keeps the previous behaviour, where the first
    /// layout fell out of the minimums.
    var primaryThicknessFraction: CGFloat?
    var primaryAutomaticMaximum: CGFloat?
    var primaryHoldingPriority: NSLayoutConstraint.Priority = .splitPaneHolding
    var collapsesPrimaryWhenTight = false
    @ViewBuilder let primary: () -> Primary
    @ViewBuilder let secondary: () -> Secondary

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSViewController(context: Context) -> CollapsingSplitViewController {
        let controller = CollapsingSplitViewController()
        controller.collapsesPrimaryWhenTight = collapsesPrimaryWhenTight
        controller.splitView.isVertical = isVertical
        controller.splitView.dividerStyle = .thin

        let primaryController = NSHostingController(rootView: primary())
        let secondaryController = NSHostingController(rootView: secondary())

        // Without this the hosting controllers report their SwiftUI content's ideal size as a
        // preferredContentSize, which an enclosing NSSplitViewController forwards to the window:
        // the window shrinks to fit the content and stops being resizable.
        primaryController.sizingOptions = []
        secondaryController.sizingOptions = []

        context.coordinator.primaryController = primaryController
        context.coordinator.secondaryController = secondaryController

        let primaryItem = NSSplitViewItem(viewController: primaryController)
        primaryItem.minimumThickness = primaryMinimum
        primaryItem.canCollapse = collapsesPrimaryWhenTight
        primaryItem.holdingPriority = primaryHoldingPriority
        if let primaryMaximum {
            primaryItem.maximumThickness = primaryMaximum
        }
        if let primaryThicknessFraction {
            primaryItem.preferredThicknessFraction = primaryThicknessFraction
        }
        if let primaryAutomaticMaximum {
            primaryItem.automaticMaximumThickness = primaryAutomaticMaximum
        }

        let secondaryItem = NSSplitViewItem(viewController: secondaryController)
        secondaryItem.minimumThickness = secondaryMinimum
        secondaryItem.canCollapse = false
        secondaryItem.holdingPriority = .defaultLow

        controller.addSplitViewItem(primaryItem)
        controller.addSplitViewItem(secondaryItem)
        controller.splitView.autosaveName = NSSplitView.AutosaveName(autosaveName)
        return controller
    }

    func updateNSViewController(_ controller: CollapsingSplitViewController, context: Context) {
        controller.collapsesPrimaryWhenTight = collapsesPrimaryWhenTight
        context.coordinator.primaryController?.rootView = primary()
        context.coordinator.secondaryController?.rootView = secondary()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsViewController: CollapsingSplitViewController,
        context: Context
    ) -> CGSize? {
        let natural = primaryMinimum + secondaryMinimum
        let resolved = proposal.replacingUnspecifiedDimensions(
            by: CGSize(width: natural, height: natural)
        )
        guard resolved.width.isFinite, resolved.height.isFinite else { return nil }
        return resolved
    }

    final class Coordinator {
        var primaryController: NSHostingController<Primary>?
        var secondaryController: NSHostingController<Secondary>?
    }
}

@MainActor
internal final class CollapsingSplitViewController: ResizeCursorSplitViewController {
    var collapsesPrimaryWhenTight = false

    private var didAutoCollapsePrimary = false

    override func viewDidLayout() {
        super.viewDidLayout()
        applyAutomaticCollapse()
    }

    private func applyAutomaticCollapse() {
        guard collapsesPrimaryWhenTight, splitView.isVertical else { return }
        guard splitViewItems.count == 2 else { return }

        let primaryItem = splitViewItems[0]
        let secondaryItem = splitViewItems[1]

        let available = splitView.bounds.width
        guard available > 0 else { return }

        let required = primaryItem.minimumThickness
            + secondaryItem.minimumThickness
            + splitView.dividerThickness

        guard available >= required else {
            guard !primaryItem.isCollapsed else { return }
            primaryItem.isCollapsed = true
            didAutoCollapsePrimary = true
            return
        }

        guard didAutoCollapsePrimary, primaryItem.isCollapsed else { return }
        primaryItem.isCollapsed = false
        didAutoCollapsePrimary = false
    }
}
