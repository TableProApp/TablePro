//
//  StreamingRowProvider.swift
//  TablePro
//
//  Feeds the merge join from a driver's row stream. Only the current batch is
//  held, so neither side of a comparison is ever materialized in full.
//

import Foundation
import TableProPluginKit

internal struct RowReadContext: Sendable {
    internal let side: ComparisonSide
    internal let isFiltered: Bool

    internal func failure(_ error: Error) -> Error {
        guard !(error is CancellationError), !(error is CompareSyncError) else { return error }
        let reason = error.localizedDescription
        switch (side, isFiltered) {
        case (.source, false):
            return CompareSyncError.readFailed(
                String(format: String(localized: "The source could not be read: %@"), reason)
            )
        case (.source, true):
            return CompareSyncError.readFailed(
                String(format: String(localized: "The source could not be read with its filter: %@"), reason)
            )
        case (.target, false):
            return CompareSyncError.readFailed(
                String(format: String(localized: "The target could not be read: %@"), reason)
            )
        case (.target, true):
            return CompareSyncError.readFailed(
                String(format: String(localized: "The target could not be read with its filter: %@"), reason)
            )
        }
    }
}

internal final class StreamingRowProvider: DataRowProviding {
    /// The merge join awaits one `nextRow()` at a time, so the iterator is only ever advanced
    /// from a single task. Region isolation cannot see that invariant across the `next()` hop.
    nonisolated(unsafe) private var iterator: AsyncThrowingStream<PluginStreamElement, Error>.AsyncIterator
    private var columns: [String]
    private let rowLimit: Int?
    private let context: RowReadContext?
    private var buffer: [DataRow] = []
    private var bufferIndex = 0
    private var deliveredCount = 0
    private var isFinished = false

    internal init(
        stream: AsyncThrowingStream<PluginStreamElement, Error>,
        columns: [String] = [],
        rowLimit: Int? = nil,
        context: RowReadContext? = nil
    ) {
        self.iterator = stream.makeAsyncIterator()
        self.columns = columns
        self.rowLimit = rowLimit
        self.context = context
    }

    internal var endedAtRowLimit: Bool {
        guard let rowLimit, isFinished, bufferIndex >= buffer.count else { return false }
        return deliveredCount >= rowLimit
    }

    internal func nextRow() async throws -> DataRow? {
        while bufferIndex >= buffer.count {
            guard !isFinished else { return nil }
            try await fillBuffer()
        }
        defer {
            bufferIndex += 1
            deliveredCount += 1
        }
        return buffer[bufferIndex]
    }

    internal func drain() async throws {
        buffer = []
        bufferIndex = 0
        while !isFinished {
            guard try await nextElement() != nil else {
                isFinished = true
                return
            }
        }
    }

    private func fillBuffer() async throws {
        buffer = []
        bufferIndex = 0
        while buffer.isEmpty {
            guard let element = try await nextElement() else {
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

    private func nextElement() async throws -> PluginStreamElement? {
        do {
            return try await iterator.next()
        } catch {
            throw context?.failure(error) ?? error
        }
    }
}

internal enum KeyOrderedQuery {
    internal static func build(
        table: String,
        schema: String?,
        columns: [String],
        keyColumns: [String],
        filter: String? = nil,
        rowLimit: Int? = nil,
        driver: any PluginDatabaseDriver,
        databaseType: DatabaseType,
        dialect: SQLDialectDescriptor? = nil
    ) -> String {
        var conditions: [String] = []
        if let filter {
            conditions.append(CompareRowFilter.condition(for: filter))
        }
        if rowLimit != nil {
            conditions += keyColumns.map { "\(driver.quoteIdentifier($0)) IS NOT NULL" }
        }
        return SQLRowLimitClause.select(
            columns: columnList(columns, driver: driver),
            from: source(table: table, schema: schema, driver: driver, databaseType: databaseType),
            where: conditions.isEmpty ? nil : conditions.joined(separator: " AND "),
            orderBy: orderBy(keyColumns, driver: driver),
            limit: rowLimit,
            dialect: dialect
        )
    }

    internal static func lookup(
        table: String,
        schema: String?,
        columns: [String],
        keyColumns: [String],
        keyTypes: [ColumnType?],
        keys: [[PluginCellValue]],
        driver: any PluginDatabaseDriver,
        databaseType: DatabaseType
    ) -> String {
        SQLRowLimitClause.select(
            columns: columnList(columns, driver: driver),
            from: source(table: table, schema: schema, driver: driver, databaseType: databaseType),
            where: keyCondition(
                keyColumns: keyColumns, keyTypes: keyTypes, keys: keys, driver: driver, databaseType: databaseType
            ),
            orderBy: orderBy(keyColumns, driver: driver),
            dialect: nil
        )
    }

    private static func columnList(_ columns: [String], driver: any PluginDatabaseDriver) -> String {
        columns.isEmpty ? "*" : columns.map { driver.quoteIdentifier($0) }.joined(separator: ", ")
    }

    private static func source(
        table: String,
        schema: String?,
        driver: any PluginDatabaseDriver,
        databaseType: DatabaseType
    ) -> String {
        SchemaQualifiedName.render(name: table, schema: schema, databaseType: databaseType, quote: driver.quoteIdentifier)
    }

    private static func orderBy(_ keyColumns: [String], driver: any PluginDatabaseDriver) -> String? {
        guard !keyColumns.isEmpty else { return nil }
        return keyColumns.map { driver.quoteIdentifier($0) }.joined(separator: ", ")
    }

    private static func keyCondition(
        keyColumns: [String],
        keyTypes: [ColumnType?],
        keys: [[PluginCellValue]],
        driver: any PluginDatabaseDriver,
        databaseType: DatabaseType
    ) -> String {
        func literal(_ value: PluginCellValue, at index: Int) -> String {
            CompareSQLLiteral.literal(
                for: value,
                columnType: index < keyTypes.count ? keyTypes[index] : nil,
                databaseType: databaseType,
                driver: driver
            )
        }
        if keyColumns.count == 1, let column = keyColumns.first {
            let values = keys.compactMap { $0.first }.map { literal($0, at: 0) }.joined(separator: ", ")
            return "\(driver.quoteIdentifier(column)) IN (\(values))"
        }
        return keys
            .map { key in
                let terms = keyColumns.enumerated().map { index, column in
                    let value = index < key.count ? key[index] : .null
                    return "\(driver.quoteIdentifier(column)) = \(literal(value, at: index))"
                }
                return "(\(terms.joined(separator: " AND ")))"
            }
            .joined(separator: " OR ")
    }
}
