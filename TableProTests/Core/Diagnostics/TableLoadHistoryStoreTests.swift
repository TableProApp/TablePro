//
//  TableLoadHistoryStoreTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("TableLoadHistoryStore")
struct TableLoadHistoryStoreTests {
    private static let stamp = TableLoadRuntimeStamp(
        appVersion: "0.68.0",
        appBuild: "1234",
        osVersion: "macOS 15.2.0"
    )

    private static let encoder = TableLoadHistoryStore.makeEncoder(prettyPrinted: false)

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

    // MARK: - Round trip

    @Test("An appended record survives a new store over the same file")
    func appendedRecordSurvivesReopening() async throws {
        let (store, fileURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        await store.append(record(totalMs: 640))

        let reopened = TableLoadHistoryStore(fileURL: fileURL)
        let records = await reopened.records()
        #expect(records.count == 1)
        #expect(records.first?.totalMs == 640)
    }

    @Test("Every appended record is kept, in the order they were written")
    func keepsEveryAppendedRecord() async {
        let (store, fileURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        for index in 0..<20 {
            await store.append(record(recordedAt: moment(100 - index), totalMs: index))
        }

        let records = await store.records()
        #expect(records.map(\.totalMs) == (0..<20).map(Double.init))
    }

    @Test("A store with no file behaves as an empty one")
    func missingFileReadsAsEmpty() async {
        let (store, fileURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let records = await store.records()
        #expect(records.isEmpty)
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

    @Test("Records past the retention window are dropped when the store is next opened")
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

        let records = await store.records()
        #expect(records.map(\.totalMs) == [2, 3])
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

        let records = await store.records()
        #expect(records.count == TableLoadHistoryStore.maxRecords)
        #expect(records.first?.totalMs == Double(overflow))
        #expect(records.last?.totalMs == Double(total - 1))
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

        let records = await store.records()
        #expect(records.count < total)
        #expect(records.count > 0)
        #expect(records.last?.totalMs == Double(total - 1))

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

        let records = await store.records()
        #expect(records.map(\.totalMs) == [0, 1, 2])
    }

    @Test("A line of garbage in the middle costs only that line")
    func recoversFromGarbageMidFile() async throws {
        let (store, fileURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let first = try line(for: record(recordedAt: moment(200), totalMs: 1))
        let second = try line(for: record(recordedAt: moment(100), totalMs: 2))
        try write("\(first)\nnot json at all\n\(second)\n", to: fileURL)

        let records = await store.records()
        #expect(records.map(\.totalMs) == [1, 2])
    }

    @Test("A file of nothing but garbage reads as empty and still accepts new records")
    func recoversFromAWhollyUnreadableFile() async throws {
        let (store, fileURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try write("}{\n\u{1}\u{2}\u{3}\n[not json\n", to: fileURL)

        let recovered = await store.records()
        #expect(recovered.isEmpty)

        await store.append(record(totalMs: 7))
        let records = await store.records()
        #expect(records.map(\.totalMs) == [7])
    }

    @Test("An empty file reads as empty")
    func recoversFromAnEmptyFile() async throws {
        let (store, fileURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try write("", to: fileURL)

        let records = await store.records()
        #expect(records.isEmpty)
    }

    // MARK: - Export

    @Test("Exporting the same history twice produces the same bytes")
    func exportIsDeterministic() async {
        let (store, fileURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        for index in 0..<5 {
            await store.append(record(recordedAt: moment(50 - index), totalMs: index))
        }

        let first = await store.exportJSON()
        let second = await store.exportJSON()
        #expect(first == second)
        #expect(first.isEmpty == false)
    }

    @Test("The export decodes back into the records the store holds")
    func exportDecodesBackToItsRecords() async throws {
        let (store, fileURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        await store.append(record(recordedAt: moment(10), totalMs: 42))

        let exported = await store.exportJSON()
        let decoded = try TableLoadHistoryStore.makeDecoder().decode(
            [TableLoadPerformanceRecord].self,
            from: exported
        )

        #expect(decoded.count == 1)
        #expect(decoded.first?.totalMs == 42)
    }

    @Test("An empty history exports an empty array rather than nothing")
    func exportsAnEmptyArrayForAnEmptyHistory() async throws {
        let (store, fileURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let exported = await store.exportJSON()
        let decoded = try TableLoadHistoryStore.makeDecoder().decode(
            [TableLoadPerformanceRecord].self,
            from: exported
        )
        #expect(decoded.isEmpty)
    }
}
