//
//  LibPQReadOnlyTransaction+Statement.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

extension LibPQReadOnlyTransaction {
    struct Scope: Sendable, Equatable {
        let reason: Reason
        let runsInOpenTransaction: Bool
    }

    static var sessionNotIdle: LibPQPluginError {
        LibPQPluginError(message: notIdleMessage(.externalClients), sqlState: nil, detail: nil)
    }

    static var safeModeSessionNotIdle: LibPQPluginError {
        LibPQPluginError(message: notIdleMessage(.safeMode), sqlState: nil, detail: nil)
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

    static func scope(for context: PluginStatementContext, capabilities: PluginCapabilities) -> Scope? {
        reason(for: context, capabilities: capabilities).map { reason in
            Scope(reason: reason, runsInOpenTransaction: context.enforcesReadOnly && !context.callsUnlistedFunction)
        }
    }

    static func run<Result>(
        state: PluginSessionTransactionState,
        scope: Scope,
        send: (String) throws -> Void,
        statement: () throws -> Result
    ) throws -> Result {
        try run(
            state: state,
            reason: scope.reason,
            runsInOpenTransaction: scope.runsInOpenTransaction,
            send: send,
            statement: statement
        )
    }

    // Inside an open transaction the wrap would make the user's own transaction read-only, so a session holding one runs
    // a statement the host checked for unlisted function calls in it as it is.
    static func run<Result>(
        state: PluginSessionTransactionState,
        reason: Reason,
        runsInOpenTransaction: Bool = false,
        send: (String) throws -> Void,
        statement: () throws -> Result
    ) throws -> Result {
        guard state == .idle else {
            guard runsInOpenTransaction else { throw notIdle(reason) }
            return try statement()
        }
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
        guard let failure = error as? LibPQPluginError, isRefusal(sqlState: failure.sqlState) else { return error }
        return LibPQPluginError(message: refusalMessage(reason), sqlState: failure.sqlState, detail: failure.message)
    }
}
