//
//  BackupScopeLoader.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

/// What the backup sheet's tree lists, read from the connection.
///
/// Databases come first and their objects only when a row is expanded. A server with two hundred
/// databases would otherwise cost two hundred table reads, and on PostgreSQL a connection each,
/// before the sheet could draw anything.
enum BackupScopeLoader {
    private static let logger = Logger(subsystem: "com.TablePro", category: "BackupScopeLoader")

    /// Every database this connection can be told to dump.
    ///
    /// An engine that reports none has exactly one, which is the file it opened. SQLite reports an
    /// empty list, and taking that literally is what left the backup sheet showing "No databases"
    /// with a permanently dimmed confirm button on every SQLite connection.
    @MainActor
    static func databases(for connection: DatabaseConnection) async -> [Container] {
        let fallback = [singleContainer(for: connection)]
        guard PluginManager.shared.supportsDatabaseSwitching(for: connection.type) else {
            return fallback
        }
        let names = try? await DatabaseManager.shared.withBrowseMetadataDriver(
            connectionId: connection.id
        ) { driver in
            try await driver.fetchDatabases()
        }
        let visible = (names ?? []).filter { !$0.isEmpty }
        guard !visible.isEmpty else { return fallback }
        return visible.map { Container(name: $0, displayName: $0) }
    }

    /// A database's identity and the name to show for it, which are not always the same string.
    ///
    /// A file-backed engine keeps its whole path in the field a server engine keeps a database name
    /// in. `name` has to stay that path, because it is what a scoped metadata read reconnects with
    /// and what the dump tool opens; showing it puts `/Users/me/Library/.../Chinook.sqlite` in the
    /// tree and then into the dump's file name.
    struct Container: Sendable, Equatable {
        let name: String
        let displayName: String
    }

    /// The one entry a file-backed or single-database connection is listed under.
    @MainActor
    static func singleContainer(for connection: DatabaseConnection) -> Container {
        let declared = connection.database.trimmingCharacters(in: .whitespaces)
        let name = declared.isEmpty
            ? PluginManager.shared.defaultGroupName(for: connection.type)
            : declared
        guard let path = NativeDumpService.localFilePath(for: connection), !path.isEmpty else {
            return Container(name: name, displayName: name)
        }
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return Container(name: name, displayName: stem.isEmpty ? name : stem)
    }

    /// The objects one database offers, schema-qualified where the engine has schemas.
    ///
    /// The qualification is not cosmetic: `pg_dump -t` matches `"schema"."table"`, and an
    /// unqualified name matches only what the search path happens to reach.
    @MainActor
    static func objects(
        in database: String,
        connection: DatabaseConnection
    ) async -> [NativeDumpObject] {
        let grouping = PluginManager.shared.databaseGroupingStrategy(for: connection.type)
        let scope = DatabaseScope(connectionId: connection.id, database: database, schema: nil)
        do {
            switch grouping {
            case .bySchema, .hierarchicalSchema:
                return try await schemaQualifiedObjects(scope: scope)
            case .flat, .byDatabase:
                let tables = try await DatabaseManager.shared.withMetadataDriver(
                    scope: scope, workload: .bulk
                ) { driver in
                    try await driver.fetchTables()
                }
                return tables.filter { $0.type == .table }.map { NativeDumpObject(name: $0.name) }
            }
        } catch {
            logger.warning("object list failed for \(database, privacy: .public)")
            return []
        }
    }

    @MainActor
    private static func schemaQualifiedObjects(scope: DatabaseScope) async throws -> [NativeDumpObject] {
        let schemas = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
            try await driver.fetchSchemas()
        }
        var objects: [NativeDumpObject] = []
        for schema in schemas {
            let qualified = DatabaseScope(
                connectionId: scope.connectionId, database: scope.database, schema: schema
            )
            let tables = try await DatabaseManager.shared.withMetadataDriver(
                scope: qualified, workload: .bulk
            ) { driver in
                try await driver.fetchTables(schema: schema)
            }
            objects += tables
                .filter { $0.type == .table }
                .map { NativeDumpObject(name: $0.name, schema: schema) }
        }
        return objects
    }

    /// Everything `sqlite3 .dump` has to be told about to reproduce the chosen tables.
    ///
    /// Measured with sqlite3 3.54.0: `.dump t1` writes `CREATE TABLE t1` and nothing else, so a
    /// narrowed dump silently loses that table's indexes and triggers. Naming them alongside it
    /// brings all three back. Every other engine already carries a table's dependents, so this runs
    /// for the SQLite family alone.
    @MainActor
    static func expandDependents(
        _ scope: NativeDumpScope,
        connection: DatabaseConnection,
        database: String
    ) async -> NativeDumpScope {
        guard connection.type == .sqlite || connection.type == .libsql else { return scope }
        guard !scope.isWholeDatabase else { return scope }
        let databaseScope = DatabaseScope(connectionId: connection.id, database: database, schema: nil)
        var names = scope.objects.map(\.name)
        var seen = Set(names)
        for object in scope.objects {
            let dependents = try? await DatabaseManager.shared.withMetadataDriver(
                scope: databaseScope
            ) { driver in
                try await driver.executeParameterized(
                    query: NativeDumpArgumentQuoting.sqliteDependentsQuery(),
                    parameters: [object.name]
                )
            }
            for row in dependents?.rows ?? [] {
                guard let name = row.first?.asText, seen.insert(name).inserted else { continue }
                names.append(name)
            }
        }
        return .objects(names.map { NativeDumpObject(name: $0) })
    }
}
