//
//  CatalogTableListing.swift
//  TablePro
//

import Foundation
import os

/// Every table one database holds, across all of its schemas.
///
/// An engine that answers `fetchTablesInAllSchemas()` is asked once. Any other is asked schema by
/// schema, and each of those reads queues on the metadata lane by itself, so a sidebar expansion
/// that arrives in the middle waits behind one schema rather than behind all of them. Every read
/// goes through the one scope the caller names: a scope per schema would open a pooled connection
/// per schema.
@MainActor
internal enum CatalogTableListing {
    /// A schema whose own read failed is named rather than dropped. Read as empty, it would tell a
    /// search that nothing in it matches, and hide exactly the table the search was looking for.
    internal struct Result: Sendable, Equatable {
        internal let tables: [TableInfo]
        internal let unlistedSchemas: Set<String>

        /// This listing with another read of some of its unlisted schemas folded in. A schema the
        /// read listed replaces what was known of it; one it still could not list keeps its rows
        /// and stays unlisted.
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

        /// A refresh that could not read a schema says nothing new about it, so the rows an earlier
        /// listing had for that schema are carried over rather than dropped.
        internal func keepingRows(from previous: Result?) -> Result {
            guard let previous, !unlistedSchemas.isEmpty else { return self }
            let carried = previous.tables.filter { table in
                guard let schema = table.schema else { return false }
                return unlistedSchemas.contains(schema)
            }
            return Result(tables: tables + carried, unlistedSchemas: unlistedSchemas)
        }
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "CatalogTableListing")

    internal static func tables(
        in scope: DatabaseScope,
        excludingSchemas excluded: Set<String>,
        metadata: ScopedMetadataProviding = DatabaseManager.shared
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

    /// The named schemas one by one, which is also how a listing asks again for the schemas it
    /// could not read the first time.
    ///
    /// Only a failure that belongs to one schema is recorded against it. A lost connection fails
    /// every schema the same way, and recording that as a listing of nothing would read as a
    /// database with no tables, so it fails the whole read instead, as does every schema failing.
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
