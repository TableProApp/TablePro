//
//  MySQLReadOnlyTransaction.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

internal enum MySQLReadOnlyTransaction {
    // Not the `/*!50605 ... */` spelling: a server older than 5.6.5 would run that as a plain read-write transaction.
    static let begin = "START TRANSACTION READ ONLY"
    static let end = "ROLLBACK"

    // ER_CANT_EXECUTE_IN_READ_ONLY_TRANSACTION.
    static let refusalCode: UInt32 = 1_792

    static var sessionNotIdle: MariaDBPluginError {
        MariaDBPluginError(
            code: 0,
            message: String(
                localized: "This connection has a transaction open. Commit or roll it back in TablePro, then try again."
            ),
            sqlState: nil
        )
    }

    static func applies(to context: PluginStatementContext, flavor: MySQLServerFlavor) -> Bool {
        context.readOnly && context.origin == .external && flavor.enforcesReadOnlyTransactions
    }

    // `START TRANSACTION` would commit the user's open transaction and release their `LOCK TABLES`.
    static func run<Result>(
        state: PluginSessionTransactionState,
        send: (String) throws -> Void,
        statement: () throws -> Result
    ) throws -> Result {
        guard state == .idle else { throw sessionNotIdle }
        do {
            try send(begin)
        } catch {
            try? send(end)
            throw error
        }
        let result: Result
        do {
            result = try statement()
        } catch {
            try? send(end)
            throw refusal(from: error)
        }
        try send(end)
        return result
    }

    static func refusal(from error: Error) -> Error {
        guard let failure = error as? MariaDBPluginError, failure.code == refusalCode else { return error }
        return MariaDBPluginError(
            code: failure.code,
            message: String(
                localized: "This connection is read only for external clients, and the database refused the statement."
            ),
            sqlState: failure.sqlState
        )
    }
}
