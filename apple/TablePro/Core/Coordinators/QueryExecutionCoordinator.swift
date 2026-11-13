//
//  QueryExecutionCoordinator.swift
//  TablePro
//

import Combine
import Foundation
import TableProSQLGrammar

// The tab an approval prompt was shown for, and the database and schema it was bound to.
struct RunTarget {
    let tabId: UUID
    let databaseName: String
    let schemaName: String?
}

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
        parent.tabVersions.record(tab, connectionId: parent.connectionId, reason: .run)

        if AppSettingsManager.shared.editor.queryParametersEnabled, parent.bindsNamedParameters {
            let combinedSQL = SQLParameterExtractor.parameterSource(of: statements)
            let detectedNames = SQLParameterExtractor.extractParameters(from: combinedSQL, grammar: parent.lexicalGrammar)

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
        guard !refuses(route, tabIndex: index), let target = runTarget(at: index) else { return }
        parent.isShowingSafeModePrompt = true
        let request = makeExecuteRequest(
            statements: batches.flatMap(\.statements),
            tabIndex: index,
            extraCapabilities: extraCapabilities
        )
        Task { [parent] in
            defer { parent.isShowingSafeModePrompt = false }
            switch await parent.executionGate.authorize(request) {
            case .authorized:
                guard parent.rereadCanStart(install.source), stillHolds(target) else { return }
                switch route {
                case .single(let only):
                    parent.executeQueryInternal(
                        only.sql,
                        bypassRowLimit: bypassRowLimit,
                        anchor: install.anchor ?? StatementAnchor(only),
                        viewport: install.viewport,
                        source: install.source,
                        onTab: target.tabId
                    )
                case .statements(let statements):
                    executeMultipleStatements(statements, bypassRowLimit: bypassRowLimit, onTab: target.tabId)
                case .batches(let batches):
                    executeBatches(batches, parameters: [], bypassRowLimit: bypassRowLimit, onTab: target.tabId)
                case .needsBatchDriver:
                    break
                }
            case .denied(let reason, _):
                parent.tabManager.mutate(tabId: target.tabId) { $0.execution.errorMessage = reason }
            }
        }
    }

    private func runTarget(at index: Int) -> RunTarget? {
        guard parent.tabManager.tabs.indices.contains(index) else { return nil }
        let tab = parent.tabManager.tabs[index]
        return RunTarget(
            tabId: tab.id, databaseName: tab.tableContext.databaseName, schemaName: tab.tableContext.schemaName
        )
    }

    // The approval prompt is not window-modal: the tab can be closed or repointed at another database before the answer.
    private func stillHolds(_ target: RunTarget) -> Bool {
        guard let tab = parent.tabManager.tabs.first(where: { $0.id == target.tabId }) else { return false }
        // A tab bound to no database follows the connection, which a queued switch may move meanwhile.
        let moved = !target.databaseName.isEmpty
            && (tab.tableContext.databaseName != target.databaseName || tab.tableContext.schemaName != target.schemaName)
        guard !moved else {
            parent.tabManager.mutate(tabId: target.tabId) {
                $0.execution.errorMessage = String(
                    localized: "This tab moved to another database while the query waited for approval. Run it again."
                )
            }
            return false
        }
        return true
    }

    private func makeExecuteRequest(
        statements: [SQLStatementScanner.ExecutableStatement],
        tabIndex index: Int,
        extraCapabilities: CallerCapabilities = []
    ) -> OperationRequest {
        let sql = statements.map(\.sql)
        let tabs = parent.tabManager.tabs
        return OperationRequest(
            connectionId: parent.connectionId,
            databaseType: parent.connection.type,
            sql: sql.joined(separator: "\n"),
            kind: OperationKind.worst(of: sql, databaseType: parent.connection.type),
            caller: .userInterface,
            capabilities: CallerCapabilities.interactiveUser.union(extraCapabilities),
            operationDescription: String(localized: "Execute Query"),
            runsIn: tabs.indices.contains(index) ? parent.scope(for: tabs[index]) : nil
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
        guard !refuses(route, tabIndex: index), let target = runTarget(at: index) else { return }
        parent.isShowingSafeModePrompt = true
        let request = makeExecuteRequest(
            statements: batches.flatMap(\.statements),
            tabIndex: index,
            extraCapabilities: extraCapabilities
        )
        Task { [parent] in
            defer { parent.isShowingSafeModePrompt = false }
            switch await parent.executionGate.authorize(request) {
            case .authorized:
                guard parent.rereadCanStart(install.source), stillHolds(target) else { return }
                executeParameterizedAfterSafeMode(
                    route,
                    parameters: parameters,
                    bypassRowLimit: bypassRowLimit,
                    install: install,
                    tabId: target.tabId
                )
            case .denied(let reason, _):
                parent.tabManager.mutate(tabId: target.tabId) { $0.execution.errorMessage = reason }
            }
        }
    }

    private func executeParameterizedAfterSafeMode(
        _ route: QueryExecutionRoute,
        parameters: [QueryParameter],
        bypassRowLimit: Bool,
        install: ResultInstall,
        tabId: UUID
    ) {
        switch route {
        case .single(let only):
            executeQueryWithParameters(
                only.sql,
                parameters: parameters,
                bypassRowLimit: bypassRowLimit,
                anchor: install.anchor ?? StatementAnchor(only),
                install: install,
                onTab: tabId
            )
        case .statements(let statements):
            executeMultipleStatementsWithParameters(
                statements, parameters: parameters, bypassRowLimit: bypassRowLimit, onTab: tabId
            )
        case .batches(let batches):
            executeBatches(batches, parameters: parameters, bypassRowLimit: bypassRowLimit, onTab: tabId)
        case .needsBatchDriver:
            break
        }
    }

    // A run the driver cannot carry out as written says so before anything is sent, rather than running part of it.
    private func refuses(_ route: QueryExecutionRoute, tabIndex index: Int) -> Bool {
        guard case .needsBatchDriver = route else { return false }
        parent.tabManager.mutate(at: index) {
            $0.execution.errorMessage = String(
                localized: "Update the database driver in Settings > Extensions to run a batch more than once with GO."
            )
        }
        return true
    }
}
