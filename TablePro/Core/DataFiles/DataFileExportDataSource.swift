//
//  DataFileExportDataSource.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProTabular
import TableProTabularIO

enum DataFileExportRows: Sendable, Equatable {
    case all
    case keys([Int])

    func count(in table: TabularTable) -> Int {
        switch self {
        case .all: return table.rowCount
        case .keys(let keys): return keys.count
        }
    }
}

final class DataFileExportDataSource: PluginExportDataSource {
    static let batchSize = 4_096

    let databaseTypeId: String
    private let table: TabularTable
    private let columns: [TabularColumnID]
    private let columnNames: [String]
    private let columnTypeNames: [String]
    private let rows: DataFileExportRows

    init(
        table: TabularTable,
        columns: [TabularColumnID],
        columnNames: [String],
        columnTypeNames: [String],
        rows: DataFileExportRows,
        databaseTypeId: String = DataSourceExportRequest.dataFileTypeId
    ) {
        self.table = table
        self.columns = columns
        self.columnNames = columnNames
        self.columnTypeNames = columnTypeNames
        self.rows = rows
        self.databaseTypeId = databaseTypeId
    }

    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let snapshot = self.table
        let columns = self.columns
        let rows = self.rows
        let total = rows.count(in: snapshot)
        let header = PluginStreamHeader(
            columns: columnNames,
            columnTypeNames: columnTypeNames,
            estimatedRowCount: total
        )
        return AsyncThrowingStream { continuation in
            let producer = Task {
                continuation.yield(.header(header))
                var start = 0
                while start < total {
                    guard !Task.isCancelled else {
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    let end = min(start + Self.batchSize, total)
                    continuation.yield(.rows(Self.batch(start..<end, of: rows, in: snapshot, columns: columns)))
                    start = end
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    static func batch(
        _ range: Range<Int>,
        of rows: DataFileExportRows,
        in table: TabularTable,
        columns: [TabularColumnID]
    ) -> [PluginRow] {
        var output: [PluginRow] = []
        output.reserveCapacity(range.count)
        let append: (Int, TabularRowCells) -> Bool = { _, cells in
            var row: PluginRow = []
            row.reserveCapacity(cells.count)
            for index in 0..<cells.count {
                row.append(cells.kinds[index].isNullLike ? .null : .text(cells.string(at: index)))
            }
            output.append(row)
            return true
        }
        switch rows {
        case .all:
            table.scan(columns: columns, rows: range, append)
        case .keys(let keys):
            table.scan(columns: columns, keys: keys[range], append)
        }
        return output
    }

    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? {
        rows.count(in: self.table)
    }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String {
        ""
    }

    func execute(query: String) async throws -> PluginQueryResult {
        throw ExportError.exportFailed(String(localized: "A data file cannot run queries."))
    }

    func quoteIdentifier(_ identifier: String) -> String {
        SQLEscaping.quoteIdentifier(identifier)
    }

    func escapeStringLiteral(_ value: String) -> String {
        SQLEscaping.escapeStringLiteral(value)
    }
}
