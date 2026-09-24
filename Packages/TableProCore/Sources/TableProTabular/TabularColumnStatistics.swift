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

    private struct Partial: Sendable {
        var rowCount = 0
        var emptyCount = 0
        var counts: [ValueHash: Int] = [:]
        var numbers: [Double] = []
        var numberSum = 0.0
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
            table.scan(columns: [column], keys: keys[chunk]) { _, cells in
                accumulate(kind: cells.kinds[0], bytes: cells.bytes[0], numeric: numeric, isDate: isDate, into: &partial)
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
        let merged = merge(partials)
        try Task.checkCancellation()
        let top = try await topValues(merged.counts, column: column, keys: keys, table: table, limit: topValueLimit)
        progress(1)
        return TabularColumnSummary(
            rowCount: merged.rowCount,
            emptyCount: merged.emptyCount,
            distinctCount: merged.counts.count,
            numeric: numeric ? numericSummary(merged) : nil,
            nonNumericCount: numeric ? merged.nonNumericCount : 0,
            earliestDate: merged.earliestDate,
            latestDate: merged.latestDate,
            shortestLength: merged.shortest,
            longestLength: merged.longest,
            topValues: top
        )
    }

    private static func accumulate(
        kind: TabularCellKind,
        bytes: UnsafeBufferPointer<UInt8>,
        numeric: Bool,
        isDate: Bool,
        into partial: inout Partial
    ) {
        partial.rowCount += 1
        let isEmpty = bytes.isEmpty || kind.isNullLike
        partial.counts[ValueHash(bytes, isEmpty: isEmpty), default: 0] += 1
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
            merged.counts.merge(partial.counts, uniquingKeysWith: +)
            merged.numbers.append(contentsOf: partial.numbers)
            merged.numberSum += partial.numberSum
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

    private static func numericSummary(_ partial: Partial) -> TabularNumericSummary? {
        guard !partial.numbers.isEmpty else { return nil }
        let sorted = partial.numbers.sorted()
        let middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        return TabularNumericSummary(
            count: sorted.count,
            minimum: sorted[0],
            maximum: sorted[sorted.count - 1],
            sum: partial.numberSum,
            mean: partial.numberSum / Double(sorted.count),
            median: median
        )
    }

    private static func topValues(
        _ counts: [ValueHash: Int],
        column: TabularColumnID,
        keys: [Int],
        table: TabularTable,
        limit: Int
    ) async throws -> [TabularValueCount] {
        let ranked = rankedEntries(counts, limit: limit)
        var wanted: [ValueHash: Int] = [:]
        for entry in ranked {
            wanted[entry.key] = entry.value
        }
        var found: [ValueHash: String] = [:]
        var position = 0
        while found.count < wanted.count, position < keys.count {
            try Task.checkCancellation()
            let end = min(keys.count, position + 65_536)
            table.scan(columns: [column], keys: keys[position..<end]) { _, cells in
                let bytes = cells.bytes[0]
                let key = ValueHash(bytes, isEmpty: bytes.isEmpty || cells.kinds[0].isNullLike)
                if wanted[key] != nil, found[key] == nil {
                    found[key] = cells.string(at: 0)
                }
                return found.count < wanted.count
            }
            position = end
        }
        return ranked.compactMap { entry in
            guard let value = found[entry.key] else { return nil }
            return TabularValueCount(value: value, isEmpty: entry.key.isEmpty, count: entry.value)
        }
    }

    private static func rankedEntries(_ counts: [ValueHash: Int], limit: Int) -> [(key: ValueHash, value: Int)] {
        let byCount: ((key: ValueHash, value: Int), (key: ValueHash, value: Int)) -> Bool = { lhs, rhs in
            lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key.first < rhs.key.first
        }
        guard counts.count > limit, limit > 0 else {
            return Array(counts.sorted(by: byCount).prefix(max(0, limit)))
        }
        let threshold = counts.values.sorted(by: >)[limit - 1]
        var chosen = counts.filter { $0.value > threshold }.map { (key: $0.key, value: $0.value) }
        for entry in counts where entry.value == threshold {
            guard chosen.count < limit else { break }
            chosen.append((key: entry.key, value: entry.value))
        }
        return chosen.sorted(by: byCount)
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
