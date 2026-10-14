//
//  TableLoadHistoryStoreTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct TableLoadHistoryStoreTests {
    private static let stamp = TableLoadRuntimeStamp(
        appVersion: "0.68.0",
        appBuild: "1234",
        osVersion: "macOS 15.2.0"
    )

    private static let encoder = TableLoadHistoryStore.makeEncoder()

    private func makeStore() -> (store: TableLoadHistoryStore, fileURL: URL) {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableLoadHistoryStoreTests.\(UUID().uuidString).jsonl")
        return (TableLoadHistoryStore(fileURL: fileURL), fileURL)
    }

    /// Dated relative to now, because opening a store prunes it against the retention window and a
    /// fixture dated from the epoch would be pruned before the test could look at it.
    private func moment(_ secondsAgo: Int) -> Date {
        Date(timeIntervalSinceNow: -Double(secondsAgo))
    }

    private func record(
        recordedAt: Date = .now,
        outcome: TableLoadOutcome = .completed,
        totalMs: Int = 100,
        padding: Int = 0
    ) -> TableLoadPerformanceRecord {
        TableLoadPerformanceRecord(
            summary: TableLoadTraceSummary(
                origin: .sidebar,
                outcome: outcome,
                anomalies: [],
                environment: TableLoadEnvironment(
                    databaseTypeId: "SQLite" + String(repeating: "x", count: padding),
                    usesSSH: false,
                    openTabCount: 2
                ),
                resultMetrics: TableLoadResultMetrics(rowCount: 10, columnCount: 4, estimatedBytes: 512),
                total: .milliseconds(totalMs),
                preparation: nil,
                driverFetch: .milliseconds(totalMs / 2),
                resultApply: nil,
                gridReload: nil,
                mainRunLoopIdle: nil
            ),
            stamp: Self.stamp,
            recordedAt: recordedAt
        )
    }

    private func write(_ contents: String, to fileURL: URL) throws {
        try Data(contents.utf8).write(to: fileURL)
    }

    private func line(for record: TableLoadPerformanceRecord) throws -> String {
        let data = try Self.encoder.encode(record)
        return try #require(String(data: data, encoding: .utf8))
    }

    private func writeLines(_ records: [TableLoadPerformanceRecord], to fileURL: URL) throws {
        let lines = try records.map { try line(for: $0) }
        try write(lines.joined(separator: "\n") + "\n", to: fileURL)
    }

    /// Decodes every line strictly, so a line the store should have dropped fails the test.
    private func storedRecords(at fileURL: URL) throws -> [TableLoadPerformanceRecord] {
        let decoder = TableLoadHistoryStore.makeDecoder()
        return try Data(contentsOf: fileURL)
            .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .map { try decoder.decode(TableLoadPerformanceRecord.self, from: Data($0)) }
    }

    // MARK: - Appending

    @Test("A record appended by a new store over the same file joins the ones before it")
    func appendedRecordSurvivesReopening() async throws {
        let (store, fileURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        await store.append(record(recordedAt: moment(10), totalMs: 640))
        await TableLoadHistoryStore(fileURL: fileURL).append(record(totalMs: 7))

        let records = try storedRecords(at: fileURL)
        #expect(records.map(\.totalMs) == [640, 7])
    }

    @Test("Every appended record is kept, in the order they were written")
    func keepsEveryAppendedRecord() async throws {
        let (store, fileURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        for index in 0..<20 {
            await store.append(record(recordedAt: moment(100 - index), totalMs: index))
        }

        let records = try storedRecords(at: fileURL)
        #expect(records.map(\.totalMs) == (0..<20).map(Double.init))
    }

    @Test("A store with no file starts one with its first record")
    func missingFileStartsWithFirstRecord() async throws {
        let (store, fileURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        await store.append(record(totalMs: 7))

        let records = try storedRecords(at: fileURL)
        #expect(records.map(\.totalMs) == [7])
    }

    @Test("The history file is readable only by its owner")
    func restrictsFilePermissions() async throws {
        let (store, fileURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        await store.append(record())

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue == 0o600)
    }

    // MARK: - Retention

    @Test("Records past the retention window are dropped when the store is next written to")
    func dropsRecordsPastTheRetentionWindow() async throws {
        let (store, fileURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let day = 86_400
        try writeLines(
            [
                record(recordedAt: moment(8 * day), totalMs: 1),
                record(recordedAt: moment(6 * day), totalMs: 2),
                record(recordedAt: moment(60), totalMs: 3)
            ],
            to: fileURL
        )

        await store.append(record(totalMs: 4))

        let records = try storedRecords(at: fileURL)
        #expect(records.map(\.totalMs) == [2, 3, 4])
    }

    @Test("The oldest records go first once the count cap is passed")
    func enforcesTheRecordCapOldestFirst() async throws {
        let (store, fileURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let overflow = 12
        let total = TableLoadHistoryStore.maxRecords + overflow
        try writeLines(
            (0..<total).map { record(recordedAt: moment(total - $0), totalMs: $0) },
            to: fileURL
        )

        await store.append(record(totalMs: total))

        let records = try storedRecords(at: fileURL)
        #expect(records.count == TableLoadHistoryStore.maxRecords)
        #expect(records.first?.totalMs == Double(overflow + 1))
        #expect(records.last?.totalMs == Double(total))
    }

    /// Padded so the byte cap binds before the count cap does, which is the only way to see it act.
    @Test("The oldest records go first once the byte cap is passed")
    func enforcesTheByteCapOldestFirst() async throws {
        let (store, fileURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let padding = 512
        let lineBytes = try line(for: record(padding: padding)).utf8.count + 1
        let fitting = TableLoadHistoryStore.maxBytes / lineBytes
        let total = fitting + 40
        #expect(total < TableLoadHistoryStore.maxRecords)

        try writeLines(
            (0..<total).map { record(recordedAt: moment(total - $0), totalMs: $0, padding: padding) },
            to: fileURL
        )

        await store.append(record(totalMs: total, padding: padding))

        let records = try storedRecords(at: fileURL)
        #expect(records.count < total)
        #expect(!records.isEmpty)
        #expect(records.last?.totalMs == Double(total))

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = try #require(attributes[.size] as? Int)
        #expect(size <= TableLoadHistoryStore.maxBytes)
    }

    // MARK: - Corrupt stores

    @Test("A history torn by a crash keeps every line that survived it")
    func recoversFromATruncatedFinalLine() async throws {
        let (store, fileURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let intact = try (0..<3).map { try line(for: record(recordedAt: moment(100 - $0), totalMs: $0)) }
        let torn = try String(line(for: record(totalMs: 99)).dropLast(20))
        try write(intact.joined(separator: "\n") + "\n" + torn, to: fileURL)

        await store.append(record(totalMs: 7))

        let records = try storedRecords(at: fileURL)
        #expect(records.map(\.totalMs) == [0, 1, 2, 7])
    }

    @Test("A line of garbage in the middle costs only that line")
    func recoversFromGarbageMidFile() async throws {
        let (store, fileURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let first = try line(for: record(recordedAt: moment(200), totalMs: 1))
        let second = try line(for: record(recordedAt: moment(100), totalMs: 2))
        try write("\(first)\nnot json at all\n\(second)\n", to: fileURL)

        await store.append(record(totalMs: 3))

        let records = try storedRecords(at: fileURL)
        #expect(records.map(\.totalMs) == [1, 2, 3])
    }

    @Test("A file of nothing but garbage still accepts new records")
    func recoversFromAWhollyUnreadableFile() async throws {
        let (store, fileURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try write("}{\n\u{1}\u{2}\u{3}\n[not json\n", to: fileURL)

        await store.append(record(totalMs: 7))

        let records = try storedRecords(at: fileURL)
        #expect(records.map(\.totalMs) == [7])
    }

    @Test("An empty file accepts new records")
    func recoversFromAnEmptyFile() async throws {
        let (store, fileURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try write("", to: fileURL)

        await store.append(record(totalMs: 7))

        let records = try storedRecords(at: fileURL)
        #expect(records.map(\.totalMs) == [7])
    }
}
