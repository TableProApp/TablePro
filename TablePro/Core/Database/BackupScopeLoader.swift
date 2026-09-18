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
                return tables.filter(\.type.isBackupSelectable).map {
                    NativeDumpObject(name: $0.name, isPartitionedParent: $0.type == .partitionedTable)
                }
            }
        } catch {
            logger.warning("object list failed for \(database, privacy: .private(mask: .hash))")
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
                .filter(\.type.isBackupSelectable)
                .map {
                    NativeDumpObject(
                        name: $0.name,
                        schema: schema,
                        isPartitionedParent: $0.type == .partitionedTable
                    )
                }
        }
        return objects
    }

    /// Everything the dump tool has to be told about to reproduce the chosen objects.
    ///
    /// Two expansions, each measured. `sqlite3 3.54.0`: `.dump t1` writes `CREATE TABLE t1` and
    /// nothing else, so a narrowed dump silently loses that table's indexes and triggers; naming
    /// them alongside it brings all three back. `pg_dump 17.11`: `-t '"public"."orders"'` on a
    /// partitioned parent emits `CREATE TABLE` and no data at all, and restoring that archive
    /// gives one empty partitioned table, so each partition is named too.
    ///
    /// Only ever reached over a narrowed selection: a fully ticked database resolves to
    /// `.wholeDatabase` in `BackupScopeModel.scopes`.
    ///
    /// A partition read that fails is reported rather than read as "no partitions", so the database
    /// is withheld and named instead of dumped from the parent alone.
    @MainActor
    static func expandDependents(
        _ scope: NativeDumpScope,
        connection: DatabaseConnection,
        database: String
    ) async -> NativeDumpScopeExpansion {
        guard !scope.isWholeDatabase else { return NativeDumpScopeExpansion(scope: scope) }
        let databaseScope = DatabaseScope(connectionId: connection.id, database: database, schema: nil)
        if connection.type == .sqlite || connection.type == .libsql {
            return NativeDumpScopeExpansion(scope: await expandSQLiteDependents(scope, databaseScope: databaseScope))
        }
        /// No engine gate. An engine with no partitions answers `relationType` nil and expands to
        /// nothing, and an object nobody marked as a parent costs no read at all.
        guard scope.objects.contains(where: \.isPartitionedParent) else {
            return NativeDumpScopeExpansion(scope: scope)
        }
        return await expandPartitions(scope.objects) { table, schema in
            do {
                return try await DatabaseManager.shared.withMetadataDriver(scope: databaseScope) { driver in
                    try await driver.fetchPartitionDetails(table: table, schema: schema)
                }
            } catch {
                logger.warning(
                    "partition read failed for \(table, privacy: .public): \(error.localizedDescription)"
                )
                return nil
            }
        }
    }

    /// The tree walk on its own, so it can be exercised without a driver.
    ///
    /// A partition that is a relation is dumped by name like any other table, and one that is
    /// itself subpartitioned is walked into. A partition carries its own schema, which need not be
    /// its parent's, and a name already in the list is never added twice.
    ///
    /// `fetch` answers nil for a read that failed, which is not the same as an empty answer: the
    /// parent is named in `unreadableObjects` so the dump of its database is withheld rather than
    /// written from the parent alone.
    @MainActor
    static func expandPartitions(
        _ objects: [NativeDumpObject],
        fetch: @MainActor (_ table: String, _ schema: String?) async -> [PartitionInfo]?
    ) async -> NativeDumpScopeExpansion {
        var expanded: [NativeDumpObject] = []
        var unreadable: [String] = []
        var seen = Set<ObjectKey>()
        var pending: [NativeDumpObject] = []
        for object in objects where seen.insert(ObjectKey(object)).inserted {
            expanded.append(object)
            if object.isPartitionedParent { pending.append(object) }
        }
        var index = 0
        while index < pending.count {
            let parent = pending[index]
            index += 1
            guard let partitions = await fetch(parent.name, parent.schema) else {
                unreadable.append(qualifiedName(parent))
                continue
            }
            for partition in partitions where partition.isSeparateRelation {
                let child = NativeDumpObject(name: partition.name, schema: partition.schema ?? parent.schema)
                guard seen.insert(ObjectKey(child)).inserted else { continue }
                expanded.append(child)
                if partition.isSubpartitioned { pending.append(child) }
            }
        }
        return NativeDumpScopeExpansion(scope: .objects(expanded), unreadableObjects: unreadable)
    }

    private static func qualifiedName(_ object: NativeDumpObject) -> String {
        guard let schema = object.schema else { return object.name }
        return "\(schema).\(object.name)"
    }

    /// Identity for the walk. `NativeDumpObject` carries the expansion hint in its own equality, so
    /// a parent and a partition of the same name would compare unequal and be dumped twice.
    private struct ObjectKey: Hashable {
        let name: String
        let schema: String?

        init(_ object: NativeDumpObject) {
            name = object.name
            schema = object.schema
        }
    }

    @MainActor
    private static func expandSQLiteDependents(
        _ scope: NativeDumpScope,
        databaseScope: DatabaseScope
    ) async -> NativeDumpScope {
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
