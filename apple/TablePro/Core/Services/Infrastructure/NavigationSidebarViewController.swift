//
//  NavigationSidebarViewController.swift
//  TablePro
//

import AppKit
import SwiftUI

/// The window's single sidebar: the connections column beside the object browser.
///
/// AppKit grants full-height layout, and the titlebar section that comes with it, to exactly
/// one leading sidebar. Making the rail and the object browser two sidebar items meant that
/// privilege had to change hands whenever the rail appeared, which no amount of re-applying
/// made reliable. Composing them inside one sidebar item leaves AppKit with the single
/// sidebar it expects, and showing or hiding the rail becomes an ordinary layout change.
///
/// Inside that item the two share a split view of their own, so the line between them is a divider
/// the user drags to widen the strip, and AppKit keeps the width while the strip is hidden.
///
/// The column holds the strip or, with the setting on, the connection navigator. A split item's
/// controller cannot be swapped once installed, and one split view carries one autosave name, so
/// the navigator gets a split of its own wrapped around the strip's: `[navigator | strip split]`,
/// with the strip collapsed inside. Each list keeps its own width, and neither the strip's split nor
/// the object browser is rebuilt when the setting flips. With the setting off the hierarchy is the
/// strip's split alone, exactly as before the navigator existed.
@MainActor
internal final class NavigationSidebarViewController: NSViewController {
    /// The object browser's floor. A strip dragged wider than the browser can give up widens the sidebar.
    internal static let objectBrowserMinimumThickness: CGFloat = 280

    internal let railController: WorkspaceRailViewController
    internal let navigatorController: ConnectionNavigatorViewController
    internal let objectBrowser: SidebarContainerViewController

    /// The column's own width moved: a drag, a restored width, or a sidebar icon size.
    internal var onRailWidthChange: (() -> Void)?

    private let splitController = NSSplitViewController()
    private let railItem: NSSplitViewItem
    private let browserItem: NSSplitViewItem

    private let navigatorSplitController = NSSplitViewController()
    private let navigatorItem: NSSplitViewItem
    private let railSplitHost = WorkspacePaneHost()
    private let railSplitHostItem: NSSplitViewItem
    private var isNavigatorSplitBuilt = false
    private var installedSplitConstraints: [NSLayoutConstraint] = []

    /// Whether the column is on screen, whichever list it holds.
    internal private(set) var isRailVisible = false
    internal private(set) var showsNavigator = false

    /// While the column slides in, its width is not yet the sidebar's to make room for: the column
    /// widens the sidebar itself, a frame at a time.
    private var isRevealingRail = false
    private var revealGeneration = 0

    internal init() {
        let railController = WorkspaceRailViewController()
        let navigatorController = ConnectionNavigatorViewController()
        let objectBrowser = SidebarContainerViewController()
        self.railController = railController
        self.navigatorController = navigatorController
        self.objectBrowser = objectBrowser
        self.railItem = NSSplitViewItem(viewController: railController)
        self.browserItem = NSSplitViewItem(viewController: objectBrowser)
        self.navigatorItem = NSSplitViewItem(viewController: navigatorController)
        self.railSplitHostItem = NSSplitViewItem(viewController: railSplitHost)
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
            guard let self, !self.isRevealingRail, !self.showsNavigator else { return }
            self.onRailWidthChange?()
        }
        navigatorController.isColumnShown = false
        navigatorController.onWidthChange = { [weak self] in
            guard let self, !self.isRevealingRail, self.showsNavigator else { return }
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

        install(splitController)

        /// Only once the split view has loaded. Collapsing before that discards the saved width and
        /// keeps the strip out of the window altogether, where it cannot find its window's selection.
        railItem.isCollapsed = true
    }

    /// Pinned below the titlebar: the divider would otherwise run up through it beside the window
    /// buttons.
    private func install(_ controller: NSSplitViewController) {
        addChild(controller)
        let split = controller.view
        split.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(split)
        installedSplitConstraints = [
            split.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            split.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            split.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ]
        NSLayoutConstraint.activate(installedSplitConstraints)
    }

    private func uninstall(_ controller: NSSplitViewController) {
        NSLayoutConstraint.deactivate(installedSplitConstraints)
        installedSplitConstraints = []
        controller.view.removeFromSuperview()
        controller.removeFromParent()
    }

    // MARK: - Which list

    private var columnItem: NSSplitViewItem {
        showsNavigator ? navigatorItem : railItem
    }

    private var columnSplitView: NSSplitView {
        showsNavigator ? navigatorSplitController.splitView : splitController.splitView
    }

    /// The navigator's view is read only once loaded, so a window that never turns the setting on
    /// never builds the list or starts its observers.
    private var loadedNavigatorView: NSView? {
        navigatorController.isViewLoaded ? navigatorController.view : nil
    }

    private var columnViewWidth: CGFloat {
        showsNavigator ? loadedNavigatorView?.frame.width ?? 0 : railController.view.frame.width
    }

    /// Puts the strip or the navigator in the column. The column leaves the screen as the lists
    /// trade places, and the window's rule brings it back through `setRailVisible`, which reveals
    /// the new list at its own width.
    internal func setNavigatorEnabled(_ enabled: Bool) {
        _ = view
        guard showsNavigator != enabled else { return }
        if isRailVisible {
            isRailVisible = false
            applyColumnShown()
            finishReveal()
            handKeyboardOnFromColumn()
            columnItem.isCollapsed = true
        }
        showsNavigator = enabled
        applyColumnShown()
        let browserFocus = objectBrowserFocus()
        if enabled {
            buildNavigatorSplitIfNeeded()
            uninstall(splitController)
            railSplitHost.show(splitController)
            install(navigatorSplitController)
        } else {
            uninstall(navigatorSplitController)
            railSplitHost.show(nil)
            install(splitController)
        }
        restore(browserFocus)
        onRailWidthChange?()
    }

    private struct BrowserFocus {
        let holder: NSView
        let selection: NSRange?
    }

    /// Moving the object browser to the other split takes it out of the window for a moment, and
    /// AppKit gives the keyboard to the window when a view holding it leaves, so the view that held
    /// it is noted first. A field being edited is held by its field editor, which leaves with the
    /// edit, so the field and its selection are noted instead.
    private func objectBrowserFocus() -> BrowserFocus? {
        guard let window = view.window, let responder = window.firstResponder as? NSView,
              responder.window === window
        else { return nil }
        let focus: BrowserFocus
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView {
            focus = BrowserFocus(holder: field, selection: editor.selectedRange())
        } else {
            focus = BrowserFocus(holder: responder, selection: nil)
        }
        return focus.holder.isDescendant(of: objectBrowser.view) ? focus : nil
    }

    private func restore(_ focus: BrowserFocus?) {
        guard let focus, let window = view.window, focus.holder.window === window,
              objectBrowserFocus()?.holder !== focus.holder,
              window.makeFirstResponder(focus.holder)
        else { return }
        if let selection = focus.selection, let editor = window.firstResponder as? NSTextView,
           NSMaxRange(selection) <= (editor.string as NSString).length {
            editor.setSelectedRange(selection)
        }
    }

    private func buildNavigatorSplitIfNeeded() {
        guard !isNavigatorSplitBuilt else { return }
        isNavigatorSplitBuilt = true
        navigatorItem.minimumThickness = ConnectionNavigatorViewController.minimumWidth
        navigatorItem.maximumThickness = ConnectionNavigatorViewController.maximumWidth
        navigatorItem.holdingPriority = .splitPaneHolding
        /// Shown and hidden only by the window's rule, as the strip is.
        navigatorItem.canCollapse = false
        railSplitHostItem.minimumThickness = Self.objectBrowserMinimumThickness
        railSplitHostItem.holdingPriority = .defaultLow

        let splitView = navigatorSplitController.splitView
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        navigatorSplitController.addSplitViewItem(navigatorItem)
        navigatorSplitController.addSplitViewItem(railSplitHostItem)
        /// Its own name, so the strip keeps the narrow width it was given while the navigator is off.
        splitView.autosaveName = SplitViewAutosaveName.current(SplitViewAutosaveName.connectionNavigator)
        _ = navigatorSplitController.view
        navigatorItem.isCollapsed = true
    }

    // MARK: - Width

    /// The width the sidebar needs on top of the object browser's own minimum. Read from the column's
    /// own frame, which AppKit leaves at the column's width while its item collapses and expands, so
    /// no animated value is ever read: reading those left the sidebar minimum behind after a show.
    internal var railAllowance: CGFloat {
        guard isRailVisible, !isRevealingRail else { return 0 }
        return railWidth + columnSplitView.dividerThickness
    }

    /// Clamped as AppKit clamps it, because a column never shown since launch still has no frame, and
    /// a strip width saved at a smaller sidebar icon size lays out at the larger size's minimum.
    private var railWidth: CGFloat {
        min(max(columnViewWidth, columnItem.minimumThickness), columnItem.maximumThickness)
    }

    /// The sidebar icon size sets the strip's minimum. AppKit widens a narrower strip to it and gives
    /// the earlier width back when the minimum drops again.
    internal func applyRailLayout() {
        railItem.minimumThickness = railController.currentLayout.minimumWidth
        navigatorItem.minimumThickness = ConnectionNavigatorViewController.minimumWidth
    }

    // MARK: - Visibility

    /// A collapsed column is hidden, not only zero points wide. AppKit counts a zero-width view as
    /// visible, so the strip's list stayed a key view: it was what the window focused when first
    /// shown, Tab could land on it, and its own Close then took the whole connection on a Command W
    /// meant for a tab. A collapsed split item hides its wrapper, which takes the column out of the
    /// key view loop, the responder chain and the accessibility tree, and the list stops offering
    /// itself as a key view as soon as the column is told to go.
    ///
    /// The keyboard moves on as the collapse starts, because AppKit hides the wrapper only once the
    /// animation ends, and a list that is about to vanish must not keep answering keys until then.
    internal func setRailVisible(_ visible: Bool, animated: Bool, alongside: (@MainActor () -> Void)? = nil) {
        guard isRailVisible != visible else { return }
        isRailVisible = visible
        applyColumnShown()
        finishReveal()
        if !visible {
            handKeyboardOnFromColumn()
        }
        let item = columnItem
        guard animated, view.window != nil else {
            alongside?()
            item.isCollapsed = !visible
            return
        }
        guard visible else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.animationDuration
                alongside?()
                item.animator().isCollapsed = true
            }
            return
        }
        revealColumn(then: alongside)
    }

    private func applyColumnShown() {
        railController.isStripShown = isRailVisible && !showsNavigator
        navigatorController.isColumnShown = isRailVisible && showsNavigator
    }

    /// The column holds its own width as a minimum while it slides in, so where the sidebar is too
    /// narrow for it the column widens the sidebar a frame at a time. Raising the sidebar's range
    /// first is a required constraint that lands on the next layout pass: the sidebar snapped its
    /// full width wide in one frame while the strip slid in behind it.
    private func revealColumn(then alongside: (@MainActor () -> Void)?) {
        let item = columnItem
        item.minimumThickness = railWidth
        isRevealingRail = true
        revealGeneration += 1
        let generation = revealGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.animationDuration
            item.animator().isCollapsed = false
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
    private func handKeyboardOnFromColumn() {
        guard let window = view.window,
              let responder = window.firstResponder as? NSView,
              isInsideColumn(responder)
        else { return }
        window.selectKeyView(following: responder)
        guard let next = window.firstResponder as? NSView, isInsideColumn(next) else { return }
        window.makeFirstResponder(nil)
    }

    private func isInsideColumn(_ responder: NSView) -> Bool {
        if responder.isDescendant(of: railController.view) { return true }
        guard let navigator = loadedNavigatorView else { return false }
        return responder.isDescendant(of: navigator)
    }
}
