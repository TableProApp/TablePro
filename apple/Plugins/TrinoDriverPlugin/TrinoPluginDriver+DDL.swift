import Foundation
import TableProPluginKit
import TableProTrinoCore

extension TrinoPluginDriver {
    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        TrinoDDLSQL.addColumn(qualifiedTable: qualifiedName(table: table, schema: nil), column: columnSpec(column))
    }

    func generateDropColumnSQL(table: String, columnName: String) -> String? {
        TrinoDDLSQL.dropColumn(qualifiedTable: qualifiedName(table: table, schema: nil), name: columnName)
    }

    func generateModifyColumnSQL(
        table: String,
        oldColumn: PluginColumnDefinition,
        newColumn: PluginColumnDefinition
    ) -> String? {
        let target = qualifiedName(table: table, schema: nil)
        var statements: [String] = []
        if oldColumn.name != newColumn.name {
            statements.append(TrinoDDLSQL.renameColumn(qualifiedTable: target, from: oldColumn.name, to: newColumn.name))
        }
        if oldColumn.dataType != newColumn.dataType {
            guard let statement = TrinoDDLSQL.setColumnType(
                qualifiedTable: target, name: newColumn.name, type: newColumn.dataType
            ) else { return nil }
            statements.append(statement)
        }
        if oldColumn.comment != newColumn.comment {
            statements.append(TrinoDDLSQL.setColumnComment(
                qualifiedTable: target,
                name: newColumn.name,
                comment: normalizedComment(newColumn.comment)
            ))
        }
        return statements.isEmpty ? nil : statements.joined(separator: ";\n")
    }

    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String? {
        TrinoDDLSQL.createTable(
            qualifiedTable: qualifiedName(table: definition.tableName, schema: nil),
            columns: definition.columns.map(columnSpec),
            tableComment: nil,
            ifNotExists: definition.ifNotExists
        )
    }

    func schemaOperationRefusal(_ operation: PluginSchemaOperation) -> String? {
        let column: PluginColumnDefinition
        switch operation {
        case .addColumn(let added):
            column = added
        case .modifyColumn(let old, let new) where old.dataType != new.dataType:
            column = new
        default:
            return nil
        }
        guard !TrinoTypeMapper.isWritable(column.dataType) else { return nil }
        return Self.unwritableTypeReason(column: column.name, type: column.dataType)
    }

    static func unwritableTypeReason(column: String, type: String) -> String {
        String(format: String(localized: "The type of column %@ does not read as one type: %@"), column, type)
    }

    // Presto has no COMMENT ON statement.
    func objectCommentStatement(name: String, objectType: String, schema: String?, comment: String?) -> String? {
        guard flavor == .trino else { return nil }
        return TrinoDDLSQL.objectComment(
            qualifiedName: qualifiedName(table: name, schema: schema),
            objectType: objectType,
            comment: comment
        )
    }

    func createViewTemplate() -> String? {
        "CREATE OR REPLACE VIEW view_name AS\nSELECT column1, column2\nFROM table_name\nWHERE condition;"
    }

    private func columnSpec(_ column: PluginColumnDefinition) -> TrinoColumnSpec {
        TrinoColumnSpec(
            name: column.name,
            type: column.dataType,
            nullable: column.isNullable,
            comment: normalizedComment(column.comment)
        )
    }

    func normalizedComment(_ comment: String?) -> String? {
        guard let comment, !comment.isEmpty else { return nil }
        return comment
    }
}
