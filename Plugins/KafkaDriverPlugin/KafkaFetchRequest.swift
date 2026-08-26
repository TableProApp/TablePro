import Foundation

struct KafkaFetchResult: Sendable {
    let records: [KafkaRecord]
    let highWatermark: Int64
    /// True when the broker's byte budget cut the reply short, so reading forward would
    /// return more. Distinguishing this from "the partition ended" is what keeps a page from
    /// silently stopping early.
    let truncated: Bool
}

enum KafkaFetchRequest {
    /// Read uncommitted would surface the records of transactions that later aborted, plus the
    /// commit and abort marker batches themselves. A debugging grid showing phantom rows from
    /// a rolled-back transaction is worse than useless, so this client always reads committed.
    private static let readCommitted: Int8 = 1

    private static let defaultPartitionBudget: Int32 = 1 * 1024 * 1024
    private static let maximumPartitionBudget: Int32 = 64 * 1024 * 1024

    /// Fetches forward from `startOffset` in one partition.
    ///
    /// The byte budget is escalated rather than fixed. Kafka's per-partition limit guarantees
    /// progress only for a message that is FIRST in the requested range (KIP-74): a 10 MB
    /// message sitting behind a 1 MB budget returns zero records forever, and a fixed budget
    /// turns that into a page that stops early with no explanation. Doubling on an empty
    /// reply that the high watermark says should not be empty is what breaks the stall.
    static func fetch(
        topic: String,
        partition: Int32,
        startOffset: Int64,
        maximumRecords: Int,
        cluster: KafkaCluster
    ) async throws -> KafkaFetchResult {
        var budget = defaultPartitionBudget
        var collected: [KafkaRecord] = []
        var highWatermark: Int64 = startOffset
        var offset = startOffset
        var sawTruncation = false

        while collected.count < maximumRecords {
            try Task.checkCancellation()
            let page = try await fetchOnce(
                topic: topic,
                partition: partition,
                startOffset: offset,
                budget: budget,
                cluster: cluster
            )
            highWatermark = page.highWatermark

            if page.records.isEmpty {
                // Nothing came back but the log says there is more: the next message does not
                // fit the budget. Grow it and try once more before giving up on the partition.
                let hasMore = offset < page.highWatermark
                if hasMore, budget < maximumPartitionBudget {
                    budget = min(budget * 4, maximumPartitionBudget)
                    continue
                }
                if hasMore { sawTruncation = true }
                break
            }

            collected.append(contentsOf: page.records)
            guard let last = page.records.last else { break }
            offset = last.offset + 1
            budget = defaultPartitionBudget
            if offset >= page.highWatermark { break }
        }

        if collected.count > maximumRecords {
            collected = Array(collected.prefix(maximumRecords))
            sawTruncation = true
        }
        return KafkaFetchResult(records: collected, highWatermark: highWatermark, truncated: sawTruncation)
    }

    private static func fetchOnce(
        topic: String,
        partition: Int32,
        startOffset: Int64,
        budget: Int32,
        cluster: KafkaCluster
    ) async throws -> KafkaFetchResult {
        try await cluster.withLeader(of: partition, topic: topic) { connection in
            let version = try await connection.negotiatedVersion(for: .fetch)
            let flexible = KafkaApiKey.fetch.isFlexible(version: version)

            let request = KafkaRequest(api: .fetch, version: version) { writer, _ in
                writer.int32(-1)                                  // replicaId
                writer.int32(500)                                 // maxWaitMs
                writer.int32(1)                                   // minBytes
                if version >= 3 { writer.int32(budget) }          // maxBytes
                if version >= 4 { writer.int8(readCommitted) }
                if version >= 7 {
                    writer.int32(0)                               // sessionId
                    writer.int32(0)                               // sessionEpoch
                }
                if flexible {
                    writer.compactArrayCount(1)
                    writer.compactString(topic)
                    writer.compactArrayCount(1)
                } else {
                    writer.legacyArrayCount(1)
                    writer.legacyString(topic)
                    writer.legacyArrayCount(1)
                }
                writer.int32(partition)
                if version >= 9 { writer.int32(-1) }              // currentLeaderEpoch
                writer.int64(startOffset)
                if version >= 12 { writer.int32(-1) }             // lastFetchedEpoch
                if version >= 5 { writer.int64(-1) }              // logStartOffset
                writer.int32(budget)                              // partitionMaxBytes
                if flexible {
                    writer.emptyTaggedFields()
                    writer.emptyTaggedFields()
                }
                if version >= 7 {
                    if flexible {
                        writer.compactArrayCount(0)               // forgottenTopicsData
                    } else {
                        writer.legacyArrayCount(0)
                    }
                }
                if version >= 11 {
                    if flexible {
                        writer.compactString("")                  // rackId
                    } else {
                        writer.legacyString("")
                    }
                }
                if flexible { writer.emptyTaggedFields() }
            }

            var body = try await connection.send(request)
            if version >= 1 { _ = try body.int32() }              // throttleTimeMs
            if version >= 7 {
                let errorCode = try body.int16()
                try KafkaErrorCode.check(errorCode, api: "Fetch")
                _ = try body.int32()                              // sessionId
            }

            let topics = try body.array(compact: flexible) { reader -> [KafkaFetchResult] in
                _ = flexible ? try reader.compactString() : try reader.legacyString()
                let partitions = try reader.array(compact: flexible) { partitionReader -> KafkaFetchResult in
                    let index = try partitionReader.int32()
                    let errorCode = try partitionReader.int16()
                    try KafkaErrorCode.check(errorCode, api: "Fetch")
                    let highWatermark = try partitionReader.int64()
                    if version >= 4 { _ = try partitionReader.int64() }   // lastStableOffset
                    if version >= 5 { _ = try partitionReader.int64() }   // logStartOffset

                    var abortedTransactions: [KafkaAbortedTransaction] = []
                    if version >= 4 {
                        abortedTransactions = try partitionReader.array(compact: flexible) { aborted in
                            let producerId = try aborted.int64()
                            let firstOffset = try aborted.int64()
                            if flexible { try aborted.taggedFields() }
                            return KafkaAbortedTransaction(producerId: producerId, firstOffset: firstOffset)
                        }
                    }
                    if version >= 11 { _ = try partitionReader.int32() }  // preferredReadReplica

                    let blob = flexible
                        ? try partitionReader.nullableCompactBytes()
                        : try partitionReader.nullableLegacyBytes()
                    if flexible { try partitionReader.taggedFields() }

                    guard let blob, !blob.isEmpty else {
                        return KafkaFetchResult(records: [], highWatermark: highWatermark, truncated: false)
                    }
                    let decoded = try KafkaRecordBatchDecoder.decode(
                        blob: blob,
                        partition: index,
                        abortedTransactions: abortedTransactions,
                        skipAborted: true
                    )
                    // A batch can start before the offset asked for, because the broker returns
                    // whole batches. Dropping the head here is what keeps paging exact.
                    let trimmed = decoded.records.filter { $0.offset >= startOffset }
                    return KafkaFetchResult(
                        records: trimmed,
                        highWatermark: highWatermark,
                        truncated: decoded.truncated
                    )
                }
                if flexible { try reader.taggedFields() }
                return partitions
            }
            // One topic and one partition were requested, so there is one answer.
            return topics.flatMap { $0 }.first
                ?? KafkaFetchResult(records: [], highWatermark: startOffset, truncated: false)
        }
    }
}
