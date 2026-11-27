//
//  MySQLReadOnlyTransaction.swift
//  MySQLDriverPlugin
//

import Foundation

// The iOS MySQL driver compiles this file too; the plugin's statement handling is in
// MySQLReadOnlyTransaction+Statement.swift.
nonisolated internal enum MySQLReadOnlyTransaction {
    // Who asked for the read-only mode, which is what a refusal names.
    enum Reason: Sendable, Equatable {
        case externalClients
        case safeMode
    }

    // Not the `/*!50605 ... */` spelling: a server older than 5.6.5 would run that as a plain read-write transaction.
    static let begin = "START TRANSACTION READ ONLY"
    static let end = "ROLLBACK"

    // ER_CANT_EXECUTE_IN_READ_ONLY_TRANSACTION.
    static let refusalCode: UInt32 = 1_792

    // MySQL 5.5.62 and MariaDB 5.5.64 answer `begin` with 1064 (measured), so an older server runs a read as it is.
    static func isAvailable(banner: String?, flavor: MySQLServerFlavor) -> Bool {
        flavor.enforcesReadOnlyTransactions && MySQLServerVersion.hasReadOnlyTransactions(banner: banner, flavor: flavor)
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
