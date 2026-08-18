//
//  QuickSwitcherOpenTable.swift
//  TablePro
//

import Foundation

/// A table that already has a tab, identified the way the quick switcher has to match it.
///
/// Matching on the bare name is wrong the moment a connection has two schemas holding a table of
/// the same name: with `public.users` open, `analytics.users` was badged Open, boosted in the
/// ranking and offered "Switch to Tab", and committing it opened a second tab anyway.
///
/// A tab or a catalog entry that names no schema follows the connection's browse cursor, which is
/// the rule `TabTableContext.resolvedDatabaseName(browsing:)` already applies to databases. Both
/// sides resolve through this initializer with the same cursor, so a driver that reports no schema
/// at all still matches on name, while two schemas that both hold `users` no longer collide.
internal struct QuickSwitcherOpenTable: Hashable, Sendable {
    internal let schema: String?
    internal let name: String

    internal init(schema: String?, name: String, browsing browseSchema: String?) {
        self.schema = Self.resolve(schema, browsing: browseSchema)
        self.name = name
    }

    private static func resolve(_ schema: String?, browsing browseSchema: String?) -> String? {
        if let schema, !schema.isEmpty {
            return schema
        }
        guard let browseSchema, !browseSchema.isEmpty else { return nil }
        return browseSchema
    }
}
