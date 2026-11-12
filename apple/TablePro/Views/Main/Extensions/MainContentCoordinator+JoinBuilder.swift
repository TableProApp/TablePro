//
//  MainContentCoordinator+JoinBuilder.swift
//  TablePro
//

import Foundation
import TableProPluginKit

@MainActor
extension MainContentCoordinator {
    var canBuildJoinQuery: Bool {
        JoinBuilderEligibility.supportsJoinBuilder(connection.type)
    }

    func openJoinBuilder(database: String?, schema: String?, tables: [String]) {
        guard canBuildJoinQuery else { return }
        activeSheet = .joinBuilder(JoinBuilderLaunchRequest(
            database: database?.nilIfEmpty ?? browseDatabaseName,
            schema: schema,
            tables: tables
        ))
    }

    // The query bar's Query Builder: the tab's own database and schema, with no table picked yet.
    func openJoinBuilder(forQueryTab tabId: UUID) {
        guard admitsSheetCommand(), let tab = tabManager.tabs.first(where: { $0.id == tabId }) else { return }
        let tabScope = scope(for: tab)
        openJoinBuilder(database: tabScope?.database, schema: tabScope?.schema, tables: [])
    }

    // One query joins one schema, so only the tables sharing the first one's are seeded.
    func openJoinBuilder(seededWith selection: Set<DatabaseTreeTableRef>) {
        let refs = selection.sorted { $0.table.name.localizedStandardCompare($1.table.name) == .orderedAscending }
        guard let first = refs.first else {
            openJoinBuilder(database: nil, schema: nil, tables: [])
            return
        }
        let tables = refs
            .filter { $0.database == first.database && $0.qualifyingSchema == first.qualifyingSchema }
            .map(\.table.name)
        openJoinBuilder(database: first.database, schema: first.qualifyingSchema, tables: tables)
    }

    func openJoinQuery(_ sql: String, database: String) {
        activeSheet = nil
        loadQueryIntoEditor(sql, databaseName: database, forceNewTab: true)
    }
}
