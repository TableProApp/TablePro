//
//  CollapsibleSplitController.swift
//  TablePro
//

import AppKit

/// A top pane over a collapsible bottom pane, divider thin and remembered.
@MainActor
internal final class CollapsibleSplitController: ResizeCursorSplitViewController {
    nonisolated static let defaultTopMinimumThickness: CGFloat = 100
    nonisolated static let defaultBottomMinimumThickness: CGFloat = 150

    /// What a split using the defaults needs before its own constraints become unsatisfiable.
    /// An enclosing split whose pane hosts one of these must not promise less than this.
    nonisolated static var combinedMinimumThickness: CGFloat {
        defaultTopMinimumThickness + defaultBottomMinimumThickness + 10
    }

    let topItem: NSSplitViewItem
    let bottomItem: NSSplitViewItem
    /// The divider is draggable and double-clickable, so AppKit owns the collapsed state as much as the
    /// owner does; a change the user makes is reported back rather than snapped away on the next update.
    var onUserCollapseChange: ((Bool) -> Void)?

    private var lastCollapsedState: Bool
    private var collapseObservation: NSKeyValueObservation?
    private var isApplyingProgrammatically = false

    init(
        top: NSViewController,
        bottom: NSViewController,
        autosaveName: String,
        topMinimumThickness: CGFloat = defaultTopMinimumThickness,
        bottomMinimumThickness: CGFloat = defaultBottomMinimumThickness,
        isBottomCollapsed: Bool
    ) {
        topItem = NSSplitViewItem(viewController: top)
        topItem.minimumThickness = topMinimumThickness
        bottomItem = NSSplitViewItem(viewController: bottom)
        bottomItem.canCollapse = true
        bottomItem.minimumThickness = bottomMinimumThickness
        lastCollapsedState = isBottomCollapsed
        super.init(nibName: nil, bundle: nil)

        splitView.isVertical = false
        splitView.dividerStyle = .thin
        addSplitViewItem(topItem)
        addSplitViewItem(bottomItem)

        // After the items are added; set earlier it does not record the divider, and adjustSubviews then resets it.
        splitView.autosaveName = SplitViewAutosaveName.current(autosaveName)

        collapseObservation = bottomItem.observe(\.isCollapsed, options: [.new]) { [weak self] observed, _ in
            nonisolated(unsafe) let observedItem = observed
            MainActor.assumeIsolated {
                guard let self, !self.isApplyingProgrammatically else { return }
                self.lastCollapsedState = observedItem.isCollapsed
                self.onUserCollapseChange?(observedItem.isCollapsed)
            }
        }

        // Assigned either way, so the owner's state wins over whatever the autosave record restored.
        bottomItem.isCollapsed = isBottomCollapsed
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setBottomCollapsed(_ collapsed: Bool) {
        guard collapsed != lastCollapsedState else { return }
        lastCollapsedState = collapsed
        isApplyingProgrammatically = true
        defer { isApplyingProgrammatically = false }
        bottomItem.animator().isCollapsed = collapsed
    }
}
