//
//  DataGridViewController+ConnectionScope.swift
//  TablePro
//

import AppKit

// The editors that read the database learn the connection from the configuration the owner sets.
extension DataGridViewController {
    var foreignKeyScope: DatabaseScope? {
        model.configuration.traits.connectionScope
    }

    var editingDatabaseType: DatabaseType? {
        model.configuration.traits.databaseType
    }

    var userDefinedTypeScope: DatabaseScope? {
        let traits = model.configuration.traits
        return traits.looksUpUserDefinedTypes ? traits.connectionScope : nil
    }

    // MySQL doubles a backslash as well as a quote, which the shared helper does not.
    func stringLiteralEscaper() -> (String) -> String {
        guard let connectionId = model.configuration.traits.connectionScope?.connectionId,
              let driver = DatabaseManager.shared.driver(for: connectionId) else {
            return { SQLEscaping.escapeStringLiteral($0) }
        }
        return { driver.escapeStringLiteral($0) }
    }

    func canSearchForeignKeys(_ databaseType: DatabaseType) -> Bool {
        PluginManager.shared.sqlDialect(for: databaseType) != nil
    }
}
