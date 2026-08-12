//
//  MainContentCoordinator+QuickSwitcher.swift
//  TablePro
//
//  Quick switcher navigation handler for MainContentCoordinator
//

import AppKit
import Foundation

extension MainContentCoordinator {
    func showQuickSwitcher() {
        guard !quickSwitcherPanel.isPresented else {
            quickSwitcherPanel.dismiss()
            return
        }
        let openTableNames = Set(
            tabManager.tabs
                .filter { $0.tabType == .table }
                .compactMap(\.tableContext.tableName)
        )
        let panelView = QuickSwitcherPanelView(
            schemaProvider: SchemaProviderRegistry.shared.getOrCreate(for: connectionId),
            connectionId: connectionId,
            databaseType: connection.type,
            openTableNames: openTableNames,
            onSelect: { [weak self] item, intent in self?.handleQuickSwitcherSelection(item, intent: intent) },
            onDismiss: { [weak self] in self?.quickSwitcherPanel.dismiss() }
        )
        quickSwitcherPanel.present(panelView, over: contentWindow)
    }

    func handleQuickSwitcherSelection(_ item: QuickSwitcherItem, intent: QuickSwitcherCommitIntent = .open) {
        if let target = item.objectTarget, target.connectionId != connectionId {
            openQuickSwitcherObject(item, target: target, intent: intent)
            return
        }

        let schemaName = item.objectTarget?.schemaName
        switch item.kind {
        case .table, .systemTable:
            openTableTab(
                item.name,
                schema: schemaName,
                showStructure: intent == .openStructure,
                isView: item.isReadOnly,
                activateGridFocus: true,
                forceNewWindowTab: intent == .openInNewWindowTab
            )

        case .view:
            openTableTab(
                item.name,
                schema: schemaName,
                showStructure: intent == .openStructure,
                isView: true,
                activateGridFocus: true,
                forceNewWindowTab: intent == .openInNewWindowTab
            )

        case .database:
            Task {
                await switchDatabase(to: item.name)
            }

        case .schema:
            Task {
                await switchSchema(to: item.name)
            }

        case .savedQuery:
            loadQueryIntoEditor(item.payload ?? item.name)

        case .queryHistory:
            loadQueryIntoEditor(item.payload ?? item.name)
        }
    }

    private func openQuickSwitcherObject(
        _ item: QuickSwitcherItem,
        target: QuickSwitcherObjectTarget,
        intent: QuickSwitcherCommitIntent
    ) {
        if let coordinator = Self.allActiveCoordinators().first(where: { coordinator in
            guard coordinator.connectionId == target.connectionId else { return false }
            guard let session = coordinator.services.databaseManager.session(for: target.connectionId),
                  session.isConnected else { return false }
            if let databaseName = target.databaseName, coordinator.browseDatabaseName != databaseName {
                return false
            }
            return target.schemaName == nil || session.browseSchema == target.schemaName
        }) {
            coordinator.openTableTab(
                item.name,
                schema: target.schemaName,
                isView: item.kind == .view || item.isReadOnly,
                activateGridFocus: true,
                forceNewWindowTab: intent == .openInNewWindowTab
            )
            if let tabId = coordinator.tabManager.selectedTabId {
                coordinator.selectTabAndFocusWindow(tabId)
            }
            return
        }

        Task { [weak self] in
            do {
                try await TabRouter.shared.route(.openTable(
                    connectionId: target.connectionId,
                    database: target.databaseName,
                    schema: target.schemaName,
                    table: item.name,
                    isView: item.kind == .view || item.isReadOnly
                ))
            } catch {
                guard let self else { return }
                AlertHelper.showErrorSheet(
                    title: String(localized: "Could Not Open Table"),
                    message: error.localizedDescription,
                    window: contentWindow
                )
            }
        }
    }
}
