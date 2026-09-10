//
//  TableLoadResultMetrics.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// The shape of the result a load produced. The byte size is estimated rather than measured, because
/// nothing in the driver layer reports one and walking every cell of a wide result is main-actor work
/// at exactly the instant the trace is timing, which would corrupt the measurement it exists to take.
///
/// The sample is ten runs of consecutive rows spread evenly across the result, which is the shape
/// that survives both ways a result is not uniform: taking the head would be biased by an `ORDER BY`
/// that puts the large rows at one end, and taking every nth row would alias against a result whose
/// size repeats with a period the stride happens to divide. A result small enough to walk outright is
/// walked, so only a result too large to measure cheaply is ever an estimate.
internal struct TableLoadResultMetrics: Sendable, Equatable {
    internal static let sampleBlockCount = 10
    internal static let sampleBlockSize = 10
    internal static let sampleLimit = sampleBlockCount * sampleBlockSize

    internal let rowCount: Int
    internal let columnCount: Int
    internal let estimatedBytes: Int

    internal init(rowCount: Int, columnCount: Int, estimatedBytes: Int) {
        self.rowCount = rowCount
        self.columnCount = columnCount
        self.estimatedBytes = estimatedBytes
    }

    internal init(rows: [[PluginCellValue]], columnCount: Int) {
        self.init(
            rowCount: rows.count,
            columnCount: columnCount,
            estimatedBytes: Self.estimateBytes(rows: rows)
        )
    }

    internal static func estimateBytes(rows: [[PluginCellValue]]) -> Int {
        guard !rows.isEmpty else { return 0 }
        guard rows.count > sampleLimit else {
            return rows.reduce(0) { $0 + byteCount(of: $1) }
        }

        let span = rows.count - sampleBlockSize
        var sampledBytes = 0
        for block in 0..<sampleBlockCount {
            let start = span * block / (sampleBlockCount - 1)
            for index in start..<(start + sampleBlockSize) {
                sampledBytes += byteCount(of: rows[index])
            }
        }
        return sampledBytes * rows.count / sampleLimit
    }

    private static func byteCount(of row: [PluginCellValue]) -> Int {
        row.reduce(0) { $0 + byteCount(of: $1) }
    }

    private static func byteCount(of value: PluginCellValue) -> Int {
        switch value {
        case .null: 0
        case let .text(text): text.utf8.count
        case let .bytes(data): data.count
        }
    }
}
