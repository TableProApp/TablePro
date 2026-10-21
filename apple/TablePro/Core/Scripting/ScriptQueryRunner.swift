//
//  ScriptQueryRunner.swift
//  TablePro
//

import Foundation

// One statement, or on SQL Server a whole script, from AppleScript or a Shortcuts action. Both clear the
// connection's own gates through `ExternalStatementGate`, the code MCP runs: External Clients, then Safe Mode.
internal enum ScriptQueryRunner {
    /// Deliberately not the MCP settings. That row cap and that timeout belong to the MCP server's
    /// own configuration, and reading them here would make a script's behaviour change when the user
    /// tuned an unrelated surface. A script that wants different limits passes them per command.
    internal static let defaultRowLimit = 500
    internal static let maximumRowLimit = 10_000
    internal static let defaultTimeoutSeconds = 30
    internal static let maximumTimeoutSeconds = 600

    internal enum Channel: Sendable, Equatable {
        case appleScript(client: String?)
        case shortcuts

        internal var caller: OperationCaller {
            switch self {
            case .appleScript(let client): .appleScript(client: client)
            case .shortcuts: .shortcuts
            }
        }

        internal var historySource: QueryHistorySource {
            switch self {
            case .appleScript: .script
            case .shortcuts: .shortcuts
            }
        }

        // AppleScript cannot address a Blocked connection, so it hears that none exists. A shortcut picked the
        // connection from a list before it was blocked, so it hears why it stopped.
        internal func refusal(for access: ExternalAccessLevel?) -> ScriptingError {
            switch (self, access) {
            case (.shortcuts, .some):
                return .refused(String(localized: "External access is disabled for this connection"))
            case (.shortcuts, nil):
                return .noSuchObject(String(localized: "That connection no longer exists in TablePro."))
            case (.appleScript, _):
                return .noSuchObject(String(localized: "No saved connection has that id."))
            }
        }

        fileprivate var clientName: String? {
            switch self {
            case .appleScript(let client): client
            case .shortcuts: String(localized: "Shortcuts")
            }
        }
    }

    internal struct Request: Sendable {
        internal let sql: String
        internal let connectionId: UUID
        internal let database: String?
        internal let schema: String?
        internal let rowLimit: Int?
        internal let timeoutSeconds: Int?
        internal let channel: Channel
    }

    /// What a script may ask of the execution gate: to write, and to drop once a person confirms it. It is never
    /// pre-cleared, since no external caller gets to say on its own that a person already agreed. On an engine that
    /// takes scripts it may also run several statements in one call.
    internal static func capabilities(on databaseType: DatabaseType) -> CallerCapabilities {
        ExternalStatementGate.capabilities([.mayWrite, .mayRunDestructive], takingScriptsOn: databaseType)
    }

    internal static func run(
        _ request: Request,
        bridge: DatabaseAccessBridge,
        history: QueryHistoryRecording = QueryHistoryManager.shared,
        gate: any ExecutionGate = ExecutionGateProvider.shared
    ) async throws -> DatabaseAccessBridge.ScriptOutcome {
        let snapshot = try await MainActor.run { () throws -> ExternalConnectionPolicySnapshot in
            try visibleSnapshot(connectionId: request.connectionId, channel: request.channel)
        }

        let capabilities = Self.capabilities(on: snapshot.databaseType)

        /// Classified before anything connects, so a statement the connection refuses never opens a
        /// session and never asks the user for a password.
        try ExternalStatementGate.classify(
            ExternalStatementGate.Statement(
                sql: request.sql,
                connectionId: request.connectionId,
                databaseType: snapshot.databaseType,
                externalAccess: snapshot.externalAccess,
                loadsExtensions: snapshot.loadsExtensions,
                allowsDestructive: true,
                allowsMultiStatement: capabilities.contains(.mayRunMultiStatement)
            )
        )

        /// Before anything connects: a script asking for rows is not consent to load extensions.
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
            caller: request.channel.caller,
            capabilities: capabilities,
            operationDescription: confirmationTitle(
                client: request.channel.clientName,
                connection: snapshot.connectionName
            ),
            gate: gate
        )

        let rowLimit = (request.rowLimit ?? defaultRowLimit).clamped(to: 1...maximumRowLimit)
        let timeout = (request.timeoutSeconds ?? defaultTimeoutSeconds).clamped(to: 1...maximumTimeoutSeconds)
        let startedAt = ContinuousClock.Instant.now
        let started = Date()

        do {
            let outcome = try await bridge.runScript(
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
                rowCount: outcome.rowsReturned,
                error: nil,
                history: history
            )
            await report(
                .succeeded(
                    OperationSummary(
                        rowsReturned: outcome.rowsReturned,
                        rowsAffected: outcome.primary.rowsAffected
                    )
                ),
                request: request,
                scope: scope,
                startedAt: startedAt
            )
            return outcome
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

    // Asked here as well as at each caller's own listing, so the rule holds for a connection id that did not come
    // from one.
    @MainActor
    internal static func visibleSnapshot(
        connectionId: UUID,
        channel: Channel
    ) throws -> ExternalConnectionPolicySnapshot {
        guard ScriptingSnapshot.isVisibleToScripts(connectionId: connectionId) else {
            let stored = ConnectionStorage.shared.loadConnections().first { $0.id == connectionId }
            throw channel.refusal(for: stored?.externalAccess)
        }
        return try ExternalConnectionPolicySnapshot.resolve(connectionId: connectionId)
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
                source: request.channel.historySource,
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
