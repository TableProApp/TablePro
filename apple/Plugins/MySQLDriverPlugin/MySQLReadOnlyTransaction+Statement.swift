//
//  MySQLReadOnlyTransaction+Statement.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

extension MySQLReadOnlyTransaction {
    // The session state is read on the statement's own queue, so nothing queued behind it can open a transaction first.
    struct Scope: Sendable {
        let reason: Reason
        let sessionState: @Sendable (Bool) -> PluginSessionTransactionState
    }

    static var sessionNotIdle: MariaDBPluginError {
        MariaDBPluginError(code: 0, message: notIdleMessage(.externalClients), sqlState: nil)
    }

    static var safeModeSessionNotIdle: MariaDBPluginError {
        MariaDBPluginError(code: 0, message: notIdleMessage(.safeMode), sqlState: nil)
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
}
