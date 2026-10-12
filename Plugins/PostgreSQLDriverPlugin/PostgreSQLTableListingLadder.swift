//
//  PostgreSQLTableListingLadder.swift
//  PostgreSQLDriverPlugin
//

import Foundation

enum PostgreSQLTableListingSource: Sendable, Equatable {
    case systemCatalogs
    case informationSchema
}

struct PostgreSQLTableListingAttempt: Sendable, Equatable {
    let source: PostgreSQLTableListingSource
    let includeComments: Bool
    let includePartitionAwareness: Bool

    var label: String {
        "source=\(source) comments=\(includeComments) partitions=\(includePartitionAwareness)"
    }
}

/// A PostgreSQL-compatible engine may lack a catalog, function, column or type the listing names, so
/// each rung drops more of them. Partition awareness degrades last, because it changes which rows
/// come back rather than which columns.
enum PostgreSQLTableListingLadder {
    static let undefinedTableSQLState = "42P01"
    static let undefinedFunctionSQLState = "42883"
    static let undefinedColumnSQLState = "42703"
    static let undefinedObjectSQLState = "42704"

    static let degradableAttempts: [PostgreSQLTableListingAttempt] = [
        PostgreSQLTableListingAttempt(source: .systemCatalogs, includeComments: true, includePartitionAwareness: true),
        PostgreSQLTableListingAttempt(source: .systemCatalogs, includeComments: false, includePartitionAwareness: true)
    ]

    static let leastCapableAttempt = PostgreSQLTableListingAttempt(
        source: .informationSchema, includeComments: false, includePartitionAwareness: false
    )

    static func query(
        for attempt: PostgreSQLTableListingAttempt,
        in scope: PostgreSQLTableListingScope,
        includeMaterializedViews: Bool,
        includeForeignTables: Bool
    ) -> String {
        switch attempt.source {
        case .systemCatalogs:
            return PostgreSQLTableListing.query(
                in: scope,
                includeMaterializedViews: includeMaterializedViews,
                includeForeignTables: includeForeignTables,
                includeComments: attempt.includeComments,
                includePartitionAwareness: attempt.includePartitionAwareness
            )
        case .informationSchema:
            return PostgreSQLTableListing.informationSchemaQuery(in: scope)
        }
    }

    /// The catalog form names `relowner` and `regclass`, which a wire-compatible engine can lack: it
    /// reaches the information_schema rung instead of failing the sidebar.
    static func isDegradable(sqlState: String?) -> Bool {
        guard let sqlState else { return false }
        return [undefinedTableSQLState, undefinedFunctionSQLState, undefinedColumnSQLState, undefinedObjectSQLState]
            .contains(sqlState)
    }
}
