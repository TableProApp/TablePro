//
//  ScriptQueryRunner.swift
//  TablePro
//

import Foundation

/// Runs one statement for a script, with every gate a script has to clear.
///
/// A script is an external caller with no token, so the gates it clears are the connection's own:
/// **External Clients** decides whether it may write at all, and Safe Mode decides whether a person
/// has to see the statement first. Both are applied by `ExternalStatementGate`, which is the same
/// code the MCP tools run, so the two surfaces cannot drift apart on what a connection allows.
///
/// The confirmation names the app that sent the Apple event, taken from the sender pid the kernel
/// stamps on it. A person approving a `DELETE` deserves to know whether it came from a Shortcut they
/// just ran or from something they forgot was open.
internal enum ScriptQueryRunner {
    /// Deliberately not the MCP settings. That row cap and that timeout belong to the MCP server's
    /// own configuration, and reading them here would make a script's behaviour change when the user
    /// tuned an unrelated surface. A script that wants different limits passes them per command.
    internal static let defaultRowLimit = 500
    internal static let maximumRowLimit = 10_000
    internal static let defaultTimeoutSeconds = 30
    internal static let maximumTimeoutSeconds = 600

    internal struct Request: Sendable {
        internal let sql: String
        internal let connectionId: UUID
        internal let database: String?
        internal let schema: String?
        internal let rowLimit: Int?
        internal let timeoutSeconds: Int?
        internal let client: String?
    }

    internal struct Outcome: Sendable {
        internal let result: QueryResult
        internal let executionTimeMs: Double
    }

    internal static func run(
        _ request: Request,
        bridge: DatabaseAccessBridge,
        history: QueryHistoryRecording = QueryHistoryManager.shared
    ) async throws -> Outcome {
        let snapshot = try await MainActor.run { () throws -> ExternalConnectionPolicySnapshot in
            /// Asked here as well as at the object model, so the rule holds even if some later
            /// command hands this a connection id it did not resolve through `connections()`.
            guard ScriptingSnapshot.isVisibleToScripts(connectionId: request.connectionId) else {
                throw ScriptingError.noSuchObject(
                    String(localized: "No saved connection has that id.")
                )
            }
            return try ExternalConnectionPolicySnapshot.resolve(connectionId: request.connectionId)
        }

        /// Classified before anything connects, so a statement the connection refuses never opens a
        /// session and never asks the user for a password.
        try ExternalStatementGate.classify(
            ExternalStatementGate.Statement(
                sql: request.sql,
                connectionId: request.connectionId,
                databaseType: snapshot.databaseType,
                externalAccess: snapshot.externalAccess,
                allowsDestructive: true
            )
        )

        /// Before anything connects. `resolveScope` calls `ensureConnected`, which runs the
        /// connection's pre-connect shell script, and a script asking for rows is not consent to run
        /// that code.
        try await ScriptConnectGate.authorizeConnect(connectionId: request.connectionId)

        let scope = try await bridge.resolveScope(
            connectionId: request.connectionId,
            database: request.database,
            schema: request.schema
        )

        try await ExternalStatementGate.authorizeExecution(
            sql: request.sql,
            connectionId: request.connectionId,
            databaseType: snapshot.databaseType,
            caller: .appleScript(client: request.client),
            capabilities: [.mayWrite, .mayRunDestructive],
            operationDescription: confirmationTitle(client: request.client, connection: snapshot.connectionName)
        )

        let rowLimit = (request.rowLimit ?? defaultRowLimit).clamped(to: 1...maximumRowLimit)
        let timeout = (request.timeoutSeconds ?? defaultTimeoutSeconds).clamped(to: 1...maximumTimeoutSeconds)
        let startedAt = ContinuousClock.Instant.now
        let started = Date()

        do {
            let outcome = try await bridge.runStatement(
                scope: scope,
                query: request.sql,
                maxRows: rowLimit,
                timeoutSeconds: timeout,
                cancellation: nil
            )
            await record(
                request,
                scope: scope,
                databaseType: snapshot.databaseType,
                elapsed: Date().timeIntervalSince(started),
                rowCount: outcome.result.rows.count,
                error: nil,
                history: history
            )
            await report(
                .succeeded(
                    OperationSummary(
                        rowsReturned: outcome.result.rows.count,
                        rowsAffected: outcome.result.rowsAffected
                    )
                ),
                request: request,
                scope: scope,
                startedAt: startedAt
            )
            return Outcome(result: outcome.result, executionTimeMs: outcome.executionTimeMs)
        } catch {
            let message = ScriptingError.from(error, secrets: snapshot.redactionSecrets).errorDescription
            await record(
                request,
                scope: scope,
                databaseType: snapshot.databaseType,
                elapsed: Date().timeIntervalSince(started),
                rowCount: 0,
                error: message,
                history: history
            )
            await report(
                .failed(reason: message ?? String(localized: "The query failed.")),
                request: request,
                scope: scope,
                startedAt: startedAt
            )
            throw ScriptingError.from(error, secrets: snapshot.redactionSecrets)
        }
    }

    private static func confirmationTitle(client: String?, connection: String) -> String {
        guard let client, !client.isEmpty else {
            return String(format: String(localized: "A script wants to run a query on \"%@\""), connection)
        }
        return String(
            format: String(localized: "%1$@ wants to run a query on \"%2$@\""),
            client,
            connection
        )
    }

    /// Scripted statements go into the history drawer under their own source, so the person whose
    /// database it is can see what ran without the app being open at the time.
    private static func record(
        _ request: Request,
        scope: DatabaseScope,
        databaseType: DatabaseType,
        elapsed: TimeInterval,
        rowCount: Int,
        error: String?,
        history: QueryHistoryRecording
    ) async {
        await history.record(
            QueryHistoryRecordRequest(
                query: request.sql,
                connectionId: request.connectionId,
                databaseName: scope.database,
                databaseType: databaseType,
                schemaName: scope.schema,
                source: .script,
                executionTime: elapsed,
                rowCount: rowCount,
                wasSuccessful: error == nil,
                errorMessage: error
            )
        )
    }

    /// A scripted query has no tab and no window, so its completion belongs to the connection, the
    /// same as an MCP query's does.
    @MainActor
    private static func report(
        _ outcome: OperationOutcome,
        request: Request,
        scope: DatabaseScope,
        startedAt: ContinuousClock.Instant
    ) {
        guard let connection = ConnectionStorage.shared.loadConnections()
            .first(where: { $0.id == request.connectionId })
        else {
            return
        }
        OperationCompletionReporter.shared.report(
            OperationCompletion(
                kind: .scriptQuery,
                owner: .connection(request.connectionId),
                connectionId: request.connectionId,
                connectionName: connection.name,
                databaseName: scope.database,
                elapsed: startedAt.duration(to: .now),
                outcome: outcome
            )
        )
    }
}
