//
//  MySQLPluginDriver+SessionScope.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

internal extension MySQLPluginDriver {
    func openSessionScope(for purpose: PluginSessionPurpose) async throws -> PluginSessionScope? {
        try await exportCatalog.openSessionScope(for: purpose, hooks: sessionHooks)
    }

    func closeSessionScope(_ scope: PluginSessionScope) async throws {
        try await exportCatalog.closeSessionScope(scope, hooks: sessionHooks)
    }

    private var sessionHooks: MySQLExportCatalog.SessionHooks {
        MySQLExportCatalog.SessionHooks(
            runSetup: { [self] in try await self.executeSetup($0) },
            transactionState: { [self] in await self.sessionTransactionState() },
            adjustFootprint: { [self] change in self.adjustFootprint(change) }
        )
    }
}
