//
//  QuickSwitcherHostResolver.swift
//  TablePro
//

import Foundation

internal enum QuickSwitcherHostResolver {
    /// Which window opens a quick switcher result, given every window that could host it.
    ///
    /// The window the panel was opened from wins whenever it can host the result. Every other
    /// window on the same connection and database is an equally good match, and the registry
    /// holding them is a dictionary with no order, so picking one arbitrarily loads the result
    /// into an editor the user is not looking at and pulls focus there. When the result belongs
    /// to another connection, the most recently focused window of that connection wins.
    internal static func host<ID: Equatable>(
        preferred: ID?,
        candidates: [ID],
        mostRecentlyFocused: ID?
    ) -> ID? {
        if let preferred, candidates.contains(preferred) { return preferred }
        if let mostRecentlyFocused, candidates.contains(mostRecentlyFocused) { return mostRecentlyFocused }
        return candidates.first
    }
}
