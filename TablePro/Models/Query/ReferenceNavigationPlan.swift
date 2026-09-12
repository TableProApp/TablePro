import Foundation

/// What the reader asked for when they followed a foreign key.
///
/// A Bool cannot say this. The decision has three destinations, not two, and `false` meaning
/// "take over the tab I am looking at" read backwards at every call site.
internal enum ReferenceOpenIntent: Equatable, Sendable {
    /// The ordinary gesture: a click on the cell's arrow, the row inspector's link, the preview
    /// popover's button, the menu's plain item.
    case follow
    /// Command-click, and the menu item that spells it out. Always its own tab, even when one is
    /// already open on the same reference.
    case newTab
}

/// The one thing a reference jump does with the window's tabs.
///
/// No outcome re-points the selected tab at a different table. A reference can only be followed
/// from a grid, so the tab it is followed from is always one the reader is reading, and retargeting
/// it left them nowhere to go back to, which is the whole defect. Re-filtering a tab that is
/// already on the referenced table is not that: it stays in the table they are in, and Back undoes
/// it.
internal enum ReferenceNavigationPlan: Equatable, Sendable {
    /// The selected tab is already on the referenced table, so only its filter changes.
    case refilterSelectedTab
    /// Another tab is already showing exactly this reference; bring it forward rather than
    /// building a second one beside it.
    case revealExistingTab
    /// A tab of its own, leaving whatever the reader was looking at where it was.
    case openNewTab
}

/// What the window looks like from the jump's point of view.
internal struct ReferenceNavigationContext: Equatable, Sendable {
    let intent: ReferenceOpenIntent
    /// The selected tab is browsing the referenced table already, whatever it is filtered to.
    let selectedTabShowsTarget: Bool
    /// Re-filtering that tab in place is safe. Staged structure edits say it is not: the discard
    /// alert clears cell changes and nothing else, so re-querying under them would promise
    /// something this path cannot keep.
    let selectedTabAcceptsRefilter: Bool
    /// Some tab, in this window or a sibling on the same connection, is already showing exactly
    /// this reference.
    let anotherTabShowsReference: Bool
}

/// Resolves a reference jump to exactly one outcome.
///
/// Pure, so the choice can be tested without a window, a coordinator or a tab manager. It used to
/// be an open-coded chain of guards inside `navigateToFKReference`, which is how it came to take
/// over a tab that every other way of opening a table would have left alone.
internal enum ReferenceNavigationPlanner {
    static func plan(for context: ReferenceNavigationContext) -> ReferenceNavigationPlan {
        guard context.intent == .follow else { return .openNewTab }

        if context.selectedTabShowsTarget, context.selectedTabAcceptsRefilter {
            return .refilterSelectedTab
        }
        /// Landing on the tab that already answers the question beats building a second one beside
        /// it, which is also the order `openTableTab` takes with `activateIfAlreadyOpen`.
        if context.anotherTabShowsReference { return .revealExistingTab }
        return .openNewTab
    }
}
