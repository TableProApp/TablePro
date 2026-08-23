//
//  StreamingRowProvider.swift
//  TablePro
//
//  Feeds the merge join from a driver's row stream. Only the current batch is
//  held, so neither side of a comparison is ever materialized in full.
//

import Foundation
import TableProPluginKit

internal final class StreamingRowProvider: DataRowProviding {
    /// The merge join awaits one `nextRow()` at a time, so the iterator is only ever advanced
    /// from a single task. Region isolation cannot see that invariant across the `next()` hop.
    nonisolated(unsafe) private var iterator: AsyncThrowingStream<PluginStreamElement, Error>.AsyncIterator
    private var columns: [String]
    private var buffer: [DataRow] = []
    private var bufferIndex = 0
    private var isFinished = false

    internal init(stream: AsyncThrowingStream<PluginStreamElement, Error>, columns: [String] = []) {
        self.iterator = stream.makeAsyncIterator()
        self.columns = columns
    }

    internal func nextRow() async throws -> DataRow? {
        while bufferIndex >= buffer.count {
            guard !isFinished else { return nil }
            try await fillBuffer()
        }
        defer { bufferIndex += 1 }
        return buffer[bufferIndex]
    }

    private func fillBuffer() async throws {
        buffer = []
        bufferIndex = 0
        while buffer.isEmpty {
            guard let element = try await iterator.next() else {
                isFinished = true
                return
            }
            switch element {
            case .header(let header):
                if columns.isEmpty { columns = header.columns }
            case .rows(let rows):
                buffer = rows.map { row in
                    var values: [String: PluginCellValue] = [:]
                    for (index, column) in columns.enumerated() where index < row.count {
                        values[column] = row[index]
                    }
                    return DataRow(values: values)
                }
            }
        }
    }
}

internal enum KeyOrderedQuery {
    internal static func build(
        table: String,
        schema: String?,
        columns: [String],
        keyColumns: [String],
        driver: any PluginDatabaseDriver
    ) -> String {
        let columnList = columns.isEmpty
            ? "*"
            : columns.map { driver.quoteIdentifier($0) }.joined(separator: ", ")
        let orderBy = keyColumns.map { driver.quoteIdentifier($0) }.joined(separator: ", ")
        var sql = "SELECT \(columnList) FROM \(qualified(table, schema, driver))"
        if !orderBy.isEmpty {
            sql += " ORDER BY \(orderBy)"
        }
        return sql
    }

    private static func qualified(_ table: String, _ schema: String?, _ driver: any PluginDatabaseDriver) -> String {
        guard let schema, !schema.isEmpty else { return driver.quoteIdentifier(table) }
        return "\(driver.quoteIdentifier(schema)).\(driver.quoteIdentifier(table))"
    }
}
