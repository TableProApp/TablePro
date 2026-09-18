import Foundation

/// Which databases and schemas the sidebar tree and its database filter list.
///
/// A browsing list, so system containers are hidden unless the user asked for them. Switchers are a
/// different kind of list and use `DatabaseSwitchList`, which always offers them.
enum DatabaseTreeVisibility {
    struct Summary: Equatable {
        let shown: Int
        let total: Int
    }

    static func filterCandidates(_ databases: [DatabaseMetadata], showsSystem: Bool) -> [DatabaseMetadata] {
        guard !showsSystem else { return databases }
        return databases.filter { !$0.isSystemDatabase }
    }

    /// A filter saved while system databases were listed can name one that is now hidden. Counting that
    /// name would leave a filter that selects nothing on screen and blank the tree, so hidden names are
    /// set aside until the setting brings them back. A name that no longer exists at all still counts.
    static func effectiveSelection(
        _ selected: Set<String>,
        databases: [DatabaseMetadata],
        showsSystem: Bool
    ) -> Set<String> {
        guard !showsSystem else { return selected }
        let hiddenSystemNames = databases.filter(\.isSystemDatabase).map(\.name)
        return selected.subtracting(hiddenSystemNames)
    }

    static func visible(
        databases: [DatabaseMetadata],
        selected: Set<String>,
        activeDatabase: String?,
        showsSystem: Bool
    ) -> [DatabaseMetadata] {
        let active = activeDatabase.flatMap { $0.isEmpty ? nil : $0 }
        let selection = effectiveSelection(selected, databases: databases, showsSystem: showsSystem)
        return databases.filter { database in
            if database.name == active { return true }
            if database.isSystemDatabase, !showsSystem { return false }
            return selection.isEmpty || selection.contains(database.name)
        }
    }

    static func isFiltering(selected: Set<String>, databases: [DatabaseMetadata], showsSystem: Bool) -> Bool {
        !effectiveSelection(selected, databases: databases, showsSystem: showsSystem).isEmpty
    }

    /// Counts what the filter picks out of what it could pick, so the sidebar banner and the filter
    /// popover report the same pair. The active database is listed whether or not the filter picks it,
    /// and counting it here produced totals like "Showing 2 of 1".
    static func summary(databases: [DatabaseMetadata], selected: Set<String>, showsSystem: Bool) -> Summary {
        let candidates = filterCandidates(databases, showsSystem: showsSystem)
        let selection = effectiveSelection(selected, databases: databases, showsSystem: showsSystem)
        let shown = selection.isEmpty
            ? candidates.count
            : candidates.filter { selection.contains($0.name) }.count
        return Summary(shown: shown, total: candidates.count)
    }

    /// The schema being browsed stays listed even when it is a system schema, for the same reason the
    /// active database does: hiding it leaves the objects the user is working in with no row to hang from.
    static func visibleSchemas(
        _ schemas: [String],
        systemSchemas: Set<String>,
        activeSchema: String?,
        showsSystem: Bool
    ) -> [String] {
        guard !showsSystem else { return schemas }
        let active = activeSchema.flatMap { $0.isEmpty ? nil : $0 }
        return schemas.filter { !systemSchemas.contains($0) || $0 == active }
    }
}
