//
//  MainContentCoordinator+DatabaseObjectTools.swift
//  TablePro
//
//  Copy DDL, Refresh Materialized View and Edit Comment on one table-like object.
//

import AppKit
import Foundation
import os
import TableProPluginKit

extension MainContentCoordinator {
    private static let objectToolsLogger = Logger(subsystem: "com.TablePro", category: "DatabaseObjectTools")

    /// The object a sidebar row or the menu bar's selection names, scoped to its own database and
    /// schema. A row whose database is nil belongs to the database being browsed.
    func objectTarget(for ref: DatabaseTreeTableRef) -> DatabaseObjectTarget? {
        guard let scope = services.databaseManager.resolvedScope(
            database: ref.database,
            schema: ref.qualifyingSchema,
            for: connectionId
        ) else { return nil }
        return DatabaseObjectTarget(
            name: ref.table.name,
            type: ref.table.type,
            schema: scope.schema ?? ref.qualifyingSchema,
            scope: scope
        )
    }

    // MARK: - Copy DDL

    /// The same text the DDL viewer and the Structure tab's DDL show, read in the object's own scope.
    func copyDDL(of ref: DatabaseTreeTableRef) {
        guard let target = objectTarget(for: ref) else { return }
        let name = target.name
        Task {
            do {
                let ddl = try await services.databaseManager.withMetadataDriver(scope: target.scope) { driver in
                    try await TableDDLComposer.fetchDDL(for: name, using: driver, includesDependencies: true)
                }
                ClipboardService.shared.writeText(ddl)
            } catch {
                Self.objectToolsLogger.error("Copy DDL failed: \(error.localizedDescription, privacy: .public)")
                AlertHelper.showErrorSheet(
                    title: String(localized: "Couldn't Copy DDL"),
                    message: error.localizedDescription,
                    window: contentWindow
                )
            }
        }
    }

    // MARK: - Refresh Materialized View

    func refreshMaterializedView(_ ref: DatabaseTreeTableRef) {
        guard !safeModeLevel.blocksAllWrites, let target = objectTarget(for: ref) else { return }
        Task {
            let prompt = await refreshPrompt(for: target)
            MaterializedViewRefreshAlert.present(prompt: prompt, window: contentWindow) { [weak self] concurrently in
                guard let self, let concurrently else { return }
                self.runMaterializedViewRefresh(target, concurrently: concurrently)
            }
        }
    }

    /// A failed check still asks the question: the refresh itself does not depend on it, and a
    /// server that could not answer the catalog read will say why when the refresh runs.
    private func refreshPrompt(for target: DatabaseObjectTarget) async -> MaterializedViewRefreshPrompt {
        do {
            let availability = try await MaterializedViewRefreshing.concurrentRefreshAvailability(of: target)
            return MaterializedViewRefreshPrompt(qualifiedName: target.qualifiedName, availability: availability)
        } catch {
            Self.objectToolsLogger.error(
                "Concurrent refresh check failed: \(error.localizedDescription, privacy: .public)"
            )
            return MaterializedViewRefreshPrompt(
                qualifiedName: target.qualifiedName,
                availability: nil,
                availabilityCheckFailed: true
            )
        }
    }

    private func runMaterializedViewRefresh(_ target: DatabaseObjectTarget, concurrently: Bool) {
        Task {
            do {
                try await MaterializedViewRefreshing.refresh(target, concurrently: concurrently, connection: connection)
                AlertHelper.showInfoSheet(
                    title: String(localized: "Materialized View Refreshed"),
                    message: String(format: String(localized: "“%@” now holds the current result of its query."), target.qualifiedName),
                    window: contentWindow
                )
            } catch {
                AlertHelper.showErrorSheet(
                    title: String(localized: "Couldn't Refresh Materialized View"),
                    message: error.localizedDescription,
                    window: contentWindow
                )
            }
        }
    }

    // MARK: - Edit Comment

    func editComment(of ref: DatabaseTreeTableRef) {
        guard !safeModeLevel.blocksAllWrites, let target = objectTarget(for: ref) else { return }
        activeSheet = .editObjectComment(target)
    }

    // MARK: - Object Changes

    /// Brings every tab showing the changed object up to date, and no other tab. The selected one
    /// reloads now, asking first if it holds edits; a background one drops its rows so it reloads
    /// when it is next shown.
    ///
    /// The selected tab goes through `handleRefresh`, the entry Cmd+R uses, rather than straight to
    /// the data reload: that one refuses to run while the Structure pane is in front and refreshes
    /// the structure instead, and a tab excluded from the eviction loop for being selected would
    /// otherwise keep its rows with nothing left to reload them.
    func applyObjectChange(
        _ change: DatabaseObjectChange,
        hasPendingTableOps: Bool,
        onDiscard: @escaping () -> Void
    ) {
        guard change.connectionId == connectionId else { return }
        let showing = tabManager.tabs.filter { tab in
            tab.tabType == .table && change.matches(
                tableName: tab.tableContext.tableName,
                databaseName: tab.tableContext.resolvedDatabaseName(browsing: browseDatabaseName),
                schemaName: tab.tableContext.schemaName
            )
        }
        let selected = tabManager.selectedTab.flatMap { tab in showing.contains { $0.id == tab.id } ? tab : nil }

        switch change.kind {
        case .rows:
            for tab in showing where tab.id != selected?.id {
                evictReloadableTableRows(for: tab.id)
            }
            if selected != nil {
                handleRefresh(hasPendingTableOps: hasPendingTableOps, onDiscard: onDiscard)
            }
        case .comment:
            for tab in showing {
                tableMetadataCache.removeValue(forKey: tab.id)
            }
            if let selected, let tableName = selected.tableContext.tableName {
                Task { await loadTableMetadata(tableName: tableName, for: selected) }
            }
            if change.scope.database == browseDatabaseName {
                Task { await refreshTables() }
            }
        }
    }
}
