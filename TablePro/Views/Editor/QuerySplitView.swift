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

        let topVC = HostingPaneController(rootView: topContent)
        let bottomVC = HostingPaneController(rootView: bottomContent)

        let topItem = NSSplitViewItem(viewController: topVC)
        topItem.minimumThickness = 100
        topItem.holdingPriority = .init(240)

        let bottomItem = NSSplitViewItem(viewController: bottomVC)
        bottomItem.minimumThickness = 150
        bottomItem.holdingPriority = .init(260)
        bottomItem.canCollapse = true
        bottomItem.isCollapsed = isBottomCollapsed

        splitVC.addSplitViewItem(topItem)
        splitVC.addSplitViewItem(bottomItem)

        context.coordinator.topVC = topVC
        context.coordinator.bottomVC = bottomVC

        return splitVC
    }

    func updateNSViewController(_ splitVC: NSSplitViewController, context: Context) {
        guard splitVC.splitViewItems.count == 2 else { return }
        let bottomItem = splitVC.splitViewItems[1]
        if bottomItem.isCollapsed != isBottomCollapsed {
            bottomItem.animator().isCollapsed = isBottomCollapsed
        }

        context.coordinator.topVC?.update(rootView: topContent)
        context.coordinator.bottomVC?.update(rootView: bottomContent)
    }

    final class Coordinator: NSObject, NSSplitViewDelegate {
        var topVC: HostingPaneController<TopContent>?
        var bottomVC: HostingPaneController<BottomContent>?

        func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
            subview == splitView.subviews.last
        }
    }
}

// MARK: - Hosting Pane Controller

/// Embeds NSHostingView in a plain NSView container. The container uses
/// frame-based layout (for NSSplitView), while the hosting view is pinned
/// to all edges via Auto Layout with low compression resistance so the
/// split view divider can freely resize panes.
final class HostingPaneController<Content: View>: NSViewController {
    private var hostingView: NSHostingView<Content>

    init(rootView: Content) {
        self.hostingView = NSHostingView(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView()
        container.autoresizingMask = [.width, .height]

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        hostingView.setContentHuggingPriority(.defaultLow - 1, for: .vertical)
        hostingView.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        hostingView.setContentCompressionResistancePriority(.defaultLow - 1, for: .vertical)
        container.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        view = container
    }

    func update(rootView: Content) {
        hostingView.rootView = rootView
    }
}
