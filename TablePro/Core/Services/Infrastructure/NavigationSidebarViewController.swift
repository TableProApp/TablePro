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
    internal let objectBrowser: SidebarContainerViewController

    private let separator = NSBox()
    private var railWidthConstraint: NSLayoutConstraint!
    private var separatorWidthConstraint: NSLayoutConstraint!

    internal private(set) var isRailVisible = false

    internal init() {
        self.railController = WorkspaceRailViewController()
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
        addChild(objectBrowser)

        let rail = railController.view
        let browser = objectBrowser.view
        separator.boxType = .separator

        for child in [rail, separator, browser] {
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

            browser.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            browser.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            browser.topAnchor.constraint(equalTo: view.topAnchor),
            browser.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

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
