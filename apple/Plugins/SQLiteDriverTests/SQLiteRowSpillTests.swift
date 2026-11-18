//
//  SQLiteRowSpillTests.swift
//  SQLiteDriverTests
//

import Foundation
import os
import TableProPluginKit
import TableProTestSupport
import TableProWireIO
import Testing

@Suite(.timeLimit(.minutes(2)))
struct SQLiteRowSpillTests {
    // Forty batches of 5,000, well past the 16 the stream buffers, so a held reader leaves most of the table unread.
    private static let rowCount = 200_000
    private static let scan = "SELECT id, payload FROM t ORDER BY rowid"

    private static func withFile(
        wal: Bool = false,
        _ body: (_ reader: SQLitePluginDriver, _ writer: SQLitePluginDriver) async throws -> Void
    ) async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("row-spill-\(UUID().uuidString).db").path
        defer {
            for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        let config = DriverConnectionConfig(host: "", port: 0, username: "", password: "", database: path)
        let reader = SQLitePluginDriver(config: config)
        let writer = SQLitePluginDriver(config: config)
        try await reader.connect()
        defer { reader.disconnect() }
        if wal { _ = try await reader.execute(query: "PRAGMA journal_mode=WAL") }
        _ = try await reader.execute(query: """
            CREATE TABLE t AS WITH RECURSIVE g(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM g WHERE x < \(rowCount))
            SELECT x AS id, hex(randomblob(50)) AS payload FROM g
            """)
        try await writer.connect()
        defer { writer.disconnect() }
        // A lock wait gives up after a second, so a check that the file is free answers quickly either way.
        try await writer.applyQueryTimeout(1)
        try await body(reader, writer)
    }

    // Counts the rows taken and the ids that are not the next one expected.
    private struct OrderedRead {
        var expected = 1
        var mismatches = 0

        mutating func take(_ element: PluginStreamElement) {
            guard case .rows(let batch) = element else { return }
            for id in batch.compactMap({ $0.first?.asText.flatMap(Int.init) }) {
                if id != expected { mismatches += 1 }
                expected += 1
            }
        }
    }

    private static func insert(_ batch: [PluginRow]) -> String {
        let values = batch.map { row in "(\(row[0].asText ?? "NULL"), '\(row[1].asText ?? "")')" }
        return "INSERT INTO copied (id, payload) VALUES " + values.joined(separator: ", ")
    }

    @Test("A reader that holds its stream no longer holds the file: another connection can take it for a write")
    func heldReaderLeavesTheFileFree() async throws {
        try await Self.withFile { reader, writer in
            var iterator = reader.streamRows(query: Self.scan).makeAsyncIterator()
            var read = OrderedRead()
            while read.expected == 1, let element = try await iterator.next() { read.take(element) }

            try await waitUntil(timeout: .seconds(30)) {
                (try? await writer.execute(query: "BEGIN EXCLUSIVE")) != nil
            }
            _ = try await writer.execute(query: "COMMIT")

            while let element = try await iterator.next() { read.take(element) }
            #expect(read.expected - 1 == Self.rowCount)
            #expect(read.mismatches == 0)
        }
    }

    @Test("A copy into a second connection to the same file finishes instead of waiting on its own read")
    func copyIntoASecondConnectionFinishes() async throws {
        try await Self.withFile { reader, writer in
            // Long enough for the read to end on a busy machine; main waits on itself past it.
            try await writer.applyQueryTimeout(15)
            _ = try await writer.execute(query: "CREATE TABLE copied (id INTEGER, payload TEXT)")
            for try await element in reader.streamRows(query: Self.scan) {
                guard case .rows(let batch) = element else { continue }
                _ = try await writer.execute(query: Self.insert(batch))
            }
            let copied = try await writer.execute(query: "SELECT count(*), min(id), max(id) FROM copied")
            let summary = copied.rows.first?.compactMap { $0.asText }
            #expect(summary == [String(Self.rowCount), "1", String(Self.rowCount)])
        }
    }

    @Test("In WAL mode a reader that holds its stream no longer keeps a checkpoint from resetting the log")
    func heldReaderLetsTheCheckpointRun() async throws {
        try await Self.withFile(wal: true) { reader, writer in
            var iterator = reader.streamRows(query: Self.scan).makeAsyncIterator()
            var read = OrderedRead()
            while read.expected == 1, let element = try await iterator.next() { read.take(element) }

            try await waitUntil(timeout: .seconds(30)) {
                _ = try await writer.execute(query: "INSERT INTO t (id, payload) VALUES (0, 'written during the read')")
                let checkpoint = try await writer.execute(query: "PRAGMA wal_checkpoint(TRUNCATE)")
                return checkpoint.rows.first?.first?.asText == "0"
            }

            while let element = try await iterator.next() { read.take(element) }
            #expect(read.expected - 1 == Self.rowCount)
            #expect(read.mismatches == 0)
        }
    }

    @Test("A read that fails after rows were spilled hands over every earlier row, then the error")
    func errorFollowsTheSpilledRows() async throws {
        let failAt = 150_000
        try await Self.withFile { reader, writer in
            let query = """
                SELECT CASE WHEN id = \(failAt) THEN abs(-9223372036854775808) ELSE id END AS id, payload
                FROM t ORDER BY rowid
                """
            var iterator = reader.streamRows(query: query).makeAsyncIterator()
            var read = OrderedRead()
            while read.expected == 1, let element = try await iterator.next() { read.take(element) }
            try await waitUntil(timeout: .seconds(30)) {
                (try? await writer.execute(query: "BEGIN EXCLUSIVE")) != nil
            }
            _ = try await writer.execute(query: "COMMIT")

            await #expect(throws: SQLitePluginError.self) {
                while let element = try await iterator.next() { read.take(element) }
            }
            #expect(read.expected == failAt)
            #expect(read.mismatches == 0)
        }
    }

    @Test("A reader that leaves an endless read stops it, and the connection runs the next statement")
    func leavingAnEndlessReadStopsIt() async throws {
        try await Self.withFile { reader, _ in
            let endless = "WITH RECURSIVE g(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM g) SELECT x, hex(randomblob(100)) FROM g"
            var iterator: AsyncThrowingStream<PluginStreamElement, Error>.Iterator? =
                reader.streamRows(query: endless).makeAsyncIterator()
            var rows = 0
            while rows == 0, let element = try await iterator?.next() {
                if case .rows(let batch) = element { rows += batch.count }
            }
            iterator = nil

            let answer = await BoundedCall.result(within: .seconds(30)) {
                try? await reader.execute(query: "SELECT 42").rows.first?.first?.asText
            }
            #expect(answer == "42")
        }
    }

    // MARK: - The spill on its own

    private static let cells: PluginRow = [.null, .text(""), .text("naïve 🧪 \u{0}"), .bytes(Data()), .bytes(Data([0, 255, 7]))]

    private static func batch(_ index: Int) -> [PluginRow] {
        (0..<100).map { [.text("\(index)-\($0)")] + cells }
    }

    private static func makeStream(
        budget: SpoolBudget = SpoolBudget(limit: 1 << 30),
        makeSpool: @escaping @Sendable () throws -> SpoolFile = { try SpoolFile() }
    ) -> (AsyncThrowingStream<PluginStreamElement, Error>, PluginRowSpill) {
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: PluginStreamElement.self, bufferingPolicy: .bufferingOldest(2)
        )
        let spill = PluginRowSpill(continuation: continuation, budget: budget, makeSpool: makeSpool)
        continuation.onTermination = { @Sendable _ in spill.abandon() }
        return (stream, spill)
    }

    private static func batches(of stream: AsyncThrowingStream<PluginStreamElement, Error>) async throws -> [[PluginRow]] {
        var batches: [[PluginRow]] = []
        for try await element in stream {
            if case .rows(let rows) = element { batches.append(rows) }
        }
        return batches
    }

    @Test("Batches the buffer cannot take come back from the spool in order, every cell as it went in")
    func spilledBatchesKeepOrderAndCells() async throws {
        let (stream, spill) = Self.makeStream()
        // On its own thread, so a producer that waited for the reader would hit the deadline instead of hanging.
        let delivered = await BoundedCall.resultOnItsOwnThread(within: .seconds(30)) {
            let accepted = (0..<40).allSatisfy { spill.deliver(Self.batch($0)) }
            spill.finish()
            return accepted
        }
        #expect(delivered == true)
        let expected = (0..<40).map { Self.batch($0) }
        #expect(try await Self.batches(of: stream) == expected)
    }

    @Test("An error after spilled batches reaches the reader after them")
    func errorAfterSpilledBatches() async throws {
        struct Failed: Error {}
        let (stream, spill) = Self.makeStream()
        for index in 0..<10 { spill.deliver(Self.batch(index)) }
        spill.finish(throwing: Failed())

        var received: [[PluginRow]] = []
        await #expect(throws: Failed.self) {
            for try await element in stream {
                if case .rows(let rows) = element { received.append(rows) }
            }
        }
        let expected = (0..<10).map { Self.batch($0) }
        #expect(received == expected)
    }

    @Test("Without a spool the producer waits for the reader, and every batch still arrives in order")
    func failedSpoolFallsBackToPacing() async throws {
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let (stream, spill) = Self.makeStream {
            attempts.withLock { $0 += 1 }
            throw SpoolFileError.cannotCreate(errno: ENOSPC)
        }
        let delivered = Self.produce(0..<20, into: spill)
        // Batch 2 meets a full buffer, so it asks for the spool.
        try await waitUntil { delivered.withLock { $0 } == 2 }
        let expected = (0..<20).map { Self.batch($0) }
        #expect(try await Self.batches(of: stream) == expected)
        #expect(attempts.withLock { $0 } == 1)
    }

    // Delivers on its own thread and counts each deliver that returned.
    private static func produce(_ indices: Range<Int>, into spill: PluginRowSpill) -> OSAllocatedUnfairLock<Int> {
        let delivered = OSAllocatedUnfairLock(initialState: 0)
        Thread {
            for index in indices {
                spill.deliver(Self.batch(index))
                delivered.withLock { $0 += 1 }
            }
            spill.finish()
        }.start()
        return delivered
    }

    private static func rows(_ element: PluginStreamElement?) -> [[PluginRow]] {
        guard case .rows(let rows)? = element else { return [] }
        return [rows]
    }

    // Batches 0 and 1 fill the buffer of two. Batch 2 spills, and the drain takes it out of the file and holds it until
    // the buffer has room, so the file is empty again before batches 3 and 4 go in.
    private static func fillWithHeldReader(_ spill: PluginRowSpill, spool: () -> SpoolFile?) async throws {
        for index in 0..<3 { spill.deliver(Self.batch(index)) }
        try await waitUntil { spool()?.byteCount == 0 }
        for index in 3..<5 { spill.deliver(Self.batch(index)) }
    }

    @Test("A spill charges its spool to the budget, refills the spool once the drain empties it, and gives it all back")
    func spillChargesTheBudget() async throws {
        let sizes = (0..<10).map { PluginRowSpill.encode(Self.batch($0)).count + 8 }
        let budget = SpoolBudget(limit: sizes[3] + sizes[4] + sizes[5] - 1)
        let created = OSAllocatedUnfairLock<[SpoolFile]>(initialState: [])
        let (stream, spill) = Self.makeStream(budget: budget) {
            let spool = try SpoolFile()
            created.withLock { $0.append(spool) }
            return spool
        }
        try await Self.fillWithHeldReader(spill) { created.withLock { $0.first } }
        let spool = try #require(created.withLock { $0.first })
        #expect(spool.byteCount == sizes[3] + sizes[4])
        #expect(budget.bytesInUse == sizes[3] + sizes[4])
        #expect(!budget.admits(sizes[5]))

        _ = Self.produce(5..<10, into: spill)
        var received: [[PluginRow]] = []
        for try await element in stream { received += Self.rows(element) }
        let expected = (0..<10).map { Self.batch($0) }
        #expect(received == expected)
        #expect(created.withLock { $0.count } == 1)
        #expect(budget.bytesInUse == 0)
    }

    @Test("With no budget left the producer waits for the reader, makes no spool, and every batch arrives in order")
    func emptyBudgetPacesEveryBatch() async throws {
        let created = OSAllocatedUnfairLock(initialState: 0)
        let (stream, spill) = Self.makeStream(budget: SpoolBudget(limit: 0)) {
            created.withLock { $0 += 1 }
            return try SpoolFile()
        }
        let delivered = Self.produce(0..<10, into: spill)
        // Batch 2 meets a full buffer, so it asks the budget.
        try await waitUntil { delivered.withLock { $0 } == 2 }
        let expected = (0..<10).map { Self.batch($0) }
        #expect(try await Self.batches(of: stream) == expected)
        #expect(created.withLock { $0 } == 0)
    }

    @Test("Spills charge one budget, and each gives back only what its own spool held")
    func spillsShareTheBudget() async throws {
        let sizes = (0..<5).map { PluginRowSpill.encode(Self.batch($0)).count + 8 }
        let held = sizes[3] + sizes[4]
        let budget = SpoolBudget(limit: held * 2)
        let spools = OSAllocatedUnfairLock<[SpoolFile]>(initialState: [])
        let makeSpool: @Sendable () throws -> SpoolFile = {
            let spool = try SpoolFile()
            spools.withLock { $0.append(spool) }
            return spool
        }
        let (first, firstSpill) = Self.makeStream(budget: budget, makeSpool: makeSpool)
        try await Self.fillWithHeldReader(firstSpill) { spools.withLock { $0.first } }
        let (second, secondSpill) = Self.makeStream(budget: budget, makeSpool: makeSpool)
        try await Self.fillWithHeldReader(secondSpill) { spools.withLock { $0.count > 1 ? $0[1] : nil } }
        #expect(budget.bytesInUse == held * 2)
        #expect(!budget.admits(1))

        firstSpill.finish()
        #expect(try await Self.batches(of: first).count == 5)
        #expect(budget.bytesInUse == held)

        secondSpill.finish()
        #expect(try await Self.batches(of: second).count == 5)
        #expect(budget.bytesInUse == 0)
    }

    @Test("Once the reader has gone the producer is told so")
    func readerGoneStopsDelivery() async throws {
        let spill: PluginRowSpill
        var iterator: AsyncThrowingStream<PluginStreamElement, Error>.Iterator?
        do {
            let (stream, made) = Self.makeStream()
            spill = made
            for index in 0..<5 { spill.deliver(Self.batch(index)) }
            iterator = stream.makeAsyncIterator()
        }
        _ = try await iterator?.next()
        iterator = nil
        try await waitUntil { !spill.deliver(Self.batch(99)) }
    }

    @Test("A batch survives the record format unchanged")
    func recordRoundTrip() throws {
        let original = Self.batch(3) + [[], [.text(String(repeating: "x", count: 100_000))]]
        #expect(try PluginRowSpill.decode(PluginRowSpill.encode(original)) == original)
        #expect(try PluginRowSpill.decode(PluginRowSpill.encode([])) == [])
        #expect(throws: (any Error).self) { try PluginRowSpill.decode([0, 0, 0, 1, 0, 0, 0, 1, 9]) }
    }
}
