//
//  QueryExecutionCoordinator.swift
//  TablePro
//

import Combine
import Foundation
import TableProSQLGrammar

@MainActor
final class QueryExecutionCoordinator: ObservableObject {
    unowned let parent: MainContentCoordinator

    init(parent: MainContentCoordinator) {
        self.parent = parent
    }

    // MARK: - Run All Statements

    func runAllStatements(extraCapabilities: CallerCapabilities = []) {
        guard let (tab, index) = parent.tabManager.selectedTabAndIndex,
              !parent.tabExecution.isExecuting(tab.id),
              tab.tabType == .query else { return }

        let batches = executionBatches(in: tab.content.query)
        let statements = batches.flatMap(\.statements)
        guard !statements.isEmpty else { return }

        if AppSettingsManager.shared.editor.queryParametersEnabled, parent.bindsNamedParameters {
            let combinedSQL = SQLParameterExtractor.parameterSource(of: statements)
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

                dispatchParameterizedBatches(
                    batches,
                    parameters: reconciled,
                    tabIndex: index,
                    extraCapabilities: extraCapabilities
                )
                return
            }
        }

        dispatchBatches(batches, tabIndex: index, extraCapabilities: extraCapabilities)
    }

    func dispatchBatches(
        _ batches: [ExecutableBatch],
        tabIndex index: Int,
        bypassRowLimit: Bool = false,
        extraCapabilities: CallerCapabilities = [],
        install: ResultInstall = .newResult
    ) {
        guard !parent.isShowingSafeModePrompt, let route = executionRoute(for: batches) else { return }
        guard !refuses(route, tabIndex: index) else { return }
        parent.isShowingSafeModePrompt = true
        let request = makeExecuteRequest(
            statements: batches.flatMap(\.statements),
            extraCapabilities: extraCapabilities
        )
        Task { [parent] in
            defer { parent.isShowingSafeModePrompt = false }
            switch await parent.executionGate.authorize(request) {
            case .authorized:
                guard parent.rereadCanStart(install.source) else { return }
                switch route {
                case .single(let only):
                    parent.executeQueryInternal(
                        only.sql,
                        bypassRowLimit: bypassRowLimit,
                        anchor: install.anchor ?? StatementAnchor(only),
                        viewport: install.viewport,
                        source: install.source
                    )
                case .statements(let statements):
                    executeMultipleStatements(statements, bypassRowLimit: bypassRowLimit)
                case .batches(let batches):
                    executeBatches(batches, parameters: [], bypassRowLimit: bypassRowLimit)
                case .needsBatchDriver:
                    break
                }
            case .denied(let reason, _):
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

    func dispatchParameterizedBatches(
        _ batches: [ExecutableBatch],
        parameters: [QueryParameter],
        tabIndex index: Int,
        bypassRowLimit: Bool = false,
        extraCapabilities: CallerCapabilities = [],
        install: ResultInstall = .newResult
    ) {
        guard !parent.isShowingSafeModePrompt, let route = executionRoute(for: batches) else { return }
        guard !refuses(route, tabIndex: index) else { return }
        parent.isShowingSafeModePrompt = true
        let tabId = parent.tabManager.tabs[index].id
        let request = makeExecuteRequest(
            statements: batches.flatMap(\.statements),
            extraCapabilities: extraCapabilities
        )
        Task { [parent] in
            defer { parent.isShowingSafeModePrompt = false }
            switch await parent.executionGate.authorize(request) {
            case .authorized:
                guard parent.rereadCanStart(install.source) else { return }
                executeParameterizedAfterSafeMode(
                    route,
                    parameters: parameters,
                    bypassRowLimit: bypassRowLimit,
                    install: install
                )
            case .denied(let reason, _):
                parent.tabManager.mutate(tabId: tabId) { $0.execution.errorMessage = reason }
            }
        }
    }

    private func executeParameterizedAfterSafeMode(
        _ route: QueryExecutionRoute,
        parameters: [QueryParameter],
        bypassRowLimit: Bool,
        install: ResultInstall
    ) {
        switch route {
        case .single(let only):
            executeQueryWithParameters(
                only.sql,
                parameters: parameters,
                bypassRowLimit: bypassRowLimit,
                anchor: install.anchor ?? StatementAnchor(only),
                install: install
            )
        case .statements(let statements):
            executeMultipleStatementsWithParameters(statements, parameters: parameters, bypassRowLimit: bypassRowLimit)
        case .batches(let batches):
            executeBatches(batches, parameters: parameters, bypassRowLimit: bypassRowLimit)
        case .needsBatchDriver:
            break
        }
    }

    /// A run the driver cannot carry out as written says so before anything is sent, rather than running part of it.
    private func refuses(_ route: QueryExecutionRoute, tabIndex index: Int) -> Bool {
        guard case .needsBatchDriver = route else { return false }
        parent.tabManager.mutate(at: index) {
            $0.execution.errorMessage = String(
                localized: "Update the database driver in Settings > Plugins to run a batch more than once with GO."
            )
        }
        return true
    }
}
