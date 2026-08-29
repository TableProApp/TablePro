//
//  QueryExecutionCoordinator.swift
//  TablePro
//

import Foundation

@MainActor @Observable
final class QueryExecutionCoordinator {
    @ObservationIgnored unowned let parent: MainContentCoordinator

    init(parent: MainContentCoordinator) {
        self.parent = parent
    }

    // MARK: - Run All Statements

    func runAllStatements(extraCapabilities: CallerCapabilities = []) {
        guard let (tab, index) = parent.tabManager.selectedTabAndIndex,
              !parent.tabExecution.isExecuting(tab.id),
              tab.tabType == .query else { return }

        let fullQuery = tab.content.query
        guard !fullQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let statements = QueryStatementScanner.executableStatements(
            in: fullQuery, model: parent.statementModel, dialect: parent.sqlDialect
        )
        guard !statements.isEmpty else { return }

        if AppSettingsManager.shared.editor.queryParametersEnabled, parent.statementModel == .sql {
            let combinedSQL = statements.map(\.sql).joined(separator: "; ")
            let detectedNames = SQLParameterExtractor.extractParameters(from: combinedSQL)

            if !detectedNames.isEmpty {
                let reconciled = detectAndReconcileParameters(
                    sql: combinedSQL,
                    existing: parent.tabManager.tabs[index].content.queryParameters
                )
                parent.tabManager.mutate(at: index) { $0.content.queryParameters = reconciled }

                if !parent.tabManager.tabs[index].content.isParameterPanelVisible {
                    parent.tabManager.mutate(at: index) { $0.content.isParameterPanelVisible = true }
                    return
                }

                dispatchParameterizedStatements(
                    statements,
                    parameters: reconciled,
                    tabIndex: index,
                    extraCapabilities: extraCapabilities
                )
                return
            }
        }

        dispatchStatements(statements, tabIndex: index, extraCapabilities: extraCapabilities)
    }

    func dispatchStatements(
        _ statements: [SQLStatementScanner.ExecutableStatement],
        tabIndex index: Int,
        bypassRowLimit: Bool = false,
        extraCapabilities: CallerCapabilities = []
    ) {
        guard !parent.isShowingSafeModePrompt else { return }
        parent.isShowingSafeModePrompt = true
        let request = makeExecuteRequest(statements: statements, extraCapabilities: extraCapabilities)
        Task { [parent] in
            defer { parent.isShowingSafeModePrompt = false }
            switch await ExecutionGateProvider.shared.authorize(request) {
            case .authorized:
                if let only = statements.first, statements.count == 1 {
                    parent.executeQueryInternal(
                        only.sql,
                        bypassRowLimit: bypassRowLimit,
                        anchor: StatementAnchor(only)
                    )
                } else {
                    executeMultipleStatements(statements, bypassRowLimit: bypassRowLimit)
                }
            case .denied(let reason):
                parent.tabManager.mutate(at: index) { $0.execution.errorMessage = reason }
            }
        }
    }

    private func makeExecuteRequest(
        statements: [SQLStatementScanner.ExecutableStatement],
        extraCapabilities: CallerCapabilities = []
    ) -> OperationRequest {
        let sql = statements.map(\.sql)
        return OperationRequest(
            connectionId: parent.connectionId,
            databaseType: parent.connection.type,
            sql: sql.joined(separator: "\n"),
            kind: OperationKind.worst(of: sql, databaseType: parent.connection.type),
            caller: .userInterface,
            capabilities: CallerCapabilities.interactiveUser.union(extraCapabilities),
            operationDescription: String(localized: "Execute Query")
        )
    }

    func dispatchParameterizedStatements(
        _ statements: [SQLStatementScanner.ExecutableStatement],
        parameters: [QueryParameter],
        tabIndex index: Int,
        bypassRowLimit: Bool = false,
        extraCapabilities: CallerCapabilities = []
    ) {
        guard !parent.isShowingSafeModePrompt else { return }
        parent.isShowingSafeModePrompt = true
        let tabId = parent.tabManager.tabs[index].id
        let request = makeExecuteRequest(statements: statements, extraCapabilities: extraCapabilities)
        Task { [parent] in
            defer { parent.isShowingSafeModePrompt = false }
            switch await ExecutionGateProvider.shared.authorize(request) {
            case .authorized:
                executeParameterizedAfterSafeMode(statements, parameters: parameters, bypassRowLimit: bypassRowLimit)
            case .denied(let reason):
                parent.tabManager.mutate(tabId: tabId) { $0.execution.errorMessage = reason }
            }
        }
    }

    private func executeParameterizedAfterSafeMode(
        _ statements: [SQLStatementScanner.ExecutableStatement],
        parameters: [QueryParameter],
        bypassRowLimit: Bool
    ) {
        if let only = statements.first, statements.count == 1 {
            executeQueryWithParameters(
                only.sql,
                parameters: parameters,
                bypassRowLimit: bypassRowLimit,
                anchor: StatementAnchor(only)
            )
        } else {
            executeMultipleStatementsWithParameters(statements, parameters: parameters, bypassRowLimit: bypassRowLimit)
        }
    }
}
