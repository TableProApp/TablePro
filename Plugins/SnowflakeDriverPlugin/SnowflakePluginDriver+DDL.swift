//
//  SnowflakePluginDriver+DDL.swift
//  SnowflakeDriverPlugin
//
//  DML statement generation for grid saves and DDL generation for the table
//  structure editor.
//

import Foundation
import TableProPluginKit

extension SnowflakePluginDriver {
    func generateStatements(
        table: String,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        let generator = SnowflakeStatementGenerator(
            qualifiedTable: qualifiedName(table: table, schema: nil),
            columns: columns,
            columnTypeNames: columnTypeNames(for: table, columns: columns),
            primaryKeyColumns: primaryKeyColumns
        )
        return generator.generateStatements(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices,
            insertedRowIndices: insertedRowIndices
        )
    }

    private var ddlGenerator: SnowflakeDDLGenerator {
        SnowflakeDDLGenerator(qualifiedTable: { [weak self] table in
            self?.qualifiedName(table: table, schema: nil) ?? table
        })
    }

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        ddlGenerator.addColumnSQL(table: table, column: column)
    }

    func generateModifyColumnSQL(
        table: String,
        oldColumn: PluginColumnDefinition,
        newColumn: PluginColumnDefinition
    ) -> String? {
        ddlGenerator.modifyColumnSQL(table: table, old: oldColumn, new: newColumn)
    }

    func generateDropColumnSQL(table: String, columnName: String) -> String? {
        ddlGenerator.dropColumnSQL(table: table, columnName: columnName)
    }

    func generateModifyPrimaryKeySQL(
        table: String,
        oldColumns: [String],
        newColumns: [String],
        constraintName: String?
    ) -> [String]? {
        ddlGenerator.modifyPrimaryKeySQL(table: table, oldColumns: oldColumns, newColumns: newColumns)
    }

    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String? {
        ddlGenerator.createTableSQL(definition: definition)
    }

    func generateColumnDefinitionSQL(column: PluginColumnDefinition) -> String? {
        ddlGenerator.columnDefinitionSQL(column)
    }
}
