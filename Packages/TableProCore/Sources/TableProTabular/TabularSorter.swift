import Foundation
import TableProTabularIO

public struct TabularSortKey: Sendable, Equatable {
    public var column: TabularColumnID
    public var ascending: Bool
    public var numeric: Bool

    public init(column: TabularColumnID, ascending: Bool, numeric: Bool) {
        self.column = column
        self.ascending = ascending
        self.numeric = numeric
    }
}

public enum TabularSorter {
    private enum Bucket: UInt8 {
        case number = 0
        case text = 1
        case empty = 2
    }

    private struct ColumnKeys: Sendable {
        var buckets: [UInt8] = []
        var numbers: [Double] = []
        var text = TabularValueStore()
    }

    public static func sortedRows(
        _ rows: [Int],
        in table: TabularTable,
        by keys: [TabularSortKey],
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [Int] {
        guard !keys.isEmpty, rows.count > 1 else { return rows }
        let extracted = try await extractKeys(rows, table: table, keys: keys) { progress($0 * 0.5) }
        try Task.checkCancellation()
        let order = try await sortPositions(count: rows.count, keys: keys, columns: extracted)
        progress(1)
        return order.map { rows[$0] }
    }

    public static func naturalKey(_ bytes: UnsafeBufferPointer<UInt8>, into store: inout TabularValueStore) {
        guard TabularValueGrammar.isASCII(bytes) else {
            let lowered = Array(TabularTextCodec.utf8String(bytes).lowercased().utf8)
            lowered.withUnsafeBufferPointer { appendNaturalKey($0, lowercased: true, into: &store) }
            return
        }
        appendNaturalKey(bytes, lowercased: false, into: &store)
    }

    private static func appendNaturalKey(
        _ bytes: UnsafeBufferPointer<UInt8>,
        lowercased: Bool,
        into store: inout TabularValueStore
    ) {
        var key: [UInt8] = []
        key.reserveCapacity(bytes.count + 8)
        var index = 0
        let count = bytes.count
        while index < count {
            let byte = bytes[index]
            guard TabularValueGrammar.isDigit(byte) else {
                key.append(lowercased ? byte : TabularValueGrammar.asciiLowercase(byte))
                index += 1
                continue
            }
            var runEnd = index
            while runEnd < count, TabularValueGrammar.isDigit(bytes[runEnd]) {
                runEnd += 1
            }
            var significant = index
            while significant < runEnd, bytes[significant] == 0x30 {
                significant += 1
            }
            let length = runEnd - significant
            key.append(UInt8(0x30 + (length / 1_000) % 10))
            key.append(UInt8(0x30 + (length / 100) % 10))
            key.append(UInt8(0x30 + (length / 10) % 10))
            key.append(UInt8(0x30 + length % 10))
            key.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[significant..<runEnd]))
            index = runEnd
        }
        key.withUnsafeBufferPointer { store.append($0, kind: .text) }
    }

    private static func extractKeys(
        _ rows: [Int],
        table: TabularTable,
        keys: [TabularSortKey],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [ColumnKeys] {
        let columnIDs = keys.map(\.column)
        let perChunk = try await TabularScanEngine.forEachChunk(of: 0..<rows.count, progress: progress) { chunk, counter in
            var local = [ColumnKeys](repeating: ColumnKeys(), count: keys.count)
            for index in local.indices {
                local[index].buckets.reserveCapacity(chunk.count)
                if keys[index].numeric {
                    local[index].numbers.reserveCapacity(chunk.count)
                }
            }
            var processed = 0
            var cancelled = false
            table.scan(columns: columnIDs, logicalRows: rows[chunk]) { _, cells in
                for (index, key) in keys.enumerated() {
                    append(cells.bytes[index], kind: cells.kinds[index], numeric: key.numeric, into: &local[index])
                }
                processed += 1
                if processed == TabularScanEngine.cancellationStride {
                    counter.add(processed)
                    processed = 0
                    if Task.isCancelled {
                        cancelled = true
                        return false
                    }
                }
                return true
            }
            counter.add(processed)
            if cancelled { throw CancellationError() }
            return local
        }
        var merged = [ColumnKeys](repeating: ColumnKeys(), count: keys.count)
        for chunk in perChunk {
            for index in merged.indices {
                merged[index].buckets.append(contentsOf: chunk[index].buckets)
                merged[index].numbers.append(contentsOf: chunk[index].numbers)
                merged[index].text.append(contentsOf: chunk[index].text)
            }
        }
        return merged
    }

    private static func append(
        _ bytes: UnsafeBufferPointer<UInt8>,
        kind: TabularCellKind,
        numeric: Bool,
        into keys: inout ColumnKeys
    ) {
        if bytes.isEmpty || kind.isNullLike {
            keys.buckets.append(Bucket.empty.rawValue)
            if numeric { keys.numbers.append(0) }
            keys.text.append(UnsafeBufferPointer(start: nil, count: 0), kind: .text)
            return
        }
        if numeric, let number = TabularValueGrammar.number(bytes) {
            keys.buckets.append(Bucket.number.rawValue)
            keys.numbers.append(number)
            keys.text.append(UnsafeBufferPointer(start: nil, count: 0), kind: .text)
            return
        }
        keys.buckets.append(Bucket.text.rawValue)
        if numeric { keys.numbers.append(0) }
        naturalKey(bytes, into: &keys.text)
    }

    private static func sortPositions(count: Int, keys: [TabularSortKey], columns: [ColumnKeys]) async throws -> [Int] {
        let comparator = PositionComparator(keys: keys, columns: columns)
        let chunks = TabularChunking.ranges(count: count)
        let sortedChunks = try await withThrowingTaskGroup(of: (Int, [Int]).self) { group in
            for (index, chunk) in chunks.enumerated() {
                group.addTask {
                    try Task.checkCancellation()
                    var positions = Array(chunk)
                    positions.sort { comparator.precedes($0, $1) }
                    return (index, positions)
                }
            }
            var results = [[Int]](repeating: [], count: chunks.count)
            for try await (index, positions) in group {
                results[index] = positions
            }
            return results
        }
        try Task.checkCancellation()
        return merge(sortedChunks, comparator: comparator)
    }

    private static func merge(_ runs: [[Int]], comparator: PositionComparator) -> [Int] {
        var heads = runs.indices.filter { !runs[$0].isEmpty }.map { (run: $0, offset: 0) }
        var result: [Int] = []
        result.reserveCapacity(runs.reduce(0) { $0 + $1.count })
        while !heads.isEmpty {
            var best = 0
            for candidate in 1..<heads.count where comparator.precedes(
                runs[heads[candidate].run][heads[candidate].offset],
                runs[heads[best].run][heads[best].offset]
            ) {
                best = candidate
            }
            let head = heads[best]
            result.append(runs[head.run][head.offset])
            if head.offset + 1 < runs[head.run].count {
                heads[best].offset += 1
            } else {
                heads.remove(at: best)
            }
        }
        return result
    }

    private struct PositionComparator: Sendable {
        let keys: [TabularSortKey]
        let columns: [ColumnKeys]

        func precedes(_ lhs: Int, _ rhs: Int) -> Bool {
            for (index, key) in keys.enumerated() {
                let column = columns[index]
                let leftBucket = column.buckets[lhs]
                let rightBucket = column.buckets[rhs]
                if leftBucket != rightBucket {
                    return leftBucket < rightBucket
                }
                if leftBucket == Bucket.empty.rawValue { continue }
                let order: Int
                if leftBucket == Bucket.number.rawValue {
                    let left = column.numbers[lhs]
                    let right = column.numbers[rhs]
                    order = left < right ? -1 : (left > right ? 1 : 0)
                } else {
                    order = compareText(column.text, lhs, rhs)
                }
                if order != 0 {
                    return key.ascending ? order < 0 : order > 0
                }
            }
            return lhs < rhs
        }

        private func compareText(_ store: TabularValueStore, _ lhs: Int, _ rhs: Int) -> Int {
            store.withValue(at: lhs) { _, left in
                store.withValue(at: rhs) { _, right in
                    let shared = min(left.count, right.count)
                    if shared > 0, let leftBase = left.baseAddress, let rightBase = right.baseAddress {
                        let result = memcmp(leftBase, rightBase, shared)
                        if result != 0 { return result < 0 ? -1 : 1 }
                    }
                    if left.count == right.count { return 0 }
                    return left.count < right.count ? -1 : 1
                }
            }
        }
    }
}
