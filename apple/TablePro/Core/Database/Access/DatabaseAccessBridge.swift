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
        let sessionExists = await MainActor.run {
            manager.activeSessions[connectionId] != nil
        }
        guard sessionExists else { throw DatabaseAccessError.notConnected(connectionId) }
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
    }

    // Runs the one approved statement as it was approved. `maskingTable` names the table the rows come from when
    // the caller built the query for one, so a `table.column` rule matches by table.
    internal func runStatement(
        _ operation: ApprovedOperation,
        maxRows: Int,
        timeoutSeconds: Int,
        cancellation: (any StatementCancellationSignal)?,
        maskingTable: String? = nil
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
        let context = operation.context
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
        let startTime = CFAbsoluteTimeGetCurrent()
        let statementRan = CatalogEvent.statementsRan(
            connectionId: connectionId, statements: [sql], databaseType: databaseType
        )

        // A write that timed out or failed may still have committed, so the catalog is refreshed rather than trusted.
        let result: QueryResult
        let tableEdits: SucceededStatements?
        do {
            (result, tableEdits) = try await runRacingTimeout(
                scope: scope,
                route: route,
                policy: policy,
                owner: owner,
                timeoutSeconds: timeoutSeconds
            ) { driver in
                let answer = try await driver.executeUserQuery(
                    query: sql,
                    rowCap: fetchCap,
                    parameters: statement.parameters.isEmpty ? nil : statement.boundValues,
                    context: context
                )
                let edits = await SucceededStatements.single(
                    sql, scope: scope, databaseType: databaseType, grammar: grammar, ranOn: driver
                )
                return (answer, edits)
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
        let executionTimeMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1_000
        let masking = await maskingPolicy(for: connectionId)
        return StatementOutcome(result: result.masked(by: masking, table: maskingTable), executionTimeMs: executionTimeMs)
    }

    // A plan the driver builds for the approved statement.
    internal func runExplainPlan(
        _ operation: ApprovedOperation,
        step: ExplainRequest.DriverStep,
        timeoutSeconds: Int,
        cancellation: (any StatementCancellationSignal)?
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
                timeoutSeconds: timeoutSeconds
            ) { driver in
                try await driver.explainPlan(statement: statement, variantId: variantId)
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
        return StatementOutcome(result: result, executionTimeMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1_000)
    }

    // One approved INSERT per row, on one write lease, each with the values it was approved with.
    internal func runInserts(_ operation: ApprovedOperation) async throws -> Int {
        guard operation.kind == .writeQuery, operation.unit == .statement, !operation.statements.isEmpty
        else { throw Self.notApproved }
        let scope = operation.scope
        let databaseType = try await ensureConnected(scope.connectionId)
        guard databaseType == operation.databaseType else { throw Self.notApproved }
        let manager = await databaseManager
        // No cancel handler: the inserts run under a `.protectedWrite` lease, which nothing may abort.
        let route = await MainActor.run { manager.executionRoute(for: scope) }
        let statements = operation.statements
        let context = operation.context
        return try await manager.withScopedDriver(
            scope: scope,
            route: route,
            cancellation: .protectedWrite
        ) { driver -> Int in
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
    }

    // The driver writes its count statement itself, so the approval is the read, with no text.
    internal func countRows(
        _ operation: ApprovedOperation,
        table: String,
        filters: [TableFilter],
        logicMode: FilterLogicMode,
        exact: Bool
    ) async throws -> (count: Int?, isApproximate: Bool) {
        guard operation.kind == .readQuery, operation.statements.isEmpty else { throw Self.notApproved }
        let scope = operation.scope
        try await ensureConnected(scope.connectionId)
        let manager = await databaseManager
        return try await manager.withMetadataDriver(scope: scope) { driver -> (count: Int?, isApproximate: Bool) in
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

    internal func transactionControl(_ operation: ApprovedOperation, action: String) async throws {
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
        try await manager.withScopedDriver(
            scope: scope,
            route: .sessionDriver,
            cancellation: .protectedWrite
        ) { driver in
            switch action {
            case "begin": try await driver.beginTransaction(mode: .readWrite)
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
    internal func runRowWrites(
        _ operation: ApprovedOperation,
        plan: DataWritePlan,
        before: @Sendable @escaping (DatabaseDriver, _ ownsConnection: Bool) async throws -> Void
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
            try await before(driver, ownsConnection)
            return try await DataWriteExecutor.run(plan, on: driver, context: context)
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
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> Output
    ) async throws -> Output {
        let connectionId = scope.connectionId
        let manager = await databaseManager
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
                throw DatabaseAccessError.timeout(
                    String(
                        format: String(localized: "Query timed out after %d seconds"),
                        timeoutSeconds
                    )
                )
            }
            guard let first = try await group.next() else {
                throw DatabaseAccessError.dataSourceError("No result from query execution")
            }
            group.cancelAll()
            return first
        }
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

/// What a transport offers a running statement so its own cancellation reaches the driver.
///
/// MCP has `notifications/cancelled` and passes its token; AppleScript has no such notification and
/// passes nil, which is why this is optional rather than a required argument.
internal protocol StatementCancellationSignal: Sendable {
    func onCancelRequested(_ handler: @escaping @Sendable () async -> Void) async
}
