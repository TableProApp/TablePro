import Foundation
import Testing

@testable import TableProEtcdCore

// Answers range requests the way etcd does for a request with no sort order: ascending keys, the limit applied as it
// reads, and `more` set when the limit cut the range short.
private final class RecordingKeyspace {
    struct Request: Equatable {
        let range: EtcdKeyRange
        let limit: Int64
        let revision: Int64?
    }

    static let revision: Int64 = 7
    static let everyKey = EtcdKeyRange(key: Data([0]), rangeEnd: Data([0]))

    let keys: [Data]
    private(set) var requests: [Request] = []

    init(count: Int) {
        keys = (0..<count).map { Self.key($0) }
    }

    static func key(_ index: Int) -> Data {
        Data(String(format: "/k/%06d", index).utf8)
    }

    var keysRead: Int64 {
        requests.reduce(0) { $0 + $1.limit }
    }

    func fetch(_ range: EtcdKeyRange, _ limit: Int64, _ revision: Int64?) -> EtcdRangeBatch<Data> {
        requests.append(Request(range: range, limit: limit, revision: revision))
        let inRange = keys.filter { key in
            guard !key.lexicographicallyPrecedes(range.key) else { return false }
            guard let end = range.rangeEnd else { return key == range.key }
            return end == Data([0]) || key.lexicographicallyPrecedes(end)
        }
        let taken = Array(inRange.prefix(Int(limit)))
        return EtcdRangeBatch(items: taken, more: inRange.count > taken.count, revision: Self.revision)
    }
}

private struct Compacted: Error {}
private struct Refused: Error {}

struct EtcdRangeScanTests {
    @Test("A page deep in the range is found by reading keys up to its offset, never past it")
    func pageStartReadsKeysUpToTheOffset() async throws {
        let keyspace = RecordingKeyspace(count: 10_000)

        let start = try await EtcdRangeScan.pageStart(
            of: RecordingKeyspace.everyKey, skipping: 2_500, batchSize: 1_000
        ) { keyspace.fetch($0, $1, $2) }

        let limits = keyspace.requests.map(\.limit)
        #expect(limits == [1_000, 1_000, 500])
        #expect(keyspace.keysRead == 2_500)
        #expect(start?.range == EtcdKeyRange(
            key: RecordingKeyspace.key(2_499) + Data([0]), rangeEnd: Data([0])
        ))
        #expect(start?.revision == RecordingKeyspace.revision)
    }

    @Test("Every skip request after the first reads at the first one's revision")
    func pageStartPinsTheRevision() async throws {
        let keyspace = RecordingKeyspace(count: 5_000)

        _ = try await EtcdRangeScan.pageStart(
            of: RecordingKeyspace.everyKey, skipping: 3_000, batchSize: 1_000
        ) { keyspace.fetch($0, $1, $2) }

        let revisions = keyspace.requests.map(\.revision)
        #expect(revisions == [nil, RecordingKeyspace.revision, RecordingKeyspace.revision])
    }

    @Test("The first page needs no skip request")
    func firstPageSendsNothing() async throws {
        let keyspace = RecordingKeyspace(count: 10)

        let start = try await EtcdRangeScan.pageStart(
            of: RecordingKeyspace.everyKey, skipping: 0, batchSize: 1_000
        ) { keyspace.fetch($0, $1, $2) }

        #expect(keyspace.requests.isEmpty)
        #expect(start == EtcdPageStart(range: RecordingKeyspace.everyKey, revision: nil))
    }

    @Test("A page at or past the last key has no start", arguments: [10, 11, 50])
    func pagePastTheEndHasNoStart(offset: Int) async throws {
        let keyspace = RecordingKeyspace(count: 10)

        let start = try await EtcdRangeScan.pageStart(
            of: RecordingKeyspace.everyKey, skipping: offset, batchSize: 4
        ) { keyspace.fetch($0, $1, $2) }

        #expect(start == nil)
    }

    @Test("A scan asks for one batch at a time and stops when the reader has enough")
    func scanStopsWhenTheBodyDoes() async throws {
        let keyspace = RecordingKeyspace(count: 10_000)
        var batches: [[Data]] = []

        try await EtcdRangeScan.scan(
            RecordingKeyspace.everyKey,
            batchSize: 1_000,
            maxItems: .max,
            key: { (key: Data) in key },
            fetch: { keyspace.fetch($0, $1, $2) },
            body: { (batch: [Data]) in
                batches.append(batch)
                return batches.count < 2
            }
        )

        let limits = keyspace.requests.map(\.limit)
        let delivered = batches.flatMap { $0 }
        let expected = (0..<2_000).map(RecordingKeyspace.key)
        #expect(limits == [1_000, 1_000])
        #expect(delivered == expected)
    }

    @Test("A scan reads the whole range in order, each key once")
    func scanReadsEveryKeyOnce() async throws {
        let keyspace = RecordingKeyspace(count: 2_345)
        var seen: [Data] = []

        try await EtcdRangeScan.scan(
            RecordingKeyspace.everyKey,
            batchSize: 1_000,
            maxItems: .max,
            key: { (key: Data) in key },
            fetch: { keyspace.fetch($0, $1, $2) },
            body: { (batch: [Data]) in
                seen += batch
                return true
            }
        )

        #expect(seen == keyspace.keys)
        #expect(keyspace.requests.count == 3)
    }

    @Test("A scan stops at its row ceiling")
    func scanStopsAtTheCeiling() async throws {
        let keyspace = RecordingKeyspace(count: 5_000)
        var seen = 0

        try await EtcdRangeScan.scan(
            RecordingKeyspace.everyKey,
            batchSize: 1_000,
            maxItems: 2_500,
            key: { (key: Data) in key },
            fetch: { keyspace.fetch($0, $1, $2) },
            body: { (batch: [Data]) in
                seen += batch.count
                return true
            }
        )

        let limits = keyspace.requests.map(\.limit)
        #expect(seen == 2_500)
        #expect(limits == [1_000, 1_000, 500])
    }

    @Test("A descending read goes on below the last key it returned")
    func descendingContinuationEndsAtTheLastKey() {
        let prefix = EtcdKeyRange(key: Data("/k/".utf8), prefix: true)

        #expect(EtcdRangeScan.range(before: Data("/k/5".utf8), in: prefix)
            == EtcdKeyRange(key: Data("/k/".utf8), rangeEnd: Data("/k/5".utf8)))
    }

    @Test("An ascending page skips its offset in matches and stops reading once full")
    func ascendingCollectorStopsWhenFull() {
        var collector = EtcdPageCollector<Int>(offset: 3, limit: 2, ascending: true)
        var accepted: [Bool] = []
        for item in 0..<10 {
            let goesOn = collector.add(item)
            accepted.append(goesOn)
            if !goesOn { break }
        }

        #expect(collector.page == [3, 4])
        #expect(accepted == [true, true, true, true, false])
    }

    @Test("A descending page is the tail of the ascending matches, newest first")
    func descendingCollectorTakesTheTail() {
        var collector = EtcdPageCollector<Int>(offset: 2, limit: 3, ascending: false)
        for item in 0..<10 {
            _ = collector.add(item)
        }

        #expect(collector.page == [7, 6, 5])
    }

    @Test("A descending page holds at most twice its offset and limit, however long the range")
    func descendingCollectorStaysBounded() {
        var collector = EtcdPageCollector<Int>(offset: 5, limit: 5, ascending: false)
        var largestHeld = 0
        for item in 0..<100_000 {
            _ = collector.add(item)
            largestHeld = max(largestHeld, collector.heldCount)
        }

        #expect(largestHeld <= 20)
        #expect(collector.page == [99_994, 99_993, 99_992, 99_991, 99_990])
    }

    @Test("Only etcd's compacted-revision answer counts as compaction")
    func compactionIsRecognized() {
        #expect(EtcdCompaction.isCompacted(grpcCode: 11, message: "etcdserver: mvcc: required revision has been compacted"))
        #expect(!EtcdCompaction.isCompacted(grpcCode: 11, message: "etcdserver: mvcc: required revision is a future revision"))
        #expect(!EtcdCompaction.isCompacted(grpcCode: 3, message: "required revision has been compacted"))
    }

    @Test("A compacted read starts over once, and a second compaction is the caller's")
    func compactedReadStartsOverOnce() async {
        var attempts = 0
        var failure: Error?
        do {
            _ = try await EtcdCompaction.restartingOnce(when: { $0 is Compacted }) { () async throws -> Int in
                attempts += 1
                throw Compacted()
            }
        } catch {
            failure = error
        }

        #expect(failure is Compacted)
        #expect(attempts == 2)
    }

    @Test("A read that recovers on its second attempt returns that attempt's answer")
    func compactedReadReturnsTheRetry() async throws {
        var attempts = 0
        let answer = try await EtcdCompaction.restartingOnce(when: { $0 is Compacted }) { () async throws -> Int in
            attempts += 1
            if attempts == 1 { throw Compacted() }
            return 42
        }

        #expect(answer == 42)
        #expect(attempts == 2)
    }

    @Test("Any other failure is not retried")
    func otherFailuresAreNotRetried() async {
        var attempts = 0
        var failure: Error?
        do {
            _ = try await EtcdCompaction.restartingOnce(when: { $0 is Compacted }) { () async throws -> Int in
                attempts += 1
                throw Refused()
            }
        } catch {
            failure = error
        }

        #expect(failure is Refused)
        #expect(attempts == 1)
    }

    @Test("A descending page past the matches is empty")
    func descendingCollectorPastTheEnd() {
        var collector = EtcdPageCollector<Int>(offset: 8, limit: 5, ascending: false)
        for item in 0..<5 {
            _ = collector.add(item)
        }

        #expect(collector.page.isEmpty)
    }
}
