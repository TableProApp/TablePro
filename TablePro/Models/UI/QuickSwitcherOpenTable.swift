//
//  QuickSwitcherOpenTable.swift
//  TablePro
//

import Foundation

/// A table that already has a tab, identified the way the quick switcher has to match it.
///
/// Matching on the bare name is wrong the moment a connection has two databases or two schemas
/// holding a table of the same name: with `tenant_a.orders` open, `tenant_b.orders` was badged
/// Open, boosted in the ranking and offered "Switch to Tab", and committing it opened a second tab
/// anyway.
///
/// A side that names no database or schema follows the connection's browse cursor, the rule
/// `TabTableContext.resolvedDatabaseName(browsing:)` applies. Both sides resolve through this
/// initializer with the same cursor, so a driver that reports neither still matches on name.
internal struct QuickSwitcherOpenTable: Hashable, Sendable {
    internal let database: String?
    internal let schema: String?
    internal let name: String

    internal init(
        database: String?,
        schema: String?,
        name: String,
        browsingDatabase: String?,
        browsingSchema: String?
    ) {
        self.database = Self.resolve(database, browsing: browsingDatabase)
        self.schema = Self.resolve(schema, browsing: browsingSchema)
        self.name = name
    }

    private static func resolve(_ value: String?, browsing browsed: String?) -> String? {
        if let value, !value.isEmpty {
            return value
        }
        guard let browsed, !browsed.isEmpty else { return nil }
        return browsed
    }
}
