import Foundation

public struct KafkaFetchTarget: Equatable, Sendable {
    public let partition: Int32
    public let startOffset: Int64

    public init(partition: Int32, startOffset: Int64) {
        self.partition = partition
        self.startOffset = startOffset
    }
}

public struct KafkaFetchedPartition: Sendable {
    public let partition: Int32
    public let errorCode: Int16
    public let highWatermark: Int64
    public let abortedTransactions: [KafkaAbortedTransaction]
    public let recordBatches: Data?
}

// Bytes the first replies of one browse may take, across every leader. A request reserves before it is sent and keeps
// the reservation until the browse ends, so the replies in flight and the pages waiting for their turn share one bound.
public final class KafkaFetchByteBudget: @unchecked Sendable {
    public let limit: Int
    private let lock = NSLock()
    private var reserved = 0

    public init(limit: Int) {
        self.limit = max(limit, 0)
    }

    public var remaining: Int {
        lock.withLock { limit - reserved }
    }

    // How many of `partitions` fit, with their bytes reserved. None fit when even one would pass the limit.
    public func reserve(partitions: Int, bytesEach: Int) -> Int {
        guard partitions > 0, bytesEach > 0 else { return 0 }
        return lock.withLock {
            let fitting = min(partitions, (limit - reserved) / bytesEach)
            guard fitting > 0 else { return 0 }
            reserved += fitting * bytesEach
            return fitting
        }
    }
}

// The Fetch request and response bodies from v4 to v12, for any number of partitions of one topic.
public enum KafkaFetchWire {
    // Read uncommitted would show records of transactions that later aborted, and their markers.
    private static let readCommitted: Int8 = 1
    private static let maximumWaitMilliseconds: Int32 = 500

    public static let firstPagesByteBudget = 64 * 1_024 * 1_024

    // A reply may pass its record limit by the fields around each partition and its aborted transactions; a reply larger
    // than this is refused, and its partitions are read on their own.
    public static func replyBytes(partitionBytes: Int32) -> Int {
        let bytes = Int(max(partitionBytes, 0))
        return bytes + bytes / 4
    }

    // What one partition of a first-page request reserves: its reply bytes, and the copy they are read into. The frame is
    // copied once into the reader, then each partition's records out of it while the reader is still held, so neither
    // step holds more than twice the reply.
    public static func reservedBytes(partitionBytes: Int32) -> Int {
        2 * replyBytes(partitionBytes: partitionBytes)
    }

    // Past the response limit a broker returns later partitions empty, and each is then read on its own.
    public static func responseBytes(partitions: Int, partitionBytes: Int32) -> Int32 {
        let (total, overflow) = Int32(clamping: max(partitions, 1)).multipliedReportingOverflow(by: partitionBytes)
        return overflow ? .max : max(total, partitionBytes)
    }

    // Only partitions with something to read, the lowest first, as many as the budget holds, and only when there are
    // several to send at once.
    public static func firstReads(
        start: [Int32: Int64],
        tail: [Int32: Int64],
        wanted: Int,
        partitionBytes: Int32
    ) -> [KafkaFetchTarget] {
        let each = reservedBytes(partitionBytes: partitionBytes)
        guard wanted > 0, each > 0 else { return [] }
        let open = start
            .filter { partition, offset in tail[partition].map { offset < $0 } ?? true }
            .map { KafkaFetchTarget(partition: $0.key, startOffset: $0.value) }
            .sorted { $0.partition < $1.partition }
            .prefix(firstPagesByteBudget / each)
        return open.count > 1 ? Array(open) : []
    }

    public static func writeRequest(
        into writer: inout KafkaProtocolWriter,
        version: Int16,
        flexible: Bool,
        topic: String,
        targets: [KafkaFetchTarget],
        partitionBytes: Int32,
        responseBytes: Int32
    ) {
        writer.int32(-1)                                      // replicaId
        writer.int32(maximumWaitMilliseconds)
        writer.int32(1)                                       // minBytes
        if version >= 3 { writer.int32(responseBytes) }
        if version >= 4 { writer.int8(readCommitted) }
        if version >= 7 {
            writer.int32(0)                                   // sessionId
            writer.int32(0)                                   // sessionEpoch
        }
        if flexible {
            writer.compactArrayCount(1)
            writer.compactString(topic)
            writer.compactArrayCount(targets.count)
        } else {
            writer.legacyArrayCount(1)
            writer.legacyString(topic)
            writer.legacyArrayCount(targets.count)
        }
        for target in targets {
            writer.int32(target.partition)
            if version >= 9 { writer.int32(-1) }              // currentLeaderEpoch
            writer.int64(target.startOffset)
            if version >= 12 { writer.int32(-1) }             // lastFetchedEpoch
            if version >= 5 { writer.int64(-1) }              // logStartOffset
            writer.int32(partitionBytes)
            if flexible { writer.emptyTaggedFields() }
        }
        if flexible { writer.emptyTaggedFields() }
        if version >= 7 {
            if flexible {
                writer.compactArrayCount(0)                   // forgottenTopicsData
            } else {
                writer.legacyArrayCount(0)
            }
        }
        if version >= 11 {
            if flexible {
                writer.compactString("")                      // rackId
            } else {
                writer.legacyString("")
            }
        }
        if flexible { writer.emptyTaggedFields() }
    }

    // A partition's error stays with that partition. Only an error for the whole request throws.
    public static func readResponse(
        _ body: inout KafkaProtocolReader,
        version: Int16,
        flexible: Bool
    ) throws -> [KafkaFetchedPartition] {
        if version >= 1 { _ = try body.int32() }              // throttleTimeMs
        if version >= 7 {
            try KafkaErrorCode.check(try body.int16(), api: "Fetch")
            _ = try body.int32()                              // sessionId
        }
        let topics = try body.array(compact: flexible) { reader -> [KafkaFetchedPartition] in
            _ = flexible ? try reader.compactString() : try reader.legacyString()
            let partitions = try reader.array(compact: flexible) { partition in
                try readPartition(&partition, version: version, flexible: flexible)
            }
            if flexible { try reader.taggedFields() }
            return partitions
        }
        return topics.flatMap { $0 }
    }

    private static func readPartition(
        _ reader: inout KafkaProtocolReader,
        version: Int16,
        flexible: Bool
    ) throws -> KafkaFetchedPartition {
        let index = try reader.int32()
        let errorCode = try reader.int16()
        let highWatermark = try reader.int64()
        if version >= 4 { _ = try reader.int64() }            // lastStableOffset
        if version >= 5 { _ = try reader.int64() }            // logStartOffset

        var aborted: [KafkaAbortedTransaction] = []
        if version >= 4 {
            aborted = try reader.array(compact: flexible) { entry in
                let producerId = try entry.int64()
                let firstOffset = try entry.int64()
                if flexible { try entry.taggedFields() }
                return KafkaAbortedTransaction(producerId: producerId, firstOffset: firstOffset)
            }
        }
        if version >= 11 { _ = try reader.int32() }           // preferredReadReplica

        let batches = flexible ? try reader.nullableCompactBytes() : try reader.nullableLegacyBytes()
        if flexible { try reader.taggedFields() }
        return KafkaFetchedPartition(
            partition: index,
            errorCode: errorCode,
            highWatermark: highWatermark,
            abortedTransactions: aborted,
            recordBatches: batches
        )
    }
}
