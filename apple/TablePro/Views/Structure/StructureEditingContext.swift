//
//  StructureEditingContext.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// The table a structure editor works on: an existing one, or the one Create Table is drafting.
@MainActor
struct StructureEditingContext {
    let connection: DatabaseConnection
    let databaseName: String
    let schemaName: String?
    let tableName: String
    let objectKind: TableInfo.TableType
    let isSessionBound: Bool
    let isCreatingTable: Bool

    static func existingTable(
        connection: DatabaseConnection,
        databaseName: String,
        schemaName: String?,
        tableName: String,
        objectKind: TableInfo.TableType,
        isSessionBound: Bool
    ) -> StructureEditingContext {
        StructureEditingContext(
            connection: connection,
            databaseName: databaseName,
            schemaName: schemaName,
            tableName: tableName,
            objectKind: objectKind,
            isSessionBound: isSessionBound,
            isCreatingTable: false
        )
    }

    static func newTable(connection: DatabaseConnection, databaseName: String, schemaName: String?) -> StructureEditingContext {
        StructureEditingContext(
            connection: connection,
            databaseName: databaseName,
            schemaName: schemaName,
            tableName: "",
            objectKind: .table,
            isSessionBound: false,
            isCreatingTable: true
        )
    }

    var databaseType: DatabaseType { connection.type }

    var scope: DatabaseScope {
        DatabaseScope(connectionId: connection.id, database: databaseName, schema: schemaName, isSessionBound: isSessionBound)
    }

    var editGate: StructureEditGate {
        StructureEditGate(databaseType: connection.type, objectKind: objectKind, schema: schemaName, isSessionBound: isSessionBound)
    }

    // A drafted table is created in one run, so every definition it can hold is open; an existing one asks the gate.
    // Its checks are added after the CREATE, so they need an engine that adds one to an existing table.
    func allows(_ operation: StructureEditOperation) -> Bool {
        guard isCreatingTable else { return editGate.allows(operation) }
        switch operation {
        case .addForeignKey, .dropForeignKey:
            return connection.type.supportsForeignKeys
        case .addCheckConstraint, .dropCheckConstraint:
            return connection.type.supportsCheckConstraintEditing
        default:
            return true
        }
    }

    func refusal(_ operation: StructureEditOperation) -> String? {
        guard !isCreatingTable else { return nil }
        return editGate.resolve(operation).unavailableReason
    }

    func addOperation(for section: StructureSection) -> StructureEditOperation {
        switch section {
        case .columns: .addColumn
        case .indexes: .addIndex
        case .foreignKeys: .addForeignKey
        case .checkConstraints: .addCheckConstraint
        }
    }

    func removeOperation(for section: StructureSection) -> StructureEditOperation {
        switch section {
        case .columns: .dropColumn
        case .indexes: .dropIndex
        case .foreignKeys: .dropForeignKey
        case .checkConstraints: .dropCheckConstraint
        }
    }
}
