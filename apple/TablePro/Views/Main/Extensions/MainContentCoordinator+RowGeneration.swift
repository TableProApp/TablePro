//
//  MainContentCoordinator+RowGeneration.swift
//  TablePro
//

import Foundation

@MainActor
extension MainContentCoordinator {
    // The row's own database and schema travel with the request: the sidebar can be browsing another one.
    func openGenerateRows(_ ref: DatabaseTreeTableRef) {
        guard !safeModeLevel.blocksAllWrites,
              RowGenerationEligibility.appliesTo(ref.table.type),
              let target = objectTarget(for: ref) else { return }
        let scope = target.scope
        let session = RowGenerationSession(
            tableName: target.name,
            scopeDescription: DatabaseEndpoint.from(
                connection: connection, database: scope.database, schema: scope.schema
            ).qualifiedDescription,
            scope: TableScope(table: target.name, in: scope),
            dataSource: RowGenerationLiveSource(connection: connection, scope: scope, tableName: target.name),
            onOpenScript: { [weak self] script in
                self?.openGeneratedRowsScript(script, database: scope.database)
            }
        )
        activeSheet = .generateRows(session)
    }

    func openGeneratedRowsScript(_ script: String, database: String) {
        activeSheet = nil
        tabManager.addTab(initialQuery: script, databaseName: database, claimFocus: true)
    }
}
