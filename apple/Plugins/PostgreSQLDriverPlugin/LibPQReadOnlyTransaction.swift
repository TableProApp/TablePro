//
//  LibPQReadOnlyTransaction.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

internal enum LibPQReadOnlyTransaction {
    // `SELECT 1` takes the snapshot, after which the server refuses any statement that makes the transaction writable.
    static let begin = "START TRANSACTION READ ONLY; SELECT 1"
    // Not COMMIT, so a `SET`, `set_config` or `NOTIFY` the statement ran is undone too.
    static let end = "ROLLBACK"

    // `cannot execute ... in a read-only transaction`, and `cannot run inside a transaction block` for VACUUM.
    static let refusalStates: Set<String> = ["25006", "25001"]

    static var sessionNotIdle: LibPQPluginError {
        LibPQPluginError(
            message: String(
                localized: "This connection has a transaction open. Commit or roll it back in TablePro, then try again."
            ),
            sqlState: nil,
            detail: nil
        )
    }

    static func applies(to context: PluginStatementContext, capabilities: PluginCapabilities) -> Bool {
        context.readOnly && context.origin == .external && capabilities.contains(.readOnlyStatements)
    }

    // Inside an open transaction the wrap would make the user's own transaction read-only.
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
        guard let failure = error as? LibPQPluginError,
              let sqlState = failure.sqlState,
              refusalStates.contains(sqlState)
        else { return error }
        return LibPQPluginError(
            message: String(
                localized: "This connection is read only for external clients, and the database refused the statement."
            ),
            sqlState: sqlState,
            detail: failure.message
        )
    }
}
