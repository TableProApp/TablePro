//
//  NavigationSidebarViewController.swift
//  TablePro
//

import AppKit
import SwiftUI

/// The window's single sidebar: the workspace rail beside the object browser.
///
/// AppKit grants full-height layout, and the titlebar section that comes with it, to exactly
/// one leading sidebar. Making the rail and the object browser two sidebar items meant that
/// privilege had to change hands whenever the rail appeared, which no amount of re-applying
/// made reliable. Composing them inside one sidebar item leaves AppKit with the single
/// sidebar it expects, and showing or hiding the rail becomes an ordinary layout change.
@MainActor
internal final class NavigationSidebarViewController: NSViewController {
    internal let railController: WorkspaceRailViewController
    internal let connectionTree: ConnectionTreeOutlineController
    internal let objectBrowser: SidebarContainerViewController

    private let separator = NSBox()
    private var railWidthConstraint: NSLayoutConstraint!
    private var separatorWidthConstraint: NSLayoutConstraint!

    /// The rule between the connections list and the object browser. Both are laid out by
    /// constraints, like everything else in this view.
    ///
    /// An `NSSplitView` sat here and had to go. It sets its panes' frames itself, and every one of
    /// those writes re-dirtied the constraints of the `_NSSplitViewItemViewWrapper` that the
    /// window's own sidebar item wraps this view in. The loop does not converge: AppKit gives up
    /// with "more Update Constraints in Window passes than there are views in the window" and the
    /// process dies on an uncaught exception before the first window is drawn. It reproduced once,
    /// on the first launch after install, and never again, which is the worst shape a crash can
    /// have in the one view every window builds. A draggable divider is not worth it.
    private let listDivider = NSBox()

    internal private(set) var isRailVisible = false

    internal init() {
        self.railController = WorkspaceRailViewController()
        self.connectionTree = ConnectionTreeOutlineController()
        self.objectBrowser = SidebarContainerViewController()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("NavigationSidebarViewController does not support NSCoder init")
    }

    override func loadView() {
        view = NSView()

        addChild(railController)
        addChild(connectionTree)
        addChild(objectBrowser)

        let rail = railController.view
        separator.boxType = .separator

        let connections = connectionTree.view
        let browser = objectBrowser.view
        listDivider.boxType = .separator

        for child in [rail, separator, connections, listDivider, browser] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }

        railWidthConstraint = rail.widthAnchor.constraint(equalToConstant: 0)
        separatorWidthConstraint = separator.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rail.topAnchor.constraint(equalTo: view.topAnchor),
            rail.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            railWidthConstraint,

            separator.leadingAnchor.constraint(equalTo: rail.trailingAnchor),
            separator.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            separator.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            separatorWidthConstraint,

            connections.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            connections.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            connections.topAnchor.constraint(equalTo: view.topAnchor),

            listDivider.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            listDivider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            listDivider.topAnchor.constraint(equalTo: connections.bottomAnchor),
            listDivider.heightAnchor.constraint(equalToConstant: 1),

            browser.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            browser.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            browser.topAnchor.constraint(equalTo: listDivider.bottomAnchor),
            browser.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        /// The list takes a fixed slice and the object browser takes the rest. Neither of these is
        /// required, and that is the point: the object browser's own content carries a minimum, so
        /// a required cap here made a short sidebar unsatisfiable and AppKit broke one of them at
        /// random. Measured at a 300pt sidebar, the panes summed to 400. The cap outranks the fixed
        /// height instead, so a short sidebar shrinks the list and the arithmetic always closes.
        let listHeight = connections.heightAnchor.constraint(equalToConstant: 200)
        listHeight.priority = NSLayoutConstraint.Priority(500)
        listHeight.isActive = true
        let listCap = connections.heightAnchor.constraint(
            lessThanOrEqualTo: view.heightAnchor,
            multiplier: 0.4
        )
        listCap.priority = NSLayoutConstraint.Priority(900)
        listCap.isActive = true

        separator.isHidden = true
    }

    /// The width the sidebar needs on top of the object browser's own minimum. Read from the
    /// constraints rather than recomputed, because `isHidden` on a plain view leaves its
    /// constraints active: a separator hidden but still 1pt wide would inset the object browser
    /// from the window edge on every single-workspace window.
    internal var railAllowance: CGFloat {
        railWidthConstraint.constant + separatorWidthConstraint.constant
    }

    internal func setRailVisible(_ visible: Bool, animated: Bool, alongside: (() -> Void)? = nil) {
        guard isRailVisible != visible else { return }
        isRailVisible = visible
        separator.isHidden = !visible
        applyRailWidth(animated: animated, alongside: alongside)
    }

    /// One animation recipe, not two. Mixing `animator()` with `allowsImplicitAnimation` leaves
    /// which one drives the geometry up to AppKit, so the declared duration is not reliably the
    /// one that runs.
    internal func applyRailWidth(animated: Bool, alongside: (() -> Void)? = nil) {
        let width = isRailVisible ? railController.currentLayout.width : 0
        let separatorWidth: CGFloat = isRailVisible ? 1 : 0
        guard railWidthConstraint.constant != width else {
            alongside?()
            return
        }
        guard animated, view.window != nil else {
            railWidthConstraint.constant = width
            separatorWidthConstraint.constant = separatorWidth
            alongside?()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            railWidthConstraint.animator().constant = width
            separatorWidthConstraint.animator().constant = separatorWidth
            alongside?()
        }
    }
}
