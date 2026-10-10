//
//  QuickSwitcherViewModel+ListingDemand.swift
//  TablePro
//

import Foundation

/// Other schemas' tables come from one listing of the database, which nothing on screen needs until a
/// search runs, the Tables scope lists every table, or a Recent row names a table only it holds.
internal extension QuickSwitcherViewModel {
    nonisolated static func wantsAllSchemaListing(
        scope: QuickSwitcherScope,
        query: String,
        recentNeedsListing: () -> Bool
    ) -> Bool {
        switch scope {
        case .all: return !query.isEmpty || recentNeedsListing()
        case .tables: return true
        case .containers, .queries, .connections: return false
        }
    }

    /// Walks Recent in rank order, the order the section fills in. Once `limit` keys have resolved
    /// the section is full; a table key that has not resolved before that may be in the listing.
    nonisolated static func recentNeedsListing(
        recentKeys: [String],
        resolvedKeys: Set<String>,
        isTableKey: (String) -> Bool,
        limit: Int = QuickSwitcherRanking.recentLimit
    ) -> Bool {
        var resolved = 0
        for key in recentKeys {
            guard resolved < limit else { return false }
            if resolvedKeys.contains(key) {
                resolved += 1
            } else if isTableKey(key) {
                return true
            }
        }
        return false
    }
}
