//
//  MainContentCoordinator+FilterState.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    var selectedTabFilterState: TabFilterState {
        filterCoordinator.selectedTabFilterState
    }

    var currentTableName: String? {
        guard let tab = tabManager.selectedTab, tab.tabType == .table else { return nil }
        return tab.tableContext.tableName
    }

    func addFilterForColumn(_ columnName: String) {
        filterCoordinator.addFilterForColumn(columnName)
    }

    var canFilterRows: Bool {
        filterCoordinator.canFilterRows
    }

    func applyCellFilter(_ filter: TableFilter, forTab tabId: UUID) {
        guard tabManager.selectedTab?.id == tabId else { return }
        filterCoordinator.applyCellFilter(filter, forTab: tabId)
    }

    func toggleFilterPanel() {
        filterCoordinator.toggleFilterPanel()
    }

    func showFilterPanel() {
        filterCoordinator.showFilterPanel()
    }

    func saveLastFilters(of tab: QueryTab) {
        filterCoordinator.saveLastFilters(of: tab)
    }

    func clearFilterState() {
        filterCoordinator.clearFilterState()
    }

    // Filters on a column the Structure tab renamed or dropped follow it, or the next page fails on an unknown column.
    func followColumnChanges(_ changes: [SchemaChange], table: String, schema: String?, database: String) {
        var renamed: [(old: String, new: String)] = []
        var dropped: Set<String> = []
        for change in changes {
            switch change {
            case .deleteColumn(let column):
                dropped.insert(column.name)
            case .modifyColumn(let old, let new) where old.name != new.name:
                renamed.append((old.name, new.name))
            default:
                continue
            }
        }
        guard !renamed.isEmpty || !dropped.isEmpty else { return }
        let names = dropped.union(renamed.map(\.old))
        // Structure never edits a temporary table, which can share the permanent table's name.
        let affected = tabManager.tabs.filter { tab in
            tab.tabType == .table
                && !tab.tableContext.isTemporary
                && tab.tableContext.tableName == table
                && tab.tableContext.schemaName == schema
                && tab.tableContext.databaseName == database
                && tab.filterState.filtersOnAnyColumn(in: names)
        }
        for tab in affected {
            tabManager.mutate(tabId: tab.id) { tab in
                for rename in renamed {
                    tab.filterState.renameFilterColumn(from: rename.old, to: rename.new)
                }
                tab.filterState.removeFilters(onColumns: dropped)
            }
            rebuildTableQuery(forTab: tab.id)
            if let updated = tabManager.tabs.first(where: { $0.id == tab.id }) {
                saveLastFilters(of: updated)
            }
        }
    }
}
