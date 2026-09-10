//
//  ConnectionFormSplitViewController.swift
//  TablePro
//
//  NSSplitViewController rather than NavigationSplitView, for the same reason
//  MainSplitViewController is one: only AppKit vends a real sidebar split item, and only a
//  window whose contentViewController IS the split controller gets `toggleSidebar(_:)` and
//  `.sidebarTrackingSeparator` through the responder chain.
//

import AppKit
import Observation
import SwiftUI

@MainActor
internal final class ConnectionFormSplitViewController: NSSplitViewController {
    private static let sidebarMinThickness: CGFloat = 200
    private static let sidebarMaxThickness: CGFloat = 260
    private static let detailMinThickness: CGFloat = 480

    private let coordinator: ConnectionFormCoordinator

    internal init(coordinator: ConnectionFormCoordinator) {
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    internal required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override internal func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true

        /// `sidebarWithViewController:` is what makes the pane an actual sidebar: full window
        /// height behind the titlebar, the vibrant material, and the divider a tracking separator
        /// can align to. A plain split item gets none of it.
        let sidebar = NSHostingController(rootView: ConnectionFormSidebar(coordinator: coordinator))
        sidebar.sizingOptions = []
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = Self.sidebarMinThickness
        sidebarItem.maximumThickness = Self.sidebarMaxThickness
        addSplitViewItem(sidebarItem)

        let detail = NSHostingController(rootView: ConnectionFormDetailView(coordinator: coordinator))
        detail.sizingOptions = []
        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = Self.detailMinThickness
        /// Below `dragThatCannotResizeWindow` (490), or the pane's own width constraint outranks a
        /// divider drag and the divider cannot move at all.
        detailItem.holdingPriority = .defaultLow
        addSplitViewItem(detailItem)

        trackTitle()
    }

    /// The window title follows the connection's type, which the Change… button can now alter.
    ///
    /// `NSWindow(contentViewController:)` binds the window's title to this controller's, so nothing
    /// writes `window.title` directly. `withObservationTracking` fires once per change, so the
    /// closure re-arms itself.
    private func trackTitle() {
        withObservationTracking {
            title = windowTitle
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackTitle() }
        }
    }

    private var windowTitle: String {
        coordinator.isNew
            ? String(format: String(localized: "New %@ Connection"), coordinator.network.type.rawValue)
            : String(format: String(localized: "Edit %@ Connection"), coordinator.network.type.rawValue)
    }
}

// MARK: - Toolbar

/// The tracking separator alone: it keeps the titlebar's own divider on the split divider as that
/// divider is dragged, which is what makes the titlebar read as part of a sidebar window.
///
/// No `.toggleSidebar`. The four sections are the window's only navigation, so a button whose job is
/// to hide them earns nothing in the titlebar. Collapsing stays reachable, because
/// `NSSplitViewController.toggleSidebar(_:)` is on the responder chain and the View menu's Show
/// Sidebar sends exactly that, so a sidebar dragged shut can always be brought back.
///
/// `.sidebarTrackingSeparator` is supplied by AppKit whenever the window's contentViewController is
/// an `NSSplitViewController`, which is why this window has no wrapper around it.
@MainActor
internal final class ConnectionFormToolbarDelegate: NSObject, NSToolbarDelegate {
    internal static let identifier = NSToolbar.Identifier("com.TablePro.toolbar.connectionForm")

    private static let items: [NSToolbarItem.Identifier] = [
        .sidebarTrackingSeparator,
    ]

    internal func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.items
    }

    internal func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.items
    }

    internal func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        nil
    }
}
