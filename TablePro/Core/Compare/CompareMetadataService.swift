//
//  CompareMetadataService.swift
//  TablePro
//
//  Every driver call the comparison makes.
//
//  It exists because the session used to reach `DatabaseManager.shared.driver(for:)`
//  directly, which hands back the connection's single live interactive driver.
//  That driver carries mutable position, so a read taken without
//  `SessionDriverGate` can interleave with a tab's query or land on whichever
//  database that tab last switched to, and it skips `metadataRoute`, which is
//  what keeps an embedded engine from being handed a second, empty instance.
//  `withMetadataDriver(scope:)` is the one route that applies both.
//
//  The closure hands back the app-level `DatabaseDriver`; the comparison needs
//  the plugin transfer types, so the downcast happens inside the gated closure,
//  the same shape `DatabaseManager+Schema` already uses.
//

import Foundation
import os
import TableProPluginKit

/// One table's raw metadata, in transfer types so it can cross the gated closure. Conversion to
/// `TableStructureSnapshot` happens on the caller's side, where the editable definition types live.
internal struct TableStructureRead: Sendable {
    internal let table: PluginTableInfo
    internal let columns: [PluginColumnInfo]
    internal let indexes: [PluginIndexInfo]
    internal let foreignKeys: [PluginForeignKeyInfo]
    internal let metadata: PluginTableMetadata?
    internal let failure: String?

    internal var snapshot: TableStructureSnapshot? {
        guard failure == nil else { return nil }
        return TableStructureSnapshot.from(
            table: table, columns: columns, indexes: indexes, foreignKeys: foreignKeys, metadata: metadata
        )
    }
}

internal struct RoutineSourceRead: Sendable {
    internal let name: String
    internal let kind: CompareObjectKind
    internal let schema: String?
    internal let signature: String?
    internal let source: String
}

@MainActor
internal struct CompareMetadataService {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "CompareMetadataService")

    private let manager: DatabaseManager

    internal init(manager: DatabaseManager = .shared) {
        self.manager = manager
    }

    // MARK: - Scope discovery

    internal func databases(for connection: DatabaseConnection) async throws -> [String] {
        try await manager.ensureConnected(connection)
        let scope = DatabaseScope(connectionId: connection.id, database: connection.database ?? "", schema: nil)
        return try await manager.withMetadataDriver(scope: scope) { driver in
            try await driver.fetchDatabases()
        }
    }

    internal func schemas(for endpoint: DatabaseEndpoint, connection: DatabaseConnection) async throws -> [String] {
        try await manager.ensureConnected(connection)
        return try await manager.withMetadataDriver(scope: endpoint.scope) { driver in
            try await driver.fetchSchemas()
        }
    }

    // MARK: - Capability

    internal func refusalReason(
        for endpoint: DatabaseEndpoint,
        connection: DatabaseConnection,
        mode: CompareSyncMode
    ) async throws -> String? {
        try await manager.ensureConnected(connection)
        let name = endpoint.qualifiedDescription
        return try await manager.withMetadataDriver(scope: endpoint.scope) { driver in
            guard let plugin = Self.pluginDriver(from: driver) else {
                return String(
                    format: String(localized: "%@ cannot be compared, because its driver does not expose metadata."),
                    name
                )
            }
            return CompareSyncEligibility.refusalReason(for: plugin, mode: mode, endpointName: name)
        }
    }

    // MARK: - Structure

    /// One object's failure is that object's, not the comparison's. A single unreadable table used
    /// to abort the whole run, which is why `TableDiffResult.comparisonError` was read by the UI and
    /// written by nothing.
    internal func tableReads(
        for endpoint: DatabaseEndpoint,
        connection: DatabaseConnection,
        includeViews: Bool
    ) async throws -> [TableStructureRead] {
        try await manager.ensureConnected(connection)
        let schema = endpoint.schema
        let concurrency = Self.metadataConcurrency(for: endpoint.databaseType)

        return try await manager.withMetadataDriver(scope: endpoint.scope) { driver in
            guard let plugin = Self.pluginDriver(from: driver) else { return [] }
            let tables = try await plugin.fetchTables(schema: schema).filter { table in
                let kind = CompareTableKindClassifier.kind(of: table)
                return kind == .table || includeViews
            }

            return try await Self.map(tables, concurrency: concurrency) { table in
                await Self.read(table: table, schema: table.schema ?? schema, using: plugin)
            }
        }
    }

    /// `fetchRoutines` supersedes the old per-kind pair and carries `identity`, which is what
    /// `fetchRoutineDDL` needs to address an overloaded routine again. A routine whose DDL cannot
    /// be read is still listed, with an empty definition, so it shows as present rather than
    /// vanishing from the comparison.
    internal func routineReads(
        for endpoint: DatabaseEndpoint,
        connection: DatabaseConnection
    ) async throws -> [RoutineSourceRead] {
        try await manager.ensureConnected(connection)
        let schema = endpoint.schema
        return try await manager.withMetadataDriver(scope: endpoint.scope) { driver in
            guard let plugin = Self.pluginDriver(from: driver) else { return [] }
            let routines = (try? await plugin.fetchRoutines(schema: schema)) ?? []
            var reads: [RoutineSourceRead] = []
            for routine in routines {
                try Task.checkCancellation()
                var source = routine.definition ?? ""
                if source.isEmpty {
                    source = (try? await plugin.fetchRoutineDDL(routine)) ?? ""
                }
                reads.append(RoutineSourceRead(
                    name: routine.name,
                    kind: routine.kind == .procedure ? .procedure : .function,
                    schema: routine.schema ?? schema,
                    signature: routine.argumentSignature,
                    source: source
                ))
            }
            return reads
        }
    }

    /// There is no schema-wide trigger fetch on the driver protocol, so the tables the structure
    /// read already listed are the ones asked. A trigger on a table that is not in scope is not in
    /// scope either.
    internal func triggerReads(
        for endpoint: DatabaseEndpoint,
        connection: DatabaseConnection,
        tables: [String]
    ) async throws -> [RoutineSourceRead] {
        try await manager.ensureConnected(connection)
        let schema = endpoint.schema
        return try await manager.withMetadataDriver(scope: endpoint.scope) { driver in
            guard let plugin = Self.pluginDriver(from: driver) else { return [] }
            var reads: [RoutineSourceRead] = []
            for table in tables {
                try Task.checkCancellation()
                guard let triggers = try? await plugin.fetchTriggers(table: table, schema: schema) else { continue }
                reads += triggers.map { trigger in
                    RoutineSourceRead(
                        name: trigger.name,
                        kind: .trigger,
                        schema: trigger.schema ?? schema,
                        signature: trigger.table ?? table,
                        source: trigger.definition ?? trigger.statement
                    )
                }
            }
            return reads
        }
    }

    internal func viewDefinitions(
        for endpoint: DatabaseEndpoint,
        connection: DatabaseConnection,
        views: [PluginTableInfo]
    ) async throws -> [RoutineSourceRead] {
        try await manager.ensureConnected(connection)
        let schema = endpoint.schema
        return try await manager.withMetadataDriver(scope: endpoint.scope) { driver in
            guard let plugin = Self.pluginDriver(from: driver) else { return [] }
            var reads: [RoutineSourceRead] = []
            for view in views {
                try Task.checkCancellation()
                let definition = try? await plugin.fetchViewDefinition(
                    view: view.name, schema: view.schema ?? schema
                )
                let source = definition ?? ""
                reads.append(RoutineSourceRead(
                    name: view.name,
                    kind: CompareTableKindClassifier.kind(of: view),
                    schema: view.schema ?? schema,
                    signature: nil,
                    source: source
                ))
            }
            return reads
        }
    }

    // MARK: - Helpers

    nonisolated private static func read(
        table: PluginTableInfo,
        schema: String?,
        using plugin: any PluginDatabaseDriver
    ) async -> TableStructureRead {
        do {
            let columns = try await plugin.fetchColumns(table: table.name, schema: schema)
            let indexes = (try? await plugin.fetchIndexes(table: table.name, schema: schema)) ?? []
            let foreignKeys = (try? await plugin.fetchForeignKeys(table: table.name, schema: schema)) ?? []
            let metadata = try? await plugin.fetchTableMetadata(table: table.name, schema: schema)
            return TableStructureRead(
                table: table, columns: columns, indexes: indexes,
                foreignKeys: foreignKeys, metadata: metadata, failure: nil
            )
        } catch {
            Self.logger.warning(
                "Structure read failed for \(table.name, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return TableStructureRead(
                table: table, columns: [], indexes: [], foreignKeys: [],
                metadata: nil, failure: error.localizedDescription
            )
        }
    }

    /// A driver that cannot be pooled reaches a different database on a second connection, so its
    /// reads stay serial. Everything else fans out, because the old code paid one round trip per
    /// table for columns, indexes, foreign keys and metadata in strict sequence.
    nonisolated private static func metadataConcurrency(for databaseType: DatabaseType) -> Int {
        databaseType.supportsConnectionPooling ? 4 : 1
    }

    nonisolated private static func map<Element: Sendable, Result: Sendable>(
        _ elements: [Element],
        concurrency: Int,
        _ transform: @escaping @Sendable (Element) async -> Result
    ) async throws -> [Result] {
        guard concurrency > 1, elements.count > 1 else {
            var results: [Result] = []
            for element in elements {
                try Task.checkCancellation()
                results.append(await transform(element))
            }
            return results
        }

        return try await withThrowingTaskGroup(of: (Int, Result).self) { group in
            var results = [Result?](repeating: nil, count: elements.count)
            var next = 0
            var running = 0

            while next < elements.count && running < concurrency {
                let index = next
                group.addTask { (index, await transform(elements[index])) }
                next += 1
                running += 1
            }

            while let (index, result) = try await group.next() {
                results[index] = result
                running -= 1
                try Task.checkCancellation()
                if next < elements.count {
                    let queued = next
                    group.addTask { (queued, await transform(elements[queued])) }
                    next += 1
                    running += 1
                }
            }
            return results.compactMap { $0 }
        }
    }

    nonisolated internal static func pluginDriver(from driver: DatabaseDriver) -> (any PluginDatabaseDriver)? {
        (driver as? PluginDriverAdapter)?.schemaPluginDriver
    }
}
