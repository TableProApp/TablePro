//
//  PluginDriverAdapter.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProConnectionLibrary
import TableProNumberFormatting
import TableProPluginKit
import TableProSQLGrammar
import TableProUtilities

final class PluginDriverAdapter: DatabaseDriver, SchemaSwitchable, DatabaseReporting {
    private struct ConnectAttempt {
        let generation: UInt64
        let gate: ConnectionSingleResumeGate<Void>
        var deadline: ContinuousClock.Instant
        var task: Task<Void, Never>?
        var isAbandoned = false
    }

    private struct State {
        var status: ConnectionStatus = .disconnected
        var columnTypeCache: [String: ColumnType] = [:]
        var nextConnectGeneration: UInt64 = 0
        var connectAttempt: ConnectAttempt?
        var connectionMayBeOpen = false
        var disconnectInProgress = false
        // Read from the driver when its connect is adopted, so both outlive the `disconnect()` Test Connection makes
        // before anyone asks: a driver forgets its server's version when it disconnects.
        var connectionWarning: String?
        var signInServerVersion: String?
        // Only a yes is kept, so the driver's own code is not asked again on every read.
        var buildsBrowseQueries = false
        var databaseMoves = 0
    }

    let connection: DatabaseConnection
    let effectiveQueryTimeoutSeconds: Int
    let pluginDriver: any PluginDatabaseDriver
    // The Vault lease this driver signed in with. Its database user goes away when it ends.
    private let credentialLease: VaultLeaseHold?
    private let connectionDeadline: ConnectionDeadline
    private let timeoutEndpoint: ConnectionTimeoutEndpoint
    private let requiresHostDeadline: Bool
    private let classifier: ColumnTypeClassifier
    private let state = OSAllocatedUnfairLock(initialState: State())

    var status: ConnectionStatus {
        state.withLock { $0.status }
    }

    var hasLostConnection: Bool {
        pluginDriver.hasLostConnection || credentialLease?.hasEnded == true
    }

    var serverVersion: String? { pluginDriver.serverVersion ?? state.withLock { $0.signInServerVersion } }
    var connectionWarning: String? { state.withLock { $0.connectionWarning } }
    var sessionLexicalState: PluginSessionLexicalState? { pluginDriver.sessionLexicalState }
    var parameterStyle: ParameterStyle { pluginDriver.parameterStyle }

    var plugin: (any PluginDatabaseDriver)? { pluginDriver }

    var sessionQueryTimeoutSeconds: Int? { effectiveQueryTimeoutSeconds }

    var queryBuildingPluginDriver: (any PluginDatabaseDriver)? {
        if state.withLock({ $0.buildsBrowseQueries }) { return pluginDriver }
        guard Self.buildsBrowseQueries(pluginDriver) else { return nil }
        state.withLock { $0.buildsBrowseQueries = true }
        return pluginDriver
    }

    // Asks the schema-aware overload: its default forwards to the older one, so it answers for a driver
    // that implements either. A driver that leaves browsing to the app returns nil from both.
    static func buildsBrowseQueries(_ driver: any PluginDatabaseDriver) -> Bool {
        driver.buildBrowseQuery(
            table: "_probe", schema: nil, sortColumns: [], columns: [], limit: 1, offset: 0
        ) != nil
    }

    var rowWritingPluginDriver: (any PluginDatabaseDriver)? {
        pluginDriver.capabilities.contains(.rowWrites) ? pluginDriver : queryBuildingPluginDriver
    }

    var primaryKeyNamesOneRow: Bool {
        !pluginDriver.capabilities.contains(.repeatingPrimaryKey)
    }

    var currentSchema: String? {
        guard pluginDriver.supportsSchemas else { return nil }
        return pluginDriver.currentSchema
    }

    var escapedSchema: String? {
        guard let schema = currentSchema else { return nil }
        return pluginDriver.escapeStringLiteral(schema)
    }

    // A read whose caller named no schema reads the connection's own; the one place a forward consults it.
    func readSchema(_ schema: String?) -> String? {
        schema ?? pluginDriver.currentSchema
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "PluginDriverAdapter")

    init(
        connection: DatabaseConnection,
        pluginDriver: any PluginDatabaseDriver,
        deadline: ConnectionDeadline? = nil,
        timeoutEndpoint: ConnectionTimeoutEndpoint? = nil,
        effectiveQueryTimeoutSeconds: Int? = nil,
        requiresHostDeadline: Bool? = nil,
        credentialLease: VaultLeaseHold? = nil
    ) {
        self.connection = connection
        self.pluginDriver = pluginDriver
        self.credentialLease = credentialLease
        self.classifier = ColumnTypeClassifier(family: SQLTypeFamily.of(connection.type))
        self.connectionDeadline = deadline ?? ConnectionDeadline(configuredSeconds: connection.connectTimeoutSeconds)
        self.timeoutEndpoint = timeoutEndpoint ?? .database(connection.timeoutEndpointName)
        self.requiresHostDeadline = requiresHostDeadline
            ?? ConnectionTimeoutPolicy.requiresHostDeadline(for: connection)
        self.effectiveQueryTimeoutSeconds = ConnectionTimeoutPolicy.effectiveQueryTimeoutSeconds(
            configuredSeconds: effectiveQueryTimeoutSeconds ?? connection.queryTimeoutSeconds,
            globalSeconds: 0
        )
        if let credentialLease {
            let connectionId = connection.id
            credentialLease.start { [weak self] remaining in
                guard let self else { return }
                let ending = CredentialLeaseEnding(connectionId: connectionId, driver: ObjectIdentifier(self), remaining: remaining)
                Task { @MainActor in
                    AppEvents.shared.credentialLeaseEnding.send(ending)
                }
            }
        }
    }

    deinit {
        credentialLease?.release()
    }

    // MARK: - Connection Management

    func connect() async throws {
        try await connectReporting(stage: { _ in })
    }

    func connectReporting(stage report: @escaping ConnectionStageReporter) async throws {
        guard state.withLock({
            $0.connectAttempt == nil && !$0.connectionMayBeOpen && !$0.disconnectInProgress
        }) else {
            throw DatabaseError.connectionFailed(String(localized: "This driver is already connecting or connected."))
        }
        if requiresHostDeadline {
            try connectionDeadline.check(endpoint: timeoutEndpoint)
        }
        let gate = ConnectionSingleResumeGate<Void>()
        let generation = state.withLock { state -> UInt64? in
            guard state.connectAttempt == nil, !state.connectionMayBeOpen, !state.disconnectInProgress else {
                return nil
            }
            state.nextConnectGeneration &+= 1
            let generation = state.nextConnectGeneration
            state.status = .connecting
            state.connectionWarning = nil
            state.signInServerVersion = nil
            state.connectAttempt = ConnectAttempt(generation: generation, gate: gate, deadline: connectionDeadline.instant)
            return generation
        }
        guard let generation else {
            throw DatabaseError.connectionFailed(String(localized: "This driver is already connecting or connected."))
        }

        let guardedReport: ConnectionStageReporter = { [weak self] stage in
            guard let self, self.isCurrentConnect(generation) else { return }
            report(stage)
        }

        let operation = Task { [self] in
            do {
                try await connectSigningIn(generation: generation, report: guardedReport)
                credentialLease?.signInAccepted()
                let adopted = gate.resume(with: .success(()))
                finishConnect(generation: generation, succeeded: true, adopted: adopted, error: nil)
            } catch {
                // Every sign-in fails here, pooled and per-database ones included, so a rejected reused password goes.
                PasswordCommandCache.shared.forget(connectionId: connection.id)
                // A user refused through the whole window is still on its way: the server may load it by the next try.
                if !(error is VaultUserNotLoaded), ConnectionFailureClassifier.isAuthenticationFailure(error) {
                    credentialLease?.signInRefused(credentials: VaultLeaseHold.isRefusedSignIn(error))
                }
                let adopted = gate.resume(with: .failure(error))
                finishConnect(generation: generation, succeeded: false, adopted: adopted, error: error)
            }
        }
        attach(operation, to: generation)

        let timeout: Task<Void, Never>?
        if requiresHostDeadline {
            timeout = Task { [self] in
                var instant = connectionDeadline.instant
                while true {
                    do {
                        try await ContinuousClock().sleep(until: instant)
                    } catch {
                        return
                    }
                    guard let later = hostDeadline(of: generation), later > instant else { break }
                    instant = later
                }
                abandonConnect(
                    generation: generation,
                    gate: gate,
                    error: connectionDeadline.timeoutError(for: timeoutEndpoint)
                )
            }
        } else {
            timeout = nil
        }

        do {
            try await withTaskCancellationHandler(
                operation: { try await gate.wait() },
                onCancel: { [self] in
                    abandonConnect(generation: generation, gate: gate, error: CancellationError())
                }
            )
            timeout?.cancel()
            await operation.value
            guard state.withLock({ $0.status == .connected && $0.connectionMayBeOpen }) else {
                throw CancellationError()
            }
            try Task.checkCancellation()
        } catch {
            timeout?.cancel()
            if error is CancellationError {
                disconnect()
            }
            state.withLock { state in
                guard let attempt = state.connectAttempt, attempt.generation == generation else { return }
                state.status = attempt.isAbandoned
                    ? .disconnected
                    : .error(error.localizedDescription)
            }
            throw error
        }
    }

    func disconnect() {
        credentialLease?.release()
        let action = state.withLock { state -> (ConnectAttempt?, Bool) in
            state.status = .disconnected
            if var attempt = state.connectAttempt {
                attempt.isAbandoned = true
                state.connectAttempt = attempt
                return (attempt, false)
            }
            guard state.connectionMayBeOpen, !state.disconnectInProgress else {
                return (nil, false)
            }
            state.connectionMayBeOpen = false
            state.disconnectInProgress = true
            return (nil, true)
        }
        if let attempt = action.0 {
            if attempt.gate.resume(with: .failure(CancellationError())) {
                attempt.task?.cancel()
            }
            return
        }
        guard action.1 else { return }
        pluginDriver.disconnect()
        state.withLock { $0.disconnectInProgress = false }
    }

    // A database can refuse a user Vault created moments ago until it loads it, so a young lease dials again.
    private func connectSigningIn(generation: UInt64, report: @escaping ConnectionStageReporter) async throws {
        guard let credentialLease else {
            try await pluginDriver.connect(reportingStage: report)
            return
        }
        try await credentialLease.dial(
            { try await pluginDriver.connect(reportingStage: report) },
            waiting: { delay in
                // The wait is the database's, not the connect's, so the host deadline moves out by it.
                moveHostDeadline(of: generation, past: delay)
                report(.custom(String(localized: "Waiting for the database to accept the new Vault user")))
            },
            isCurrent: { isCurrentConnect(generation) }
        )
    }

    private func moveHostDeadline(of generation: UInt64, past wait: Duration) {
        let instant = ContinuousClock.now + wait + .seconds(connectionDeadline.configuredSeconds)
        state.withLock { state in
            guard var attempt = state.connectAttempt, attempt.generation == generation else { return }
            attempt.deadline = max(attempt.deadline, instant)
            state.connectAttempt = attempt
        }
    }

    private func hostDeadline(of generation: UInt64) -> ContinuousClock.Instant? {
        state.withLock { state in
            guard let attempt = state.connectAttempt, attempt.generation == generation else { return nil }
            return attempt.deadline
        }
    }

    private func attach(_ task: Task<Void, Never>, to generation: UInt64) {
        let shouldCancel = state.withLock { state in
            guard var attempt = state.connectAttempt, attempt.generation == generation else {
                return true
            }
            attempt.task = task
            state.connectAttempt = attempt
            return attempt.isAbandoned
        }
        if shouldCancel {
            task.cancel()
        }
    }

    private func isCurrentConnect(_ generation: UInt64) -> Bool {
        state.withLock { state in
            guard let attempt = state.connectAttempt else { return false }
            return attempt.generation == generation && !attempt.isAbandoned
        }
    }

    private func abandonConnect(
        generation: UInt64,
        gate: ConnectionSingleResumeGate<Void>,
        error: Error
    ) {
        let won = gate.resume(with: .failure(error)) { [self] in
            state.withLock { state in
                guard var attempt = state.connectAttempt, attempt.generation == generation else { return }
                attempt.isAbandoned = true
                state.connectAttempt = attempt
            }
        }
        if won {
            let task: Task<Void, Never>? = state.withLock { state in
                guard let attempt = state.connectAttempt, attempt.generation == generation else { return nil }
                return attempt.task
            }
            task?.cancel()
        }
    }

    private func finishConnect(
        generation: UInt64,
        succeeded: Bool,
        adopted: Bool,
        error: Error?
    ) {
        let warning = succeeded ? pluginDriver.connectionWarning : nil
        let version = succeeded ? pluginDriver.serverVersion : nil
        let shouldDisconnect = state.withLock { state in
            guard let attempt = state.connectAttempt, attempt.generation == generation else {
                return false
            }
            state.connectAttempt = nil
            let keepsConnection = succeeded && adopted && !attempt.isAbandoned
            if keepsConnection {
                state.connectionMayBeOpen = true
                state.status = .connected
                state.connectionWarning = warning
                state.signInServerVersion = version
                return false
            }
            if let error, adopted {
                state.status = .error(error.localizedDescription)
            } else {
                state.status = .disconnected
            }
            guard !state.disconnectInProgress else { return false }
            state.connectionMayBeOpen = false
            state.disconnectInProgress = true
            return true
        }
        guard shouldDisconnect else { return }
        pluginDriver.disconnect()
        state.withLock { $0.disconnectInProgress = false }
    }

    @concurrent
    func ping() async throws {
        try await pluginDriver.ping()
    }

    @concurrent
    func applyQueryTimeout(_ seconds: Int) async throws {
        try await pluginDriver.applyQueryTimeout(seconds)
    }

    @concurrent
    func openSessionScope(for purpose: PluginSessionPurpose) async throws -> PluginSessionScope? {
        try await pluginDriver.openSessionScope(for: purpose)
    }

    @concurrent
    func closeSessionScope(_ scope: PluginSessionScope) async throws {
        try await pluginDriver.closeSessionScope(scope)
    }

    var releasableResourceCommandTitle: String? {
        pluginDriver.releasableResourceCommandTitle
    }

    @concurrent
    func releaseIdleResource() async throws -> PluginResourceRelease {
        try await pluginDriver.releaseIdleResource()
    }

    @concurrent
    func importExportedDatabase(from folder: URL, into file: URL) async throws {
        try await pluginDriver.importExportedDatabase(from: folder, into: file)
    }

    @concurrent
    func resolveQueryCompletionProfile(
        databaseTypeId: String,
        base: QueryCompletionProfile
    ) async throws -> QueryCompletionProfile {
        try await pluginDriver.resolveQueryCompletionProfile(
            databaseTypeId: databaseTypeId,
            base: base
        )
    }

    // MARK: - Query Execution

    // Texts this driver sent that may have left its session in another database, counted before each goes out so a
    // failed or cancelled one counts too. The host compares it with the count where it last placed the driver.
    var databaseMoves: Int { state.withLock { $0.databaseMoves } }

    // The door every text takes to the plugin: a NUL is refused, and one that may move the database is counted.
    func admit(_ statement: String) throws {
        try StatementTextValidator.validate(statement)
        noteDatabaseMoves([statement])
    }

    // An engine the classifier has no reading for is not ruled out, unless no statement can move its database at all.
    func noteDatabaseMoves(_ texts: [String]) {
        let databaseType = connection.type
        guard !texts.isEmpty,
              PluginMetadataRegistry.shared.snapshot(for: databaseType)?.capabilities.statementsCanSwitchDatabase ?? true
        else { return }
        if let dialect = SQLSessionDialect(TransactionEngineFamily.of(databaseType)) {
            let grammar = SQLLexicalResolver.readings(for: databaseType, session: pluginDriver.sessionLexicalState).execution
            guard SQLSessionStateClassifier.mayChangeDatabase(ofStatements: texts, dialect: dialect, grammar: grammar)
            else { return }
        }
        state.withLock { $0.databaseMoves += 1 }
    }

    @concurrent
    func execute(query: String) async throws -> QueryResult {
        try admit(query)
        let pluginResult = try await pluginDriver.execute(query: query, context: statementContext(query))
        return mapQueryResult(pluginResult)
    }

    @concurrent
    func executeRead(query: String) async throws -> QueryResult {
        try admit(query)
        var context = PluginStatementContext()
        context.readOnly = true
        context.lexicalFeatures = sessionLexicalFeatures
        return mapQueryResult(try await pluginDriver.execute(query: query, context: context))
    }

    func executeParameterized(query: String, parameters: [Any?]) async throws -> QueryResult {
        try await executeParameterized(query: query, parameters: parameters, context: PluginStatementContext())
    }

    func executeUserQuery(query: String, rowCap: Int?, parameters: [Any?]?) async throws -> QueryResult {
        try await executeUserQuery(query: query, rowCap: rowCap, parameters: parameters, context: PluginStatementContext())
    }

    func statementContext(_ query: String) -> PluginStatementContext {
        var context = PluginStatementContext.statement(query, databaseType: connection.type)
        context.lexicalFeatures = sessionLexicalFeatures
        return context
    }

    // How this session lexes text, so the driver binds and quotes the way the server reads it. Nil for an engine
    // nobody described, whose own backslash answer is safer than the host's ANSI guess.
    fileprivate var sessionLexicalFeatures: SQLLexicalFeatures? {
        let typeId = connection.type.rawValue
        guard SQLLexicalProfile.curated(forDatabaseTypeId: typeId) != nil
            || PluginMetadataRegistry.shared.snapshot(for: connection.type)?.editor.sqlDialect?.lexicalFeatures != nil
        else { return nil }
        return SQLLexicalResolver.readings(for: connection.type, session: pluginDriver.sessionLexicalState)
            .execution.pluginFeatures
    }


    @concurrent
    func executeBoundedQuery(query: String, rowCap: Int) async throws -> QueryResult? {
        try admit(query)
        guard let pluginResult = try await pluginDriver.executeBoundedQuery(query: query, rowCap: rowCap) else {
            return nil
        }
        return mapQueryResult(pluginResult)
    }

    var supportsResultSetBatches: Bool {
        pluginDriver.capabilities.contains(.resultSetBatches)
    }

    // The parameters are made Sendable here, on the caller's actor, so the driver call itself can leave it.
    func executeBatch(query: String, rowCap: Int?, parameters: [Any?]?) async throws -> QueryBatchResult? {
        try await executeBatch(query: query, rowCap: rowCap, cellValues: parameters?.map(Self.cellValue(for:)))
    }

    @concurrent
    private func executeBatch(query: String, rowCap: Int?, cellValues: [PluginCellValue]?) async throws -> QueryBatchResult? {
        try admit(query)
        guard let batch = try await pluginDriver.executeBatch(
            query: query,
            rowCap: rowCap,
            parameters: cellValues
        ) else {
            return nil
        }
        return QueryBatchResult(
            resultSets: batch.resultSets.map(mapQueryResult),
            rowsAffected: batch.rowsAffected,
            errors: batch.errors,
            discardedResultSetCount: batch.discardedResultSetCount,
            executionTime: batch.executionTime
        )
    }

    var supportsStatementBatches: Bool {
        pluginDriver.capabilities.contains(.statementBatches)
    }

    // Each statement is checked and described as its own call would, and one that would be refused ends the batch there.
    @concurrent
    func executeStatements(_ statements: [BatchedStatement]) async throws -> [BatchedStatementOutcome]? {
        var items: [PluginBatchStatement] = []
        var refusal: (any Error)?
        for statement in statements {
            do {
                try StatementTextValidator.validate(statement.sql)
                try refuseUnenforcedPolicy(statement.context ?? PluginStatementContext())
            } catch {
                refusal = error
                break
            }
            items.append(pluginStatement(for: statement))
        }
        guard !items.isEmpty else { return refusal.map { [.failed($0)] } }
        noteDatabaseMoves(items.map(\.query))
        guard let answered = try await pluginDriver.executeStatements(items) else { return nil }
        var outcomes: [BatchedStatementOutcome] = []
        for answer in answered.prefix(items.count) {
            outcomes.append(BatchedStatementOutcome(answer))
            guard outcomes.last?.succeeded == true else { return outcomes }
        }
        guard outcomes.count == items.count else {
            return outcomes + [.failed(DatabaseError.queryFailed(
                String(localized: "The driver did not report every statement it was sent.")
            ))]
        }
        return outcomes + (refusal.map { [.failed($0)] } ?? [])
    }

    private func pluginStatement(for statement: BatchedStatement) -> PluginBatchStatement {
        guard let parameters = statement.parameters else {
            let context = statement.context.map { statementContext(statement.sql, approvedAs: $0) }
                ?? statementContext(statement.sql)
            return PluginBatchStatement(query: statement.sql, parameters: nil, context: context)
        }
        return PluginBatchStatement(
            query: statement.sql,
            parameters: parameters.map(Self.cellValue(for:)),
            context: statementContext(
                statement.sql, approvedAs: statement.context ?? PluginStatementContext(), parameters: parameters
            )
        )
    }

    // The subject itself is read, whatever the driver wraps it in: SQL Server runs a `USE` under SHOWPLAN too.
    @concurrent
    func explainPlan(statement: String, variantId: String) async throws -> QueryResult {
        try admit(statement)
        return mapQueryResult(try await pluginDriver.explainPlan(statement: statement, variantId: variantId))
    }

    // MARK: - Schema Operations

    @concurrent
    func fetchTables(schema: String?) async throws -> [TableInfo] {
        let resolvedSchema = readSchema(schema)
        let pluginTables = try await pluginDriver.fetchTables(schema: resolvedSchema)
        return await Self.mapPluginTables(pluginTables, schemaFallback: resolvedSchema)
    }

    @concurrent
    func fetchTablesInAllSchemas() async throws -> [TableInfo]? {
        guard let pluginTables = try await pluginDriver.fetchTablesInAllSchemas() else { return nil }
        return await Self.mapPluginTables(pluginTables, schemaFallback: nil)
    }

    @concurrent
    func fetchTables(inSchemas schemas: [String]) async throws -> [TableInfo]? {
        guard let pluginTables = try await pluginDriver.fetchTables(inSchemas: schemas) else { return nil }
        let schemaFallback = schemas.count == 1 ? schemas.first : nil
        return await Self.mapPluginTables(pluginTables, schemaFallback: schemaFallback)
    }

    var listsTemporaryTables: Bool {
        pluginDriver.capabilities.contains(.temporaryTables)
    }

    @concurrent
    func fetchTemporaryTables() async throws -> [TableInfo] {
        let pluginTables = try await pluginDriver.fetchTemporaryTables()
        return await Self.mapPluginTables(pluginTables, schemaFallback: nil, isTemporary: true)
    }

    @concurrent
    func fetchPartitionDetails(table: String, schema: String?) async throws -> [PartitionInfo] {
        let resolvedSchema = readSchema(schema)
        let partitions = try await pluginDriver.fetchPartitionDetails(table: table, schema: resolvedSchema)
        return partitions.map { partition in
            let relationType = partition.relationType.flatMap(Self.mapPluginTableType)
            return PartitionInfo(
                name: partition.name,
                schema: relationType == nil ? partition.schema : (partition.schema ?? resolvedSchema),
                bound: partition.bound,
                ordinalPosition: partition.ordinalPosition,
                rowCount: partition.rowCount,
                relationType: relationType,
                isSubpartitioned: partition.isSubpartitioned,
                parentPartitionName: partition.parentPartitionName
            )
        }
    }

    /// One vocabulary for what a plugin calls an object, shared with the partition path so a
    /// foreign-table partition cannot arrive as a plain table and pick up Truncate on its way in.
    nonisolated internal static func mapPluginTableType(_ declaredType: String) -> TableInfo.TableType? {
        PluginTableKindDecoder.decode(declaredType).kind
    }

    // A listing can name every table of a large catalog, and a caller on the main actor would map it there.
    @concurrent
    nonisolated private static func mapPluginTables(
        _ tables: [PluginTableInfo],
        schemaFallback: String?,
        isTemporary: Bool = false
    ) async -> [TableInfo] {
        tables.map { mapPluginTable($0, schemaFallback: schemaFallback, isTemporary: isTemporary) }
    }

    nonisolated private static func mapPluginTable(
        _ table: PluginTableInfo,
        schemaFallback: String?,
        isTemporary: Bool
    ) -> TableInfo {
        let decoded = PluginTableKindDecoder.decode(table.type)
        let tableType: TableInfo.TableType
        if let mapped = decoded.kind {
            tableType = mapped
        } else {
            Self.logger.warning("Unknown plugin table type \"\(table.type, privacy: .public)\" for \"\(table.name, privacy: .private(mask: .hash))\"; defaulting to .table")
            tableType = .table
        }
        return TableInfo(
            name: table.name,
            type: tableType,
            rowCount: table.rowCount,
            schema: table.schema ?? schemaFallback,
            comment: table.comment,
            partitionCount: table.partitionCount,
            isSystemVersioned: decoded.isSystemVersioned,
            ownedByTable: table.ownedByTable,
            ownedByColumn: table.ownedByColumn,
            isTemporary: isTemporary
        )
    }

    @concurrent
    func fetchColumns(table: String, schema: String?) async throws -> [ColumnInfo] {
        let pluginColumns = try await pluginDriver.fetchColumns(table: table, schema: readSchema(schema))
        return pluginColumns.map(ColumnInfo.init)
    }

    @concurrent
    func fetchIndexes(table: String, schema: String?) async throws -> [IndexInfo] {
        let pluginIndexes = try await pluginDriver.fetchIndexes(
            table: table, schema: readSchema(schema)
        )
        return pluginIndexes.map(IndexInfo.init)
    }

    @concurrent
    func fetchForeignKeys(table: String, schema: String?) async throws -> [ForeignKeyInfo] {
        let pluginFKs = try await pluginDriver.fetchForeignKeys(
            table: table, schema: readSchema(schema)
        )
        return pluginFKs.map(ForeignKeyInfo.init)
    }

    @concurrent
    func fetchImmutableColumns(table: String, schema: String?) async throws -> Set<String> {
        try await pluginDriver.fetchImmutableColumns(table: table, schema: readSchema(schema))
    }

    @concurrent
    func fetchCheckConstraints(table: String, schema: String?) async throws -> [CheckConstraintInfo] {
        let pluginConstraints = try await pluginDriver.fetchCheckConstraints(
            table: table, schema: readSchema(schema)
        )
        return pluginConstraints.map(CheckConstraintInfo.init)
    }

    @concurrent
    func fetchTriggers(table: String, schema: String?) async throws -> [TriggerInfo] {
        let resolvedSchema = readSchema(schema)
        let pluginTriggers = try await pluginDriver.fetchTriggers(table: table, schema: resolvedSchema)
        return pluginTriggers.map { TriggerInfo($0.adopting(table: table, schema: resolvedSchema)) }
    }

    @concurrent
    func fetchAllTriggers(schema: String?) async throws -> [TriggerInfo] {
        let resolvedSchema = readSchema(schema)
        let pluginTriggers = try await pluginDriver.fetchAllTriggers(schema: resolvedSchema)
        return pluginTriggers.map { TriggerInfo($0.adopting(table: nil, schema: resolvedSchema)) }
    }

    @concurrent
    func fetchTriggerDDL(_ trigger: TriggerInfo) async throws -> String {
        try await pluginDriver.fetchTriggerDDL(trigger.pluginTrigger)
    }

    func createTriggerTemplate(table: String, schema: String?) -> String? {
        pluginDriver.createTriggerTemplate(table: table, schema: readSchema(schema))
    }

    @concurrent
    func fetchTriggerDefinition(name: String, table: String, schema: String?) async throws -> String? {
        try await pluginDriver.fetchTriggerDefinition(name: name, table: table, schema: readSchema(schema))
    }

    func generateDropTriggerSQL(name: String, table: String, schema: String?) -> String? {
        pluginDriver.generateDropTriggerSQL(name: name, table: table, schema: readSchema(schema))
    }

    var triggerEditUsesReplace: Bool { pluginDriver.triggerEditUsesReplace }

    var supportsTransactionalDDL: Bool { pluginDriver.supportsTransactionalDDL }

    var unsupportedStructureColumnFields: Set<StructureColumnField> { pluginDriver.unsupportedStructureColumnFields }

    var unsupportedIndexTypes: Set<String> { pluginDriver.unsupportedIndexTypes }

    var checkConstraintRefusal: String? { pluginDriver.checkConstraintRefusal }

    // A raw condition is text the user wrote, which the driver writes into its count.
    private func noteRawFilterMoves(_ filters: [PluginQueryFilter]) {
        noteDatabaseMoves(filters.filter { $0.column == TableFilter.rawSQLColumn }.map(\.value))
    }

    @concurrent
    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        try await pluginDriver.fetchApproximateRowCount(
            table: table, schema: readSchema(schema)
        )
    }

    @concurrent
    func fetchFilteredRowCount(table: String, filters: [TableFilter], logicMode: FilterLogicMode) async throws -> Int? {
        guard !FilterSQLGenerator.withholdsFromDriver(filters, databaseType: connection.type) else { return nil }
        let queryFilters = filters
            .filter { $0.isEnabled && !$0.columnName.isEmpty }
            .map(\.asPluginQueryFilter)
        noteRawFilterMoves(queryFilters)
        return try await pluginDriver.fetchFilteredRowCount(
            table: table,
            queryFilters: queryFilters,
            logicMode: logicMode == .and ? "and" : "or"
        )
    }

    @concurrent
    func fetchExactRowCount(
        table: String,
        schema: String?,
        filters: [TableFilter],
        logicMode: FilterLogicMode
    ) async throws -> Int? {
        guard !FilterSQLGenerator.withholdsFromDriver(filters, databaseType: connection.type) else { return nil }
        let queryFilters = filters
            .filter { $0.isEnabled && !$0.columnName.isEmpty }
            .map(\.asPluginQueryFilter)
        noteRawFilterMoves(queryFilters)
        return try await pluginDriver.fetchExactRowCount(
            table: table,
            schema: readSchema(schema),
            queryFilters: queryFilters,
            logicMode: logicMode == .and ? "and" : "or"
        )
    }

    @concurrent
    func fetchExactRowCount(table: String, schema: String?, browseFilters: [PluginQueryFilter]) async throws -> Int? {
        noteRawFilterMoves(browseFilters)
        return try await pluginDriver.fetchExactRowCount(
            table: table,
            schema: readSchema(schema),
            queryFilters: browseFilters,
            logicMode: "and"
        )
    }

    @concurrent
    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        try await pluginDriver.fetchTableDDL(table: table, schema: readSchema(schema))
    }

    @concurrent
    func fetchIndexDDL(table: String, schema: String?) async throws -> [String] {
        try await pluginDriver.fetchIndexDDL(table: table, schema: readSchema(schema))
    }

    @concurrent
    func fetchCommentDDL(table: String, schema: String?) async throws -> [String] {
        try await pluginDriver.fetchCommentDDL(table: table, schema: readSchema(schema))
    }

    @concurrent
    func fetchDependentTypes(forTable table: String, schema: String?) async throws -> [(name: String, labels: [String])] {
        try await pluginDriver.fetchDependentTypes(table: table, schema: readSchema(schema))
    }

    @concurrent
    func fetchDependentSequences(forTable table: String, schema: String?) async throws -> [(name: String, ddl: String)] {
        try await pluginDriver.fetchDependentSequences(table: table, schema: readSchema(schema))
    }

    @concurrent
    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        try await pluginDriver.fetchViewDefinition(view: view, schema: readSchema(schema))
    }

    @concurrent
    func fetchTableMetadata(tableName: String, schema: String?) async throws -> TableMetadata {
        let pluginMeta = try await pluginDriver.fetchTableMetadata(
            table: tableName,
            schema: readSchema(schema)
        )
        return TableMetadata(pluginMeta)
    }

    @concurrent
    func fetchObjectComment(tableName: String, schema: String?) async throws -> String? {
        try await pluginDriver.fetchObjectComment(table: tableName, schema: readSchema(schema))
    }

    @concurrent
    func fetchDatabases() async throws -> [String] {
        try await pluginDriver.fetchDatabases()
    }

    @concurrent
    func fetchSchemas() async throws -> [String] {
        try await pluginDriver.fetchSchemas()
    }

    @concurrent
    func fetchExternalSchemaNames() async throws -> Set<String> {
        try await pluginDriver.fetchExternalSchemaNames()
    }

    @concurrent
    func fetchRoutines(schema: String?) async throws -> [RoutineInfo] {
        let resolvedSchema = readSchema(schema)
        do {
            let pluginRoutines = try await pluginDriver.fetchRoutines(schema: resolvedSchema)
            return pluginRoutines.map { RoutineInfo($0.adopting(kind: $0.kind, schema: resolvedSchema)) }
                .sorted { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }
        } catch {
            Self.logger.warning("fetchRoutines failed: \(error.publicLogShape, privacy: .public)")
            throw error
        }
    }

    @concurrent
    func fetchRoutineDDL(_ routine: RoutineInfo) async throws -> String {
        try await pluginDriver.fetchRoutineDDL(routine.pluginRoutine)
    }

    /// The resolved schema is stamped on any type that came back without one, the same backfill
    /// `fetchRoutines` does above. A driver that leaves it nil produces types whose qualified name
    /// is bare, which the sidebar then files under no schema at all.
    @concurrent
    func fetchUserDefinedTypes(schema: String?) async throws -> [UserDefinedTypeInfo] {
        let resolvedSchema = readSchema(schema)
        do {
            return try await pluginDriver.fetchUserDefinedTypes(schema: resolvedSchema)
                .map { UserDefinedTypeInfo($0.adoptingSchema(resolvedSchema)) }
                .sorted { $0.name < $1.name }
        } catch {
            Self.logger.warning("fetchUserDefinedTypes failed: \(error.publicLogShape, privacy: .public)")
            throw error
        }
    }

    /// Only a one-schema list can stamp a schema on a type that came back without one.
    @concurrent
    func fetchUserDefinedTypes(inSchemas schemas: [String]) async throws -> [UserDefinedTypeInfo]? {
        let schemaFallback = schemas.count == 1 ? schemas.first : nil
        do {
            guard let types = try await pluginDriver.fetchUserDefinedTypes(inSchemas: schemas) else { return nil }
            return types
                .map { UserDefinedTypeInfo($0.adoptingSchema(schemaFallback)) }
                .sorted { ($0.schema ?? "", $0.name) < ($1.schema ?? "", $1.name) }
        } catch {
            Self.logger.warning("fetchUserDefinedTypes(inSchemas:) failed: \(error.publicLogShape, privacy: .public)")
            throw error
        }
    }

    @concurrent
    func fetchUserDefinedType(_ type: UserDefinedTypeInfo) async throws -> UserDefinedTypeInfo {
        UserDefinedTypeInfo(try await pluginDriver.fetchUserDefinedType(type.pluginType))
    }

    func generateDropTypeSQL(type: UserDefinedTypeInfo, cascade: Bool) -> String? {
        pluginDriver.generateDropTypeSQL(type: type.pluginType, cascade: cascade)
    }

    func createUserDefinedTypeStatements(_ definition: PluginUserDefinedTypeDefinition) -> [String]? {
        pluginDriver.createUserDefinedTypeStatements(definition)
    }

    func alterUserDefinedTypeStatements(type: UserDefinedTypeInfo, change: PluginUserDefinedTypeChange) -> [String]? {
        pluginDriver.alterUserDefinedTypeStatements(type: type.pluginType, change: change)
    }

    func userDefinedTypeChangeRunsOutsideTransaction(_ change: PluginUserDefinedTypeChange) -> Bool {
        pluginDriver.userDefinedTypeChangeRunsOutsideTransaction(change)
    }

    @concurrent
    func fetchDatabaseMetadata(_ database: String) async throws -> DatabaseMetadata {
        let pluginMeta = try await pluginDriver.fetchDatabaseMetadata(database)
        return Self.databaseMetadata(pluginMeta, systemDatabaseNames: systemDatabaseNames)
    }

    @concurrent
    func createDatabaseFormSpec() async throws -> CreateDatabaseFormSpec? {
        guard let pluginSpec = try await pluginDriver.createDatabaseFormSpec() else { return nil }
        return mapFormSpec(pluginSpec)
    }

    @concurrent
    func createDatabase(_ request: CreateDatabaseRequest) async throws {
        let pluginRequest = PluginCreateDatabaseRequest(name: request.name, values: request.values)
        try await pluginDriver.createDatabase(pluginRequest)
    }

    @concurrent
    func dropDatabase(name: String) async throws {
        try await pluginDriver.dropDatabase(name: name)
    }

    @concurrent
    func dropSchema(name: String) async throws {
        try await pluginDriver.dropSchema(name: name)
    }

    @concurrent
    func renameTable(name: String, schema: String?, to newName: String, objectType: String) async throws {
        try await pluginDriver.renameTable(name: name, schema: schema, to: newName, objectType: objectType)
    }

    @concurrent
    func renameDatabase(name: String, to newName: String) async throws {
        try await pluginDriver.renameDatabase(name: name, to: newName)
    }

    @concurrent
    func renameSchema(name: String, to newName: String) async throws {
        try await pluginDriver.renameSchema(name: name, to: newName)
    }

    func documentWriteStatement(_ write: PluginDocumentWrite) throws -> String? {
        try pluginDriver.documentWriteStatement(write)
    }

    @concurrent
    func executeDocumentWrite(_ write: PluginDocumentWrite) async throws {
        try await pluginDriver.executeDocumentWrite(write)
    }

    @concurrent
    func fetchDocument(table: String, schema: String?, locator: String) async throws -> String? {
        try await pluginDriver.fetchDocument(table: table, schema: schema, locator: locator)
    }

    func createSchemaStatements(_ definition: PluginSchemaDefinition) -> [String]? {
        pluginDriver.createSchemaStatements(definition)
    }

    func renameSchemaStatements(name: String, to newName: String) -> [String]? {
        pluginDriver.renameSchemaStatements(name: name, to: newName)
    }

    func alterSchemaStatements(
        from current: PluginSchemaDetails,
        to target: PluginSchemaDefinition
    ) -> [String]? {
        pluginDriver.alterSchemaStatements(from: current, to: target)
    }

    @concurrent
    func fetchSchemaDetails(name: String) async throws -> PluginSchemaDetails? {
        try await pluginDriver.fetchSchemaDetails(name: name)
    }

    @concurrent
    func fetchSessionContexts() async throws -> [PluginSessionContext]? {
        try await pluginDriver.fetchSessionContexts()
    }

    @concurrent
    func switchSessionContext(id: String, to value: String) async throws {
        try await pluginDriver.switchSessionContext(id: id, to: value)
    }

    // MARK: - Batch Operations

    @concurrent
    func sampleFieldPaths(table: String, schema: String?, limit: Int) async throws -> [PluginFieldPath] {
        try await pluginDriver.sampleFieldPaths(table: table, schema: readSchema(schema), limit: limit)
    }

    var providesBulkColumnFetch: Bool { pluginDriver.providesBulkColumnFetch }

    var fetchesAllColumnsInOneRequest: Bool { pluginDriver.fetchesAllColumnsInOneRequest }

    @concurrent
    func fetchAllColumns(schema: String?) async throws -> [CatalogName: [ColumnInfo]] {
        let schema = readSchema(schema)
        do {
            return try await pluginDriver.fetchAllColumns(schema: schema).keyedByCatalogName
                .mapValues { $0.map(ColumnInfo.init) }
        } catch is PluginCatalogNameCollision {
            return try await readEachTable(in: schema) { table in
                try await pluginDriver.fetchColumns(table: table, schema: schema).map(ColumnInfo.init)
            }
        }
    }

    var providesBulkForeignKeyFetch: Bool { pluginDriver.providesBulkForeignKeyFetch }

    @concurrent
    func fetchAllForeignKeys(schema: String?) async throws -> [CatalogName: [ForeignKeyInfo]] {
        let schema = readSchema(schema)
        do {
            return try await pluginDriver.fetchAllForeignKeys(schema: schema).keyedByCatalogName
                .mapValues { $0.map(ForeignKeyInfo.init) }
        } catch is PluginCatalogNameCollision {
            return try await readEachTable(in: schema) { table in
                let keys = try await pluginDriver.fetchForeignKeys(table: table, schema: schema)
                return keys.isEmpty ? nil : keys.map(ForeignKeyInfo.init)
            }
        }
    }

    // The schema-wide answer named two objects Swift's String equates, so each listed object is read alone. A table that
    // cannot be read fails the read, as the schema-wide one would have.
    private func readEachTable<Value>(
        in schema: String?,
        _ read: (String) async throws -> Value?
    ) async throws -> [CatalogName: Value] {
        var result: [CatalogName: Value] = [:]
        for table in try await pluginDriver.fetchTables(schema: schema) {
            try Task.checkCancellation()
            if let value = try await read(table.name) { result[CatalogName(table.name)] = value }
        }
        return result
    }

    @concurrent
    func fetchAllDatabaseMetadata() async throws -> [DatabaseMetadata] {
        let pluginResult = try await pluginDriver.fetchAllDatabaseMetadata()
        let systemNames = systemDatabaseNames
        return pluginResult.map { Self.databaseMetadata($0, systemDatabaseNames: systemNames) }
    }

    /// The connection type's own list, added to whatever the driver reports. SQL Server and ClickHouse
    /// never set the flag, and MySQL leaves it off for a database with no readable tables, so trusting
    /// the flag alone listed `master` and `msdb` as user databases once the switcher's metadata landed,
    /// while the sidebar, classifying by the same list as here, kept them apart.
    private var systemDatabaseNames: Set<String> {
        Set(PluginMetadataRegistry.shared.snapshot(for: connection.type)?.schema.systemDatabaseNames ?? [])
    }

    nonisolated static func databaseMetadata(
        _ pluginMeta: PluginDatabaseMetadata,
        systemDatabaseNames: Set<String>
    ) -> DatabaseMetadata {
        let isSystem = pluginMeta.isSystemDatabase || systemDatabaseNames.contains(pluginMeta.name)
        return DatabaseMetadata(
            id: pluginMeta.name,
            name: pluginMeta.name,
            tableCount: pluginMeta.tableCount,
            sizeBytes: pluginMeta.sizeBytes,
            lastAccessed: nil,
            isSystemDatabase: isSystem,
            icon: isSystem ? "gearshape" : "cylinder"
        )
    }

    // MARK: - Query Cancellation

    func cancelQuery() throws {
        try pluginDriver.cancelQuery()
    }

    // MARK: - Server Output

    @concurrent
    func fetchServerOutput() async throws -> PluginServerOutput {
        try await pluginDriver.fetchServerOutput()
    }

    // MARK: - Schema Switching

    @concurrent
    func switchSchema(to schema: String) async throws {
        try await pluginDriver.switchSchema(to: schema)
    }

    // MARK: - Database Switching

    var currentDatabase: String? {
        pluginDriver.currentDatabase
    }

    // MARK: - Definition SQL (clipboard copy)

    func generateColumnDefinitionSQL(column: PluginColumnDefinition) -> String? {
        pluginDriver.generateColumnDefinitionSQL(column: column)
    }

    func generateIndexDefinitionSQL(index: PluginIndexDefinition, tableName: String?) -> String? {
        pluginDriver.generateIndexDefinitionSQL(index: index, tableName: tableName)
    }

    func generateForeignKeyDefinitionSQL(fk: PluginForeignKeyDefinition) -> String? {
        pluginDriver.generateForeignKeyDefinitionSQL(fk: fk)
    }

    // MARK: - Table Operations

    /// Nil where the engine has no way to say it. The driver's own answer wins; the app builds the
    /// statement only for an engine whose DDL it can actually write, per `SQLDDLFallbackPolicy`.
    func truncateTableStatements(table: String, schema: String?, cascade: Bool) -> [String]? {
        if let stmts = pluginDriver.truncateTableStatements(table: table, schema: schema, cascade: cascade) {
            return stmts
        }
        guard allowsGeneratedDDL else { return nil }
        let name = qualifiedName(table, schema: schema)
        let cascadeSuffix = cascade ? " CASCADE" : ""
        return ["TRUNCATE TABLE \(name)\(cascadeSuffix)"]
    }

    func dropObjectStatement(name: String, objectType: String, schema: String?, cascade: Bool) -> String? {
        if let stmt = pluginDriver.dropObjectStatement(name: name, objectType: objectType, schema: schema, cascade: cascade) {
            return stmt
        }
        guard allowsGeneratedDDL else { return nil }
        let qualName = qualifiedName(name, schema: schema)
        let cascadeSuffix = cascade ? " CASCADE" : ""
        return "DROP \(objectType) \(qualName)\(cascadeSuffix)"
    }

    private var allowsGeneratedDDL: Bool {
        SQLDDLFallbackPolicy.allowsGeneratedDDL(for: connection.type)
    }

    func foreignKeyDisableStatements() -> [String]? {
        pluginDriver.foreignKeyDisableStatements()
    }

    func foreignKeyEnableStatements() -> [String]? {
        pluginDriver.foreignKeyEnableStatements()
    }

    func rowUpdateStatement(table: String, assignments: String, predicate: String) -> String? {
        pluginDriver.rowUpdateStatement(table: table, assignments: assignments, predicate: predicate)
    }

    func rowDeleteStatement(table: String, predicate: String?) -> String? {
        pluginDriver.rowDeleteStatement(table: table, predicate: predicate)
    }

    // MARK: - Identifier Quoting

    func quoteIdentifier(_ name: String) -> String {
        pluginDriver.quoteIdentifier(name)
    }

    func escapeStringLiteral(_ value: String) -> String {
        pluginDriver.escapeStringLiteral(value)
    }

    // MARK: - Private Helpers

    private func qualifiedName(_ name: String, schema: String?) -> String {
        SchemaQualifiedName.render(
            name: name, schema: schema, databaseType: connection.type, quote: pluginDriver.quoteIdentifier
        )
    }

    // MARK: - Result Mapping

    func mapQueryResult(_ pluginResult: PluginQueryResult) -> QueryResult {
        let columnTypes = mapColumnTypes(
            rawTypeNames: pluginResult.columnTypeNames,
            classificationHints: PluginResultColumnHints.hints(
                from: pluginResult.columnMeta,
                columnCount: pluginResult.columns.count
            )
        )
        var result = QueryResult(
            columns: pluginResult.columns,
            columnTypes: columnTypes,
            rows: pluginResult.rows,
            rowsAffected: pluginResult.rowsAffected,
            executionTime: pluginResult.executionTime,
            error: nil
        )
        result.isTruncated = pluginResult.isTruncated
        result.statusMessage = pluginResult.statusMessage
        result.timing = pluginResult.timing
        result.columnMeta = pluginResult.columnMeta?.map {
            ResultColumnMeta(isPrimaryKey: $0.isPrimaryKey, isNullable: $0.isNullable, isAutoIncrement: $0.isIdentity)
        }
        result.rowLocators = pluginResult.rowLocators
        result.columnOrigins = pluginResult.columnOrigins
        result.exportDocuments = pluginResult.exportDocuments
        result.absentCells = pluginResult.absentCells ?? [:]
        return result
    }

    private func mapColumnTypes(rawTypeNames: [String], classificationHints: [String?]) -> [ColumnType] {
        state.withLock { state in
            rawTypeNames.enumerated().map { index, rawTypeName in
                let hint = index < classificationHints.count ? classificationHints[index] : nil
                guard let hint else { return classified(rawTypeName, cache: &state.columnTypeCache) }
                return classified(hint, cache: &state.columnTypeCache).declared(as: rawTypeName)
            }
        }
    }

    private func classified(_ typeName: String, cache: inout [String: ColumnType]) -> ColumnType {
        if let cached = cache[typeName] { return cached }
        let mapped = classifier.classify(rawTypeName: typeName)
        cache[typeName] = mapped
        return mapped
    }
}

private extension PluginDriverAdapter {
    func mapFormSpec(_ spec: PluginCreateDatabaseFormSpec) -> CreateDatabaseFormSpec {
        CreateDatabaseFormSpec(
            fields: spec.fields.map(mapFormField),
            footnote: spec.footnote,
            textInputs: spec.textInputs.map(mapTextInput)
        )
    }

    func mapTextInput(_ input: PluginCreateDatabaseFormSpec.TextInput) -> CreateDatabaseFormSpec.TextInput {
        CreateDatabaseFormSpec.TextInput(
            id: input.id,
            label: input.label,
            placeholder: input.placeholder,
            isRequired: input.isRequired
        )
    }

    func mapFormField(_ field: PluginCreateDatabaseFormSpec.Field) -> CreateDatabaseFormSpec.Field {
        CreateDatabaseFormSpec.Field(
            id: field.id,
            label: field.label,
            kind: mapFieldKind(field.kind),
            visibleWhen: field.visibleWhen.map(mapVisibility),
            groupedBy: field.groupedBy
        )
    }

    func mapFieldKind(_ kind: PluginCreateDatabaseFormSpec.FieldKind) -> CreateDatabaseFormSpec.FieldKind {
        switch kind {
        case .picker(let options, let defaultValue):
            return .picker(options: options.map(mapOption), defaultValue: defaultValue)
        case .searchable(let options, let defaultValue):
            return .searchable(options: options.map(mapOption), defaultValue: defaultValue)
        }
    }

    func mapOption(_ option: PluginCreateDatabaseFormSpec.Option) -> CreateDatabaseFormSpec.Option {
        CreateDatabaseFormSpec.Option(
            value: option.value,
            label: option.label,
            subtitle: option.subtitle,
            group: option.group
        )
    }

    func mapVisibility(_ visibility: PluginCreateDatabaseFormSpec.Visibility) -> CreateDatabaseFormSpec.Visibility {
        CreateDatabaseFormSpec.Visibility(fieldId: visibility.fieldId, equals: visibility.equals)
    }
}

// MARK: - Statements an external caller approved

extension PluginDriverAdapter {
    @concurrent
    func execute(query: String, context: PluginStatementContext) async throws -> QueryResult {
        try admit(query)
        try refuseUnenforcedPolicy(context)
        let pluginResult = try await pluginDriver.execute(query: query, context: statementContext(query, approvedAs: context))
        return mapQueryResult(pluginResult)
    }

    var runsReadOnlyStatements: Bool {
        pluginDriver.capabilities.contains(.readOnlyStatements)
    }

    // `[Any?]` is not Sendable, so only its conversion stays on the caller's actor; the checks, the statement's
    // description and the driver call leave it with the Sendable values.
    func executeParameterized(
        query: String,
        parameters: [Any?],
        context: PluginStatementContext
    ) async throws -> QueryResult {
        try await executeParameterized(
            query: query,
            cellValues: parameters.map(Self.cellValue(for:)),
            parameterKinds: TypedParameterValue.kinds(of: parameters),
            context: context
        )
    }

    @concurrent
    private func executeParameterized(
        query: String,
        cellValues: [PluginCellValue],
        parameterKinds: [PluginColumnKind?]?,
        context: PluginStatementContext
    ) async throws -> QueryResult {
        try admit(query)
        try refuseUnenforcedPolicy(context)
        let pluginResult = try await pluginDriver.executeParameterized(
            query: query,
            parameters: cellValues,
            context: statementContext(query, approvedAs: context, parameterKinds: parameterKinds)
        )
        return mapQueryResult(pluginResult)
    }

    func executeUserQuery(
        query: String,
        rowCap: Int?,
        parameters: [Any?]?,
        context: PluginStatementContext
    ) async throws -> QueryResult {
        try await executeUserQuery(
            query: query,
            rowCap: rowCap,
            cellValues: parameters?.map(Self.cellValue(for:)),
            parameterKinds: TypedParameterValue.kinds(of: parameters),
            context: context
        )
    }

    @concurrent
    private func executeUserQuery(
        query: String,
        rowCap: Int?,
        cellValues: [PluginCellValue]?,
        parameterKinds: [PluginColumnKind?]?,
        context: PluginStatementContext
    ) async throws -> QueryResult {
        try admit(query)
        try refuseUnenforcedPolicy(context)
        let pluginResult = try await pluginDriver.executeUserQuery(
            query: query,
            rowCap: rowCap,
            parameters: cellValues,
            context: statementContext(query, approvedAs: context, parameterKinds: parameterKinds)
        )
        return mapQueryResult(pluginResult)
    }

    func statementContext(_ query: String, approvedAs caller: PluginStatementContext, parameters: [Any?]? = nil) -> PluginStatementContext {
        statementContext(query, approvedAs: caller, parameterKinds: TypedParameterValue.kinds(of: parameters))
    }

    func statementContext(
        _ query: String,
        approvedAs caller: PluginStatementContext,
        parameterKinds: [PluginColumnKind?]?
    ) -> PluginStatementContext {
        var context = PluginStatementContext.statement(query, databaseType: connection.type, approvedAs: caller)
        context.lexicalFeatures = sessionLexicalFeatures
        context.parameterKinds = parameterKinds ?? context.parameterKinds
        return context
    }

    // A driver built before `.statementPolicy` would run an external write the approval did not cover.
    func refuseUnenforcedPolicy(_ context: PluginStatementContext) throws {
        guard context.origin == .external, !context.readOnly,
              !context.allowsDestructive || !context.allowsServerCode,
              PluginMetadataRegistry.shared.snapshot(for: connection.type)?.capabilities.statementPolicyInDriver == true,
              !pluginDriver.capabilities.contains(.statementPolicy)
        else { return }
        throw ExternalStatementGateError.denied(
            String(
                format: String(localized: "Update the %@ driver in Settings > Extensions to run this from an external client."),
                connection.type.rawValue
            )
        )
    }
}
