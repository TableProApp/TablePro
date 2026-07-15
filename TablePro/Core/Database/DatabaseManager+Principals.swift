import Combine
import Foundation
import os
import TableProPluginKit

extension DatabaseManager {
    func principalDriver(
        for connectionId: UUID
    ) -> (any PluginDatabaseDriver & PluginPrincipalManagement)? {
        guard let adapter = driver(for: connectionId) as? PluginDriverAdapter else { return nil }
        return adapter.schemaPluginDriver as? any PluginDatabaseDriver & PluginPrincipalManagement
    }

    func executePrincipalChanges(
        changes: [PrincipalChange],
        databaseType: DatabaseType,
        connectionId: UUID
    ) async throws {
        guard let driver = driver(for: connectionId) else {
            throw DatabaseError.notConnected
        }
        guard let principalDriver = principalDriver(for: connectionId) else {
            throw DatabaseError.unsupportedOperation
        }

        try await trackOperation(sessionId: connectionId) {
            let generator = PrincipalStatementGenerator(driver: principalDriver)
            let statements = try generator.generate(changes: changes)
            guard !statements.isEmpty else { return }

            let combinedSQL = statements.map(\.sql).joined(separator: "\n")
            let kind: OperationKind = statements.contains(where: \.isDestructive)
                ? .destructiveQuery
                : .schemaMutation

            let authorization = await ExecutionGateProvider.shared.authorize(
                OperationRequest(
                    connectionId: connectionId,
                    databaseType: databaseType,
                    sql: combinedSQL,
                    kind: kind,
                    caller: .userInterface,
                    capabilities: .interactiveUser,
                    operationDescription: String(localized: "Apply User and Role Changes")
                )
            )
            guard case .authorized = authorization else {
                throw DatabaseError.queryFailed(
                    authorization.deniedReason
                        ?? String(localized: "User and role changes were not authorized")
                )
            }

            try await runPrincipalStatements(
                statements,
                driver: driver,
                rollsBack: principalDriver.rollsBackPrincipalStatements,
                connectionId: connectionId
            )
        }
    }

    private func runPrincipalStatements(
        _ statements: [SchemaStatement],
        driver: any DatabaseDriver,
        rollsBack: Bool,
        connectionId: UUID
    ) async throws {
        let useTransaction = driver.supportsTransactions && rollsBack
        if useTransaction {
            try await driver.beginTransaction()
        }

        var appliedCount = 0
        do {
            for statement in statements {
                _ = try await driver.execute(query: statement.sql)
                appliedCount += 1
            }
            if useTransaction {
                try await driver.commitTransaction()
            }
        } catch {
            var rolledBack = false
            if useTransaction {
                do {
                    try await driver.rollbackTransaction()
                    rolledBack = true
                } catch {
                    Self.logger.error(
                        "Rollback failed after principal change error: \(error.localizedDescription)"
                    )
                }
            }
            throw PrincipalApplyError(
                failedStatement: statements[min(appliedCount, statements.count - 1)],
                appliedCount: appliedCount,
                totalCount: statements.count,
                rolledBack: rolledBack,
                underlying: error
            )
        }

        let databaseName = activeSessions[connectionId]?.activeDatabase ?? ""
        // Query history is stored unencrypted on disk. A CREATE USER / ALTER USER statement embeds
        // the plaintext password, so it is never recorded.
        for statement in statements where !statement.carriesCredentials {
            QueryHistoryManager.shared.recordQuery(
                query: statement.sql.hasSuffix(";") ? statement.sql : statement.sql + ";",
                connectionId: connectionId,
                databaseName: databaseName,
                executionTime: 0,
                rowCount: 0,
                wasSuccessful: true
            )
        }

        await MainActor.run {
            AppCommands.shared.refreshPrincipals.send(connectionId)
        }
    }
}
