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
        let panelView = QuickSwitcherPanelView(
            schemaProvider: SchemaProviderRegistry.shared.getOrCreate(for: connectionId),
            connectionId: connectionId,
            databaseType: connection.type,
            onSelect: { [weak self] item in self?.handleQuickSwitcherSelection(item) },
            onDismiss: { [weak self] in self?.quickSwitcherPanel.dismiss() }
        )
        quickSwitcherPanel.present(panelView, over: contentWindow)
    }

    func handleQuickSwitcherSelection(_ item: QuickSwitcherItem) {
        switch item.kind {
        case .table, .systemTable:
            openTableTab(item.name, activateGridFocus: true)

        case .view:
            openTableTab(item.name, isView: true, activateGridFocus: true)

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
