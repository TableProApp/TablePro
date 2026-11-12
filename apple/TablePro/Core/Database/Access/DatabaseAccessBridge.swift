//
//  DatabaseAccessBridge.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit
import TableProSQLGrammar

/// Connecting, switching container and running one statement, for a caller that is not a person
/// clicking in the app.
///
/// MCP, the AI assistant and AppleScript all need the same six operations against `DatabaseManager`
/// and they must agree on every one of them, so they share this rather than each reaching into the
/// manager on its own terms. Everything here is typed: JSON is a wire format that belongs to the
/// MCP transport, and `MCPConnectionBridge` is the layer that encodes these results into it.
///
/// Nothing here runs without an `ApprovedOperation`, which only `ExternalStatementGate.approve` makes, so
/// every statement it sends is the one Safe Mode showed, in the scope it showed.
internal actor DatabaseAccessBridge {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "DatabaseAccess")

    private let managerOverride: DatabaseManager?

    internal init(manager: DatabaseManager? = nil) {
        self.managerOverride = manager
    }

    internal var databaseManager: DatabaseManager {
        get async { await MainActor.run { managerOverride ?? .shared } }
    }

    // MARK: - Connect

    internal struct ConnectionSnapshot: Sendable {
        internal let serverVersion: String?
        internal let database: String
        internal let schema: String?
    }

    internal struct ConnectionStatusSnapshot: Sendable {
        internal let status: ConnectionStatus
        internal let database: String
        internal let schema: String?
        internal let serverVersion: String?
        internal let connectedAt: Date
        internal let lastActiveAt: Date
    }

    internal func connect(connectionId: UUID) async throws -> ConnectionSnapshot {
        let manager = await databaseManager
        let connection = try await resolveConnection(connectionId)

        // A session the reconnect loop is redialing, or gave up on, keeps its driver; only a live one skips the redial.
        let alreadyLive = await MainActor.run {
            if case .live = manager.connectionState(connectionId) { return true }
            return false
        }
        if !alreadyLive {
            do {
                try await manager.ensureConnected(connection)
            } catch let refusal as PreConnectScriptConsentError {
                throw Self.accessError(for: refusal)
            } catch let refusal as EnvVarReferenceConsentError {
                throw Self.accessError(for: refusal)
            } catch let refusal as LocalCredentialConsentError {
                throw Self.accessError(for: refusal)
            }
        }

        let snapshot = await MainActor.run { () -> ConnectionSnapshot? in
            guard let session = manager.activeSessions[connectionId],
                  let driver = session.driver
            else {
                return nil
            }
            return ConnectionSnapshot(
                serverVersion: driver.serverVersion,
                database: session.resolvedBrowseDatabase,
                schema: session.browseSchema
            )
        }

        guard let snapshot else { throw DatabaseAccessError.notConnected(connectionId) }
        return snapshot
    }

    internal func disconnect(connectionId: UUID) async throws {
        let manager = await databaseManager
        try await Self.disconnectUnlessWorkIsLost(connectionId, manager: manager)
    }

    // TablePro asks the user before a disconnect that loses work; a caller that is not a person gets a refusal.
    @MainActor
    private static func disconnectUnlessWorkIsLost(_ connectionId: UUID, manager: DatabaseManager) async throws {
        guard manager.activeSessions[connectionId] != nil else { throw DatabaseAccessError.notConnected(connectionId) }
        let turnRevisionBefore = manager.sessionTransactions.turnRevision(for: connectionId)
        let probed = await manager.transactionSafety(for: connectionId)
        // Read after the probe and with no suspension before the disconnect, so work that started meanwhile counts.
        guard manager.activeSessions[connectionId] != nil else { throw DatabaseAccessError.notConnected(connectionId) }
        let transactions = manager.settledTransactionSafety(
            probed, for: connectionId, turnRevisionBefore: turnRevisionBefore
        )
        if let refusal = ExternalDisconnectRefusal.message(
            work: RunningWorkRegistry.shared.items(in: .connection(connectionId)),
            transactions: transactions,
            hasUnsavedWork: MainContentCoordinator.hasUnsavedWork(forConnection: connectionId)
        ) {
            throw DatabaseAccessError.forbidden(refusal)
        }
        await manager.disconnectSession(connectionId)
    }

    internal func connectionStatus(connectionId: UUID) async throws -> ConnectionStatusSnapshot {
        let manager = await databaseManager
        let snapshot = await MainActor.run { () -> ConnectionStatusSnapshot? in
            guard let session = manager.activeSessions[connectionId] else { return nil }
            return ConnectionStatusSnapshot(
                status: session.effectiveStatus,
                database: session.resolvedBrowseDatabase,
                schema: session.browseSchema,
                serverVersion: session.driver?.serverVersion,
                connectedAt: session.connectedAt,
                lastActiveAt: session.lastActiveAt
            )
        }
        guard let snapshot else { throw DatabaseAccessError.notConnected(connectionId) }
        return snapshot
    }

    // MARK: - Resolve

    internal func resolveConnection(_ connectionId: UUID) async throws -> DatabaseConnection {
        let manager = await databaseManager
        return try await MainActor.run {
            let connections = manager.connectionStorage.loadConnections()
            guard let connection = connections.first(where: { $0.id == connectionId }) else {
                throw DatabaseAccessError.notFound(
                    String(localized: "No saved connection has that id.")
                )
            }
            return connection
        }
    }

    /// Every row an automation client, MCP or the in-app assistant reads leaves through this bridge, so this is
    /// where those rows take the connection's masking rules.
    internal func maskingPolicy(for connectionId: UUID) async -> MaskingPolicy {
        let manager = await databaseManager
        return await MainActor.run {
            if let session = manager.session(for: connectionId) {
                return session.connection.maskingPolicy
            }
            return manager.connectionStorage.loadConnection(id: connectionId)?.maskingPolicy ?? .none
        }
    }

    internal func resolveDriver(_ connectionId: UUID) async throws -> (DatabaseDriver, DatabaseType) {
        let manager = await databaseManager
        let pending: DatabaseConnection? = await MainActor.run {
            switch manager.connectionState(connectionId) {
            case .live: return nil
            case .stored(let connection): return connection
            case .unknown: return nil
            }
        }
        if let pending {
            do {
                try await manager.ensureConnected(pending)
            } catch let refusal as PreConnectScriptConsentError {
                throw Self.accessError(for: refusal)
            } catch let refusal as EnvVarReferenceConsentError {
                throw Self.accessError(for: refusal)
            } catch let refusal as LocalCredentialConsentError {
                throw Self.accessError(for: refusal)
            }
        }
        /// An automation client is the likeliest thing to reach a connection nobody has touched
        /// for hours, and it never passes through `ensureConnected` once a session exists, so this
        /// is where the check has to be for MCP and for Cocoa Scripting.
        await manager.verifyBeforeUse(connectionId)
        return try await MainActor.run {
            switch manager.connectionState(connectionId) {
            case .live(let driver, let session):
                return (driver, session.connection.type)
            case .stored, .unknown:
                throw DatabaseAccessError.notConnected(connectionId)
            }
        }
    }

    @discardableResult
    internal func ensureConnected(_ connectionId: UUID) async throws -> DatabaseType {
        let (_, databaseType) = try await resolveDriver(connectionId)
        return databaseType
    }

    // A refused consent prompt reaches a client as a refusal or a timeout, not a failure.
    private static func accessError(for refusal: PreConnectScriptConsentError) -> DatabaseAccessError {
        let detail = refusal.errorDescription ?? ""
        switch refusal {
        case .unanswered:
            return .timeout(detail)
        case .declined, .needsPerson:
            return .forbidden(detail)
        }
    }

    private static func accessError(for refusal: EnvVarReferenceConsentError) -> DatabaseAccessError {
        let detail = refusal.errorDescription ?? ""
        switch refusal {
        case .unanswered:
            return .timeout(detail)
        case .declined, .needsPerson:
            return .forbidden(detail)
        }
    }

    private static func accessError(for refusal: LocalCredentialConsentError) -> DatabaseAccessError {
        let detail = refusal.errorDescription ?? ""
        switch refusal {
        case .unanswered:
            return .timeout(detail)
        case .declined, .needsPerson:
            return .forbidden(detail)
        }
    }

    internal func resolveScope(connectionId: UUID, database: String?, schema: String?) async throws -> DatabaseScope {
        let manager = await databaseManager
        try await ensureConnected(connectionId)
        return try await MainActor.run {
            guard let scope = manager.resolvedScope(
                database: database,
                schema: schema,
                for: connectionId
            ) else {
                throw DatabaseAccessError.invalidArgument(
                    String(localized: "No database to run against. Pass a database name.")
                )
            }
            return scope
        }
    }

    internal func switchDatabase(connectionId: UUID, database: String) async throws {
        let manager = await databaseManager
        try await manager.switchDatabase(to: database, for: connectionId)
    }

    internal func switchSchema(connectionId: UUID, schema: String) async throws {
        let manager = await databaseManager
        try await manager.switchSchema(to: schema, for: connectionId)
    }

    // MARK: - Plan

    // The exact text a statement reaches the driver as, decided before anyone approves it: trailing separators off,
    // and on an engine that returns only its leading rows, the limit it is sent with.
    internal func plannedStatement(scope: DatabaseScope, query: String, maxRows: Int) async throws -> OperationStatement {
        guard !Self.statementText(query, grammar: .ansi).isEmpty else { throw Self.emptyQuery }
        let (sessionDriver, databaseType) = try await resolveDriver(scope.connectionId)
        let grammar = SQLLexicalResolver.readings(
            for: databaseType, session: sessionDriver.sessionLexicalState
        ).execution
        let normalized = Self.statementText(query, databaseType: databaseType, grammar: grammar)
        guard !normalized.isEmpty else { throw Self.emptyQuery }
        guard Self.capsRows(normalized, databaseType: databaseType) else { return OperationStatement(sql: normalized) }
        let limited = await MainActor.run {
            LeadingRowsStatement.resolve(normalized, rowCap: maxRows, databaseType: databaseType)
        }
        return OperationStatement(sql: limited.sql)
    }

    internal struct PlannedText: Sendable {
        internal let statement: OperationStatement
        internal let unit: OperationUnit
    }

    // A text that runs as a SQL Server script stays whole, to be cut at its GO lines; anything else is one statement.
    internal func plannedScript(scope: DatabaseScope, query: String, maxRows: Int) async throws -> PlannedText {
        guard !Self.statementText(query, grammar: .ansi).isEmpty else { throw Self.emptyQuery }
        let (driver, databaseType) = try await resolveDriver(scope.connectionId)
        switch await scriptRoute(query, scope: scope, databaseType: databaseType, driver: driver) {
        case .single(let statement):
            return PlannedText(
                statement: try await plannedStatement(scope: scope, query: statement.sql, maxRows: maxRows),
                unit: .statement
            )
        case .batches:
            return PlannedText(statement: OperationStatement(sql: query), unit: .script)
        case .statements:
            throw DatabaseAccessError.invalidArgument(
                String(localized: "Update the database driver in Settings > Extensions to run several statements in one call.")
            )
        case .needsBatchDriver:
            throw DatabaseAccessError.invalidArgument(
                String(localized: "Update the database driver in Settings > Extensions to run a batch more than once with GO.")
            )
        case nil:
            throw Self.emptyQuery
        }
    }

    internal func scriptRoute(
        _ text: String,
        scope: DatabaseScope,
        databaseType: DatabaseType,
        driver: DatabaseDriver
    ) async -> QueryExecutionRoute? {
        await MainActor.run {
            QueryExecutionRoute.resolve(
                QueryBatchPlanner.batches(
                    in: text,
                    model: QueryStatementModel.forDatabaseType(databaseType),
                    grammar: SQLLexicalResolver.executionGrammar(for: databaseType, connectionId: scope.connectionId)
                ),
                databaseType: databaseType,
                sendsBatchesWhole: driver.supportsResultSetBatches
            )
        }
    }

    private static func capsRows(_ sql: String, databaseType: DatabaseType) -> Bool {
        QueryClassifier.classify(sql, databaseType: databaseType).tier == .safe
            || sql.range(of: #"\bRETURNING\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static var emptyQuery: DatabaseAccessError {
        .invalidArgument(String(localized: "The query is empty."))
    }

    static var notApproved: DatabaseAccessError {
        .forbidden(String(localized: "This operation is not the one that was approved."))
    }

    // MARK: - Run

    internal struct StatementOutcome: Sendable {
        internal let result: QueryResult
        internal let executionTimeMs: Double
        // What the answer spent, nil when it ran with none.
        internal let budget: ExternalAnswerBudget?
    }

    // Runs the one approved statement as it was approved, its rows masked as `masking` says, then held to `budget`.
    // AppleScript and Shortcuts pass none.
    internal func runStatement(
        _ operation: ApprovedOperation,
        maxRows: Int,
        timeoutSeconds: Int,
        cancellation: (any StatementCancellationSignal)?,
        masking: ExternalRowMasking = .byOrigin,
        budget: ExternalAnswerBudget? = nil
    ) async throws -> StatementOutcome {
        let reach = DriverReach()
        do {
            return try await runApprovedStatement(
                operation, maxRows: maxRows, timeoutSeconds: timeoutSeconds, cancellation: cancellation, masking: masking,
                budget: budget, reach: reach
            )
        } catch {
            throw await externalError(error, on: operation.scope.connectionId, reach: reach)
        }
    }

    private func runApprovedStatement(
        _ operation: ApprovedOperation,
        maxRows: Int,
        timeoutSeconds: Int,
        cancellation: (any StatementCancellationSignal)?,
        masking: ExternalRowMasking,
        budget: ExternalAnswerBudget?,
        reach: DriverReach
    ) async throws -> StatementOutcome {
        guard operation.unit == .statement, operation.statements.count == 1, let statement = operation.statements.first
        else { throw Self.notApproved }
        let scope = operation.scope
        let (sessionDriver, databaseType) = try await resolveDriver(scope.connectionId)
        guard databaseType == operation.databaseType else { throw Self.notApproved }
        let grammar = SQLLexicalResolver.readings(
            for: databaseType, session: sessionDriver.sessionLexicalState
        ).execution
        let sql = statement.sql
        let classification = QueryClassifier.classify(sql, databaseType: databaseType)
        var rowCap: Int?
        if Self.capsRows(sql, databaseType: databaseType) {
            let ceiling = await MainActor.run { PluginManager.shared.paginationCapability(for: databaseType).maximumRows }
            rowCap = ceiling.map { min(maxRows, $0) } ?? maxRows
        }
        let context = operation.context(readingAtMost: budget?.remainingBytes)
        let fetchCap = rowCap
        let connectionId = scope.connectionId
        // One owner per statement, so a cancel or a timeout reaches this statement's lease only.
        let owner = DriverLeaseOwner()
        let policy: DriverCancellationPolicy = classification.tier == .safe
            ? .cancellableRead(owner)
            : .protectedWrite

        await forwardCancellation(cancellation, to: owner, on: connectionId)

        let manager = await databaseManager
        let route = await MainActor.run { manager.executionRoute(for: scope) }
        let commitMode = await MainActor.run { manager.commitMode(for: connectionId) }
        let agentGuard = AgentTransactionGuard(
            commitMode: commitMode, databaseType: databaseType, grammar: grammar, connectionId: connectionId
        )
        let writes = classification.tier != .safe
        let startTime = CFAbsoluteTimeGetCurrent()
        let statementRan = CatalogEvent.statementsRan(
            connectionId: connectionId, statements: [sql], databaseType: databaseType
        )

        // A write that timed out or failed may still have committed, so the catalog is refreshed rather than trusted.
        var result: QueryResult
        let tableEdits: SucceededStatements?
        let transactionNotice: String?
        do {
            (result, tableEdits, transactionNotice) = try await runRacingTimeout(
                scope: scope,
                route: route,
                policy: policy,
                owner: owner,
                timeoutSeconds: timeoutSeconds,
                onLateCompletion: { CatalogChangeService.post(statementRan) }
            ) { driver in
                reach.mark()
                let ran = try await agentGuard.running([sql], writes: writes, on: driver) { _ in
                    // Before it runs, so a statement that fails or a connection lost under it is still noted.
                    await manager.noteSessionStatements([sql], ranOn: driver, scope: scope)
                    return try await driver.executeUserQuery(
                        query: sql,
                        rowCap: fetchCap,
                        parameters: statement.parameters.isEmpty ? nil : statement.boundValues,
                        context: context
                    )
                }
                let edits = await SucceededStatements.single(
                    sql, scope: scope, databaseType: databaseType, grammar: grammar, ranOn: driver
                )
                return (ran.value, edits, ran.notice)
            }
        } catch {
            if classification.tier != .safe {
                CatalogChangeService.post(statementRan)
            }
            throw error
        }

        CatalogChangeService.post(statementRan)
        if let tableEdits {
            CatalogChangeService.post(.statementsSucceeded(tableEdits))
        }
        if let transactionNotice {
            result.statusMessage = [result.statusMessage, transactionNotice].compactMap { $0 }.joined(separator: " ")
        }
        let executionTimeMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1_000
        let rules = await maskingPolicy(for: connectionId)
        let applied = await MainActor.run { masking.resolved(in: scope, databaseType: databaseType) }
        // Masked first, so a partial mask reads the whole value before any cut.
        let masked = applied.apply(rules, to: result)
        guard var spent = budget else {
            return StatementOutcome(result: masked, executionTimeMs: executionTimeMs, budget: nil)
        }
        let kept = spent.keep(masked)
        // Short of the row cap and truncated anyway: the driver stopped at the byte limit.
        if context.resultByteLimit != nil, let fetchCap, masked.isTruncated, masked.rows.count < fetchCap {
            spent.markSizeLimited()
        }
        return StatementOutcome(result: kept, executionTimeMs: executionTimeMs, budget: spent)
    }

    // A plan the driver builds for the approved statement, masked as `masking` says.
    internal func runExplainPlan(
        _ operation: ApprovedOperation,
        step: ExplainRequest.DriverStep,
        timeoutSeconds: Int,
        cancellation: (any StatementCancellationSignal)?,
        masking: ExternalRowMasking = .byOrigin
    ) async throws -> StatementOutcome {
        let reach = DriverReach()
        do {
            let outcome = try await runDriverPlan(
                operation, step: step, timeoutSeconds: timeoutSeconds, cancellation: cancellation, reach: reach
            )
            let rules = await maskingPolicy(for: operation.scope.connectionId)
            return StatementOutcome(
                result: masking.apply(rules, to: outcome.result), executionTimeMs: outcome.executionTimeMs, budget: nil
            )
        } catch {
            throw await externalError(error, on: operation.scope.connectionId, reach: reach)
        }
    }

    // A server's message can repeat a value the statement read, as PostgreSQL's `invalid input syntax for type
    // integer: "..."` does, so on a connection with masking rules an external caller gets the error's code only.
    // What failed before a driver took the statement, a connect, a route or a pin, is the app's own and keeps its words.
    internal func externalError(_ error: Error, on connectionId: UUID, reach: DriverReach) async -> Error {
        guard reach.isReached, ServerErrorText.mayRepeatAValue(error) else { return error }
        guard await !maskingPolicy(for: connectionId).isEmpty else { return error }
        return ServerErrorText.withholding(error)
    }

    private func runDriverPlan(
        _ operation: ApprovedOperation,
        step: ExplainRequest.DriverStep,
        timeoutSeconds: Int,
        cancellation: (any StatementCancellationSignal)?,
        reach: DriverReach
    ) async throws -> StatementOutcome {
        guard operation.unit == .statement, operation.statements.count == 1, let approved = operation.statements.first
        else { throw Self.notApproved }
        let scope = operation.scope
        let statement = approved.sql
        let databaseType = try await ensureConnected(scope.connectionId)
        guard databaseType == operation.databaseType else { throw Self.notApproved }
        let writes = step.runsStatement
            && QueryClassifier.classify(statement, databaseType: databaseType).tier != .safe
        let connectionId = scope.connectionId
        let owner = DriverLeaseOwner()
        let policy: DriverCancellationPolicy = writes ? .protectedWrite : .cancellableRead(owner)

        await forwardCancellation(cancellation, to: owner, on: connectionId)

        let manager = await databaseManager
        let route = await MainActor.run { manager.executionRoute(for: scope) }
        let startTime = CFAbsoluteTimeGetCurrent()
        let statementRan = CatalogEvent.statementsRan(
            connectionId: connectionId, statements: [statement], databaseType: databaseType
        )
        let variantId = step.variantId
        let result: QueryResult
        do {
            result = try await runRacingTimeout(
                scope: scope,
                route: route,
                policy: policy,
                owner: owner,
                timeoutSeconds: timeoutSeconds,
                onLateCompletion: { CatalogChangeService.post(statementRan) }
            ) { driver in
                reach.mark()
                return try await driver.explainPlan(statement: statement, variantId: variantId)
            }
        } catch {
            if writes {
                CatalogChangeService.post(statementRan)
            }
            throw error
        }
        if writes {
            CatalogChangeService.post(statementRan)
        }
        return StatementOutcome(
            result: result, executionTimeMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1_000, budget: nil
        )
    }

    // One approved INSERT per row, on one write lease, each with the values it was approved with.
    internal func runInserts(_ operation: ApprovedOperation) async throws -> Int {
        let reach = DriverReach()
        do {
            return try await runApprovedInserts(operation, reach: reach)
        } catch {
            throw await externalError(error, on: operation.scope.connectionId, reach: reach)
        }
    }

    private func runApprovedInserts(_ operation: ApprovedOperation, reach: DriverReach) async throws -> Int {
        guard operation.kind == .writeQuery, operation.unit == .statement, !operation.statements.isEmpty
        else { throw Self.notApproved }
        let scope = operation.scope
        let databaseType = try await ensureConnected(scope.connectionId)
        guard databaseType == operation.databaseType else { throw Self.notApproved }
        let manager = await databaseManager
        // No cancel handler: the inserts run under a `.protectedWrite` lease, which nothing may abort.
        let route = await MainActor.run { manager.executionRoute(for: scope) }
        let agentGuard = await MainActor.run {
            AgentTransactionGuard(
                commitMode: manager.commitMode(for: scope.connectionId),
                databaseType: databaseType,
                grammar: SQLLexicalResolver.executionGrammar(for: databaseType, connectionId: scope.connectionId),
                connectionId: scope.connectionId
            )
        }
        let statements = operation.statements
        let context = operation.context
        return try await manager.withScopedDriver(
            scope: scope,
            route: route,
            cancellation: .protectedWrite
        ) { driver -> Int in
            reach.mark()
            // The hold and savepoint execute_query gets, so a Manual Commit insert waits for Commit too.
            let ran = try await agentGuard.running(
                statements.map(\.sql), writes: true, asOneUnit: statements.count > 1, on: driver
            ) { _ in
                var affected = 0
                for statement in statements {
                    let result = try await driver.executeParameterized(
                        query: statement.sql,
                        parameters: statement.boundValues,
                        context: context
                    )
                    affected += max(result.rowsAffected, 0)
                }
                return affected
            }
            return ran.value
        }
    }

    // The driver writes its count statement itself, so the approval is the read, with no text.
    internal func countRows(
        _ operation: ApprovedOperation,
        table: String,
        filters: [TableFilter],
        logicMode: FilterLogicMode,
        exact: Bool
    ) async throws -> (count: Int?, isApproximate: Bool) {
        let reach = DriverReach()
        do {
            return try await countApprovedRows(
                operation, table: table, filters: filters, logicMode: logicMode, exact: exact, reach: reach
            )
        } catch {
            throw await externalError(error, on: operation.scope.connectionId, reach: reach)
        }
    }

    private func countApprovedRows(
        _ operation: ApprovedOperation,
        table: String,
        filters: [TableFilter],
        logicMode: FilterLogicMode,
        exact: Bool,
        reach: DriverReach
    ) async throws -> (count: Int?, isApproximate: Bool) {
        guard operation.kind == .readQuery, operation.statements.isEmpty else { throw Self.notApproved }
        let scope = operation.scope
        try await ensureConnected(scope.connectionId)
        let manager = await databaseManager
        return try await manager.withMetadataDriver(scope: scope) { driver -> (count: Int?, isApproximate: Bool) in
            reach.mark()
            if exact {
                let value = try await driver.fetchExactRowCount(table: table, filters: filters, logicMode: logicMode)
                return (value, false)
            }
            if !filters.isEmpty {
                let value = try await driver.fetchFilteredRowCount(table: table, filters: filters, logicMode: logicMode)
                return (value, false)
            }
            return (try await driver.fetchApproximateRowCount(table: table), true)
        }
    }

    // A deferred constraint fails at COMMIT, naming the key values it checked.
    internal func transactionControl(_ operation: ApprovedOperation, action: String) async throws {
        let reach = DriverReach()
        do {
            try await runTransactionControl(operation, action: action, reach: reach)
        } catch {
            throw await externalError(error, on: operation.scope.connectionId, reach: reach)
        }
    }

    private func runTransactionControl(_ operation: ApprovedOperation, action: String, reach: DriverReach) async throws {
        guard operation.kind == .writeQuery, operation.statements.isEmpty else { throw Self.notApproved }
        let scope = operation.scope
        try await ensureConnected(scope.connectionId)
        let manager = await databaseManager
        let supported = await MainActor.run {
            manager.driver(for: scope.connectionId)?.supportsTransactions ?? false
        }
        guard supported else {
            throw DatabaseAccessError.dataSourceError(String(localized: "This engine does not support transactions."))
        }
        // The user commits a Manual Commit connection's work; an agent's begin, commit or rollback would end or bury it.
        guard await MainActor.run(body: { manager.commitMode(for: scope.connectionId) }) == .automatic else {
            throw DatabaseAccessError.dataSourceError(ManualCommit.transactionControlRefusalMessage)
        }
        try await manager.withScopedDriver(
            scope: scope,
            route: .sessionDriver,
            cancellation: .protectedWrite
        ) { driver in
            reach.mark()
            switch action {
            case "begin":
                // MySQL's START TRANSACTION commits a transaction already open; PostgreSQL's BEGIN warns and joins it.
                guard await driver.heldSessionTransactionState() == .idle else {
                    throw DatabaseAccessError.dataSourceError(ManualCommit.openTransactionRefusalMessage)
                }
                try await driver.beginTransaction(mode: .readWrite)
            case "commit": try await driver.commitTransaction()
            case "rollback": try await driver.rollbackTransaction()
            default:
                throw DatabaseAccessError.invalidArgument(
                    String(localized: "Transaction action must be begin, commit, or rollback.")
                )
            }
        }
        if action == "commit" || action == "rollback" {
            CatalogChangeService.post(.transactionEnded(connectionId: scope.connectionId))
        }
    }

    internal func createDatabase(_ operation: ApprovedOperation, name: String, options: [String: String]) async throws {
        guard operation.kind == .schemaMutation, operation.statements.isEmpty else { throw Self.notApproved }
        let connectionId = operation.scope.connectionId
        let (driver, _) = try await resolveDriver(connectionId)
        let manager = await databaseManager
        try await manager.trackOperation(sessionId: connectionId) {
            try await driver.createDatabase(CreateDatabaseRequest(name: name, values: options))
        }
        CatalogChangeService.post(.changed(CatalogChange(connectionId: connectionId, kinds: .databases)))
    }

    internal func dropDatabase(_ operation: ApprovedOperation, name: String) async throws {
        guard operation.kind == .destructiveQuery, operation.statements.isEmpty else { throw Self.notApproved }
        let connectionId = operation.scope.connectionId
        let manager = await databaseManager
        await MainActor.run {
            MetadataConnectionPool.shared.closeAll(connectionId: connectionId, database: name)
            manager.sessionLanes.close(database: name, for: connectionId)
        }
        let (driver, _) = try await resolveDriver(connectionId)
        try await manager.trackOperation(sessionId: connectionId) {
            try await driver.dropDatabase(name: name)
        }
        CatalogChangeService.post(.containerDropped(.database(name), connectionId: connectionId))
    }

    internal func dropSchema(_ operation: ApprovedOperation, name: String) async throws {
        guard operation.kind == .destructiveQuery, operation.statements.isEmpty else { throw Self.notApproved }
        let scope = operation.scope
        try await ensureConnected(scope.connectionId)
        let manager = await databaseManager
        // Pinned to the approved database, so a switch while the dialog was open cannot move the drop.
        let route = await MainActor.run { manager.schemaChangeRoute(for: scope) }
        try await manager.withScopedDriver(scope: scope, route: route, cancellation: .protectedWrite) { driver in
            try await driver.dropSchema(name: name)
        }
        CatalogChangeService.post(
            .containerDropped(.schema(database: nil, schema: name), connectionId: scope.connectionId)
        )
    }

    // A grid save's plan, run only when it is the plan that was approved.
    // An UPDATE that breaks a NOT NULL or CHECK constraint fails listing the row's other values.
    internal func runRowWrites(
        _ operation: ApprovedOperation,
        plan: DataWritePlan,
        before: @Sendable @escaping (DatabaseDriver, _ ownsConnection: Bool) async throws -> Void
    ) async throws -> DataWriteRun {
        let reach = DriverReach()
        do {
            return try await runApprovedRowWrites(operation, plan: plan, before: before, reach: reach)
        } catch {
            throw await externalError(error, on: operation.scope.connectionId, reach: reach)
        }
    }

    private func runApprovedRowWrites(
        _ operation: ApprovedOperation,
        plan: DataWritePlan,
        before: @Sendable @escaping (DatabaseDriver, _ ownsConnection: Bool) async throws -> Void,
        reach: DriverReach
    ) async throws -> DataWriteRun {
        guard operation.kind == .writeQuery,
              operation.scope == plan.scope,
              operation.statements == plan.statements.map(OperationStatement.init(bound:))
        else { throw Self.notApproved }
        let scope = operation.scope
        let manager = await databaseManager
        let route = await MainActor.run { manager.schemaChangeRoute(for: scope) }
        let ownsConnection = route.isPooled
        let context = operation.context
        return try await manager.withScopedDriver(
            scope: scope,
            route: route,
            cancellation: .protectedWrite
        ) { driver in
            reach.mark()
            try await before(driver, ownsConnection)
            return try await DataWriteExecutor.run(plan, commitMode: .automatic, on: driver, context: context)
        }
    }

    internal func forwardCancellation(
        _ cancellation: (any StatementCancellationSignal)?,
        to owner: DriverLeaseOwner,
        on connectionId: UUID
    ) async {
        guard let cancellation else { return }
        let manager = await databaseManager
        await cancellation.onCancelRequested {
            await MainActor.run {
                try? manager.cancelRunningQuery(
                    owner: owner, on: connectionId, delivery: .immediate
                )
            }
        }
    }

    internal func runRacingTimeout<Output: Sendable>(
        scope: DatabaseScope,
        route: ScopedDriverRoute,
        policy: DriverCancellationPolicy,
        owner: DriverLeaseOwner,
        timeoutSeconds: Int,
        onLateCompletion: (@Sendable () -> Void)? = nil,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> Output
    ) async throws -> Output {
        let connectionId = scope.connectionId
        let manager = await databaseManager
        if policy == .protectedWrite {
            return try await Self.awaitProtectedWrite(
                timeout: .seconds(timeoutSeconds),
                timeoutSeconds: timeoutSeconds,
                onLateCompletion: onLateCompletion
            ) { enterDriver in
                try await manager.withScopedDriver(scope: scope, route: route, cancellation: policy) { driver in
                    try enterDriver()
                    return try await body(driver)
                }
            }
        }
        return try await withThrowingTaskGroup(of: Output.self) { group in
            group.addTask {
                try await manager.withScopedDriver(
                    scope: scope,
                    route: route,
                    cancellation: policy,
                    body
                )
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                await MainActor.run {
                    try? manager.cancelRunningQuery(
                        owner: owner, on: connectionId, delivery: .immediate
                    )
                }
                throw Self.plainTimeout(seconds: timeoutSeconds)
            }
            guard let first = try await group.next() else {
                throw DatabaseAccessError.dataSourceError("No result from query execution")
            }
            group.cancelAll()
            return first
        }
    }

    private static func plainTimeout(seconds: Int) -> DatabaseAccessError {
        .timeout(String(format: String(localized: "Query timed out after %d seconds"), seconds))
    }

    private enum ProtectedWritePhase: Sendable {
        case queued
        case inDriver
        case abandoned
    }

    // A protected write is never aborted once the driver has it. Past the deadline, or after the
    // caller cancels, such a write runs on and the caller is told the outcome is unknown: a plain
    // timeout would read as "nothing happened" and invite a retry that applies it twice. A write
    // still waiting for its turn is refused instead, so nothing runs after the caller was told no.
    // `work` calls `enterDriver` as the first thing inside its driver turn.
    internal static func awaitProtectedWrite<Output: Sendable>(
        timeout: Duration,
        timeoutSeconds: Int,
        onLateCompletion: (@Sendable () -> Void)? = nil,
        _ work: @Sendable @escaping (_ enterDriver: @escaping @Sendable () throws -> Void) async throws -> Output
    ) async throws -> Output {
        let phase = OSAllocatedUnfairLock(initialState: ProtectedWritePhase.queued)
        let callerLeft = OSAllocatedUnfairLock(initialState: false)
        let abandonIfQueued: @Sendable () -> Bool = {
            phase.withLock { current -> Bool in
                guard current == .queued else { return current == .abandoned }
                current = .abandoned
                return true
            }
        }
        let (outcomes, continuation) = AsyncThrowingStream<Output?, any Error>.makeStream()
        let deadline = Task<Bool, Never> {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return false
            }
            continuation.yield(nil)
            return true
        }
        let workTask = Task {
            do {
                let output = try await work {
                    let entered = phase.withLock { current -> Bool in
                        guard current == .queued else { return false }
                        current = .inDriver
                        return true
                    }
                    guard entered else { throw CancellationError() }
                }
                continuation.yield(output)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
            deadline.cancel()
            guard phase.withLock({ $0 == .inDriver }) else { return }
            let deadlinePassed = await deadline.value
            if deadlinePassed || callerLeft.withLock({ $0 }) {
                onLateCompletion?()
            }
        }
        return try await withTaskCancellationHandler {
            for try await outcome in outcomes {
                if let outcome { return outcome }
                if abandonIfQueued() {
                    workTask.cancel()
                    throw plainTimeout(seconds: timeoutSeconds)
                }
                throw DatabaseAccessError.timeout(
                    String(
                        format: String(localized: """
                            The statement did not finish within %d seconds and is still running. \
                            It may have been applied; check before running it again.
                            """),
                        timeoutSeconds
                    ),
                    context: ["outcome": "unknown"]
                )
            }
            if phase.withLock({ $0 == .inDriver }) {
                throw stoppedWhileRunning
            }
            try Task.checkCancellation()
            throw DatabaseAccessError.dataSourceError("No result from query execution")
        } onCancel: {
            if abandonIfQueued() {
                workTask.cancel()
            } else {
                callerLeft.withLock { $0 = true }
            }
            deadline.cancel()
        }
    }

    // Not "timed out": the caller stopped it, and a retry would apply it twice.
    static var stoppedWhileRunning: DatabaseAccessError {
        .stoppedWhileRunning(String(
            localized: """
                The statement was still running in the database when it was stopped, and it runs to the end. \
                It may have been applied; check before running it again.
                """
        ))
    }

    /// The text an external client's statement reaches the driver as.
    ///
    /// Trailing separators come off and a terminator that belongs to the statement stays, as the editor decides it:
    /// a PL/SQL unit sent without the `;` after its `END` fails, or is stored INVALID, on Oracle. A caller may check
    /// emptiness with `.ansi` before it knows the engine and again once it does.
    internal static func statementText(_ query: String, grammar: SQLLexicalGrammar) -> String {
        SQLStatementScanner.executableText(of: query, grammar: grammar)
    }

    internal static func statementText(
        _ query: String,
        databaseType: DatabaseType,
        grammar: SQLLexicalGrammar? = nil
    ) -> String {
        QueryStatementScanner.executableText(
            of: query,
            model: QueryStatementModel.forDatabaseType(databaseType),
            grammar: grammar ?? databaseType.lexicalGrammar
        )
    }
}

// How the rows an external caller reads meet the connection's masking rules.
internal enum ExternalRowMasking: Sendable, Equatable {
    // The caller's own statement, which can rename or compute any column: matched by what each column reads.
    case byOrigin
    // A statement the app wrote that selects this table's own columns by name.
    case table(String)
    // A plan measured to hold only the statement's own literals, or an answer to a server call the app wrote:
    // matched by column name.
    case byName

    func apply(_ policy: MaskingPolicy, to result: QueryResult) -> QueryResult {
        switch self {
        case .byOrigin: return result.maskedForExternalCaller(by: policy)
        case .table(let table): return result.maskedForExternalCaller(by: policy, table: table)
        case .byName: return result.masked(by: policy)
        }
    }

    // Measured: PostgreSQL 17 plans, with ANALYZE and VERBOSE too, and SQLite 3.54 plans and bytecode hold only the
    // statement's own literals. MariaDB writes the values it read from const tables into its plan, so a format nobody
    // measured is masked as rows are, which masks a plan whole.
    static func plan(in format: ExplainPlanFormat?) -> ExternalRowMasking {
        guard let format, valueFreePlanFormats.contains(format) else { return .byOrigin }
        return .byName
    }

    private static let valueFreePlanFormats: Set<ExplainPlanFormat> = [.postgresJson, .sqliteQueryPlan]

    // The app's projection of a table proves by name only for a user table. A system one, ClickHouse's
    // `system.query_log` or `pg_stat_activity`, repeats other tables' values and what sessions sent, so it is masked
    // as a result with no origins is. The system names are the ones the engine's plugin declares.
    @MainActor
    func resolved(in scope: DatabaseScope, databaseType: DatabaseType) -> ExternalRowMasking {
        guard case .table(let table) = self else { return self }
        let databases = PluginManager.shared.systemContainerNames(for: databaseType, target: .database)
        let schemas = PluginManager.shared.systemContainerNames(for: databaseType, target: .schema)
        let containers = [scope.database] + [scope.schema].compactMap { $0 } + table.split(separator: ".").dropLast().map(String.init)
        guard !containers.contains(where: { databases.contains($0) || schemas.contains($0) }) else { return .byOrigin }
        return self
    }
}

// Set as a driver takes the statement.
internal final class DriverReach: Sendable {
    private let reached = OSAllocatedUnfairLock(initialState: false)

    func mark() {
        reached.withLock { $0 = true }
    }

    var isReached: Bool {
        reached.withLock { $0 }
    }
}

// What an external caller learns of a failed statement on a connection with masking rules.
internal enum ServerErrorText {
    // The app's own refusals, timeouts and cancels name no value; whatever a driver or a server wrote might.
    static func mayRepeatAValue(_ error: Error) -> Bool {
        switch error {
        case is CancellationError, is DatabaseAccessError, is ExternalStatementGateError, is ShortcutsActionError,
             is any ManualCommitRefusing:
            return false
        case let failure as DatabaseError:
            if case .queryFailed = failure { return true }
            return false
        case let refusal as DataWriteError:
            // Only this case quotes the driver; the rest are the app's own counts and names.
            if case .changeRefused = refusal { return true }
            return false
        default:
            return true
        }
    }

    static func withholding(_ error: Error) -> Error {
        guard mayRepeatAValue(error) else { return error }
        guard let partial = error as? DataWritePartialCommitError else {
            return DatabaseAccessError.dataSourceError(withheld(for: error))
        }
        // What was already written is the app's own account, and what the caller must do next depends on it.
        return DataWritePartialCommitError(
            committed: partial.committed,
            totalStatements: partial.totalStatements,
            engine: partial.engine,
            disposition: partial.disposition,
            underlying: withholding(partial.underlying)
        )
    }

    static var withheldMessage: String {
        String(
            localized: "The statement failed. Its message is withheld because this connection has masking rules, and the message can repeat a masked value."
        )
    }

    static var withheldStatementText: String {
        String(localized: "The statement text is withheld because this connection has masking rules, and it can repeat a masked value.")
    }

    static func withheld(for error: Error) -> String {
        let labels = (error as? any PluginDriverError).map { Self.codes(of: $0) } ?? []
        guard !labels.isEmpty else { return withheldMessage }
        return String(
            format: String(
                localized: "The statement failed with %@. Its message is withheld because this connection has masking rules, and the message can repeat a masked value."
            ),
            labels.joined(separator: ", ")
        )
    }

    private static func codes(of error: any PluginDriverError) -> [String] {
        var codes: [String] = []
        if let code = error.pluginErrorCode, code != 0 {
            codes.append("error \(code)")
        }
        if let state = error.pluginSqlState, !state.isEmpty {
            codes.append("SQLSTATE \(state)")
        }
        return codes
    }
}

/// What a transport offers a running statement so its own cancellation reaches the driver.
///
/// MCP has `notifications/cancelled` and passes its token; AppleScript has no such notification and
/// passes nil, which is why this is optional rather than a required argument.
internal protocol StatementCancellationSignal: Sendable {
    func onCancelRequested(_ handler: @escaping @Sendable () async -> Void) async
}

// Kinds only: a line naming the work could name a tab, a file or another connection the caller cannot see.
@MainActor
internal enum ExternalDisconnectRefusal {
    internal enum Loss: Hashable, CaseIterable {
        case query
        case transfer
        case agentReply
        case comparison
        case transaction
        case unsavedChanges

        internal var noun: String {
            switch self {
            case .query: return String(localized: "a running query")
            case .transfer: return String(localized: "an import, export, backup, restore or copy")
            case .agentReply: return String(localized: "an agent reply")
            case .comparison: return String(localized: "a comparison or sync")
            case .transaction: return String(localized: "an open transaction")
            case .unsavedChanges: return String(localized: "unsaved changes")
            }
        }
    }

    internal static func message(
        work: [RunningWork],
        transactions: SessionTransactionSafety,
        hasUnsavedWork: Bool
    ) -> String? {
        var losses = Set(work.map { loss(for: $0.kind) })
        if transactions == .holding { losses.insert(.transaction) }
        if hasUnsavedWork { losses.insert(.unsavedChanges) }
        if let message = message(for: losses) { return message }
        guard transactions == .unknown else { return nil }
        return String(
            localized: "TablePro cannot tell whether this connection holds an open transaction, so it stays connected. Try again once its work is done, or disconnect in TablePro."
        )
    }

    internal static func message(for losses: Set<Loss>) -> String? {
        let nouns = Loss.allCases.filter { losses.contains($0) }.map { $0.noun }
        guard !nouns.isEmpty else { return nil }
        return String(
            format: String(
                localized: "This connection has %@ in TablePro, which disconnecting would stop or discard. Finish it first, or disconnect in TablePro, which asks the user."
            ),
            ListFormatter.localizedString(byJoining: nouns)
        )
    }

    private static func loss(for kind: RunningWorkKind) -> Loss {
        switch kind {
        case .query: return .query
        case .restore, .dataImport, .dataExport, .backup, .tableTransfer, .objectCopy: return .transfer
        case .agentReply: return .agentReply
        case .compareRun, .compareApply: return .comparison
        }
    }
}
