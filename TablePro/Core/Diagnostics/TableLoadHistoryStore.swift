//
//  TableLoadHistoryStore.swift
//  TablePro
//

import Foundation
import os

/// Where a finished trace goes. The one requirement is that the producer is a synchronous
/// `@MainActor` method, so this cannot be `async`: the call has to return before any disk work
/// happens or the measurement pays for its own recording.
internal protocol TableLoadSummarySink: Sendable {
    func record(_ record: TableLoadPerformanceRecord)
}

/// What `TableLoadTracer.shared` gets under XCTest. Dozens of coordinator suites drive
/// `openTableTab`, which begins real traces, and `AppStorageEnvironment` resolves to the production
/// directory under a unit-test host, so a live sink would append to the developer's own history on
/// every test run. Discarding at the sink means no file is opened and nothing needs cleaning up.
internal struct DiscardingTableLoadSummarySink: TableLoadSummarySink {
    internal func record(_ record: TableLoadPerformanceRecord) {}
}

/// A bounded, device-local history of how long table loads took, kept so an intermittent slowdown
/// can be looked at after it happened rather than only while `log stream` is running.
///
/// Newline-delimited JSON rather than the single re-encoded array `ExecutionAuditLog` uses. Two
/// reasons, both about the caps this store has and that one does not: rewriting the whole array costs
/// the size of the store on every append, which at the ten thousand records allowed here is megabytes
/// written per table click; and a write torn by a crash takes the entire array with it, where a torn
/// final line costs one record. Nothing is held in memory between appends either, because ten
/// thousand decoded records is a lot of residency for a file the running app never reads.
internal actor TableLoadHistoryStore: TableLoadSummarySink {
    internal static let shared = TableLoadHistoryStore()

    internal static let retentionDays = 7
    internal static let maxRecords = 10_000
    internal static let maxBytes = 5 * 1_024 * 1_024

    private static let prunePeriod: TimeInterval = 3_600
    private static let newline = UInt8(ascii: "\n")
    private static let logger = Logger(subsystem: "com.TablePro", category: "TableLoadHistory")

    /// Fractional seconds, because a store that measures milliseconds and stamps whole seconds
    /// cannot order a burst of navigation inside one, and the retention pass sorts on this field.
    private static let timestamps = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private let fileURL: URL
    private var recordCount = 0
    private var fileBytes = 0
    private var lastPrunedAt = Date.distantPast
    private var loaded = false

    internal init(fileURL: URL = TableLoadHistoryStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    /// Resolved through `AppStorageEnvironment` like every other store, so a UI test writes into its
    /// own sandbox rather than the history of the person running it.
    internal static func defaultFileURL() -> URL {
        let directory = AppStorageEnvironment.shared.supportDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("TableLoadHistory.jsonl")
    }

    nonisolated internal func record(_ record: TableLoadPerformanceRecord) {
        Task { await self.append(record) }
    }

    internal func append(_ record: TableLoadPerformanceRecord) {
        loadIfNeeded()
        guard let line = Self.encode(record), writeLine(line) else { return }
        recordCount += 1
        fileBytes += line.count
        pruneIfNeeded()
    }

    internal func records() -> [TableLoadPerformanceRecord] {
        loadIfNeeded()
        return Self.decodeRecords(in: Self.readFile(at: fileURL)).map(\.record)
    }

    /// Byte-for-byte stable for the same input, so an external report can diff two exports.
    internal func exportJSON() -> Data {
        (try? Self.makeEncoder(prettyPrinted: true).encode(records())) ?? Data()
    }

    /// The first touch in a process reconciles the file against the retention rules, so a history
    /// left behind by a build that quit before pruning cannot grow past its caps.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        prune()
    }

    private func pruneIfNeeded() {
        let isOverCapacity = recordCount > Self.maxRecords || fileBytes > Self.maxBytes
        let isStale = Date().timeIntervalSince(lastPrunedAt) > Self.prunePeriod
        guard isOverCapacity || isStale else { return }
        prune()
    }

    /// An undecodable line is dropped rather than refused. A history whose tail was torn by a crash
    /// has to keep working, because it is diagnostic data and refusing to read it would make the
    /// store itself the outage. The count is logged rather than swallowed, so a schema change that
    /// makes an older record unreadable shows up as a number instead of a file that quietly shrank.
    ///
    /// The counts are set from the file as read before the rewrite, so a write that fails leaves the
    /// caps reflecting what is still on disk. Left at zero they would read as under capacity and the
    /// only retry would be the hourly one, which is an hour of appending with no bound enforced.
    private func prune() {
        lastPrunedAt = Date()

        let data = Self.readFile(at: fileURL)
        guard !data.isEmpty else {
            recordCount = 0
            fileBytes = 0
            return
        }

        let decoded = Self.decodeRecords(in: data)
        let unreadable = data.split(separator: Self.newline, omittingEmptySubsequences: true).count - decoded.count
        if unreadable > 0 {
            Self.logger.notice(
                "Dropped \(unreadable, privacy: .public) unreadable line(s) from the table load history"
            )
        }

        recordCount = decoded.count
        fileBytes = data.count

        let cutoff = Date().addingTimeInterval(-Double(Self.retentionDays) * 86_400)
        var kept = decoded.filter { $0.record.recordedAt >= cutoff }
        kept.sort { $0.record.recordedAt < $1.record.recordedAt }

        if kept.count > Self.maxRecords {
            kept.removeFirst(kept.count - Self.maxRecords)
        }

        var total = kept.reduce(0) { $0 + $1.line.count + 1 }
        var dropped = 0
        while total > Self.maxBytes, dropped < kept.count {
            total -= kept[dropped].line.count + 1
            dropped += 1
        }
        if dropped > 0 {
            kept.removeFirst(dropped)
        }

        var output = Data()
        for entry in kept {
            output.append(entry.line)
            output.append(Self.newline)
        }
        write(output, recordCount: kept.count)
    }

    private func write(_ output: Data, recordCount newCount: Int) {
        do {
            try output.write(to: fileURL, options: .atomic)
            recordCount = newCount
            fileBytes = output.count
            Self.restrictPermissions(of: fileURL)
        } catch {
            Self.logger.error(
                "Table load history could not be rewritten: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func writeLine(_ line: Data) -> Bool {
        let path = fileURL.path(percentEncoded: false)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(
                atPath: path,
                contents: nil,
                attributes: [.posixPermissions: NSNumber(value: 0o600)]
            )
        }

        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            Self.logger.error("Table load history could not be opened for writing")
            return false
        }
        defer { try? handle.close() }

        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            return true
        } catch {
            Self.logger.error(
                "Table load history could not be appended to: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    private static func encode(_ record: TableLoadPerformanceRecord) -> Data? {
        guard var data = try? makeEncoder(prettyPrinted: false).encode(record) else {
            logger.error("Table load history record could not be encoded")
            return nil
        }
        data.append(newline)
        return data
    }

    private static func decodeRecords(in data: Data) -> [(record: TableLoadPerformanceRecord, line: Data)] {
        let decoder = makeDecoder()
        return data.split(separator: newline, omittingEmptySubsequences: true).compactMap { slice in
            let line = Data(slice)
            guard let record = try? decoder.decode(TableLoadPerformanceRecord.self, from: line) else { return nil }
            return (record, line)
        }
    }

    internal static func makeEncoder(prettyPrinted: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(timestamps.format(date))
        }
        return encoder
    }

    internal static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            return try Date(text, strategy: timestamps)
        }
        return decoder
    }

    private static func readFile(at url: URL) -> Data {
        (try? Data(contentsOf: url)) ?? Data()
    }

    private static func restrictPermissions(of url: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path(percentEncoded: false)
        )
    }
}
