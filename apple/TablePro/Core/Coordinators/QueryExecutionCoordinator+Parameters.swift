//
//  QueryExecutionCoordinator+Parameters.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit
import TableProSQLGrammar

private let paramLog = Logger(subsystem: "com.TablePro", category: "QueryParameters")

/// One statement of a multi-statement run, resolved before the transaction opens so the
/// lease holds nothing but driver work.
/// Carries the driver-bound parameter values into the scoped-driver closure. The values are
/// handed to the driver and never touched again by the caller, which is what `[Any?]` hides.
private struct BoundParameterValues: @unchecked Sendable {
    let values: [Any?]
}

/// What one multi-statement run left behind, and the plan it actually ran under.
///
/// The plan is decided twice: from the statement text before any driver is leased, and again inside
/// the lease, where the driver can say what the session is already holding. Only the second answer
/// ran, so the failure banner and the status line are written from it.
private struct MultiStatementRun {
    var outcome: BatchStatementOutcome<QueryResult>
    let plan: BatchTransactionPlan
    let sessionState: PluginSessionTransactionState
    let startState: PluginSessionTransactionState
    /// What the session held once the run ended, asked of a run that joined the session's
    /// transaction or drops or renames a table, and `.unknown` for any other.
    let endState: PluginSessionTransactionState
    var failureOutput: PluginServerOutput = .none
}

private struct PreparedStatement: @unchecked Sendable {
    let originalSQL: String
    let executableSQL: String
    /// `executableSQL` with the LIMIT an engine that caps its rows is always sent. Kept apart
    /// because Fetch All re-runs `executableSQL`, and re-running the limited text would fetch the
    /// same trimmed rows again.
    let sentSQL: String
    let parameterValues: [Any?]?
    let rowCap: Int?
    let anchor: StatementAnchor?
    /// Where the script was cut after this statement, which a replan of the rest starts from.
    let statement: SQLStatementScanner.ExecutableStatement?
    /// Whether this is the script's own `COMMIT`, read from the text before the lease is taken so
    /// the run never lexes inside it.
    let isCommitPoint: Bool
}

// What a run sends: the rest is cut again from the script once a statement changes how the session reads literals.
@MainActor
private final class RunningStatements {
    private(set) var prepared: [PreparedStatement]
    private var grammar: SQLLexicalGrammar
    private let script: String?
    private let end: Int
    private let prepare: @MainActor (SQLStatementScanner.ExecutableStatement, SQLLexicalGrammar) -> PreparedStatement

    init(
        prepared: [PreparedStatement],
        grammar: SQLLexicalGrammar,
        script: String?,
        end: Int,
        prepare: @escaping @MainActor (SQLStatementScanner.ExecutableStatement, SQLLexicalGrammar) -> PreparedStatement
    ) {
        self.prepared = prepared
        self.grammar = grammar
        self.script = script
        self.end = end
        self.prepare = prepare
    }

    func replanned(after ran: Int, session: SQLLexicalGrammar) -> [PreparedStatement]? {
        guard session != grammar, let script, prepared.indices.contains(ran - 1),
              let last = prepared[ran - 1].statement
        else { return nil }
        let rest = QueryExecutionCoordinator.remainingStatements(
            in: script, after: last, through: end, grammar: session
        ).map { prepare($0, session) }
        grammar = session
        prepared = Array(prepared.prefix(ran)) + rest
        return rest
    }
}

/// What a run has to write into query history, held together so the recording can happen below the
/// settle gate rather than beside the result sets.
///
/// A batch that was stopped, or superseded by a navigation, has its results dropped there. History
/// used to be written above the gate, so a stopped run recorded every statement as successful while
/// the tab reported it as stopped, which is not what the single-statement path does.
private struct ExecutedStatementHistory {
    let prepared: [PreparedStatement]
    let results: [QueryResult]
    let parameters: [QueryParameter]
    let connection: DatabaseConnection

    func keeping(_ kept: [QueryResult]) -> ExecutedStatementHistory {
        ExecutedStatementHistory(prepared: prepared, results: kept, parameters: parameters, connection: connection)
    }
}

extension BatchStatementOutcome {
    // The units a run the user stopped keeps: those that completed, and none that its plan rolled back.
    func keptAfterStop(plan: BatchTransactionPlan) -> [Output] {
        switch self {
        case .completed(let results), .cancelled(let results):
            return results
        case .failed(_, .commitOutcomeUnknown, _):
            // Nothing can say whether these were saved, so they are not recorded as plain successes.
            return []
        case .failed(let results, _, _):
            return plan.keepsExecutedStatements ? Array(results.prefix(succeededCount)) : []
        }
    }

    var leftCommitOutcomeUnknown: Bool {
        guard case .failed(_, .commitOutcomeUnknown, _) = self else { return false }
        return true
    }
}

extension QueryExecutionCoordinator {
    func detectAndReconcileParameters(sql: String, existing: [QueryParameter]) -> [QueryParameter] {
        QueryExecutor.detectAndReconcileParameters(sql: sql, existing: existing, grammar: parent.lexicalGrammar)
    }

    func executeQueryWithParameters(
        _ sql: String,
        parameters: [QueryParameter],
        bypassRowLimit: Bool = false,
        anchor: StatementAnchor? = nil,
        install: ResultInstall = .newResult,
        onTab target: UUID? = nil
    ) {
        guard let (_, index) = parent.executionTab(target) else { return }

        let missing = parameters.filter {
            !$0.isNull && $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let firstMissing = missing.first {
            parent.tabManager.mutate(at: index) {
                $0.execution.errorMessage = String(
                    format: String(localized: "Missing value for parameter: %@"),
                    ":\(firstMissing.name)"
                )
            }
            return
        }

        let style = PluginMetadataRegistry.shared.snapshot(
            for: parent.connection.type
        )?.parameterStyle ?? .questionMark
        let conversion = SQLParameterExtractor.convertToNativeStyle(
            sql: sql,
            parameters: parameters,
            style: style,
            grammar: parent.lexicalGrammar
        )

        paramLog.info("Executing parameterized query: \(conversion.sql.prefix(100), privacy: .private) with \(conversion.values.count) parameters")

        executeQueryInternalParameterized(
            conversion.sql,
            parameters: conversion.values,
            originalParameters: parameters,
            bypassRowLimit: bypassRowLimit,
            originalSQL: sql,
            anchor: anchor,
            install: install,
            onTab: target
        )
    }

    /// The query runs on the tab's own database, not on wherever the connection's shared
    /// driver happens to be pointing.
    func executeQueryInternalParameterized(
        _ sql: String,
        parameters: [Any?],
        originalParameters: [QueryParameter],
        bypassRowLimit: Bool = false,
        originalSQL: String? = nil,
        anchor: StatementAnchor? = nil,
        install: ResultInstall = .newResult,
        onTab target: UUID? = nil
    ) {
        guard let (selectedTab, index) = parent.executionTab(target),
              !parent.tabExecution.isExecuting(selectedTab.id) else { return }

        guard let scope = parent.scope(for: selectedTab) else {
            parent.tabManager.mutate(at: index) {
                $0.execution.errorMessage = String(localized: "Not connected to database")
            }
            return
        }

        parent.tabManager.mutate(at: index) { tab in
            tab.execution.executionTime = nil
            tab.execution.errorMessage = nil
        }
        let tab = parent.tabManager.tabs[index]

        let conn = parent.connection
        let tabId = parent.tabManager.tabs[index].id
        let (claim, lease) = parent.beginTabExecution(for: tabId)

        let statement = resolveStatement(sql: sql, tabType: tab.tabType, bypassLimit: bypassRowLimit)
        let rowCap = statement.rowCap
        let (tableName, isEditable) = parent.resolveTableEditability(tab: tab, sql: sql)

        let needsMetadataFetch: Bool
        if isEditable, let tableName {
            needsMetadataFetch = !isMetadataCached(tabId: tabId, tableName: tableName)
        } else {
            needsMetadataFetch = false
        }
        /// Captured now, while the result this decision was made against is still the active one.
        let cachedMetadata: ParsedSchemaMetadata? = needsMetadataFetch ? nil : ParsedSchemaMetadata.cached(
            rows: parent.tabSessionRegistry.tableRows(for: tabId),
            context: tab.tableContext
        )

        let readsView = tab.tableContext.knowsView(named: tableName)
        let boundValues = BoundParameterValues(values: parameters)
        let failureOutput = ServerOutputBox()
        let grammar = parent.lexicalGrammar
        let safeModeIsReadOnly = parent.runsAtReadOnly
        let held = parent.manualCommitRun(skipped: tab.tabType != .query)
        let parameterizedTask = Task { [weak self, parent] in
            guard let self else { return }

            let schemaTask = parent.startSchemaFetch(
                tableName, uncached: needsMetadataFetch, isView: readsView, scope: scope
            )

            do {
                let (fetchResult, tableEdits) = try await DatabaseManager.shared.withScopedDriver(
                    scope: scope,
                    route: DatabaseManager.shared.executionRoute(for: scope),
                    cancellation: .cancellableRead(lease)
                ) { [queryExecutor = parent.queryExecutor, boundValues] driver in
                    let fetched = try await held.running([statement.sql], on: driver) {
                        // Before it runs, so a statement that fails or a connection lost under it is still noted.
                        await DatabaseManager.shared.noteSessionStatements([statement.sql], ranOn: driver, scope: scope)
                        return try await queryExecutor.executeQuery(
                            driver: driver,
                            sql: statement.sql,
                            parameters: boundValues.values,
                            rowCap: rowCap,
                            safeModeIsReadOnly: safeModeIsReadOnly,
                            capturingOutputInto: failureOutput
                        )
                    }
                    let edits = await SucceededStatements.single(
                        statement.sql, scope: scope, databaseType: conn.type, grammar: grammar, ranOn: driver
                    )
                    return (fetched, edits)
                }
                MainContentCoordinator.postStatementRan(statement.sql, on: conn, succeeded: tableEdits)

                guard !Task.isCancelled else {
                    schemaTask?.cancel()
                    await parent.resetExecutionState(claim: claim, executionTime: fetchResult.executionTime)
                    return
                }

                let inlineMeta = needsMetadataFetch
                    ? QueryExecutor.inlineMetadata(from: fetchResult.resultColumnMeta, columns: fetchResult.columns)
                    : nil

                let applied = await applyParameterizedResult(
                    tabId: tabId,
                    fetchResult: fetchResult,
                    inlineMetadata: inlineMeta ?? cachedMetadata,
                    tableName: tableName,
                    isEditable: isEditable,
                    sql: sql,
                    connection: conn,
                    claim: claim,
                    originalParameters: originalParameters,
                    nativeParameters: parameters,
                    originalSQL: originalSQL,
                    anchor: anchor,
                    install: install
                )
                guard applied else {
                    schemaTask?.cancel()
                    return
                }

                if isEditable, let tableName {
                    if needsMetadataFetch {
                        launchPhase2Work(
                            tableName: tableName,
                            tabId: tabId,
                            connectionType: conn.type,
                            schemaTask: schemaTask
                        )
                    } else {
                        launchPhase2Count(
                            tableName: tableName,
                            tabId: tabId,
                            connectionType: conn.type
                        )
                    }
                } else if !isEditable || tableName == nil {
                    await MainActor.run { [parent] in
                        parent.clearChangesIfCurrent(claim: claim)
                    }
                }
            } catch {
                schemaTask?.cancel()
                CatalogChangeService.post(
                    .statementsRan(connectionId: conn.id, statements: [statement.sql], databaseType: conn.type)
                )
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard parent.tabExecution.settle(claim) else {
                        parent.reportStopRollback(error, tabId: tabId)
                        return
                    }
                    parent.tabManager.mutate(tabId: tabId) { tab in
                        tab.pagination.isLoadingMore = false
                    }
                    parent.retireQueryTask(.claim(claim))
                    if DatabaseCancellationDiagnosis.isCancellation(error) || Task.isCancelled {
                        parent.reportEndedExecutions([
                            EndedExecution(tabId: claim.tabId, startedAt: claim.startedAt, reason: .cancelledByUser)
                        ])
                        parent.reportStopRollback(error, tabId: tabId)
                        return
                    }
                    handleQueryExecutionError(
                        error,
                        sql: sql,
                        tabId: tabId,
                        connection: conn,
                        serverOutput: failureOutput.output
                    )
                    reportOperation(kind: .query, claim: claim, outcome: .failed(reason: error.localizedDescription))
                }
            }
        }
        parent.installQueryTask(parameterizedTask, owner: .claim(claim), lease: lease)
    }

    // One lease for every statement, so the transaction and its rollback reach the same handle.
    func executeMultipleStatementsWithParameters(
        _ statements: [SQLStatementScanner.ExecutableStatement],
        parameters: [QueryParameter],
        bypassRowLimit: Bool = false,
        onTab target: UUID? = nil
    ) {
        guard let (selectedTab, index) = parent.executionTab(target),
              !parent.tabExecution.isExecuting(selectedTab.id) else { return }

        let missing = parameters.filter {
            !$0.isNull && $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let firstMissing = missing.first {
            parent.tabManager.mutate(at: index) {
                $0.execution.errorMessage = String(
                    format: String(localized: "Missing value for parameter: %@"),
                    ":\(firstMissing.name)"
                )
            }
            return
        }

        guard let scope = parent.scope(for: selectedTab) else {
            parent.tabManager.mutate(at: index) {
                $0.execution.errorMessage = String(localized: "Not connected to database")
            }
            return
        }

        let style = PluginMetadataRegistry.shared.snapshot(
            for: parent.connection.type
        )?.parameterStyle ?? .questionMark

        parent.tabManager.mutate(at: index) { tab in
            tab.execution.executionTime = nil
            tab.execution.errorMessage = nil
        }

        let conn = parent.connection
        let tabId = parent.tabManager.tabs[index].id
        let (claim, lease) = parent.beginTabExecution(for: tabId)
        let tabType = parent.tabManager.tabs[index].tabType

        let statementTexts = statements.map(\.sql)
        let transactionKind = OperationKind.worst(of: statementTexts, databaseType: conn.type)
        let grammar = parent.lexicalGrammar
        let plan = BatchTransactionPolicy.plan(for: statementTexts, databaseType: conn.type, grammar: grammar, safeModeIsReadOnly: parent.runsAtReadOnly)
        let prepared = statements.map { statement in
            prepareStatement(
                statement: statement,
                parameters: parameters,
                style: style,
                tabType: tabType,
                bypassRowLimit: bypassRowLimit,
                grammar: grammar
            )
        }
        let asksEndState = SucceededStatements.runNeedsEndState(
            prepared.map(\.sentSQL), databaseType: conn.type, grammar: grammar
        )
        let script = parent.tabManager.tabs[index].content.query
        let running = RunningStatements(
            prepared: prepared,
            grammar: grammar,
            script: Self.scriptHolds(statements, in: script) ? script : nil,
            end: statements.last.map { NSMaxRange($0.range) } ?? 0
        ) { statement, grammar in
            self.prepareStatement(
                statement: statement,
                parameters: parameters,
                style: style,
                tabType: tabType,
                bypassRowLimit: bypassRowLimit,
                grammar: grammar
            )
        }

        let multiStatementTask = Task { [weak self, parent] in
            guard let self else { return }

            let run = await runMultiStatementTransaction(
                prepared: prepared,
                running: running,
                scope: scope,
                mode: transactionKind.transactionAccessMode,
                plan: plan,
                asksEndState: asksEndState,
                claim: claim,
                lease: lease
            )
            let outcome = run.outcome
            let sent = running.prepared
            let sessionNotice = run.plan.readsSessionEndState ? run.sessionState.openTransactionNotice : nil

            let ranStatements: [String]
            switch outcome {
            case .completed:
                ranStatements = sent.map(\.sentSQL)
            case .failed(let results, let failure, _):
                let ranCount = failure.ranStatementCount(executedCount: results.count, totalCount: sent.count)
                ranStatements = sent.prefix(ranCount).map(\.sentSQL)
            case .cancelled:
                ranStatements = sent.map(\.sentSQL)
            }
            CatalogChangeService.post(
                .statementsRan(connectionId: conn.id, statements: ranStatements, databaseType: conn.type)
            )
            CatalogChangeService.post(.statementsSucceeded(SucceededStatements(
                scope: scope,
                databaseType: conn.type,
                statements: sent.prefix(outcome.succeededCount).map(\.sentSQL),
                commit: .run(
                    startedIn: run.startState, endedIn: run.endState, plan: run.plan, completed: outcome.isCompleted
                )
            )))

            let results: [QueryResult]
            switch outcome {
            case .completed(let ran), .cancelled(let ran), .failed(let ran, _, _):
                results = ran
            }
            let resultPlan = RunResultPlan(producesRows: results.map { !$0.columns.isEmpty })
            let built = await buildStatementRows(
                zip(sent, results).enumerated().map { index, pair in
                    resultPlan.showsRows(ofStatement: index) ? (sql: pair.0.originalSQL as String?, result: pair.1) : nil
                },
                tabId: tabId
            )

            let history = ExecutedStatementHistory(
                prepared: sent, results: results, parameters: parameters, connection: conn
            )
            guard parent.tabExecution.settle(claim) || reportsUnknownCommitAfterStop(outcome, claim: claim) else {
                keepStatementsAfterStop(
                    history.keeping(outcome.keptAfterStop(plan: run.plan)),
                    claim: claim,
                    sessionNotice: sessionNotice,
                    built: built
                )
                return
            }
            parent.retireQueryTask(.claim(claim))

            switch outcome {
            case .cancelled:
                keepStoppedStatements(
                    history: history, tabId: tabId, sessionNotice: sessionNotice, built: built, presentsResults: true
                )
                parent.reportEndedExecutions([
                    EndedExecution(tabId: claim.tabId, startedAt: claim.startedAt, reason: .cancelledByUser)
                ])
            case .completed:
                applyCompletedStatements(
                    history: history, tabId: tabId, claim: claim, sessionNotice: sessionNotice, built: built
                )
            case .failed(let results, let failure, let errorDescription):
                handleMultiStatementError(
                    MultiStatementFailureContext(
                        failure: failure,
                        errorDescription: errorDescription,
                        executedCount: results.count,
                        totalCount: sent.count,
                        plan: run.plan,
                        sessionState: run.sessionState
                    ),
                    history: history,
                    tabId: tabId,
                    claim: claim,
                    anchors: sent.map(\.anchor),
                    timing: PluginQueryTiming.batch(of: results),
                    failureOutput: run.failureOutput,
                    built: built
                )
            }
        }
        parent.installQueryTask(multiStatementTask, owner: .claim(claim), lease: lease)
    }

    private func prepareStatement(
        statement: SQLStatementScanner.ExecutableStatement,
        parameters: [QueryParameter],
        style: ParameterStyle,
        tabType: TabType,
        bypassRowLimit: Bool,
        grammar: SQLLexicalGrammar
    ) -> PreparedStatement {
        let sql = statement.sql
        let parameterNames = parameters.isEmpty || !statement.acceptsBindParameters
            ? []
            : SQLParameterExtractor.extractParameters(from: sql, grammar: grammar)
        let conversion = parameterNames.isEmpty
            ? nil
            : SQLParameterExtractor.convertToNativeStyle(sql: sql, parameters: parameters, style: style, grammar: grammar)
        let executableSQL = conversion?.sql ?? sql
        let bounded = resolveStatement(sql: executableSQL, tabType: tabType, bypassLimit: bypassRowLimit)
        return PreparedStatement(
            originalSQL: sql,
            executableSQL: executableSQL,
            sentSQL: bounded.sql,
            parameterValues: conversion?.values,
            rowCap: bounded.rowCap,
            anchor: StatementAnchor(statement),
            statement: statement,
            isCommitPoint: BatchCommitStatement.matches(sql, grammar: grammar)
        )
    }

    // The session state is read inside the lease, so nothing opens a transaction between the answer and the run.
    private func runMultiStatementTransaction(
        prepared: [PreparedStatement],
        running: RunningStatements,
        scope: DatabaseScope,
        mode: PluginTransactionAccessMode,
        plan: BatchTransactionPlan,
        asksEndState: Bool,
        claim: TabExecutionClaim,
        lease: DriverLeaseOwner
    ) async -> MultiStatementRun {
        let commitMode = DatabaseManager.shared.commitMode(for: scope.connectionId)
        let failureOutput = ServerOutputBox()
        let commitOutput = ServerOutputBox()
        let databaseType = parent.connection.type
        let safeModeIsReadOnly = parent.runsAtReadOnly
        let grammar = parent.lexicalGrammar
        let statementTexts = prepared.map(\.sentSQL)
        do {
            var run = try await DatabaseManager.shared.withScopedDriver(
                scope: scope,
                route: DatabaseManager.shared.executionRoute(for: scope),
                cancellation: .cancellableRead(lease)
            ) { driver in
                let context = driver.readOnlyRunContext(safeModeIsReadOnly: safeModeIsReadOnly)
                let startState = await driver.heldSessionTransactionState()
                let manual = ManualCommit.decision(
                    commitMode: commitMode,
                    statements: statementTexts,
                    databaseType: databaseType,
                    grammar: grammar,
                    supportsTransactions: driver.supportsTransactions,
                    sessionState: startState
                )
                if let refusal = manual.refusal { throw refusal }
                let sessionPlan = ManualCommit.runPlan(text: plan, decision: manual, sessionState: startState)
                let outcome = await BatchStatementRun.run(
                    prepared,
                    plan: sessionPlan,
                    mode: mode,
                    driver: driver,
                    connectionId: scope.connectionId,
                    gate: self.claimGate(for: claim),
                    failureSQL: \.executableSQL,
                    isCommitPoint: \.isCommitPoint,
                    replanned: { ran in
                        running.replanned(
                            after: ran,
                            session: SQLLexicalResolver.readings(
                                for: databaseType, session: driver.sessionLexicalState
                            ).execution
                        )
                    },
                    commitOutput: commitOutput
                ) { statement in
                    try await ServerOutputCapture.running(on: driver, failureOutput: failureOutput) {
                        try await self.executeStatement(
                            rowCap: statement.rowCap,
                            originalSQL: statement.sentSQL,
                            driver: driver,
                            parameters: statement.parameterValues,
                            context: context
                        )
                    }
                }
                let sent = await running.prepared
                await DatabaseManager.shared.noteSessionStatements(
                    sent.prefix(outcome.ranCount(of: sent.count)).map(\.sentSQL), ranOn: driver, scope: scope
                )
                guard sessionPlan.readsSessionEndState else {
                    let endState: PluginSessionTransactionState = asksEndState
                        ? await driver.heldSessionTransactionState()
                        : .unknown
                    return MultiStatementRun(
                        outcome: outcome,
                        plan: sessionPlan,
                        sessionState: .idle,
                        startState: startState,
                        endState: endState
                    )
                }
                let sessionState = await driver.heldSessionTransactionState()
                return MultiStatementRun(
                    outcome: outcome,
                    plan: sessionPlan,
                    sessionState: sessionState,
                    startState: startState,
                    endState: sessionState
                )
            }
            if run.outcome.isCompleted {
                run.outcome = run.outcome.appendingCommitOutput(commitOutput.output)
            } else {
                run.failureOutput = failureOutput.output.appending(commitOutput.output)
            }
            return run
        } catch {
            if DatabaseCancellationDiagnosis.isCancellation(error) || Task.isCancelled {
                return MultiStatementRun(
                    outcome: .cancelled(results: []),
                    plan: plan,
                    sessionState: .unknown,
                    startState: .unknown,
                    endState: .unknown
                )
            }
            return MultiStatementRun(
                outcome: .failed(results: [], failure: .connection, errorDescription: error.localizedDescription),
                plan: plan,
                sessionState: .unknown,
                startState: .unknown,
                endState: .unknown
            )
        }
    }

    /// The claim questions the run asks, in the one place that holds both the claim and the
    /// registry. Marking and unmarking go through here so a future commit point cannot invent its
    /// own ordering.
    func claimGate(for claim: TabExecutionClaim) -> BatchClaimGate {
        BatchClaimGate(
            isCurrent: { self.parent.tabExecution.isCurrent(claim) },
            enterCommitPhase: { self.parent.tabExecution.enterUninterruptiblePhase(claim) },
            leaveCommitPhase: { self.parent.tabExecution.leaveUninterruptiblePhase(claim) }
        )
    }

    // A commit nobody can confirm is reported as one even after a Stop, rather than kept as plain successes.
    func reportsUnknownCommitAfterStop<Output>(_ outcome: BatchStatementOutcome<Output>, claim: TabExecutionClaim) -> Bool {
        outcome.leftCommitOutcomeUnknown
            && stoppedRunCanReplaceResults(onTab: claim.tabId)
            && parent.tabExecution.settleStopped(claim, replacingContent: true)
    }

    // A stopped run comes back after the tab went idle. Edits staged since then keep the result they were made on.
    func stoppedRunCanReplaceResults(onTab tabId: UUID) -> Bool {
        guard let tab = parent.tabManager.tabs.first(where: { $0.id == tabId }) else { return false }
        return !parent.holdsUnsavedWork(tab)
    }

    // A Stop during a statement reads as one between statements: the completed ones are kept, with no error result.
    private func keepStatementsAfterStop(
        _ history: ExecutedStatementHistory,
        claim: TabExecutionClaim,
        sessionNotice: String?,
        built: StatementRowsBuild
    ) {
        guard !history.results.isEmpty else { return }
        let presentsResults = stoppedRunCanReplaceResults(onTab: claim.tabId)
        guard parent.tabExecution.settleStopped(claim, replacingContent: presentsResults) else { return }
        keepStoppedStatements(
            history: history,
            tabId: claim.tabId,
            sessionNotice: sessionNotice,
            built: built,
            presentsResults: presentsResults
        )
        parent.reportEndedExecutions([
            EndedExecution(tabId: claim.tabId, startedAt: claim.startedAt, reason: .cancelledByUser)
        ])
    }

    // A Stop cannot take back what a plan without a transaction already committed, so those statements keep their history.
    private func keepStoppedStatements(
        history: ExecutedStatementHistory,
        tabId: UUID,
        sessionNotice: String?,
        built: StatementRowsBuild,
        presentsResults: Bool
    ) {
        guard !history.results.isEmpty else { return }
        recordExecutedStatements(history, tabId: tabId, commitOutcomeIsUnknown: false)
        guard presentsResults else { return }
        presentMultiStatementResults(
            tabId: tabId,
            timing: PluginQueryTiming.batch(of: history.results),
            totalRowsAffected: history.results.reduce(0) { $0 + $1.rowsAffected },
            newResultSets: statementResultSets(history, tabId: tabId, built: built),
            sessionNotice: sessionNotice
        )
    }

    // Below the caller's settle gate: a superseded batch writes no history rows, outcome or result sets.
    private func applyCompletedStatements(
        history: ExecutedStatementHistory,
        tabId: UUID,
        claim: TabExecutionClaim,
        sessionNotice: String?,
        built: StatementRowsBuild
    ) {
        let totalRowsAffected = history.results.reduce(0) { $0 + $1.rowsAffected }
        reportOperation(
            kind: .queryBatch,
            claim: claim,
            outcome: .succeeded(
                OperationSummary(rowsAffected: totalRowsAffected, statementCount: history.results.count)
            )
        )
        recordExecutedStatements(history, tabId: tabId, commitOutcomeIsUnknown: false)
        presentMultiStatementResults(
            tabId: tabId,
            timing: PluginQueryTiming.batch(of: history.results),
            totalRowsAffected: totalRowsAffected,
            newResultSets: statementResultSets(history, tabId: tabId, built: built),
            sessionNotice: sessionNotice
        )
    }

    // Only the statements the plan keeps become results, so a long script builds a few, not one per statement.
    private func statementResultSets(_ history: ExecutedStatementHistory, tabId: UUID, built: StatementRowsBuild) -> [ResultSet] {
        let firstNumber = parent.tabManager.tabs.first { $0.id == tabId }?.display.pinnedResultCount ?? 0
        let reading = parent.tableNameReading
        let ran = Array(zip(history.prepared, history.results))
        let plan = RunResultPlan(producesRows: ran.map { !$0.1.columns.isEmpty })
        let resultSets = plan.entries.enumerated().map { position, entry -> ResultSet in
            switch entry {
            case .summary(let indices):
                return makeRunSummaryResultSet(indices.map { RunSummaryPart(ran[$0].1) })
            case .statement(let index):
                let (statement, result) = ran[index]
                return makeStatementResultSet(
                    result: result,
                    sql: statement.originalSQL,
                    index: firstNumber + position,
                    baseQuery: statement.executableSQL,
                    baseQueryParameterValues: statement.parameterValues?.map(TypedParameterValue.kept),
                    namedParameterStatement: statement.parameterValues == nil
                        ? nil
                        : NamedParameterStatement(sql: statement.originalSQL, parameters: history.parameters),
                    tabId: tabId,
                    anchor: statement.anchor,
                    built: built.statement(at: index, readBy: reading)
                )
            }
        }
        appendDroppedNotice(of: plan, to: resultSets)
        return resultSets
    }

    /// A commit whose connection died before the answer leaves every statement of the batch in a
    /// state nothing can report as done, so history says so rather than claiming a success it
    /// cannot prove.
    private func recordExecutedStatements(
        _ history: ExecutedStatementHistory,
        tabId: UUID,
        commitOutcomeIsUnknown: Bool
    ) {
        let unresolvedOutcome = commitOutcomeIsUnknown
            ? String(localized: "The connection was lost while committing, so this may not be saved.")
            : nil
        for (statement, result) in zip(history.prepared, history.results) {
            recordStatementHistory(
                sql: statement.originalSQL,
                result: result,
                connection: history.connection,
                databaseName: historyDatabaseName(tabId: tabId),
                parameterValues: statement.parameterValues == nil ? nil : history.parameters,
                unresolvedOutcome: unresolvedOutcome
            )
        }
    }

    func applyParameterizedResult(
        tabId: UUID,
        fetchResult: QueryFetchResult,
        inlineMetadata: ParsedSchemaMetadata?,
        tableName: String?,
        isEditable: Bool,
        sql: String,
        connection: DatabaseConnection,
        claim: TabExecutionClaim,
        originalParameters: [QueryParameter],
        nativeParameters: [Any?],
        originalSQL: String? = nil,
        anchor: StatementAnchor? = nil,
        install: ResultInstall = .newResult
    ) async -> Bool {
        let prepared = await TableRows.preparing(
            fetchResult.rows,
            exportDocuments: fetchResult.exportDocuments,
            absentCells: fetchResult.absentCells,
            shape: phase1RowShape(
                tabId: tabId, tableName: tableName, columns: fetchResult.columns, columnTypes: fetchResult.columnTypes
            )
        )
        return await MainActor.run { [weak self] in
            guard let self else { return false }
            guard parent.tabExecution.settle(claim) else { return false }
            parent.retireQueryTask(.claim(claim))
            guard !Task.isCancelled else {
                parent.reportEndedExecutions([
                    EndedExecution(tabId: claim.tabId, startedAt: claim.startedAt, reason: .cancelledByUser)
                ])
                return false
            }
            parent.toolbarState.recordQueryTiming(fetchResult.resolvedTiming, for: claim.tabId)
            reportOperation(
                kind: .query,
                claim: claim,
                outcome: .succeeded(
                    OperationSummary(
                        rowsReturned: fetchResult.rows.count,
                        rowsAffected: fetchResult.rowsAffected
                    )
                )
            )

            guard parent.rereadStillApplies(install.source) else { return false }
            applyPhase1Result(
                tabId: tabId,
                columns: fetchResult.columns,
                columnTypes: fetchResult.columnTypes,
                rows: fetchResult.rows,
                executionTime: fetchResult.executionTime,
                rowsAffected: fetchResult.rowsAffected,
                statusMessage: fetchResult.statusMessage,
                tableName: tableName,
                isEditable: isEditable,
                metadata: inlineMetadata,
                hasSchema: false,
                read: TableFreshness.Read(startedAt: claim.startedAt, includesDefinition: false),
                sql: sql,
                connection: connection,
                isTruncated: fetchResult.isTruncated,
                queryParameterValues: originalParameters,
                historySQL: originalSQL,
                anchor: anchor,
                timing: fetchResult.resolvedTiming,
                viewport: install.viewport,
                source: install.source,
                serverOutput: fetchResult.serverOutput,
                exportDocuments: fetchResult.exportDocuments,
                absentCells: fetchResult.absentCells,
                columnOrigins: fetchResult.columnOrigins,
                prepared: prepared
            )

            let parameterValues = nativeParameters.map(TypedParameterValue.kept)
            let statement = originalSQL.map { NamedParameterStatement(sql: $0, parameters: originalParameters) }
            parent.tabManager.mutate(tabId: tabId) {
                $0.pagination.baseQueryParameterValues = parameterValues
                $0.display.activeResultSet?.baseQueryParameterValues = parameterValues
                $0.display.activeResultSet?.namedParameterStatement = statement
            }
            return true
        }
    }

    // Below the caller's settle gate: the lease already rolled back, and a superseded batch writes no history.
    private func handleMultiStatementError(
        _ context: MultiStatementFailureContext,
        history: ExecutedStatementHistory,
        tabId: UUID,
        claim: TabExecutionClaim,
        anchors: [StatementAnchor?],
        timing: PluginQueryTiming,
        failureOutput: PluginServerOutput,
        built: StatementRowsBuild
    ) {
        let cumulativeTime = timing.total
        let errorDescription = context.errorDescription
        let report = context.report()
        let contextMsg = ServerOutputCapture.failureMessage(report.message, output: failureOutput)

        let errorRS = ResultSet(label: report.resultLabel)
        errorRS.errorMessage = contextMsg
        errorRS.failedQuery = report.failedSQL
        errorRS.statementAnchor = report.failedStatementIndex
            .flatMap { anchors.indices.contains($0) ? anchors[$0] : nil }

        let failedStatementSQL = report.failedSQL
        reportOperation(kind: .queryBatch, claim: claim, outcome: .failed(reason: errorDescription))
        recordExecutedStatements(
            history,
            tabId: tabId,
            commitOutcomeIsUnknown: context.failure == .commitOutcomeUnknown
        )

        parent.flushBufferToActiveResult(tabId: tabId, pinnedOnly: true)
        parent.tabManager.mutate(tabId: tabId) { tab in
            // The Error result carries the failure, so the banner stays on it rather than over every other result.
            tab.execution.errorMessage = nil
            tab.execution.errorQuery = nil
            tab.execution.executionTime = cumulativeTime
            tab.execution.lastExecutedAt = Date()

            tab.display.replaceUnpinnedResults(with: statementResultSets(history, tabId: tabId, built: built) + [errorRS])
            if tab.display.isResultsCollapsed {
                tab.display.isResultsCollapsed = false
            }
        }
        parent.seedBufferFromActiveResult(tabId: tabId)
        parent.dropParkedEdits(ofBackgroundTab: tabId)
        if parent.tabManager.selectedTabId == tabId {
            parent.toolbarState.isResultsCollapsed = false
            parent.toolbarState.recordQueryTiming(timing, for: tabId)
            parent.announceQueryError(report.message)
        }

        guard let rawSQL = failedStatementSQL else { return }
        let recordSQL = rawSQL.hasSuffix(";") ? rawSQL : rawSQL + ";"
        recordHistory(
            QueryHistoryRecordRequest(
                query: recordSQL,
                connectionId: history.connection.id,
                databaseName: historyDatabaseName(tabId: tabId),
                databaseType: history.connection.type,
                schemaName: historySchemaName(tabId: tabId),
                source: .editor,
                executionTime: cumulativeTime,
                rowCount: -1,
                wasSuccessful: false,
                errorMessage: errorDescription
            )
        )
    }
}
