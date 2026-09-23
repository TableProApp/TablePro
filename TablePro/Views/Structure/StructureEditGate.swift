//
//  StructureEditGate.swift
//  TablePro
//
//  What the Structure tab may offer for one connection and one object.
//

import Foundation
import TableProPluginKit

/// The Structure tab's single answer to "may this edit be offered on this object".
///
/// One value rather than a flag per call site, because the footer pair, the grid's own keyboard and
/// context-menu paths, the reorder drag and the per-column lock all have to agree. They did not: the
/// footer read the engine's capability flags, the grid delegate read them again in its own guards,
/// and only the foreign key and reorder policies asked about the object at all, as
/// `isTable: !isViewObject`, which cannot say that a materialized view takes `CREATE INDEX` and
/// refuses `SET DEFAULT`. (#2726)
@MainActor
struct StructureEditGate {
    let databaseType: DatabaseType
    let objectKind: TableInfo.TableType

    private var matrix: StructureObjectEditMatrix {
        PluginManager.shared.structureEditMatrix(for: databaseType)
    }

    private var canEditSchema: Bool { databaseType.supportsSchemaEditing }

    func allows(_ operation: StructureEditOperation) -> Bool {
        resolve(operation).isAvailable
    }

    func resolve(_ operation: StructureEditOperation) -> StructureEditAvailability {
        /// The foreign key arm is answered by `ForeignKeyEditPolicy`, which also owns the `.alter`
        /// versus `.rebuild` distinction the save itself reads, and which words an engine's refusal
        /// as "cannot add or remove a table's foreign keys" rather than the sentence every other
        /// constraint shares. Routing it through here rather than beside here is what keeps every
        /// call site asking one object.
        if operation == .addForeignKey || operation == .dropForeignKey {
            return foreignKeyAvailability.structureEditAvailability
        }
        return StructureEditEligibility.resolve(
            operation,
            on: objectKind,
            matrix: matrix,
            engineAllows: engineSupports(operation),
            engineName: databaseType.displayName,
            canEditSchema: canEditSchema
        )
    }

    var foreignKeyAvailability: ForeignKeyEditAvailability {
        ForeignKeyEditPolicy.resolve(
            support: PluginManager.shared.foreignKeyEditSupport(for: databaseType),
            engineName: databaseType.displayName,
            kindRefusal: kindRefusal(.addForeignKey),
            canEditSchema: canEditSchema
        )
    }

    /// Why the object's kind refuses the operation, ignoring the engine. Handed to
    /// `ForeignKeyEditPolicy` and `ColumnReorderPolicy`, which own the engine half of the same
    /// decision and would otherwise have to word a refusal about a kind they cannot see.
    func kindRefusal(_ operation: StructureEditOperation) -> String? {
        StructureEditEligibility.refusalReason(for: operation, on: objectKind, matrix: matrix)
    }

    /// Every field of the Columns grid this object lets the user change. A view keeps Name, Default
    /// and Comment editable while Nullable, Type and the rest lock, because that is what PostgreSQL
    /// accepts on one.
    var editableColumnFields: Set<StructureColumnField> {
        guard canEditSchema else { return [] }
        return StructureEditEligibility.editableFields(on: objectKind, matrix: matrix)
    }

    var allowsAnyEdit: Bool {
        canEditSchema && StructureEditEligibility.allowsAnyEdit(on: objectKind, matrix: matrix)
    }

    var allowsTriggerEditing: Bool {
        databaseType.supportsTriggerEditing && TriggerEditEligibility.kindAcceptsTriggers(objectKind)
    }

    func locksField(at index: Int, on tab: StructureTab, orderedFields: [StructureColumnField]) -> Bool {
        switch tab {
        case .columns:
            guard orderedFields.indices.contains(index) else { return false }
            return !editableColumnFields.contains(orderedFields[index])
        case .indexes, .foreignKeys, .checkConstraints:
            guard let adding = StructureFooterPolicy.operation(forAdding: tab) else { return false }
            return !allows(adding)
        case .ddl, .parts, .triggers:
            return false
        }
    }

    func lockedFieldIndices(
        on tab: StructureTab,
        orderedFields: [StructureColumnField],
        fieldCount: Int
    ) -> Set<Int> {
        Set((0..<fieldCount).filter { locksField(at: $0, on: tab, orderedFields: orderedFields) })
    }

    /// Whether the engine has a statement for this operation at all, which is a different question
    /// from whether the object's kind accepts it. An engine with no `ADD CONSTRAINT … FOREIGN KEY`
    /// refuses it on a plain table too.
    ///
    /// Exhaustive on purpose. The column attribute changes carry no capability flag of their own and
    /// are covered by `supportsSchemaEditing`, so a `default:` arm here would silently swallow a new
    /// operation that does need one.
    private func engineSupports(_ operation: StructureEditOperation) -> Bool {
        switch operation {
        case .addColumn:
            return databaseType.supportsAddColumn
        case .dropColumn:
            return databaseType.supportsDropColumn
        case .addIndex:
            return databaseType.supportsAddIndex
        case .dropIndex:
            return databaseType.supportsDropIndex
        case .addForeignKey, .dropForeignKey:
            /// `resolve` answers these through `ForeignKeyEditPolicy` before reaching here. Stated
            /// anyway so this switch stays total over the operations, which is what makes a new one
            /// fail to compile until somebody decides its engine half.
            return PluginManager.shared.foreignKeyEditSupport(for: databaseType).isEditable
        case .addCheckConstraint, .dropCheckConstraint:
            return databaseType.supportsCheckConstraintEditing
        case .reorderColumns:
            return PluginManager.shared.columnReorderSupport(for: databaseType) != .unsupported
        case .renameColumn, .setNotNull, .dropNotNull, .setDefault, .dropDefault,
             .changeColumnType, .redefineColumn, .commentOnColumn:
            return true
        }
    }
}
