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
        guard let quickSwitcherPanel else { return }
        guard !quickSwitcherPanel.isPresented else {
            quickSwitcherPanel.dismiss()
            return
        }
        let browseSchema = services.databaseManager.session(for: connectionId)?.browseSchema
        let switcherScope = browseScope
            ?? DatabaseScope(connectionId: connectionId, database: connection.database, schema: nil)
        let openTables = Set(
            tabManager.tabs
                .filter { $0.tabType == .table }
                .compactMap { tab -> QuickSwitcherOpenTable? in
                    guard let tableName = tab.tableContext.tableName else { return nil }
                    return QuickSwitcherOpenTable(
                        schema: tab.tableContext.schemaName,
                        name: tableName,
                        browsing: browseSchema
                    )
                }
        )
        let panelView = QuickSwitcherPanelView(
            schemaProvider: SchemaProviderRegistry.shared.getOrCreate(for: switcherScope),
            connectionId: connectionId,
            databaseType: connection.type,
            openTables: openTables,
            browseSchema: browseSchema,
            onSelect: { [weak self] item, intent in self?.handleQuickSwitcherSelection(item, intent: intent) },
            onDismiss: { [weak self] in self?.quickSwitcherPanel?.dismiss() }
        )
        quickSwitcherPanel.present(panelView, over: contentWindow)
    }

    func handleQuickSwitcherSelection(_ item: QuickSwitcherItem, intent: QuickSwitcherCommitIntent = .open) {
        if let target = item.target,
           item.kind == .savedQuery || item.kind == .queryHistory {
            openQuickSwitcherQuery(item, target: target, intent: intent)
            return
        }

        if let target = item.target, target.connectionId != connectionId {
            openQuickSwitcherObject(item, target: target, intent: intent)
            return
        }

        let schemaName = item.target?.schemaName ?? item.schemaName
        switch item.kind {
        case .table, .systemTable:
            openTableTab(
                item.name,
                schema: schemaName,
                showStructure: intent == .openStructure,
                isView: item.isReadOnly,
                activateGridFocus: true,
                forceNewTab: intent == .openInNewWindowTab
            )

        case .view:
            openTableTab(
                item.name,
                schema: schemaName,
                showStructure: intent == .openStructure,
                isView: true,
                activateGridFocus: true,
                forceNewTab: intent == .openInNewWindowTab
            )

        case .database:
            Task {
                await switchDatabase(to: item.name)
            }

        case .schema:
            Task {
                await switchSchema(to: item.name)
            }

        case .procedure, .function, .trigger:
            guard let objectRef = item.objectRef else { return }
            showObjectSource(objectRef)

        case .savedQuery:
            loadQueryIntoEditor(
                item.payload ?? item.name,
                forceNewTab: intent == .openInNewWindowTab
            )

        case .queryHistory:
            loadQueryIntoEditor(
                item.payload ?? item.name,
                forceNewTab: intent == .openInNewWindowTab
            )
        }
    }

    private func openQuickSwitcherObject(
        _ item: QuickSwitcherItem,
        target: QuickSwitcherTarget,
        intent: QuickSwitcherCommitIntent
    ) {
        if let coordinator = coordinator(browsing: target) {
            let disposition = coordinator.openTableTab(
                item.name,
                schema: target.schemaName,
                isView: item.kind == .view || item.isReadOnly,
                activateGridFocus: true,
                forceNewTab: intent == .openInNewWindowTab
            )
            switch disposition {
            case .currentCoordinator:
                if let tabId = coordinator.tabManager.selectedTabId {
                    coordinator.selectTabAndFocusWindow(tabId)
                }
            case .focusedElsewhere:
                break
            case nil:
                coordinator.focusWindow()
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

    private func openQuickSwitcherQuery(
        _ item: QuickSwitcherItem,
        target: QuickSwitcherTarget,
        intent: QuickSwitcherCommitIntent
    ) {
        guard let session = services.databaseManager.session(for: target.connectionId),
              session.isConnected,
              session.driver != nil else {
            AlertHelper.showErrorSheet(
                title: String(localized: "Could Not Open Query"),
                message: String(localized: "The target connection is no longer open."),
                window: contentWindow
            )
            return
        }

        let query = item.payload ?? item.name
        if let coordinator = coordinator(browsing: target) {
            let disposition = coordinator.loadQueryIntoEditor(
                query,
                databaseName: target.databaseName,
                forceNewTab: intent == .openInNewWindowTab
            )
            if disposition == .currentCoordinator,
               let tabId = coordinator.tabManager.selectedTabId {
                coordinator.selectTabAndFocusWindow(tabId)
            }
            return
        }

        let payload = EditorTabPayload(
            connectionId: target.connectionId,
            tabType: .query,
            databaseName: target.databaseName,
            initialQuery: query
        )
        openTabInNewWindow(payload)
    }

    /// A window already on the target database can open any of its schemas directly, because
    /// `openTableTab` carries the schema per tab. Matching on the browsed schema too would send
    /// most results down the router instead, which reconnects the connection and retargets that
    /// window's sidebar as a side effect of opening one table.
    private func canHost(_ target: QuickSwitcherTarget) -> Bool {
        guard connectionId == target.connectionId,
              let session = services.databaseManager.session(for: target.connectionId),
              session.isConnected else { return false }
        guard let databaseName = target.databaseName else { return true }
        return browseDatabaseName == databaseName
    }

    /// Adapter over `QuickSwitcherHostResolver`, which owns the choice itself.
    private func coordinator(browsing target: QuickSwitcherTarget) -> MainContentCoordinator? {
        let candidates = Self.allActiveCoordinators().filter { $0.canHost(target) }
        guard !candidates.isEmpty else { return nil }
        let lastFocused = WindowLifecycleMonitor.shared.mostRecentWindow(for: target.connectionId)
        let hostId = QuickSwitcherHostResolver.host(
            preferred: canHost(target) ? instanceId : nil,
            candidates: candidates.map(\.instanceId),
            mostRecentlyFocused: candidates.first { $0.contentWindow === lastFocused }?.instanceId
        )
        return candidates.first { $0.instanceId == hostId }
    }
}
