import Foundation

public extension EtcdKeyRange {
    init(key: Data, rangeEnd: Data?) {
        self.key = key
        self.rangeEnd = rangeEnd
    }
}

public struct EtcdRangeBatch<Item> {
    public let items: [Item]
    public let more: Bool
    public let revision: Int64?

    public init(items: [Item], more: Bool, revision: Int64?) {
        self.items = items
        self.more = more
        self.revision = revision
    }
}

public struct EtcdPageStart: Equatable, Sendable {
    public let range: EtcdKeyRange
    public let revision: Int64?

    public init(range: EtcdKeyRange, revision: Int64?) {
        self.range = range
        self.revision = revision
    }
}

// Reads a key range a bounded batch per request instead of in one response. A batch sends no sort order, so etcd
// applies the limit as it reads, in ascending key order; a descending sort makes it read the whole range first. Every
// request after the first reads at the first one's revision, so the batches are one snapshot, as a single request is.
public enum EtcdRangeScan {
    public static func keyAfter(_ key: Data) -> Data {
        key + Data([0])
    }

    // The rest of `range` after `key`, in ascending order.
    public static func range(after key: Data, in range: EtcdKeyRange) -> EtcdKeyRange {
        EtcdKeyRange(key: keyAfter(key), rangeEnd: range.rangeEnd)
    }

    // The part of `range` below `key`, which is where a descending read goes on.
    public static func range(before key: Data, in range: EtcdKeyRange) -> EtcdKeyRange {
        EtcdKeyRange(key: range.key, rangeEnd: key)
    }

    // Hands each batch to `body` until it returns false, the range ends or `maxItems` have been read.
    public static func scan<Item>(
        _ range: EtcdKeyRange,
        batchSize: Int,
        maxItems: Int,
        key: (Item) -> Data,
        fetch: (_ range: EtcdKeyRange, _ limit: Int64, _ revision: Int64?) async throws -> EtcdRangeBatch<Item>,
        body: ([Item]) throws -> Bool
    ) async throws {
        var current = range
        var revision: Int64?
        var read = 0
        while read < maxItems {
            try Task.checkCancellation()
            let batch = try await fetch(current, Int64(min(max(1, batchSize), maxItems - read)), revision)
            revision = revision ?? batch.revision
            read += batch.items.count
            guard try body(batch.items), batch.more, let last = batch.items.last else { return }
            current = Self.range(after: key(last), in: range)
        }
    }

    // Where the page at `offset` begins, found by reading keys alone and never past the offset. Nil when the range
    // has no key at that offset.
    public static func pageStart(
        of range: EtcdKeyRange,
        skipping offset: Int,
        batchSize: Int,
        fetchKeys: (_ range: EtcdKeyRange, _ limit: Int64, _ revision: Int64?) async throws -> EtcdRangeBatch<Data>
    ) async throws -> EtcdPageStart? {
        guard offset > 0 else { return EtcdPageStart(range: range, revision: nil) }
        var current = range
        var revision: Int64?
        var remaining = offset
        while remaining > 0 {
            try Task.checkCancellation()
            let batch = try await fetchKeys(current, Int64(min(remaining, max(1, batchSize))), revision)
            revision = revision ?? batch.revision
            guard batch.more, let last = batch.items.last else { return nil }
            remaining -= batch.items.count
            current = Self.range(after: last, in: range)
        }
        return EtcdPageStart(range: current, revision: revision)
    }
}

public enum EtcdCompaction {
    // etcd's ErrCompacted, sent as gRPC OutOfRange.
    public static func isCompacted(grpcCode: Int?, message: String) -> Bool {
        grpcCode == 11 && message.contains("required revision has been compacted")
    }

    // A read pinned to its first batch's revision fails once the store compacts past it. It starts over once at the
    // current revision, which is what a single request would have read.
    public static func restartingOnce<Value>(
        when isCompacted: (Error) -> Bool,
        _ read: () async throws -> Value
    ) async throws -> Value {
        do {
            return try await read()
        } catch let error where isCompacted(error) {
            return try await read()
        }
    }
}

// The matching rows of one page, gathered from rows read in ascending key order. A descending page is the tail of the
// ascending matches, so it keeps only the last `offset + limit` of them rather than every row in the range.
public struct EtcdPageCollector<Item> {
    private let offset: Int
    private let limit: Int
    private let ascending: Bool
    private var skipped = 0
    private var kept: [Item] = []

    public init(offset: Int, limit: Int, ascending: Bool) {
        self.offset = max(0, offset)
        self.limit = max(0, limit)
        self.ascending = ascending
    }

    // False once an ascending page is complete, so the read can stop.
    public mutating func add(_ item: Item) -> Bool {
        if ascending {
            guard kept.count < limit else { return false }
            if skipped < offset {
                skipped += 1
            } else {
                kept.append(item)
            }
            return kept.count < limit
        }
        let capacity = offset + limit
        guard capacity > 0 else { return true }
        kept.append(item)
        if kept.count >= 2 * capacity {
            kept.removeFirst(kept.count - capacity)
        }
        return true
    }

    public var page: [Item] {
        guard !ascending else { return kept }
        return Array(kept.suffix(offset + limit).dropLast(offset).reversed())
    }

    var heldCount: Int { kept.count }
}
