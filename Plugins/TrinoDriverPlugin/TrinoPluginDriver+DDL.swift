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
            statements.append(TrinoDDLSQL.setColumnType(qualifiedTable: target, name: newColumn.name, type: newColumn.dataType))
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
