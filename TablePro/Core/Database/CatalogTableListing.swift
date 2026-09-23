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
        /// read listed moves across; one it still could not list stays unlisted.
        internal func merging(_ retry: Result, retried schemas: Set<String>) -> Result {
            let kept = tables.filter { table in
                guard let schema = table.schema else { return true }
                return !schemas.contains(schema)
            }
            return Result(
                tables: kept + retry.tables,
                unlistedSchemas: unlistedSchemas.subtracting(schemas).union(retry.unlistedSchemas)
            )
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
    internal static func tables(
        inSchemas schemas: [String],
        scope: DatabaseScope,
        metadata: ScopedMetadataProviding = DatabaseManager.shared
    ) async throws -> Result {
        var tables: [TableInfo] = []
        var unlisted: Set<String> = []
        for schema in schemas {
            try Task.checkCancellation()
            do {
                tables += try await metadata.withMetadataDriver(scope: scope, workload: .bulk) { driver in
                    try await driver.fetchTables(schema: schema)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.warning(
                    "[catalog] schema not listed schema=\(schema, privacy: .private(mask: .hash)) error=\(error.publicLogShape, privacy: .public)"
                )
                unlisted.insert(schema)
            }
        }
        return Result(tables: tables, unlistedSchemas: unlisted)
    }
}
