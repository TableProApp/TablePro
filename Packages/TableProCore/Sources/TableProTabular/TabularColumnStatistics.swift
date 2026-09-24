import Foundation
import TableProTabularIO

public struct TabularValueCount: Sendable, Equatable {
    public let value: String
    public let isEmpty: Bool
    public let count: Int

    public init(value: String, isEmpty: Bool, count: Int) {
        self.value = value
        self.isEmpty = isEmpty
        self.count = count
    }
}

public struct TabularNumericSummary: Sendable, Equatable {
    public let count: Int
    public let minimum: Double
    public let maximum: Double
    public let sum: Double
    public let mean: Double
    public let median: Double
}

public struct TabularColumnSummary: Sendable, Equatable {
    public let rowCount: Int
    public let emptyCount: Int
    public let distinctCount: Int
    public let numeric: TabularNumericSummary?
    public let nonNumericCount: Int
    public let earliestDate: String?
    public let latestDate: String?
    public let shortestLength: Int?
    public let longestLength: Int?
    public let topValues: [TabularValueCount]
}

public enum TabularColumnStatistics {
    public static let defaultTopValueLimit = 1_000
    static let partitionCount = 16

    private struct Occurrence: Sendable {
        var count: Int
        let firstKey: Int

        func adding(_ other: Occurrence) -> Occurrence {
            Occurrence(count: count + other.count, firstKey: min(firstKey, other.firstKey))
        }
    }

    private typealias RankedEntry = (key: ValueHash, occurrence: Occurrence)

    private struct Partial: Sendable {
        var rowCount = 0
        var emptyCount = 0
        var counts = [[ValueHash: Occurrence]](repeating: [:], count: partitionCount)
        var numbers: [Double] = []
        var numberSum = 0.0
        var minimum: Double?
        var maximum: Double?
        var nonNumericCount = 0
        var earliestDate: String?
        var latestDate: String?
        var shortest: Int?
        var longest: Int?
    }

    public static func summarize(
        column: TabularColumnID,
        kind: TabularInferredKind,
        keys: [Int],
        in table: TabularTable,
        topValueLimit: Int = defaultTopValueLimit,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> TabularColumnSummary {
        let numeric = kind.sortsNumerically
        let isDate = kind == .date
        let partials = try await TabularScanEngine.forEachChunk(of: 0..<keys.count, progress: { progress($0 * 0.8) }) { chunk, counter in
            var partial = Partial()
            var cancelled = false
            var processed = 0
            table.scan(columns: [column], keys: keys[chunk]) { key, cells in
                accumulate(key: key, kind: cells.kinds[0], bytes: cells.bytes[0], numeric: numeric, isDate: isDate, into: &partial)
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
            return partial
        }
        var merged = merge(partials)
        try Task.checkCancellation()
        let distinct = try await mergedCounts(partials, limit: topValueLimit)
        try Task.checkCancellation()
        let top = topValues(distinct.ranked, column: column, table: table)
        progress(1)
        return TabularColumnSummary(
            rowCount: merged.rowCount,
            emptyCount: merged.emptyCount,
            distinctCount: distinct.count,
            numeric: numeric ? numericSummary(&merged) : nil,
            nonNumericCount: numeric ? merged.nonNumericCount : 0,
            earliestDate: merged.earliestDate,
            latestDate: merged.latestDate,
            shortestLength: merged.shortest,
            longestLength: merged.longest,
            topValues: top
        )
    }

    private static func accumulate(
        key: Int,
        kind: TabularCellKind,
        bytes: UnsafeBufferPointer<UInt8>,
        numeric: Bool,
        isDate: Bool,
        into partial: inout Partial
    ) {
        partial.rowCount += 1
        let isEmpty = bytes.isEmpty || kind.isNullLike
        let hash = ValueHash(bytes, isEmpty: isEmpty)
        partial.counts[hash.partition][hash, default: Occurrence(count: 0, firstKey: key)].count += 1
        guard !isEmpty else {
            partial.emptyCount += 1
            return
        }
        let length = scalarCount(bytes)
        partial.shortest = min(partial.shortest ?? length, length)
        partial.longest = max(partial.longest ?? length, length)
        if numeric {
            if let number = TabularValueGrammar.number(bytes) {
                partial.numbers.append(number)
                partial.numberSum += number
                partial.minimum = min(partial.minimum ?? number, number)
                partial.maximum = max(partial.maximum ?? number, number)
            } else {
                partial.nonNumericCount += 1
            }
        }
        if isDate {
            let text = TabularTextCodec.utf8String(bytes)
            guard TabularTypeInference.isISODate(text) else { return }
            if partial.earliestDate.map({ text < $0 }) ?? true { partial.earliestDate = text }
            if partial.latestDate.map({ text > $0 }) ?? true { partial.latestDate = text }
        }
    }

    private static func merge(_ partials: [Partial]) -> Partial {
        var merged = Partial()
        for partial in partials {
            merged.rowCount += partial.rowCount
            merged.emptyCount += partial.emptyCount
            merged.numbers.append(contentsOf: partial.numbers)
            merged.numberSum += partial.numberSum
            if let value = partial.minimum { merged.minimum = min(merged.minimum ?? value, value) }
            if let value = partial.maximum { merged.maximum = max(merged.maximum ?? value, value) }
            merged.nonNumericCount += partial.nonNumericCount
            if let value = partial.earliestDate, merged.earliestDate.map({ value < $0 }) ?? true {
                merged.earliestDate = value
            }
            if let value = partial.latestDate, merged.latestDate.map({ value > $0 }) ?? true {
                merged.latestDate = value
            }
            if let value = partial.shortest { merged.shortest = min(merged.shortest ?? value, value) }
            if let value = partial.longest { merged.longest = max(merged.longest ?? value, value) }
        }
        return merged
    }

    private static func mergedCounts(
        _ partials: [Partial],
        limit: Int
    ) async throws -> (count: Int, ranked: [RankedEntry]) {
        try await withThrowingTaskGroup(of: (count: Int, ranked: [RankedEntry]).self) { group in
            for partition in 0..<partitionCount {
                group.addTask {
                    try Task.checkCancellation()
                    var merged: [ValueHash: Occurrence] = [:]
                    merged.reserveCapacity(partials.reduce(0) { $0 + $1.counts[partition].count })
                    for partial in partials {
                        merged.merge(partial.counts[partition]) { $0.adding($1) }
                    }
                    return (merged.count, rankedEntries(merged, limit: limit))
                }
            }
            var count = 0
            var candidates: [RankedEntry] = []
            for try await partition in group {
                count += partition.count
                candidates.append(contentsOf: partition.ranked)
            }
            return (count, Array(candidates.sorted(by: rankOrder).prefix(max(0, limit))))
        }
    }

    private static func numericSummary(_ partial: inout Partial) -> TabularNumericSummary? {
        guard let minimum = partial.minimum, let maximum = partial.maximum, !partial.numbers.isEmpty else {
            return nil
        }
        let count = partial.numbers.count
        return TabularNumericSummary(
            count: count,
            minimum: minimum,
            maximum: maximum,
            sum: partial.numberSum,
            mean: partial.numberSum / Double(count),
            median: median(of: &partial.numbers)
        )
    }

    static func median(of numbers: inout [Double]) -> Double {
        let middle = numbers.count / 2
        let upper = select(middle, in: &numbers)
        guard numbers.count.isMultiple(of: 2) else { return upper }
        let lower = numbers[0..<middle].max() ?? upper
        return (lower + upper) / 2
    }

    private static func select(_ rank: Int, in numbers: inout [Double]) -> Double {
        var low = 0
        var high = numbers.count - 1
        while low < high {
            let pivot = medianOfThree(numbers[low], numbers[(low + high) / 2], numbers[high])
            var left = low
            var right = high
            while left <= right {
                while numbers[left] < pivot { left += 1 }
                while numbers[right] > pivot { right -= 1 }
                if left <= right {
                    numbers.swapAt(left, right)
                    left += 1
                    right -= 1
                }
            }
            if rank <= right {
                high = right
            } else if rank >= left {
                low = left
            } else {
                return numbers[rank]
            }
        }
        return numbers[rank]
    }

    private static func medianOfThree(_ first: Double, _ second: Double, _ third: Double) -> Double {
        max(min(first, second), min(max(first, second), third))
    }

    private static func topValues(
        _ ranked: [RankedEntry],
        column: TabularColumnID,
        table: TabularTable
    ) -> [TabularValueCount] {
        var texts: [Int: String] = [:]
        table.scan(columns: [column], keys: ranked.map(\.occurrence.firstKey).sorted()) { key, cells in
            texts[key] = cells.string(at: 0)
            return true
        }
        return ranked.compactMap { entry in
            guard let value = texts[entry.occurrence.firstKey] else { return nil }
            return TabularValueCount(value: value, isEmpty: entry.key.isEmpty, count: entry.occurrence.count)
        }
    }

    private static func rankOrder(_ lhs: RankedEntry, _ rhs: RankedEntry) -> Bool {
        let left = lhs.occurrence.count
        let right = rhs.occurrence.count
        return left != right ? left > right : lhs.key.first < rhs.key.first
    }

    private static func rankedEntries(_ counts: [ValueHash: Occurrence], limit: Int) -> [RankedEntry] {
        let entries = counts.map { (key: $0.key, occurrence: $0.value) }
        guard entries.count > limit, limit > 0 else {
            return Array(entries.sorted(by: rankOrder).prefix(max(0, limit)))
        }
        let threshold = entries.map(\.occurrence.count).sorted(by: >)[limit - 1]
        var chosen = entries.filter { $0.occurrence.count > threshold }
        let tied = entries.filter { $0.occurrence.count == threshold }.sorted(by: rankOrder)
        chosen.append(contentsOf: tied.prefix(max(0, limit - chosen.count)))
        return chosen.sorted(by: rankOrder)
    }

    private static func scalarCount(_ bytes: UnsafeBufferPointer<UInt8>) -> Int {
        var count = 0
        for byte in bytes where byte & 0xC0 != 0x80 {
            count += 1
        }
        return count
    }
}

struct ValueHash: Hashable, Sendable {
    let first: UInt64
    let second: UInt64
    let isEmpty: Bool

    var partition: Int {
        Int(truncatingIfNeeded: second % UInt64(TabularColumnStatistics.partitionCount))
    }

    init(_ bytes: UnsafeBufferPointer<UInt8>, isEmpty: Bool) {
        self.isEmpty = isEmpty
        guard !isEmpty else {
            first = 0
            second = 0
            return
        }
        var primary: UInt64 = 0xCBF2_9CE4_8422_2325
        var secondary: UInt64 = 0x84222325_CBF29CE4
        for byte in bytes {
            primary = (primary ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
            secondary = (secondary &+ UInt64(byte)) &* 0x9E37_79B9_7F4A_7C15
            secondary ^= secondary >> 29
        }
        first = primary
        second = secondary ^ UInt64(bytes.count)
    }
}
