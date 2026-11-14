//
//  QueryExecutionCoordinator+Parameters.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit
import TableProSQLGrammar

private let paramLog = Logger(subsystem: "com.TablePro", category: "QueryParameters")

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
    // Read from the text before the lease is taken, so the run never lexes inside it.
    let isCommitPoint: Bool
    let endsItsTransaction: Bool
    let closesTransaction: Bool
    let movesDatabase: Bool
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
    // Read once per run: the rows built off the main actor and the results shown take the same plan.
    let rowResultLimit: Int?

    func keeping(_ kept: [QueryResult]) -> ExecutedStatementHistory {
        ExecutedStatementHistory(
            prepared: prepared, results: kept, parameters: parameters, rowResultLimit: rowResultLimit
        )
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

    // One lease for every statement, so the transaction and its rollback reach the same handle.
    func executeMultipleStatementsWithParameters(
        _ statements: [SQLStatementScanner.ExecutableStatement],
        parameters: [QueryParameter],
        onTab tabId: UUID,
        bypassRowLimit: Bool = false
    ) {
        guard let run = TabRun.begin(onTab: tabId, parameters: parameters, in: parent),
              let tab = parent.tabManager.tabs.first(where: { $0.id == tabId }) else { return }

        let style = PluginMetadataRegistry.shared.snapshot(
            for: parent.connection.type
        )?.parameterStyle ?? .questionMark
        let conn = run.connection
        let scope = run.scope
        let tabType = tab.tabType

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
        let script = tab.content.query
        let running = RunningStatements(
            prepared: prepared,
            grammar: grammar,
            script: Self.scriptHolds(statements, in: script) ? script : nil,
            // The segment's end, so a last COPY cut again keeps its rows.
            end: statements.last?.segmentEnd ?? 0
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

        run.launch { [weak self] run in
            guard let self else { return }

            let ran = await runMultiStatementTransaction(
                prepared: prepared,
                running: running,
                scope: scope,
                mode: transactionKind.transactionAccessMode,
                plan: plan,
                asksEndState: asksEndState,
                claim: run.claim,
                lease: run.lease
            )
            let outcome = ran.outcome
            let sent = running.prepared
            let readsEndState = ran.plan.readsSessionEndState || ran.plan == .autocommit
            let sessionNotice = readsEndState ? ran.sessionState.openTransactionNotice : nil

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
                    startedIn: ran.startState, endedIn: ran.endState, plan: ran.plan, completed: outcome.isCompleted
                )
            )))

            let results: [QueryResult]
            switch outcome {
            case .completed(let ran), .cancelled(let ran), .failed(let ran, _, _):
                results = ran
            }
            let rowResultLimit = AppSettingsManager.shared.dataGrid.resultSetLimitPerRun
            let resultPlan = RunResultPlan(producesRows: results.map { !$0.columns.isEmpty }, keepingRowResults: rowResultLimit)
            let built = await buildStatementRows(
                zip(sent, results).enumerated().map { index, pair in
                    resultPlan.showsRows(ofStatement: index) ? (sql: pair.0.originalSQL as String?, result: pair.1) : nil
                },
                tabId: tabId
            )

            let history = ExecutedStatementHistory(
                prepared: sent, results: results, parameters: parameters, rowResultLimit: rowResultLimit
            )
            guard run.settle() || reportsUnknownCommitAfterStop(outcome, claim: run.claim) else {
                keepStatementsAfterStop(
                    history.keeping(outcome.keptAfterStop(plan: ran.plan)),
                    run: run,
                    sessionNotice: sessionNotice,
                    built: built
                )
                return
            }

            switch outcome {
            case .cancelled:
                keepStoppedStatements(
                    history: history, run: run, sessionNotice: sessionNotice, built: built, presentsResults: true
                )
                run.reportCancelled()
            case .completed:
                applyCompletedStatements(history: history, run: run, sessionNotice: sessionNotice, built: built)
            case .failed(let results, let failure, let errorDescription):
                handleMultiStatementError(
                    MultiStatementFailureContext(
                        failure: failure,
                        errorDescription: errorDescription,
                        executedCount: results.count,
                        totalCount: sent.count,
                        plan: ran.plan,
                        sessionState: ran.sessionState
                    ),
                    history: history,
                    run: run,
                    anchors: sent.map(\.anchor),
                    timing: PluginQueryTiming.batch(of: results),
                    failureOutput: ran.failureOutput,
                    built: built
                )
            }
        }
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
        let family = TransactionEngineFamily.of(parent.connection.type)
        let definitionEnds = family.definitionEndsTransaction
        return PreparedStatement(
            originalSQL: sql,
            executableSQL: executableSQL,
            sentSQL: bounded.sql,
            parameterValues: conversion?.values,
            rowCap: bounded.rowCap,
            anchor: StatementAnchor(statement),
            statement: statement,
            isCommitPoint: BatchCommitStatement.matches(sql, grammar: grammar),
            endsItsTransaction: definitionEnds && AutocommitOnlyStatement.matches(sql, family: family, grammar: grammar),
            closesTransaction: definitionEnds && TransactionEndStatement.matches(sql, grammar: grammar),
            movesDatabase: AutocommitOnlyStatement.movesDatabase(sql, family: family, grammar: grammar)
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
        let definitionEnds = TransactionEngineFamily.of(databaseType).definitionEndsTransaction
        let safeModeIsReadOnly = parent.runsAtReadOnly
        let grammar = parent.lexicalGrammar
        let statementTexts = prepared.map(\.sentSQL)
        do {
            var run = try await DatabaseManager.shared.withScopedDriver(
                scope: scope,
                route: DatabaseManager.shared.executionRoute(for: scope),
                cancellation: .cancellableRead(lease),
                sessionWork: .statements
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
                    endsItsTransaction: \.endsItsTransaction,
                    closesTransaction: \.closesTransaction,
                    movesDatabase: \.movesDatabase,
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
                            copyData: statement.statement?.copyData,
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
                    // An unwrapped run can still leave a transaction open: a Teradata ANSI session holds its DDL in one, completed or not.
                    let readsHeldWork = sessionPlan == .autocommit && (!outcome.isCompleted || definitionEnds)
                    let heldState: PluginSessionTransactionState = readsHeldWork
                        ? (asksEndState ? endState : await driver.heldSessionTransactionState())
                        : .idle
                    return MultiStatementRun(
                        outcome: outcome,
                        plan: sessionPlan,
                        sessionState: heldState,
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
        run: TabRun,
        sessionNotice: String?,
        built: StatementRowsBuild
    ) {
        guard !history.results.isEmpty else { return }
        let presentsResults = stoppedRunCanReplaceResults(onTab: run.tabId)
        guard parent.tabExecution.settleStopped(run.claim, replacingContent: presentsResults) else { return }
        keepStoppedStatements(
            history: history,
            run: run,
            sessionNotice: sessionNotice,
            built: built,
            presentsResults: presentsResults
        )
        run.reportCancelled()
    }

    // A Stop cannot take back what a plan without a transaction already committed, so those statements keep their history.
    private func keepStoppedStatements(
        history: ExecutedStatementHistory,
        run: TabRun,
        sessionNotice: String?,
        built: StatementRowsBuild,
        presentsResults: Bool
    ) {
        guard !history.results.isEmpty else { return }
        recordExecutedStatements(history, run: run, commitOutcomeIsUnknown: false)
        guard presentsResults else { return }
        presentMultiStatementResults(
            tabId: run.tabId,
            timing: PluginQueryTiming.batch(of: history.results),
            totalRowsAffected: history.results.reduce(0) { $0 + $1.rowsAffected },
            newResultSets: statementResultSets(history, tabId: run.tabId, built: built),
            sessionNotice: sessionNotice
        )
    }

    // Below the caller's settle gate: a superseded batch writes no history rows, outcome or result sets.
    private func applyCompletedStatements(
        history: ExecutedStatementHistory,
        run: TabRun,
        sessionNotice: String?,
        built: StatementRowsBuild
    ) {
        let totalRowsAffected = history.results.reduce(0) { $0 + $1.rowsAffected }
        run.report(
            .queryBatch,
            .succeeded(OperationSummary(rowsAffected: totalRowsAffected, statementCount: history.results.count))
        )
        recordExecutedStatements(history, run: run, commitOutcomeIsUnknown: false)
        presentMultiStatementResults(
            tabId: run.tabId,
            timing: PluginQueryTiming.batch(of: history.results),
            totalRowsAffected: totalRowsAffected,
            newResultSets: statementResultSets(history, tabId: run.tabId, built: built),
            sessionNotice: sessionNotice
        )
    }

    // Only the statements the plan keeps become results, so a long script builds a few, not one per statement.
    private func statementResultSets(_ history: ExecutedStatementHistory, tabId: UUID, built: StatementRowsBuild) -> [ResultSet] {
        let firstNumber = parent.tabManager.tabs.first { $0.id == tabId }?.display.pinnedResultCount ?? 0
        let reading = parent.tableNameReading
        let ran = Array(zip(history.prepared, history.results))
        let plan = RunResultPlan(producesRows: ran.map { !$0.1.columns.isEmpty }, keepingRowResults: history.rowResultLimit)
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

    // A commit whose connection died before the answer cannot be reported as done, so history says so.
    private func recordExecutedStatements(
        _ history: ExecutedStatementHistory,
        run: TabRun,
        commitOutcomeIsUnknown: Bool
    ) {
        let unresolvedOutcome = commitOutcomeIsUnknown
            ? String(localized: "The connection was lost while committing, so this may not be saved.")
            : nil
        for (statement, result) in zip(history.prepared, history.results) {
            run.recordHistory(RunHistoryEntry(
                query: statement.originalSQL,
                terminates: true,
                source: .editor,
                executionTime: result.executionTime,
                rowCount: result.rows.count,
                failure: unresolvedOutcome,
                timing: result.resolvedTiming
            ))
        }
    }

    // Below the caller's settle gate: the lease already rolled back, and a superseded batch writes no history.
    private func handleMultiStatementError(
        _ context: MultiStatementFailureContext,
        history: ExecutedStatementHistory,
        run: TabRun,
        anchors: [StatementAnchor?],
        timing: PluginQueryTiming,
        failureOutput: PluginServerOutput,
        built: StatementRowsBuild
    ) {
        let errorDescription = context.errorDescription
        let report = context.report()

        let errorRS = ResultSet(label: report.resultLabel)
        errorRS.errorMessage = ServerOutputCapture.failureMessage(report.message, output: failureOutput)
        errorRS.failedQuery = report.failedSQL
        errorRS.statementAnchor = report.failedStatementIndex
            .flatMap { anchors.indices.contains($0) ? anchors[$0] : nil }

        // A run stopped to wait for a commit has no server error, so the notification carries the report.
        run.report(.queryBatch, .failed(reason: errorDescription.isEmpty ? report.message : errorDescription))
        recordExecutedStatements(
            history,
            run: run,
            commitOutcomeIsUnknown: context.failure == .commitOutcomeUnknown
        )
        presentFailedRun(
            tabId: run.tabId,
            resultSets: statementResultSets(history, tabId: run.tabId, built: built),
            error: errorRS,
            timing: timing,
            announcing: report.message
        )

        guard let failedSQL = report.failedSQL else { return }
        run.recordHistory(RunHistoryEntry(
            query: failedSQL,
            terminates: true,
            source: .editor,
            executionTime: timing.total,
            rowCount: -1,
            failure: errorDescription
        ))
    }
}
