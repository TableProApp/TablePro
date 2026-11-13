//
//  MainContentCoordinator+Masking.swift
//  TablePro
//

import Combine
import Foundation
import TableProSQLGrammar

extension MainContentCoordinator {
    var maskingPolicy: MaskingPolicy {
        (services.databaseManager.session(for: connectionId)?.connection ?? connection).maskingPolicy
    }

    func columnMasks(forTabId tabId: UUID, table: String?, columns: [String], columnTypes: [ColumnType]) -> ColumnMasks {
        if tabManager.tabs.first(where: { $0.id == tabId })?.revealsMaskedValues == true { return .none }
        return maskingPolicy.columnMasks(table: table, columns: columns, columnTypes: columnTypes)
    }

    func exportMaskingPolicy(forTabId tabId: UUID) -> MaskingPolicy {
        tabManager.tabs.first(where: { $0.id == tabId })?.revealsMaskedValues == true ? .none : maskingPolicy
    }

    // The grid matched only the names a statement chose, so a tab's rows leave for the assistant or a script masked
    // the way the bridge masks an external caller's result, whatever the person revealed in the grid.
    func externalOverlay(forTab tabId: UUID) -> ColumnMasks {
        let policy = maskingPolicy
        guard !policy.isEmpty else { return .none }
        let rows = tabSessionRegistry.tableRows(for: tabId)
        let tab = tabManager.tabs.first { $0.id == tabId }
        let table = tab?.tabType == .table ? tab?.tableContext.tableName : nil
        let external = policy.externalColumnMasks(
            table: table, columns: rows.columns, typeNames: rows.columnTypes.map(\.rawType), origins: rows.columnOrigins
        )
        return rows.externalOverlay(external)
    }

    func externallyMaskedRows(forTab tabId: UUID) -> TableRows {
        let rows = tabSessionRegistry.tableRows(for: tabId)
        let overlay = externalOverlay(forTab: tabId)
        return overlay.isEmpty ? rows : rows.externallyMasked(by: overlay)
    }

    // A failed statement's text can repeat a value the server read.
    func externalErrorText(_ message: String?) -> String? {
        guard let message, !maskingPolicy.isEmpty else { return message }
        return ServerErrorText.withheldMessage
    }

    func observeMaskingRuleChanges() -> AnyCancellable {
        services.appEvents.connectionUpdated
            .filter { [connectionId] changed in changed == nil || changed == connectionId }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.maskLoadedResults()
                self?.maskingRulesApplied.send()
            }
    }

    // Masks the rows already on screen when a rule is saved, rather than waiting for the next run. Read from storage,
    // since the live session may adopt the saved record after this runs.
    func maskLoadedResults() {
        guard let stored = services.databaseManager.connectionStorage.loadConnection(id: connectionId) else { return }
        let policy = stored.maskingPolicy
        guard !policy.isEmpty else { return }
        for tab in tabManager.tabs where !tab.revealsMaskedValues {
            let table = tab.tabType == .table ? tab.tableContext.tableName : nil
            mutateActiveTableRows(for: tab.id) { rows in
                rows.addMasks(policy.columnMasks(table: table, columns: rows.columns, columnTypes: rows.columnTypes), policy: policy, table: table)
            }
            for resultSet in tab.display.resultSets {
                let rows = resultSet.tableRows
                resultSet.tableRows.addMasks(policy.columnMasks(table: nil, columns: rows.columns, columnTypes: rows.columnTypes), policy: policy)
            }
        }
    }

    // LAContext shows this as "TablePro is trying to <reason>.", so it stays a lowercase phrase with no period.
    static var revealMaskedValuesReason: String {
        String(localized: "show masked values")
    }

    func revealMaskedValues(
        tabId: UUID,
        authenticator: any OperationAuthenticating = BiometricOperationAuthenticating()
    ) async {
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }), !tab.revealsMaskedValues else { return }
        guard await authenticator.authenticate(reason: Self.revealMaskedValuesReason) else { return }
        tabManager.mutate(tabId: tabId) { $0.revealsMaskedValues = true }
        guard tabManager.selectedTabId == tabId else { return }
        switch tab.tabType {
        case .table:
            runQuery(viewport: .keepPlace)
        default:
            // Running a query tab again could repeat a write, so only a read reruns; anything else shows on its next run.
            let classification = QueryClassifier.classify(tab.content.query, databaseType: connection.type)
            guard classification.tier == .safe else { return }
            runQuery(viewport: .keepPlace)
        }
    }
}
