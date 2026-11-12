//
//  CassandraPluginDriver+RowWrites.swift
//  CassandraDriverPlugin
//

import Foundation
import TableProCassandraCore
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
            insertedRowData: insertedRowData,
            lifetimes: keptLifetimes(keyspace: schema, table: table)
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
        CassandraRowWriter.restoreInserts(
            keyspace: schema,
            table: table,
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            rows: rows,
            lifetimes: keptLifetimes(keyspace: schema, table: table)
        )
    }

    // An unqualified write lands in the session's keyspace, the one an unqualified browse read.
    private func keptLifetimes(keyspace schema: String?, table: String) -> CassandraRowWriter.Lifetimes {
        let keyspace = schema.flatMap { $0.isEmpty ? nil : $0 } ?? currentSchema
        return { [cellLifetimes] key in
            guard let keyspace else { return nil }
            return cellLifetimes.lifetimes(
                of: CassandraRowIdentity(table: CassandraTableIdentity(keyspace: keyspace, table: table), key: key)
            )
        }
    }
}
