//
//  MainContentCoordinator+Explain.swift
//  TablePro
//
//  The one path that runs EXPLAIN, whatever asked for it: the toolbar button, a variant picked
//  from its menu, or the Query menu item. Every one of them authorizes through the execution
//  gate and is fenced against a superseded result, the same way a normal query is.
//

import Foundation
import TableProEditorKit
import TableProPluginKit
import TableProSQLGrammar

extension MainContentCoordinator {
    @discardableResult
    func runExplain(onTab tabId: UUID, variant: ExplainVariant? = nil) -> Task<Void, Never>? {
        guard tabManager.selectedTab?.id == tabId else { return nil }
        // Nil when the discard prompt has to ask first: the plan follows the answer.
        var started: Task<Void, Never>?
        confirmRunDiscard(onTab: tabId) { [weak self] in
            started = self?.startExplain(variant: variant, onTab: tabId)
        }
        return started
    }

    private func startExplain(variant: ExplainVariant?, onTab tabId: UUID) -> Task<Void, Never>? {
        flushEditorText(forTab: tabId)
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }) else { return nil }
        guard !tabExecution.isExecuting(tabId) else {
            traceExecutionBlocked(tabId: tabId, site: "runExplain")
            return nil
        }
        guard !isShowingSafeModePrompt else { return nil }
        guard let statement = explainStatement(in: tab) else { return nil }
        let anchor = tab.tabType == .table ? nil : StatementAnchor(statement)
        guard let request = ExplainRequest.make(
            variant: variant,
            declaredVariants: connection.type.explainVariants,
            databaseType: connection.type,
            statement: statement.sql
        ) else {
            tabManager.mutate(tabId: tabId) {
                $0.execution.errorMessage = String(
                    localized: "EXPLAIN is not supported for this database type."
                )
            }
            return nil
        }
        guard let target = queryExecutionCoordinator.runTarget(onTab: tabId) else { return nil }

        isShowingSafeModePrompt = true
        let authorization = authorizationRequest(for: request, runsIn: scope(for: tab))
        return Task {
            defer { isShowingSafeModePrompt = false }
            switch await executionGate.authorize(authorization) {
            case .authorized:
                guard queryExecutionCoordinator.stillHolds(target) else { return }
                queryExecutionCoordinator.executeExplain(request, anchor: anchor, onTab: tabId)
            case .denied(let reason, .policy):
                tabManager.mutate(tabId: tabId) { $0.execution.errorMessage = reason }
            case .denied(_, .cancelledByUser):
                return
            }
        }
    }

    // MARK: - Request

    // An Oracle actual plan runs its statement in the tab's schema, where a bare name resolves.
    private func authorizationRequest(for request: ExplainRequest, runsIn: DatabaseScope?) -> OperationRequest {
        OperationRequest(
            connectionId: connectionId,
            databaseType: connection.type,
            sql: request.gatedSQL(databaseType: connection.type),
            kind: request.operationKind(databaseType: connection.type),
            caller: .userInterface,
            capabilities: .interactiveUser,
            operationDescription: String(localized: "Execute Query"),
            runsIn: runsIn
        )
    }

    /// The statement EXPLAIN will describe, and where it sits in the tab's query.
    ///
    /// Resolved the same way a run resolves it, so the plan is anchored to the statement the reader would have run.
    /// A table tab's query is generated rather than typed, so its offset is meaningless and the caller drops it.
    private func explainStatement(in tab: QueryTab) -> SQLStatementScanner.ExecutableStatement? {
        let fullQuery = tab.content.query

        let sql: String
        let sourceOffset: Int
        if tab.tabType == .table {
            sql = fullQuery
            sourceOffset = 0
        } else {
            let target = selectionOrStatementAtCursor(in: fullQuery)
            sql = target.sql
            sourceOffset = target.offset
        }

        return QueryStatementScanner
            .executableStatements(in: sql, model: statementModel, grammar: lexicalGrammar)
            .first?
            .offset(by: sourceOffset)
    }
}
