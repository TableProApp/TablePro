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

    // `parameters` nil runs the text as written; a list binds each statement's `:name` markers.
    func dispatchBatches(
        _ batches: [ExecutableBatch],
        parameters: [QueryParameter]? = nil,
        onTab tabId: UUID,
        bypassRowLimit: Bool = false,
        extraCapabilities: CallerCapabilities = [],
        install: ResultInstall = .newResult
    ) {
        guard !parent.isShowingSafeModePrompt, let route = executionRoute(for: batches) else { return }
        guard !refuses(route, onTab: tabId), let target = runTarget(onTab: tabId) else { return }
        parent.isShowingSafeModePrompt = true
        let request = makeExecuteRequest(
            statements: batches.flatMap(\.statements),
            onTab: tabId,
            extraCapabilities: extraCapabilities
        )
        Task { [parent] in
            defer { parent.isShowingSafeModePrompt = false }
            switch await parent.executionGate.authorize(request) {
            case .authorized:
                guard parent.rereadCanStart(install.source), stillHolds(target) else { return }
                start(route, parameters: parameters, bypassRowLimit: bypassRowLimit, install: install, onTab: target.tabId)
            case .denied(let reason, _):
                parent.tabManager.mutate(tabId: target.tabId) { $0.execution.errorMessage = reason }
            }
        }
    }

    private func start(
        _ route: QueryExecutionRoute,
        parameters: [QueryParameter]?,
        bypassRowLimit: Bool,
        install: ResultInstall,
        onTab tabId: UUID
    ) {
        switch route {
        case .single(let only):
            let anchor = install.anchor ?? StatementAnchor(only)
            if let parameters {
                executeQueryWithParameters(
                    only.sql, parameters: parameters, onTab: tabId,
                    bypassRowLimit: bypassRowLimit, anchor: anchor, install: install
                )
            } else {
                startSingleRun(
                    SingleRunRequest(sql: only.sql, bypassRowLimit: bypassRowLimit, anchor: anchor, install: install),
                    onTab: tabId
                )
            }
        case .statements(let statements):
            executeMultipleStatementsWithParameters(
                statements, parameters: parameters ?? [], onTab: tabId, bypassRowLimit: bypassRowLimit
            )
        case .batches(let batches):
            executeBatches(batches, parameters: parameters ?? [], onTab: tabId, bypassRowLimit: bypassRowLimit)
        case .needsBatchDriver:
            break
        }
    }

    func runTarget(onTab tabId: UUID) -> RunTarget? {
        guard let tab = parent.tabManager.tabs.first(where: { $0.id == tabId }) else { return nil }
        return RunTarget(
            tabId: tab.id, databaseName: tab.tableContext.databaseName, schemaName: tab.tableContext.schemaName
        )
    }

    // The approval prompt is not window-modal: the tab can be closed or repointed at another database before the answer.
    func stillHolds(_ target: RunTarget) -> Bool {
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
        onTab tabId: UUID,
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
            operationDescription: String(localized: "Execute Query"),
            runsIn: parent.tabManager.tabs.first { $0.id == tabId }.flatMap(parent.scope(for:))
        )
    }

    // A run the driver cannot carry out as written says so before anything is sent, rather than running part of it.
    private func refuses(_ route: QueryExecutionRoute, onTab tabId: UUID) -> Bool {
        guard case .needsBatchDriver = route else { return false }
        parent.tabManager.mutate(tabId: tabId) {
            $0.execution.errorMessage = String(
                localized: "Update the database driver in Settings > Extensions to run a batch more than once with GO."
            )
        }
        return true
    }
}
