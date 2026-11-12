import Foundation
import TableProKafkaCore

/// Where a scan reads from, and which end of the merged run is the page.
struct KafkaScanWindow: Sendable {
    /// The first offset to read in each partition.
    let start: [Int32: Int64]
    /// The exclusive end each partition was measured back from. Empty for a forward scan.
    let tail: [Int32: Int64]
    /// True when the page is the newest rows of the window rather than the oldest.
    let readsBackward: Bool
    // The earliest offset of each partition a tail scan may walk back to. Empty for a forward scan.
    var floor: [Int32: Int64] = [:]
}

struct KafkaBrowsePage: Sendable {
    let records: [KafkaRecord]
    /// The window this scan was taken from, so the next page reads the same one rather than
    /// re-resolving a moving anchor.
    let window: KafkaScanWindow
    let truncated: Bool
}

/// Turns a `CONSUME` statement into reads against the cluster.
///
/// Kafka has no cross-partition ordering, no server-side sort and no skip-N, so a page is
/// assembled here: read forward from an anchor in each partition, merge, then slice. That is
/// the same shape Redis and DynamoDB already use to satisfy the host's integer limit/offset
/// from a cursor-native store.
///
/// Which end of the merged run is the page depends on the start mode, and getting that wrong is
/// invisible on one partition. `FROM NEWEST` steps each of P partitions back by the page size
/// and then reads forward, so the merged run holds up to P times the page and its newest rows
/// are at the END. Taking the front of it returned the oldest rows of the tail window and
/// called them the newest messages; with one partition the front and the back are the same rows,
/// which is why every test missed it.
enum KafkaBrowseEngine {
    /// The host asks for `limit` rows starting at `skip`. Over-fetching `skip + limit` and
    /// slicing is the honest way to answer that, but it has to be bounded or a deep page would
    /// pull an unbounded amount of the log into memory.
    private static let maximumOverFetch = 50_000
    // Past the page's own range a walk reads at most this many bytes per partition: a tail of aborted transactions,
    // or a range that runs from an empty stretch into a dense one, would otherwise be read without bound. The page is
    // then cut short and says so.
    private static let tailWalkByteBudget = 256 * 1_024 * 1_024

    static func consume(_ query: KafkaConsumeQuery, cluster: KafkaCluster) async throws -> KafkaBrowsePage {
        let metadata = try await cluster.metadata(topics: [query.topic])
        let topic = try metadata.requireTopic(named: query.topic)

        let available = topic.partitions.map(\.index).sorted()
        let selected = try resolvePartitions(query.partitions, available: available, topic: query.topic)
        guard !selected.isEmpty else {
            return KafkaBrowsePage(
                records: [],
                window: KafkaScanWindow(start: [:], tail: [:], readsBackward: false),
                truncated: false
            )
        }

        let wanted = min(query.skip + query.limit, maximumOverFetch)
        let window = try await resolveWindow(query, partitions: selected, cluster: cluster)

        // Each partition contributes at most `wanted` records, because the merge cannot know
        // in advance how the messages are distributed: one partition may hold the whole page.
        var collected: [KafkaRecord] = []
        var truncated = query.skip + query.limit > maximumOverFetch
        var walkedStarts = window.start
        for partition in selected {
            try Task.checkCancellation()
            guard let start = window.start[partition] else { continue }
            // A tail scan must not read past the end it was anchored to, or page two would show
            // messages produced after page one and the window would not be a window at all.
            if window.readsBackward, let end = window.tail[partition] {
                var walk = KafkaTailWalk<KafkaRecord>(
                    wanted: wanted,
                    end: end,
                    firstStart: start,
                    floor: window.floor[partition] ?? start
                )
                // The page's own range is read as before; the ranges past it share the budget.
                var walkBytesLeft: Int?
                while let range = walk.nextRange {
                    try Task.checkCancellation()
                    let result = try await KafkaFetchRequest.fetch(
                        topic: query.topic,
                        partition: partition,
                        startOffset: range.start,
                        maximumRecords: walk.needed,
                        endOffset: range.end,
                        keepingNewest: walk.needed,
                        byteBudget: walkBytesLeft,
                        cluster: cluster
                    )
                    if result.stoppedAtByteBudget {
                        truncated = true
                        break
                    }
                    walkBytesLeft = walkBytesLeft.map { $0 - result.bytesRead } ?? tailWalkByteBudget
                    if result.truncated { truncated = true }
                    walk.absorb(result.records)
                }
                collected.append(contentsOf: walk.records)
                walkedStarts[partition] = walk.start
                continue
            }
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
        let page = KafkaRecordOrdering.page(
            ordered,
            skip: query.skip,
            limit: query.limit,
            readsBackward: window.readsBackward
        )
        if ordered.count > query.skip + query.limit { truncated = true }
        let walked = KafkaScanWindow(
            start: walkedStarts, tail: window.tail, readsBackward: window.readsBackward, floor: window.floor
        )
        return KafkaBrowsePage(records: page, window: walked, truncated: truncated)
    }

    /// The partitions to read, or an error naming the ones the topic does not have.
    ///
    /// A filter that quietly drops what it cannot match returns an empty page indistinguishable
    /// from an empty topic. The topic name already refuses to work that way
    /// (`KafkaClusterMetadata.requireTopic`) and a partition number is no different.
    static func resolvePartitions(_ requested: [Int32]?, available: [Int32], topic: String) throws -> [Int32] {
        guard let requested else { return available }
        let missing = requested.filter { !available.contains($0) }
        guard missing.isEmpty else {
            throw KafkaError.unknownPartitions(topic: topic, partitions: missing, available: available)
        }
        return Set(requested).sorted()
    }

    // `.resolved` and `.tail` come from the window baked into page one's query, so page two reads that window, not a moved tail.
    static func resolveWindow(
        _ query: KafkaConsumeQuery,
        partitions: [Int32],
        cluster: KafkaCluster
    ) async throws -> KafkaScanWindow {
        let step = Int64(min(query.skip + query.limit, maximumOverFetch))

        switch query.start {
        case .resolved(let anchors):
            return KafkaScanWindow(
                start: anchors.filter { partitions.contains($0.key) },
                tail: [:],
                readsBackward: false
            )

        case .tail(let ends):
            // The window is fixed by the ends page one recorded, so a later page steps back
            // from the same place. Re-deriving "newest" here would walk the window forward and
            // page two would show page one's rows again, or none at all.
            let kept = ends.filter { partitions.contains($0.key) }
            let earliest = try await KafkaOffsetsRequest.listOffsets(
                topic: query.topic,
                partitions: Array(kept.keys),
                timestamp: KafkaOffsetsRequest.earliestTimestamp,
                cluster: cluster
            )
            var starts: [Int32: Int64] = [:]
            var floors: [Int32: Int64] = [:]
            for (partition, end) in kept {
                // No fallback offset. A partition whose earliest offset did not come back has
                // an unknown floor, and anchoring it at zero would send the page to the start of
                // a log whose first surviving message may be far past it.
                guard let floor = earliest[partition] else { continue }
                starts[partition] = KafkaOffsetMath.stepBack(from: end, by: step, floor: floor)
                floors[partition] = floor
            }
            return KafkaScanWindow(start: starts, tail: kept, readsBackward: true, floor: floors)

        case .oldest:
            let starts = try await KafkaOffsetsRequest.listOffsets(
                topic: query.topic,
                partitions: partitions,
                timestamp: KafkaOffsetsRequest.earliestTimestamp,
                cluster: cluster
            )
            return KafkaScanWindow(start: starts, tail: [:], readsBackward: false)

        case .offset(let offset):
            let bounds = try await KafkaOffsetsRequest.bounds(
                topic: query.topic,
                partitions: partitions,
                cluster: cluster
            )
            // Clamping keeps a hand-typed offset from becoming OFFSET_OUT_OF_RANGE, which
            // reads as a driver failure rather than as "that offset is not in the log".
            var starts: [Int32: Int64] = [:]
            for bound in bounds {
                starts[bound.partition] = min(max(offset, bound.earliest), bound.latest)
            }
            return KafkaScanWindow(start: starts, tail: [:], readsBackward: false)

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
            var starts: [Int32: Int64] = [:]
            for partition in partitions {
                let candidate = resolved[partition] ?? -1
                starts[partition] = candidate >= 0 ? candidate : (latest[partition] ?? 0)
            }
            return KafkaScanWindow(start: starts, tail: [:], readsBackward: false)

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
            // The merged run is then read from its newest end, which is what `readsBackward`
            // says and what the partition count would otherwise hide.
            var starts: [Int32: Int64] = [:]
            var ends: [Int32: Int64] = [:]
            var floors: [Int32: Int64] = [:]
            for bound in bounds {
                starts[bound.partition] = KafkaOffsetMath.stepBack(from: bound.latest, by: step, floor: bound.earliest)
                ends[bound.partition] = bound.latest
                floors[bound.partition] = bound.earliest
            }
            return KafkaScanWindow(start: starts, tail: ends, readsBackward: true, floor: floors)
        }
    }
}
