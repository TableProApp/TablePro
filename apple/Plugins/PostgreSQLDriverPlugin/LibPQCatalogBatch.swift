//
//  LibPQCatalogBatch.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPostgreSQLCore

// Catalog reads as one simple Query: the server answers each statement in order and runs none after the first that
// fails. A `SET LOCAL` goes in only where a read needs another search path. Leading statements run before any pin.
nonisolated struct LibPQCatalogBatch: Equatable, Sendable {
    private static let separator = "\n;\n"

    let text: String
    let statementCount: Int
    // Where each read's answer sits among the Query's results.
    let readResultIndexes: [Int]

    init(leading: [String] = [], reads: [PostgreSQLCatalogRead], trailing: [String] = []) {
        var statements = leading
        var indexes: [Int] = []
        var currentPath: String?
        for read in reads {
            let path = Self.searchPathStatement(for: read)
            if path != currentPath {
                statements.append(path)
                currentPath = path
            }
            indexes.append(statements.count)
            statements.append(read.statement)
        }
        statements.append(contentsOf: trailing)
        text = statements.joined(separator: Self.separator)
        statementCount = statements.count
        readResultIndexes = indexes
    }

    private static func searchPathStatement(for read: PostgreSQLCatalogRead) -> String {
        let path = read.namesRelativeTo.map(PostgreSQLCatalogSearchPath.relative(to:)) ?? PostgreSQLCatalogSearchPath.pinned
        return path.trimmingCharacters(in: CharacterSet(charactersIn: "; "))
    }
}

// What a driver adds to the flight that reads the session's schema after sign-in.
nonisolated struct LibPQConnectPlan: Equatable, Sendable {
    let reads: [PostgreSQLCatalogRead]
    let statementTimeoutMilliseconds: Int?
    let stabilizesBrowseScans: Bool

    static func statementTimeout(milliseconds: Int) -> String {
        "SET statement_timeout = \(milliseconds)"
    }

    // Behind a pooler `PQbackendPID` is the pooler's own number, so the setting never lands on a server session other
    // clients share. The row it returns proves the session talks to a backend directly.
    static func browseScanSetting(backendProcessID: Int32) -> String {
        """
        SELECT pg_catalog.set_config('synchronize_seqscans', 'off', false) \
        WHERE pg_catalog.pg_backend_pid() OPERATOR(pg_catalog.=) \(backendProcessID)
        """
    }
}
