import Foundation

/// Which databases and schemas the sidebar tree and its filters list.
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
        showsSystem: Bool,
        selected: Set<String> = [],
        pinned: Set<String> = []
    ) -> [String] {
        let active = activeSchema.flatMap { $0.isEmpty ? nil : $0 }
        let selection = effectiveSchemaSelection(
            selected, schemas: schemas, systemSchemas: systemSchemas, showsSystem: showsSystem
        )
        return schemas.filter { schema in
            if schema == active || pinned.contains(schema) { return true }
            if !showsSystem, systemSchemas.contains(schema) { return false }
            return selection.isEmpty || selection.contains(schema)
        }
    }

    static func schemaFilterCandidates(_ schemas: [String], systemSchemas: Set<String>, showsSystem: Bool) -> [String] {
        guard !showsSystem else { return schemas }
        return schemas.filter { !systemSchemas.contains($0) }
    }

    /// Unlike a database filter, a name the schema list no longer holds is set aside too, or a filter
    /// of dropped schemas shows the browsed schema alone. Nil `schemas` is a list not read yet.
    static func effectiveSchemaSelection(
        _ selected: Set<String>,
        schemas: [String]?,
        systemSchemas: Set<String>,
        showsSystem: Bool
    ) -> Set<String> {
        var selection = showsSystem ? selected : selected.subtracting(systemSchemas)
        if let schemas {
            selection.formIntersection(schemas)
        }
        return selection
    }

    static func isFilteringSchemas(
        selected: Set<String>,
        schemas: [String]?,
        systemSchemas: Set<String>,
        showsSystem: Bool
    ) -> Bool {
        !effectiveSchemaSelection(selected, schemas: schemas, systemSchemas: systemSchemas, showsSystem: showsSystem)
            .isEmpty
    }

    static func schemaSummary(
        schemas: [String],
        selected: Set<String>,
        systemSchemas: Set<String>,
        showsSystem: Bool
    ) -> Summary {
        let candidates = schemaFilterCandidates(schemas, systemSchemas: systemSchemas, showsSystem: showsSystem)
        let selection = effectiveSchemaSelection(
            selected, schemas: schemas, systemSchemas: systemSchemas, showsSystem: showsSystem
        )
        let shown = selection.isEmpty ? candidates.count : candidates.filter { selection.contains($0) }.count
        return Summary(shown: shown, total: candidates.count)
    }

    /// The schemas a filtered reader may read, or nil when nothing is filtered. The browsed schema
    /// joins a non-empty selection because the tree lists it whatever the filter says.
    static func keptSchemas(
        selected: Set<String>,
        schemas: [String]?,
        systemSchemas: Set<String>,
        showsSystem: Bool,
        activeSchema: String?
    ) -> Set<String>? {
        let selection = effectiveSchemaSelection(
            selected, schemas: schemas, systemSchemas: systemSchemas, showsSystem: showsSystem
        )
        guard !selection.isEmpty else { return nil }
        guard let active = activeSchema, !active.isEmpty else { return selection }
        return selection.union([active])
    }
}
