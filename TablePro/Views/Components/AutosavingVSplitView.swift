//
//  AutosavingVSplitView.swift
//  TablePro
//
//  A vertically stacked split view whose divider position persists via NSSplitView.autosaveName.
//

import AppKit
import SwiftUI

struct AutosavingVSplitView<Top: View, Bottom: View>: NSViewControllerRepresentable {
    let autosaveName: String
    let topMinimumHeight: CGFloat
    let bottomMinimumHeight: CGFloat
    @ViewBuilder let top: () -> Top
    @ViewBuilder let bottom: () -> Bottom

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSViewController(context: Context) -> NSSplitViewController {
        let controller = NSSplitViewController()
        controller.splitView.isVertical = false
        controller.splitView.dividerStyle = .thin

        let topController = NSHostingController(rootView: top())
        let bottomController = NSHostingController(rootView: bottom())
        context.coordinator.topController = topController
        context.coordinator.bottomController = bottomController

        let topItem = NSSplitViewItem(viewController: topController)
        topItem.minimumThickness = topMinimumHeight
        topItem.canCollapse = false
        let bottomItem = NSSplitViewItem(viewController: bottomController)
        bottomItem.minimumThickness = bottomMinimumHeight
        bottomItem.canCollapse = false

        controller.addSplitViewItem(topItem)
        controller.addSplitViewItem(bottomItem)
        controller.splitView.autosaveName = NSSplitView.AutosaveName(autosaveName)
        return controller
    }

    func updateNSViewController(_ controller: NSSplitViewController, context: Context) {
        context.coordinator.topController?.rootView = top()
        context.coordinator.bottomController?.rootView = bottom()
    }

    final class Coordinator {
        var topController: NSHostingController<Top>?
        var bottomController: NSHostingController<Bottom>?
    }
}
