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
        switch item.kind {
        case .table, .systemTable:
            openTableTab(
                item.name,
                showStructure: intent == .openStructure,
                activateGridFocus: true,
                forceNewWindowTab: intent == .openInNewWindowTab
            )

        case .view:
            openTableTab(
                item.name,
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
}
