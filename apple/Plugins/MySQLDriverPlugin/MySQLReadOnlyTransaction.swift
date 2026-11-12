//
//  MySQLReadOnlyTransaction.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

internal enum MySQLReadOnlyTransaction {
    // Who asked for the read-only mode, which is what a refusal names.
    enum Reason: Sendable, Equatable {
        case externalClients
        case safeMode
    }

    // The session state is read on the statement's own queue, so nothing queued behind it can open a transaction first.
    struct Scope: Sendable {
        let reason: Reason
        let sessionState: @Sendable (Bool) -> PluginSessionTransactionState
    }

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

    // Read-Only offers no Commit, so the way out is a rollback.
    static var safeModeSessionNotIdle: MariaDBPluginError {
        MariaDBPluginError(
            code: 0,
            message: String(
                localized: "Safe Mode is set to Read-Only for this connection, and it has a transaction open. Roll it back, then try again."
            ),
            sqlState: nil
        )
    }

    static func reason(for context: PluginStatementContext, flavor: MySQLServerFlavor) -> Reason? {
        guard flavor.enforcesReadOnlyTransactions else { return nil }
        if context.readOnly, context.origin == .external { return .externalClients }
        if context.enforcesReadOnly { return .safeMode }
        return nil
    }

    static func applies(to context: PluginStatementContext, flavor: MySQLServerFlavor) -> Bool {
        reason(for: context, flavor: flavor) != nil
    }

    // `START TRANSACTION` would commit the user's open transaction and release their `LOCK TABLES`.
    static func run<Result>(
        state: PluginSessionTransactionState,
        reason: Reason,
        send: (String) throws -> Void,
        statement: () throws -> Result
    ) throws -> Result {
        guard state == .idle else { throw notIdle(reason) }
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
            throw refusal(from: error, reason: reason)
        }
        try send(end)
        return result
    }

    static func notIdle(_ reason: Reason) -> MariaDBPluginError {
        switch reason {
        case .externalClients: sessionNotIdle
        case .safeMode: safeModeSessionNotIdle
        }
    }

    static func refusal(from error: Error, reason: Reason) -> Error {
        guard let failure = error as? MariaDBPluginError, failure.code == refusalCode else { return error }
        return MariaDBPluginError(code: failure.code, message: refusalMessage(reason), sqlState: failure.sqlState)
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
