//
//  MainContentCoordinator+QuickSwitcher.swift
//  TablePro
//
//  Quick switcher navigation handler for MainContentCoordinator
//

import Foundation

extension MainContentCoordinator {
    func showQuickSwitcher() {
        quickSwitcherPanel.show(
            schemaProvider: SchemaProviderRegistry.shared.getOrCreate(for: connection.id),
            connectionId: connection.id,
            databaseType: connection.type,
            onSelect: { [weak self] item in
                self?.handleQuickSwitcherSelection(item)
            }
        )
    }

    func handleQuickSwitcherSelection(_ item: QuickSwitcherItem) {
        switch item.kind {
        case .table, .systemTable:
            openTableTab(item.name)

        case .view:
            openTableTab(item.name, isView: true)

        case .database:
            Task {
                await switchDatabase(to: item.name)
            }

        case .schema:
            Task {
                await switchSchema(to: item.name)
            }

        case .queryHistory:
            loadQueryIntoEditor(item.name)
        }
    }
}
