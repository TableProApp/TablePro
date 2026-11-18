import Foundation
import TableProKafkaCore
import TableProWireIO

struct KafkaFetchResult: Sendable {
    let records: [KafkaRecord]
    let highWatermark: Int64
    /// True when the broker's byte budget cut the reply short, so reading forward would
    /// return more. Distinguishing this from "the partition ended" is what keeps a page from
    /// silently stopping early.
    let truncated: Bool
    // Where the next read starts, past control, aborted and compacted batches too. For one reply, nil when no batch
    // came back whole; for a whole fetch, nil only when nothing can follow Int64.max.
    let nextOffset: Int64?
    // The replies passed `byteBudget` before the read reached its end, so it returns no records.
    var stoppedAtByteBudget = false
    // Record batch bytes the replies carried, aborted and control batches included.
    var bytesRead = 0
}

enum KafkaFetchRequest {
    /// Read uncommitted would surface the records of transactions that later aborted, plus the
    /// commit and abort marker batches themselves. A debugging grid showing phantom rows from
    /// a rolled-back transaction is worse than useless, so this client always reads committed.
    private static let readCommitted: Int8 = 1

    private static let defaultPartitionBudget: Int32 = 1 * 1_024 * 1_024
    private static let maximumPartitionBudget: Int32 = 64 * 1_024 * 1_024

    // Kafka guarantees progress only for the first message in range (KIP-74), so the byte budget grows on a reply
    // that held no whole batch. `endOffset` stops the read there, so a tail window never reads past its anchor.
    // With `keepingNewest` the read runs to `endOffset` and holds only that many of the newest records it passed.
    // It gives up once the replies carried more than `byteBudget` bytes.
    static func fetch(
        topic: String,
        partition: Int32,
        startOffset: Int64,
        maximumRecords: Int,
        endOffset: Int64? = nil,
        keepingNewest: Int? = nil,
        byteBudget: Int? = nil,
        cluster: KafkaCluster
    ) async throws -> KafkaFetchResult {
        var budget = defaultPartitionBudget
        var collected: [KafkaRecord] = []
        var highWatermark: Int64 = startOffset
        var offset: Int64? = startOffset
        var sawTruncation = false
        var decompression: DecompressionBudget?
        var bytesRead = 0

        while keepingNewest != nil || collected.count < maximumRecords, let from = offset {
            if let endOffset, from >= endOffset { break }
            try Task.checkCancellation()
            let allowance = try KafkaCompression.fetchBudget(requesting: budget, after: decompression)
            let (page, spent) = try await fetchOnce(
                topic: topic,
                partition: partition,
                startOffset: from,
                budget: budget,
                decompression: allowance,
                cluster: cluster
            )
            decompression = spent
            highWatermark = page.highWatermark
            bytesRead += page.bytesRead
            if let byteBudget, bytesRead > byteBudget {
                return KafkaFetchResult(
                    records: [], highWatermark: page.highWatermark, truncated: true, nextOffset: nil,
                    stoppedAtByteBudget: true, bytesRead: bytesRead
                )
            }

            if page.records.isEmpty {
                // Commit and abort markers, aborted runs and batches compaction emptied hold offsets but no
                // records, so a reply of only those is progress, not a message too big for the budget.
                if let next = page.nextOffset, next > from {
                    offset = next
                    budget = defaultPartitionBudget
                    if next >= page.highWatermark { break }
                    continue
                }
                // No whole batch came back but the log says there is more: the next message does not
                // fit the budget. Grow it and try once more before giving up on the partition.
                let hasMore = from < page.highWatermark
                if hasMore, budget < maximumPartitionBudget {
                    budget = min(budget * 4, maximumPartitionBudget)
                    continue
                }
                if hasMore { sawTruncation = true }
                break
            }

            let kept = endOffset.map { end in page.records.filter { $0.offset < end } } ?? page.records
            collected.append(contentsOf: kept)
            if let keepingNewest, collected.count > keepingNewest {
                collected.removeFirst(collected.count - keepingNewest)
            }
            let afterRecords = page.records.last.flatMap { KafkaOffsetMath.offset(after: $0.offset) }
            offset = afterRecords.map { max($0, page.nextOffset ?? $0) }
            budget = defaultPartitionBudget
            if let next = offset, next >= page.highWatermark { break }
        }

        if keepingNewest == nil, collected.count > maximumRecords {
            collected = Array(collected.prefix(maximumRecords))
            sawTruncation = true
            offset = collected.last.flatMap { KafkaOffsetMath.offset(after: $0.offset) }
        }
        return KafkaFetchResult(
            records: collected, highWatermark: highWatermark, truncated: sawTruncation, nextOffset: offset,
            bytesRead: bytesRead
        )
    }

    // Returns the decompression budget as the reply left it, so the next page continues from it.
    private static func fetchOnce(
        topic: String,
        partition: Int32,
        startOffset: Int64,
        budget: Int32,
        decompression: DecompressionBudget,
        cluster: KafkaCluster
    ) async throws -> (KafkaFetchResult, DecompressionBudget) {
        try await cluster.withLeader(of: partition, topic: topic, api: "Fetch") { connection in
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
            var spent = decompression
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
                        return KafkaFetchResult(records: [], highWatermark: highWatermark, truncated: false, nextOffset: nil)
                    }
                    let decoded = try KafkaRecordBatchDecoder.decode(
                        blob: blob,
                        partition: index,
                        abortedTransactions: abortedTransactions,
                        skipAborted: true,
                        budget: &spent
                    )
                    // A batch can start before the offset asked for, because the broker returns
                    // whole batches. Dropping the head here is what keeps paging exact.
                    let trimmed = decoded.records.filter { $0.offset >= startOffset }
                    return KafkaFetchResult(
                        records: trimmed,
                        highWatermark: highWatermark,
                        truncated: decoded.truncated,
                        nextOffset: decoded.nextOffset,
                        bytesRead: blob.count
                    )
                }
                if flexible { try reader.taggedFields() }
                return partitions
            }
            // One topic and one partition were requested, so there is one answer.
            let result = topics.flatMap { $0 }.first
                ?? KafkaFetchResult(records: [], highWatermark: startOffset, truncated: false, nextOffset: nil)
            return (result, spent)
        }
    }
}
