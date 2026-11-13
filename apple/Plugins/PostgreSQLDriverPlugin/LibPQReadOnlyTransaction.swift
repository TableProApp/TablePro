//
//  LibPQReadOnlyTransaction.swift
//  PostgreSQLDriverPlugin
//

import Foundation

// The iOS PostgreSQL driver compiles this file too; the plugin's statement handling is in
// LibPQReadOnlyTransaction+Statement.swift.
nonisolated internal enum LibPQReadOnlyTransaction {
    // Who asked for the read-only mode, which is what a refusal names.
    enum Reason: Sendable, Equatable {
        case externalClients
        case safeMode
    }

    // `SELECT 1` takes the snapshot, after which the server refuses any statement that makes the transaction writable.
    static let begin = "START TRANSACTION READ ONLY; SELECT 1"
    // Not COMMIT, so a `SET`, `set_config` or `NOTIFY` the statement ran is undone too.
    static let end = "ROLLBACK"

    // `cannot execute ... in a read-only transaction`, and `cannot run inside a transaction block` for VACUUM.
    static let refusalStates: Set<String> = ["25006", "25001"]

    static func isRefusal(sqlState: String?) -> Bool {
        guard let sqlState else { return false }
        return refusalStates.contains(sqlState)
    }

    static func notIdleMessage(_ reason: Reason) -> String {
        switch reason {
        case .externalClients:
            String(localized: "This connection has a transaction open. Commit or roll it back in TablePro, then try again.")
        // Read-Only offers no Commit, so the way out is a rollback.
        case .safeMode:
            String(
                localized: "Safe Mode is set to Read-Only for this connection, and it has a transaction open. Roll it back, then try again."
            )
        }
    }

    static func refusalMessage(_ reason: Reason) -> String {
        switch reason {
        case .externalClients:
            String(localized: "This connection is read only for external clients, and the database refused the statement.")
        case .safeMode:
            String(localized: "Safe Mode is set to Read-Only for this connection, and the database refused the statement.")
        }
    }
}
