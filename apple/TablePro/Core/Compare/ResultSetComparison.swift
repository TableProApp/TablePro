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
    // The fields each row has none of, by row id.
    internal let absentColumns: [RowID: Set<Int>]
    internal let isTruncated: Bool
    internal let primaryKeyColumns: [String]

    internal init(
        title: String,
        detail: String,
        columns: [String],
        columnTypes: [ColumnType] = [],
        rows: ContiguousArray<Row>,
        absentColumns: [RowID: Set<Int>] = [:],
        isTruncated: Bool = false,
        primaryKeyColumns: [String] = []
    ) {
        self.title = title
        self.detail = detail
        self.columns = columns
        self.columnTypes = columnTypes
        self.rows = rows
        self.absentColumns = absentColumns
        self.isTruncated = isTruncated
        self.primaryKeyColumns = primaryKeyColumns
    }

    internal func columnType(at index: Int) -> ColumnType? {
        columnTypes.indices.contains(index) ? columnTypes[index] : nil
    }

    internal func isAbsent(_ row: Row, column: Int) -> Bool {
        absentColumns[row.id]?.contains(column) == true
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
        let columnReadings = readings(pairing: pairing, left: left, right: right)
        let keySet = Set(keyPairs)
        let compared = pairing.pairs.indices.filter { !keySet.contains($0) }

        var rightByKey: [[CellToken]: Int] = [:]
        rightByKey.reserveCapacity(right.rows.count)
        for index in right.rows.indices {
            try checkCancellation(at: index)
            let key = keyPairs.map { token(right.rows[index], pairing.pairs[$0].right, columnReadings[$0], in: right) }
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
            let key = keyPairs.map { token(leftRow, pairing.pairs[$0].left, columnReadings[$0], in: left) }
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
                return token(leftRow, pair.left, columnReadings[pairIndex], in: left) != token(rightRow, pair.right, columnReadings[pairIndex], in: right)
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
        let columnReadings = readings(pairing: pairing, left: left, right: right)

        var rightByValues: [[CellToken]: [Int]] = [:]
        for index in right.rows.indices {
            try checkCancellation(at: index)
            let values = pairing.pairs.indices.map { token(right.rows[index], pairing.pairs[$0].right, columnReadings[$0], in: right) }
            rightByValues[values, default: []].append(index)
        }

        var entries: [ResultComparisonEntry] = []
        entries.reserveCapacity(max(left.rows.count, right.rows.count))
        var taken: [[CellToken]: Int] = [:]
        var rightMatched = [Bool](repeating: false, count: right.rows.count)

        for index in left.rows.indices {
            try checkCancellation(at: index)
            let values = pairing.pairs.indices.map { token(left.rows[index], pairing.pairs[$0].left, columnReadings[$0], in: left) }
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

    // One key per value, so keys, whole rows and values share one equivalence: an absent field is not NULL, and two
    // spellings of one instant agree to the microsecond.
    private enum CellToken: Hashable {
        case absent
        case null
        case text(String)
        case bytes(Data)
        case instant(Int64)
    }

    private struct ColumnReading {
        let kind: ValueComparisonKind
        // One side's values all carry an offset and the other's none, so both are read on the wall clock.
        let wallClock: Bool
    }

    private enum Zoning {
        case empty
        case zoned
        case unzoned
        case mixed
    }

    private static func token(
        _ row: Row, _ column: Int, _ reading: ColumnReading, in side: ResultComparisonSide
    ) -> CellToken {
        guard !side.isAbsent(row, column: column) else { return .absent }
        switch row[column] {
        case .null:
            return .null
        case .bytes(let data):
            return .bytes(data)
        case .text(let text):
            guard reading.kind == .temporal || reading.kind == .unknown else { return .text(text) }
            let wallClock = reading.wallClock ? Self.withoutOffset(text) : nil
            guard let microseconds = instantMicroseconds(wallClock ?? text) else { return .text(text) }
            return .instant(microseconds)
        }
    }

    private static func withoutOffset(_ text: String) -> String? {
        CrossEngineValueCoercer.strippingTimeZoneOffset(text.trimmingCharacters(in: .whitespaces))
    }

    // Read from every value, so row order and NULLs decide nothing; a column holding both spellings is mixed.
    private static func zoning(of side: ResultComparisonSide, column: Int) -> Zoning {
        var zoning = Zoning.empty
        for row in side.rows where !side.isAbsent(row, column: column) {
            guard case .text(let text) = row[column], startsLikeATimestamp(text) else { continue }
            switch (zoning, withoutOffset(text) != nil) {
            case (.empty, true): zoning = .zoned
            case (.empty, false): zoning = .unzoned
            case (.zoned, false), (.unzoned, true): return .mixed
            default: break
            }
        }
        return zoning
    }

    // Every pattern `TimestampValue` reads starts with `yyyy-`, so anything else skips the formatters.
    private static func startsLikeATimestamp(_ text: String) -> Bool {
        let head = Array(text.utf8.drop { $0 == UInt8(ascii: " ") }.prefix(5))
        return head.count == 5 && head[4] == UInt8(ascii: "-")
            && head[0 ..< 4].allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
    }

    private static func instantMicroseconds(_ text: String) -> Int64? {
        guard startsLikeATimestamp(text), let instant = TimestampValue.parse(text) else { return nil }
        let nanoseconds = instant.nanosecondsSinceEpoch
        let quotient = nanoseconds / 1_000
        return nanoseconds % 1_000 < 0 ? quotient - 1 : quotient
    }

    private static func readings(
        pairing: ResultColumnPairing,
        left: ResultComparisonSide,
        right: ResultComparisonSide
    ) -> [ColumnReading] {
        pairing.pairs.map { pair in
            let leftKind = ValueComparisonKind(columnType: left.columnType(at: pair.left))
            let rightKind = ValueComparisonKind(columnType: right.columnType(at: pair.right))
            let kind = leftKind == rightKind ? leftKind : .unknown
            guard kind == .temporal || kind == .unknown else { return ColumnReading(kind: kind, wallClock: false) }
            let zonings = (zoning(of: left, column: pair.left), zoning(of: right, column: pair.right))
            switch zonings {
            case (.zoned, .unzoned), (.unzoned, .zoned):
                return ColumnReading(kind: kind, wallClock: true)
            default:
                return ColumnReading(kind: kind, wallClock: false)
            }
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
