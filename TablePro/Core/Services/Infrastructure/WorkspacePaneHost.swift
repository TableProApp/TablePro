//
//  WorkspacePaneHost.swift
//  TablePro
//

import AppKit

/// A stable container showing one connection's pane at a time, used by the split items and by the
/// titlebar accessory that carries the editor tab strip.
///
/// `NSSplitViewItem.viewController` cannot be reassigned once the item is installed in an
/// `NSSplitViewController`, so a window that hosts several connections cannot swap the item itself.
/// It swaps the item's child instead, which is what lets every other connection's view tree stay
/// alive rather than be rebuilt from scratch on each switch. A titlebar accessory has the same
/// shape of problem: one accessory per window, one strip per connection.
///
/// The container publishes no size of its own: it owns no intrinsic content size and every pane it
/// shows is an `NSHostingController` with `sizingOptions = []`. That is the firewall keeping tab
/// content from pinning the window's split dividers (#1872), and `WorkspacePanes` is where it is
/// applied.
@MainActor
internal final class WorkspacePaneHost: NSViewController {
    private(set) var shown: NSViewController?

    override internal func loadView() {
        view = NSView()
    }

    /// A pane can publish a height, which the editor tab strip does when it wraps onto more rows.
    /// `NSViewController` only tells the immediate parent, so this container passes it on to
    /// whatever is hosting it.
    override internal func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        guard viewController === shown else { return }
        preferredContentSize = viewController.preferredContentSize
    }

    internal func show(_ controller: NSViewController?) {
        guard shown !== controller else { return }

        if let outgoing = shown {
            outgoing.view.removeFromSuperview()
            outgoing.removeFromParent()
        }
        shown = controller

        guard let controller else {
            preferredContentSize = .zero
            return
        }
        addChild(controller)
        preferredContentSize = controller.preferredContentSize
        let pane = controller.view
        pane.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pane.topAnchor.constraint(equalTo: view.topAnchor),
            pane.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// Takes down a pane whose connection is going away. Without this the container keeps the last
    /// workspace's hosting controller as a child, and through it the `MainContentCoordinator` that
    /// only leaves the app-wide coordinator registry when it deinits.
    internal func discardIfShowing(_ controller: NSViewController) {
        guard shown === controller else { return }
        show(nil)
    }
}
