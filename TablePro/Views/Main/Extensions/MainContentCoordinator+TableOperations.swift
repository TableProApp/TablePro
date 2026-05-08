//
//  MainContentCoordinator+TableOperations.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    private var tableOperationBuilder: TableOperationSQLBuilder {
        TableOperationSQLBuilder(
            connectionId: connectionId,
            databaseType: connection.type,
            viewNamesProvider: {
                guard let session = DatabaseManager.shared.session(for: self.connectionId) else { return [] }
                return Set(session.tables.filter { $0.type == .view }.map(\.name))
            },
            adapterProvider: {
                DatabaseManager.shared.driver(for: self.connectionId) as? PluginDriverAdapter
            }
        )
    }

    func generateTableOperationSQL(
        truncates: Set<String>,
        deletes: Set<String>,
        options: [String: TableOperationOptions],
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
