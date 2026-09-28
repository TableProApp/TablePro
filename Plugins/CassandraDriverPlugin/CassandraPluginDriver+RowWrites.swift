//
//  CassandraPluginDriver+RowWrites.swift
//  CassandraDriverPlugin
//

import Foundation
import TableProPluginKit

extension CassandraPluginDriver {
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
        try CassandraRowWriter.rowWrites(
            keyspace: schema,
            table: table,
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            changes: changes,
            insertedRowData: insertedRowData
        )
    }

    func generateIdentityPreservingInsert(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        rows: [[PluginCellValue]],
        absentCells: [Int: Set<Int>]
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        CassandraRowWriter.restoreInserts(keyspace: schema, table: table, columns: columns, rows: rows)
    }
}
