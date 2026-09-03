//
//  UserDefinedTypeSuggestions.swift
//  TablePro
//

import Foundation
import os

/// The user-defined types a column type picker offers, spelled as a column definition names them.
///
/// The sidebar's caches are the wrong source: `SchemaService` holds the browsed scope, which need
/// not be the table's, and `DatabaseTreeMetadataService` fills only on tree expansion. The picker
/// fetches for the table's own database and keeps nothing, because a schema's types change rarely
/// and one catalog read per popover is cheaper than a cache nothing else invalidates.
enum UserDefinedTypeSuggestions {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "TypePicker")

    /// Every schema-bound type is qualified, its own schema included: PostgreSQL searches
    /// `pg_catalog` before the search path, so a bare `text` names the built-in even where the
    /// table's schema holds a domain called `text`. The engine's own spelling is used where the
    /// driver supplied one, because only the engine knows which names it folds or reserves; the
    /// fallback quotes each part that is not a plain lower-case identifier.
    static func entries(types: [UserDefinedTypeInfo], tableSchema: String?) -> [String] {
        types
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

    /// Every schema the table can reach, not only its own: a column may use `sales.status` from a
    /// table in `public`, and the picker is where that spelling is learned.
    @MainActor
    static func load(scope: DatabaseScope) async -> [String] {
        guard let session = DatabaseManager.shared.session(for: scope.connectionId),
              session.connection.type.supportsUserDefinedTypeBrowse
        else { return [] }
        let systemSchemas = Set(PluginManager.shared.systemSchemaNames(for: session.connection.type))
        do {
            let types = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
                let schemas = try await driver.fetchSchemas().filter { !systemSchemas.contains($0) }
                let targets: [String?] = schemas.isEmpty ? [scope.schema] : schemas
                return try await withThrowingTaskGroup(of: [UserDefinedTypeInfo].self) { group in
                    for schema in targets {
                        group.addTask { try await driver.fetchUserDefinedTypes(schema: schema) }
                    }
                    var all: [UserDefinedTypeInfo] = []
                    for try await types in group { all += types }
                    return all
                }
            }
            return entries(types: types, tableSchema: scope.schema)
        } catch is CancellationError {
            return []
        } catch {
            logger.warning("user-defined type fetch failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
