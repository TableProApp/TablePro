//
//  SurrealRowFlattener.swift
//  SurrealDBDriverPlugin
//

import Foundation
import TableProPluginKit

public struct SurrealFlattenedRows: Equatable, Sendable {
    public let columns: [String]
    public let columnTypeNames: [String]
    public let rows: [[PluginCellValue]]

    public init(columns: [String], columnTypeNames: [String], rows: [[PluginCellValue]]) {
        self.columns = columns
        self.columnTypeNames = columnTypeNames
        self.rows = rows
    }
}

public enum SurrealRowFlattener {
    public static func flatten(_ value: SurrealValue, knownColumns: [String] = []) -> SurrealFlattenedRows {
        let records = normalize(value)
        guard !records.isEmpty || !knownColumns.isEmpty else {
            return SurrealFlattenedRows(columns: [], columnTypeNames: [], rows: [])
        }

        if records.allSatisfy({ $0.objectPairs != nil }) {
            let columns = orderColumns(unionColumns(records, seeded: knownColumns))
            let rows = records.map { record in
                columns.map { cell(record[$0] ?? .none) }
            }
            return SurrealFlattenedRows(
                columns: columns,
                columnTypeNames: typeNames(for: columns, in: records),
                rows: rows
            )
        }

        let column = "result"
        return SurrealFlattenedRows(
            columns: [column],
            columnTypeNames: [records.first?.typeName ?? "any"],
            rows: records.map { [cell($0)] }
        )
    }

    public static func cell(_ value: SurrealValue) -> PluginCellValue {
        switch value {
        case .null, .none:
            return .null
        case let .bytes(data):
            return .bytes(data)
        default:
            return .text(value.displayText)
        }
    }

    // MARK: - Helpers

    private static func normalize(_ value: SurrealValue) -> [SurrealValue] {
        switch value {
        case let .array(items):
            return items
        case .null, .none:
            return []
        default:
            return [value]
        }
    }

    private static func unionColumns(_ records: [SurrealValue], seeded: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for column in seeded where !seen.contains(column) {
            seen.insert(column)
            ordered.append(column)
        }
        for record in records {
            guard let pairs = record.objectPairs else { continue }
            for pair in pairs where !seen.contains(pair.key) {
                seen.insert(pair.key)
                ordered.append(pair.key)
            }
        }
        return ordered
    }

    private static func orderColumns(_ columns: [String]) -> [String] {
        var ordered: [String] = []
        for pinned in [
            SurrealInfoParser.recordIdColumn,
            SurrealInfoParser.edgeInColumn,
            SurrealInfoParser.edgeOutColumn
        ] where columns.contains(pinned) {
            ordered.append(pinned)
        }
        ordered.append(contentsOf: columns.filter { !ordered.contains($0) })
        return ordered
    }

    private static func typeNames(for columns: [String], in records: [SurrealValue]) -> [String] {
        columns.map { column in
            for record in records {
                guard let value = record[column], !value.isAbsent else { continue }
                return value.typeName
            }
            return "any"
        }
    }
}
