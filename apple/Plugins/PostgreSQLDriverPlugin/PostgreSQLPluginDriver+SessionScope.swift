//
//  PostgreSQLPluginDriver+SessionScope.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

// On this class rather than `LibPQBackedDriver`, so CockroachDB and Redshift keep PluginKit's nil scopes.
internal extension PostgreSQLPluginDriver {
    private var sessionScope: PostgreSQLSessionScope {
        PostgreSQLSessionScope(
            setting: { [core] statement, requiresIdleSession in
                try await core.executeSessionSetting(statement, requiresIdleSession: requiresIdleSession)
            },
            transactionState: { [core] in await core.sessionTransactionState() }
        )
    }

    func openSessionScope(for purpose: PluginSessionPurpose) async throws -> PluginSessionScope? {
        try await sessionScope.open(for: purpose)
    }

    func closeSessionScope(_ scope: PluginSessionScope) async throws {
        try await sessionScope.close(scope)
    }
}
