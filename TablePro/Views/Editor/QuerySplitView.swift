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

        let topContainer = HostingContainerController(rootView: topContent)
        let bottomContainer = HostingContainerController(rootView: bottomContent)

        let topItem = NSSplitViewItem(viewController: topContainer)
        topItem.minimumThickness = 100
        topItem.holdingPriority = .init(240)

        let bottomItem = NSSplitViewItem(viewController: bottomContainer)
        bottomItem.minimumThickness = 150
        bottomItem.holdingPriority = .init(260)
        bottomItem.canCollapse = true
        bottomItem.isCollapsed = isBottomCollapsed

        splitVC.addSplitViewItem(topItem)
        splitVC.addSplitViewItem(bottomItem)

        context.coordinator.topContainer = topContainer
        context.coordinator.bottomContainer = bottomContainer

        return splitVC
    }

    func updateNSViewController(_ splitVC: NSSplitViewController, context: Context) {
        guard splitVC.splitViewItems.count == 2 else { return }
        let bottomItem = splitVC.splitViewItems[1]
        if bottomItem.isCollapsed != isBottomCollapsed {
            bottomItem.animator().isCollapsed = isBottomCollapsed
        }

        context.coordinator.topContainer?.hostingController.rootView = topContent
        context.coordinator.bottomContainer?.hostingController.rootView = bottomContent
    }

    final class Coordinator: NSObject, NSSplitViewDelegate {
        var topContainer: HostingContainerController<TopContent>?
        var bottomContainer: HostingContainerController<BottomContent>?

        func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
            subview == splitView.subviews.last
        }
    }
}

// MARK: - Hosting Container

/// Wraps NSHostingController in a plain NSViewController with Auto Layout
/// constraints pinning the hosted SwiftUI view to all edges. This ensures
/// the SwiftUI content fills the NSSplitView pane instead of rendering
/// at its intrinsic size.
final class HostingContainerController<Content: View>: NSViewController {
    let hostingController: NSHostingController<Content>

    init(rootView: Content) {
        self.hostingController = NSHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }
}
