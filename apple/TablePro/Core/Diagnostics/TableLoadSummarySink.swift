import Foundation
import os

// Not async: the producer is a synchronous main-actor method, called after the trace's timings are taken.
internal protocol TableLoadSummarySink: Sendable {
    func record(_ record: TableLoadPerformanceRecord)
}

/// One `tableload <json>` line per finished load on standard error, for a benchmark that launched the
/// app with `TABLEPRO_TABLE_LOAD_TRACE=1`. Nothing in the app reads a load back, so nothing is kept.
internal struct TableLoadStandardErrorSink: TableLoadSummarySink {
    internal static let linePrefix = "tableload "

    private let write: @Sendable (Data) -> Void

    internal init(write: @escaping @Sendable (Data) -> Void = { FileHandle.standardError.write($0) }) {
        self.write = write
    }

    internal func record(_ record: TableLoadPerformanceRecord) {
        guard let json = try? TableLoadPerformanceRecord.makeEncoder().encode(record) else { return }
        var line = Data(Self.linePrefix.utf8)
        line.append(json)
        line.append(UInt8(ascii: "\n"))
        write(line)
    }
}

/// Builds up to 0.87 kept every load for a week in `TableLoadHistory.jsonl`, up to 5 MB. It is one
/// stat when absent, so it is checked at every launch rather than tracked.
internal enum RetiredTableLoadHistory {
    internal static let fileName = "TableLoadHistory.jsonl"

    private static let logger = Logger(subsystem: "com.TablePro", category: "TableLoad")

    internal static func remove(in supportDirectory: URL, fileManager: FileManager = .default) {
        let file = supportDirectory.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: file.path(percentEncoded: false)) else { return }
        do {
            try fileManager.removeItem(at: file)
        } catch {
            logger.error("Retired table load history could not be removed: \(error.publicLogShape, privacy: .public)")
        }
    }
}
