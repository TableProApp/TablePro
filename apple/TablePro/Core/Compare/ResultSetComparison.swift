//
//  ResultSetComparison.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal struct ResultComparisonSide: Sendable {
    internal let title: String
    internal let detail: String
    internal let columns: [String]
    internal let columnTypes: [ColumnType]
    internal let rows: ContiguousArray<Row>
    internal let isTruncated: Bool
    internal let primaryKeyColumns: [String]

    internal init(
        title: String,
        detail: String,
        columns: [String],
        columnTypes: [ColumnType] = [],
        rows: ContiguousArray<Row>,
        isTruncated: Bool = false,
        primaryKeyColumns: [String] = []
    ) {
        self.title = title
        self.detail = detail
        self.columns = columns
        self.columnTypes = columnTypes
        self.rows = rows
        self.isTruncated = isTruncated
        self.primaryKeyColumns = primaryKeyColumns
    }

    internal func columnType(at index: Int) -> ColumnType? {
        columnTypes.indices.contains(index) ? columnTypes[index] : nil
    }
}

internal struct ResultColumnPairing: Equatable, Sendable {
    internal struct Pair: Equatable, Sendable {
        internal let name: String
        internal let left: Int
        internal let right: Int
    }

    internal let pairs: [Pair]
    internal let leftOnly: [String]
    internal let rightOnly: [String]

    // Exact names pair first, so `ID` only falls back to `id` when nothing spelled the same is left.
    // A repeated name pairs by occurrence: the second `id` on the left with the second on the right.
    internal init(left: [String], right: [String]) {
        var rightTaken = Array(repeating: false, count: right.count)
        var partner = [Int?](repeating: nil, count: left.count)

        for (leftIndex, name) in left.enumerated() {
            guard let rightIndex = right.indices.first(where: { !rightTaken[$0] && right[$0] == name }) else { continue }
            rightTaken[rightIndex] = true
            partner[leftIndex] = rightIndex
        }
        for (leftIndex, name) in left.enumerated() where partner[leftIndex] == nil {
            guard let rightIndex = right.indices.first(where: {
                !rightTaken[$0] && right[$0].caseInsensitiveCompare(name) == .orderedSame
            }) else { continue }
            rightTaken[rightIndex] = true
            partner[leftIndex] = rightIndex
        }

        pairs = left.indices.compactMap { index in
            partner[index].map { Pair(name: left[index], left: index, right: $0) }
        }
        leftOnly = left.indices.filter { partner[$0] == nil }.map { left[$0] }
        rightOnly = right.indices.filter { !rightTaken[$0] }.map { right[$0] }
    }
}

internal enum ResultRowDifference: CaseIterable, Hashable, Sendable {
    case onlyLeft
    case onlyRight
    case changed
    case same

    internal var isDifference: Bool {
        self != .same
    }
}

internal struct ResultComparisonEntry: Hashable, Sendable {
    internal let kind: ResultRowDifference
    internal let leftRow: Int?
    internal let rightRow: Int?
    internal let changedPairs: [Int]

    internal init(kind: ResultRowDifference, leftRow: Int?, rightRow: Int?, changedPairs: [Int] = []) {
        self.kind = kind
        self.leftRow = leftRow
        self.rightRow = rightRow
        self.changedPairs = changedPairs
    }
}

internal struct ResultComparison: Sendable {
    internal let id = UUID()
    internal let entries: [ResultComparisonEntry]
    internal let keyPairs: [Int]

    private let counts: [ResultRowDifference: Int]

    internal init(entries: [ResultComparisonEntry], keyPairs: [Int]) {
        self.entries = entries
        self.keyPairs = keyPairs
        var counts: [ResultRowDifference: Int] = [:]
        for entry in entries {
            counts[entry.kind, default: 0] += 1
        }
        self.counts = counts
    }

    internal func count(of kind: ResultRowDifference) -> Int {
        counts[kind] ?? 0
    }

    internal var differenceCount: Int {
        count(of: .onlyLeft) + count(of: .onlyRight) + count(of: .changed)
    }
}

internal enum ResultComparisonError: Error, Equatable, LocalizedError {
    case duplicateKey(String)

    internal var errorDescription: String? {
        switch self {
        case .duplicateKey(let message):
            return message
        }
    }
}

internal enum ResultComparisonEngine {
    private static let cancellationStride = 4_096

    // Empty `keyPairs` matches whole rows: a row that differs in one value reads as one row only on each side.
    internal static func compare(
        left: ResultComparisonSide,
        right: ResultComparisonSide,
        pairing: ResultColumnPairing,
        keyPairs: [Int]
    ) throws -> ResultComparison {
        let keyPairs = keyPairs.filter { pairing.pairs.indices.contains($0) }
        guard !keyPairs.isEmpty else {
            return try compareWholeRows(left: left, right: right, pairing: pairing)
        }
        return try compareByKey(left: left, right: right, pairing: pairing, keyPairs: keyPairs)
    }

    // The left result's table key first; a key with a column missing from either result is skipped.
    internal static func defaultKeyPairs(
        left: ResultComparisonSide,
        right: ResultComparisonSide,
        pairing: ResultColumnPairing
    ) -> [Int] {
        let candidates: [(key: [String], names: [String])] = [
            (left.primaryKeyColumns, pairing.pairs.map(\.name)),
            (right.primaryKeyColumns, pairing.pairs.map { right.columns[$0.right] })
        ]
        for candidate in candidates where !candidate.key.isEmpty {
            let indices = candidate.key.compactMap { column in
                candidate.names.firstIndex(of: column)
                    ?? candidate.names.firstIndex { $0.caseInsensitiveCompare(column) == .orderedSame }
            }
            guard indices.count == candidate.key.count, Set(indices).count == indices.count else { continue }
            return indices.sorted()
        }
        return []
    }

    private static func compareByKey(
        left: ResultComparisonSide,
        right: ResultComparisonSide,
        pairing: ResultColumnPairing,
        keyPairs: [Int]
    ) throws -> ResultComparison {
        let kinds = valueKinds(pairing: pairing, left: left, right: right)
        let keySet = Set(keyPairs)
        let compared = pairing.pairs.indices.filter { !keySet.contains($0) }

        var rightByKey: [[CellToken]: Int] = [:]
        rightByKey.reserveCapacity(right.rows.count)
        for index in right.rows.indices {
            try checkCancellation(at: index)
            let key = keyPairs.map { token(right.rows[index], pairing.pairs[$0].right, kinds[$0]) }
            guard rightByKey.updateValue(index, forKey: key) == nil else {
                throw duplicateKeyError(right.rows[index], keyPairs.map { pairing.pairs[$0].right }, onLeft: false)
            }
        }

        var entries: [ResultComparisonEntry] = []
        entries.reserveCapacity(max(left.rows.count, right.rows.count))
        var seenOnLeft = Set<[CellToken]>()
        var rightMatched = [Bool](repeating: false, count: right.rows.count)

        for index in left.rows.indices {
            try checkCancellation(at: index)
            let leftRow = left.rows[index]
            let key = keyPairs.map { token(leftRow, pairing.pairs[$0].left, kinds[$0]) }
            guard seenOnLeft.insert(key).inserted else {
                throw duplicateKeyError(leftRow, keyPairs.map { pairing.pairs[$0].left }, onLeft: true)
            }
            guard let partner = rightByKey[key] else {
                entries.append(ResultComparisonEntry(kind: .onlyLeft, leftRow: index, rightRow: nil))
                continue
            }
            rightMatched[partner] = true
            let rightRow = right.rows[partner]
            let changed = compared.filter { pairIndex in
                let pair = pairing.pairs[pairIndex]
                return token(leftRow, pair.left, kinds[pairIndex]) != token(rightRow, pair.right, kinds[pairIndex])
            }
            entries.append(ResultComparisonEntry(
                kind: changed.isEmpty ? .same : .changed,
                leftRow: index,
                rightRow: partner,
                changedPairs: changed
            ))
        }

        for index in right.rows.indices where !rightMatched[index] {
            entries.append(ResultComparisonEntry(kind: .onlyRight, leftRow: nil, rightRow: index))
        }
        return ResultComparison(entries: entries, keyPairs: keyPairs)
    }

    // A multiset: two equal rows on the left and one on the right leave one of the two only on the left.
    private static func compareWholeRows(
        left: ResultComparisonSide,
        right: ResultComparisonSide,
        pairing: ResultColumnPairing
    ) throws -> ResultComparison {
        let kinds = valueKinds(pairing: pairing, left: left, right: right)

        var rightByValues: [[CellToken]: [Int]] = [:]
        for index in right.rows.indices {
            try checkCancellation(at: index)
            let values = pairing.pairs.indices.map { token(right.rows[index], pairing.pairs[$0].right, kinds[$0]) }
            rightByValues[values, default: []].append(index)
        }

        var entries: [ResultComparisonEntry] = []
        entries.reserveCapacity(max(left.rows.count, right.rows.count))
        var taken: [[CellToken]: Int] = [:]
        var rightMatched = [Bool](repeating: false, count: right.rows.count)

        for index in left.rows.indices {
            try checkCancellation(at: index)
            let values = pairing.pairs.indices.map { token(left.rows[index], pairing.pairs[$0].left, kinds[$0]) }
            let next = taken[values, default: 0]
            guard let bucket = rightByValues[values], next < bucket.count else {
                entries.append(ResultComparisonEntry(kind: .onlyLeft, leftRow: index, rightRow: nil))
                continue
            }
            taken[values] = next + 1
            rightMatched[bucket[next]] = true
            entries.append(ResultComparisonEntry(kind: .same, leftRow: index, rightRow: bucket[next]))
        }

        for index in right.rows.indices where !rightMatched[index] {
            entries.append(ResultComparisonEntry(kind: .onlyRight, leftRow: nil, rightRow: index))
        }
        return ResultComparison(entries: entries, keyPairs: [])
    }

    // One equality for keys, whole rows and values, matching `CellValueComparator` at its default
    // options: an absent field is not NULL, and two spellings of one instant agree to the microsecond.
    private enum CellToken: Hashable {
        case absent
        case null
        case text(String)
        case bytes(Data)
        case instant(Int64)
    }

    private static func token(_ row: Row, _ column: Int, _ kind: ValueComparisonKind) -> CellToken {
        guard !row.isAbsent(column) else { return .absent }
        switch row[column] {
        case .null:
            return .null
        case .bytes(let data):
            return .bytes(data)
        case .text(let text):
            guard kind == .temporal || kind == .unknown, let microseconds = instantMicroseconds(text) else {
                return .text(text)
            }
            return .instant(microseconds)
        }
    }

    // Every pattern `TimestampValue` reads starts with `yyyy-`, so anything else skips the formatters.
    private static func instantMicroseconds(_ text: String) -> Int64? {
        let head = Array(text.utf8.drop { $0 == UInt8(ascii: " ") }.prefix(5))
        guard head.count == 5, head[4] == UInt8(ascii: "-"),
              head[0 ..< 4].allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),
              let instant = TimestampValue.parse(text) else { return nil }
        let nanoseconds = instant.nanosecondsSinceEpoch
        let quotient = nanoseconds / 1_000
        return nanoseconds % 1_000 < 0 ? quotient - 1 : quotient
    }

    private static func valueKinds(
        pairing: ResultColumnPairing,
        left: ResultComparisonSide,
        right: ResultComparisonSide
    ) -> [ValueComparisonKind] {
        pairing.pairs.map { pair in
            let leftKind = ValueComparisonKind(columnType: left.columnType(at: pair.left))
            let rightKind = ValueComparisonKind(columnType: right.columnType(at: pair.right))
            return leftKind == rightKind ? leftKind : .unknown
        }
    }

    private static func checkCancellation(at index: Int) throws {
        guard index % cancellationStride == 0 else { return }
        try Task.checkCancellation()
    }

    private static func duplicateKeyError(_ row: Row, _ columns: [Int], onLeft: Bool) -> ResultComparisonError {
        let format = onLeft
            ? String(localized: "Key %@ matches more than one row in the left result. Choose key columns that identify a single row, or match whole rows.")
            : String(localized: "Key %@ matches more than one row in the right result. Choose key columns that identify a single row, or match whole rows.")
        return .duplicateKey(String(format: format, KeyOrdering.description(of: columns.map { row[$0] })))
    }
}
