//
//  SidebarAttachedSchemas.swift
//  TablePro
//

import Foundation

/// The databases a file connection attaches beside the one it opened. The flat list keeps the opened
/// file's objects in its kind sections and lists each attached database below them as a schema row,
/// which loads, expands and offers its menus the way a schema row does in the tree.
internal enum SidebarAttachedSchemas {
    /// Every attached database while nothing is searched. During a search, those whose name matches or
    /// whose loaded objects hold a match; one not read yet stays out until its read lands.
    internal static func visible(
        attached: [String],
        database: String,
        searchText: String,
        loadedContent: (String) -> DatabaseTreeObjectBuckets?
    ) -> [String] {
        guard !searchText.isEmpty else { return attached }
        return attached.filter { schema in
            DatabaseTreeFilter.schemaSearchVerdict(
                schema: schema,
                database: database,
                searchText: searchText,
                loadedContent: loadedContent(schema),
                listingMatches: nil,
                listingCoversSchema: false
            ) == .match
        }
    }
}

internal extension DatabaseTreeTableRef {
    /// A table of a database attached beside the opened file, which every statement has to name
    /// by that database.
    @MainActor
    func isInAttachedDatabase(of databaseType: DatabaseType) -> Bool {
        qualifyingSchema != nil && PluginManager.shared.listsAttachedDatabases(for: databaseType)
    }
}
