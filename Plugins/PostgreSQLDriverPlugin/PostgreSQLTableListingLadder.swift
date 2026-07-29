//
//  PostgreSQLTableListingLadder.swift
//  PostgreSQLDriverPlugin
//
//  Ordered fallbacks for the table listing, extracted so the ordering can be
//  exercised by unit tests via TableProTests/PluginTestSources.
//

import Foundation

struct PostgreSQLTableListingAttempt: Sendable, Equatable {
    let includeOptionalCatalogs: Bool
    let includeComments: Bool
    let includePartitionAwareness: Bool

    var label: String {
        "catalogs=\(includeOptionalCatalogs) comments=\(includeComments) partitions=\(includePartitionAwareness)"
    }
}

/// A PostgreSQL-compatible engine may lack the optional catalogs the listing
/// reads, so each rung drops one more of them and retries. Partition awareness
/// degrades last: it is the only rung that changes which rows come back rather
/// than which columns, so a partition-free listing is worth every other
/// fallback first. A single flat `catch` cannot express this, because the same
/// SQLSTATE means a different missing catalog at each rung.
enum PostgreSQLTableListingLadder {
    static let undefinedTableSQLState = "42P01"
    static let undefinedFunctionSQLState = "42883"

    static let degradableAttempts: [PostgreSQLTableListingAttempt] = [
        PostgreSQLTableListingAttempt(
            includeOptionalCatalogs: true, includeComments: true, includePartitionAwareness: true
        ),
        PostgreSQLTableListingAttempt(
            includeOptionalCatalogs: false, includeComments: true, includePartitionAwareness: true
        ),
        PostgreSQLTableListingAttempt(
            includeOptionalCatalogs: false, includeComments: false, includePartitionAwareness: true
        )
    ]

    static let leastCapableAttempt = PostgreSQLTableListingAttempt(
        includeOptionalCatalogs: false, includeComments: false, includePartitionAwareness: false
    )

    static func isDegradable(sqlState: String?) -> Bool {
        guard let sqlState else { return false }
        return sqlState == undefinedTableSQLState || sqlState == undefinedFunctionSQLState
    }
}
