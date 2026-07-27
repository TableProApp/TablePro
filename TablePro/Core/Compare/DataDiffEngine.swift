//
//  DataDiffEngine.swift
//  TablePro
//
//  Key-ordered merge join over two row providers. Both sides are read in key
//  order and walked in lockstep, so neither side is ever materialized and no
//  server-side hash function has to agree between two engines.
//

import Foundation
import TableProPluginKit

internal struct DataRow: Hashable {
    internal let values: [String: PluginCellValue]

    internal func value(for column: String) -> PluginCellValue {
        if let exact = values[column] { return exact }
        let lowered = column.lowercased()
        guard let match = values.first(where: { $0.key.lowercased() == lowered }) else { return .null }
        return match.value
    }
}

internal protocol DataRowProviding: AnyObject {
    func nextRow() async throws -> DataRow?
}

internal enum RowDiffKind: String, Codable, Hashable, Sendable {
    case insert
    case update
    case delete
    case identical
}

internal struct CellDifference: Hashable {
    internal let column: String
    internal let rule: ComparisonRule
    internal let sourceValue: PluginCellValue
    internal let targetValue: PluginCellValue
}

internal struct RowDiffEntry: Identifiable, Hashable {
    internal let id: UUID
    internal let kind: RowDiffKind
    internal let keyDescription: String
    internal let sourceRow: DataRow?
    internal let targetRow: DataRow?
    internal let cellDifferences: [CellDifference]

    internal init(
        id: UUID = UUID(),
        kind: RowDiffKind,
        keyDescription: String,
        sourceRow: DataRow?,
        targetRow: DataRow?,
        cellDifferences: [CellDifference] = []
    ) {
        self.id = id
        self.kind = kind
        self.keyDescription = keyDescription
        self.sourceRow = sourceRow
        self.targetRow = targetRow
        self.cellDifferences = cellDifferences
    }
}

internal struct DataDiffSummary {
    internal let insertCount: Int
    internal let updateCount: Int
    internal let deleteCount: Int
    internal let identicalCount: Int
    internal let entries: [RowDiffEntry]
    internal let truncatedEntries: Bool

    internal var differenceCount: Int {
        insertCount + updateCount + deleteCount
    }

    internal var totalCount: Int {
        differenceCount + identicalCount
    }
}

internal struct DataDiffEngine {
    private let options: DataCompareOptions
    private let comparator: CellValueComparator
    private let comparisonColumns: [String]

    internal init(options: DataCompareOptions, columns: [String]) {
        self.options = options
        self.comparator = CellValueComparator(options: options)
        self.comparisonColumns = options.comparisonColumns(from: columns)
    }

    internal func compare(
        source: DataRowProviding,
        target: DataRowProviding
    ) async throws -> DataDiffSummary {
        guard options.hasKey else {
            throw CompareSyncError.noComparisonKey(String(localized: "Choose a key column before comparing data."))
        }

        var accumulator = Accumulator(limit: options.maxRetainedEntries)
        var sourceRow = try await source.nextRow()
        var targetRow = try await target.nextRow()

        while sourceRow != nil || targetRow != nil {
            try Task.checkCancellation()

            guard let left = sourceRow else {
                accumulator.add(deleteEntry(for: targetRow))
                targetRow = try await target.nextRow()
                continue
            }
            guard let right = targetRow else {
                accumulator.add(insertEntry(for: left))
                sourceRow = try await source.nextRow()
                continue
            }

            let leftKey = keyComponents(of: left)
            let rightKey = keyComponents(of: right)
            switch KeyOrdering.compare(leftKey, rightKey) {
            case .orderedSame:
                accumulator.add(matchedEntry(source: left, target: right))
                sourceRow = try await source.nextRow()
                targetRow = try await target.nextRow()
            case .orderedAscending:
                accumulator.add(insertEntry(for: left))
                sourceRow = try await source.nextRow()
            case .orderedDescending:
                accumulator.add(deleteEntry(for: right))
                targetRow = try await target.nextRow()
            }
        }

        return accumulator.summary()
    }

    private func insertEntry(for row: DataRow) -> RowDiffEntry {
        RowDiffEntry(
            kind: .insert,
            keyDescription: keyDescription(of: row),
            sourceRow: row,
            targetRow: nil
        )
    }

    private func deleteEntry(for row: DataRow?) -> RowDiffEntry {
        RowDiffEntry(
            kind: .delete,
            keyDescription: row.map { keyDescription(of: $0) } ?? "",
            sourceRow: nil,
            targetRow: row
        )
    }

    private func matchedEntry(source: DataRow, target: DataRow) -> RowDiffEntry {
        var differences: [CellDifference] = []
        for column in comparisonColumns {
            let sourceValue = source.value(for: column)
            let targetValue = target.value(for: column)
            let outcome = comparator.compare(sourceValue, targetValue)
            guard !outcome.isEqual else { continue }
            differences.append(CellDifference(
                column: column,
                rule: outcome.rule,
                sourceValue: sourceValue,
                targetValue: targetValue
            ))
        }
        return RowDiffEntry(
            kind: differences.isEmpty ? .identical : .update,
            keyDescription: keyDescription(of: source),
            sourceRow: source,
            targetRow: target,
            cellDifferences: differences
        )
    }

    private func keyComponents(of row: DataRow) -> [PluginCellValue] {
        options.keyColumns.map { row.value(for: $0) }
    }

    private func keyDescription(of row: DataRow) -> String {
        options.keyColumns
            .map { column in KeyOrdering.sortKey(row.value(for: column)) }
            .joined(separator: ", ")
    }
}

private extension DataDiffEngine {
    struct Accumulator {
        private let limit: Int
        private var insertCount = 0
        private var updateCount = 0
        private var deleteCount = 0
        private var identicalCount = 0
        private var entries: [RowDiffEntry] = []
        private var truncated = false

        init(limit: Int) {
            self.limit = limit
        }

        mutating func add(_ entry: RowDiffEntry) {
            switch entry.kind {
            case .insert: insertCount += 1
            case .update: updateCount += 1
            case .delete: deleteCount += 1
            case .identical: identicalCount += 1
            }
            guard entries.count < limit else {
                truncated = true
                return
            }
            entries.append(entry)
        }

        func summary() -> DataDiffSummary {
            DataDiffSummary(
                insertCount: insertCount,
                updateCount: updateCount,
                deleteCount: deleteCount,
                identicalCount: identicalCount,
                entries: entries,
                truncatedEntries: truncated
            )
        }
    }
}

internal enum KeyOrdering {
    internal static func compare(_ lhs: [PluginCellValue], _ rhs: [PluginCellValue]) -> ComparisonResult {
        for (left, right) in zip(lhs, rhs) {
            let leftKey = sortKey(left)
            let rightKey = sortKey(right)
            if leftKey == rightKey { continue }
            if let leftNumber = Double(leftKey), let rightNumber = Double(rightKey) {
                return leftNumber < rightNumber ? .orderedAscending : .orderedDescending
            }
            return leftKey < rightKey ? .orderedAscending : .orderedDescending
        }
        if lhs.count == rhs.count { return .orderedSame }
        return lhs.count < rhs.count ? .orderedAscending : .orderedDescending
    }

    internal static func sortKey(_ value: PluginCellValue) -> String {
        switch value {
        case .null: return ""
        case .text(let text): return text
        case .bytes(let data): return data.base64EncodedString()
        }
    }
}

internal final class ArrayRowProvider: DataRowProviding {
    private var rows: [DataRow]
    private var index = 0

    internal init(rows: [DataRow]) {
        self.rows = rows
    }

    internal func nextRow() async throws -> DataRow? {
        guard index < rows.count else { return nil }
        defer { index += 1 }
        return rows[index]
    }
}
