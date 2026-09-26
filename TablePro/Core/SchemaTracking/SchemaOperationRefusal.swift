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
        case .addIndex(let index):
            return driver.schemaOperationRefusal(.addIndex(index.toPlugin()))
        case .modifyIndex(let old, let new):
            return driver.schemaOperationRefusal(.modifyIndex(old: old.toPlugin(), new: new.toPlugin()))
                ?? driver.schemaOperationRefusal(.addIndex(new.toPlugin()))
        case .deleteIndex(let index):
            return driver.schemaOperationRefusal(.dropIndex(index.toPlugin()))
        case .modifyCheckConstraint(let old, let new):
            if let refusal = driver.checkConstraintRefusal { return refusal }
            guard old.expression == new.expression, old.name != new.name else { return nil }
            return driver.schemaOperationRefusal(.renameCheckConstraint(from: old.name, to: new.name))
        case .addCheckConstraint, .deleteCheckConstraint:
            return driver.checkConstraintRefusal
        case .modifyColumn(let old, let new):
            return driver.schemaOperationRefusal(.modifyColumn(old: old.toPlugin(), new: new.toPlugin()))
        case .deleteColumn(let column):
            return driver.schemaOperationRefusal(.dropColumn(column.toPlugin()))
        case .addForeignKey, .modifyForeignKey, .deleteForeignKey, .modifyPrimaryKey:
            return nil
        }
    }

    /// The operations a change carries out, as the driver's save-level questions receive them. A
    /// check constraint is an operation only when it is renamed, and foreign key and primary key
    /// changes have no case at all.
    static func operations(for change: SchemaChange) -> [PluginSchemaOperation] {
        switch change {
        case .addColumn(let column):
            return [.addColumn(column.toPlugin())]
        case .modifyColumn(let old, let new):
            return [.modifyColumn(old: old.toPlugin(), new: new.toPlugin())]
        case .deleteColumn(let column):
            return [.dropColumn(column.toPlugin())]
        case .addIndex(let index):
            return [.addIndex(index.toPlugin())]
        case .modifyIndex(let old, let new):
            return [.modifyIndex(old: old.toPlugin(), new: new.toPlugin())]
        case .deleteIndex(let index):
            return [.dropIndex(index.toPlugin())]
        case .modifyCheckConstraint(let old, let new):
            guard old.expression == new.expression, old.name != new.name else { return [] }
            return [.renameCheckConstraint(from: old.name, to: new.name)]
        case .addCheckConstraint, .deleteCheckConstraint, .addForeignKey, .modifyForeignKey, .deleteForeignKey,
             .modifyPrimaryKey:
            return []
        }
    }

    static func reason(for definition: PluginCreateTableDefinition, driver: any PluginDatabaseDriver) -> String? {
        let operations = definition.columns.map(PluginSchemaOperation.addColumn)
            + definition.indexes.map(PluginSchemaOperation.addIndex)
        return operations.lazy.compactMap { driver.schemaOperationRefusal($0) }.first
    }
}
