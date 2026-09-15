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

import CryptoKit
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
    var endedAtRowLimit: Bool { get }
    func nextRow() async throws -> DataRow?
    func drain() async throws
}

internal protocol OneSidedRowResolving: AnyObject {
    func rows(matching keys: [[PluginCellValue]], on side: ComparisonSide) async throws -> [DataRow]
}

internal enum RowDiffKind: String, Codable, Hashable, Sendable {
    case insert
    case update
    case delete
    case identical
    case conflict

    internal var isDifference: Bool {
        switch self {
        case .insert, .update, .delete: return true
        case .identical, .conflict: return false
        }
    }
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

    internal func differs(in column: String) -> Bool {
        cellDifferences.contains { $0.column.caseInsensitiveCompare(column) == .orderedSame }
    }
}

internal struct DataDiffSummary: Hashable, Sendable {
    internal let insertCount: Int
    internal let updateCount: Int
    internal let deleteCount: Int
    internal let identicalCount: Int
    internal let conflictCount: Int
    internal let skippedNullKeyCount: Int
    internal let entries: [RowDiffEntry]
    internal let identicalEntries: [RowDiffEntry]
    internal let truncatedEntries: Bool
    internal let comparedKeyCount: Int
    internal let stoppedAtRowLimit: Bool
    internal let differenceDigest: String

    /// The last key both sides were read past, present only when a row limit cut the walk short.
    /// Everything up to and including it was read on both sides, so it is the point a filter such
    /// as `id > <key>` resumes from without skipping a key or comparing one twice.
    internal let resumeKey: [PluginCellValue]?

    /// One comparison's own identity. Two runs that produce the same counts and the same digest are
    /// still two answers, and a view that caches on the answer has to be able to tell them apart:
    /// matching rows are counted rather than digested, so both can move while the digest stands.
    internal let runIdentity: UUID

    internal init(
        insertCount: Int,
        updateCount: Int,
        deleteCount: Int,
        identicalCount: Int,
        conflictCount: Int = 0,
        skippedNullKeyCount: Int,
        entries: [RowDiffEntry],
        identicalEntries: [RowDiffEntry] = [],
        truncatedEntries: Bool,
        comparedKeyCount: Int = 0,
        stoppedAtRowLimit: Bool = false,
        differenceDigest: String = "",
        resumeKey: [PluginCellValue]? = nil,
        runIdentity: UUID = UUID()
    ) {
        self.insertCount = insertCount
        self.updateCount = updateCount
        self.deleteCount = deleteCount
        self.identicalCount = identicalCount
        self.conflictCount = conflictCount
        self.skippedNullKeyCount = skippedNullKeyCount
        self.entries = entries
        self.identicalEntries = identicalEntries
        self.truncatedEntries = truncatedEntries
        self.comparedKeyCount = comparedKeyCount
        self.stoppedAtRowLimit = stoppedAtRowLimit
        self.differenceDigest = differenceDigest
        self.resumeKey = resumeKey
        self.runIdentity = runIdentity
    }

    internal var differenceCount: Int {
        insertCount + updateCount + deleteCount
    }

    internal var totalCount: Int {
        differenceCount + identicalCount + conflictCount
    }

    internal var answerIdentity: String {
        "\(runIdentity.uuidString)|\(insertCount)|\(updateCount)|\(deleteCount)|\(identicalCount)|\(conflictCount)|\(differenceDigest)"
    }

    internal func count(of kind: RowDiffKind) -> Int {
        switch kind {
        case .insert: return insertCount
        case .update: return updateCount
        case .delete: return deleteCount
        case .identical: return identicalCount
        case .conflict: return conflictCount
        }
    }
}

internal struct KeyedRow {
    internal let row: DataRow
    internal let key: [PluginCellValue]
}

internal enum ComparisonSide: String, Sendable {
    case source
    case target

    internal var displayName: String {
        switch self {
        case .source: return String(localized: "source")
        case .target: return String(localized: "target")
        }
    }

    internal var opposite: ComparisonSide {
        self == .source ? .target : .source
    }
}

internal struct DataComparisonShape: Sendable {
    internal let keyColumns: [String]
    internal let keyOrders: [KeyOrdering.ColumnOrder]
    internal let comparedColumns: [String]
    internal let valueKinds: [String: ValueComparisonKind]
    internal let digestColumns: [String]
    internal let defersOneSidedRows: Bool

    internal init(
        keyColumns: [String],
        keyOrders: [KeyOrdering.ColumnOrder] = [],
        comparedColumns: [String],
        valueKinds: [String: ValueComparisonKind] = [:],
        digestColumns: [String] = [],
        defersOneSidedRows: Bool = false
    ) {
        self.keyColumns = keyColumns
        self.keyOrders = keyOrders
        self.comparedColumns = comparedColumns
        self.valueKinds = valueKinds
        self.digestColumns = digestColumns
        self.defersOneSidedRows = defersOneSidedRows
    }

    internal func valueKind(of column: String) -> ValueComparisonKind {
        valueKinds[column.lowercased()] ?? .unknown
    }
}

internal struct DataDiffEngine {
    private static let resolutionBatchSize = 200

    private let options: DataCompareOptions
    private let shape: DataComparisonShape
    private let comparator: CellValueComparator
    private let ordering: KeyOrdering

    internal init(options: DataCompareOptions, shape: DataComparisonShape) {
        self.options = options
        self.shape = shape
        self.comparator = CellValueComparator(options: options)
        self.ordering = KeyOrdering(orders: shape.keyOrders)
    }

    /// `onEntry` sees every entry the walk produces, before the accumulator's retention cap.
    /// Script generation runs the walk a second time with a sink rather than reading the capped
    /// entry list, because that list is a preview.
    internal func compare(
        source: DataRowProviding,
        target: DataRowProviding,
        resolver: OneSidedRowResolving? = nil,
        onEntry: ((RowDiffEntry) throws -> Void)? = nil
    ) async throws -> DataDiffSummary {
        guard !shape.keyColumns.isEmpty else {
            throw CompareSyncError.noComparisonKey(String(localized: "Choose a key column before comparing data."))
        }

        let accumulator = Accumulator(
            limit: options.maxRetainedEntries,
            identicalLimit: options.maxRetainedIdenticalEntries,
            digestColumns: shape.digestColumns
        )
        let recorder = EntryRecorder(accumulator: accumulator, sink: onEntry)
        let sourceReader = KeyedRowReader(
            provider: source, keyColumns: shape.keyColumns, ordering: ordering, side: .source
        )
        let targetReader = KeyedRowReader(
            provider: target, keyColumns: shape.keyColumns, ordering: ordering, side: .target
        )

        /// Keys, never rows. A filter that matches a million rows on one side only would otherwise
        /// hold every one of their columns until the walk ended, which is the whole of what
        /// streaming both sides exists to avoid.
        var deferredSource: [[PluginCellValue]] = []
        var deferredTarget: [[PluginCellValue]] = []
        var positions = 0
        var stoppedAtRowLimit = false

        /// The walk classifies every key both sides were read past, so the last one it classified is
        /// the boundary of the region the answer covers: `min` of the two sides' last delivered keys
        /// once a limit cut one of them short. Counting merged positions against the limit instead
        /// stopped mid-region and threw away differences both sides had already been read past.
        var lastClassifiedKey: [PluginCellValue]?

        var left = try await sourceReader.next(accumulator)
        var right = try await targetReader.next(accumulator)

        walk: while true {
            try Task.checkCancellation()
            /// Both sides ending is an answer about every row, unless a pushed limit is what ended
            /// them, so the limit is only reported as a stop when there was something left to read.
            if left == nil, right == nil {
                stoppedAtRowLimit = source.endedAtRowLimit || target.endedAtRowLimit
                break walk
            }

            switch (left, right) {
            case (nil, nil):
                break walk
            case (nil, let targetRow?):
                guard !source.endedAtRowLimit else {
                    stoppedAtRowLimit = true
                    break walk
                }
                if shape.defersOneSidedRows {
                    deferredTarget.append(targetRow.key)
                } else {
                    try recorder.record(deleteEntry(for: targetRow))
                }
                lastClassifiedKey = targetRow.key
                right = try await targetReader.next(accumulator)
            case (let sourceRow?, nil):
                guard !target.endedAtRowLimit else {
                    stoppedAtRowLimit = true
                    break walk
                }
                if shape.defersOneSidedRows {
                    deferredSource.append(sourceRow.key)
                } else {
                    try recorder.record(insertEntry(for: sourceRow))
                }
                lastClassifiedKey = sourceRow.key
                left = try await sourceReader.next(accumulator)
            case (let sourceRow?, let targetRow?):
                switch ordering.compare(sourceRow.key, targetRow.key) {
                case .orderedSame:
                    try recorder.record(matchedEntry(source: sourceRow, target: targetRow))
                    lastClassifiedKey = sourceRow.key
                    left = try await sourceReader.next(accumulator)
                    right = try await targetReader.next(accumulator)
                case .orderedAscending:
                    if shape.defersOneSidedRows {
                        deferredSource.append(sourceRow.key)
                    } else {
                        try recorder.record(insertEntry(for: sourceRow))
                    }
                    lastClassifiedKey = sourceRow.key
                    left = try await sourceReader.next(accumulator)
                case .orderedDescending:
                    if shape.defersOneSidedRows {
                        deferredTarget.append(targetRow.key)
                    } else {
                        try recorder.record(deleteEntry(for: targetRow))
                    }
                    lastClassifiedKey = targetRow.key
                    right = try await targetReader.next(accumulator)
                }
            }
            positions += 1
        }

        try await source.drain()
        try await target.drain()

        if !deferredSource.isEmpty || !deferredTarget.isEmpty {
            guard let resolver else {
                throw CompareSyncError.unsupportedOperation(
                    String(localized: "A filtered comparison needs both sides to look up rows by key.")
                )
            }
            try await resolve(deferredSource, from: .source, resolver: resolver, recorder: recorder)
            try await resolve(deferredTarget, from: .target, resolver: resolver, recorder: recorder)
        }

        return accumulator.summary(
            comparedKeyCount: positions,
            stoppedAtRowLimit: stoppedAtRowLimit,
            resumeKey: stoppedAtRowLimit ? lastClassifiedKey : nil
        )
    }

    private func resolve(
        _ keys: [[PluginCellValue]],
        from side: ComparisonSide,
        resolver: OneSidedRowResolving,
        recorder: EntryRecorder
    ) async throws {
        var start = 0
        while start < keys.count {
            try Task.checkCancellation()
            let batch = Array(keys[start ..< min(start + Self.resolutionBatchSize, keys.count)])
            start += batch.count
            let own = try keyedAndSorted(try await resolver.rows(matching: batch, on: side), side: side)
            guard own.count >= batch.count else {
                throw Self.vanishedRowsError(count: batch.count - own.count, side: side)
            }
            let counterparts = try keyedAndSorted(
                try await resolver.rows(matching: batch, on: side.opposite), side: side.opposite
            )

            var index = 0
            for row in own {
                while index < counterparts.count,
                      ordering.compare(counterparts[index].key, row.key) == .orderedAscending {
                    index += 1
                }
                guard index < counterparts.count,
                      ordering.compare(counterparts[index].key, row.key) == .orderedSame else {
                    try recorder.record(side == .source ? insertEntry(for: row) : deleteEntry(for: row))
                    continue
                }
                let counterpart = counterparts[index]
                index += 1
                let pair = side == .source ? (row, counterpart) : (counterpart, row)
                try recorder.record(conflictEntry(source: pair.0, target: pair.1))
            }
        }
    }

    /// A deferred key was read from that side's own stream moments earlier, so a lookup that cannot
    /// find it again means the rows moved under the comparison, or that the lookup itself matches
    /// nothing. Both answer with silence, and a comparison that quietly drops differences reads as
    /// two databases that agree.
    private static func vanishedRowsError(count: Int, side: ComparisonSide) -> CompareSyncError {
        .rowsChangedSinceComparison(String(
            format: side == .source
                ? String(localized: "%d rows could not be read back from the source by key. Compare again.")
                : String(localized: "%d rows could not be read back from the target by key. Compare again."),
            count
        ))
    }

    private func keyedAndSorted(_ rows: [DataRow], side: ComparisonSide) throws -> [KeyedRow] {
        let keyed = rows
            .map { row in KeyedRow(row: row, key: shape.keyColumns.map { row.value(for: $0) }) }
            .filter { !KeyOrdering.hasNullComponent($0.key) }
            .sorted { ordering.compare($0.key, $1.key) == .orderedAscending }
        for index in keyed.indices.dropFirst() where ordering.compare(keyed[index - 1].key, keyed[index].key) == .orderedSame {
            throw KeyedRowReader.duplicateKeyError(keyed[index].key, side: side)
        }
        return keyed
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

    private func deleteEntry(for entry: KeyedRow) -> RowDiffEntry {
        RowDiffEntry(
            kind: .delete,
            keyDescription: KeyOrdering.description(of: entry.key),
            keyIdentity: KeyOrdering.identity(of: entry.key),
            sourceRow: nil,
            targetRow: entry.row
        )
    }

    private func matchedEntry(source: KeyedRow, target: KeyedRow) -> RowDiffEntry {
        let differences = cellDifferences(source: source, target: target)
        return RowDiffEntry(
            kind: differences.isEmpty ? .identical : .update,
            keyDescription: KeyOrdering.description(of: source.key),
            keyIdentity: KeyOrdering.identity(of: source.key),
            sourceRow: source.row,
            targetRow: target.row,
            cellDifferences: differences
        )
    }

    private func conflictEntry(source: KeyedRow, target: KeyedRow) -> RowDiffEntry {
        RowDiffEntry(
            kind: .conflict,
            keyDescription: KeyOrdering.description(of: source.key),
            keyIdentity: KeyOrdering.identity(of: source.key),
            sourceRow: source.row,
            targetRow: target.row,
            cellDifferences: cellDifferences(source: source, target: target)
        )
    }

    private func cellDifferences(source: KeyedRow, target: KeyedRow) -> [CellDifference] {
        var differences: [CellDifference] = []
        for (index, column) in shape.keyColumns.enumerated()
            where !KeyOrdering.isIdentical(source.key[index], target.key[index], order: ordering.order(at: index)) {
            differences.append(CellDifference(
                column: column,
                rule: .exactValue,
                sourceValue: source.key[index],
                targetValue: target.key[index]
            ))
        }
        for column in shape.comparedColumns {
            let sourceValue = source.row.value(for: column)
            let targetValue = target.row.value(for: column)
            let outcome = comparator.compare(sourceValue, targetValue, as: shape.valueKind(of: column))
            guard !outcome.isEqual else { continue }
            differences.append(CellDifference(
                column: column,
                rule: outcome.rule,
                sourceValue: sourceValue,
                targetValue: targetValue
            ))
        }
        return differences
    }
}

internal extension DataDiffEngine {
    final class Accumulator {
        private let limit: Int
        private let identicalLimit: Int
        private let digestColumns: [String]
        private var counts: [RowDiffKind: Int] = [:]
        private var skippedNullKeyCount = 0
        private var entries: [RowDiffEntry] = []
        private var identicalEntries: [RowDiffEntry] = []
        private var truncated = false
        private var digest = SHA256()

        init(limit: Int, identicalLimit: Int, digestColumns: [String]) {
            self.limit = limit
            self.identicalLimit = identicalLimit
            self.digestColumns = digestColumns
        }

        func addSkippedNullKey() {
            skippedNullKeyCount += 1
        }

        func add(_ entry: RowDiffEntry) {
            counts[entry.kind, default: 0] += 1
            guard entry.kind != .identical else {
                if identicalEntries.count < identicalLimit {
                    identicalEntries.append(entry)
                }
                return
            }
            updateDigest(with: entry)
            guard entries.count < limit else {
                truncated = true
                return
            }
            entries.append(entry)
        }

        func summary(
            comparedKeyCount: Int,
            stoppedAtRowLimit: Bool,
            resumeKey: [PluginCellValue]? = nil
        ) -> DataDiffSummary {
            DataDiffSummary(
                insertCount: counts[.insert] ?? 0,
                updateCount: counts[.update] ?? 0,
                deleteCount: counts[.delete] ?? 0,
                identicalCount: counts[.identical] ?? 0,
                conflictCount: counts[.conflict] ?? 0,
                skippedNullKeyCount: skippedNullKeyCount,
                entries: entries,
                identicalEntries: identicalEntries,
                truncatedEntries: truncated,
                comparedKeyCount: comparedKeyCount,
                stoppedAtRowLimit: stoppedAtRowLimit,
                differenceDigest: digest.finalize().map { String(format: "%02x", $0) }.joined(),
                resumeKey: resumeKey
            )
        }

        private func updateDigest(with entry: RowDiffEntry) {
            append(entry.kind.rawValue)
            append(entry.keyIdentity)
            for row in [entry.sourceRow, entry.targetRow] {
                guard let row else {
                    digest.update(data: Data([0x03]))
                    continue
                }
                digest.update(data: Data([0x04]))
                for column in digestColumns {
                    append(column)
                    append(row.value(for: column))
                }
            }
        }

        /// Length-prefixed rather than separated. Row text can hold any byte a separator could use,
        /// so a sentinel alone lets two different rows frame to the same bytes and hash alike.
        private func append(_ text: String) {
            append(Data(text.utf8))
        }

        private func append(_ data: Data) {
            withUnsafeBytes(of: UInt32(data.count).bigEndian) { digest.update(bufferPointer: $0) }
            digest.update(data: data)
        }

        private func append(_ value: PluginCellValue) {
            switch value {
            case .null:
                digest.update(data: Data([0x00]))
            case .text(let text):
                digest.update(data: Data([0x01]))
                append(text)
            case .bytes(let data):
                digest.update(data: Data([0x02]))
                append(data)
            }
        }
    }
}

private final class EntryRecorder {
    private let accumulator: DataDiffEngine.Accumulator
    private let sink: ((RowDiffEntry) throws -> Void)?

    init(accumulator: DataDiffEngine.Accumulator, sink: ((RowDiffEntry) throws -> Void)?) {
        self.accumulator = accumulator
        self.sink = sink
    }

    func record(_ entry: RowDiffEntry) throws {
        accumulator.add(entry)
        try sink?(entry)
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

    func next(_ accumulator: DataDiffEngine.Accumulator) async throws -> KeyedRow? {
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
        switch ordering.compare(previousKey, key) {
        case .orderedAscending:
            return
        case .orderedSame:
            throw Self.duplicateKeyError(key, side: side)
        case .orderedDescending:
            let explanation = String(
                localized: "The %1$@ sorted rows differently than the comparison expects, near key %2$@. Pick a numeric key, or one that sorts by byte value."
            )
            throw CompareSyncError.streamOutOfOrder(
                String(format: explanation, side.displayName, KeyOrdering.description(of: key))
            )
        }
    }

    static func duplicateKeyError(_ key: [PluginCellValue], side: ComparisonSide) -> CompareSyncError {
        CompareSyncError.duplicateKey(
            String(
                format: String(
                    localized: "Key %1$@ matches more than one row in the %2$@. Choose key columns that identify a single row."
                ),
                KeyOrdering.description(of: key), side.displayName
            )
        )
    }
}

internal final class ArrayRowProvider: DataRowProviding {
    private let rows: [DataRow]
    private let rowLimit: Int?
    private let holdsRowPastTheLimit: Bool
    private var index = 0

    internal init(rows: [DataRow], rowLimit: Int? = nil) {
        self.rows = rowLimit.map { Array(rows.prefix($0)) } ?? rows
        self.rowLimit = rowLimit
        self.holdsRowPastTheLimit = rowLimit.map { rows.count > $0 } ?? false
    }

    internal var endedAtRowLimit: Bool {
        guard let rowLimit, index >= rows.count else { return false }
        return holdsRowPastTheLimit && rows.count >= rowLimit
    }

    internal func nextRow() async throws -> DataRow? {
        guard index < rows.count else { return nil }
        defer { index += 1 }
        return rows[index]
    }

    internal func drain() async throws {
        index = rows.count
    }
}
