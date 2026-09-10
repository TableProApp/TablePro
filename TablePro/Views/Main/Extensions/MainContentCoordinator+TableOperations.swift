//
//  MainContentCoordinator+TableOperations.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    private var tableOperationBuilder: TableOperationSQLBuilder {
        TableOperationSQLBuilder(
            adapterProvider: {
                DatabaseManager.shared.driver(for: self.connectionId) as? PluginDriverAdapter
            }
        )
    }

    func generateTableOperationSQL(
        truncates: Set<DatabaseTreeTableRef>,
        deletes: Set<DatabaseTreeTableRef>,
        options: [DatabaseTreeTableRef: TableOperationOptions],
        includeFKHandling: Bool = true
    ) -> [String] {
        tableOperationBuilder.generate(
            truncates: truncates,
            deletes: deletes,
            options: options,
            includeFKHandling: includeFKHandling
        )
    }

    func fkDisableStatements(for dbType: DatabaseType) -> [String] {
        tableOperationBuilder.foreignKeyDisableStatements()
    }

    func fkEnableStatements(for dbType: DatabaseType) -> [String] {
        tableOperationBuilder.foreignKeyEnableStatements()
    }
}
