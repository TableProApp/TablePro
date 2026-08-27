//
//  DatabaseTreeOutlineCoordinator+Commands.swift
//  TablePro
//

import AppKit
import TableProPluginKit

/// Runs what a contextual menu item describes.
///
/// Every command arrives with its targets already resolved by the spec, so nothing here re-reads a
/// selection the user may have changed since the menu opened.
extension DatabaseTreeOutlineCoordinator {
    internal func perform(_ command: SidebarMenuCommand) {
        switch command {
        case .createTable:
            mainCoordinator?.createNewTable()
        case .createView:
            mainCoordinator?.createView()
        case .filterDatabases:
            mainCoordinator?.splitViewController?.presentDatabaseFilter()
        case .showAllDatabases:
            mainCoordinator?.splitViewController?.clearDatabaseFilter()
        case .openInNewTab(let ref):
            activateThen(ref) { [weak self] in
                self?.mainCoordinator?.openTableTab(ref.table, schema: ref.schema, forceNewTab: true)
            }
        case .editViewDefinition(let ref):
            activateThen(ref) { [weak self] in
                self?.mainCoordinator?.editViewDefinition(ref.table.name)
            }
        case .showStructure(let ref):
            activateThen(ref) { [weak self] in
                self?.mainCoordinator?.openTableTab(
                    ref.table,
                    schema: ref.schema,
                    showStructure: true,
                    forceNonPreview: true,
                    activateGridFocus: true
                )
            }
        case .showERDiagram:
            mainCoordinator?.showERDiagram()
        case .copyTableNames(let names):
            ClipboardService.shared.writeText(names.joined(separator: ","))
        case .exportTables(let names, let ref):
            activateThen(ref) { [weak self] in
                self?.mainCoordinator?.openExportDialog(preselectedTableNames: names)
            }
        case .importTables(let formatId, let ref):
            activateThen(ref) { [weak self] in
                self?.mainCoordinator?.openImportDialog(formatId: formatId)
            }
        case .maintenance(let operation, let tableName, let ref):
            activateThen(ref) { [weak self] in
                self?.mainCoordinator?.showMaintenanceSheet(
                    operation: operation,
                    tableName: tableName,
                    database: ref.database,
                    schema: ref.schema
                )
            }
        case .truncateTables(let targets, let ref):
            activateThen(ref) { [weak self] in
                self?.viewModel?.batchToggleTruncate(refs: targets)
            }
        case .dropTables(let targets, let ref):
            activateThen(ref) { [weak self] in
                self?.viewModel?.batchToggleDelete(refs: targets)
            }
        case .beginRenameTable(let ref, let isRecentRow):
            activateThen(ref) { [weak self] in
                self?.beginRename(.table(ref), isRecentRow: isRecentRow)
            }
        case .renameContainer(let ref):
            beginRename(.container(ref))
        case .toggleFavorite(let ref):
            toggleFavorite(ref)
        case .removeRecent(let ref):
            sidebarState?.removeRecentTable(database: ref.database, schema: ref.schema, name: ref.table.name)
        case .clearRecents:
            sidebarState?.clearRecentTables(inDatabase: mainCoordinator?.browseDatabaseName)
        case .useAsActive(let container):
            useAsActive(container)
        case .setFavoriteDatabases(let databases, let environment):
            for database in databases {
                favoriteDatabasesStorage.setFavorite(
                    database: database,
                    environment: environment,
                    connectionId: connectionId
                )
            }
        case .removeFavoriteDatabases(let databases):
            for database in databases {
                favoriteDatabasesStorage.removeFavorite(database: database, connectionId: connectionId)
            }
        case .refreshContainers(let targets):
            refreshContainers(targets)
        case .copyContainerNames(let targets):
            ClipboardService.shared.writeText(targets.map(\.name).joined(separator: ","))
        case .exportContainers(let targets):
            mainCoordinator?.openExportDialog(containers: targets)
        case .dropContainers(let targets):
            mainCoordinator?.requestContainerDrop(targets)
        case .showAllTablesMetadata:
            mainCoordinator?.showAllTablesMetadata()
        case .refreshObjectKind(let kind):
            refreshObjectKind(kind)
        case .refreshContainerObjectKind(let group):
            refreshContainerObjectKind(group)
        case .refreshHierarchicalSchema(let schema):
            reloadHierarchicalSchemaTables(schema)
        case .copyText(let text):
            ClipboardService.shared.writeText(text)
        case .showObjectSource(let ref):
            mainCoordinator?.showObjectSource(ref)
        case .copyRedisNamespacePrefix(let prefix):
            ClipboardService.shared.writeText(prefix)
        case .copyRedisKey(let key):
            ClipboardService.shared.writeText(key)
        case .openRedisKey(let key, let keyType):
            mainCoordinator?.openRedisKey(key, keyType: keyType)
        case .toggleObjectIcons:
            AppSettingsManager.shared.general.showObjectIcons.toggle()
            refreshVisibleRows()
        case .toggleObjectComments:
            AppSettingsManager.shared.general.showObjectComments.toggle()
            refreshVisibleRows()
        case .setRowSize(let size):
            AppSettingsManager.shared.general.sidebarRowSize = size
        }
    }

    /// A command that opens or edits an object has to reach the database that object lives in
    /// first, which is what a click on the row would have done.
    private func activateThen(_ ref: DatabaseTreeTableRef, _ body: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            await activate(ref)
            body()
        }
    }

    private func useAsActive(_ container: DatabaseContainerRef) {
        switch container.kind {
        case .database:
            guard let database = container.database else { return }
            setActiveDatabase(database)
        case .schema:
            guard let schema = container.schema else { return }
            setActiveSchema(database: container.database, schema: schema)
        }
    }
}
