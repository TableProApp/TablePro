//
//  MainContentCoordinator+Masking.swift
//  TablePro
//

import Combine
import Foundation

extension MainContentCoordinator {
    var maskingPolicy: MaskingPolicy {
        (services.databaseManager.session(for: connectionId)?.connection ?? connection).maskingPolicy
    }

    func columnMasks(forTabId tabId: UUID, table: String?, columns: [String], columnTypes: [ColumnType]) -> ColumnMasks {
        if tabManager.tabs.first(where: { $0.id == tabId })?.revealsMaskedValues == true { return .none }
        return maskingPolicy.columnMasks(table: table, columns: columns, columnTypes: columnTypes)
    }

    func observeMaskingRuleChanges() -> AnyCancellable {
        services.appEvents.connectionUpdated
            .filter { [connectionId] changed in changed == nil || changed == connectionId }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.maskLoadedResults() }
    }

    /// Masks the rows already on screen when a rule is saved, rather than waiting for the next run. Read from storage,
    /// since the live session may adopt the saved record after this runs.
    func maskLoadedResults() {
        guard let stored = services.databaseManager.connectionStorage.loadConnection(id: connectionId) else { return }
        let policy = stored.maskingPolicy
        guard !policy.isEmpty else { return }
        for tab in tabManager.tabs where !tab.revealsMaskedValues {
            let table = tab.tabType == .table ? tab.tableContext.tableName : nil
            mutateActiveTableRows(for: tab.id) { rows in
                rows.addMasks(policy.columnMasks(table: table, columns: rows.columns, columnTypes: rows.columnTypes))
            }
            for resultSet in tab.display.resultSets {
                let rows = resultSet.tableRows
                resultSet.tableRows.addMasks(policy.columnMasks(table: nil, columns: rows.columns, columnTypes: rows.columnTypes))
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
