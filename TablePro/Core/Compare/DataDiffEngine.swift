//
//  DataDiffEngine.swift
//  TablePro
//
//  Key-ordered merge join over two row providers. Both sides are read in key
//  order and walked in lockstep, so neither side is ever materialized and no
//  server-side hash function has to agree between two engines.
//
//  The walk depends on the client comparator agreeing with the order the server
//  sent rows in. See KeyOrdering: numeric keys agree by construction, and any
//  other key is verified as the stream is read, so a disagreeing collation is
//  reported instead of silently producing a delete for a row that exists on both
//  sides.
//

import Foundation
import TableProPluginKit

internal struct DataRow: Hashable, Sendable {
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

internal struct CellDifference: Hashable, Sendable {
    internal let column: String
    internal let rule: ComparisonRule
    internal let sourceValue: PluginCellValue
    internal let targetValue: PluginCellValue
}

internal struct RowDiffEntry: Identifiable, Hashable, Sendable {
    internal let id: UUID
    internal let kind: RowDiffKind
    internal let keyDescription: String
    internal let keyIdentity: String
    internal let sourceRow: DataRow?
    internal let targetRow: DataRow?
    internal let cellDifferences: [CellDifference]

    internal init(
        id: UUID = UUID(),
        kind: RowDiffKind,
        keyDescription: String,
        keyIdentity: String? = nil,
        sourceRow: DataRow?,
        targetRow: DataRow?,
        cellDifferences: [CellDifference] = []
    ) {
        self.id = id
        self.kind = kind
        self.keyDescription = keyDescription
        self.keyIdentity = keyIdentity ?? keyDescription
        self.sourceRow = sourceRow
        self.targetRow = targetRow
        self.cellDifferences = cellDifferences
    }
}

internal struct DataDiffSummary: Hashable, Sendable {
    internal let insertCount: Int
    internal let updateCount: Int
    internal let deleteCount: Int
    internal let identicalCount: Int
    internal let skippedNullKeyCount: Int
    internal let entries: [RowDiffEntry]
    internal let truncatedEntries: Bool

    internal var differenceCount: Int {
        insertCount + updateCount + deleteCount
    }

    internal var totalCount: Int {
        differenceCount + identicalCount
    }
}

internal struct KeyedRow {
    internal let row: DataRow
    internal let key: [PluginCellValue]
}

internal enum ComparisonSide: String {
    case source
    case target

    internal var displayName: String {
        switch self {
        case .source: return String(localized: "source")
        case .target: return String(localized: "target")
        }
    }
}

internal struct DataDiffEngine {
    private let options: DataCompareOptions
    private let comparator: CellValueComparator
    private let comparisonColumns: [String]
    private let ordering: KeyOrdering

    internal init(
        options: DataCompareOptions,
        columns: [String],
        keyDescriptors: [KeyColumnDescriptor] = []
    ) {
        self.options = options
        self.comparator = CellValueComparator(options: options)
        self.comparisonColumns = options.comparisonColumns(from: columns)
        self.ordering = KeyOrdering(
            orders: KeyOrdering.orders(for: options.keyColumns, descriptors: keyDescriptors)
        )
    }

    /// `onEntry` sees every entry the walk produces, before the accumulator's retention cap.
    /// Script generation runs the walk a second time with a sink rather than reading the capped
    /// entry list, because that list is a preview: building the script from it emitted 5,000
    /// statements for a 12,000-row difference and reported success.
    internal func compare(
        source: DataRowProviding,
        target: DataRowProviding,
        onEntry: ((RowDiffEntry) throws -> Void)? = nil
    ) async throws -> DataDiffSummary {
        guard options.hasKey else {
            throw CompareSyncError.noComparisonKey(String(localized: "Choose a key column before comparing data."))
        }

        var accumulator = Accumulator(limit: options.maxRetainedEntries)
        let sourceReader = KeyedRowReader(
            provider: source, keyColumns: options.keyColumns, ordering: ordering, side: .source
        )
        let targetReader = KeyedRowReader(
            provider: target, keyColumns: options.keyColumns, ordering: ordering, side: .target
        )

        var left = try await sourceReader.next(&accumulator)
        var right = try await targetReader.next(&accumulator)

        func record(_ entry: RowDiffEntry) throws {
            accumulator.add(entry)
            try onEntry?(entry)
        }

        while left != nil || right != nil {
            try Task.checkCancellation()

            guard let sourceEntry = left else {
                try record(deleteEntry(for: right))
                right = try await targetReader.next(&accumulator)
                continue
            }
            guard let targetEntry = right else {
                try record(insertEntry(for: sourceEntry))
                left = try await sourceReader.next(&accumulator)
                continue
            }

            switch ordering.compare(sourceEntry.key, targetEntry.key) {
            case .orderedSame:
                try record(matchedEntry(source: sourceEntry, target: targetEntry))
                left = try await sourceReader.next(&accumulator)
                right = try await targetReader.next(&accumulator)
            case .orderedAscending:
                try record(insertEntry(for: sourceEntry))
                left = try await sourceReader.next(&accumulator)
            case .orderedDescending:
                try record(deleteEntry(for: targetEntry))
                right = try await targetReader.next(&accumulator)
            }
        }

        return accumulator.summary()
    }

    private func insertEntry(for entry: KeyedRow) -> RowDiffEntry {
        RowDiffEntry(
            kind: .insert,
            keyDescription: KeyOrdering.description(of: entry.key),
            keyIdentity: KeyOrdering.identity(of: entry.key),
            sourceRow: entry.row,
            targetRow: nil
        )
    }

    private func deleteEntry(for entry: KeyedRow?) -> RowDiffEntry {
        RowDiffEntry(
            kind: .delete,
            keyDescription: entry.map { KeyOrdering.description(of: $0.key) } ?? "",
            keyIdentity: entry.map { KeyOrdering.identity(of: $0.key) } ?? "",
            sourceRow: nil,
            targetRow: entry?.row
        )
    }

    private func matchedEntry(source: KeyedRow, target: KeyedRow) -> RowDiffEntry {
        var differences: [CellDifference] = []
        for column in comparisonColumns {
            let sourceValue = source.row.value(for: column)
            let targetValue = target.row.value(for: column)
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
            keyDescription: KeyOrdering.description(of: source.key),
            keyIdentity: KeyOrdering.identity(of: source.key),
            sourceRow: source.row,
            targetRow: target.row,
            cellDifferences: differences
        )
    }
}

internal extension DataDiffEngine {
    struct Accumulator {
        private let limit: Int
        private var insertCount = 0
        private var updateCount = 0
        private var deleteCount = 0
        private var identicalCount = 0
        private var skippedNullKeyCount = 0
        private var entries: [RowDiffEntry] = []
        private var truncated = false

        init(limit: Int) {
            self.limit = limit
        }

        mutating func addSkippedNullKey() {
            skippedNullKeyCount += 1
        }

        /// Only differences are retained. Keeping identical rows too meant a table with 100,000
        /// matching rows and ten differences near the end filled the retained list with matches and
        /// dropped every difference, so the pane reported a count and listed nothing. The identical
        /// count stays exact and the pane reports it as a number rather than as rows.
        mutating func add(_ entry: RowDiffEntry) {
            switch entry.kind {
            case .insert: insertCount += 1
            case .update: updateCount += 1
            case .delete: deleteCount += 1
            case .identical:
                identicalCount += 1
                return
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
                skippedNullKeyCount: skippedNullKeyCount,
                entries: entries,
                truncatedEntries: truncated
            )
        }
    }
}

private final class KeyedRowReader {
    private let provider: DataRowProviding
    private let keyColumns: [String]
    private let ordering: KeyOrdering
    private let side: ComparisonSide
    private var previousKey: [PluginCellValue]?

    init(provider: DataRowProviding, keyColumns: [String], ordering: KeyOrdering, side: ComparisonSide) {
        self.provider = provider
        self.keyColumns = keyColumns
        self.ordering = ordering
        self.side = side
    }

    func next(_ accumulator: inout DataDiffEngine.Accumulator) async throws -> KeyedRow? {
        while let row = try await provider.nextRow() {
            let key = keyColumns.map { row.value(for: $0) }
            if KeyOrdering.hasNullComponent(key) {
                accumulator.addSkippedNullKey()
                continue
            }
            try checkOrder(of: key)
            previousKey = key
            return KeyedRow(row: row, key: key)
        }
        return nil
    }

    /// Runs for every order kind, not just text. A numeric key that will not parse falls back to
    /// byte order, and a collation this build does not recognise stays byte-ordered, so the check
    /// is the only thing standing between a disagreeing server order and a wrong diff.
    private func checkOrder(of key: [PluginCellValue]) throws {
        guard let previousKey else { return }
        guard ordering.compare(previousKey, key) == .orderedDescending else { return }
        let explanation = String(
            localized: "The %1$@ sorted rows differently than the comparison expects, near key %2$@. Pick a numeric key, or one that sorts by byte value."
        )
        throw CompareSyncError.streamOutOfOrder(
            String(format: explanation, side.displayName, KeyOrdering.description(of: key))
        )
    }
}

internal final class ArrayRowProvider: DataRowProviding {
    private let rows: [DataRow]
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
