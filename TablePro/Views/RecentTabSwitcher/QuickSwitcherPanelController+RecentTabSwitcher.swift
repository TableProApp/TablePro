//
//  QuickSwitcherPanelController+RecentTabSwitcher.swift
//  TablePro
//

import AppKit

/// The recent-tab list goes in the window's one floating panel rather than a panel of its own, so
/// it and Open Quickly can never be up together over the same point: presenting either closes the
/// other, and the close tells the switch in progress to end.
extension QuickSwitcherPanelController: RecentTabSwitcherPresenting {
    internal static let recentTabSwitcherIdentity = "recent-tab-switcher"
    internal static let recentTabSwitcherAccessibilityIdentifier = "recent-tab-switcher-panel"

    internal func presentRecentTabSwitcher(
        _ model: RecentTabSwitcherModel,
        over window: NSWindow?,
        onClose: @escaping () -> Void
    ) {
        present(
            RecentTabSwitcherView(model: model),
            over: window,
            identity: Self.recentTabSwitcherIdentity,
            focus: .passive,
            accessibilityIdentifier: Self.recentTabSwitcherAccessibilityIdentifier,
            onClose: onClose
        )
    }

    internal func dismissRecentTabSwitcher() {
        guard isPresenting(Self.recentTabSwitcherIdentity) else { return }
        dismiss()
    }
}
