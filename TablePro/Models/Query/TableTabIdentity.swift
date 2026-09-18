//
//  TableTabIdentity.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// The three values a table tab is keyed on from the moment it opens.
///
/// `QueryTabManager.tabShowingTable` finds a tab by this triple and the strip titles two tabs
/// apart by it, so anything that has to reach the tab showing a given object has to spell it the
/// same way. Closing tabs after a drop compared the table name on its own, so dropping
/// `analytics.users` also closed the tab on `public.users` and discarded its row buffer.
struct TableTabIdentity: Hashable, Sendable {
    let table: String
    let database: String
    let schema: String?

    init(table: String, database: String, schema: String?) {
        self.table = table
        self.database = database
        self.schema = schema?.nilIfEmpty
    }

    /// A tab opened from the object tree takes the browse database rather than the row's own,
    /// because the tree activates the row's database before it opens anything. Resolving the
    /// schema is the caller's job for the same reason: only the session knows its default.
    init(ref: DatabaseTreeTableRef, browsing browseDatabase: String, resolvedSchema: String?) {
        self.init(
            table: ref.table.name,
            database: ref.database ?? browseDatabase,
            schema: resolvedSchema
        )
    }
}

extension QueryTab {
    /// A tab restored from a payload written before tabs carried a database has an empty one, and
    /// `resolvedDatabaseName` defines that as the browse cursor. Reading the raw field instead left
    /// such a tab open with dead rows after its table was dropped.
    func tableIdentity(browsing browseDatabase: String) -> TableTabIdentity? {
        guard tabType == .table, let name = tableContext.tableName, !name.isEmpty else { return nil }
        return TableTabIdentity(
            table: name,
            database: tableContext.resolvedDatabaseName(browsing: browseDatabase),
            schema: tableContext.schemaName?.nilIfEmpty
        )
    }
}
