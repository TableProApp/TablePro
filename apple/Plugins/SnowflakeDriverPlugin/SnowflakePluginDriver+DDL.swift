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
    func generateRowWrites(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) throws -> [PluginRowWrite]? {
        try generateRowWrites(
            table: table, schema: schema, columns: columns, primaryKeyColumns: primaryKeyColumns, changes: changes,
            insertedRowData: insertedRowData, deletedRowIndices: deletedRowIndices,
            insertedRowIndices: insertedRowIndices, context: PluginRowWriteContext()
        )
    }

    // The host read the types on whichever connection loaded the table; this driver's cache may never have seen it.
    func generateRowWrites(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>,
        context: PluginRowWriteContext
    ) throws -> [PluginRowWrite]? {
        try generator(table: table, schema: schema, columns: columns, primaryKeyColumns: primaryKeyColumns, context: context)
            .rowWrites(
                from: changes,
                insertedRowData: insertedRowData,
                deletedRowIndices: deletedRowIndices,
                insertedRowIndices: insertedRowIndices
            )
    }

    func generateIdentityPreservingInsert(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        rows: [[PluginCellValue]]
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        generator(table: table, schema: schema, columns: columns, primaryKeyColumns: primaryKeyColumns, context: nil)
            .restoreStatements(rows: rows)
    }

    private func generator(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        context: PluginRowWriteContext?
    ) -> SnowflakeStatementGenerator {
        let cached = columnTypeNames(for: table, columns: columns)
        let read = context?.columnTypeNames ?? [:]
        return SnowflakeStatementGenerator(
            qualifiedTable: qualifiedName(table: table, schema: schema),
            columns: columns,
            columnTypeNames: zip(columns, cached).map { read[$0] ?? $1 },
            primaryKeyColumns: primaryKeyColumns
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

    func objectCommentStatement(name: String, objectType: String, schema: String?, comment: String?) -> String? {
        SnowflakeDDLGenerator.objectCommentSQL(
            qualifiedName: qualifiedName(table: name, schema: schema),
            objectType: objectType,
            comment: comment
        )
    }
}
