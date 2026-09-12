//
//  ResultStatusPresentation.swift
//  TablePro
//

import CoreGraphics

/// How much room the status bar has, and so how much of its chrome it draws.
///
/// The bar used to pin both of its clusters at full width, which made its own minimum wider than the
/// pane hosting it: the tab content column adopted that width, `sizingOptions = []` kept the need
/// invisible to Auto Layout, and SwiftUI centred the oversized column in the pane. Measured at the
/// window's own 720pt minimum with the sidebar open, the column ran 766pt inside a 440pt pane, so
/// 163pt was unreachable at each edge: the grid's row numbers and first column sat under the
/// sidebar, and the pagination cluster sat past the trailing edge. `ViewThatFits` picks the widest
/// tier whose ideal width fits, and `narrow` is measured to fit the narrowest pane the window
/// allows, so no tier can over-size the column again.
enum StatusBarTier: CaseIterable {
    /// Every control at full width, titles beside icons.
    case regular
    /// Titles drop to their icons and the page edges go. Every control is still on the bar.
    case compact
    /// The mode switcher becomes a pull-down and rows-per-page moves inside the page indicator.
    case narrow
}

/// What a tier draws.
///
/// Only a control whose command has another route may leave: First and Last go, and the Query menu
/// carries all four page commands at every width. Nothing that opens a popover may go, because a
/// `.popover` anchored to a button that is no longer in the view tree cannot present, so giving up
/// the Highlight Rules button would have made `View > Highlight Rules…` do nothing at that width.
/// Rows-per-page has no menu-bar route at all, so it moves inside the page indicator rather than
/// leaving.
///
/// A lookup rather than a computation, and the companion to `ResultStatusControls`: that one answers
/// which controls a result offers, this one answers how they are drawn. Both are pure so the whole
/// matrix is decidable without mounting a view.
struct ResultStatusPresentation: Equatable {
    /// Whether a control carries its title beside its icon.
    let showsControlTitles: Bool
    /// A segmented control while the modes fit, and a pull-down naming the current one once they do
    /// not. `View > Result View` offers the same choice either way.
    let modeSwitcherIsSegmented: Bool
    /// First and Last. Previous and Next never leave the bar: they are what a reader reaches for,
    /// and burying the most-used control is the one thing a narrow bar must not do. The Query menu
    /// carries all four at every width.
    let showsEdgePageButtons: Bool
    /// Whether rows-per-page stands beside the page indicator or moves inside its menu.
    let pageSizeIsInline: Bool

    init(tier: StatusBarTier) {
        switch tier {
        case .regular:
            showsControlTitles = true
            modeSwitcherIsSegmented = true
            showsEdgePageButtons = true
            pageSizeIsInline = true
        case .compact:
            showsControlTitles = false
            modeSwitcherIsSegmented = true
            showsEdgePageButtons = false
            pageSizeIsInline = true
        case .narrow:
            showsControlTitles = false
            modeSwitcherIsSegmented = false
            showsEdgePageButtons = false
            pageSizeIsInline = false
        }
    }
}

/// The two widths the tier ladder rests on.
enum StatusBarLayoutMetrics {
    /// A pull-down takes the width of its widest item, so the longest translated mode name would
    /// otherwise decide the narrow tier's floor. Measured: the four English names need 90pt and a
    /// long-locale set 153pt, which this caps back to a fixed cost.
    static let modeMenuMaximumWidth: CGFloat = 110

    /// The width the readout reports as its ideal, which has to be a constant rather than the
    /// sentence's own width: `ViewThatFits` chooses on a candidate's ideal size, so a wordy driver
    /// message read off the text would drop the whole bar a tier by itself. The mounted readout
    /// still grows into the slack and truncates below this.
    static let readoutIdealWidth: CGFloat = 120
}
