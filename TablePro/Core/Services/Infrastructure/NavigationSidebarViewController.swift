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
///
/// Inside that item the two share a split view of their own, so the line between them is a divider
/// the user drags to widen the strip, and AppKit keeps the width while the strip is hidden.
@MainActor
internal final class NavigationSidebarViewController: NSViewController {
    /// The object browser's floor. A strip dragged wider than the browser can give up widens the sidebar.
    internal static let objectBrowserMinimumThickness: CGFloat = 280

    internal let railController: WorkspaceRailViewController
    internal let objectBrowser: SidebarContainerViewController

    /// The strip's own width moved: a drag, a restored width, or a sidebar icon size.
    internal var onRailWidthChange: (() -> Void)?

    private let splitController = NSSplitViewController()
    private let railItem: NSSplitViewItem
    private let browserItem: NSSplitViewItem

    internal private(set) var isRailVisible = false

    /// While the strip slides in, its width is not yet the sidebar's to make room for: the strip
    /// widens the sidebar itself, a frame at a time.
    private var isRevealingRail = false
    private var revealGeneration = 0

    internal init() {
        let railController = WorkspaceRailViewController()
        let objectBrowser = SidebarContainerViewController()
        self.railController = railController
        self.objectBrowser = objectBrowser
        self.railItem = NSSplitViewItem(viewController: railController)
        self.browserItem = NSSplitViewItem(viewController: objectBrowser)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("NavigationSidebarViewController does not support NSCoder init")
    }

    override func loadView() {
        view = NSView()

        _ = railController.view
        railController.isStripShown = false
        railController.refreshLayoutIfNeeded()
        railController.onWidthChange = { [weak self] in
            guard let self, !self.isRevealingRail else { return }
            self.onRailWidthChange?()
        }
        railItem.minimumThickness = railController.currentLayout.minimumWidth
        railItem.maximumThickness = WorkspaceRailMetrics.maximumWidth
        railItem.holdingPriority = .splitPaneHolding
        /// Shown and hidden only by the window's rule. A divider dragged shut would leave no handle to
        /// bring the strip back by, since AppKit hides a divider whose outer pane is collapsed.
        railItem.canCollapse = false
        browserItem.minimumThickness = Self.objectBrowserMinimumThickness
        browserItem.holdingPriority = .defaultLow

        let splitView = splitController.splitView
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitController.addSplitViewItem(railItem)
        splitController.addSplitViewItem(browserItem)
        /// AppKit applies the saved record as the split view loads, so the name goes on first.
        splitView.autosaveName = SplitViewAutosaveName.current(SplitViewAutosaveName.workspaceRail)

        addChild(splitController)
        let split = splitController.view
        split.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            /// The divider would otherwise run up through the titlebar beside the window buttons.
            split.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            split.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        /// Only once the split view has loaded. Collapsing before that discards the saved width and
        /// keeps the strip out of the window altogether, where it cannot find its window's selection.
        railItem.isCollapsed = true
    }

    /// The width the sidebar needs on top of the object browser's own minimum. Read from the strip's
    /// own frame, which AppKit leaves at the strip's width while its item collapses and expands, so
    /// no animated value is ever read: reading those left the sidebar minimum behind after a show.
    internal var railAllowance: CGFloat {
        guard isRailVisible, !isRevealingRail else { return 0 }
        return railWidth + splitController.splitView.dividerThickness
    }

    /// Clamped as AppKit clamps it, because a strip never shown since launch still has no frame, and
    /// a width saved at a smaller sidebar icon size lays out at the larger size's minimum.
    private var railWidth: CGFloat {
        min(max(railController.view.frame.width, railItem.minimumThickness), railItem.maximumThickness)
    }

    /// The sidebar icon size sets the strip's minimum. AppKit widens a narrower strip to it and gives
    /// the earlier width back when the minimum drops again.
    internal func applyRailLayout() {
        railItem.minimumThickness = railController.currentLayout.minimumWidth
    }

    /// A collapsed strip is hidden, not only zero points wide. AppKit counts a zero-width view as
    /// visible, so the strip's list stayed a key view: it was what the window focused when first
    /// shown, Tab could land on it, and its own Close then took the whole connection on a Command W
    /// meant for a tab. A collapsed split item hides its wrapper, which takes the strip out of the
    /// key view loop, the responder chain and the accessibility tree, and the list stops offering
    /// itself as a key view as soon as the strip is told to go.
    ///
    /// The keyboard moves on as the collapse starts, because AppKit hides the wrapper only once the
    /// animation ends, and a list that is about to vanish must not keep answering keys until then.
    internal func setRailVisible(_ visible: Bool, animated: Bool, alongside: (@MainActor () -> Void)? = nil) {
        guard isRailVisible != visible else { return }
        isRailVisible = visible
        railController.isStripShown = visible
        finishReveal()
        if !visible {
            handKeyboardOnFromRail()
        }
        guard animated, view.window != nil else {
            alongside?()
            railItem.isCollapsed = !visible
            return
        }
        guard visible else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.animationDuration
                alongside?()
                railItem.animator().isCollapsed = true
            }
            return
        }
        revealRail(then: alongside)
    }

    /// The strip holds its own width as a minimum while it slides in, so where the sidebar is too
    /// narrow for it the strip widens the sidebar a frame at a time. Raising the sidebar's range
    /// first is a required constraint that lands on the next layout pass: the sidebar snapped its
    /// full width wide in one frame while the strip slid in behind it.
    private func revealRail(then alongside: (@MainActor () -> Void)?) {
        railItem.minimumThickness = railWidth
        isRevealingRail = true
        revealGeneration += 1
        let generation = revealGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.animationDuration
            railItem.animator().isCollapsed = false
        } completionHandler: { [weak self] in
            guard let self, self.revealGeneration == generation, self.isRevealingRail else { return }
            self.finishReveal()
            alongside?()
        }
    }

    private func finishReveal() {
        guard isRevealingRail else { return }
        isRevealingRail = false
        applyRailLayout()
    }

    private static let animationDuration: TimeInterval = 0.15

    /// Moves the keyboard to the next key view, which is what AppKit does itself when a focused
    /// view is hidden, only at the start of the collapse rather than the end. Leaving it with the
    /// window instead would make every key beep until the next click. The window takes it only
    /// when nothing else in the loop can.
    private func handKeyboardOnFromRail() {
        guard let window = view.window,
              let responder = window.firstResponder as? NSView,
              responder.isDescendant(of: railController.view)
        else { return }
        window.selectKeyView(following: responder)
        guard let next = window.firstResponder as? NSView, next.isDescendant(of: railController.view) else { return }
        window.makeFirstResponder(nil)
    }
}
