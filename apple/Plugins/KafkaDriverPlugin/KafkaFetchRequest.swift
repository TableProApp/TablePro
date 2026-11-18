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

// A partition's first reply, read together with the other partitions of its leader.
struct KafkaFetchFirstPage: Sendable {
    let startOffset: Int64
    let page: KafkaFetchResult
    let decompression: DecompressionBudget
}

enum KafkaFetchRequest {
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
        firstPage: KafkaFetchFirstPage? = nil,
        cluster: KafkaCluster
    ) async throws -> KafkaFetchResult {
        var firstPage = firstPage
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
            let page: KafkaFetchResult
            if let first = firstPage, first.startOffset == from {
                page = first.page
                decompression = first.decompression
            } else {
                let allowance = try KafkaCompression.fetchBudget(requesting: budget, after: decompression)
                let (fetched, spent) = try await fetchOnce(
                    topic: topic,
                    partition: partition,
                    startOffset: from,
                    budget: budget,
                    decompression: allowance,
                    cluster: cluster
                )
                page = fetched
                decompression = spent
            }
            firstPage = nil
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

    // One request per leader for every partition's first page, the leaders read at once. It only saves round trips:
    // a partition it cannot answer is left out, and that partition's own read retries or reports what went wrong.
    static func firstPages(
        topic: String,
        targets: [KafkaFetchTarget],
        cluster: KafkaCluster
    ) async -> [Int32: KafkaFetchFirstPage] {
        guard !targets.isEmpty else { return [:] }
        let starts = Dictionary(targets.map { ($0.partition, $0.startOffset) }) { first, _ in first }
        let outcomes = try? await cluster.withLeaders(
            topic: topic,
            partitions: targets.map(\.partition)
        ) { connection, partitions in
            try await readFirstPages(topic: topic, partitions: partitions, starts: starts, on: connection)
        }
        return (outcomes ?? [:]).compactMapValues { outcome in
            guard case .value(let first) = outcome else { return nil }
            return first
        }
    }

    private static func readFirstPages(
        topic: String,
        partitions: [Int32],
        starts: [Int32: Int64],
        on connection: KafkaConnection
    ) async throws -> [Int32: KafkaPartitionOutcome<KafkaFetchFirstPage>] {
        let targets = partitions.compactMap { partition in
            starts[partition].map { KafkaFetchTarget(partition: partition, startOffset: $0) }
        }
        let replies = try await send(topic: topic, targets: targets, partitionBudget: defaultPartitionBudget, on: connection)
        var outcomes: [Int32: KafkaPartitionOutcome<KafkaFetchFirstPage>] = [:]
        for reply in replies where partitions.contains(reply.partition) {
            guard let start = starts[reply.partition] else { continue }
            guard reply.errorCode == KafkaErrorCode.none else {
                outcomes[reply.partition] = .rejected(code: reply.errorCode)
                continue
            }
            do {
                var spent = try KafkaCompression.fetchBudget(requesting: defaultPartitionBudget)
                let page = try decode(reply, from: start, budget: &spent)
                outcomes[reply.partition] = .value(KafkaFetchFirstPage(startOffset: start, page: page, decompression: spent))
            } catch {
                outcomes[reply.partition] = .failed(.malformedResponse(error.localizedDescription))
            }
        }
        return outcomes
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
            let target = KafkaFetchTarget(partition: partition, startOffset: startOffset)
            let replies = try await send(topic: topic, targets: [target], partitionBudget: budget, on: connection)
            var spent = decompression
            guard let reply = replies.first else {
                let empty = KafkaFetchResult(records: [], highWatermark: startOffset, truncated: false, nextOffset: nil)
                return (empty, spent)
            }
            try KafkaErrorCode.check(reply.errorCode, api: "Fetch")
            return (try decode(reply, from: startOffset, budget: &spent), spent)
        }
    }

    private static func send(
        topic: String,
        targets: [KafkaFetchTarget],
        partitionBudget: Int32,
        on connection: KafkaConnection
    ) async throws -> [KafkaFetchedPartition] {
        let version = try await connection.negotiatedVersion(for: .fetch)
        let flexible = KafkaApiKey.fetch.isFlexible(version: version)
        let request = KafkaRequest(api: .fetch, version: version) { writer, _ in
            KafkaFetchWire.writeRequest(
                into: &writer,
                version: version,
                flexible: flexible,
                topic: topic,
                targets: targets,
                partitionBytes: partitionBudget,
                responseBytes: KafkaFetchWire.responseBytes(partitions: targets.count, partitionBytes: partitionBudget)
            )
        }
        var body = try await connection.send(request)
        return try KafkaFetchWire.readResponse(&body, version: version, flexible: flexible)
    }

    private static func decode(
        _ reply: KafkaFetchedPartition,
        from startOffset: Int64,
        budget: inout DecompressionBudget
    ) throws -> KafkaFetchResult {
        guard let blob = reply.recordBatches, !blob.isEmpty else {
            return KafkaFetchResult(records: [], highWatermark: reply.highWatermark, truncated: false, nextOffset: nil)
        }
        let decoded = try KafkaRecordBatchDecoder.decode(
            blob: blob,
            partition: reply.partition,
            abortedTransactions: reply.abortedTransactions,
            skipAborted: true,
            budget: &budget
        )
        // A batch can start before the offset asked for, because the broker returns
        // whole batches. Dropping the head here is what keeps paging exact.
        let trimmed = decoded.records.filter { $0.offset >= startOffset }
        return KafkaFetchResult(
            records: trimmed,
            highWatermark: reply.highWatermark,
            truncated: decoded.truncated,
            nextOffset: decoded.nextOffset,
            bytesRead: blob.count
        )
    }
}
