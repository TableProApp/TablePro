//
//  SchemaOperationRefusal.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal struct SchemaOperationRefusedError: LocalizedError, Equatable {
    let reason: String

    var errorDescription: String? { reason }
}

internal enum SchemaOperationRefusal {
    static func reason(for change: SchemaChange, driver: any PluginDatabaseDriver) -> String? {
        switch change {
        case .addColumn(let column):
            return driver.schemaOperationRefusal(.addColumn(column.toPlugin()))
        case .addIndex(let index), .modifyIndex(_, let index):
            return driver.schemaOperationRefusal(.addIndex(index.toPlugin()))
        case .modifyCheckConstraint(let old, let new):
            guard old.expression == new.expression, old.name != new.name else { return nil }
            return driver.schemaOperationRefusal(.renameCheckConstraint(from: old.name, to: new.name))
        case .modifyColumn, .deleteColumn, .deleteIndex, .addForeignKey, .modifyForeignKey,
             .deleteForeignKey, .modifyPrimaryKey, .addCheckConstraint, .deleteCheckConstraint:
            return nil
        }
    }

    static func reason(for definition: PluginCreateTableDefinition, driver: any PluginDatabaseDriver) -> String? {
        let operations = definition.columns.map(PluginSchemaOperation.addColumn)
            + definition.indexes.map(PluginSchemaOperation.addIndex)
        return operations.lazy.compactMap { driver.schemaOperationRefusal($0) }.first
    }
}
