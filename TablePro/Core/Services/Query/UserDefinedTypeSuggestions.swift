//
//  UserDefinedTypeSuggestions.swift
//  TablePro
//

import Foundation
import os

internal protocol UserDefinedTypeCatalogReading: Sendable {
    func fetchSchemas() async throws -> [String]
    func fetchUserDefinedTypes(schema: String?) async throws -> [UserDefinedTypeInfo]
    func fetchUserDefinedTypes(inSchemas schemas: [String]) async throws -> [UserDefinedTypeInfo]?
}

internal struct DriverTypeCatalog: UserDefinedTypeCatalogReading {
    let driver: any DatabaseDriver

    func fetchSchemas() async throws -> [String] {
        try await driver.fetchSchemas()
    }

    func fetchUserDefinedTypes(schema: String?) async throws -> [UserDefinedTypeInfo] {
        try await driver.fetchUserDefinedTypes(schema: schema)
    }

    func fetchUserDefinedTypes(inSchemas schemas: [String]) async throws -> [UserDefinedTypeInfo]? {
        try await driver.fetchUserDefinedTypes(inSchemas: schemas)
    }
}

/// The user-defined types a column type picker offers, spelled as a column definition names them.
///
/// Read from the table's own database on each open and kept nowhere: one statement covers every
/// offered schema, and the sidebar's caches hold the browsed scope, which need not be the table's.
enum UserDefinedTypeSuggestions {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "TypePicker")

    /// Every schema-bound type is qualified, its own schema included: PostgreSQL searches
    /// `pg_catalog` before the search path, so a bare `text` names the built-in even where the
    /// table's schema holds a domain called `text`. The engine's own spelling is used where the
    /// driver supplied one, because only the engine knows which names it folds or reserves; the
    /// fallback quotes each part that is not a plain lower-case identifier.
    ///
    /// A kind that cannot stand as a column type is left out rather than offered and rejected by
    /// the server: a SQL Server table type is a table-valued parameter and nothing else.
    static func entries(types: [UserDefinedTypeInfo], tableSchema: String?) -> [String] {
        types
            .filter(\.kind.isUsableAsColumnType)
            .map { type -> String in
                if let spelling = type.columnTypeSpelling, !spelling.isEmpty { return spelling }
                guard let schema = type.schema, !schema.isEmpty else { return identifier(type.name) }
                return "\(identifier(schema)).\(identifier(type.name))"
            }
            .sorted { sortKey($0).localizedCaseInsensitiveCompare(sortKey($1)) == .orderedAscending }
    }

    /// Quotes are spelling, not order: `app."select"` belongs between `app.mood` and `app.zeta`,
    /// not ahead of every bare name because a quote sorts before a letter.
    private static func sortKey(_ entry: String) -> String {
        entry.replacingOccurrences(of: "\"", with: "")
    }

    /// Bare only for a name PostgreSQL would read back unchanged: lower-case letters, digits and
    /// underscores, not starting with a digit. Anything else is double-quoted, quotes doubled.
    static func identifier(_ name: String) -> String {
        let scalars = name.unicodeScalars
        let isPlain = !scalars.isEmpty
            && !(scalars.first.map { CharacterSet.decimalDigits.contains($0) } ?? false)
            && scalars.allSatisfy { Self.plainIdentifierScalars.contains($0) }
        guard !isPlain else { return name }
        return "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static let plainIdentifierScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")

    /// Every schema the sidebar shows, not only the table's own: a column may use `sales.status`
    /// from a table in `public`, and the picker is where that spelling is learned.
    @MainActor
    static func load(scope: DatabaseScope) async -> [String] {
        guard let session = DatabaseManager.shared.session(for: scope.connectionId),
              session.connection.type.supportsUserDefinedTypeBrowse
        else { return [] }
        let systemSchemas = Set(PluginManager.shared.systemSchemaNames(for: session.connection.type))
        let schemaFilter = SidebarSchemaFilter().keptSchemas(connectionId: scope.connectionId, database: scope.database) ?? []
        let tableSchema = scope.schema
        do {
            let types = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
                try await Self.fetchTypes(
                    from: DriverTypeCatalog(driver: driver),
                    tableSchema: tableSchema,
                    systemSchemas: systemSchemas,
                    schemaFilter: schemaFilter
                )
            }
            return entries(types: types, tableSchema: scope.schema)
        } catch is CancellationError {
            return []
        } catch {
            logger.warning("user-defined type fetch failed: \(error.publicLogShape, privacy: .public)")
            return []
        }
    }

    /// The table's own schema is offered even when the sidebar hides it or the server did not list it.
    /// An engine that lists no schemas offers none, and is asked about the table's own scope alone.
    static func offeredSchemas(
        listed: [String],
        tableSchema: String?,
        systemSchemas: Set<String>,
        schemaFilter: Set<String>
    ) -> [String] {
        guard !listed.isEmpty else { return [] }
        var offered = listed.filter { schema in
            guard !systemSchemas.contains(schema) else { return false }
            return schemaFilter.isEmpty || schemaFilter.contains(schema) || schema == tableSchema
        }
        if let tableSchema, !tableSchema.isEmpty, !systemSchemas.contains(tableSchema), !offered.contains(tableSchema) {
            offered.append(tableSchema)
        }
        return offered
    }

    static func fetchTypes(
        from catalog: some UserDefinedTypeCatalogReading,
        tableSchema: String?,
        systemSchemas: Set<String>,
        schemaFilter: Set<String>
    ) async throws -> [UserDefinedTypeInfo] {
        let offered = offeredSchemas(
            listed: try await catalog.fetchSchemas(),
            tableSchema: tableSchema,
            systemSchemas: systemSchemas,
            schemaFilter: schemaFilter
        )
        guard !offered.isEmpty else { return try await catalog.fetchUserDefinedTypes(schema: tableSchema) }
        if let types = try await catalog.fetchUserDefinedTypes(inSchemas: offered) { return types }
        return try await withThrowingTaskGroup(of: [UserDefinedTypeInfo].self) { group in
            for schema in offered {
                group.addTask { try await catalog.fetchUserDefinedTypes(schema: schema) }
            }
            var all: [UserDefinedTypeInfo] = []
            for try await types in group { all += types }
            return all
        }
    }
}
