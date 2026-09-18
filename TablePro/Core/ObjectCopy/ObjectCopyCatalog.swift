//
//  ObjectCopyCatalog.swift
//  TablePro
//
//  What a scope has to offer, by identity only.
//
//  The sheet lists objects before the user has chosen anything, so this reads
//  names rather than structures: `CompareMetadataService.tableReads` pays four
//  round trips per table for columns, indexes, foreign keys and metadata, which
//  is the right price to plan a copy and the wrong one to fill a checklist.
//
//  A routine carries its argument signature and a trigger its table, because
//  two overloads and two same-named triggers are two objects and the planner
//  keys on that identity.
//

import Foundation
import os
import TableProPluginKit

@MainActor
internal struct ObjectCopyCatalog {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ObjectCopyCatalog")

    private let manager: DatabaseManager

    internal init(manager: DatabaseManager = .shared) {
        self.manager = manager
    }

    /// Every object in the endpoint's scope, and on a schema-aware engine that names no schema,
    /// every object in every schema of the database.
    ///
    /// `fetchTables(schema: nil)` resolves to the connection's current schema on PostgreSQL and
    /// SQL Server, so a whole-database copy taken that way carried one schema and reported success
    /// over the rest. Each selection keeps the schema it was found in, which is what lets the
    /// planner read and write them one namespace at a time.
    internal func objects(
        in endpoint: DatabaseEndpoint,
        connection: DatabaseConnection
    ) async throws -> [ObjectCopySelection] {
        try await manager.ensureConnected(connection)
        let scopes = try await namespaces(of: endpoint, connection: connection)
        var found: [ObjectCopySelection] = []
        for scope in scopes {
            found += try await manager.withMetadataDriver(
                scope: endpoint.withSchema(scope).scope, workload: .bulk
            ) { driver in
                guard let plugin = CompareMetadataService.pluginDriver(from: driver) else { return [] }
                return try await Self.read(from: plugin, schema: scope)
            }
        }
        return found
    }

    /// The schemas one read has to cover. A single nil is "whatever the connection is on", which is
    /// the right answer for every engine without schemas and for a scope that already names one.
    internal func namespaces(
        of endpoint: DatabaseEndpoint,
        connection: DatabaseConnection
    ) async throws -> [String?] {
        guard PluginManager.shared.supportsSchemaSwitching(for: endpoint.databaseType),
              (endpoint.schema ?? "").isEmpty
        else { return [endpoint.schema?.nilIfEmpty] }
        let found = try await schemas(in: endpoint, connection: connection)
        return found.isEmpty ? [nil] : found.map { $0 }
    }

    nonisolated private static func read(
        from plugin: any PluginDatabaseDriver,
        schema: String?
    ) async throws -> [ObjectCopySelection] {
        var found: [ObjectCopySelection] = []

        let tables = try await plugin.fetchTables(schema: schema)
        for table in tables where !CompareTableKindClassifier.isForeign(table) {
            found.append(ObjectCopySelection(
                kind: CompareTableKindClassifier.kind(of: table),
                name: table.name,
                schema: table.schema ?? schema
            ))
        }

        /// A driver that does not report routines or triggers answers with an empty list rather
        /// than an error, and one that fails is not a reason to offer no tables either.
        let routines = (try? await plugin.fetchRoutines(schema: schema)) ?? []
        for routine in routines {
            found.append(ObjectCopySelection(
                kind: routine.kind == .procedure ? .procedure : .function,
                name: routine.name,
                schema: routine.schema ?? schema,
                signature: routine.argumentSignature
            ))
        }

        let triggers = (try? await plugin.fetchAllTriggers(schema: schema)) ?? []
        for trigger in triggers {
            found.append(ObjectCopySelection(
                kind: .trigger,
                name: trigger.name,
                schema: trigger.schema ?? schema,
                owner: trigger.table
            ))
        }
        return found
    }

    /// The schemas a database-wide copy would have to cover, so the sheet can refuse rather than
    /// carry one schema's objects and call it the database.
    internal func schemas(
        in endpoint: DatabaseEndpoint,
        connection: DatabaseConnection
    ) async throws -> [String] {
        try await manager.ensureConnected(connection)
        return try await manager.withMetadataDriver(scope: endpoint.scope) { driver in
            guard let plugin = CompareMetadataService.pluginDriver(from: driver), plugin.supportsSchemas
            else { return [] }
            return try await plugin.fetchSchemas()
        }
    }

    /// The form the destination's `CREATE DATABASE` offers.
    ///
    /// Its absence is also the honest answer to "can this driver create a database at all": every
    /// driver that implements `createDatabase` publishes one, and the ones that inherit the
    /// protocol's throwing default publish nil. Keying Duplicate on `supportsDatabaseSwitching`
    /// instead offered it on DuckDB, Trino and Teradata, where it reached that default.
    internal func createDatabaseForm(
        for endpoint: DatabaseEndpoint,
        connection: DatabaseConnection
    ) async throws -> CreateDatabaseFormSpec? {
        try await manager.ensureConnected(connection)
        let scope = DatabaseScope(connectionId: endpoint.connectionId, database: "", schema: nil)
        return try await manager.withMetadataDriver(scope: scope) { driver in
            try await driver.createDatabaseFormSpec()
        }
    }
}
