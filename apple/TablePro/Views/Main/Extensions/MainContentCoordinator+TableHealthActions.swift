import AppKit
import Foundation
import TableProUtilities

extension MainContentCoordinator {
    @discardableResult
    func tableHealthModel(for tabId: UUID) -> TableHealthViewModel {
        if let model = tableHealthModels[tabId] { return model }
        let model = TableHealthViewModel(
            connectionId: connectionId,
            provider: TableHealthProviderFactory.provider(for: connection.type),
            history: TableHealthHistoryStorage.shared,
            database: { [weak self] in
                self?.tabManager.tabs.first { $0.id == tabId }?.tableContext.databaseName ?? ""
            }
        )
        tableHealthModels[tabId] = model
        return model
    }

    // Every place a Table Health tab goes away comes here, so no report keeps the bulk metadata lane after its tab.
    func discardTableHealthModels(_ tabIds: [UUID]) {
        for tabId in tabIds {
            tableHealthModels.removeValue(forKey: tabId)?.cancel()
        }
    }

    func tableHealthActions(for model: TableHealthViewModel) -> TableHealthActions {
        TableHealthActions(
            openTable: { [weak self, weak model] finding in
                guard let self, let model, let table = finding.table else { return }
                self.openTableTab(table, schema: finding.schema, database: model.databaseName)
            },
            openInEditor: { [weak self, weak model] text in
                guard let self, let model else { return }
                self.openTableHealthFixes(text, database: model.databaseName)
            },
            saveFixScript: { [weak self, weak model] script in
                guard let self, let model else { return }
                self.saveTableHealthFixScript(script, database: model.databaseName)
            },
            export: { [weak self, weak model] in
                guard let self, let model else { return }
                self.openTableHealthExport(model)
            }
        )
    }

    // File > Export > Export Results… and the Actions menu land here for a Table Health tab.
    func openTableHealthExport(forTab tabId: UUID) {
        guard let model = tableHealthModels[tabId] else { return }
        openTableHealthExport(model)
    }

    func openTableHealthExport(_ model: TableHealthViewModel) {
        guard admitsSheetCommand(), let request = model.exportRequest() else { return }
        activeSheet = .exportDataSource(request)
    }

    func openTableHealthFixes(_ text: String, database: String) {
        WindowManager.shared.openTab(
            payload: EditorTabPayload(
                connectionId: connectionId,
                tabType: .query,
                databaseName: database,
                initialQuery: text,
                skipAutoExecute: true
            )
        )
    }

    func saveTableHealthFixScript(_ script: String, database: String) {
        let suggestedName = String(format: String(localized: "Table Health for %@"), database) + ".sql"
        Task { @MainActor [weak self] in
            guard let url = await SQLFileService.showSavePanel(suggestedName: suggestedName) else { return }
            do {
                try await SQLFileService.writeFile(content: script, to: url, encoding: .utf8)
            } catch {
                AlertHelper.showErrorSheet(
                    title: String(localized: "Could Not Save the Fix Script"),
                    message: error.localizedDescription,
                    window: self?.contentWindow
                )
            }
        }
    }
}
