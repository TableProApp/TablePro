import Foundation
import os
import TableProTabularIO

public final class TabularProgressCounter: Sendable {
    private let state: OSAllocatedUnfairLock<(done: Int, lastReported: Double)>
    private let total: Int
    private let report: @Sendable (Double) -> Void

    public init(total: Int, report: @escaping @Sendable (Double) -> Void) {
        self.total = max(1, total)
        self.report = report
        state = OSAllocatedUnfairLock(initialState: (0, 0))
    }

    public func add(_ units: Int) {
        let fraction = state.withLock { current -> Double? in
            current.done += units
            let fraction = min(1, Double(current.done) / Double(total))
            guard fraction - current.lastReported >= 0.01 || fraction >= 1 else { return nil }
            current.lastReported = fraction
            return fraction
        }
        if let fraction {
            report(fraction)
        }
    }
}

public enum TabularScanEngine {
    public static let cancellationStride = 4_096

    public static func matchingRows(
        in table: TabularTable,
        matcher: TabularRowMatcher,
        rows: Range<Int>? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [Int] {
        let scope = (rows ?? 0..<table.rowCount).clamped(to: 0..<table.rowCount)
        guard !matcher.isTrivial else { return Array(scope) }
        let chunked = try await forEachChunk(of: scope, progress: progress) { chunk, counter in
            var matches: [Int] = []
            let completed = scanChunk(table, columns: matcher.columns, rows: chunk, counter: counter) { row, cells in
                if matcher.matches(cells) {
                    matches.append(row)
                }
            }
            guard completed else { throw CancellationError() }
            return matches
        }
        return chunked.flatMap { $0 }
    }

    public static func forEachChunk<Result: Sendable>(
        of scope: Range<Int>,
        progress: @escaping @Sendable (Double) -> Void,
        _ work: @escaping @Sendable (Range<Int>, TabularProgressCounter) throws -> Result
    ) async throws -> [Result] {
        guard !scope.isEmpty else { return [] }
        let counter = TabularProgressCounter(total: scope.count, report: progress)
        let chunks = TabularChunking.ranges(count: scope.count).map {
            (scope.lowerBound + $0.lowerBound)..<(scope.lowerBound + $0.upperBound)
        }
        return try await withThrowingTaskGroup(of: (Int, Result).self) { group in
            for (position, chunk) in chunks.enumerated() {
                group.addTask {
                    try Task.checkCancellation()
                    return (position, try work(chunk, counter))
                }
            }
            var results = [Result?](repeating: nil, count: chunks.count)
            for try await (position, result) in group {
                results[position] = result
            }
            return results.compactMap { $0 }
        }
    }

    @discardableResult
    public static func scanChunk(
        _ table: TabularTable,
        columns: [TabularColumnID],
        rows: Range<Int>,
        counter: TabularProgressCounter?,
        _ body: (Int, TabularRowCells) -> Void
    ) -> Bool {
        var processed = 0
        var cancelled = false
        table.scan(columns: columns, rows: rows) { row, cells in
            processed += 1
            if processed == cancellationStride {
                counter?.add(processed)
                processed = 0
                if Task.isCancelled {
                    cancelled = true
                    return false
                }
            }
            body(row, cells)
            return true
        }
        counter?.add(processed)
        return !cancelled
    }
}
