import Foundation

struct KafkaBrowsePage: Sendable {
    let records: [KafkaRecord]
    /// The per-partition offsets this scan started from, so the next page can resume exactly
    /// where this one began rather than re-resolving a moving anchor.
    let anchor: [Int32: Int64]
    let truncated: Bool
}

/// Turns a `CONSUME` statement into reads against the cluster.
///
/// Kafka has no cross-partition ordering, no server-side sort and no skip-N, so a page is
/// assembled here: read forward from an anchor in each partition, merge, then slice. That is
/// the same shape Redis and DynamoDB already use to satisfy the host's integer limit/offset
/// from a cursor-native store.
enum KafkaBrowseEngine {
    /// The host asks for `limit` rows starting at `skip`. Over-fetching `skip + limit` and
    /// slicing is the honest way to answer that, but it has to be bounded or a deep page would
    /// pull an unbounded amount of the log into memory.
    private static let maximumOverFetch = 50_000

    static func consume(_ query: KafkaConsumeQuery, cluster: KafkaCluster) async throws -> KafkaBrowsePage {
        let metadata = try await cluster.metadata(topics: [query.topic])
        let topic = try metadata.requireTopic(named: query.topic)

        let available = topic.partitions.map(\.index).sorted()
        let selected = query.partitions.map { requested in
            requested.filter { available.contains($0) }
        } ?? available
        guard !selected.isEmpty else {
            return KafkaBrowsePage(records: [], anchor: [:], truncated: false)
        }

        let wanted = min(query.skip + query.limit, maximumOverFetch)
        let anchor = try await resolveAnchor(query, partitions: selected, cluster: cluster)

        // Each partition contributes at most `wanted` records, because the merge cannot know
        // in advance how the messages are distributed: one partition may hold the whole page.
        var collected: [KafkaRecord] = []
        var truncated = false
        for partition in selected {
            try Task.checkCancellation()
            guard let start = anchor[partition] else { continue }
            let result = try await KafkaFetchRequest.fetch(
                topic: query.topic,
                partition: partition,
                startOffset: start,
                maximumRecords: wanted,
                cluster: cluster
            )
            collected.append(contentsOf: result.records)
            if result.truncated { truncated = true }
        }

        let ordered = KafkaRecordOrdering.merge(collected)
        let page = Array(ordered.dropFirst(query.skip).prefix(query.limit))
        if ordered.count > query.skip + query.limit { truncated = true }
        return KafkaBrowsePage(records: page, anchor: anchor, truncated: truncated)
    }

    /// Resolves a start mode into one concrete offset per partition.
    ///
    /// `.resolved` short-circuits, and that is the point: the browse path bakes the resolved
    /// anchor into the query string it hands back, so re-running it for page two reads the
    /// same window rather than re-deriving "newest" against a tail that has since moved.
    static func resolveAnchor(
        _ query: KafkaConsumeQuery,
        partitions: [Int32],
        cluster: KafkaCluster
    ) async throws -> [Int32: Int64] {
        switch query.start {
        case .resolved(let anchors):
            return anchors.filter { partitions.contains($0.key) }

        case .oldest:
            return try await KafkaOffsetsRequest.listOffsets(
                topic: query.topic,
                partitions: partitions,
                timestamp: KafkaOffsetsRequest.earliestTimestamp,
                cluster: cluster
            )

        case .offset(let offset):
            let bounds = try await KafkaOffsetsRequest.bounds(
                topic: query.topic,
                partitions: partitions,
                cluster: cluster
            )
            // Clamping keeps a hand-typed offset from becoming OFFSET_OUT_OF_RANGE, which
            // reads as a driver failure rather than as "that offset is not in the log".
            var anchors: [Int32: Int64] = [:]
            for bound in bounds {
                anchors[bound.partition] = min(max(offset, bound.earliest), bound.latest)
            }
            return anchors

        case .timestamp(let milliseconds):
            let resolved = try await KafkaOffsetsRequest.listOffsets(
                topic: query.topic,
                partitions: partitions,
                timestamp: milliseconds,
                cluster: cluster
            )
            // A partition with nothing at or after that time answers -1, and the honest
            // reading of that is "start at the end", meaning it contributes nothing.
            let latest = try await KafkaOffsetsRequest.listOffsets(
                topic: query.topic,
                partitions: partitions,
                timestamp: KafkaOffsetsRequest.latestTimestamp,
                cluster: cluster
            )
            var anchors: [Int32: Int64] = [:]
            for partition in partitions {
                let candidate = resolved[partition] ?? -1
                anchors[partition] = candidate >= 0 ? candidate : (latest[partition] ?? 0)
            }
            return anchors

        case .newest:
            let bounds = try await KafkaOffsetsRequest.bounds(
                topic: query.topic,
                partitions: partitions,
                cluster: cluster
            )
            // "Newest" means the last N messages, so each partition steps back by its share of
            // the page and then reads forward. Sharing the budget evenly is a guess about how
            // messages are distributed, so it is deliberately generous: taking the whole page
            // size from every partition costs one extra read and never misses a recent message.
            let step = Int64(min(query.skip + query.limit, maximumOverFetch))
            var anchors: [Int32: Int64] = [:]
            for bound in bounds {
                anchors[bound.partition] = max(bound.earliest, bound.latest - step)
            }
            return anchors
        }
    }
}
