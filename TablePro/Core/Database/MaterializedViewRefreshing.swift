//
//  MaterializedViewRefreshing.swift
//  TablePro
//
//  Recomputes a materialized view's rows through the execution gate.
//

import Combine
import Foundation
import TableProPluginKit

@MainActor
enum MaterializedViewRefreshing {
    /// Nil where the engine has no refresh that leaves readers alone, so the prompt offers no
    /// option at all rather than one that is always off.
    static func concurrentRefreshAvailability(
        of target: DatabaseObjectTarget
    ) async throws -> PluginConcurrentRefreshAvailability? {
        let name = target.name
        let schema = target.schema
        return try await DatabaseManager.shared.withMetadataDriver(scope: target.scope) { driver in
            try await driver.concurrentRefreshAvailability(materializedView: name, schema: schema)
        }
    }

    /// Runs on its own connection wherever the engine has one to give, never inside a transaction a
    /// query tab left open: a plain refresh holds an exclusive lock on the view until the
    /// transaction it runs in ends, which inside the user's would be until they committed.
    static func refresh(
        _ target: DatabaseObjectTarget,
        concurrently: Bool,
        connection: DatabaseConnection,
        gate: any ExecutionGate = ExecutionGateProvider.shared
    ) async throws {
        guard let driver = DatabaseManager.shared.driver(for: connection.id) else {
            throw DatabaseObjectCommandError.notConnected
        }
        guard let sql = driver.refreshMaterializedViewStatement(
            name: target.name,
            schema: target.schema,
            concurrently: concurrently
        ) else {
            throw DatabaseObjectCommandError.unsupported
        }
        try await DatabaseObjectCommandRunner.run(
            sql,
            on: target,
            connection: connection,
            kind: .maintenance,
            operationDescription: String(localized: "Refresh Materialized View"),
            gate: gate
        )
        AppCommands.shared.objectChanged.send(target.change(.rows))
    }
}
