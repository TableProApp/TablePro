//
//  MainContentCoordinator+DatabaseObjectTools.swift
//  TablePro
//
//  Copy DDL, Refresh Materialized View and Edit Comment on one object.
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
        let schema = target.schema
        Task {
            do {
                let ddl = try await services.databaseManager.withMetadataDriver(scope: target.scope) { driver in
                    try await TableDDLComposer.fetchDDL(for: name, using: driver, includesDependencies: true, schema: schema)
                }
                ClipboardService.shared.writeText(ddl)
            } catch {
                Self.objectToolsLogger.error("Copy DDL failed: \(error.publicLogShape, privacy: .public)")
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
                "Concurrent refresh check failed: \(error.publicLogShape, privacy: .public)"
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
            } catch ExecutionGateError.cancelledByUser {
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

    // MARK: - Sequences

    func setSequenceNextValue(of ref: DatabaseTreeTableRef) {
        guard !safeModeLevel.blocksAllWrites, let target = objectTarget(for: ref) else { return }
        activeSheet = .setSequenceNextValue(target)
    }

    func editSequence(_ ref: DatabaseTreeTableRef) {
        guard !safeModeLevel.blocksAllWrites, let target = objectTarget(for: ref) else { return }
        activeSheet = .editSequence(target)
    }

    // MARK: - Object Changes

    private func viewTabIds(writingThrough change: DatabaseObjectChange) -> Set<UUID> {
        Set(tabManager.tabs.filter { tab in
            guard tab.tabType == .table, let base = tab.tableContext.viewWriteTarget?.baseTable else { return false }
            return change.matches(
                tableName: base.name,
                databaseName: base.database ?? tab.tableContext.resolvedDatabaseName(browsing: browseDatabaseName),
                schemaName: base.schema ?? tab.tableContext.schemaName
            )
        }.map(\.id))
    }

    // A rows change refreshes structure too: a MongoDB collection's columns and a matview's indexes follow its rows.
    func applyObjectChange(_ change: DatabaseObjectChange) {
        guard change.connectionId == connectionId else { return }
        let showing = tabManager.tabs.filter { tab in
            tab.tabType == .table && change.matches(
                tableName: tab.tableContext.tableName,
                databaseName: tab.tableContext.resolvedDatabaseName(browsing: browseDatabaseName),
                schemaName: tab.tableContext.schemaName
            )
        }
        let showingIds = Set(showing.map(\.id))
        let selected = tabManager.selectedTab.flatMap { showingIds.contains($0.id) ? $0 : nil }
        // A view tab writing through the changed table shows its rows, so it reloads with it.
        let writingIds = showingIds.union(viewTabIds(writingThrough: change))

        switch change.kind {
        case .rows:
            let rows = TableFreshness.Change(extent: .rows, at: change.changedAt)
            refreshTableTabs(for: rows, excluding: change.originTabId) { writingIds.contains($0.id) }
        case .structure:
            forgetSchemaColumns(of: change)
            let definition = TableFreshness.Change(extent: .definition, at: change.changedAt)
            refreshTableTabs(for: definition, excluding: change.originTabId) { writingIds.contains($0.id) }
        case .comment:
            markTableMetadataStale(forTabs: showingIds)
            if let selected {
                Task { await loadTableMetadata(for: selected) }
            }
            refreshStructure(ofTabs: showing)
        case .dropped:
            closeTabsForRemovedObjects(ids: showing.map(\.id))
        case .renamed(let newName):
            retitleTabs(ids: Set(showing.map(\.id)), to: newName)
        }
    }
}
