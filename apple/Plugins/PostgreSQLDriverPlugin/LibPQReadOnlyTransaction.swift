//
//  LibPQReadOnlyTransaction.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

internal enum LibPQReadOnlyTransaction {
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

    static var sessionNotIdle: LibPQPluginError {
        LibPQPluginError(
            message: String(
                localized: "This connection has a transaction open. Commit or roll it back in TablePro, then try again."
            ),
            sqlState: nil,
            detail: nil
        )
    }

    // Read-Only offers no Commit, so the way out is a rollback.
    static var safeModeSessionNotIdle: LibPQPluginError {
        LibPQPluginError(
            message: String(
                localized: "Safe Mode is set to Read-Only for this connection, and it has a transaction open. Roll it back, then try again."
            ),
            sqlState: nil,
            detail: nil
        )
    }

    static func reason(for context: PluginStatementContext, capabilities: PluginCapabilities) -> Reason? {
        if context.readOnly, context.origin == .external, capabilities.contains(.readOnlyStatements) {
            return .externalClients
        }
        if context.enforcesReadOnly, capabilities.contains(.enforcesReadOnlyMode) {
            return .safeMode
        }
        return nil
    }

    static func applies(to context: PluginStatementContext, capabilities: PluginCapabilities) -> Bool {
        reason(for: context, capabilities: capabilities) != nil
    }

    // Inside an open transaction the wrap would make the user's own transaction read-only.
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

    static func notIdle(_ reason: Reason) -> LibPQPluginError {
        switch reason {
        case .externalClients: sessionNotIdle
        case .safeMode: safeModeSessionNotIdle
        }
    }

    static func refusal(from error: Error, reason: Reason) -> Error {
        guard let failure = error as? LibPQPluginError,
              let sqlState = failure.sqlState,
              refusalStates.contains(sqlState)
        else { return error }
        return LibPQPluginError(message: refusalMessage(reason), sqlState: sqlState, detail: failure.message)
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
