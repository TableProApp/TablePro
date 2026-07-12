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
    var primaryHoldingPriority: NSLayoutConstraint.Priority = .defaultHigh
    @ViewBuilder let primary: () -> Primary
    @ViewBuilder let secondary: () -> Secondary

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSViewController(context: Context) -> NSSplitViewController {
        let controller = NSSplitViewController()
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
        primaryItem.canCollapse = false
        primaryItem.holdingPriority = primaryHoldingPriority
        if let primaryMaximum {
            primaryItem.maximumThickness = primaryMaximum
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

    func updateNSViewController(_ controller: NSSplitViewController, context: Context) {
        context.coordinator.primaryController?.rootView = primary()
        context.coordinator.secondaryController?.rootView = secondary()
    }

    final class Coordinator {
        var primaryController: NSHostingController<Primary>?
        var secondaryController: NSHostingController<Secondary>?
    }
}
