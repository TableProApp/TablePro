//
//  LibPQReadOnlyTransaction+Statement.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

extension LibPQReadOnlyTransaction {
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
        guard let failure = error as? LibPQPluginError, isRefusal(sqlState: failure.sqlState) else { return error }
        return LibPQPluginError(message: refusalMessage(reason), sqlState: failure.sqlState, detail: failure.message)
    }
}
