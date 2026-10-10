//
//  CatalogTableListing.swift
//  TablePro
//

import Foundation
import os

/// Every read goes through the one scope the caller names: a scope per schema would open a pooled
/// connection per schema.
@MainActor
internal enum CatalogTableListing {
    internal enum SchemaSelection: Hashable, Sendable {
        case all
        case only(Set<String>)

        internal func intersection(_ other: SchemaSelection) -> SchemaSelection {
            switch (self, other) {
            case (.all, _):
                return other
            case (_, .all):
                return self
            case (.only(let kept), .only(let otherKept)):
                return .only(kept.intersection(otherKept))
            }
        }
    }

    /// A schema whose own read failed is named rather than dropped. Read as empty, it would tell a
    /// search that nothing in it matches, and hide exactly the table the search was looking for.
    internal struct Result: Sendable, Equatable {
        internal let tables: [TableInfo]
        internal let unlistedSchemas: Set<String>

        /// A schema the retry listed replaces what was known of it; one it still could not list
        /// keeps its rows and stays unlisted.
        internal func merging(_ retry: Result, retried schemas: Set<String>) -> Result {
            let listedNow = schemas.subtracting(retry.unlistedSchemas)
            let kept = tables.filter { table in
                guard let schema = table.schema else { return true }
                return !listedNow.contains(schema)
            }
            return Result(
                tables: kept + retry.tables,
                unlistedSchemas: unlistedSchemas.subtracting(schemas).union(retry.unlistedSchemas)
            )
        }

        /// A refresh that could not read a schema says nothing new about it, so the earlier rows
        /// for that schema are carried over rather than dropped.
        internal func keepingRows(from previous: Result?) -> Result {
            guard let previous, !unlistedSchemas.isEmpty else { return self }
            let carried = previous.tables.filter { table in
                guard let schema = table.schema else { return false }
                return unlistedSchemas.contains(schema)
            }
            return Result(tables: tables + carried, unlistedSchemas: unlistedSchemas)
        }

        internal func restricted(to selection: SchemaSelection) -> Result {
            guard case .only(let kept) = selection else { return self }
            return Result(
                tables: tables.filter { table in table.schema.map { kept.contains($0) } ?? true },
                unlistedSchemas: unlistedSchemas.intersection(kept)
            )
        }
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "CatalogTableListing")

    internal static func tables(
        in scope: DatabaseScope,
        selection: SchemaSelection = .all,
        excludingSchemas excluded: Set<String>,
        metadata: ScopedMetadataProviding = DatabaseManager.shared
    ) async throws -> Result {
        switch selection {
        case .all:
            return try await tablesInEverySchema(in: scope, excludingSchemas: excluded, metadata: metadata)
        case .only(let kept):
            return try await tables(inKeptSchemas: kept.subtracting(excluded), scope: scope, metadata: metadata)
        }
    }

    private static func tablesInEverySchema(
        in scope: DatabaseScope,
        excludingSchemas excluded: Set<String>,
        metadata: ScopedMetadataProviding
    ) async throws -> Result {
        let listed = try await metadata.withMetadataDriver(scope: scope, workload: .bulk) { driver in
            try await driver.fetchTablesInAllSchemas()
        }
        if let listed {
            let tables = listed.filter { table in
                guard let schema = table.schema else { return true }
                return !excluded.contains(schema)
            }
            return Result(tables: tables, unlistedSchemas: [])
        }
        let schemas = try await metadata.withMetadataDriver(scope: scope, workload: .bulk) { driver in
            try await driver.fetchSchemas()
        }
        return try await tables(inSchemas: schemas.filter { !excluded.contains($0) }, scope: scope, metadata: metadata)
    }

    /// The kept set is the schema list, so no schema list is read. An engine without a set read is
    /// asked schema by schema, never through the all-schema listing, so a hidden schema is never read.
    private static func tables(
        inKeptSchemas schemas: Set<String>,
        scope: DatabaseScope,
        metadata: ScopedMetadataProviding
    ) async throws -> Result {
        guard !schemas.isEmpty else { return Result(tables: [], unlistedSchemas: []) }
        let names = schemas.sorted()
        let listed = try await metadata.withMetadataDriver(scope: scope, workload: .bulk) { driver in
            try await driver.fetchTables(inSchemas: names)
        }
        if let listed {
            let tables = listed.filter { table in table.schema.map { schemas.contains($0) } ?? true }
            return Result(tables: tables, unlistedSchemas: [])
        }
        return try await tables(inSchemas: names, scope: scope, metadata: metadata)
    }

    /// One lease per schema, so a sidebar expansion queued behind this waits for one schema, not all.
    /// A lost connection fails every schema alike, so it fails the whole read rather than listing nothing.
    internal static func tables(
        inSchemas schemas: [String],
        scope: DatabaseScope,
        metadata: ScopedMetadataProviding = DatabaseManager.shared
    ) async throws -> Result {
        var tables: [TableInfo] = []
        var unlisted: Set<String> = []
        var lastError: Error?
        for schema in schemas {
            try Task.checkCancellation()
            do {
                tables += try await metadata.withMetadataDriver(scope: scope, workload: .bulk) { driver in
                    try await driver.fetchTables(schema: schema)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as DatabaseError {
                throw error
            } catch {
                logger.warning(
                    "[catalog] schema not listed schema=\(schema, privacy: .private(mask: .hash)) error=\(error.publicLogShape, privacy: .public)"
                )
                unlisted.insert(schema)
                lastError = error
            }
        }
        if let lastError, !schemas.isEmpty, unlisted.count == schemas.count {
            throw lastError
        }
        return Result(tables: tables, unlistedSchemas: unlisted)
    }
}
