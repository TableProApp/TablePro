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

    public static func sortedKeys(
        _ rows: [Int],
        in table: TabularTable,
        by keys: [TabularSortKey],
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [Int] {
        guard !keys.isEmpty, rows.count > 1 else { return rows }
        let extracted = try await extractKeys(rows, table: table, keys: keys) { progress($0 * 0.5) }
        try Task.checkCancellation()
        let order = try await sortPositions(count: rows.count, buffers: extracted)
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
        store.appendBuilt(kind: .text) { key in
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
        }
    }

    private static func extractKeys(
        _ rows: [Int],
        table: TabularTable,
        keys: [TabularSortKey],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> SortKeyBuffers {
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
            table.scan(columns: columnIDs, keys: rows[chunk]) { _, cells in
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
        return SortKeyBuffers(keys: keys, count: rows.count, chunks: perChunk)
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

    private static func sortPositions(count: Int, buffers: SortKeyBuffers) async throws -> [Int] {
        let chunks = TabularChunking.ranges(count: count)
        var runs = try await withThrowingTaskGroup(of: (Int, [Int]).self) { group in
            for (index, chunk) in chunks.enumerated() {
                group.addTask {
                    try Task.checkCancellation()
                    let comparator = buffers.comparator
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
        while runs.count > 1 {
            try Task.checkCancellation()
            let pairs = stride(from: 0, to: runs.count, by: 2).map { index in
                (runs[index], index + 1 < runs.count ? runs[index + 1] : [])
            }
            runs = try await withThrowingTaskGroup(of: (Int, [Int]).self) { group in
                for (index, pair) in pairs.enumerated() {
                    group.addTask {
                        try Task.checkCancellation()
                        return (index, merge(pair.0, pair.1, comparator: buffers.comparator))
                    }
                }
                var merged = [[Int]](repeating: [], count: pairs.count)
                for try await (index, run) in group {
                    merged[index] = run
                }
                return merged
            }
        }
        return withExtendedLifetime(buffers) { runs.first ?? [] }
    }

    private static func merge(_ left: [Int], _ right: [Int], comparator: PositionComparator) -> [Int] {
        guard !right.isEmpty else { return left }
        guard !left.isEmpty else { return right }
        var result: [Int] = []
        result.reserveCapacity(left.count + right.count)
        var leftIndex = 0
        var rightIndex = 0
        while leftIndex < left.count, rightIndex < right.count {
            if comparator.precedes(right[rightIndex], left[leftIndex]) {
                result.append(right[rightIndex])
                rightIndex += 1
            } else {
                result.append(left[leftIndex])
                leftIndex += 1
            }
        }
        result.append(contentsOf: left[leftIndex...])
        result.append(contentsOf: right[rightIndex...])
        return result
    }

    private struct ColumnView {
        let buckets: UnsafeMutableBufferPointer<UInt8>
        let numbers: UnsafeMutableBufferPointer<Double>
        let textBytes: UnsafeMutableBufferPointer<UInt8>
        let textEnds: UnsafeMutableBufferPointer<Int>
        let ascending: Bool
    }

    private final class SortKeyBuffers: @unchecked Sendable {
        let views: UnsafeMutableBufferPointer<ColumnView>

        init(keys: [TabularSortKey], count: Int, chunks: [[ColumnKeys]]) {
            views = .allocate(capacity: keys.count)
            for (index, key) in keys.enumerated() {
                let textByteCount = chunks.reduce(0) { $0 + $1[index].text.bytes.count }
                let view = ColumnView(
                    buckets: .allocate(capacity: count),
                    numbers: .allocate(capacity: key.numeric ? count : 0),
                    textBytes: .allocate(capacity: textByteCount),
                    textEnds: .allocate(capacity: count),
                    ascending: key.ascending
                )
                var position = 0
                var byteOffset = 0
                for chunk in chunks {
                    let chunkKeys = chunk[index]
                    Self.copy(chunkKeys.buckets, into: view.buckets, at: position)
                    if key.numeric {
                        Self.copy(chunkKeys.numbers, into: view.numbers, at: position)
                    }
                    Self.copy(chunkKeys.text.bytes, into: view.textBytes, at: byteOffset)
                    for (offset, end) in chunkKeys.text.ends.enumerated() {
                        view.textEnds[position + offset] = byteOffset + end
                    }
                    position += chunkKeys.buckets.count
                    byteOffset += chunkKeys.text.bytes.count
                }
                views.initializeElement(at: index, to: view)
            }
        }

        deinit {
            for view in views {
                view.buckets.deallocate()
                view.numbers.deallocate()
                view.textBytes.deallocate()
                view.textEnds.deallocate()
            }
            views.deinitialize().deallocate()
        }

        var comparator: PositionComparator {
            PositionComparator(views: UnsafeBufferPointer(views))
        }

        private static func copy<Element>(
            _ source: [Element],
            into destination: UnsafeMutableBufferPointer<Element>,
            at offset: Int
        ) {
            guard !source.isEmpty, let base = destination.baseAddress else { return }
            source.withUnsafeBufferPointer { source in
                guard let sourceBase = source.baseAddress else { return }
                (base + offset).initialize(from: sourceBase, count: source.count)
            }
        }
    }

    private struct PositionComparator: @unchecked Sendable {
        let views: UnsafeBufferPointer<ColumnView>

        func precedes(_ lhs: Int, _ rhs: Int) -> Bool {
            for view in views {
                let leftBucket = view.buckets[lhs]
                let rightBucket = view.buckets[rhs]
                if leftBucket != rightBucket {
                    return leftBucket < rightBucket
                }
                if leftBucket == Bucket.empty.rawValue { continue }
                let order: Int
                if leftBucket == Bucket.number.rawValue {
                    let left = view.numbers[lhs]
                    let right = view.numbers[rhs]
                    order = left < right ? -1 : (left > right ? 1 : 0)
                } else {
                    order = compareText(view, lhs, rhs)
                }
                if order != 0 {
                    return view.ascending ? order < 0 : order > 0
                }
            }
            return lhs < rhs
        }

        private func compareText(_ view: ColumnView, _ lhs: Int, _ rhs: Int) -> Int {
            let leftStart = lhs == 0 ? 0 : view.textEnds[lhs - 1]
            let rightStart = rhs == 0 ? 0 : view.textEnds[rhs - 1]
            let leftCount = view.textEnds[lhs] - leftStart
            let rightCount = view.textEnds[rhs] - rightStart
            let shared = min(leftCount, rightCount)
            if shared > 0, let base = view.textBytes.baseAddress {
                let result = memcmp(base + leftStart, base + rightStart, shared)
                if result != 0 { return result < 0 ? -1 : 1 }
            }
            if leftCount == rightCount { return 0 }
            return leftCount < rightCount ? -1 : 1
        }
    }
}
