//
//  EditorTabDetachPolicy.swift
//  TablePro
//

import Foundation

/// Whether a tab may be moved into a window of its own, kept apart from the window machinery so
/// the rule can be tested without one.
///
/// The rule is narrow on purpose. Detaching moves a `QueryTab`, which carries what is persisted;
/// it does not carry a coordinator's live edit state, so a tab with work that has not been written
/// yet would arrive in the new window with that work silently gone. Refusing is the honest answer,
/// and the same one the strip gives for a reorder it cannot complete: the command dims rather than
/// destroying something quietly.
internal enum EditorTabDetachPolicy {
    internal static func canDetach(
        tabCount: Int,
        hasUnsavedWork: Bool,
        isBusy: Bool,
        isConnected: Bool
    ) -> Bool {
        /// The last tab has nowhere to go. Moving it would empty this window and fill an identical
        /// one, which is what `Move Connection to New Window` already does and says.
        guard tabCount > 1 else { return false }
        guard !hasUnsavedWork else { return false }
        /// A query or a table load in flight is claimed by the coordinator that started it. Moving
        /// the tab out from under one leaves the completion with no tab to write into and the new
        /// window with no claim, so it fetches the same page again.
        guard !isBusy else { return false }
        return isConnected
    }
}
