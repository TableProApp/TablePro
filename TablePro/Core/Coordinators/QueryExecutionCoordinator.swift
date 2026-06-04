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

    func runAllStatements() {
        guard let (tab, index) = parent.tabManager.selectedTabAndIndex,
              !tab.execution.isExecuting,
              tab.tabType == .query else { return }

        let fullQuery = tab.content.query
        guard !fullQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let statements = SQLStatementScanner.allStatements(in: fullQuery, dialect: parent.sqlDialect)
        guard !statements.isEmpty else { return }

        if parent.services.appSettings.editor.queryParametersEnabled {
            let combinedSQL = statements.joined(separator: "; ")
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

                dispatchParameterizedStatements(statements, parameters: reconciled, tabIndex: index)
                return
            }
        }

        dispatchStatements(statements, tabIndex: index)
    }

    func dispatchStatements(_ statements: [String], tabIndex index: Int) {
        guard !parent.isShowingSafeModePrompt else { return }
        parent.isShowingSafeModePrompt = true
        let request = makeExecuteRequest(statements: statements)
        Task { [weak self, parent] in
            guard let self else { return }
            defer { parent.isShowingSafeModePrompt = false }
            do {
                try await ExecutionGateProvider.shared.authorizing(request) {
                    if statements.count == 1 {
                        parent.executeQueryInternal(statements[0])
                    } else {
                        self.executeMultipleStatements(statements, authorizationRequest: request)
                    }
                }
            } catch {
                parent.tabManager.mutate(at: index) { $0.execution.errorMessage = error.localizedDescription }
            }
        }
    }

    func makeExecuteRequest(statements: [String]) -> OperationRequest {
        OperationRequest.interactiveUser(
            connectionId: parent.connectionId,
            databaseType: parent.connection.type,
            sql: statements.joined(separator: "\n"),
            kind: OperationKind.worst(of: statements, databaseType: parent.connection.type),
            operationDescription: String(localized: "Execute Query")
        )
    }

    func dispatchParameterizedStatements(
        _ statements: [String],
        parameters: [QueryParameter],
        tabIndex index: Int
    ) {
        guard !parent.isShowingSafeModePrompt else { return }
        parent.isShowingSafeModePrompt = true
        let tabId = parent.tabManager.tabs[index].id
        let request = makeExecuteRequest(statements: statements)
        Task { [weak self, parent] in
            guard let self else { return }
            defer { parent.isShowingSafeModePrompt = false }
            do {
                try await ExecutionGateProvider.shared.authorizing(request) {
                    self.executeParameterizedAfterSafeMode(
                        statements,
                        parameters: parameters,
                        authorizationRequest: request
                    )
                }
            } catch {
                parent.tabManager.mutate(tabId: tabId) { $0.execution.errorMessage = error.localizedDescription }
            }
        }
    }

    private func executeParameterizedAfterSafeMode(
        _ statements: [String],
        parameters: [QueryParameter],
        authorizationRequest: OperationRequest
    ) {
        if statements.count == 1 {
            executeQueryWithParameters(statements[0], parameters: parameters)
        } else {
            executeMultipleStatementsWithParameters(
                statements,
                parameters: parameters,
                authorizationRequest: authorizationRequest
            )
        }
    }
}
